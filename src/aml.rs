use std::cell::RefCell;
use std::collections::HashMap;
use std::fmt;

const HEADER_LEN: usize = 36;
const MAX_DEPTH: usize = 64;
const MAX_STATEMENT_DEPTH: usize = 128;

#[derive(Debug)]
pub struct ParseError {
    offset: usize,
    message: String,
}

impl fmt::Display for ParseError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "at file offset {:#06x}: {}", self.offset, self.message)
    }
}

impl std::error::Error for ParseError {}

pub struct Table {
    pub signature: &'static str,
    pub length: usize,
    pub revision: u8,
    pub bytes: Vec<u8>,
    pub aliases: Vec<(AbsolutePath, AbsolutePath)>,
    pub declarations: Vec<Declaration>,
}

#[derive(Clone, Copy)]
pub enum IntegerWidth {
    Bits32,
    Bits64,
}

impl IntegerWidth {
    pub fn bits(self) -> u8 {
        match self {
            Self::Bits32 => 32,
            Self::Bits64 => 64,
        }
    }
}

impl Table {
    pub fn integer_width(&self) -> IntegerWidth {
        let revision = if self.signature == "DSDT" {
            self.revision
        } else {
            2
        };
        if revision < 2 {
            IntegerWidth::Bits32
        } else {
            IntegerWidth::Bits64
        }
    }
}

pub enum Declaration {
    Name(NamedValue),
    Mutex {
        offset: usize,
        name: AbsolutePath,
        level: u8,
    },
    Event {
        offset: usize,
        name: AbsolutePath,
    },
    Method(Method),
    Field(Expression),
    Region(Region),
    RegionFields(RegionFields),
    Executable(Vec<Statement>),
    Scope {
        offset: usize,
        name: AbsolutePath,
    },
    Container {
        offset: usize,
        name: AbsolutePath,
        kind: ContainerKind,
    },
    Noop {
        offset: usize,
    },
    Alias {
        offset: usize,
        name: AbsolutePath,
    },
    External {
        offset: usize,
        name: AbsolutePath,
        kind: u8,
        arity: u8,
        advisory: bool,
    },
}

#[derive(Clone, Copy)]
pub enum ContainerKind {
    Device,
    Processor { id: u8, block: u32, length: u8 },
    PowerResource { level: u8, order: u16 },
    ThermalZone,
}

impl ContainerKind {
    fn object_type(self) -> u8 {
        match self {
            Self::Device => 6,
            Self::PowerResource { .. } => 11,
            Self::Processor { .. } => 12,
            Self::ThermalZone => 13,
        }
    }
}

pub struct Region {
    pub offset: usize,
    pub name: AbsolutePath,
    pub space: u8,
    pub base: Expression,
    pub length: Expression,
}

pub enum FieldBacking {
    Region(AbsolutePath),
    Bank(AbsolutePath, AbsolutePath, Expression),
    Index(AbsolutePath, AbsolutePath),
}

pub struct RegionFields {
    pub offset: usize,
    pub backing: FieldBacking,
    pub units: Vec<FieldUnit>,
}

pub struct FieldUnit {
    pub name: AbsolutePath,
    pub start: u64,
    pub bits: u64,
    pub flags: u8,
}

pub struct NamedValue {
    pub offset: usize,
    pub name: AbsolutePath,
    pub initializer: Literal,
}

pub enum Literal {
    Integer(IntegerLiteral),
    String(Vec<u8>),
    Aggregate(Expression),
    Pending,
}

#[derive(Clone, Copy)]
pub enum IntegerLiteral {
    Zero,
    One,
    Ones,
    Immediate(u64),
}

impl IntegerLiteral {
    pub fn value(self, width: IntegerWidth) -> u64 {
        let value = match self {
            Self::Zero => 0,
            Self::One => 1,
            Self::Ones => u64::MAX,
            Self::Immediate(value) => value,
        };
        match width {
            IntegerWidth::Bits32 => u64::from(value as u32),
            IntegerWidth::Bits64 => value,
        }
    }
}

pub struct Method {
    pub offset: usize,
    pub name: AbsolutePath,
    pub flags: u8,
    pub body: Vec<Statement>,
}

impl Method {
    pub fn arg_count(&self) -> u8 {
        self.flags & 0x07
    }
}

pub struct Statement {
    pub offset: usize,
    pub kind: StatementKind,
}

pub enum StatementKind {
    Name(AbsolutePath, Expression),
    Region(Region),
    RegionFields(RegionFields),
    If {
        predicate: Expression,
        body: Vec<Statement>,
        otherwise: Option<ElseBlock>,
    },
    While(Expression, Vec<Statement>),
    Break,
    Continue,
    Noop,
    Return(Expression),
    Evaluate(Expression),
    Delay {
        sleep: bool,
        duration: Expression,
    },
    Notify(AbsolutePath, Expression),
    Release(AbsolutePath),
    Unload(Expression),
    EventControl {
        target: AbsolutePath,
        signal: bool,
    },
}

pub struct ElseBlock {
    pub offset: usize,
    pub body: Vec<Statement>,
}

#[derive(Debug)]
pub enum Operator {
    Timer,
    LoadTable,
    Load,
    Wait(AbsolutePath),
    Acquire(AbsolutePath, u16),
    Store,
    CopyObject,
    RefOf,
    DerefOf,
    Index,
    Mid,
    Convert(u8),
    SizeOf,
    ObjectType,
    NamespaceType(AbsolutePath, u8),
    Add,
    Concatenate,
    Subtract,
    Increment,
    Decrement,
    Multiply,
    Divide,
    Mod,
    ShiftLeft,
    ShiftRight,
    And,
    Nand,
    Or,
    Nor,
    Xor,
    Not,
    FindSetLeftBit,
    FindSetRightBit,
    LAnd,
    LOr,
    LNot,
    LEqual,
    LGreater,
    LLess,
}

pub enum Expression {
    Integer(IntegerLiteral),
    String(Vec<u8>),
    Local(u8),
    Arg(u8),
    NullTarget,
    DebugTarget,
    Buffer(Box<Expression>, Vec<u8>),
    Package(Box<Expression>, Vec<Expression>),
    Field(AbsolutePath),
    CreateField {
        name: AbsolutePath,
        buffer: Box<Expression>,
        index: Box<Expression>,
        length: Box<Expression>,
        mode: u8,
    },
    Name(AbsolutePath),
    RegionSource(AbsolutePath),
    Call(AbsolutePath, Vec<Expression>),
    UnresolvedCall(AbsolutePath, Vec<Expression>),
    CondRefOf {
        source: Option<Box<Expression>>,
        target: Box<Expression>,
    },
    NamespaceObject(AbsolutePath, u8),
    Apply(Operator, Vec<Expression>),
}

#[derive(Clone)]
enum Symbol {
    Integer,
    String,
    Buffer,
    Package,
    Field,
    Method(u8),
    ExternalMethod(u8),
    Other,
    Event,
    Mutex,
    Region,
    FieldUnit,
    Container(ContainerKind),
    PendingAlias(usize),
    Redirect(AbsolutePath),
}

#[derive(Clone, Debug, Default, Eq, Hash, PartialEq)]
pub struct AbsolutePath(Vec<String>);

impl AbsolutePath {
    pub fn predefined_os() -> Self {
        Self(vec!["_OS_".into()])
    }

    pub fn is_osi(&self) -> bool {
        self.0 == ["_OSI"]
    }

    pub fn parent(&self) -> Option<Self> {
        self.0.split_last().map(|(_, prefix)| Self(prefix.to_vec()))
    }

    pub fn llvm_suffix(&self) -> String {
        // A dot separates segments and cannot appear in a NameSeg.
        self.0.join(".")
    }
}

impl fmt::Display for AbsolutePath {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("\\")?;
        format_segments(f, &self.0)
    }
}

fn format_segments(f: &mut fmt::Formatter<'_>, segments: &[String]) -> fmt::Result {
    for (index, segment) in segments.iter().enumerate() {
        if index != 0 {
            f.write_str(".")?;
        }
        f.write_str(segment)?;
    }
    Ok(())
}

enum Prefix {
    Root,
    Parent(usize),
}

struct NameString {
    prefix: Prefix,
    segments: Vec<String>,
    search_parents: bool,
}

impl NameString {
    fn absolute(&self, scope: &AbsolutePath, offset: usize) -> Result<AbsolutePath, ParseError> {
        let base = match self.prefix {
            Prefix::Root => &[][..],
            Prefix::Parent(count) => {
                let len = scope.0.len().checked_sub(count).ok_or_else(|| ParseError {
                    offset,
                    message: format!("name {self} goes above the namespace root"),
                })?;
                &scope.0[..len]
            }
        };
        let mut segments = base.to_vec();
        segments.extend_from_slice(&self.segments);
        Ok(AbsolutePath(segments))
    }
}

