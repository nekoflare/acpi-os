use std::collections::{BTreeSet, HashMap};
use std::fmt::{Arguments, Write};

use crate::aml::{
    AbsolutePath, Declaration, Expression, FieldBacking, IntegerLiteral, IntegerWidth, Literal,
    Method, NamedValue, Operator, Statement, StatementKind, Table,
};

const NO_RETURN_TYPE: u64 = 0x110;
const NO_RETURN_STATUS: u32 = 14;

fn slot_names(table: &Table, dynamic: bool) -> impl Iterator<Item = &AbsolutePath> {
    use std::slice::from_ref;
    table.declarations.iter().flat_map(move |declaration| {
        let (name, units) = match declaration {
            Declaration::Name(name) => (from_ref(&name.name), &[][..]),
            Declaration::Event { name, .. }
            | Declaration::Mutex { name, .. }
            | Declaration::Field(Expression::CreateField { name, .. }) => (from_ref(name), &[][..]),
            Declaration::Region(region) => (from_ref(&region.name), &[][..]),
            Declaration::Alias { name, .. } if dynamic => (from_ref(name), &[][..]),
            Declaration::RegionFields(fields) => (&[][..], fields.units.as_slice()),
            _ => (&[][..], &[][..]),
        };
        name.iter().chain(units.iter().map(|unit| &unit.name))
    })
}

struct AliasBinding {
    target: AbsolutePath,
    state: Option<usize>,
}

struct Bindings {
    slots: HashMap<AbsolutePath, usize>,
    static_slots: usize,
    aliases: HashMap<AbsolutePath, AliasBinding>,
    namespace_states: HashMap<AbsolutePath, usize>,
    freestanding: bool,
    breakpoint_handler: bool,
}

fn table_dependencies(tables: &[Table], static_count: usize) -> Vec<BTreeSet<usize>> {
    let mut owners = HashMap::new();
    let mut aliases = HashMap::new();
    for (index, table) in tables.iter().enumerate() {
        for name in slot_names(table, true) {
            owners.insert(name, index);
        }
        for declaration in &table.declarations {
            match declaration {
                Declaration::Method(method) => {
                    owners.insert(&method.name, index);
                }
                Declaration::Container { name, .. } => {
                    owners.insert(name, index);
                }
                _ => {}
            }
        }
        aliases.extend(table.aliases.iter().map(|(name, target)| (name, target)));
    }

    tables[static_count..]
        .iter()
        .enumerate()
        .map(|(id, table)| {
            let table_index = static_count + id;
            let mut dependencies = BTreeSet::new();
            let mut require = |name: &AbsolutePath| {
                let mut name = name;
                loop {
                    if let Some(&owner) = owners.get(name)
                        && owner >= static_count
                        && owner != table_index
                    {
                        dependencies.insert(owner - static_count);
                    }
                    let Some(target) = aliases.get(name) else {
                        break;
                    };
                    name = target;
                }
            };
            let names = owners
                .iter()
                .filter_map(|(&name, &owner)| (owner == table_index).then_some(name));
            for name in names {
                let mut parent = name.parent();
                while let Some(path) = parent {
                    require(&path);
                    parent = path.parent();
                }
            }
            for (_, target) in &table.aliases {
                require(target);
            }
            for declaration in &table.declarations {
                match declaration {
                    Declaration::Scope { name, .. } => require(name),
                    Declaration::RegionFields(fields) => match &fields.backing {
                        FieldBacking::Region(region) => require(region),
                        FieldBacking::Bank(region, selector, _) => {
                            require(region);
                            require(selector);
                        }
                        FieldBacking::Index(index, data) => {
                            require(index);
                            require(data);
                        }
                    },
                    _ => {}
                }
            }
            dependencies
        })
        .collect()
}

pub fn emit(
    tables: &[Table],
    width: IntegerWidth,
    static_count: usize,
    freestanding: bool,
) -> Result<String, String> {
    let mut module = String::new();
    let mut intrinsics = BTreeSet::new();
    let mut strings = Vec::new();
    let os_name = AbsolutePath::predefined_os();
    let slots: HashMap<_, _> = std::iter::once(&os_name)
        .chain(
            tables
                .iter()
                .enumerate()
                .flat_map(|(index, table)| slot_names(table, index >= static_count)),
        )
        .enumerate()
        .map(|(index, name)| (name.clone(), index))
        .collect();
    let static_slots = 1 + tables[..static_count]
        .iter()
        .flat_map(|table| slot_names(table, false))
        .count();
    let dynamic_count = tables.len() - static_count;
    let count = slots.len() + dynamic_count * 2 + usize::from(dynamic_count != 0);
    let aliases = tables
        .iter()
        .enumerate()
        .flat_map(|(index, table)| {
            let state = index
                .checked_sub(static_count)
                .map(|id| slots.len() + id * 2);
            table.aliases.iter().map(move |(name, target)| {
                (
                    name.clone(),
                    AliasBinding {
                        target: target.clone(),
                        state,
                    },
                )
            })
        })
        .collect();
    let base_state = slots.len();
    let namespace_states = tables[static_count..]
        .iter()
        .enumerate()
        .flat_map(|(index, table)| {
            let state = base_state + index * 2;
            table
                .declarations
                .iter()
                .filter_map(move |decl| match decl {
                    Declaration::Container { name, .. } => Some((name.clone(), state)),
                    Declaration::Method(method) => Some((method.name.clone(), state)),
                    Declaration::Mutex { name, .. } | Declaration::Event { name, .. } => {
                        Some((name.clone(), state))
                    }
                    Declaration::Region(region) => Some((region.name.clone(), state)),
                    _ => None,
                })
        })
        .collect();

    let dependencies = table_dependencies(tables, static_count);
    for (index, required) in dependencies.iter().enumerate() {
        let items = required
            .iter()
            .map(|id| format!("i64 {id}"))
            .collect::<Vec<_>>()
            .join(", ");
        writeln!(
            module,
            "@aml.dynamic.dependencies.{index} = private constant [{} x i64] [{items}]",
            required.len()
        )
        .unwrap();
    }
    writeln!(module, "@aml_dynamic_count = constant i64 {dynamic_count}").unwrap();
    writeln!(
        module,
        "@aml_dynamic_tables = constant [{dynamic_count} x {{ i64, i64, i64, ptr, ptr, i64, ptr, i64 }}] ["
    )
    .unwrap();
    let mut first = static_slots;
    for (table_index, table) in tables[static_count..].iter().enumerate() {
        let size = slot_names(table, true).count();
        let bytes = byte_global(&mut strings, &table.bytes);
        let length = table.bytes.len();
        let dependency_count = dependencies[table_index].len();
        let state = slots.len() + table_index * 2;
        let end = if table_index + 1 == dynamic_count {
            ""
        } else {
            ","
        };
        writeln!(module, "  {{ i64, i64, i64, ptr, ptr, i64, ptr, i64 }} {{ i64 {first}, i64 {size}, i64 {state}, ptr @aml.initialize.{table_index}, ptr {bytes}, i64 {length}, ptr @aml.dynamic.dependencies.{table_index}, i64 {dependency_count} }}{end}").unwrap();
        first += size;
    }
    module.push_str("]\n");
    module.push_str("%aml.value = type { i64, ptr, i64 }\n");
    writeln!(
        module,
        "%aml.context = type {{ i64, ptr, i64, i64, i64, i32, i8, {{ [9 x ptr], i64 }}, ptr, [{count} x %aml.value] }}"
    )
    .unwrap();
    module.push_str(
        r#"
declare ptr @calloc(i64, i64)
declare void @aml_objects_destroy(ptr)
declare void @aml_context_set_host(ptr, ptr)
declare ptr @aml_object_slot(ptr)
declare void @aml_retire_region(ptr)
declare i64 @acpi_arena_mark()
declare void @acpi_arena_reset(i64)
declare void @aml_reset_allocations(ptr, ptr)
declare void @aml_objects_collect(ptr)
declare i32 @aml_sync_level(ptr)
declare void @aml_release_mutexes(ptr)
declare ptr @aml_dynamic_slot(ptr, i64)
declare i1 @aml_table_active(ptr, i64)
declare i1 @aml_table_enter(ptr, i64)
declare void @aml_table_leave(ptr, i64)
declare i32 @aml_object_op(ptr, ptr, i32, ptr, ptr, ptr, i64)

define ptr @aml_context_create() {
entry:
  %ctx = call ptr @aml_context_create_with_host(ptr null)
  ret ptr %ctx
}

define ptr @aml_context_create_with_host(ptr %host) {
entry:
  %size = ptrtoint ptr getelementptr (%aml.context, ptr null, i32 1) to i64
  %ctx = call ptr @calloc(i64 1, i64 %size)
  %failed = icmp eq ptr %ctx, null
  br i1 %failed, label %error, label %initialize
initialize:
  call void @aml_context_set_host(ptr %ctx, ptr %host)
  %width = getelementptr inbounds %aml.context, ptr %ctx, i32 0, i32 3
"#,
    );
    writeln!(module, "  store i64 {}, ptr %width", width.bits() / 8).unwrap();
    writeln!(module, "  %count = getelementptr inbounds %aml.context, ptr %ctx, i32 0, i32 4\n  store i64 {count}, ptr %count").unwrap();
    for index in 0..slots.len() {
        let tag = if index < static_slots { 260 } else { 264 };
        writeln!(module, "  %init.slot{index} = getelementptr inbounds %aml.context, ptr %ctx, i32 0, i32 9, i64 {index}\n  store %aml.value {{ i64 0, ptr null, i64 {tag} }}, ptr %init.slot{index}").unwrap();
    }
    module.push_str(
        r#"  store i64 100000, ptr %ctx
  %result = alloca %aml.value
  %status = call i32 @aml.initialize(ptr %ctx, ptr %result, i32 1)
  call void @aml_release_mutexes(ptr %ctx)
  %ok = icmp eq i32 %status, 0
  br i1 %ok, label %done, label %cleanup
cleanup:
  call void @aml_objects_destroy(ptr %ctx)
  br label %error
error:
  ret ptr null
done:
  ret ptr %ctx
}

define void @aml_context_destroy(ptr %ctx) {
entry:
  call void @aml_objects_destroy(ptr %ctx)
  ret void
}

define internal i1 @aml.consume_step(ptr %ctx) {
entry:
  %remaining = load i64, ptr %ctx
  %available = icmp ne i64 %remaining, 0
  br i1 %available, label %consume, label %exhausted
consume:
  %next = sub i64 %remaining, 1
  store i64 %next, ptr %ctx
  ret i1 true
exhausted:
  ret i1 false
}

"#,
    );
    let breakpoint_handler = freestanding
        && tables[..static_count]
            .iter()
            .flat_map(|table| &table.declarations)
            .any(|decl| {
                matches!(decl, Declaration::Method(method)
            if method.name.llvm_suffix() == "BRKP" && method.arg_count() == 1)
            });
    let bindings = Bindings {
        slots,
        static_slots,
        aliases,
        namespace_states,
        freestanding,
        breakpoint_handler,
    };
    let os_object = Declaration::Name(NamedValue {
        offset: 0,
        name: os_name,
        initializer: Literal::String(b"Microsoft Windows NT".to_vec()),
    });
    emit_initializer(
        &mut module,
        "aml.initialize",
        std::iter::once(&os_object).chain(
            tables[..static_count]
                .iter()
                .flat_map(|table| &table.declarations),
        ),
        width,
        &mut intrinsics,
        &bindings,
        &mut strings,
    )?;
    for (index, table) in tables.iter().enumerate() {
        let dynamic_index = index.checked_sub(static_count);
        if let Some(id) = dynamic_index {
            emit_initializer(
                &mut module,
                &format!("aml.initialize.{id}"),
                table.declarations.iter(),
                width,
                &mut intrinsics,
                &bindings,
                &mut strings,
            )?;
        }
        for declaration in &table.declarations {
            if let Declaration::Method(method) = declaration {
                MethodEmitter::new(method, width, &mut intrinsics, &bindings, &mut strings)
                    .emit(&mut module, dynamic_index.map(|id| base_state + id * 2))?;
            }
        }
    }
    for declaration in intrinsics {
        writeln!(module, "{declaration}").unwrap();
    }
    if breakpoint_handler {
        let clone = ObjectOp::Clone as u32;
        writeln!(module,
            r#"
define i32 @aml_interrupt_BRKP(ptr %ctx, ptr %frame, i64 %length) {{
entry:
  %source = alloca %aml.value
  %snapshot = alloca %aml.value
  %result = alloca %aml.value
  %buffer = insertvalue %aml.value {{ i64 0, ptr null, i64 3 }}, ptr %frame, 1
  %view = insertvalue %aml.value %buffer, i64 %length, 0
  store %aml.value %view, ptr %source
  %copy.status = call i32 @aml_object_op(ptr %ctx, ptr %snapshot, i32 {clone}, ptr %source, ptr null, ptr null, i64 0)
  %ok = icmp eq i32 %copy.status, 0
  br i1 %ok, label %dispatch, label %failed
dispatch:
  %registers = load %aml.value, ptr %snapshot
  %status = call i32 @aml.impl.BRKP(ptr %ctx, ptr %result, i32 1, %aml.value %registers)
  ret i32 %status
failed:
  ret i32 %copy.status
}}
"#,
        ).unwrap();
    }
    for global in strings {
        module.push_str(&global);
    }
    Ok(module)
}

