//! Links the generated AML module with the C object runtime.
//!
//! The runtime (`objects.c`) is compiled to bitcode with clang and merged
//! into the generated module in-process through the LLVM linker.

use std::io;
#[cfg(unix)]
use std::os::unix::fs::DirBuilderExt;
use std::path::PathBuf;
use std::process::Command;
use std::{env, fs};

use crate::ir::{Context, Module};

struct TemporaryDirectory(PathBuf);

impl TemporaryDirectory {
    fn create() -> io::Result<Self> {
        let mut builder = fs::DirBuilder::new();
        #[cfg(unix)]
        builder.mode(0o700);
        for attempt in 0..128 {
            let path = env::temp_dir().join(format!("amlaot-{}-{attempt}", std::process::id()));
            match builder.create(&path) {
                Ok(()) => return Ok(Self(path)),
                Err(error) if error.kind() == io::ErrorKind::AlreadyExists => continue,
                Err(error) => return Err(error),
            }
        }
        Err(io::Error::new(
            io::ErrorKind::AlreadyExists,
            "no temporary directory available",
        ))
    }
}

impl Drop for TemporaryDirectory {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn run(command: &mut Command) -> Result<(), String> {
    let output = command
        .output()
        .map_err(|error| format!("{command:?}: {error}"))?;
    if !output.status.success() {
        return Err(format!(
            "{command:?}: {}",
            String::from_utf8_lossy(&output.stderr).trim(),
        ));
    }
    Ok(())
}

/// Links the runtime into `module` and returns the combined textual IR.
pub fn link(llvm: &Context, module: Module<'_>, freestanding: bool) -> Result<String, String> {
    let temp = TemporaryDirectory::create()
        .map_err(|error| format!("creating link directory: {error}"))?;
    for (name, contents) in [
        ("objects.c", include_str!("objects.c")),
        ("runtime.h", include_str!("runtime.h")),
    ] {
        fs::write(temp.0.join(name), contents)
            .map_err(|error| format!("writing {name}: {error}"))?;
    }
    let clang = env::var_os("AMLAOT_CLANG").unwrap_or_else(|| "clang".into());
    let objects = temp.0.join("objects.bc");
    let mut compiler = Command::new(clang);
    compiler.args(["-std=c17", "-O1", "-emit-llvm", "-c"]);
    if freestanding {
        compiler.args([
            "-ffreestanding",
            "-fno-stack-protector",
            "-mno-red-zone",
            "-mgeneral-regs-only",
        ]);
    }
    // Generated functions inherit the runtime's target attributes, so a
    // target such as `-march=x86-64-v3` must be chosen here; `-march` on
    // the final compile of the linked module cannot override them.
    if let Some(flags) = env::var_os("AMLAOT_RUNTIME_CFLAGS") {
        let flags = flags
            .into_string()
            .map_err(|_| "AMLAOT_RUNTIME_CFLAGS is not valid UTF-8".to_string())?;
        compiler.args(flags.split_whitespace());
    }
    run(compiler
        .arg("-o")
        .arg(&objects)
        .arg(temp.0.join("objects.c")))?;
    let runtime = llvm.parse_bitcode(&objects)?;
    module.link(runtime)?;
    // Generated functions must share the runtime's target attributes, or
    // LLVM will not inline runtime helpers (including the always-inline
    // freestanding `aml_object_op`) into them.
    module.inherit_target_attributes("aml_object_op");
    module.verify()?;
    Ok(module.print())
}
