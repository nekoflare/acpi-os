use std::{fmt, io};

use crate::aml::{
    ContainerKind, Declaration, Expression, IntegerLiteral, Literal, Operator, Statement,
    StatementKind, Table,
};

pub fn write(out: &mut impl io::Write, table: &Table) -> io::Result<()> {
    writeln!(out, "{} ({} bytes)", table.signature, table.length)?;
    for declaration in &table.declarations {
        let method = match declaration {
            Declaration::Name(value) => {
                writeln!(
                    out,
                    "{:#06x}  Name {} = {}",
                    value.offset, value.name, value.initializer
                )?;
                continue;
            }
            Declaration::Scope { offset, name } => {
                writeln!(out, "{offset:#06x}  Scope {name}")?;
                continue;
            }
            Declaration::Container { offset, name, kind } => {
                match kind {
                    ContainerKind::Device => writeln!(out, "{offset:#06x}  Device {name}")?,
                    ContainerKind::Processor { id, block, length } => writeln!(
                        out,
                        "{offset:#06x}  Processor {name} (id={id}, block={block:#x}, length={length})"
                    )?,
                    ContainerKind::PowerResource { level, order } => writeln!(
                        out,
                        "{offset:#06x}  PowerResource {name} (level={level}, order={order})"
                    )?,
                    ContainerKind::ThermalZone => {
                        writeln!(out, "{offset:#06x}  ThermalZone {name}")?
                    }
                }
                continue;
            }
            Declaration::Alias { offset, name } => {
                writeln!(out, "{offset:#06x}  Alias {name}")?;
                continue;
            }
            Declaration::External {
                offset,
                name,
                kind,
                arity,
                ..
            } => {
                writeln!(
                    out,
                    "{offset:#06x}  External {name} (type={kind}, args={arity})"
                )?;
                continue;
            }
            Declaration::Mutex {
                offset,
                name,
                level,
            } => {
                writeln!(out, "{offset:#06x}  Mutex {name} (sync_level={level})")?;
                continue;
            }
            Declaration::Region(region) => {
                writeln!(
                    out,
                    "{:#06x}  OperationRegion({}, {:#x}, {}, {})",
                    region.offset, region.name, region.space, region.base, region.length
                )?;
                continue;
            }
            Declaration::RegionFields(fields) => {
                write!(out, "{:#06x}  ", fields.offset)?;
                write_fields(out, fields)?;
                continue;
            }
            Declaration::Event { offset, name } => {
                writeln!(out, "{offset:#06x}  Event {name}")?;
                continue;
            }
            Declaration::Noop { offset } => {
                writeln!(out, "{offset:#06x}  Noop")?;
                continue;
            }
            Declaration::Field(field) => {
                writeln!(out, "        {field}")?;
                continue;
            }
            Declaration::Executable(body) => {
                write_statements(out, body, 0)?;
                continue;
            }
            Declaration::Method(method) => method,
        };
        writeln!(
            out,
            "{:#06x}  Method {} (args={}, serialized={}, sync_level={}) {{",
            method.offset,
            method.name,
            method.arg_count(),
            method.flags & 0x08 != 0,
            method.flags >> 4,
        )?;
        write_statements(out, &method.body, 1)?;
        writeln!(out, "        }}")?;
    }
    Ok(())
}

fn write_fields(out: &mut impl io::Write, fields: &crate::aml::RegionFields) -> io::Result<()> {
    use crate::aml::FieldBacking::*;
    match &fields.backing {
        Region(region) => writeln!(out, "Field({region})")?,
        Bank(region, selector, value) => writeln!(out, "BankField({region}, {selector}, {value})")?,
        Index(index, data) => writeln!(out, "IndexField({index}, {data})")?,
    }
    for unit in &fields.units {
        writeln!(
            out,
            "        {} (start={}, bits={}, flags={:#x})",
            unit.name, unit.start, unit.bits, unit.flags
        )?;
    }
    Ok(())
}