fn emit_initializer<'a>(
    module: &mut String,
    name: &str,
    declarations: impl Iterator<Item = &'a Declaration>,
    width: IntegerWidth,
    intrinsics: &mut BTreeSet<String>,
    bindings: &Bindings,
    strings: &mut Vec<String>,
) -> Result<(), String> {
    let initializer = Method {
        name: AbsolutePath::default(),
        offset: 0,
        flags: 0,
        body: Vec::new(),
    };
    let slots = &bindings.slots;
    let mut emitter = MethodEmitter::new(&initializer, width, intrinsics, bindings, strings);
    emitter.check_budget();
    for declaration in declarations {
        let name = match declaration {
            Declaration::Name(name) => name,
            Declaration::Region(region) => {
                emitter.lower_region(region)?;
                continue;
            }
            Declaration::RegionFields(fields) => {
                emitter.lower_region_fields(fields)?;
                continue;
            }
            Declaration::Alias { name, .. } if slots.contains_key(name) => {
                if let Some(target) = emitter.alias_reference_target(&bindings.aliases[name].target)
                {
                    let reference = emitter.named_reference(target);
                    let address = emitter.named_address(slots[name]);
                    emitter
                        .instruction(format_args!("store %aml.value {reference}, ptr {address}"));
                }
                continue;
            }
            Declaration::Mutex { name, level, .. } => {
                let address = emitter.named_address(slots[name]);
                let initial = integer_constant(u64::from(*level));
                emitter.instruction(format_args!("store %aml.value {initial}, ptr {address}"));
                continue;
            }
            Declaration::Event { name, .. } => {
                let address = emitter.named_address(slots[name]);
                emitter.instruction(format_args!(
                    "store %aml.value zeroinitializer, ptr {address}"
                ));
                continue;
            }
            Declaration::Field(field) => {
                emitter.lower_value(field)?;
                continue;
            }
            Declaration::Executable(body) => {
                if emitter.lower_statements(body)? {
                    return emitter.emit_body(module, name, "");
                }
                continue;
            }
            _ => continue,
        };
        let value = match &name.initializer {
            Literal::Integer(integer) => Ok(integer_constant(integer.value(width))),
            Literal::String(bytes) => emitter.lower_string(bytes),
            Literal::Aggregate(expression) => emitter.lower_value(expression),
            Literal::Pending => unreachable!("initializer has been parsed"),
        }
        .map_err(|error| {
            format!(
                "initializer for {} at file offset {:#06x}: {error}",
                name.name, name.offset
            )
        })?;
        let address = emitter.named_address(slots[&name.name]);
        emitter.instruction(format_args!("store %aml.value {value}, ptr {address}"));
    }
    emitter.return_status("0");
    emitter.emit_body(module, name, "")
}

fn integer_constant(value: u64) -> String {
    format!("{{ i64 {value}, ptr null, i64 0 }}")
}

fn cond_ref_local(predicate: &Expression, truth: bool) -> u8 {
    match predicate {
        Expression::Apply(Operator::LNot, args) => cond_ref_local(&args[0], !truth),
        Expression::CondRefOf {
            source: Some(_),
            target,
        } if truth => match **target {
            Expression::Local(index) => 1 << index,
            _ => 0,
        },
        _ => 0,
    }
}

fn byte_constant(globals: &mut Vec<String>, bytes: &[u8]) -> String {
    let symbol = byte_global(globals, bytes);
    format!("{{ i64 {}, ptr {symbol}, i64 2 }}", bytes.len())
}

fn byte_global(globals: &mut Vec<String>, bytes: &[u8]) -> String {
    let symbol = format!("@aml.string.{}", globals.len());
    let size = bytes.len() + 1;
    let mut global = format!("{symbol} = private unnamed_addr constant [{size} x i8] c\"");
    for byte in bytes {
        write!(global, "\\{byte:02X}").unwrap();
    }
    writeln!(global, "\\00\"").unwrap();
    globals.push(global);
    symbol
}

struct MethodEmitter<'a> {
    method: &'a Method,
    width: IntegerWidth,
    intrinsics: &'a mut BTreeSet<String>,
    body: String,
    next_value: usize,
    next_label: usize,
    used_locals: u8,
    initialized_locals: u8,
    loops: Vec<LoopBlocks>,
    bindings: &'a Bindings,
    local_objects: HashMap<AbsolutePath, usize>,
    local_regions: BTreeSet<usize>,
    referenced_locals: u8,
    referenced_args: u8,
    strings: &'a mut Vec<String>,
    has_division: bool,
    has_type_check: bool,
    has_table_check: bool,
    /// Whether the method body can allocate runtime objects (buffers, packages,
    /// strings, fields, regions). Non-allocating methods skip the per-call
    /// mark-and-sweep `aml_objects_collect`, which is the dominant per-invocation
    /// runtime cost for pure-integer methods.
    allocates: bool,
    /// Whether the method body ever acquires a mutex. If not, the per-call
    /// `aml_release_mutexes` walk is skipped (it can only observe an empty list).
    acquires_mutex: bool,
}

// Runtime operations outside the AML opcode space.
#[repr(u32)]
enum ObjectOp {
    Clone = 0x100,
    Read,
    StoreSlot,
    StoreNamed,
    StoreRef,
    CopySlot,
    Buffer,
    Package,
    PackageElement,
    FieldCreate,
    String,
    Type,
    Export,
    Timer,
    Delay,
    Notify,
    EventControl,
    EventWait,
    MutexAcquire,
    MutexRelease,
    RegionCreate,
    RegionFieldCreate,
    LoadPaths,
    LoadTable,
    Load,
    Unload,
    NamespaceRef,
    Osi,
    InitNamed,
    UnresolvedExternal,
    IndexRead,
}

struct LoopBlocks {
    header: String,
    exit: String,
    exit_locals: Option<u8>,
}

// Only paths that can reach a join constrain its initialized locals.
fn merge_paths(left: Option<u8>, right: Option<u8>) -> Option<u8> {
    match (left, right) {
        (Some(left), Some(right)) => Some(left & right),
        _ => left.or(right),
    }
}

