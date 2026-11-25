//! Intrinsic manifests: external AML methods the compiler lowers inline.
//!
//! A manifest maps the names of `External` methods to machine operations, so
//! an AML program can reach hardware without the compiler knowing about any
//! particular kernel. Every intrinsic takes AML integers and returns one.
//!
//! One definition per line; `#` starts a comment. Strings use double quotes
//! with `\"` and `\\` escapes.
//!
//! ```text
//! XLDQ load u64 volatile          # Arg0: address; returns the value
//! XSTB store u8 volatile          # Arg0: address, Arg1: value; returns 0
//! XXAD atomic add u64             # Arg0: address, Arg1: operand; returns the old value
//! XCAS cmpxchg u64                # Arg0: address, Arg1: expected, Arg2: new; returns the old value
//! XTSC asm 0 "rdtsc; shlq $$32, %rdx; orq %rdx, %rax" "={rax},~{rdx}"
//! XCPU call 0 acpi_online_cpu_count pure
//! ```
//!
//! Widths are `u8`, `u16`, `u32`, and `u64`; loads zero-extend and stores
//! truncate. Memory operations without `volatile` let LLVM merge or drop
//! accesses, so reserve them for memory nothing else changes concurrently.
//! Atomic operations are sequentially consistent and support `add`, `sub`,
//! `and`, `or`, `xor`, and `xchg`.
//!
//! `asm <arity> "<template>" "<constraints>"` takes `arity` integer inputs
//! and returns its output if the constraints declare one (`=`), otherwise 0.
//! `call <arity> <symbol>` calls `uint64_t symbol(uint64_t, ...)`. Both treat
//! the operation as having side effects unless marked `pure`, which lets
//! LLVM merge, hoist, or delete calls whose result is unused.

use std::collections::HashMap;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Width {
    U8 = 8,
    U16 = 16,
    U32 = 32,
    U64 = 64,
}