impl fmt::Display for NameString {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self.prefix {
            Prefix::Root => f.write_str("\\")?,
            Prefix::Parent(count) => {
                for _ in 0..count {
                    f.write_str("^")?;
                }
            }
        }
        format_segments(f, &self.segments)
    }
}

type Namespace = HashMap<AbsolutePath, Symbol>;

struct MethodScope<'a> {
    namespace: &'a Namespace,
    path: &'a AbsolutePath,
    local_objects: RefCell<Namespace>,
}

impl MethodScope<'_> {
    fn resolve(&self, cursor: &mut Cursor<'_>) -> Result<(AbsolutePath, Symbol), ParseError> {
        let offset = cursor.offset;
        let name = cursor.name_string()?;
        self.lookup(&name, offset)?
            .ok_or_else(|| unknown_name(&name, offset, self.path))
    }

    fn lookup(
        &self,
        name: &NameString,
        offset: usize,
    ) -> Result<Option<(AbsolutePath, Symbol)>, ParseError> {
        if let Some(binding) = find_name(name, offset, &self.local_objects.borrow(), self.path)? {
            return Ok(Some(binding));
        }
        Ok(
            find_name(name, offset, self.namespace, self.path)?.map(
                |(path, symbol)| match symbol {
                    Symbol::Redirect(target) => (path, self.namespace[&target].clone()),
                    _ => (path, symbol),
                },
            ),
        )
    }
}

#[derive(Clone)]
struct Cursor<'a> {
    bytes: &'a [u8],
    offset: usize,
}

impl<'a> Cursor<'a> {
    fn error(&self, message: impl Into<String>) -> ParseError {
        ParseError {
            offset: self.offset,
            message: message.into(),
        }
    }

    fn take(&mut self, length: usize) -> Result<&'a [u8], ParseError> {
        let bytes = self
            .bytes
            .get(..length)
            .ok_or_else(|| self.error(format!("expected {length} byte(s) in this package")))?;
        self.bytes = &self.bytes[length..];
        self.offset += length;
        Ok(bytes)
    }

    fn peek(&self) -> Result<u8, ParseError> {
        self.bytes
            .first()
            .copied()
            .ok_or_else(|| self.error("unexpected end of package"))
    }

    fn byte(&mut self) -> Result<u8, ParseError> {
        Ok(self.take(1)?[0])
    }

    fn package(&mut self) -> Result<Cursor<'a>, ParseError> {
        let invalid_length = self.error("invalid package length");
        let before = self.offset;
        let length = self.package_length()?;
        let payload = length
            .checked_sub(self.offset - before)
            .ok_or(invalid_length)?;
        Ok(Cursor {
            offset: self.offset,
            bytes: self.take(payload)?,
        })
    }

    fn package_length(&mut self) -> Result<usize, ParseError> {
        let invalid_length = self.error("invalid package length");
        let lead = self.byte()?;
        let extra = lead >> 6;
        let mut length = usize::from(lead & 0x3f);
        if extra != 0 {
            if lead & 0x30 != 0 {
                return Err(invalid_length);
            }
            length = usize::from(lead & 0x0f);
            for index in 0..extra {
                length |= usize::from(self.byte()?) << (4 + index * 8);
            }
        }
        Ok(length)
    }

    fn name_string(&mut self) -> Result<NameString, ParseError> {
        let prefix = if self.peek()? == b'\\' {
            self.byte()?;
            Prefix::Root
        } else {
            let mut count = 0;
            while self.peek()? == b'^' {
                self.byte()?;
                count += 1;
            }
            Prefix::Parent(count)
        };
        let lead = self.peek()?;
        let count = match lead {
            0 => {
                self.byte()?;
                0
            }
            0x2e => {
                self.byte()?;
                2
            }
            0x2f => {
                self.byte()?;
                let count = self.byte()?;
                if count == 0 {
                    return Err(self.error("MultiNamePath must contain at least one NameSeg"));
                }
                count
            }
            _ => 1,
        };
        let search_parents = matches!(prefix, Prefix::Parent(0)) && is_name_lead(lead);
        let segments = (0..count)
            .map(|_| self.name_segment())
            .collect::<Result<_, _>>()?;
        Ok(NameString {
            prefix,
            segments,
            search_parents,
        })
    }

    fn name_segment(&mut self) -> Result<String, ParseError> {
        let invalid_name = self.error("invalid NameSeg");
        let segment = self.take(4)?;
        if !is_name_lead(segment[0])
            || !segment[1..]
                .iter()
                .all(|&byte| is_name_lead(byte) || byte.is_ascii_digit())
        {
            return Err(invalid_name);
        }
        Ok(String::from_utf8(segment.to_vec()).expect("validated ASCII NameSeg"))
    }

    fn unsupported_opcode(&mut self) -> ParseError {
        let offset = self.offset;
        let opcode = match self.byte() {
            Ok(0x5b) => match self.byte() {
                Ok(second) => 0x5b00 | u16::from(second),
                Err(err) => return err,
            },
            Ok(byte) => u16::from(byte),
            Err(err) => return err,
        };
        ParseError {
            offset,
            message: format!("unsupported opcode {opcode:#04x}"),
        }
    }
}

fn is_name_lead(byte: u8) -> bool {
    byte.is_ascii_uppercase() || byte == b'_'
}

fn starts_name(opcode: u8) -> bool {
    is_name_lead(opcode) || matches!(opcode, b'\\' | b'^' | 0x2e | 0x2f)
}

fn resolve_name(
    cursor: &mut Cursor<'_>,
    namespace: &Namespace,
    scope: &AbsolutePath,
) -> Result<(AbsolutePath, Symbol), ParseError> {
    let offset = cursor.offset;
    let name = cursor.name_string()?;
    let (path, symbol) = lookup_name(&name, offset, namespace, scope)?;
    Ok(match symbol {
        Symbol::Redirect(target) => (target.clone(), namespace[&target].clone()),
        _ => (path, symbol),
    })
}

fn lookup_name(
    name: &NameString,
    offset: usize,
    namespace: &Namespace,
    scope: &AbsolutePath,
) -> Result<(AbsolutePath, Symbol), ParseError> {
    find_name(name, offset, namespace, scope)?.ok_or_else(|| unknown_name(name, offset, scope))
}

fn unknown_name(name: &NameString, offset: usize, scope: &AbsolutePath) -> ParseError {
    ParseError {
        offset,
        message: format!("unknown name {name} from {scope}"),
    }
}

fn find_name(
    name: &NameString,
    offset: usize,
    namespace: &Namespace,
    scope: &AbsolutePath,
) -> Result<Option<(AbsolutePath, Symbol)>, ParseError> {
    find_name_matching(name, offset, namespace, scope, |symbol| {
        !matches!(symbol, Symbol::ExternalMethod(_))
    })
}

fn find_name_matching(
    name: &NameString,
    offset: usize,
    namespace: &Namespace,
    scope: &AbsolutePath,
    matches: impl Fn(&Symbol) -> bool,
) -> Result<Option<(AbsolutePath, Symbol)>, ParseError> {
    if name.segments.is_empty() && matches!(name.prefix, Prefix::Parent(0)) {
        return Err(ParseError {
            offset,
            message: "bare NullName does not name a namespace object".into(),
        });
    }
    let mut path = name.absolute(scope, offset)?;
    loop {
        if let Some(symbol) = namespace.get(&path).filter(|symbol| matches(symbol)) {
            return Ok(Some((path, symbol.clone())));
        }
        if !name.search_parents || path.0.len() <= 1 {
            break;
        }
        // Keep the last segment and try it at the next enclosing scope.
        path.0.remove(path.0.len() - 2);
    }
    Ok(None)
}

fn table_header(bytes: &[u8]) -> Result<(&'static str, u8), ParseError> {
    let header = Cursor { bytes, offset: 0 }.take(HEADER_LEN)?;
    let signature = match &header[..4] {
        b"DSDT" => "DSDT",
        b"SSDT" => "SSDT",
        _ => {
            return Err(ParseError {
                offset: 0,
                message: "expected a DSDT or SSDT header".into(),
            });
        }
    };
    let length = u32::from_le_bytes(header[4..8].try_into().unwrap()) as usize;
    if length != bytes.len() {
        return Err(ParseError {
            offset: 4,
            message: format!(
                "table length is {length} bytes, file contains {}",
                bytes.len()
            ),
        });
    }
    if bytes.iter().copied().fold(0u8, u8::wrapping_add) != 0 {
        return Err(ParseError {
            offset: 9,
            message: "invalid table checksum".into(),
        });
    }
    Ok((signature, header[8]))
}