// Only scalar, leaf region methods can discard their allocations on return.
fn scoped_region_method(body: &[Statement]) -> bool {
    let [region, fields, rest @ ..] = body else { return false };
    let (StatementKind::Region(region), StatementKind::RegionFields(fields)) =
        (&region.kind, &fields.kind)
    else { return false };
    let [field] = fields.units.as_slice() else { return false };
    if !matches!(&fields.backing, FieldBacking::Region(name) if *name == region.name)
        || !matches!(region.base, Expression::Arg(_) | Expression::Integer(_))
        || !matches!(region.length, Expression::Integer(_))
        || field.bits > 64
    {
        return false;
    }
    fn scalar(expr: &Expression) -> bool {
        matches!(expr, Expression::Integer(_) | Expression::Arg(_))
    }
    fn safe(statement: &Statement, field: &AbsolutePath) -> bool {
        let is_field = |expr: &Expression| matches!(expr, Expression::Field(name) if name == field);
        match &statement.kind {
            StatementKind::Return(expr) => matches!(expr, Expression::Integer(_)) || is_field(expr),
            StatementKind::Evaluate(Expression::Apply(Operator::Store, args)) => {
                matches!(args.as_slice(), [source, target] if scalar(source) && is_field(target))
            }
            StatementKind::If { predicate, body, otherwise: None } => {
                matches!(predicate, Expression::Apply(Operator::LEqual, args) if args.iter().all(scalar))
                    && body.iter().all(|s| safe(s, field))
            }
            _ => false,
        }
    }
    rest.iter().all(|s| safe(s, &field.name))
}

impl<'a> MethodEmitter<'a> {
    fn new(
        method: &'a Method,
        width: IntegerWidth,
        intrinsics: &'a mut BTreeSet<String>,
        bindings: &'a Bindings,
        strings: &'a mut Vec<String>,
    ) -> Self {
        Self {
            method,
            width,
            intrinsics,
            bindings,
            strings,
            body: String::new(),
            next_value: 0,
            next_label: 0,
            used_locals: 0,
            initialized_locals: 0,
            loops: Vec::new(),
            has_division: false,
            has_type_check: false,
            has_table_check: false,
            allocates: false,
            acquires_mutex: false,
            local_objects: HashMap::new(),
            local_regions: BTreeSet::new(),
            referenced_locals: 0,
            referenced_args: 0,
        }
    }