impl Width {
    pub fn bits(self) -> u32 {
        self as u32
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AtomicOp {
    Xchg,
    Add,
    Sub,
    And,
    Or,
    Xor,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Intrinsic {
    Load {
        width: Width,
        volatile: bool,
    },
    Store {
        width: Width,
        volatile: bool,
    },
    Atomic {
        op: AtomicOp,
        width: Width,
    },
    CmpXchg {
        width: Width,
    },
    Asm {
        arity: usize,
        template: String,
        constraints: String,
        pure: bool,
    },
    Call {
        arity: usize,
        symbol: String,
        pure: bool,
    },
}

impl Intrinsic {
    pub fn arity(&self) -> usize {
        match self {
            Intrinsic::Load { .. } => 1,
            Intrinsic::Store { .. } | Intrinsic::Atomic { .. } => 2,
            Intrinsic::CmpXchg { .. } => 3,
            Intrinsic::Asm { arity, .. } | Intrinsic::Call { arity, .. } => *arity,
        }
    }
}

/// Intrinsics keyed by the four-character AML name.
#[derive(Default, Debug)]
pub struct Manifest(HashMap<String, Intrinsic>);

/// Names the code generator implements itself; a manifest cannot redefine them.
pub const BUILTIN_NAMES: [&str; 5] = ["XADR", "XGDT", "XIDT", "XHND", "XBRK"];

impl Manifest {
    pub fn get(&self, name: &str) -> Option<&Intrinsic> {
        self.0.get(name)
    }

    pub fn parse(source: &str) -> Result<Self, String> {
        let mut manifest = Self::default();
        for (index, line) in source.lines().enumerate() {
            let error = |message: String| format!("line {}: {message}", index + 1);
            let tokens = tokenize(line).map_err(error)?;
            let Some((name, rest)) = tokens.split_first() else {
                continue;
            };
            let name = name.word().map_err(error)?;
            if name.len() != 4
                || !name
                    .bytes()
                    .all(|byte| byte.is_ascii_uppercase() || byte.is_ascii_digit() || byte == b'_')
                || name.as_bytes()[0].is_ascii_digit()
            {
                return Err(error(format!("{name:?} is not a four-character AML name")));
            }
            if BUILTIN_NAMES.contains(&name) {
                return Err(error(format!("{name} is built into the compiler")));
            }
            let intrinsic = parse_definition(rest).map_err(error)?;
            if manifest.0.insert(name.to_owned(), intrinsic).is_some() {
                return Err(error(format!("{name} is defined twice")));
            }
        }
        Ok(manifest)
    }
}

enum Token {
    Word(String),
    Quoted(String),
}

impl Token {
    fn word(&self) -> Result<&str, String> {
        match self {
            Token::Word(word) => Ok(word),
            Token::Quoted(text) => Err(format!("unexpected string {text:?}")),
        }
    }

    fn string(&self) -> Result<&str, String> {
        match self {
            Token::Quoted(text) => Ok(text),
            Token::Word(word) => Err(format!("expected a quoted string, found {word:?}")),
        }
    }
}

fn tokenize(line: &str) -> Result<Vec<Token>, String> {
    let mut tokens = Vec::new();
    let mut chars = line.chars().peekable();
    while let Some(&next) = chars.peek() {
        match next {
            '#' => break,
            c if c.is_whitespace() => {
                chars.next();
            }
            '"' => {
                chars.next();
                let mut text = String::new();
                loop {
                    match chars.next() {
                        Some('"') => break,
                        Some('\\') => match chars.next() {
                            Some(c @ ('"' | '\\')) => text.push(c),
                            other => return Err(format!("invalid escape {other:?}")),
                        },
                        Some(c) => text.push(c),
                        None => return Err("unterminated string".into()),
                    }
                }
                tokens.push(Token::Quoted(text));
            }
            _ => {
                let mut word = String::new();
                while let Some(&c) = chars.peek() {
                    if c.is_whitespace() || c == '#' || c == '"' {
                        break;
                    }
                    word.push(c);
                    chars.next();
                }
                tokens.push(Token::Word(word));
            }
        }
    }
    Ok(tokens)
}

fn parse_width(token: Option<&Token>) -> Result<Width, String> {
    let word = token.ok_or("missing width")?.word()?;
    Ok(match word {
        "u8" => Width::U8,
        "u16" => Width::U16,
        "u32" => Width::U32,
        "u64" => Width::U64,
        _ => return Err(format!("unknown width {word:?}; use u8, u16, u32, or u64")),
    })
}

fn parse_arity(token: Option<&Token>) -> Result<usize, String> {
    let word = token.ok_or("missing arity")?.word()?;
    match word.parse::<usize>() {
        Ok(arity) if arity <= 7 => Ok(arity),
        _ => Err(format!(
            "invalid arity {word:?}; AML methods take 0 to 7 arguments"
        )),
    }
}

/// Parses trailing flags, accepting only those in `allowed`.
fn parse_flags(tokens: &[Token], allowed: &[&str]) -> Result<Vec<String>, String> {
    let mut flags = Vec::new();
    for token in tokens {
        let flag = token.word()?;
        if !allowed.contains(&flag) {
            return Err(format!("unexpected {flag:?}"));
        }
        if flags.iter().any(|seen| seen == flag) {
            return Err(format!("{flag} given twice"));
        }
        flags.push(flag.to_owned());
    }
    Ok(flags)
}

fn parse_definition(tokens: &[Token]) -> Result<Intrinsic, String> {
    let (kind, rest) = tokens.split_first().ok_or("missing operation")?;
    let kind = kind.word()?;
    let intrinsic = match kind {
        "load" | "store" => {
            let width = parse_width(rest.first())?;
            let volatile = !parse_flags(&rest[1..], &["volatile"])?.is_empty();
            if kind == "load" {
                Intrinsic::Load { width, volatile }
            } else {
                Intrinsic::Store { width, volatile }
            }
        }
        "atomic" => {
            let op = rest.first().ok_or("missing atomic operation")?.word()?;
            let op = match op {
                "xchg" => AtomicOp::Xchg,
                "add" => AtomicOp::Add,
                "sub" => AtomicOp::Sub,
                "and" => AtomicOp::And,
                "or" => AtomicOp::Or,
                "xor" => AtomicOp::Xor,
                _ => return Err(format!("unknown atomic operation {op:?}")),
            };
            let width = parse_width(rest.get(1))?;
            parse_flags(rest.get(2..).unwrap_or_default(), &[])?;
            Intrinsic::Atomic { op, width }
        }
        "cmpxchg" => {
            let width = parse_width(rest.first())?;
            parse_flags(&rest[1..], &[])?;
            Intrinsic::CmpXchg { width }
        }
        "asm" => {
            let arity = parse_arity(rest.first())?;
            let template = rest.get(1).ok_or("missing asm template")?.string()?;
            let constraints = rest.get(2).ok_or("missing asm constraints")?.string()?;
            let pure = !parse_flags(&rest[3..], &["pure"])?.is_empty();
            Intrinsic::Asm {
                arity,
                template: template.to_owned(),
                constraints: constraints.to_owned(),
                pure,
            }
        }
        "call" => {
            let arity = parse_arity(rest.first())?;
            let symbol = rest.get(1).ok_or("missing symbol")?.word()?;
            if symbol.is_empty()
                || !symbol
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || byte == b'_' || byte == b'.')
            {
                return Err(format!("invalid symbol {symbol:?}"));
            }
            let pure = !parse_flags(&rest[2..], &["pure"])?.is_empty();
            Intrinsic::Call {
                arity,
                symbol: symbol.to_owned(),
                pure,
            }
        }
        _ => return Err(format!("unknown operation {kind:?}")),
    };
    Ok(intrinsic)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_every_operation() {
        let manifest = Manifest::parse(
            r#"
            # memory
            XLDQ load u64 volatile
            XSTB store u8          # plain store
            XXAD atomic add u32
            XCAS cmpxchg u64
            XTSC asm 0 "rdtsc; shlq $$32, %rdx; orq %rdx, %rax" "={rax},~{rdx}"
            XINV asm 1 "invlpg ($0)" "r,~{memory}"
            XCPU call 0 acpi_online_cpu_count pure
            "#,
        )
        .unwrap();
        assert_eq!(
            manifest.get("XLDQ"),
            Some(&Intrinsic::Load {
                width: Width::U64,
                volatile: true
            })
        );
        assert_eq!(
            manifest.get("XSTB"),
            Some(&Intrinsic::Store {
                width: Width::U8,
                volatile: false
            })
        );
        assert_eq!(manifest.get("XXAD").unwrap().arity(), 2);
        assert_eq!(manifest.get("XCAS").unwrap().arity(), 3);
        assert_eq!(
            manifest.get("XINV"),
            Some(&Intrinsic::Asm {
                arity: 1,
                template: "invlpg ($0)".into(),
                constraints: "r,~{memory}".into(),
                pure: false
            })
        );
        assert_eq!(
            manifest.get("XCPU"),
            Some(&Intrinsic::Call {
                arity: 0,
                symbol: "acpi_online_cpu_count".into(),
                pure: true
            })
        );
    }

    #[test]
    fn rejects_bad_definitions() {
        for source in [
            "XLDQ load u128",
            "XLDQ load u64 fast",
            "XLDQ load u64\nXLDQ load u8",
            "XGDT load u64",
            "LONGNAME load u64",
            "XTSC asm 0 rdtsc \"=r\"",
            "XTSC asm 9 \"rdtsc\" \"=r\"",
            "XCPU call 0",
            "XCPU frobnicate",
            "XTSC asm 0 \"rdtsc",
        ] {
            assert!(Manifest::parse(source).is_err(), "accepted {source:?}");
        }
    }
}