#[cfg(test)]
pub fn parse_table(bytes: &[u8]) -> Result<Table, String> {
    Ok(parse_tables(&[("input", bytes)])?.remove(0))
}

struct Alias {
    table: usize,
    offset: usize,
    scope: AbsolutePath,
    source: NameString,
    name: AbsolutePath,
}

fn bind_alias(
    index: usize,
    aliases: &[Alias],
    namespace: &mut Namespace,
    depth: usize,
) -> Result<AbsolutePath, (usize, ParseError)> {
    let alias = &aliases[index];
    if let Symbol::Redirect(target) = &namespace[&alias.name] {
        return Ok(target.clone());
    }
    if depth == MAX_DEPTH {
        return Err((
            alias.table,
            ParseError {
                offset: alias.offset,
                message: format!("cyclic or excessively deep Alias {}", alias.name),
            },
        ));
    }
    let (path, symbol) = lookup_name(&alias.source, alias.offset, namespace, &alias.scope)
        .map_err(|error| (alias.table, error))?;
    let target = match symbol {
        Symbol::PendingAlias(next) => bind_alias(next, aliases, namespace, depth + 1)?,
        Symbol::Redirect(target) => target,
        _ => path,
    };
    namespace.insert(alias.name.clone(), Symbol::Redirect(target.clone()));
    Ok(target)
}

pub fn parse_tables(inputs: &[(&str, &[u8])]) -> Result<Vec<Table>, String> {
    let root = AbsolutePath::default();
    let mut namespace = Namespace::from([(root.clone(), Symbol::Other)]);
    // Predefined namespace objects exist before the table is loaded.
    for segment in ["_GPE", "_PR_", "_SB_", "_SI_", "_TZ_", "_GL_", "_REV"] {
        namespace.insert(AbsolutePath(vec![segment.into()]), Symbol::Other);
    }
    namespace.insert(AbsolutePath(vec!["_OSI".into()]), Symbol::Method(1));
    namespace.insert(AbsolutePath::predefined_os(), Symbol::String);

    let mut tables = Vec::new();
    let mut bodies = Vec::new();
    let mut aliases = Vec::new();
    for (index, &(label, bytes)) in inputs.iter().enumerate() {
        let (signature, revision) = table_header(bytes).map_err(|err| format!("{label}: {err}"))?;
        if (index == 0 && inputs.len() > 1 && signature != "DSDT")
            || (index > 0 && signature != "SSDT")
        {
            return Err(format!("{label}: expected a DSDT followed by SSDTs"));
        }
        let mut cursor = Cursor {
            bytes: &bytes[HEADER_LEN..],
            offset: HEADER_LEN,
        };
        let mut loader = TableLoader {
            namespace: &mut namespace,
            declarations: Vec::new(),
            method_bodies: Vec::new(),
            executable_blocks: Vec::new(),
            initializers: Vec::new(),
            aliases: &mut aliases,
            table: index,
        };
        loader
            .parse_declarations(&mut cursor, &root, 0)
            .map_err(|err| format!("{label}: {err}"))?;
        tables.push(Table {
            signature,
            length: bytes.len(),
            revision,
            bytes: bytes.to_vec(),
            aliases: Vec::new(),
            declarations: loader.declarations,
        });
        bodies.push((
            loader.method_bodies,
            loader.initializers,
            loader.executable_blocks,
        ));
    }
    for index in 0..aliases.len() {
        bind_alias(index, &aliases, &mut namespace, 0)
            .map_err(|(table, err)| format!("{}: {err}", inputs[table].0))?;
    }
    for alias in &aliases {
        let (target, _) = lookup_name(&alias.source, alias.offset, &namespace, &alias.scope)
            .map_err(|err| format!("{}: {err}", inputs[alias.table].0))?;
        tables[alias.table]
            .aliases
            .push((alias.name.clone(), target));
    }
    for (index, table) in tables.iter().enumerate() {
        for declaration in &table.declarations {
            if let Declaration::External {
                offset,
                name,
                kind: 8,
                arity,
                ..
            } = declaration
            {
                let symbol = namespace
                    .entry(name.clone())
                    .or_insert(Symbol::ExternalMethod(*arity));
                if let Symbol::ExternalMethod(previous) = symbol
                    && *previous != *arity
                {
                    let label = inputs[index].0;
                    return Err(format!(
                        "{label}: at file offset {offset:#06x}: conflicting External method arities for {name}"
                    ));
                }
            }
        }
    }
    for (table_index, (table, (method_bodies, initializers, executable_blocks))) in
        tables.iter_mut().zip(bodies).enumerate()
    {
        let label = inputs[table_index].0;
        for declaration in &table.declarations {
            if let Declaration::External {
                offset,
                name,
                kind,
                arity,
                advisory: false,
            } = declaration
            {
                let symbol = match namespace.get(name) {
                    Some(Symbol::Redirect(target)) => namespace.get(target),
                    symbol => symbol,
                };
                let matches = match (kind, symbol) {
                    (0, Some(_)) | (1, Some(Symbol::Integer)) => true,
                    (kind, Some(Symbol::Container(container))) => *kind == container.object_type(),
                    (7, Some(Symbol::Event))
                    | (9, Some(Symbol::Mutex))
                    | (2, Some(Symbol::String))
                    | (3, Some(Symbol::Buffer))
                    | (4, Some(Symbol::Package))
                    | (10, Some(Symbol::Region))
                    | (5, Some(Symbol::FieldUnit))
                    | (14, Some(Symbol::Field)) => true,
                    (8, Some(Symbol::Method(count))) => count == arity,
                    (8, Some(Symbol::ExternalMethod(count))) => count == arity,
                    _ => false,
                };
                if !matches {
                    return Err(format!(
                        "{label}: {}",
                        ParseError {
                            offset: *offset,
                            message: if symbol.is_none() {
                                format!("unresolved External {name}")
                            } else {
                                format!("type or arity mismatch for External {name}")
                            },
                        }
                    ));
                }
            }
        }
        for (index, path, mut cursor) in initializers {
            let Declaration::Name(name) = &mut table.declarations[index] else {
                unreachable!("only Name declarations have initializers");
            };
            let scope = MethodScope {
                namespace: &namespace,
                path: &path,
                local_objects: RefCell::default(),
            };
            let expression = parse_expression(&mut cursor, &scope, 0)
                .map_err(|err| format!("{label}: {err}"))?;
            name.initializer = Literal::Aggregate(expression);
        }
        for (index, mut body) in method_bodies {
            let Declaration::Method(method) = &mut table.declarations[index] else {
                unreachable!("only method declarations have bodies");
            };
            let scope = MethodScope {
                namespace: &namespace,
                path: &method.name,
                local_objects: RefCell::default(),
            };
            method.body = parse_statements(&mut body, &scope, 0, false)
                .map_err(|err| format!("{label}: {err}"))?;
        }
        for (index, path, mut block) in executable_blocks {
            let scope = MethodScope {
                namespace: &namespace,
                path: &path,
                local_objects: RefCell::default(),
            };
            table.declarations[index] = Declaration::Executable(
                parse_statements(&mut block, &scope, 0, false)
                    .map_err(|err| format!("{label}: {err}"))?,
            );
        }
    }
    Ok(tables)
}

fn declaration_name(
    cursor: &mut Cursor<'_>,
    scope: &AbsolutePath,
    namespace: &Namespace,
) -> Result<AbsolutePath, ParseError> {
    let offset = cursor.offset;
    let name = cursor.name_string()?;
    if name.segments.is_empty() {
        return Err(ParseError {
            offset,
            message: "NullName cannot declare a namespace object".into(),
        });
    }
    let path = name.absolute(scope, offset)?;
    let parent = AbsolutePath(path.0[..path.0.len() - 1].to_vec());
    if !namespace.contains_key(&parent) {
        return Err(ParseError {
            offset,
            message: format!("unknown parent {parent} for declaration {path}"),
        });
    }
    if namespace.contains_key(&path) {
        return Err(ParseError {
            offset,
            message: format!("duplicate declaration {path}"),
        });
    }
    Ok(path)
}

fn parse_external(
    cursor: &mut Cursor<'_>,
    scope: &AbsolutePath,
    advisory: bool,
) -> Result<Declaration, ParseError> {
    let offset = cursor.offset;
    if cursor.peek()? != 0x15 {
        return Err(cursor.unsupported_opcode());
    }
    cursor.byte()?;
    let external = cursor.name_string()?;
    if external.segments.is_empty() {
        return Err(cursor.error("NullName cannot declare an External"));
    }
    let name = external.absolute(scope, offset)?;
    let kind = cursor.byte()?;
    let arity = cursor.byte()?;
    if kind > 14 || (kind == 8 && arity > 7) {
        return Err(cursor.error("unsupported External type or arity"));
    }
    Ok(Declaration::External {
        offset,
        name,
        kind,
        arity,
        advisory,
    })
}

