use std::io;
#[cfg(unix)]
use std::os::unix::fs::DirBuilderExt;
use std::path::PathBuf;
use std::process::Command;
use std::{env, fs};

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

fn run(command: &mut Command) -> Result<Vec<u8>, String> {
    let output = command
        .output()
        .map_err(|error| format!("{command:?}: {error}"))?;
    if !output.status.success() {
        return Err(format!(
            "{command:?}: {}",
            String::from_utf8_lossy(&output.stderr).trim(),
        ));
    }
    Ok(output.stdout)
}

pub fn link(module: &str, freestanding: bool) -> Result<Vec<u8>, String> {
    let temp = TemporaryDirectory::create()
        .map_err(|error| format!("creating link directory: {error}"))?;
    for (name, contents) in [
        ("methods.ll", module),
        ("objects.c", include_str!("objects.c")),
        ("runtime.h", include_str!("runtime.h")),
    ] {
        fs::write(temp.0.join(name), contents)
            .map_err(|error| format!("writing {name}: {error}"))?;
    }
    let clang = env::var_os("AMLAOT_CLANG").unwrap_or_else(|| "clang".into());
    let linker = env::var_os("AMLAOT_LLVM_LINK").unwrap_or_else(|| "llvm-link".into());
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
    run(compiler
        .arg("-o")
        .arg(&objects)
        .arg(temp.0.join("objects.c")))?;
    run(Command::new(linker)
        .args(["-S", "-o", "-"])
        .arg(objects)
        .arg(temp.0.join("methods.ll")))
}
