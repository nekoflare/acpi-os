//! Links the LLVM C API libraries that `src/ir.rs` declares.
//!
//! `llvm-config` is taken from `AMLAOT_LLVM_CONFIG`, falling back to `PATH`.
//! A shared LLVM build is linked as `libLLVM`; a static one as its component
//! archives plus their system libraries and the C++ runtime.

use std::env;
use std::process::Command;

const COMPONENTS: &[&str] = &["core", "bitreader", "linker", "analysis"];

fn llvm_config(program: &str, args: &[&str]) -> String {
    let output = Command::new(program)
        .args(args)
        .output()
        .unwrap_or_else(|error| panic!("cannot run {program}: {error}"));
    if !output.status.success() {
        panic!(
            "{program} {} failed:\n{}",
            args.join(" "),
            String::from_utf8_lossy(&output.stderr)
        );
    }
    String::from_utf8(output.stdout)
        .expect("llvm-config printed invalid UTF-8")
        .trim()
        .to_owned()
}

fn main() {
    println!("cargo:rerun-if-env-changed=AMLAOT_LLVM_CONFIG");
    println!("cargo:rerun-if-env-changed=AMLAOT_LLVM_LINK");
    let program = env::var("AMLAOT_LLVM_CONFIG").unwrap_or_else(|_| "llvm-config".into());

    let version = llvm_config(&program, &["--version"]);
    let major: u32 = version
        .split('.')
        .next()
        .and_then(|major| major.parse().ok())
        .unwrap_or(0);
    if major < 18 {
        panic!("{program} reports LLVM {version}; LLVM 18 or newer is required");
    }

    let mode =
        env::var("AMLAOT_LLVM_LINK").unwrap_or_else(|_| llvm_config(&program, &["--shared-mode"]));
    let link = match mode.as_str() {
        "shared" => "--link-shared",
        "static" => "--link-static",
        other => panic!("unknown LLVM link mode {other:?}"),
    };

    println!(
        "cargo:rustc-link-search=native={}",
        llvm_config(&program, &["--libdir"])
    );
    let mut args = vec![link, "--libs"];
    args.extend(COMPONENTS);
    let kind = if link == "--link-static" {
        "static="
    } else {
        "dylib="
    };
    for library in llvm_config(&program, &args).split_whitespace() {
        let name = library.strip_prefix("-l").unwrap_or(library);
        println!("cargo:rustc-link-lib={kind}{name}");
    }
    if link == "--link-static" {
        let mut args = vec![link, "--system-libs"];
        args.extend(COMPONENTS);
        for flag in llvm_config(&program, &args).split_whitespace() {
            if let Some(name) = flag.strip_prefix("-l") {
                println!("cargo:rustc-link-lib={name}");
            }
        }
        println!("cargo:rustc-link-lib=stdc++");
    }
}