    fn emit(mut self, module: &mut String, table_state: Option<usize>) -> Result<(), String> {
        let method = self.method;
        self.check_budget();
        if !self.lower_statements(&method.body)? {
            self.instruction(format_args!(
                "store %aml.value {{ i64 0, ptr null, i64 {NO_RETURN_TYPE} }}, ptr %result"
            ));
            self.return_status("0");
        }
        let name = method.name.llvm_suffix();
        let export_op = ObjectOp::Export as u32;
        let mut args = String::new();
        for index in 0..method.arg_count() {
            write!(args, ", i64 %arg{index}").unwrap();
        }
        writeln!(
            module,
            r#"define i32 @aml_{name}(ptr %ctx, ptr %result{args}) {{
entry:
  %value = alloca %aml.value
  %missing.result = icmp eq ptr %result, null
  br i1 %missing.result, label %invalid, label %invoke
invoke:
  %status = call i32 @aml_value_{name}(ptr %ctx, ptr %value{args})
  %ok = icmp eq i32 %status, 0
  br i1 %ok, label %check.type, label %failed
check.type:
  %returned = load %aml.value, ptr %value
  %type = extractvalue %aml.value %returned, 2
  %is.integer = icmp eq i64 %type, 0
  br i1 %is.integer, label %success, label %check.no.return
check.no.return:
  %is.no.return = icmp eq i64 %type, {NO_RETURN_TYPE}
  %type.status = select i1 %is.no.return, i32 {NO_RETURN_STATUS}, i32 4
  ret i32 %type.status
success:
  %integer = extractvalue %aml.value %returned, 0
  store i64 %integer, ptr %result
  ret i32 0
failed:
  ret i32 %status
invalid:
  ret i32 3
}}"#
        )
        .unwrap();
        // Build the argument-preparation instructions (masking in 32-bit mode
        // and packing each integer into an %aml.value) into a string so they
        // land inside the aml_value_<name> body rather than between functions.
        let mut arg_prep = String::new();
        let mut operands = String::new();
        let mut parameters = String::new();
        for index in 0..method.arg_count() {
            let value = if matches!(self.width, IntegerWidth::Bits32) {
                writeln!(
                    arg_prep,
                    "  %arg{index}.masked = and i64 %arg{index}, 4294967295"
                )
                .unwrap();
                format!("%arg{index}.masked")
            } else {
                format!("%arg{index}")
            };
            writeln!(
                arg_prep,
                "  %arg{index}.value = insertvalue %aml.value zeroinitializer, i64 {value}, 0"
            )
            .unwrap();
            write!(operands, ", %aml.value %arg{index}.value").unwrap();
            write!(parameters, ", %aml.value %arg{index}").unwrap();
        }
        // Non-allocating methods never create runtime objects, so the
        // mark-and-sweep GC at entry is a no-op for their reachability set and
        // is skipped. Methods that never acquire a mutex skip the per-call
        // held-mutex walk on exit. Both are the dominant per-invocation costs
        // for pure-integer methods.
        let collect = if self.allocates {
            "  call void @aml_objects_collect(ptr %ctx)\n"
        } else {
            ""
        };
        let release = if self.acquires_mutex {
            "  call void @aml_release_mutexes(ptr %ctx)\n"
        } else {
            ""
        };
        // Fast path the integer export: instead of routing every return
        // through the runtime Export dispatch, inspect the result's type tag.
        // Integer results (the common case) are stored directly; non-integer
        // results fall back to aml_object_op(Export) so references, packages
        // and buffers are still cloned out of the internal slot correctly.
        writeln!(
            module,
            r#"define i32 @aml_value_{name}(ptr %ctx, ptr %result{args}) {{
entry:
  %missing.ctx = icmp eq ptr %ctx, null
  %missing.result = icmp eq ptr %result, null
  %invalid = or i1 %missing.ctx, %missing.result
  br i1 %invalid, label %error, label %invoke
invoke:
{collect}  store i64 {budget}, ptr %ctx
{arg_prep}  %internal.result = alloca %aml.value
  %status = call i32 @aml.impl.{name}(ptr %ctx, ptr %internal.result, i32 1{operands})
{release}  %ok = icmp eq i32 %status, 0
  br i1 %ok, label %export, label %failed
export:
  %result.type = getelementptr inbounds %aml.value, ptr %internal.result, i32 0, i32 2
  %result.tag = load i64, ptr %result.type
  %is.integer = icmp eq i64 %result.tag, 0
  br i1 %is.integer, label %export.integer, label %export.object
export.integer:
  %result.value = load %aml.value, ptr %internal.result
  store %aml.value %result.value, ptr %result
  ret i32 0
export.object:
  %export.status = call i32 @aml_object_op(ptr %ctx, ptr %result, i32 {export_op}, ptr %internal.result, ptr null, ptr null, i64 0)
  ret i32 %export.status
failed:
  ret i32 %status
error:
  ret i32 3
}}"#,
            budget = if self.bindings.freestanding { -1 } else { 100000 }
        )
        .unwrap();
        let implementation = format!("aml.impl.{name}");
        let mut implementation = implementation;
        if let Some(state) = table_state {
            writeln!(module, r#"define internal i32 @{implementation}(ptr %ctx, ptr %result, i32 %depth{parameters}) {{
entry:
  %loaded = call i1 @aml_table_enter(ptr %ctx, i64 {state})
  br i1 %loaded, label %invoke, label %unavailable
invoke:
  %status = call i32 @{implementation}.loaded(ptr %ctx, ptr %result, i32 %depth{parameters})
  call void @aml_table_leave(ptr %ctx, i64 {state})
  ret i32 %status
unavailable:
  ret i32 10
}}
"#).unwrap();
            implementation.push_str(".loaded");
        }
        if method.flags & 8 == 0 {
            return self.emit_body(module, &implementation, &parameters);
        }
        let sync_level = method.flags >> 4;
        writeln!(
            module,
            r#"define internal i32 @{implementation}(ptr %ctx, ptr %result, i32 %depth{parameters}) {{
entry:
  %level = getelementptr inbounds %aml.context, ptr %ctx, i32 0, i32 5
  %previous = load i32, ptr %level
  %current = call i32 @aml_sync_level(ptr %ctx)
  %allowed = icmp ule i32 %current, {sync_level}
  br i1 %allowed, label %invoke, label %error
invoke:
  store i32 {sync_level}, ptr %level
  %status = call i32 @{implementation}.body(ptr %ctx, ptr %result, i32 %depth{parameters})
  store i32 %previous, ptr %level
  ret i32 %status
error:
  ret i32 8
}}
"#
        )
        .unwrap();
        self.emit_body(module, &format!("{implementation}.body"), &parameters)
    }

    fn emit_body(
        mut self,
        module: &mut String,
        name: &str,
        parameters: &str,
    ) -> Result<(), String> {
        if self.has_division {
            self.start_block("division.error");
            self.return_status("1");
        }
        if self.has_table_check {
            self.start_block("table.unavailable");
            self.return_status("10");
        }
        if self.has_type_check {
            self.start_block("type.error");
            self.return_status("4");
        }
        self.start_block("limit.error");
        self.return_status("2");

        writeln!(
            module,
            "define internal i32 @{name}(ptr %ctx, ptr %result, i32 %depth{parameters}) {{\nentry:"
        )
        .unwrap();
        for name in [
            "call.result",
            "object.result",
            "object.a",
            "object.b",
            "object.c",
        ] {
            writeln!(module, "  %{name} = alloca %aml.value").unwrap();
        }
        let mut references: Vec<_> = (0..self.local_objects.len())
            .map(|index| format!("%field{index}"))
            .collect();
        for index in 0..8 {
            if self.used_locals & (1 << index) == 0 {
                continue;
            }
            let slot = format!("%local{index}");
            if self.referenced_locals & (1 << index) != 0 {
                references.push(slot);
            } else {
                writeln!(module, "  {slot} = alloca %aml.value\n  store %aml.value {{ i64 0, ptr null, i64 260 }}, ptr {slot}").unwrap();
            }
        }
        for index in 0..self.method.arg_count() {
            let slot = format!("%arg{index}.addr");
            if self.referenced_args & (1 << index) != 0 {
                references.push(slot);
            } else {
                writeln!(module, "  {slot} = alloca %aml.value").unwrap();
            }
        }
        module.push_str("  %exit.status = alloca i32\n");
        module.push_str("  %depth.ok = icmp ule i32 %depth, 64\n  br i1 %depth.ok, label %prepare, label %depth.error\nprepare:\n");
        let scoped = self.bindings.freestanding && matches!(self.width, IntegerWidth::Bits64) && scoped_region_method(&self.method.body);
        if scoped {
            module.push_str("  %arena.mark = call i64 @acpi_arena_mark()\n  %allocations.addr = getelementptr i64, ptr %ctx, i64 1\n  %allocations.mark = load ptr, ptr %allocations.addr\n");
        }
        for (index, slot) in references.iter().enumerate() {
            writeln!(module, "  {slot} = call ptr @aml_object_slot(ptr %ctx)\n  %slot.ok{index} = icmp ne ptr {slot}, null\n  br i1 %slot.ok{index}, label %slot.ready{index}, label %allocation.error\nslot.ready{index}:").unwrap();
        }
        for index in 0..self.method.arg_count() {
            writeln!(
                module,
                "  store %aml.value %arg{index}, ptr %arg{index}.addr"
            )
            .unwrap();
        }
        module.push_str("  br label %execute\nexecute:\n");
        module.push_str(&self.body);
        module.push_str("finish:\n");
        for index in self.local_regions {
            writeln!(module, "  call void @aml_retire_region(ptr %field{index})").unwrap();
        }
        let reset = "  call void @aml_reset_allocations(ptr %ctx, ptr %allocations.mark)\n  call void @acpi_arena_reset(i64 %arena.mark)\n";
        if scoped {
            module.push_str(reset);
        }
        module.push_str("  %final.status = load i32, ptr %exit.status\n  ret i32 %final.status\ndepth.error:\n  ret i32 2\n");
        if !references.is_empty() {
            module.push_str("allocation.error:\n");
            if scoped {
                module.push_str(reset);
            }
            module.push_str("  ret i32 6\n");
        }
        module.push_str("}\n\n");
        Ok(())
    }

    fn return_status(&mut self, status: &str) {
        self.instruction(format_args!("store i32 {status}, ptr %exit.status"));
        self.jump("finish");
    }

    fn instruction(&mut self, instruction: Arguments<'_>) {
        writeln!(self.body, "  {instruction}").unwrap();
    }

    fn value(&mut self, instruction: Arguments<'_>) -> String {
        let name = format!("%v{}", self.next_value);
        self.next_value += 1;
        self.instruction(format_args!("{name} = {instruction}"));
        name
    }

    fn label(&mut self, prefix: &str) -> String {
        let name = format!("{prefix}.{}", self.next_label);
        self.next_label += 1;
        name
    }

    fn start_block(&mut self, label: &str) {
        writeln!(self.body, "{label}:").unwrap();
    }

    fn jump(&mut self, label: &str) {
        self.instruction(format_args!("br label %{label}"));
    }

    // Returns true when no path falls through the statements.
    fn lower_statements(&mut self, statements: &[Statement]) -> Result<bool, String> {
        for statement in statements {
            if self.lower_statement(statement)? {
                return Ok(true);
            }
        }
        Ok(false)
    }

    fn lower_statement(&mut self, statement: &Statement) -> Result<bool, String> {
        match &statement.kind {
            StatementKind::Region(region) => {
                self.lower_region(region)?;
                Ok(false)
            }
            StatementKind::RegionFields(fields) => {
                self.lower_region_fields(fields)?;
                Ok(false)
            }
            StatementKind::Name(name, initializer) => {
                let value = self.statement_value(statement.offset, initializer)?;
                let address = self.named_object_address(name);
                self.object_into(ObjectOp::InitNamed as u32, &[&value], 0, &address);
                Ok(false)
            }
            StatementKind::Return(expression) => {
                let result = self.statement_value(statement.offset, expression)?;
                let tag = self.value(format_args!("extractvalue %aml.value {result}, 2"));
                let integer = self.value(format_args!("icmp eq i64 {tag}, 0"));
                let direct = self.label("return.integer");
                let copy = self.label("return.copy");
                self.branch(&integer, &direct, &copy);
                self.start_block(&direct);
                self.instruction(format_args!("store %aml.value {result}, ptr %result"));
                self.return_status("0");
                self.start_block(&copy);
                self.object_into(ObjectOp::Clone as u32, &[&result], 0, "%result");
                self.return_status("0");
                Ok(true)
            }
            StatementKind::Delay { sleep, duration } => {
                let duration = self.statement_value(statement.offset, duration)?;
                self.object_into(
                    ObjectOp::Delay as u32,
                    &[&duration],
                    u64::from(*sleep),
                    "null",
                );
                Ok(false)
            }
            StatementKind::Unload(handle) => {
                let handle = self.statement_value(statement.offset, handle)?;
                self.object_into(ObjectOp::Unload as u32, &[&handle], 0, "null");
                Ok(false)
            }
            StatementKind::Release(target) => {
                let target = self.binding(target);
                self.object_into(
                    ObjectOp::MutexRelease as u32,
                    &[],
                    self.bindings.slots[&target] as u64,
                    "null",
                );
                Ok(false)
            }
            StatementKind::EventControl { target, signal } => {
                let target = self.binding(target);
                let signal = integer_constant(u64::from(*signal));
                self.object_into(
                    ObjectOp::EventControl as u32,
                    &[&signal],
                    self.bindings.slots[&target] as u64,
                    "null",
                );
                Ok(false)
            }
            StatementKind::Notify(target, value) => {
                let value = self.statement_value(statement.offset, value)?;
                let target = self.binding(target);
                if let Some(&state) = self.bindings.namespace_states.get(&target) {
                    self.check_table_state(state);
                }
                let path = byte_constant(self.strings, target.to_string().as_bytes());
                self.object_into(ObjectOp::Notify as u32, &[&path, &value], 0, "null");
                Ok(false)
            }
            StatementKind::Evaluate(Expression::Call(name, args)) => {
                self.lower_call(name, args, false)
                    .map_err(|err| self.statement_error(statement.offset, &err))?;
                Ok(false)
            }
            StatementKind::Evaluate(expression) => {
                self.statement_value(statement.offset, expression)?;
                Ok(false)
            }
            StatementKind::If {
                predicate,
                body,
                otherwise,
            } => self.lower_if(
                statement.offset,
                predicate,
                body,
                otherwise
                    .as_ref()
                    .map(|block| block.body.as_slice())
                    .unwrap_or_default(),
            ),
            StatementKind::While(predicate, body) => {
                self.lower_while(statement.offset, predicate, body)
            }
            StatementKind::Break | StatementKind::Continue => {
                let blocks = self
                    .loops
                    .last_mut()
                    .expect("parser requires an enclosing While");
                let target = if matches!(statement.kind, StatementKind::Break) {
                    blocks.exit_locals =
                        merge_paths(blocks.exit_locals, Some(self.initialized_locals));
                    blocks.exit.clone()
                } else {
                    blocks.header.clone()
                };
                self.jump(&target);
                Ok(true)
            }
            StatementKind::Noop => Ok(false),
        }
    }

    fn lower_region(&mut self, region: &crate::aml::Region) -> Result<(), String> {
        let base = self.statement_value(region.offset, &region.base)?;
        let length = self.statement_value(region.offset, &region.length)?;
        let path = byte_constant(self.strings, region.name.to_string().as_bytes());
        let address = self.named_object_address(&region.name);
        if let Some(&index) = self.local_objects.get(&region.name) {
            self.local_regions.insert(index);
        }
        self.object_into(
            ObjectOp::RegionCreate as u32,
            &[&base, &length, &path],
            u64::from(region.space),
            &address,
        );
        Ok(())
    }

    fn field_binding(&mut self, name: Option<&AbsolutePath>, payload: &str) -> String {
        let mut index = u64::MAX;
        let mut address = None;
        if let Some(name) = name {
            let target = self.binding(name);
            if let Some(&slot) = self.bindings.slots.get(&target) {
                index = slot as u64;
            } else {
                address = Some(self.named_object_address(&target));
            }
        }
        let binding = self.value(format_args!(
            "insertvalue %aml.value {{ i64 0, ptr null, i64 {index} }}, i64 {payload}, 0"
        ));
        if let Some(address) = address {
            return self.value(format_args!(
                "insertvalue %aml.value {binding}, ptr {address}, 1"
            ));
        }
        binding
    }

    fn lower_region_fields(&mut self, fields: &crate::aml::RegionFields) -> Result<(), String> {
        let (region, selector, data, bank) = match &fields.backing {
            FieldBacking::Region(region) => (Some(region), None, None, "0".into()),
            FieldBacking::Bank(region, selector, value) => {
                let value = self.statement_value(fields.offset, value)?;
                self.require_integer(&value);
                let bank = self.value(format_args!("extractvalue %aml.value {value}, 0"));
                (Some(region), Some(selector), None, bank)
            }
            FieldBacking::Index(index, data) => (None, Some(index), Some(data), "0".into()),
        };
        let bank = self.field_binding(data, &bank);
        for unit in &fields.units {
            let location = self.field_binding(region, &unit.start.to_string());
            let size = self.field_binding(selector, &unit.bits.to_string());
            let address = self.named_object_address(&unit.name);
            self.object_into(
                ObjectOp::RegionFieldCreate as u32,
                &[&location, &size, &bank],
                u64::from(unit.flags),
                &address,
            );
        }
        Ok(())
    }

    fn statement_value(
        &mut self,
        offset: usize,
        expression: &Expression,
    ) -> Result<String, String> {
        self.lower_value(expression)
            .map_err(|err| self.statement_error(offset, &err))
    }

    fn statement_error(&self, offset: usize, error: &str) -> String {
        format!(
            "method {} at file offset {offset:#06x}: {error}",
            self.method.name
        )
    }

    fn branch(&mut self, condition: &str, yes: &str, no: &str) {
        self.instruction(format_args!("br i1 {condition}, label %{yes}, label %{no}"));
    }

    fn truth_value(&mut self, value: &str) -> String {
        let bits = self.width.bits();
        self.value(format_args!("icmp ne i{bits} {value}, 0"))
    }

    fn lower_if(
        &mut self,
        offset: usize,
        predicate: &Expression,
        body: &[Statement],
        otherwise: &[Statement],
    ) -> Result<bool, String> {
        if let Expression::Integer(value) = predicate {
            return self.lower_statements(if value.value(self.width) != 0 {
                body
            } else {
                otherwise
            });
        }
        let value = self.statement_value(offset, predicate)?;
        let value = self.require_integer(&value);
        let condition = self.truth_value(&value);
        let yes = self.label("if.then");
        let no = self.label("if.else");
        let end = self.label("if.end");
        self.branch(&condition, &yes, &no);
        let before = self.initialized_locals;

        self.start_block(&yes);
        self.initialized_locals |= cond_ref_local(predicate, true);
        let yes_locals = self.lower_to_join(body, &end)?;
        self.initialized_locals = before | cond_ref_local(predicate, false);
        self.start_block(&no);
        let no_locals = self.lower_to_join(otherwise, &end)?;
        Ok(self.start_join(&end, merge_paths(yes_locals, no_locals)))
    }

    fn lower_while(
        &mut self,
        offset: usize,
        predicate: &Expression,
        body: &[Statement],
    ) -> Result<bool, String> {
        let header = self.label("while.cond");
        let exit = self.label("while.end");
        let entry = self.label("while.body");
        self.jump(&header);
        self.start_block(&header);
        self.check_budget();
        let exit_locals = if let Expression::Integer(value) = predicate {
            if value.value(self.width) == 0 {
                return Ok(false);
            }
            self.jump(&entry);
            None
        } else {
            let value = self.statement_value(offset, predicate)?;
            let value = self.require_integer(&value);
            let condition = self.truth_value(&value);
            self.branch(&condition, &entry, &exit);
            Some(self.initialized_locals | cond_ref_local(predicate, false))
        };

        // Backedges cannot uninitialize locals, and the first iteration
        // always enters with the state established by the predicate above.
        self.loops.push(LoopBlocks {
            header: header.clone(),
            exit: exit.clone(),
            exit_locals,
        });
        self.start_block(&entry);
        self.initialized_locals |= cond_ref_local(predicate, true);
        self.lower_to_join(body, &header)?;
        let blocks = self.loops.pop().unwrap();
        Ok(self.start_join(&exit, blocks.exit_locals))
    }

    fn lower_to_join(&mut self, body: &[Statement], end: &str) -> Result<Option<u8>, String> {
        if self.lower_statements(body)? {
            return Ok(None);
        }
        self.jump(end);
        Ok(Some(self.initialized_locals))
    }

    fn start_join(&mut self, label: &str, locals: Option<u8>) -> bool {
        if let Some(locals) = locals {
            self.start_block(label);
            self.initialized_locals = locals;
            return false;
        }
        true
    }

    fn pack_integer(&mut self, value: &str) -> String {
        let wide = match self.width {
            IntegerWidth::Bits32 => self.value(format_args!("zext i32 {value} to i64")),
            IntegerWidth::Bits64 => value.to_string(),
        };
        self.value(format_args!(
            "insertvalue %aml.value zeroinitializer, i64 {wide}, 0"
        ))
    }

    fn object_into(&mut self, op: u32, values: &[&str], extra: u64, output: &str) {
        // Track whether this method can allocate runtime objects or acquire
        // mutexes. Non-allocating, mutex-free methods skip the per-call GC and
        // mutex-release walks in the outer wrapper.
        match op {
            op if op == ObjectOp::Buffer as u32
                || op == ObjectOp::String as u32
                || op == ObjectOp::Package as u32
                || op == ObjectOp::FieldCreate as u32
                || op == ObjectOp::RegionCreate as u32
                || op == ObjectOp::RegionFieldCreate as u32
                || op == ObjectOp::NamespaceRef as u32 =>
            {
                self.allocates = true;
            }
            op if op == ObjectOp::MutexAcquire as u32 => {
                self.acquires_mutex = true;
            }
            _ => {}
        }
        let mut pointers = ["null"; 3];
        for ((value, slot), pointer) in values
            .iter()
            .zip(["%object.a", "%object.b", "%object.c"])
            .zip(&mut pointers)
        {
            self.instruction(format_args!("store %aml.value {value}, ptr {slot}"));
            *pointer = slot;
        }
        let [a, b, c] = pointers;
        let extra = if op == ObjectOp::Load as u32 || op == ObjectOp::LoadTable as u32 {
            self.value(format_args!("zext i32 %depth to i64"))
        } else {
            extra.to_string()
        };
        let status = self.value(format_args!("call i32 @aml_object_op(ptr %ctx, ptr {output}, i32 {op}, ptr {a}, ptr {b}, ptr {c}, i64 {extra})"));
        self.check_status(&status);
    }

    fn check_status(&mut self, status: &str) {
        let ok = self.value(format_args!("icmp eq i32 {status}, 0"));
        let success = self.label("object.ok");
        let failed = self.label("object.error");
        self.branch(&ok, &success, &failed);
        self.start_block(&failed);
        self.return_status(status);
        self.start_block(&success);
    }

    fn object(&mut self, op: u32, values: &[&str], extra: u64) -> String {
        self.object_into(op, values, extra, "%object.result");
        self.value(format_args!("load %aml.value, ptr %object.result"))
    }

    fn lower_string(&mut self, bytes: &[u8]) -> Result<String, String> {
        let source = byte_constant(self.strings, bytes);
        Ok(self.object(ObjectOp::String as u32, &[&source], 0))
    }

    fn payload(&mut self, value: &str) -> String {
        let payload = self.value(format_args!("extractvalue %aml.value {value}, 0"));
        match self.width {
            IntegerWidth::Bits32 => self.value(format_args!("trunc i64 {payload} to i32")),
            IntegerWidth::Bits64 => payload,
        }
    }

    fn require_integer(&mut self, value: &str) -> String {
        let tag = self.value(format_args!("extractvalue %aml.value {value}, 2"));
        let integer = self.value(format_args!("icmp eq i64 {tag}, 0"));
        let valid = self.label("type.ok");
        self.branch(&integer, &valid, "type.error");
        self.start_block(&valid);
        self.has_type_check = true;
        self.payload(value)
    }

    fn lower_value(&mut self, expression: &Expression) -> Result<String, String> {
        let value = match expression {
            Expression::Integer(value) => integer_constant(value.value(self.width)),
            Expression::String(bytes) => self.lower_string(bytes)?,
            Expression::Buffer(size, bytes) => {
                let size = self.lower_value(size)?;
                let size = self.require_integer(&size);
                let size = self.pack_integer(&size);
                let bytes = byte_constant(self.strings, bytes);
                self.object(ObjectOp::Buffer as u32, &[&size, &bytes], 0)
            }
            Expression::Package(size, elements) => {
                let size = self.lower_value(size)?;
                let size = self.require_integer(&size);
                let size = self.pack_integer(&size);
                let package = self.object(ObjectOp::Package as u32, &[&size], 0);
                for (index, element) in elements.iter().enumerate() {
                    let element = self.lower_value(element)?;
                    self.object_into(
                        ObjectOp::PackageElement as u32,
                        &[&package, &element],
                        index as u64,
                        "null",
                    );
                }
                package
            }
            Expression::CreateField {
                name,
                buffer,
                index,
                length,
                mode,
            } => {
                let buffer = self.lower_value(buffer)?;
                let index = self.lower_value(index)?;
                let index = self.require_integer(&index);
                let index = self.pack_integer(&index);
                let length = self.lower_value(length)?;
                let length = self.require_integer(&length);
                let length = self.pack_integer(&length);
                let address = self.named_object_address(name);
                self.object_into(
                    ObjectOp::FieldCreate as u32,
                    &[&buffer, &index, &length],
                    u64::from(*mode),
                    &address,
                );
                integer_constant(0)
            }
            Expression::RegionSource(name) => {
                let address = self.named_object_address(name);
                self.value(format_args!("load %aml.value, ptr {address}"))
            }
            Expression::Field(name) => {
                let address = self.named_object_address(name);
                let field = self.value(format_args!("load %aml.value, ptr {address}"));
                self.object(ObjectOp::Read as u32, &[&field], 0)
            }
            Expression::Local(_) | Expression::Arg(_) | Expression::Name(_) => {
                self.load(expression)?
            }
            Expression::Call(name, args) => self.lower_call(name, args, true)?,
            Expression::UnresolvedCall(name, args) => self.lower_external(name, args)?,
            Expression::Apply(operator, args) => self.lower_operator(operator, args)?,
            Expression::CondRefOf { source, target } => {
                self.lower_cond_ref(source.as_deref(), target)?
            }
            Expression::NamespaceObject(..) => return Err("expected a value expression".into()),
            Expression::NullTarget | Expression::DebugTarget => {
                return Err("expected a value expression".into());
            }
        };
        Ok(value)
    }

    fn lower_external(
        &mut self,
        name: &AbsolutePath,
        args: &[Expression],
    ) -> Result<String, String> {
        let name = name.llvm_suffix();
        let integer_intrinsic = match name.as_str() {
            "XMEM" => Some(("acpi_read_memory", 2)),
            "XMAP" => Some(("acpi_page_range", 2)),
            "XCR3" => Some(("acpi_page_root", 0)),
            "XPIO" => Some(("acpi_port_io", 3)),
            "XDWD" => Some(("acpi_mmio_dword", 2)),
            "XFBQ" => Some(("acpi_framebuffer_info", 1)),
            "XPRW" => Some(("acpi_pixel_row", 4)),
            "XFBL" => Some(("acpi_framebuffer_blit", 3)),
            "XAPC" => Some(("acpi_has_apic", 0)),
            "XCPU" => Some(("acpi_online_cpu_count", 0)),
            "XIDX" => Some(("acpi_current_cpu_id", 0)),
            "XFLT" => Some(("acpi_last_fault_vector", 0)),
            "XFRP" => Some(("acpi_last_fault_rip", 0)),
            "XSMP" => Some(("acpi_smp_initialize", 4)),
            "XSCT" => Some(("acpi_smp_timer", 3)),
            "XSGO" => Some(("acpi_smp_release", 0)),
            "XSTP" => Some(("acpi_schedule_step", 0)),
            "XSUL" => Some(("acpi_scheduler_unlock", 0)),
            "XSLK" => Some(("acpi_scheduler_lock", 0)),
            "XMSR" => Some(("acpi_apic_msr", 2)),
            "XWAI" => Some(("acpi_wait_irq", 1)),
            "XRUN" => Some(("acpi_run_task", 5)),
            "XIMG" => Some(("acpi_image_word", 2)),
            "XCPY" => Some(("acpi_image_copy", 3)),
            "XMOV" => Some(("acpi_copy_memory", 3)),
            "XBYT" => Some(("acpi_virtual_byte", 1)),
            "XSTB" => Some(("acpi_store_byte", 2)),
            "XTRG" => Some(("acpi_load_tr", 1)),
            "XCLR" => Some(("acpi_clear_page", 1)),
            "XINV" => Some(("acpi_invalidate_page", 1)),
            _ => None,
        };
        if !self.bindings.freestanding
            || (integer_intrinsic.is_none()
                && !matches!(name.as_str(), "XADR" | "XGDT" | "XIDT" | "XHND" | "XBRK"))
        {
            for arg in args {
                self.lower_value(arg)?;
            }
            return Ok(self.object(ObjectOp::UnresolvedExternal as u32, &[], 0));
        }
        if !matches!(self.width, IntegerWidth::Bits64) {
            return Err("x86 kernel intrinsics require 64-bit AML integers".into());
        }
        let arity = match name.as_str() {
            "XGDT" => 3,
            "XADR" | "XIDT" => 1,
            _ => integer_intrinsic.map_or(0, |(_, arity)| arity),
        };
        if args.len() != arity {
            return Err(format!("{name} requires {arity} argument(s)"));
        }
        if let Some((symbol, _)) = integer_intrinsic {
            let mut operands = Vec::with_capacity(arity);
            for arg in args {
                let value = self.lower_value(arg)?;
                operands.push(format!("i64 {}", self.require_integer(&value)));
            }
            let types = vec!["i64"; arity].join(", ");
            self.intrinsics
                .insert(format!("declare i64 @{symbol}({types})"));
            let operands = operands.join(", ");
            let value = self.value(format_args!("call i64 @{symbol}({operands})"));
            return Ok(self.pack_integer(&value));
        }
        if arity != 0 {
            let value = self.lower_value(&args[0])?;
            let tag = self.value(format_args!("extractvalue %aml.value {value}, 2"));
            let is_buffer = self.value(format_args!("icmp eq i64 {tag}, 3"));
            let valid = if name == "XADR" {
                is_buffer
            } else {
                let size = self.value(format_args!("extractvalue %aml.value {value}, 0"));
                let fits = self.value(format_args!("icmp eq i64 {size}, 10"));
                self.value(format_args!("and i1 {is_buffer}, {fits}"))
            };
            let ready = self.label("x86.buffer");
            self.branch(&valid, &ready, "type.error");
            self.start_block(&ready);
            self.has_type_check = true;
            let data = self.value(format_args!("extractvalue %aml.value {value}, 1"));
            return match name.as_str() {
                "XADR" => {
                    let address = self.value(format_args!("ptrtoint ptr {data} to i64"));
                    Ok(self.pack_integer(&address))
                }
                "XGDT" => {
                    let code = self.lower_value(&args[1])?;
                    let code = self.require_integer(&code);
                    let segments = self.lower_value(&args[2])?;
                    let segments = self.require_integer(&segments);
                    self.intrinsics
                        .insert("declare void @acpi_load_gdt(ptr, i64, i64)".into());
                    self.instruction(format_args!(
                        "call void @acpi_load_gdt(ptr {data}, i64 {code}, i64 {segments})"
                    ));
                    Ok(integer_constant(0))
                }
                _ => {
                    self.instruction(format_args!(
                        "call void asm sideeffect \"lidt ($0)\", \"r,~{{memory}}\"(ptr {data})"
                    ));
                    Ok(integer_constant(0))
                }
            };
        }
        if !self.bindings.breakpoint_handler {
            return Err(format!(
                "{name} requires a static one-argument \\BRKP method"
            ));
        }
        if name == "XHND" {
            self.intrinsics
                .insert("declare void @acpi_breakpoint_entry()".into());
            let address = self.value(format_args!("ptrtoint ptr @acpi_breakpoint_entry to i64"));
            return Ok(self.pack_integer(&address));
        }
        self.intrinsics
            .insert("declare i32 @acpi_trigger_breakpoint(ptr)".into());
        let status = self.value(format_args!("call i32 @acpi_trigger_breakpoint(ptr %ctx)"));
        self.check_status(&status);
        Ok(integer_constant(0))
    }

    fn lower_call(
        &mut self,
        name: &AbsolutePath,
        args: &[Expression],
        needs_value: bool,
    ) -> Result<String, String> {
        let args = args
            .iter()
            .map(|arg| self.lower_value(arg))
            .collect::<Result<Vec<_>, _>>()?;
        let name = self.binding(name);
        if name.is_osi() {
            return Ok(self.object(ObjectOp::Osi as u32, &[&args[0]], 0));
        }
        let mut operands = String::new();
        for value in args {
            write!(operands, ", %aml.value {value}").unwrap();
        }
        let name = name.llvm_suffix();
        let depth = self.value(format_args!("add i32 %depth, 1"));
        let status = self.value(format_args!(
            "call i32 @aml.impl.{name}(ptr %ctx, ptr %call.result, i32 {depth}{operands})"
        ));
        let success = self.value(format_args!("icmp eq i32 {status}, 0"));
        let valid = self.label("call.ok");
        let error = self.label("call.error");
        self.branch(&success, &valid, &error);
        self.start_block(&error);
        self.return_status(&status);
        self.start_block(&valid);
        if !needs_value {
            return Ok(String::new());
        }
        let value = self.value(format_args!("load %aml.value, ptr %call.result"));
        let tag = self.value(format_args!("extractvalue %aml.value {value}, 2"));
        let present = self.value(format_args!("icmp ne i64 {tag}, {NO_RETURN_TYPE}"));
        let valid = self.label("result.present");
        let missing = self.label("result.missing");
        self.branch(&present, &valid, &missing);
        self.start_block(&missing);
        self.return_status(&NO_RETURN_STATUS.to_string());
        self.start_block(&valid);
        Ok(value)
    }

    fn lower_cond_ref(
        &mut self,
        source: Option<&Expression>,
        target: &Expression,
    ) -> Result<String, String> {
        let Some(source) = source else {
            return Ok(integer_constant(0));
        };
        let true_value = IntegerLiteral::Ones.value(self.width);
        let available = self.conditional_reference_available(source);
        let absent = self.label("condref.absent");
        let end = self.label("condref.end");
        let before = self.initialized_locals;
        if let Some(available) = &available {
            let present = self.label("condref.present");
            self.branch(available, &present, &absent);
            self.start_block(&present);
        }
        if matches!(target, Expression::NullTarget) {
            if matches!(source, Expression::Apply(..)) {
                self.reference_operand(source, false)?;
            }
        } else {
            let reference = if let Expression::NamespaceObject(name, kind) = source {
                let state = self.namespace_reference_state(name);
                self.binding(name);
                let kind = integer_constant(u64::from(*kind));
                self.object(ObjectOp::NamespaceRef as u32, &[&kind], state)
            } else {
                self.reference_operand(source, true)?
            };
            self.store(target, &reference, false)?;
        }
        if let Some(available) = available {
            self.jump(&end);
            self.start_block(&absent);
            self.jump(&end);
            self.start_block(&end);
            self.initialized_locals = before;
            let result = self.value(format_args!(
                "select i1 {available}, i64 {true_value}, i64 0"
            ));
            return Ok(self.value(format_args!(
                "insertvalue %aml.value zeroinitializer, i64 {result}, 0"
            )));
        }
        Ok(integer_constant(true_value))
    }

    fn namespace_reference_state(&self, name: &AbsolutePath) -> u64 {
        let mut name = name;
        while let Some(alias) = self.bindings.aliases.get(name) {
            if let Some(state) = alias.state {
                return state as u64;
            }
            name = &alias.target;
        }
        self.bindings
            .namespace_states
            .get(name)
            .map_or(u64::MAX, |&state| state as u64)
    }

    fn conditional_reference_available(&mut self, source: &Expression) -> Option<String> {
        let (mut name, opaque) = match source {
            Expression::Name(name) | Expression::Field(name) | Expression::RegionSource(name) => {
                (name, false)
            }
            Expression::NamespaceObject(name, _) => (name, true),
            _ => return None,
        };
        let mut states = Vec::new();
        while let Some(alias) = self.bindings.aliases.get(name) {
            states.extend(alias.state);
            name = &alias.target;
        }
        if let Some(&state) = self.bindings.namespace_states.get(name) {
            states.push(state);
        }
        let mut available = None;
        for state in states {
            let active = self.value(format_args!(
                "call i1 @aml_table_active(ptr %ctx, i64 {state})"
            ));
            available = Some(match available {
                Some(previous) => self.value(format_args!("and i1 {previous}, {active}")),
                None => active,
            });
        }
        if !opaque
            && let Some(&slot) = self.bindings.slots.get(name)
            && slot >= self.bindings.static_slots
        {
            let address = self.value(format_args!(
                "call ptr @aml_dynamic_slot(ptr %ctx, i64 {slot})"
            ));
            let exists = self.value(format_args!("icmp ne ptr {address}, null"));
            available = Some(match available {
                Some(previous) => self.value(format_args!("and i1 {previous}, {exists}")),
                None => exists,
            });
        }
        if !opaque && !self.bindings.slots.contains_key(name) {
            let address = self.named_object_address(name);
            let field = self.value(format_args!("load %aml.value, ptr {address}"));
            let kind = self.value(format_args!("extractvalue %aml.value {field}, 2"));
            return Some(self.value(format_args!("icmp ne i64 {kind}, 260")));
        }
        available
    }

    fn lower_operator(
        &mut self,
        operator: &Operator,
        args: &[Expression],
    ) -> Result<String, String> {
        use Operator::*;
        let bits = self.width.bits();
        let value = match (operator, args) {
            (Load, [source, target]) => {
                let source = self.lower_value(source)?;
                let handle = self.object(ObjectOp::Load as u32, &[&source], 0);
                self.store(target, &handle, false)?;
                return Ok(handle);
            }
            (LoadTable, [signature, oem, table, root, parameter, data]) => {
                let signature = self.lower_value(signature)?;
                let oem = self.lower_value(oem)?;
                let table = self.lower_value(table)?;
                let root = self.lower_value(root)?;
                let parameter = self.lower_value(parameter)?;
                self.lower_value(data)?;
                self.object_into(ObjectOp::LoadPaths as u32, &[&root, &parameter], 0, "null");
                return Ok(self.object(ObjectOp::LoadTable as u32, &[&signature, &oem, &table], 0));
            }
            (Acquire(target, _), []) => {
                let target = self.binding(target);
                return Ok(self.object(
                    ObjectOp::MutexAcquire as u32,
                    &[],
                    self.bindings.slots[&target] as u64,
                ));
            }
            (Wait(target), [timeout]) => {
                let timeout = self.lower_value(timeout)?;
                let target = self.binding(target);
                let path = byte_constant(self.strings, target.to_string().as_bytes());
                return Ok(self.object(
                    ObjectOp::EventWait as u32,
                    &[&path, &timeout],
                    self.bindings.slots[&target] as u64,
                ));
            }
            (Timer, []) => return Ok(self.object(ObjectOp::Timer as u32, &[], 0)),
            (Store | CopyObject, [source, target]) => {
                let value = self.lower_value(source)?;
                self.store(target, &value, matches!(operator, CopyObject))?;
                return Ok(value);
            }
            (RefOf, [source]) => return self.reference_operand(source, true),
            (DerefOf, [Expression::Apply(Index, operands)])
                if matches!(operands.as_slice(), [_, _, Expression::NullTarget]) =>
            {
                let (source, index) = self.binary_objects(&operands[0], &operands[1])?;
                let index = self.require_integer(&index);
                let index = self.pack_integer(&index);
                return Ok(self.object(ObjectOp::IndexRead as u32, &[&source, &index], 0));
            }
            (DerefOf, [source]) => {
                let source = self.lower_value(source)?;
                return Ok(self.object(0x83, &[&source], 0));
            }
            (Index, [source, index, target]) => {
                let (source, index) = self.binary_objects(source, index)?;
                let index = self.require_integer(&index);
                let index = self.pack_integer(&index);
                let reference = self.object(0x88, &[&source, &index], 0);
                self.store(target, &reference, false)?;
                return Ok(reference);
            }
            (Concatenate, [left, right, target]) => {
                let (left, right) = self.binary_objects(left, right)?;
                let destination = self.indirect_target(target)?;
                let result = self.object(0x73, &[&left, &right], 0);
                self.store_result(target, destination.as_deref(), &result)?;
                return Ok(result);
            }
            (Mid, [source, index, length, target]) => {
                let value = if matches!(source, Expression::Name(_)) {
                    None
                } else {
                    Some(self.lower_value(source)?)
                };
                let index = self.lower_value(index)?;
                let index = self.require_integer(&index);
                let index = self.pack_integer(&index);
                let length = self.lower_value(length)?;
                let length = self.require_integer(&length);
                let length = self.pack_integer(&length);
                let destination = self.indirect_target(target)?;
                let source = match value {
                    Some(value) => value,
                    None => self.lower_value(source)?,
                };
                let result = self.object(0x9e, &[&source, &index, &length], 0);
                self.store_result(target, destination.as_deref(), &result)?;
                return Ok(result);
            }
            (NamespaceType(name, object_type), []) => {
                let name = self.binding(name);
                if let Some(&state) = self.bindings.namespace_states.get(&name) {
                    self.check_table_state(state);
                } else if let Some(&index) = self.bindings.slots.get(&name) {
                    self.named_address(index);
                } else if *object_type == 10 {
                    let address = self.named_object_address(&name);
                    let region = self.value(format_args!("load %aml.value, ptr {address}"));
                    return Ok(self.object(ObjectOp::Type as u32, &[&region], 0));
                }
                return Ok(integer_constant(u64::from(*object_type)));
            }
            (SizeOf | ObjectType, [source]) => {
                let source = self.raw_value(source, matches!(operator, ObjectType))?;
                let op = if matches!(operator, SizeOf) {
                    0x87
                } else {
                    ObjectOp::Type as u32
                };
                return Ok(self.object(op, &[&source], 0));
            }
            (Convert(op), [source, target]) => {
                let source = self.lower_value(source)?;
                let result = self.object(u32::from(*op), &[&source], 0);
                self.store(target, &result, false)?;
                return Ok(result);
            }
            (Convert(op), [source, length, target]) => {
                let (source, length) = self.binary_objects(source, length)?;
                let length = self.require_integer(&length);
                let length = self.pack_integer(&length);
                let result = self.object(u32::from(*op), &[&source, &length], 0);
                self.store(target, &result, false)?;
                return Ok(result);
            }
            (LAnd | LOr | LEqual | LGreater | LLess, [lhs, rhs]) => {
                let (lhs, rhs) = self.binary_objects(lhs, rhs)?;
                let op = match operator {
                    LAnd => 0x90,
                    LOr => 0x91,
                    LEqual => 0x93,
                    LGreater => 0x94,
                    _ => 0x95,
                };
                return Ok(self.object(op, &[&lhs, &rhs], 0));
            }
            (Increment | Decrement, [target]) => {
                let reference = self.reference_operand(target, false)?;
                let op = if matches!(operator, Increment) {
                    0x75
                } else {
                    0x76
                };
                return Ok(self.object(op, &[&reference], 0));
            }
            (LNot, [source]) => {
                let source = self.lower_value(source)?;
                let source = self.require_integer(&source);
                let comparison = self.value(format_args!("icmp eq i{bits} {source}, 0"));
                self.value(format_args!("sext i1 {comparison} to i{bits}"))
            }
            (Not | FindSetLeftBit | FindSetRightBit, [source, target]) => {
                let source = self.lower_value(source)?;
                let source = self.require_integer(&source);
                let value = match operator {
                    Not => self.complement(&source),
                    _ => self.find_set_bit(&source, matches!(operator, FindSetLeftBit)),
                };
                self.store_integer(target, &value)?;
                value
            }
            (Divide, [lhs, rhs, remainder_target, quotient_target]) => {
                let (lhs, rhs) = self.binary_values(lhs, rhs)?;
                self.check_divisor(&rhs);
                let quotient = self.value(format_args!("udiv i{bits} {lhs}, {rhs}"));
                let remainder = self.value(format_args!("urem i{bits} {lhs}, {rhs}"));
                // The result is the quotient. uACPI writes the quotient
                // first, so an aliased target ends up holding the remainder.
                self.store_integer(quotient_target, &quotient)?;
                self.store_integer(remainder_target, &remainder)?;
                quotient
            }
            (operator, [lhs, rhs, target]) => {
                let (lhs, rhs) = self.binary_values(lhs, rhs)?;
                let opcode = match operator {
                    Add => "add",
                    Subtract => "sub",
                    Multiply => "mul",
                    And | Nand => "and",
                    Or | Nor => "or",
                    Xor => "xor",
                    ShiftLeft => "shl",
                    ShiftRight => "lshr",
                    Mod => "urem",
                    _ => return Err(format!("invalid operands for {operator:?}")),
                };
                if matches!(operator, Mod) {
                    self.check_divisor(&rhs);
                }
                let value = if matches!(operator, ShiftLeft | ShiftRight) {
                    let in_range = self.value(format_args!("icmp ult i{bits} {rhs}, {bits}"));
                    let mask = bits - 1;
                    let count = self.value(format_args!("and i{bits} {rhs}, {mask}"));
                    let shifted = self.value(format_args!("{opcode} i{bits} {lhs}, {count}"));
                    self.value(format_args!(
                        "select i1 {in_range}, i{bits} {shifted}, i{bits} 0"
                    ))
                } else {
                    self.value(format_args!("{opcode} i{bits} {lhs}, {rhs}"))
                };
                let value = if matches!(operator, Nand | Nor) {
                    self.complement(&value)
                } else {
                    value
                };
                self.store_integer(target, &value)?;
                value
            }
            _ => return Err(format!("invalid operands for {operator:?}")),
        };
        Ok(self.pack_integer(&value))
    }

    fn check_budget(&mut self) {
        // Trusted freestanding kernel code owns its lifetime and idle loop.
        if self.bindings.freestanding {
            return;
        }
        let available = self.value(format_args!("call i1 @aml.consume_step(ptr %ctx)"));
        let valid = self.label("budget.ok");
        self.branch(&available, &valid, "limit.error");
        self.start_block(&valid);
    }

    fn check_divisor(&mut self, divisor: &str) {
        let nonzero = self.truth_value(divisor);
        let valid = self.label("division.ok");
        self.branch(&nonzero, &valid, "division.error");
        self.start_block(&valid);
        self.has_division = true;
    }

    fn complement(&mut self, value: &str) -> String {
        let bits = self.width.bits();
        self.value(format_args!("xor i{bits} {value}, -1"))
    }

    fn find_set_bit(&mut self, source: &str, left: bool) -> String {
        let bits = self.width.bits();
        let scan = if left { "ctlz" } else { "cttz" };
        let intrinsic = format!("@llvm.{scan}.i{bits}");
        self.intrinsics
            .insert(format!("declare i{bits} {intrinsic}(i{bits}, i1 immarg)"));
        let count = self.value(format_args!(
            "call i{bits} {intrinsic}(i{bits} {source}, i1 false)"
        ));
        if left {
            return self.value(format_args!("sub i{bits} {bits}, {count}"));
        }
        let position = self.value(format_args!("add i{bits} {count}, 1"));
        let nonzero = self.truth_value(source);
        self.value(format_args!(
            "select i1 {nonzero}, i{bits} {position}, i{bits} 0"
        ))
    }

    fn binary_values(
        &mut self,
        lhs: &Expression,
        rhs: &Expression,
    ) -> Result<(String, String), String> {
        let (left, right) = self.binary_objects(lhs, rhs)?;
        Ok((self.require_integer(&left), self.require_integer(&right)))
    }

    fn binary_objects(
        &mut self,
        lhs: &Expression,
        rhs: &Expression,
    ) -> Result<(String, String), String> {
        // A named integer operand retains the object until the operator reads
        // it. Evaluating the right operand can mutate that same object.
        let (left, right) = if matches!(lhs, Expression::Name(_)) {
            let right = self.lower_value(rhs)?;
            (self.lower_value(lhs)?, right)
        } else {
            let left = self.lower_value(lhs)?;
            (left, self.lower_value(rhs)?)
        };
        Ok((left, right))
    }

    fn reference_operand(&mut self, target: &Expression, escapes: bool) -> Result<String, String> {
        match target {
            Expression::Apply(Operator::Index | Operator::RefOf, _) => {
                return self.lower_value(target);
            }
            Expression::Apply(Operator::DerefOf, args) => return self.lower_value(&args[0]),
            Expression::Local(index) if escapes => self.referenced_locals |= 1 << index,
            Expression::Arg(index) if escapes && *index < self.method.arg_count() => {
                self.referenced_args |= 1 << index;
            }
            _ => {}
        }
        if let Expression::Name(name) | Expression::Field(name) = target {
            self.binding(name);
            if let Some(index) = self.alias_reference_target(name) {
                return Ok(self.named_reference(index));
            }
        }
        let slot = self.slot_address(target)?;
        Ok(self.value(format_args!(
            "insertvalue %aml.value {{ i64 0, ptr null, i64 256 }}, ptr {slot}, 1"
        )))
    }

    fn alias_reference_target(&self, name: &AbsolutePath) -> Option<usize> {
        let mut name = name;
        loop {
            if let Some(&index) = self.bindings.slots.get(name) {
                return Some(index);
            }
            name = &self.bindings.aliases.get(name)?.target;
        }
    }

    fn named_reference(&mut self, index: usize) -> String {
        let slot = self.named_address(index);
        let storage = if index < self.bindings.static_slots {
            1
        } else {
            2
        };
        self.value(format_args!(
            "insertvalue %aml.value {{ i64 {storage}, ptr null, i64 256 }}, ptr {slot}, 1"
        ))
    }

    fn slot_address(&mut self, slot: &Expression) -> Result<String, String> {
        match slot {
            Expression::Local(index) => {
                self.used_locals |= 1 << index;
                Ok(format!("%local{index}"))
            }
            Expression::Arg(index) if *index < self.method.arg_count() => {
                Ok(format!("%arg{index}.addr"))
            }
            Expression::Arg(index) => Err(format!("Arg{index} is outside the method signature")),
            Expression::Name(name) | Expression::Field(name) | Expression::RegionSource(name) => {
                Ok(self.named_object_address(name))
            }
            _ => Err("expected a local, argument, or named value slot".into()),
        }
    }

    fn check_table(&mut self, available: &str) {
        let valid = self.label("table.available");
        self.branch(available, &valid, "table.unavailable");
        self.start_block(&valid);
        self.has_table_check = true;
    }

    fn check_table_state(&mut self, state: usize) {
        let active = self.value(format_args!(
            "call i1 @aml_table_active(ptr %ctx, i64 {state})"
        ));
        self.check_table(&active);
    }

    fn binding(&mut self, name: &AbsolutePath) -> AbsolutePath {
        let mut target = name;
        while let Some(alias) = self.bindings.aliases.get(target) {
            if let Some(state) = alias.state {
                self.check_table_state(state);
            }
            target = &alias.target;
        }
        target.clone()
    }

    fn named_address(&mut self, index: usize) -> String {
        if index >= self.bindings.static_slots {
            let address = self.value(format_args!(
                "call ptr @aml_dynamic_slot(ptr %ctx, i64 {index})"
            ));
            let loaded = self.value(format_args!("icmp ne ptr {address}, null"));
            self.check_table(&loaded);
            return address;
        }

        self.value(format_args!(
            "getelementptr inbounds %aml.context, ptr %ctx, i32 0, i32 9, i64 {index}"
        ))
    }

    fn named_object_address(&mut self, name: &AbsolutePath) -> String {
        let name = self.binding(name);
        if let Some(&index) = self.bindings.slots.get(&name) {
            return self.named_address(index);
        }
        let next = self.local_objects.len();
        let index = self.local_objects.entry(name).or_insert(next);
        format!("%field{index}")
    }

    fn raw_value(
        &mut self,
        slot: &Expression,
        allow_uninitialized: bool,
    ) -> Result<String, String> {
        if matches!(
            slot,
            Expression::Local(_) | Expression::Arg(_) | Expression::Name(_) | Expression::Field(_)
        ) {
            if !allow_uninitialized {
                return self.load(slot);
            }
            let address = self.slot_address(slot)?;
            return Ok(self.value(format_args!("load %aml.value, ptr {address}")));
        }
        self.lower_value(slot)
    }

    fn load(&mut self, slot: &Expression) -> Result<String, String> {
        let address = self.slot_address(slot)?;
        let value = self.value(format_args!("load %aml.value, ptr {address}"));
        let check = match slot {
            Expression::Name(_) => true,
            Expression::Local(index) => self.initialized_locals & (1 << index) == 0,
            _ => false,
        };
        if check {
            return Ok(self.object(ObjectOp::Read as u32, &[&value], 0));
        }
        Ok(value)
    }

    fn store_integer(&mut self, slot: &Expression, value: &str) -> Result<(), String> {
        let value = self.pack_integer(value);
        self.store(slot, &value, false)
    }

    fn indirect_target(&mut self, target: &Expression) -> Result<Option<String>, String> {
        if matches!(target, Expression::Apply(..)) {
            return self.reference_operand(target, false).map(Some);
        }
        Ok(None)
    }

    fn store_result(
        &mut self,
        target: &Expression,
        reference: Option<&str>,
        value: &str,
    ) -> Result<(), String> {
        if let Some(reference) = reference {
            self.object_into(ObjectOp::StoreRef as u32, &[value, reference], 0, "null");
            return Ok(());
        }
        self.store(target, value, false)
    }

    fn store(&mut self, slot: &Expression, value: &str, copy: bool) -> Result<(), String> {
        // Debug evaluates the source and discards the resulting diagnostic value.
        if matches!(slot, Expression::NullTarget | Expression::DebugTarget) {
            return Ok(());
        }
        if matches!(slot, Expression::Apply(_, _)) {
            let reference = self.reference_operand(slot, false)?;
            self.object_into(ObjectOp::StoreRef as u32, &[value, &reference], 0, "null");
            return Ok(());
        }
        let address = self.slot_address(slot)?;
        let op = match slot {
            Expression::Field(_) => ObjectOp::StoreNamed,
            _ if copy => ObjectOp::CopySlot,
            Expression::Name(_) => ObjectOp::StoreNamed,
            _ => ObjectOp::StoreSlot,
        };
        let extra = u64::from(matches!(slot, Expression::Arg(_)));
        self.object_into(op as u32, &[value], extra, &address);
        if let Expression::Local(index) = slot {
            self.initialized_locals |= 1 << index;
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::aml::parse_table;

    fn emit_method(body: &[u8]) -> Result<String, String> {
        let mut bytes = include_bytes!("../example.aml")[..36].to_vec();
        let package_length = u8::try_from(6 + body.len()).unwrap();
        assert!(package_length < 64);
        bytes.extend_from_slice(&[0x14, package_length, b'T', b'E', b'S', b'T', 1]);
        bytes.extend_from_slice(body);
        let length = u32::try_from(bytes.len()).unwrap();
        bytes[4..8].copy_from_slice(&length.to_le_bytes());
        bytes[9] = 0;
        bytes[9] = 0u8.wrapping_sub(bytes.iter().copied().fold(0, u8::wrapping_add));
        let table = parse_table(&bytes).unwrap();
        let width = table.integer_width();
        emit(&[table], width, 1, false)
    }

    #[test]
    fn if_join_checks_only_paths_that_fall_through() {
        let mut body = [
            0xa0, 4, 0x68, 0xa4, 0x01, // If (Arg0) { Return (One) }
            0xa1, 4, 0x70, 0x01, 0x60, // Else { Store (One, Local0) }
            0xa4, 0x60, // Return (Local0)
            0xa4, 0x61, // Unreachable Return (Local1)
        ];
        let ir = emit_method(&body).unwrap();
        assert!(ir.contains("if.end"));
        assert!(!ir.contains("%local1"));

        body[3..5].copy_from_slice(&[0xa3, 0xa3]); // Replace the first Return with Noops.
        assert!(!ir.contains("i32 257, ptr"));
        let ir = emit_method(&body).unwrap();
        assert!(ir.contains("i32 257, ptr"));
    }

    #[test]
    fn loop_exit_merges_breaks_and_the_predicate_false_edge() {
        let mut body = [
            0xa2, 6, 0x01, 0x70, 0x01, 0x60,
            0xa5, // While (One) { Store (One, Local0); Break }
            0xa4, 0x60, // Return (Local0)
        ];
        let ir = emit_method(&body).unwrap();
        assert!(ir.contains("br label %while.end"));
        body[2] = 0x68; // An Arg0 predicate can skip the initialization.
        assert!(!ir.contains("i32 257, ptr"));
        let ir = emit_method(&body).unwrap();
        assert!(ir.contains("i32 257, ptr"));
    }
}
