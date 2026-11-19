mod aml;
mod dump;
mod link;
mod llvm;

use std::io::Write;
use std::path::Path;
use std::{env, fs, io, process::ExitCode};

fn run() -> Result<(), Box<dyn std::error::Error>> {
    const USAGE: &str = "usage: amlaot [--emit-llvm [--freestanding]] [--dsdt <dsdt.aml>] [--dynamic-ssdt <table.aml>]... <table.aml> [ssdt.aml ...]";
    let mut args = env::args_os().skip(1);
    let mut emit_llvm = false;
    let mut freestanding = false;
    let mut dsdt = None;
    let mut paths = Vec::new();
    let mut dynamic_paths = Vec::new();
    while let Some(arg) = args.next() {
        match arg.to_str() {
            Some("--emit-llvm") if !emit_llvm => emit_llvm = true,
            Some("--freestanding") if !freestanding => freestanding = true,
            Some("--dsdt") if dsdt.is_none() => dsdt = Some(args.next().ok_or(USAGE)?),
            Some("--dynamic-ssdt") => dynamic_paths.push(args.next().ok_or(USAGE)?),
            Some(arg) if arg.starts_with("--") => return Err(USAGE.into()),
            _ => paths.push(arg),
        }
    }
    if paths.is_empty() || (freestanding && !emit_llvm) {
        return Err(USAGE.into());
    }
    if let Some(dsdt) = dsdt {
        paths.insert(0, dsdt);
    }
    let static_count = paths.len();
    paths.extend(dynamic_paths);
    let sources = paths
        .iter()
        .map(|path| {
            let path = Path::new(path);
            Ok((path.display().to_string(), read_table(path)?))
        })
        .collect::<Result<Vec<_>, String>>()?;
    let inputs: Vec<_> = sources
        .iter()
        .map(|(label, bytes)| (label.as_str(), bytes.as_slice()))
        .collect();
    let tables = aml::parse_tables(&inputs)?;
    let mut out = io::stdout().lock();
    if emit_llvm {
        let module = llvm::emit(
            &tables,
            tables[0].integer_width(),
            static_count,
            freestanding,
        )?;
        out.write_all(&link::link(&module, freestanding)?)?;
    } else {
        for table in &tables {
            dump::write(&mut out, table)?;
        }
    }
    Ok(())
}

fn read_table(path: &Path) -> Result<Vec<u8>, String> {
    fs::read(path).map_err(|err| format!("{}: {err}", path.display()))
}

fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(err) => {
            eprintln!("amlaot: {err}");
            ExitCode::FAILURE
        }
    }
}