fn write_statements(out: &mut impl io::Write, body: &[Statement], depth: usize) -> io::Result<()> {
    let indent = depth * 2;
    for statement in body {
        write!(out, "{:#06x}  {:indent$}", statement.offset, "")?;
        match &statement.kind {
            StatementKind::Region(region) => writeln!(
                out,
                "OperationRegion({}, {:#x}, {}, {})",
                region.name, region.space, region.base, region.length
            )?,
            StatementKind::RegionFields(fields) => write_fields(out, fields)?,
            StatementKind::Name(name, value) => writeln!(out, "Name({name}, {value})")?,
            StatementKind::If {
                predicate,
                body,
                otherwise,
            } => {
                writeln!(out, "If ({predicate}) {{")?;
                write_statements(out, body, depth + 1)?;
                writeln!(out, "        {:indent$}}}", "")?;
                if let Some(otherwise) = otherwise {
                    writeln!(out, "{:#06x}  {:indent$}Else {{", otherwise.offset, "")?;
                    write_statements(out, &otherwise.body, depth + 1)?;
                    writeln!(out, "        {:indent$}}}", "")?;
                }
            }
            StatementKind::While(predicate, body) => {
                writeln!(out, "While ({predicate}) {{")?;
                write_statements(out, body, depth + 1)?;
                writeln!(out, "        {:indent$}}}", "")?;
            }
            StatementKind::Break => writeln!(out, "Break")?,
            StatementKind::Continue => writeln!(out, "Continue")?,
            StatementKind::Noop => writeln!(out, "Noop")?,
            StatementKind::Return(value) => writeln!(out, "Return({value})")?,
            StatementKind::Delay { sleep, duration } => {
                let opcode = if *sleep { "Sleep" } else { "Stall" };
                writeln!(out, "{opcode}({duration})")?;
            }
            StatementKind::Unload(handle) => writeln!(out, "Unload({handle})")?,
            StatementKind::Release(target) => writeln!(out, "Release({target})")?,
            StatementKind::EventControl { target, signal } => {
                let opcode = if *signal { "Signal" } else { "Reset" };
                writeln!(out, "{opcode}({target})")?;
            }
            StatementKind::Notify(target, value) => writeln!(out, "Notify({target}, {value})")?,
            StatementKind::Evaluate(value) => writeln!(out, "{value}")?,
        }
    }
    Ok(())
}

impl fmt::Display for Expression {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let args = match self {
            Self::Integer(value) => return write!(f, "{value}"),
            Self::String(bytes) => return write_string(f, bytes),
            Self::Local(index) => return write!(f, "Local{index}"),
            Self::Arg(index) => return write!(f, "Arg{index}"),
            Self::Buffer(size, bytes) => return write!(f, "Buffer({size}, {bytes:02X?})"),
            Self::Package(size, elements) => {
                write!(f, "Package({size}")?;
                for element in elements {
                    write!(f, ", {element}")?;
                }
                return f.write_str(")");
            }
            Self::CreateField {
                name,
                buffer,
                index,
                length,
                ..
            } => {
                return write!(f, "CreateField({buffer}, {index}, {length}, {name})");
            }
            Self::Field(name) => return write!(f, "{name}"),
            Self::NullTarget => return f.write_str("NullTarget"),
            Self::DebugTarget => return f.write_str("Debug"),
            Self::Name(name) | Self::RegionSource(name) | Self::NamespaceObject(name, _) => {
                return write!(f, "{name}");
            }
            Self::CondRefOf { source, target } => {
                if let Some(source) = source {
                    return write!(f, "CondRefOf({source}, {target})");
                }
                return write!(f, "CondRefOf(<unresolved>, {target})");
            }
            Self::Call(name, args) => {
                write!(f, "Call {name}(")?;
                args
            }
            Self::UnresolvedCall(name, args) => {
                write!(f, "UnresolvedCall {name}(")?;
                args
            }
            Self::Apply(Operator::NamespaceType(name, _), _) => {
                return write!(f, "ObjectType({name})");
            }
            Self::Apply(Operator::Acquire(target, timeout), _) => {
                return write!(f, "Acquire({target}, {timeout:#x})");
            }
            Self::Apply(Operator::Wait(target), args) => {
                write!(f, "Wait({target}, ")?;
                args
            }
            Self::Apply(op, args) => {
                write!(f, "{op:?}(")?;
                args
            }
        };
        for (index, arg) in args.iter().enumerate() {
            if index != 0 {
                f.write_str(", ")?;
            }
            write!(f, "{arg}")?;
        }
        f.write_str(")")
    }
}

impl fmt::Display for IntegerLiteral {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Zero => f.write_str("Zero"),
            Self::One => f.write_str("One"),
            Self::Ones => f.write_str("Ones"),
            Self::Immediate(value) => write!(f, "{value:#x}"),
        }
    }
}

impl fmt::Display for Literal {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Integer(integer) => write!(f, "{integer}"),
            Self::String(bytes) => write_string(f, bytes),
            Self::Aggregate(expression) => write!(f, "{expression}"),
            Self::Pending => unreachable!("initializer has been parsed"),
        }
    }
}

fn write_string(f: &mut fmt::Formatter<'_>, bytes: &[u8]) -> fmt::Result {
    write!(f, "\"{}\"", bytes.escape_ascii())
}