struct TableLoader<'a, 'b> {
    namespace: &'b mut Namespace,
    declarations: Vec<Declaration>,
    method_bodies: Vec<(usize, Cursor<'a>)>,
    executable_blocks: Vec<(usize, AbsolutePath, Cursor<'a>)>,
    initializers: Vec<(usize, AbsolutePath, Cursor<'a>)>,
    aliases: &'b mut Vec<Alias>,
    table: usize,
}

impl<'a> TableLoader<'a, '_> {
    fn parse_region_fields(
        &mut self,
        body: &mut Cursor<'a>,
        scope: &AbsolutePath,
        depth: usize,
        offset: usize,
        opcode: u8,
    ) -> Result<RegionFields, ParseError> {
        let mut resolve = |body: &mut Cursor<'_>, is_region| {
            let offset = body.offset;
            let namestring = body.name_string()?;
            let (name, symbol) = lookup_name(&namestring, offset, self.namespace, scope)?;
            let symbol = match symbol {
                Symbol::PendingAlias(index) => {
                    let target = bind_alias(index, self.aliases, self.namespace, 0)
                        .map_err(|(_, err)| err)?;
                    self.namespace[&target].clone()
                }
                Symbol::Redirect(target) => self.namespace[&target].clone(),
                symbol => symbol,
            };
            match (is_region, symbol) {
                (true, Symbol::Region) | (false, Symbol::FieldUnit) => Ok(name),
                _ => Err(body.error(format!("invalid field backing {name}"))),
            }
        };
        let backing = match opcode {
            0x81 => FieldBacking::Region(resolve(body, true)?),
            0x86 => FieldBacking::Index(resolve(body, false)?, resolve(body, false)?),
            0x87 => {
                let region = resolve(body, true)?;
                let selector = resolve(body, false)?;
                let terms = MethodScope {
                    namespace: self.namespace,
                    path: scope,
                    local_objects: RefCell::default(),
                };
                FieldBacking::Bank(region, selector, parse_expression(body, &terms, depth)?)
            }
            _ => unreachable!(),
        };
        let units = parse_field_units(body, |body| {
            let name = declaration_name(body, scope, self.namespace)?;
            self.namespace.insert(name.clone(), Symbol::FieldUnit);
            Ok(name)
        })?;
        Ok(RegionFields {
            offset,
            backing,
            units,
        })
    }

    fn parse_declarations(
        &mut self,
        cursor: &mut Cursor<'a>,
        scope: &AbsolutePath,
        depth: usize,
    ) -> Result<(), ParseError> {
        if depth >= MAX_DEPTH {
            return Err(cursor.error("AML namespace nesting limit exceeded"));
        }
        while !cursor.bytes.is_empty() {
            let offset = cursor.offset;
            let declaration = match cursor.peek()? {
                0xa3 => {
                    cursor.byte()?;
                    Declaration::Noop { offset }
                }
                0x06 => {
                    cursor.byte()?;
                    let source = cursor.name_string()?;
                    let name = declaration_name(cursor, scope, self.namespace)?;
                    self.namespace
                        .insert(name.clone(), Symbol::PendingAlias(self.aliases.len()));
                    self.aliases.push(Alias {
                        table: self.table,
                        offset,
                        scope: scope.clone(),
                        source,
                        name: name.clone(),
                    });
                    Declaration::Alias { offset, name }
                }
                0x15 => parse_external(cursor, scope, false)?,
                0x08 => {
                    cursor.byte()?;
                    let name = declaration_name(cursor, scope, self.namespace)?;
                    let opcode = cursor.peek()?;
                    let (initializer, symbol) = if opcode == 0x0d {
                        (Literal::String(parse_string(cursor)?), Symbol::String)
                    } else if matches!(opcode, 0x11..=0x13) {
                        self.initializers.push((
                            self.declarations.len(),
                            scope.clone(),
                            cursor.clone(),
                        ));
                        cursor.byte()?;
                        cursor.package()?;
                        (
                            Literal::Pending,
                            if opcode == 0x11 {
                                Symbol::Buffer
                            } else {
                                Symbol::Package
                            },
                        )
                    } else {
                        let integer = parse_integer(cursor, opcode)?
                            .ok_or_else(|| cursor.error("expected a data object initializer"))?;
                        (Literal::Integer(integer), Symbol::Integer)
                    };
                    self.namespace.insert(name.clone(), symbol);
                    Declaration::Name(NamedValue {
                        offset,
                        name,
                        initializer,
                    })
                }
                opcode
                    if matches!(opcode, 0x8a..=0x8d | 0x8f)
                        || cursor.bytes.starts_with(&[0x5b, 0x13]) =>
                {
                    let field_scope = MethodScope {
                        namespace: self.namespace,
                        path: scope,
                        local_objects: RefCell::default(),
                    };
                    let field = parse_expression(cursor, &field_scope, depth)?;
                    let Expression::CreateField { name, .. } = &field else {
                        unreachable!()
                    };
                    let parent = AbsolutePath(name.0[..name.0.len() - 1].to_vec());
                    if !self.namespace.contains_key(&parent) {
                        return Err(
                            cursor.error(format!("undeclared buffer field parent {parent}"))
                        );
                    }
                    self.namespace.insert(name.clone(), Symbol::Field);
                    Declaration::Field(field)
                }
                0x14 => {
                    cursor.byte()?;
                    let mut body = cursor.package()?;
                    let name = declaration_name(&mut body, scope, self.namespace)?;
                    let flags = body.byte()?;
                    self.namespace
                        .insert(name.clone(), Symbol::Method(flags & 0x07));
                    self.method_bodies.push((self.declarations.len(), body));
                    Declaration::Method(Method {
                        offset,
                        name,
                        flags,
                        body: Vec::new(),
                    })
                }
                0x5b if cursor.bytes.starts_with(&[0x5b, 0x80]) => {
                    cursor.take(2)?;
                    let name = declaration_name(cursor, scope, self.namespace)?;
                    let terms = MethodScope {
                        namespace: self.namespace,
                        path: scope,
                        local_objects: RefCell::default(),
                    };
                    let region = parse_region(cursor, &terms, depth, offset, name)?;
                    self.namespace.insert(region.name.clone(), Symbol::Region);
                    Declaration::Region(region)
                }
                0x5b if matches!(cursor.bytes, [0x5b, 0x81 | 0x86 | 0x87, ..]) => {
                    let opcode = cursor.take(2)?[1];
                    Declaration::RegionFields(self.parse_region_fields(
                        &mut cursor.package()?,
                        scope,
                        depth + 1,
                        offset,
                        opcode,
                    )?)
                }
                0x5b if cursor.bytes.starts_with(&[0x5b, 0x01]) => {
                    cursor.take(2)?;
                    let name = declaration_name(cursor, scope, self.namespace)?;
                    let level = cursor.byte()? & 0x0f;
                    self.namespace.insert(name.clone(), Symbol::Mutex);
                    Declaration::Mutex {
                        offset,
                        name,
                        level,
                    }
                }
                0x5b if cursor.bytes.starts_with(&[0x5b, 0x02]) => {
                    cursor.take(2)?;
                    let name = declaration_name(cursor, scope, self.namespace)?;
                    self.namespace.insert(name.clone(), Symbol::Event);
                    Declaration::Event { offset, name }
                }
                0xa0 => {
                    let mut block = cursor.clone();
                    cursor.byte()?;
                    let mut body = cursor.package()?;
                    if body.bytes.starts_with(&[0, 0x15]) {
                        body.byte()?;
                        while !body.bytes.is_empty() {
                            self.declarations
                                .push(parse_external(&mut body, scope, true)?);
                        }
                        continue;
                    }
                    if cursor.bytes.first() == Some(&0xa1) {
                        cursor.byte()?;
                        cursor.package()?;
                    }
                    block.bytes = &block.bytes[..cursor.offset - offset];
                    self.executable_blocks
                        .push((self.declarations.len(), scope.clone(), block));
                    Declaration::Executable(Vec::new())
                }
                opcode if opcode == 0x10 || matches!(cursor.bytes, [0x5b, 0x82..=0x85, ..]) => {
                    cursor.byte()?;
                    let container = if opcode == 0x5b {
                        Some(cursor.byte()?)
                    } else {
                        None
                    };
                    let mut body = cursor.package()?;
                    let name = if let Some(container) = container {
                        let name = declaration_name(&mut body, scope, self.namespace)?;
                        let kind = match container {
                            0x82 => ContainerKind::Device,
                            0x83 => ContainerKind::Processor {
                                id: body.byte()?,
                                block: u32::from_le_bytes(body.take(4)?.try_into().unwrap()),
                                length: body.byte()?,
                            },
                            0x84 => ContainerKind::PowerResource {
                                level: body.byte()?,
                                order: u16::from_le_bytes(body.take(2)?.try_into().unwrap()),
                            },
                            0x85 => ContainerKind::ThermalZone,
                            _ => unreachable!(),
                        };
                        self.namespace.insert(name.clone(), Symbol::Container(kind));
                        self.declarations.push(Declaration::Container {
                            kind,
                            offset,
                            name: name.clone(),
                        });
                        name
                    } else {
                        let (name, symbol) = resolve_name(&mut body, self.namespace, scope)?;
                        let name = if let Symbol::PendingAlias(index) = symbol {
                            bind_alias(index, self.aliases, self.namespace, 0)
                                .map_err(|(_, err)| err)?
                        } else {
                            name
                        };
                        self.declarations.push(Declaration::Scope {
                            offset,
                            name: name.clone(),
                        });
                        name
                    };
                    self.parse_declarations(&mut body, &name, depth + 1)?;
                    continue;
                }
                opcode if starts_name(opcode) => {
                    let terms = MethodScope {
                        namespace: self.namespace,
                        path: scope,
                        local_objects: RefCell::default(),
                    };
                    let expression = parse_expression(cursor, &terms, 0)?;
                    if !matches!(expression, Expression::Call(..)) {
                        return Err(ParseError {
                            offset,
                            message: "expected a module-level method call".into(),
                        });
                    }
                    Declaration::Executable(vec![Statement {
                        offset,
                        kind: StatementKind::Evaluate(expression),
                    }])
                }
                _ => return Err(cursor.unsupported_opcode()),
            };
            self.declarations.push(declaration);
        }
        Ok(())
    }
}

fn parse_field_units(
    body: &mut Cursor<'_>,
    mut declare: impl FnMut(&mut Cursor<'_>) -> Result<AbsolutePath, ParseError>,
) -> Result<Vec<FieldUnit>, ParseError> {
    let mut flags = body.byte()?;
    if flags & 0x80 != 0 || flags & 0x60 == 0x60 || flags & 0x0f > 5 {
        return Err(body.error("invalid field flags"));
    }
    let mut start = 0u64;
    let mut units = Vec::new();
    while !body.bytes.is_empty() {
        match body.peek()? {
            0 => {
                body.byte()?;
                let bits = body.package_length()? as u64;
                start = start
                    .checked_add(bits)
                    .ok_or_else(|| body.error("field offset overflow"))?;
            }
            1 | 3 => {
                let extended = body.byte()? == 3;
                let access = body.byte()?;
                let attribute = body.byte()?;
                let length = if extended { body.byte()? } else { 0 };
                if access > 5 || attribute != 0 || length != 0 {
                    return Err(body.error("unsupported field access attribute or length"));
                }
                flags = (flags & 0xf0) | access;
            }
            2 => return Err(body.error("unsupported field Connection")),
            _ => {
                let name = declare(body)?;
                let bits = body.package_length()? as u64;
                units.push(FieldUnit {
                    name,
                    start,
                    bits,
                    flags,
                });
                start = start
                    .checked_add(bits)
                    .ok_or_else(|| body.error("field offset overflow"))?;
            }
        }
    }
    Ok(units)
}

fn method_object_name(
    cursor: &mut Cursor<'_>,
    scope: &MethodScope<'_>,
) -> Result<AbsolutePath, ParseError> {
    let name = declaration_name(cursor, scope.path, scope.namespace)?;
    if name.parent().as_ref() != Some(scope.path)
        || !matches!(scope.namespace.get(scope.path), Some(Symbol::Method(_)))
    {
        return Err(cursor.error("object declaration must be in its method scope"));
    }
    if scope.local_objects.borrow().contains_key(&name) {
        return Err(cursor.error(format!("duplicate declaration {name}")));
    }
    Ok(name)
}

fn parse_region(
    cursor: &mut Cursor<'_>,
    scope: &MethodScope<'_>,
    depth: usize,
    offset: usize,
    name: AbsolutePath,
) -> Result<Region, ParseError> {
    Ok(Region {
        offset,
        name,
        space: cursor.byte()?,
        base: parse_expression(cursor, scope, depth + 1)?,
        length: parse_expression(cursor, scope, depth + 1)?,
    })
}

fn absent_reference_guard(expression: &Expression) -> Option<bool> {
    match expression {
        Expression::CondRefOf { source: None, .. } => Some(false),
        Expression::Apply(Operator::LNot, args) => {
            absent_reference_guard(&args[0]).map(|value| !value)
        }
        _ => None,
    }
}

fn parse_statements(
    cursor: &mut Cursor<'_>,
    scope: &MethodScope<'_>,
    depth: usize,
    in_loop: bool,
) -> Result<Vec<Statement>, ParseError> {
    if depth >= MAX_STATEMENT_DEPTH {
        return Err(cursor.error("AML nesting limit exceeded"));
    }
    let mut statements = Vec::new();
    while !cursor.bytes.is_empty() {
        let offset = cursor.offset;
        let opcode = cursor.peek()?;
        let kind = match opcode {
            0x08 => {
                cursor.byte()?;
                let name = method_object_name(cursor, scope)?;
                let opcode = cursor.peek()?;
                let symbol = match opcode {
                    0x0d => Symbol::String,
                    0x11 => Symbol::Buffer,
                    0x12 | 0x13 => Symbol::Package,
                    0x00 | 0x01 | 0x0a..=0x0c | 0x0e | 0xff => Symbol::Integer,
                    _ => return Err(cursor.error("expected a data object initializer")),
                };
                let initializer = parse_expression(cursor, scope, 0)?;
                scope
                    .local_objects
                    .borrow_mut()
                    .insert(name.clone(), symbol);
                StatementKind::Name(name, initializer)
            }
            0x5b if cursor.bytes.starts_with(&[0x5b, 0x80]) => {
                cursor.take(2)?;
                let name = method_object_name(cursor, scope)?;
                let region = parse_region(cursor, scope, 0, offset, name)?;
                scope
                    .local_objects
                    .borrow_mut()
                    .insert(region.name.clone(), Symbol::Region);
                StatementKind::Region(region)
            }
            0x5b if matches!(cursor.bytes, [0x5b, 0x81 | 0x86 | 0x87, ..]) => {
                let opcode = cursor.take(2)?[1];
                let mut body = cursor.package()?;
                let resolve = |body: &mut Cursor<'_>, is_region| {
                    let (name, symbol) = scope.resolve(body)?;
                    match (is_region, symbol) {
                        (true, Symbol::Region) | (false, Symbol::FieldUnit) => Ok(name),
                        _ => Err(body.error(format!("invalid field backing {name}"))),
                    }
                };
                let backing = match opcode {
                    0x81 => FieldBacking::Region(resolve(&mut body, true)?),
                    0x86 => {
                        FieldBacking::Index(resolve(&mut body, false)?, resolve(&mut body, false)?)
                    }
                    _ => FieldBacking::Bank(
                        resolve(&mut body, true)?,
                        resolve(&mut body, false)?,
                        parse_expression(&mut body, scope, 0)?,
                    ),
                };
                let units = parse_field_units(&mut body, |body| {
                    let name = method_object_name(body, scope)?;
                    scope
                        .local_objects
                        .borrow_mut()
                        .insert(name.clone(), Symbol::FieldUnit);
                    Ok(name)
                })?;
                StatementKind::RegionFields(RegionFields {
                    offset,
                    backing,
                    units,
                })
            }
            0xa0 | 0xa2 => {
                cursor.byte()?;
                let mut package = cursor.package()?;
                let predicate = parse_expression(&mut package, scope, 0)?;
                // A missing name has no callable signature. The package
                // boundary lets us skip a branch that cannot be reached.
                let guard = absent_reference_guard(&predicate);
                let predicate = match guard {
                    Some(false) => Expression::Integer(IntegerLiteral::Zero),
                    Some(true) => Expression::Integer(IntegerLiteral::One),
                    None => predicate,
                };
                let body = if guard == Some(false) {
                    Vec::new()
                } else {
                    parse_statements(&mut package, scope, depth + 1, in_loop || opcode == 0xa2)?
                };
                if opcode == 0xa0 {
                    let otherwise = if cursor.bytes.first() == Some(&0xa1) {
                        let offset = cursor.offset;
                        cursor.byte()?;
                        let mut package = cursor.package()?;
                        let body = if guard == Some(true) {
                            Vec::new()
                        } else {
                            parse_statements(&mut package, scope, depth + 1, in_loop)?
                        };
                        Some(ElseBlock { offset, body })
                    } else {
                        None
                    };
                    StatementKind::If {
                        predicate,
                        body,
                        otherwise,
                    }
                } else {
                    StatementKind::While(predicate, body)
                }
            }
            0xa1 => return Err(cursor.error("Else must follow an If in the same package")),
            0xa3 => {
                cursor.byte()?;
                StatementKind::Noop
            }
            0xa4 => {
                cursor.byte()?;
                StatementKind::Return(parse_expression(cursor, scope, 0)?)
            }
            0x5b if matches!(cursor.bytes, [0x5b, 0x21 | 0x22, ..]) => {
                let sleep = cursor.take(2)?[1] == 0x22;
                StatementKind::Delay {
                    sleep,
                    duration: parse_expression(cursor, scope, 0)?,
                }
            }
            0x5b if matches!(cursor.bytes, [0x5b, 0x24 | 0x26, ..]) => {
                let signal = cursor.take(2)?[1] == 0x24;
                let target = resolve_sync_object(cursor, scope, true)?;
                StatementKind::EventControl { target, signal }
            }
            0x5b if cursor.bytes.starts_with(&[0x5b, 0x27]) => {
                cursor.take(2)?;
                StatementKind::Release(resolve_sync_object(cursor, scope, false)?)
            }
            0x5b if cursor.bytes.starts_with(&[0x5b, 0x2a]) => {
                cursor.take(2)?;
                StatementKind::Unload(parse_target(cursor, scope, 0, false)?)
            }
            0x86 => {
                cursor.byte()?;
                let (target, symbol) = scope.resolve(cursor)?;
                if !matches!(
                    symbol,
                    Symbol::Container(
                        ContainerKind::Device
                            | ContainerKind::Processor { .. }
                            | ContainerKind::ThermalZone
                    )
                ) {
                    return Err(ParseError {
                        offset,
                        message: format!("invalid Notify target {target}"),
                    });
                }
                StatementKind::Notify(target, parse_expression(cursor, scope, 0)?)
            }
            0x9f | 0xa5 => {
                let (mnemonic, kind) = if opcode == 0x9f {
                    ("Continue", StatementKind::Continue)
                } else {
                    ("Break", StatementKind::Break)
                };
                if !in_loop {
                    return Err(cursor.error(format!("{mnemonic} must be inside a While")));
                }
                cursor.byte()?;
                kind
            }
            _ => {
                let invalid_statement = cursor.error("expected a statement");
                let expression = parse_expression(cursor, scope, 0)?;
                match expression {
                    Expression::Call(..)
                    | Expression::UnresolvedCall(..)
                    | Expression::Apply(..)
                    | Expression::CondRefOf { .. }
                    | Expression::CreateField { .. } => StatementKind::Evaluate(expression),
                    _ => return Err(invalid_statement),
                }
            }
        };
        statements.push(Statement { offset, kind });
    }
    Ok(statements)
}

fn resolve_sync_object(
    cursor: &mut Cursor<'_>,
    scope: &MethodScope<'_>,
    event: bool,
) -> Result<AbsolutePath, ParseError> {
    let offset = cursor.offset;
    let (name, symbol) = scope.resolve(cursor)?;
    if matches!(
        (event, symbol),
        (true, Symbol::Event) | (false, Symbol::Mutex)
    ) {
        Ok(name)
    } else {
        let expected = if event { "Event" } else { "Mutex" };
        Err(ParseError {
            offset,
            message: format!("{name} is not a {expected}"),
        })
    }
}

fn parse_expression(
    cursor: &mut Cursor<'_>,
    scope: &MethodScope<'_>,
    depth: usize,
) -> Result<Expression, ParseError> {
    if depth >= MAX_DEPTH {
        return Err(cursor.error("AML nesting limit exceeded"));
    }
    let opcode = cursor.peek()?;
    if starts_name(opcode) {
        let invalid_value = cursor.offset;
        let encoded = cursor.name_string()?;
        let (name, symbol) = match scope.lookup(&encoded, invalid_value)? {
            Some(binding) => binding,
            None => find_name_matching(
                &encoded,
                invalid_value,
                scope.namespace,
                scope.path,
                |symbol| matches!(symbol, Symbol::ExternalMethod(_)),
            )?
            .ok_or_else(|| unknown_name(&encoded, invalid_value, scope.path))?,
        };
        let count = match symbol {
            Symbol::Integer | Symbol::String | Symbol::Buffer | Symbol::Package => {
                return Ok(Expression::Name(name));
            }
            Symbol::Field | Symbol::FieldUnit => return Ok(Expression::Field(name)),
            Symbol::Method(count) | Symbol::ExternalMethod(count) => count,
            _ => {
                return Err(ParseError {
                    offset: invalid_value,
                    message: format!("{name} is not a supported value or method"),
                });
            }
        };
        let mut args = Vec::with_capacity(usize::from(count));
        for _ in 0..count {
            args.push(parse_expression(cursor, scope, depth + 1)?);
        }
        return Ok(if matches!(symbol, Symbol::ExternalMethod(_)) {
            Expression::UnresolvedCall(name, args)
        } else {
            Expression::Call(name, args)
        });
    }

    match opcode {
        0x11..=0x13 => {
            cursor.byte()?;
            let mut body = cursor.package()?;
            let size = if opcode == 0x12 {
                Expression::Integer(IntegerLiteral::Immediate(u64::from(body.byte()?)))
            } else {
                parse_expression(&mut body, scope, depth + 1)?
            };
            if opcode == 0x11 {
                return Ok(Expression::Buffer(Box::new(size), body.bytes.to_vec()));
            }
            let mut elements = Vec::new();
            while !body.bytes.is_empty() {
                if starts_name(body.peek()?) {
                    // Package NameStrings are path values, including forward
                    // or unresolved paths and names that would be calls elsewhere.
                    let name = body.name_string()?;
                    elements.push(Expression::String(name.to_string().into_bytes()));
                } else {
                    elements.push(parse_expression(&mut body, scope, depth + 1)?);
                }
            }
            return Ok(Expression::Package(Box::new(size), elements));
        }
        0x8e => {
            let mut lookahead = cursor.clone();
            lookahead.byte()?;
            if starts_name(lookahead.peek()?) {
                let (name, symbol) = scope.resolve(&mut lookahead)?;
                let object_type = match symbol {
                    Symbol::Container(kind) => Some(kind.object_type()),
                    Symbol::Event => Some(7),
                    Symbol::Method(_) => Some(8),
                    Symbol::Mutex => Some(9),
                    Symbol::Region => Some(10),
                    _ => None,
                };
                if let Some(object_type) = object_type {
                    *cursor = lookahead;
                    return Ok(Expression::Apply(
                        Operator::NamespaceType(name, object_type),
                        Vec::new(),
                    ));
                }
            }
        }
        0x8a..=0x8d | 0x8f => {
            cursor.byte()?;
            let bits = match opcode {
                0x8a => 32,
                0x8b => 16,
                0x8c => 8,
                0x8d => 1,
                _ => 64,
            };
            return parse_field(cursor, scope, depth, Some(bits));
        }
        0x5b if cursor.bytes.starts_with(&[0x5b, 0x1f]) => {
            cursor.take(2)?;
            let args = (0..6)
                .map(|_| parse_expression(cursor, scope, depth + 1))
                .collect::<Result<_, _>>()?;
            return Ok(Expression::Apply(Operator::LoadTable, args));
        }
        0x5b if cursor.bytes.starts_with(&[0x5b, 0x12]) => {
            cursor.take(2)?;
            let source = if starts_name(cursor.peek()?) {
                let offset = cursor.offset;
                let name = cursor.name_string()?;
                scope
                    .lookup(&name, offset)?
                    .map(|(path, symbol)| match symbol {
                        Symbol::Integer | Symbol::String | Symbol::Buffer | Symbol::Package => {
                            Expression::Name(path)
                        }
                        Symbol::Field | Symbol::FieldUnit => Expression::Field(path),
                        Symbol::Region if scope.local_objects.borrow().contains_key(&path) => {
                            Expression::RegionSource(path)
                        }
                        symbol => {
                            let kind = match symbol {
                                Symbol::Container(kind) => kind.object_type(),
                                Symbol::Event => 7,
                                Symbol::Method(_) => 8,
                                Symbol::Mutex => 9,
                                Symbol::Region => 10,
                                Symbol::Other if path.0 == ["_REV"] => 1,
                                Symbol::Other if path.0 == ["_GL_"] => 9,
                                _ => 0,
                            };
                            Expression::NamespaceObject(path, kind)
                        }
                    })
            } else {
                Some(parse_target(cursor, scope, depth + 1, false)?)
            };
            return Ok(Expression::CondRefOf {
                source: source.map(Box::new),
                target: Box::new(parse_target(cursor, scope, depth + 1, true)?),
            });
        }
        0x5b if cursor.bytes.starts_with(&[0x5b, 0x20]) => {
            cursor.take(2)?;
            let mut lookahead = cursor.clone();
            let source = if starts_name(lookahead.peek()?)
                && let Ok((name, Symbol::Region)) = scope.resolve(&mut lookahead)
            {
                *cursor = lookahead;
                Expression::RegionSource(name)
            } else {
                parse_target(cursor, scope, depth + 1, false)?
            };
            let target = parse_target(cursor, scope, depth + 1, true)?;
            return Ok(Expression::Apply(Operator::Load, vec![source, target]));
        }
        0x5b if cursor.bytes.starts_with(&[0x5b, 0x23]) => {
            cursor.take(2)?;
            let target = resolve_sync_object(cursor, scope, false)?;
            let timeout = u16::from_le_bytes(cursor.take(2)?.try_into().unwrap());
            return Ok(Expression::Apply(
                Operator::Acquire(target, timeout),
                Vec::new(),
            ));
        }
        0x5b if cursor.bytes.starts_with(&[0x5b, 0x25]) => {
            cursor.take(2)?;
            let target = resolve_sync_object(cursor, scope, true)?;
            let timeout = parse_expression(cursor, scope, depth + 1)?;
            return Ok(Expression::Apply(Operator::Wait(target), vec![timeout]));
        }
        0x5b if cursor.bytes.starts_with(&[0x5b, 0x33]) => {
            cursor.take(2)?;
            return Ok(Expression::Apply(Operator::Timer, Vec::new()));
        }
        0x5b if cursor.bytes.starts_with(&[0x5b, 0x13]) => {
            cursor.take(2)?;
            return parse_field(cursor, scope, depth, None);
        }
        _ => {}
    }
    use Operand::{Slot, Target, Value};
    let (operator, operands): (Operator, &[Operand]) = match opcode {
        0x70 => (Operator::Store, &[Value, Slot]),
        0x71 => (Operator::RefOf, &[Slot]),
        0x72 => (Operator::Add, &[Value, Value, Target]),
        0x73 => (Operator::Concatenate, &[Value, Value, Target]),
        0x74 => (Operator::Subtract, &[Value, Value, Target]),
        0x75 => (Operator::Increment, &[Slot]),
        0x76 => (Operator::Decrement, &[Slot]),
        0x77 => (Operator::Multiply, &[Value, Value, Target]),
        0x78 => (Operator::Divide, &[Value, Value, Target, Target]),
        0x79 => (Operator::ShiftLeft, &[Value, Value, Target]),
        0x7a => (Operator::ShiftRight, &[Value, Value, Target]),
        0x7b => (Operator::And, &[Value, Value, Target]),
        0x7c => (Operator::Nand, &[Value, Value, Target]),
        0x7d => (Operator::Or, &[Value, Value, Target]),
        0x7e => (Operator::Nor, &[Value, Value, Target]),
        0x7f => (Operator::Xor, &[Value, Value, Target]),
        0x80 => (Operator::Not, &[Value, Target]),
        0x81 => (Operator::FindSetLeftBit, &[Value, Target]),
        0x82 => (Operator::FindSetRightBit, &[Value, Target]),
        0x83 => (Operator::DerefOf, &[Value]),
        0x85 => (Operator::Mod, &[Value, Value, Target]),
        0x87 => (Operator::SizeOf, &[Slot]),
        0x88 => (Operator::Index, &[Value, Value, Target]),
        0x8e => (Operator::ObjectType, &[Value]),
        0x90 => (Operator::LAnd, &[Value, Value]),
        0x91 => (Operator::LOr, &[Value, Value]),
        0x92 => (Operator::LNot, &[Value]),
        0x93 => (Operator::LEqual, &[Value, Value]),
        0x94 => (Operator::LGreater, &[Value, Value]),
        0x95 => (Operator::LLess, &[Value, Value]),
        0x96..=0x99 => (Operator::Convert(opcode), &[Value, Target]),
        0x9c => (Operator::Convert(opcode), &[Value, Value, Target]),
        0x9d => (Operator::CopyObject, &[Value, Slot]),
        0x9e => (Operator::Mid, &[Value, Value, Value, Target]),
        _ => return parse_atom(cursor, opcode),
    };
    cursor.byte()?;
    let mut values = Vec::with_capacity(operands.len());
    for operand in operands {
        values.push(match operand {
            Value => parse_expression(cursor, scope, depth + 1)?,
            Slot => parse_target(cursor, scope, depth + 1, false)?,
            Target => parse_target(cursor, scope, depth + 1, true)?,
        });
    }
    Ok(Expression::Apply(operator, values))
}

enum Operand {
    Value,
    Slot,
    Target,
}

fn parse_target(
    cursor: &mut Cursor<'_>,
    scope: &MethodScope<'_>,
    depth: usize,
    allow_null: bool,
) -> Result<Expression, ParseError> {
    let opcode = cursor.peek()?;
    match opcode {
        0 if allow_null => {
            cursor.byte()?;
            Ok(Expression::NullTarget)
        }
        0x60..=0x6e => parse_slot(cursor, opcode),
        0x5b if cursor.bytes.starts_with(&[0x5b, 0x31]) => {
            cursor.take(2)?;
            Ok(Expression::DebugTarget)
        }
        0x71 | 0x83 | 0x88 => parse_expression(cursor, scope, depth),
        _ if starts_name(opcode) => {
            let offset = cursor.offset;
            let (name, symbol) = scope.resolve(cursor)?;
            if matches!(symbol, Symbol::Field | Symbol::FieldUnit) {
                return Ok(Expression::Field(name));
            }
            if !matches!(
                symbol,
                Symbol::Integer | Symbol::String | Symbol::Buffer | Symbol::Package
            ) {
                return Err(ParseError {
                    offset,
                    message: format!("{name} cannot be a value target"),
                });
            }
            Ok(Expression::Name(name))
        }
        _ => Err(cursor.error("expected a local, argument, or named value target")),
    }
}

fn parse_field(
    cursor: &mut Cursor<'_>,
    scope: &MethodScope<'_>,
    depth: usize,
    fixed_bits: Option<u64>,
) -> Result<Expression, ParseError> {
    let buffer = Box::new(parse_expression(cursor, scope, depth + 1)?);
    let index = Box::new(parse_expression(cursor, scope, depth + 1)?);
    let (length, mode) = match fixed_bits {
        Some(bits) => (
            Expression::Integer(IntegerLiteral::Immediate(bits)),
            if bits == 1 { 0 } else { 2 },
        ),
        None => (parse_expression(cursor, scope, depth + 1)?, 1),
    };
    let offset = cursor.offset;
    let name = cursor.name_string()?;
    if name.segments.is_empty() {
        return Err(cursor.error("NullName cannot declare a buffer field"));
    }
    let name = name.absolute(scope.path, offset)?;
    if scope.namespace.contains_key(&name)
        || scope
            .local_objects
            .borrow_mut()
            .insert(name.clone(), Symbol::Field)
            .is_some()
    {
        return Err(cursor.error(format!("duplicate buffer field {name}")));
    }
    Ok(Expression::CreateField {
        name,
        buffer,
        index,
        length: Box::new(length),
        mode,
    })
}

fn parse_slot(cursor: &mut Cursor<'_>, opcode: u8) -> Result<Expression, ParseError> {
    cursor.byte()?;
    if opcode < 0x68 {
        Ok(Expression::Local(opcode - 0x60))
    } else {
        Ok(Expression::Arg(opcode - 0x68))
    }
}

fn parse_atom(cursor: &mut Cursor<'_>, opcode: u8) -> Result<Expression, ParseError> {
    if (0x60..=0x6e).contains(&opcode) {
        return parse_slot(cursor, opcode);
    }
    if opcode == 0x0d {
        return parse_string(cursor).map(Expression::String);
    }
    parse_integer(cursor, opcode)?
        .map(Expression::Integer)
        .ok_or_else(|| cursor.unsupported_opcode())
}

fn parse_string(cursor: &mut Cursor<'_>) -> Result<Vec<u8>, ParseError> {
    let offset = cursor.offset;
    cursor.byte()?;
    let length = cursor
        .bytes
        .iter()
        .position(|&byte| byte == 0)
        .ok_or_else(|| ParseError {
            offset,
            message: "unterminated string literal within AML package".into(),
        })?;
    let bytes = cursor.take(length + 1)?;
    Ok(bytes[..length].to_vec())
}

fn parse_integer(
    cursor: &mut Cursor<'_>,
    opcode: u8,
) -> Result<Option<IntegerLiteral>, ParseError> {
    let len = match opcode {
        0x00 | 0x01 | 0xff => {
            cursor.byte()?;
            return Ok(Some(match opcode {
                0 => IntegerLiteral::Zero,
                1 => IntegerLiteral::One,
                _ => IntegerLiteral::Ones,
            }));
        }
        0x0a => 1,
        0x0b => 2,
        0x0c => 4,
        0x0e => 8,
        _ => return Ok(None),
    };
    cursor.byte()?;
    let mut bytes = [0; 8];
    bytes[..len].copy_from_slice(cursor.take(len)?);
    Ok(Some(IntegerLiteral::Immediate(u64::from_le_bytes(bytes))))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn wrapped_externals_do_not_override_loaded_definitions() {
        // Name (VALU, One); External (VALU, DeviceObj)
        let name = b"\x08VALU\x01";
        let external = b"\x15VALU\x06\x00";
        let build = |wrapper: &[u8]| {
            let mut table = include_bytes!("../example.aml")[..HEADER_LEN].to_vec();
            table.extend_from_slice(name);
            table.extend_from_slice(wrapper);
            table.extend_from_slice(external);
            let len = table.len() as u32;
            table[4..8].copy_from_slice(&len.to_le_bytes());
            table[9] = 0;
            table[9] = 0u8.wrapping_sub(table.iter().copied().fold(0u8, u8::wrapping_add));
            table
        };
        assert!(parse_table(&build(b"\xa0\x09\x00")).is_ok());
        let error = parse_table(&build(b"")).err().unwrap();
        assert!(error.contains("type or arity mismatch for External \\VALU"));
    }

    #[test]
    fn resolves_forward_calls_with_the_declared_arity() {
        let mut fixture = include_bytes!("../example.aml").to_vec();
        // Move TEST before STEP without changing either method or the checksum.
        fixture[HEADER_LEN..].rotate_left(0x3c - HEADER_LEN);

        let table = parse_table(&fixture).unwrap();
        let Declaration::Method(test) = &table.declarations[0] else {
            panic!("expected Method");
        };
        assert_eq!(test.name.to_string(), "\\TEST");
        let StatementKind::While(_, body) = &test.body[2].kind else {
            panic!("expected While");
        };
        let StatementKind::Evaluate(Expression::Apply(Operator::Add, args)) = &body[0].kind else {
            panic!("expected Add");
        };
        assert!(matches!(&args[..], [
            Expression::Local(1),
            Expression::Call(name, call_args),
            Expression::Local(1),
        ] if name.to_string() == "\\STEP" && matches!(&call_args[..], [Expression::Local(0)])));
    }

    #[test]
    fn only_an_unprefixed_nameseg_searches_ancestors() {
        let scope = AbsolutePath(vec!["DEV0".into(), "MTH0".into()]);
        let value = AbsolutePath(vec!["DEV0".into(), "VAL0".into()]);
        let namespace = Namespace::from([(value.clone(), Symbol::Integer)]);

        for bytes in [b"VAL0".as_slice(), b"^VAL0"] {
            let mut cursor = Cursor { bytes, offset: 0 };
            let (resolved, _) = resolve_name(&mut cursor, &namespace, &scope).unwrap();
            assert_eq!(resolved, value);
        }
        for bytes in [b"\x2f\x01VAL0".as_slice(), b"^^VAL0", b"^^^VAL0"] {
            let mut cursor = Cursor { bytes, offset: 0 };
            assert!(resolve_name(&mut cursor, &namespace, &scope).is_err());
        }
    }

    #[test]
    fn null_name_depends_on_its_context() {
        let root = AbsolutePath::default();
        let parent = AbsolutePath(vec!["DEV0".into()]);
        let method = AbsolutePath(vec!["DEV0".into(), "MTH0".into()]);
        let namespace = Namespace::from([
            (root.clone(), Symbol::Other),
            (parent.clone(), Symbol::Other),
        ]);
        let scope = MethodScope {
            namespace: &namespace,
            path: &method,
            local_objects: RefCell::default(),
        };

        let mut cursor = Cursor {
            bytes: &[0, 0],
            offset: 0,
        };
        assert!(matches!(
            parse_expression(&mut cursor, &scope, 0).unwrap(),
            Expression::Integer(IntegerLiteral::Zero)
        ));
        assert!(matches!(
            parse_target(&mut cursor, &scope, 0, true).unwrap(),
            Expression::NullTarget
        ));

        for (bytes, expected) in [(b"\\\0", root), (b"^\0", parent)] {
            let mut cursor = Cursor { bytes, offset: 0 };
            let (resolved, _) = resolve_name(&mut cursor, &namespace, &method).unwrap();
            assert_eq!(resolved, expected);
        }
    }

    #[test]
    fn package_length_includes_all_its_encoding_bytes() {
        let mut bytes = [0; 67];
        bytes[..2].copy_from_slice(&[0x42, 0x04]); // Length 66, payload 64.
        bytes[66] = 0xa4;
        let mut cursor = Cursor {
            bytes: &bytes,
            offset: 0,
        };

        let package = cursor.package().unwrap();
        assert_eq!(package.offset, 2);
        assert_eq!(package.bytes.len(), 64);
        assert_eq!(cursor.byte().unwrap(), 0xa4);
    }

    #[test]
    fn an_operand_cannot_read_past_its_package() {
        // The If package ends at an incomplete Return; the final Zero belongs
        // to the enclosing package.
        let mut cursor = Cursor {
            bytes: &[0xa0, 0x03, 0x01, 0xa4, 0x00],
            offset: 0,
        };
        let scope = MethodScope {
            namespace: &Namespace::new(),
            path: &AbsolutePath::default(),
            local_objects: RefCell::default(),
        };
        let Err(error) = parse_statements(&mut cursor, &scope, 0, false) else {
            panic!("accepted a Return missing its operand");
        };
        assert_eq!(error.offset, 4);
        assert_eq!(cursor.bytes, &[0x00]);
    }

    #[test]
    fn long_if_chains_have_a_separate_nesting_limit() {
        let scope = MethodScope {
            namespace: &Namespace::new(),
            path: &AbsolutePath::default(),
            local_objects: RefCell::default(),
        };
        let chain = |levels| {
            let mut bytes = vec![0xa4, 0x01]; // Return (One)
            for _ in 0..levels {
                let length = bytes.len() + 3;
                let mut outer = vec![0xa0, 0x40 | (length & 15) as u8, (length >> 4) as u8, 0x60];
                outer.append(&mut bytes);
                bytes = outer;
            }
            bytes
        };
        let bytes = chain(100);
        let mut cursor = Cursor {
            bytes: &bytes,
            offset: 0,
        };
        assert!(parse_statements(&mut cursor, &scope, 0, false).is_ok());
        let bytes = chain(MAX_STATEMENT_DEPTH);
        let mut cursor = Cursor {
            bytes: &bytes,
            offset: 0,
        };
        let Err(error) = parse_statements(&mut cursor, &scope, 0, false) else {
            panic!("accepted an over-deep statement chain");
        };
        assert!(error.message.contains("nesting limit exceeded"));
    }

    #[test]
    fn string_terminator_must_be_in_the_same_package() {
        // The final Zero belongs to the enclosing package.
        let mut cursor = Cursor {
            bytes: &[0xa0, 0x05, 0x01, 0xa4, 0x0d, b'A', 0x00],
            offset: 0,
        };
        let scope = MethodScope {
            namespace: &Namespace::new(),
            path: &AbsolutePath::default(),
            local_objects: RefCell::default(),
        };
        let Err(error) = parse_statements(&mut cursor, &scope, 0, false) else {
            panic!("accepted a string without a terminator");
        };
        assert_eq!(error.offset, 4);
        assert!(error.message.contains("unterminated string"));
        assert_eq!(cursor.bytes, &[0]);
    }

    #[test]
    fn rejects_unmatched_else_and_loop_control() {
        let scope = MethodScope {
            namespace: &Namespace::new(),
            path: &AbsolutePath::default(),
            local_objects: RefCell::default(),
        };
        for (bytes, message) in [
            (&[0xa1, 1][..], "Else must follow an If in the same package"),
            (&[0xa5][..], "Break must be inside a While"),
            (&[0x9f][..], "Continue must be inside a While"),
        ] {
            let mut cursor = Cursor { bytes, offset: 0 };
            let Err(error) = parse_statements(&mut cursor, &scope, 0, false) else {
                panic!("accepted unmatched control flow");
            };
            assert_eq!(error.offset, 0);
            assert_eq!(error.message, message);
        }
    }
}
