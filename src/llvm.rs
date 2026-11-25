//! Lowers parsed AML tables to an LLVM module through the LLVM C API.

use std::collections::{BTreeSet, HashMap, HashSet};

use crate::aml::{
    AbsolutePath, Declaration, Expression, FieldBacking, IntegerLiteral, IntegerWidth, Literal,
    Method, NamedValue, Operator, Statement, StatementKind, Table,
};
use crate::intrinsics::{self, AtomicOp, Intrinsic, Manifest, Width};
use crate::ir::{self, Block, Builder, Context, Module, Type, Value};
use crate::opt::{self, Facts, MethodFacts};

const NO_RETURN_TYPE: u64 = 0x110;
const NO_RETURN_STATUS: u32 = 14;
const REFERENCE_TYPE: u64 = 0x100;
const UNINITIALIZED_TYPE: u64 = 260;
const DYNAMIC_SLOT_TYPE: u64 = 264;

// Runtime status codes used directly by generated code.
const DIVISION_BY_ZERO: u32 = 1;
const EXECUTION_LIMIT: u32 = 2;
const TYPE_MISMATCH: u32 = 4;
const OUT_OF_MEMORY: u32 = 6;
const UNINITIALIZED: u32 = 7;
const SYNC_LEVEL_TOO_HIGH: u32 = 8;
const TABLE_NOT_LOADED: u32 = 10;
const INVALID_ARGUMENT: u32 = 3;
/// Internal status of an integer-returning method that reached its end
/// without a `Return`. It never escapes to the host: callers either treat it
/// as success or, when they need the value, as `AML_NO_RETURN`.
const FELL_THROUGH: u32 = 0x7fff_ffff;

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
    intrinsics: Manifest,
}

impl Bindings {
    fn resolve(&self, name: &AbsolutePath) -> AbsolutePath {
        let mut target = name;
        while let Some(alias) = self.aliases.get(target) {
            target = &alias.target;
        }
        target.clone()
    }
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

/// LLVM types shared by the whole module.
#[derive(Clone, Copy)]
struct Types<'c> {
    void: Type<'c>,
    i1: Type<'c>,
    i8: Type<'c>,
    i32: Type<'c>,
    i64: Type<'c>,
    ptr: Type<'c>,
    /// The AML integer type: `i32` for revision 1 tables, otherwise `i64`.
    int: Type<'c>,
    /// `%aml.value = { i64 integer_or_length, ptr data, i64 type }`.
    value: Type<'c>,
    context: Type<'c>,
}

/// An internal calling convention specialized to what analysis proved:
/// `(ctx, [result], depth, args...)`. Scalar arguments travel as bare `i64`
/// payloads instead of tagged values. Integer-returning methods return
/// `{ i32 status, i64 value }` in registers instead of writing `result`, and
/// report reaching their end without a `Return` as `FELL_THROUGH`.
#[derive(Clone, Copy, PartialEq, Eq)]
struct Signature {
    arg_count: usize,
    scalar_args: u8,
    returns_integer: bool,
    /// Whether the body can reach its end without a `Return`.
    falls_through: bool,
}

impl Signature {
    /// Module-level initializers keep the general convention.
    const INITIALIZER: Signature = Signature {
        arg_count: 0,
        scalar_args: 0,
        returns_integer: false,
        falls_through: true,
    };

    fn scalar(self, index: usize) -> bool {
        index < 8 && self.scalar_args & (1 << index) != 0
    }

    fn depth_param(self) -> u32 {
        if self.returns_integer { 1 } else { 2 }
    }

    fn first_arg_param(self) -> u32 {
        self.depth_param() + 1
    }

    fn param_count(self) -> usize {
        self.first_arg_param() as usize + self.arg_count
    }
}

/// Module-wide code generation state.
struct Codegen<'c> {
    llvm: &'c Context,
    module: Module<'c>,
    types: Types<'c>,
    width: IntegerWidth,
    bindings: Bindings,
    facts: Facts,
    strings: HashMap<Vec<u8>, Value<'c>>,
    /// Internal calling conventions, keyed by implementation symbol.
    signatures: HashMap<String, Signature>,
}

impl<'c> Codegen<'c> {
    fn runtime(&self, name: &str, ret: Type<'c>, params: &[Type<'c>]) -> Value<'c> {
        self.module
            .declare(name, ret.function(params))
            .expect("runtime declarations are consistent")
    }

    fn object_op(&self) -> Value<'c> {
        let t = self.types;
        self.runtime(
            "aml_object_op",
            t.i32,
            &[t.ptr, t.ptr, t.i32, t.ptr, t.ptr, t.ptr, t.i64],
        )
    }

    /// The internal calling convention described by `signature`.
    fn implementation_type(&self, signature: Signature) -> Type<'c> {
        let t = self.types;
        let mut params = vec![t.ptr];
        if !signature.returns_integer {
            params.push(t.ptr);
        }
        params.push(t.i32);
        params.extend((0..signature.arg_count).map(|index| {
            if signature.scalar(index) {
                t.i64
            } else {
                t.value
            }
        }));
        self.status_type(signature).function(&params)
    }

    /// What an implementation returns: a status, with the integer result
    /// alongside it for integer-returning methods.
    fn status_type(&self, signature: Signature) -> Type<'c> {
        let t = self.types;
        if signature.returns_integer {
            self.llvm.struct_type(&[t.i32, t.i64])
        } else {
            t.i32
        }
    }

    /// The return value carrying a failure `status` (or an empty success).
    fn status_constant(&self, signature: Signature, status: u32) -> Value<'c> {
        let llvm = self.llvm;
        if signature.returns_integer {
            llvm.const_struct(
                self.status_type(signature),
                &[llvm.i32(status), llvm.i64(0)],
            )
        } else {
            llvm.i32(status)
        }
    }

    fn signature(&self, name: &str) -> Result<Signature, String> {
        self.signatures
            .get(name)
            .copied()
            .ok_or_else(|| format!("{name} is not a method of these tables"))
    }

    fn declare_implementation(
        &mut self,
        name: &str,
        signature: Signature,
    ) -> Result<Value<'c>, String> {
        self.signatures.insert(name.to_owned(), signature);
        self.implementation(name)
    }

    /// The host calling convention: `(ctx, result, i64 args...)`.
    fn export_type(&self, arg_count: usize) -> Type<'c> {
        let t = self.types;
        let mut params = vec![t.ptr, t.ptr];
        params.extend(std::iter::repeat_n(t.i64, arg_count));
        t.i32.function(&params)
    }

    fn implementation(&self, name: &str) -> Result<Value<'c>, String> {
        self.module
            .declare(name, self.implementation_type(self.signature(name)?))
    }

    fn value_constant(&self, payload: u64, data: Value<'c>, tag: u64) -> Value<'c> {
        let llvm = self.llvm;
        llvm.const_struct(self.types.value, &[llvm.i64(payload), data, llvm.i64(tag)])
    }

    fn integer(&self, value: u64) -> Value<'c> {
        self.value_constant(value, self.llvm.null(), 0)
    }

    fn byte_global(&mut self, bytes: &[u8]) -> Value<'c> {
        if let Some(&global) = self.strings.get(bytes) {
            return global;
        }
        let initializer = self.llvm.const_bytes(bytes);
        let ty = self.types.i8.array(bytes.len() as u64 + 1);
        let global = self.module.add_global(
            ty,
            &format!("aml.string.{}", self.strings.len()),
            initializer,
        );
        global.set_linkage(ir::PRIVATE);
        global.set_constant();
        global.set_unnamed_addr();
        self.strings.insert(bytes.to_vec(), global);
        global
    }

    fn byte_constant(&mut self, bytes: &[u8]) -> Value<'c> {
        let symbol = self.byte_global(bytes);
        self.value_constant(bytes.len() as u64, symbol, 2)
    }

    fn ones(&self) -> u64 {
        IntegerLiteral::Ones.value(self.width)
    }
}

/// Builds the IR module for `tables`.
pub fn emit<'c>(
    llvm: &'c Context,
    tables: &[Table],
    width: IntegerWidth,
    static_count: usize,
    freestanding: bool,
    intrinsics: Manifest,
) -> Result<Module<'c>, String> {
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
    let brkp = tables[..static_count]
        .iter()
        .flat_map(|table| &table.declarations)
        .find_map(|decl| match decl {
            Declaration::Method(method)
                if method.name.llvm_suffix() == "BRKP" && method.arg_count() == 1 =>
            {
                Some(method.name.clone())
            }
            _ => None,
        });
    let breakpoint_handler = freestanding && brkp.is_some();
    let bindings = Bindings {
        slots,
        static_slots,
        aliases,
        namespace_states,
        freestanding,
        breakpoint_handler,
        intrinsics,
    };
    let untyped_entries: Vec<_> = brkp.into_iter().filter(|_| breakpoint_handler).collect();
    let facts = opt::analyze(
        tables,
        static_count,
        width,
        |name| bindings.resolve(name),
        &untyped_entries,
    );
    if std::env::var_os("AMLAOT_STATS").is_some() {
        let (locals, args, returns) = facts.summary();
        eprintln!(
            "amlaot: proved {locals} scalar locals, {args} scalar arguments, \
             {returns} integer-returning methods, {} integer named objects, \
             {} methods reachable from initialization",
            facts.integer_names(),
            facts.init_methods()
        );
    }

    let module = llvm.module("aml");
    let ptr = llvm.ptr();
    let i64 = llvm.int(64);
    let value = llvm.named_struct("aml.value", &[i64, ptr, i64]);
    let i32 = llvm.int(32);
    let i8 = llvm.int(8);
    let context = llvm.named_struct(
        "aml.context",
        &[
            i64,
            ptr,
            i64,
            i64,
            i64,
            i32,
            i8,
            llvm.struct_type(&[ptr.array(9), i64]),
            ptr,
            value.array(count as u64),
        ],
    );
    let types = Types {
        void: llvm.void(),
        i1: llvm.int(1),
        i8,
        i32,
        i64,
        ptr,
        int: llvm.int(u32::from(width.bits())),
        value,
        context,
    };
    let mut cg = Codegen {
        llvm,
        module,
        types,
        width,
        bindings,
        facts,
        strings: HashMap::new(),
        signatures: HashMap::new(),
    };

    // Every initializer and method implementation is declared up front so
    // calls and the dynamic table descriptors can refer to them in any order.
    cg.declare_implementation("aml.initialize", Signature::INITIALIZER)?;
    for id in 0..dynamic_count {
        cg.declare_implementation(&format!("aml.initialize.{id}"), Signature::INITIALIZER)?;
    }
    for table in tables {
        for declaration in &table.declarations {
            if let Declaration::Method(method) = declaration {
                let facts = cg.facts.method(&method.name);
                let signature = Signature {
                    arg_count: usize::from(method.arg_count()),
                    scalar_args: facts.map_or(0, |facts| facts.scalar_args),
                    returns_integer: facts.is_some_and(|facts| facts.returns_integer),
                    falls_through: opt::falls_through(&method.body, width),
                };
                cg.declare_implementation(
                    &format!("aml.impl.{}", method.name.llvm_suffix()),
                    signature,
                )?;
            }
        }
    }

    emit_dynamic_tables(&mut cg, tables, static_count, static_slots)?;
    emit_context_functions(&cg, count, static_slots);

    let os_object = Declaration::Name(NamedValue {
        offset: 0,
        name: os_name,
        initializer: Literal::String(b"Microsoft Windows NT".to_vec()),
    });
    emit_initializer(
        &mut cg,
        "aml.initialize",
        std::iter::once(&os_object).chain(
            tables[..static_count]
                .iter()
                .flat_map(|table| &table.declarations),
        ),
    )?;
    for (index, table) in tables.iter().enumerate() {
        let dynamic_index = index.checked_sub(static_count);
        if let Some(id) = dynamic_index {
            emit_initializer(
                &mut cg,
                &format!("aml.initialize.{id}"),
                table.declarations.iter(),
            )?;
        }
        for declaration in &table.declarations {
            if let Declaration::Method(method) = declaration {
                emit_method(&mut cg, method, dynamic_index.map(|id| base_state + id * 2))?;
            }
        }
    }
    if cg.bindings.breakpoint_handler {
        emit_breakpoint_bridge(&cg)?;
    }
    cg.module.verify()?;
    Ok(cg.module)
}

fn emit_dynamic_tables(
    cg: &mut Codegen<'_>,
    tables: &[Table],
    static_count: usize,
    static_slots: usize,
) -> Result<(), String> {
    let llvm = cg.llvm;
    let t = cg.types;
    let dynamic_count = tables.len() - static_count;
    let dependencies = table_dependencies(tables, static_count);
    let dependency_globals: Vec<_> = dependencies
        .iter()
        .enumerate()
        .map(|(index, required)| {
            let items: Vec<_> = required.iter().map(|&id| llvm.i64(id as u64)).collect();
            let global = cg.module.add_global(
                t.i64.array(items.len() as u64),
                &format!("aml.dynamic.dependencies.{index}"),
                llvm.const_array(t.i64, &items),
            );
            global.set_linkage(ir::PRIVATE);
            global.set_constant();
            global
        })
        .collect();
    cg.module
        .add_global(t.i64, "aml_dynamic_count", llvm.i64(dynamic_count as u64))
        .set_constant();

    let descriptor = llvm.struct_type(&[t.i64, t.i64, t.i64, t.ptr, t.ptr, t.i64, t.ptr, t.i64]);
    let mut first = static_slots;
    let mut entries = Vec::with_capacity(dynamic_count);
    for (table_index, table) in tables[static_count..].iter().enumerate() {
        let size = slot_names(table, true).count();
        let bytes = cg.byte_global(&table.bytes);
        let state = cg.bindings.slots.len() + table_index * 2;
        let initialize = cg
            .module
            .function(&format!("aml.initialize.{table_index}"))
            .expect("initializers are declared");
        entries.push(llvm.const_struct(
            descriptor,
            &[
                llvm.i64(first as u64),
                llvm.i64(size as u64),
                llvm.i64(state as u64),
                initialize,
                bytes,
                llvm.i64(table.bytes.len() as u64),
                dependency_globals[table_index],
                llvm.i64(dependencies[table_index].len() as u64),
            ],
        ));
        first += size;
    }
    cg.module
        .add_global(
            descriptor.array(dynamic_count as u64),
            "aml_dynamic_tables",
            llvm.const_array(descriptor, &entries),
        )
        .set_constant();
    Ok(())
}

fn emit_context_functions(cg: &Codegen<'_>, count: usize, static_slots: usize) {
    let llvm = cg.llvm;
    let t = cg.types;
    let b = llvm.builder();

    let create_with_host = cg.module.add_function(
        "aml_context_create_with_host",
        t.ptr.function(&[t.ptr]),
        ir::EXTERNAL,
    );
    let create = cg
        .module
        .add_function("aml_context_create", t.ptr.function(&[]), ir::EXTERNAL);
    b.position_at_end(llvm.block(create, "entry"));
    let context = b.call(create_with_host, &[llvm.null()]);
    b.ret(context);

    let calloc = cg.runtime("calloc", t.ptr, &[t.i64, t.i64]);
    let set_host = cg.runtime("aml_context_set_host", t.void, &[t.ptr, t.ptr]);
    let release_mutexes = cg.runtime("aml_release_mutexes", t.void, &[t.ptr]);
    let destroy_objects = cg.runtime("aml_objects_destroy", t.void, &[t.ptr]);
    let initialize = cg.module.function("aml.initialize").unwrap();

    let host = create_with_host.param(0);
    host.set_name("host");
    let entry = llvm.block(create_with_host, "entry");
    let setup = llvm.block(create_with_host, "initialize");
    let cleanup = llvm.block(create_with_host, "cleanup");
    let error = llvm.block(create_with_host, "error");
    let done = llvm.block(create_with_host, "done");
    b.position_at_end(entry);
    let ctx = b.call(calloc, &[llvm.i64(1), llvm.size_of(t.context)]);
    let failed = b.icmp(ir::EQ, ctx, llvm.null());
    b.cond_br(failed, error, setup);
    b.position_at_end(setup);
    b.call(set_host, &[ctx, host]);
    let field = |index: u32| b.gep(t.context, ctx, &[llvm.i32(0), llvm.i32(index)]);
    b.store(llvm.i64(cg.width.bits() as u64 / 8), field(3));
    b.store(llvm.i64(count as u64), field(4));
    for index in 0..cg.bindings.slots.len() {
        let tag = if index < static_slots {
            UNINITIALIZED_TYPE
        } else {
            DYNAMIC_SLOT_TYPE
        };
        let slot = b.gep(
            t.context,
            ctx,
            &[llvm.i32(0), llvm.i32(9), llvm.i64(index as u64)],
        );
        b.store(cg.value_constant(0, llvm.null(), tag), slot);
    }
    b.store(llvm.i64(100_000), ctx);
    let result = b.alloca(t.value, "result");
    let status = b.call(initialize, &[ctx, result, llvm.i32(1)]);
    b.call(release_mutexes, &[ctx]);
    let ok = b.icmp(ir::EQ, status, llvm.i32(0));
    b.cond_br(ok, done, cleanup);
    b.position_at_end(cleanup);
    b.call(destroy_objects, &[ctx]);
    b.br(error);
    b.position_at_end(error);
    b.ret(llvm.null());
    b.position_at_end(done);
    b.ret(ctx);

    let destroy = cg.module.add_function(
        "aml_context_destroy",
        t.void.function(&[t.ptr]),
        ir::EXTERNAL,
    );
    b.position_at_end(llvm.block(destroy, "entry"));
    b.call(destroy_objects, &[destroy.param(0)]);
    b.ret_void();

    // The execution budget lives in the first context word.
    let consume = cg
        .module
        .add_function("aml.consume_step", t.i1.function(&[t.ptr]), ir::INTERNAL);
    let ctx = consume.param(0);
    let entry = llvm.block(consume, "entry");
    let available_block = llvm.block(consume, "consume");
    let exhausted = llvm.block(consume, "exhausted");
    b.position_at_end(entry);
    let remaining = b.load(t.i64, ctx);
    let available = b.icmp(ir::NE, remaining, llvm.i64(0));
    b.cond_br(available, available_block, exhausted);
    b.position_at_end(available_block);
    b.store(b.sub(remaining, llvm.i64(1)), ctx);
    b.ret(llvm.i1(true));
    b.position_at_end(exhausted);
    b.ret(llvm.i1(false));
}

fn emit_breakpoint_bridge(cg: &Codegen<'_>) -> Result<(), String> {
    let llvm = cg.llvm;
    let t = cg.types;
    let b = llvm.builder();
    let bridge = cg.module.add_function(
        "aml_interrupt_BRKP",
        t.i32.function(&[t.ptr, t.ptr, t.i64]),
        ir::EXTERNAL,
    );
    let (ctx, frame, length) = (bridge.param(0), bridge.param(1), bridge.param(2));
    let entry = llvm.block(bridge, "entry");
    let dispatch = llvm.block(bridge, "dispatch");
    let failed = llvm.block(bridge, "failed");
    b.position_at_end(entry);
    let source = b.alloca(t.value, "source");
    let snapshot = b.alloca(t.value, "snapshot");
    let result = b.alloca(t.value, "result");
    let view = b.insert(cg.value_constant(0, llvm.null(), 3), frame, 1);
    let view = b.insert(view, length, 0);
    b.store(view, source);
    let null = llvm.null();
    let copy = b.call(
        cg.object_op(),
        &[
            ctx,
            snapshot,
            llvm.i32(ObjectOp::Clone as u32),
            source,
            null,
            null,
            llvm.i64(0),
        ],
    );
    let ok = b.icmp(ir::EQ, copy, llvm.i32(0));
    b.cond_br(ok, dispatch, failed);
    b.position_at_end(dispatch);
    let registers = b.load(t.value, snapshot);
    let name = "aml.impl.BRKP";
    let signature = cg.signature(name)?;
    let mut operands = vec![ctx];
    if !signature.returns_integer {
        operands.push(result);
    }
    operands.extend([llvm.i32(1), registers]);
    let status = b.call(cg.implementation(name)?, &operands);
    if signature.returns_integer {
        // Falling off the end of the handler is a successful return.
        let status = b.extract(status, 0);
        let fell = b.icmp(ir::EQ, status, llvm.i32(FELL_THROUGH));
        b.ret(b.select(fell, llvm.i32(0), status));
    } else {
        b.ret(status);
    }
    b.position_at_end(failed);
    b.ret(copy);
    Ok(())
}

fn emit_initializer<'a>(
    cg: &mut Codegen<'_>,
    name: &str,
    declarations: impl Iterator<Item = &'a Declaration>,
) -> Result<(), String> {
    let initializer = Method {
        name: AbsolutePath::default(),
        offset: 0,
        flags: 0,
        body: Vec::new(),
    };
    let function = cg.module.function(name).expect("initializers are declared");
    let facts = MethodFacts {
        scalar_locals: 0,
        scalar_args: 0,
        returns_integer: false,
    };
    let mut emitter = MethodEmitter::new(cg, &initializer, function, facts, Signature::INITIALIZER);
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
            Declaration::Alias { name, .. } if emitter.cg.bindings.slots.contains_key(name) => {
                let target = emitter.cg.bindings.aliases[name].target.clone();
                if let Some(target) = emitter.alias_reference_target(&target) {
                    let reference = emitter.named_reference(target);
                    let address = emitter.named_address(emitter.cg.bindings.slots[name]);
                    emitter.b.store(reference, address);
                }
                continue;
            }
            Declaration::Mutex { name, level, .. } => {
                let address = emitter.named_address(emitter.cg.bindings.slots[name]);
                let initial = emitter.integer(u64::from(*level));
                emitter.b.store(initial, address);
                continue;
            }
            Declaration::Event { name, .. } => {
                let address = emitter.named_address(emitter.cg.bindings.slots[name]);
                let zero = emitter.cg.llvm.zero(emitter.cg.types.value);
                emitter.b.store(zero, address);
                continue;
            }
            Declaration::Field(field) => {
                emitter.lower_value(field)?;
                continue;
            }
            Declaration::Executable(body) => {
                if emitter.lower_statements(body)? {
                    return emitter.finish();
                }
                continue;
            }
            _ => continue,
        };
        let value = match &name.initializer {
            Literal::Integer(integer) => Ok(emitter.integer(integer.value(emitter.cg.width))),
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
        let address = emitter.named_address(emitter.cg.bindings.slots[&name.name]);
        emitter.b.store(value, address);
    }
    emitter.return_constant(0);
    emitter.finish()
}

fn emit_method(
    cg: &mut Codegen<'_>,
    method: &Method,
    table_state: Option<usize>,
) -> Result<(), String> {
    let llvm = cg.llvm;
    let t = cg.types;
    let name = method.name.llvm_suffix();
    let arg_count = usize::from(method.arg_count());
    let signature = cg.signature(&format!("aml.impl.{name}"))?;
    let implementation = cg.implementation(&format!("aml.impl.{name}"))?;
    let serialized = method.flags & 8 != 0;
    let mut body_name = format!("aml.impl.{name}");
    if table_state.is_some() {
        body_name.push_str(".loaded");
    }
    let loaded_name = body_name.clone();
    if serialized {
        body_name.push_str(".body");
    }
    let body = if table_state.is_none() && !serialized {
        implementation
    } else {
        cg.module
            .add_function(&body_name, cg.implementation_type(signature), ir::INTERNAL)
    };
    let facts = cg.facts.method(&method.name).unwrap_or(MethodFacts {
        scalar_locals: 0,
        scalar_args: 0,
        returns_integer: false,
    });

    let names_ready = !cg.facts.runs_during_init(&method.name);
    let mut emitter = MethodEmitter::new(cg, method, body, facts, signature);
    emitter.names_ready = names_ready;
    emitter.check_budget();
    if !emitter.lower_statements(&method.body)? {
        if let Some(result) = emitter.result {
            let none = emitter.cg.value_constant(0, llvm.null(), NO_RETURN_TYPE);
            emitter.b.store(none, result);
            emitter.return_constant(0);
        } else {
            emitter.return_constant(FELL_THROUGH);
        }
    }
    let allocates = emitter.allocates;
    let acquires_mutex = emitter.acquires_mutex;
    emitter.finish()?;
    implementation.set_linkage(ir::INTERNAL);

    let b = llvm.builder();
    fn forward(function: Value<'_>, count: usize) -> Vec<Value<'_>> {
        (0..count)
            .map(|index| function.param(index as u32))
            .collect()
    }

    // impl -> loaded: gate execution on the owning dynamic table.
    if let Some(state) = table_state {
        let loaded = if serialized {
            cg.module.add_function(
                &loaded_name,
                cg.implementation_type(signature),
                ir::INTERNAL,
            )
        } else {
            body
        };
        let enter = cg.runtime("aml_table_enter", t.i1, &[t.ptr, t.i64]);
        let leave = cg.runtime("aml_table_leave", t.void, &[t.ptr, t.i64]);
        let entry = llvm.block(implementation, "entry");
        let invoke = llvm.block(implementation, "invoke");
        let unavailable = llvm.block(implementation, "unavailable");
        b.position_at_end(entry);
        let ctx = implementation.param(0);
        let active = b.call(enter, &[ctx, llvm.i64(state as u64)]);
        b.cond_br(active, invoke, unavailable);
        b.position_at_end(invoke);
        let status = b.call(loaded, &forward(implementation, signature.param_count()));
        b.call(leave, &[ctx, llvm.i64(state as u64)]);
        b.ret(status);
        b.position_at_end(unavailable);
        b.ret(cg.status_constant(signature, TABLE_NOT_LOADED));
    }

    // Serialized methods run at their declared sync level.
    if serialized {
        let outer = cg.module.function(&loaded_name).unwrap();
        let sync_level = u32::from(method.flags >> 4);
        let current_level = cg.runtime("aml_sync_level", t.i32, &[t.ptr]);
        let entry = llvm.block(outer, "entry");
        let invoke = llvm.block(outer, "invoke");
        let error = llvm.block(outer, "error");
        b.position_at_end(entry);
        let ctx = outer.param(0);
        let level = b.gep(t.context, ctx, &[llvm.i32(0), llvm.i32(5)]);
        let previous = b.load(t.i32, level);
        let current = b.call(current_level, &[ctx]);
        let allowed = b.icmp(ir::ULE, current, llvm.i32(sync_level));
        b.cond_br(allowed, invoke, error);
        b.position_at_end(invoke);
        b.store(llvm.i32(sync_level), level);
        let status = b.call(body, &forward(outer, signature.param_count()));
        b.store(previous, level);
        b.ret(status);
        b.position_at_end(error);
        b.ret(cg.status_constant(signature, SYNC_LEVEL_TOO_HIGH));
    }

    // aml_value_<name>: the host entry point that returns any AML value.
    let value_entry = cg.module.add_function(
        &format!("aml_value_{name}"),
        cg.export_type(arg_count),
        ir::EXTERNAL,
    );
    {
        let ctx = value_entry.param(0);
        let result = value_entry.param(1);
        let entry = llvm.block(value_entry, "entry");
        let invoke = llvm.block(value_entry, "invoke");
        let export = llvm.block(value_entry, "export");
        let failed = llvm.block(value_entry, "failed");
        let error = llvm.block(value_entry, "error");
        b.position_at_end(entry);
        let internal = b.alloca(t.value, "internal.result");
        let missing_ctx = b.icmp(ir::EQ, ctx, llvm.null());
        let missing_result = b.icmp(ir::EQ, result, llvm.null());
        b.cond_br(b.or(missing_ctx, missing_result), error, invoke);
        b.position_at_end(invoke);
        // Non-allocating methods never create runtime objects, so the
        // mark-and-sweep at entry would find nothing new to free.
        if allocates {
            b.call(cg.runtime("aml_objects_collect", t.void, &[t.ptr]), &[ctx]);
        }
        let budget = if cg.bindings.freestanding {
            u64::MAX
        } else {
            100_000
        };
        b.store(llvm.i64(budget), ctx);
        let mut operands = vec![ctx];
        if !signature.returns_integer {
            operands.push(internal);
        }
        operands.push(llvm.i32(1));
        for index in 0..arg_count {
            let mut arg = value_entry.param(2 + index as u32);
            if matches!(cg.width, IntegerWidth::Bits32) {
                arg = b.and(arg, llvm.i64(u64::from(u32::MAX)));
            }
            if signature.scalar(index) {
                operands.push(arg);
            } else {
                operands.push(b.insert(llvm.zero(t.value), arg, 0));
            }
        }
        let status = b.call(implementation, &operands);
        // Methods that never acquire a mutex cannot hold one on return.
        if acquires_mutex {
            b.call(cg.runtime("aml_release_mutexes", t.void, &[t.ptr]), &[ctx]);
        }
        if signature.returns_integer {
            // The integer result arrives in registers; falling through
            // exports the no-return marker.
            let returned = b.extract(status, 1);
            let status = b.extract(status, 0);
            let integer = b.insert(llvm.zero(t.value), returned, 0);
            let fell = b.icmp(ir::EQ, status, llvm.i32(FELL_THROUGH));
            let none = cg.value_constant(0, llvm.null(), NO_RETURN_TYPE);
            let ok = b.icmp(ir::EQ, status, llvm.i32(0));
            b.cond_br(b.or(ok, fell), export, failed);
            b.position_at_end(export);
            b.store(b.select(fell, none, integer), result);
            b.ret(llvm.i32(0));
            b.position_at_end(failed);
            b.ret(status);
            b.position_at_end(error);
            b.ret(llvm.i32(INVALID_ARGUMENT));
        } else {
            let export_integer = llvm.block(value_entry, "export.integer");
            let export_object = llvm.block(value_entry, "export.object");
            let ok = b.icmp(ir::EQ, status, llvm.i32(0));
            b.cond_br(ok, export, failed);
            b.position_at_end(export);
            let tag_address = b.gep(t.value, internal, &[llvm.i32(0), llvm.i32(2)]);
            let tag = b.load(t.i64, tag_address);
            let integer = b.icmp(ir::EQ, tag, llvm.i64(0));
            b.cond_br(integer, export_integer, export_object);
            // Integer results are copied directly; other values are snapshotted
            // by the runtime so references never leak out of the context.
            b.position_at_end(export_integer);
            b.store(b.load(t.value, internal), result);
            b.ret(llvm.i32(0));
            b.position_at_end(export_object);
            let null = llvm.null();
            let exported = b.call(
                cg.object_op(),
                &[
                    ctx,
                    result,
                    llvm.i32(ObjectOp::Export as u32),
                    internal,
                    null,
                    null,
                    llvm.i64(0),
                ],
            );
            b.ret(exported);
            b.position_at_end(failed);
            b.ret(status);
            b.position_at_end(error);
            b.ret(llvm.i32(INVALID_ARGUMENT));
        }
    }

    // aml_<name>: the integer-only host entry point.
    let integer_entry = cg.module.add_function(
        &format!("aml_{name}"),
        cg.export_type(arg_count),
        ir::EXTERNAL,
    );
    {
        let result = integer_entry.param(1);
        let entry = llvm.block(integer_entry, "entry");
        let invoke = llvm.block(integer_entry, "invoke");
        let check_type = llvm.block(integer_entry, "check.type");
        let check_no_return = llvm.block(integer_entry, "check.no.return");
        let success = llvm.block(integer_entry, "success");
        let failed = llvm.block(integer_entry, "failed");
        let invalid = llvm.block(integer_entry, "invalid");
        b.position_at_end(entry);
        let value = b.alloca(t.value, "value");
        let missing = b.icmp(ir::EQ, result, llvm.null());
        b.cond_br(missing, invalid, invoke);
        b.position_at_end(invoke);
        let mut args = forward(integer_entry, 2 + arg_count);
        args[1] = value;
        let status = b.call(value_entry, &args);
        let ok = b.icmp(ir::EQ, status, llvm.i32(0));
        b.cond_br(ok, check_type, failed);
        b.position_at_end(check_type);
        let returned = b.load(t.value, value);
        let tag = b.extract(returned, 2);
        b.cond_br(b.icmp(ir::EQ, tag, llvm.i64(0)), success, check_no_return);
        b.position_at_end(check_no_return);
        let no_return = b.icmp(ir::EQ, tag, llvm.i64(NO_RETURN_TYPE));
        b.ret(b.select(
            no_return,
            llvm.i32(NO_RETURN_STATUS),
            llvm.i32(TYPE_MISMATCH),
        ));
        b.position_at_end(success);
        b.store(b.extract(returned, 0), result);
        b.ret(llvm.i32(0));
        b.position_at_end(failed);
        b.ret(status);
        b.position_at_end(invalid);
        b.ret(llvm.i32(INVALID_ARGUMENT));
    }
    Ok(())
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

// Runtime operations outside the AML opcode space.
#[derive(Clone, Copy, PartialEq, Eq)]
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

// AML opcodes the runtime implements directly.
const CONCATENATE: u32 = 0x73;
const INCREMENT: u32 = 0x75;
const DECREMENT: u32 = 0x76;
const DEREF_OF: u32 = 0x83;
const SIZE_OF: u32 = 0x87;
const INDEX: u32 = 0x88;
const LAND: u32 = 0x90;
const LOR: u32 = 0x91;
const LEQUAL: u32 = 0x93;
const LGREATER: u32 = 0x94;
const LLESS: u32 = 0x95;
const MID: u32 = 0x9e;

struct LoopBlocks<'c> {
    header: Block<'c>,
    exit: Block<'c>,
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
    let [region, fields, rest @ ..] = body else {
        return false;
    };
    let (StatementKind::Region(region), StatementKind::RegionFields(fields)) =
        (&region.kind, &fields.kind)
    else {
        return false;
    };
    let [field] = fields.units.as_slice() else {
        return false;
    };
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
            StatementKind::If {
                predicate,
                body,
                otherwise: None,
            } => {
                matches!(predicate, Expression::Apply(Operator::LEqual, args) if args.iter().all(scalar))
                    && body.iter().all(|s| safe(s, field))
            }
            _ => false,
        }
    }
    rest.iter().all(|s| safe(s, &field.name))
}

/// Lowers one method or initializer body into an internal function.
struct MethodEmitter<'a, 'c> {
    cg: &'a mut Codegen<'c>,
    method: &'a Method,
    facts: MethodFacts,
    b: Builder<'c>,
    /// Inserts allocas into the entry block while `b` is elsewhere.
    entry_builder: Builder<'c>,
    function: Value<'c>,
    execute: Block<'c>,
    finish_block: Block<'c>,
    ctx: Value<'c>,
    signature: Signature,
    /// Where a general method writes its result. Integer-returning methods
    /// keep the payload in `return_value` and return it in registers.
    result: Option<Value<'c>>,
    return_value: Option<Value<'c>>,
    depth: Value<'c>,
    call_result: Value<'c>,
    object_result: Value<'c>,
    operands: [Value<'c>; 3],
    exit_status: Value<'c>,
    /// Shared blocks that store a status and leave, keyed by status.
    error_blocks: HashMap<u32, Block<'c>>,
    /// Placeholder allocas for locals, arguments, and method-scoped objects.
    /// Referenced ones are replaced by runtime-owned slots in `finish`.
    locals: [Option<Value<'c>>; 8],
    args: Vec<Value<'c>>,
    fields: Vec<Value<'c>>,
    initialized_locals: u8,
    referenced_locals: u8,
    referenced_args: u8,
    loops: Vec<LoopBlocks<'c>>,
    local_objects: HashMap<AbsolutePath, usize>,
    local_regions: BTreeSet<usize>,
    /// Values statically known to be AML integers (type tag zero).
    integers: HashSet<Value<'c>>,
    /// Whether the method body can allocate runtime objects (buffers, packages,
    /// strings, fields, regions). Non-allocating methods skip the per-call
    /// mark-and-sweep `aml_objects_collect`, which is the dominant per-invocation
    /// runtime cost for pure-integer methods.
    allocates: bool,
    /// Whether the method body ever acquires a mutex. If not, the per-call
    /// `aml_release_mutexes` walk is skipped (it can only observe an empty list).
    acquires_mutex: bool,
    /// The method cannot run during static initialization, so every proven
    /// named integer already holds an integer and needs no readiness check.
    names_ready: bool,
}

impl<'a, 'c> MethodEmitter<'a, 'c> {
    fn new(
        cg: &'a mut Codegen<'c>,
        method: &'a Method,
        function: Value<'c>,
        facts: MethodFacts,
        signature: Signature,
    ) -> Self {
        let llvm = cg.llvm;
        let t = cg.types;
        let b = llvm.builder();
        let entry_builder = llvm.builder();
        entry_builder.position_at_end(llvm.block(function, "entry"));
        let execute = llvm.block(function, "execute");
        let finish_block = llvm.block(function, "finish");
        b.position_at_end(execute);
        let alloca = |name: &str| entry_builder.alloca(t.value, name);
        let call_result = alloca("call.result");
        let object_result = alloca("object.result");
        let operands = [alloca("object.a"), alloca("object.b"), alloca("object.c")];
        let args = (0..method.arg_count())
            .map(|index| alloca(&format!("arg{index}.addr")))
            .collect();
        let exit_status = entry_builder.alloca(t.i32, "exit.status");
        let ctx = function.param(0);
        ctx.set_name("ctx");
        let result = (!signature.returns_integer).then(|| function.param(1));
        if let Some(result) = result {
            result.set_name("result");
        }
        let return_value = signature.returns_integer.then(|| {
            let slot = entry_builder.alloca(t.i64, "return.value");
            entry_builder.store(llvm.i64(0), slot);
            slot
        });
        let depth = function.param(signature.depth_param());
        depth.set_name("depth");
        for index in 0..method.arg_count() {
            function
                .param(signature.first_arg_param() + u32::from(index))
                .set_name(&format!("arg{index}"));
        }
        Self {
            cg,
            method,
            facts,
            b,
            entry_builder,
            function,
            execute,
            finish_block,
            ctx,
            signature,
            result,
            return_value,
            depth,
            call_result,
            object_result,
            operands,
            exit_status,
            error_blocks: HashMap::new(),
            locals: [None; 8],
            args,
            fields: Vec::new(),
            initialized_locals: 0,
            referenced_locals: 0,
            referenced_args: 0,
            loops: Vec::new(),
            local_objects: HashMap::new(),
            local_regions: BTreeSet::new(),
            integers: HashSet::new(),
            allocates: false,
            acquires_mutex: false,
            names_ready: false,
        }
    }

    /// Completes the function: prologue, slot allocation, and epilogue.
    fn finish(self) -> Result<(), String> {
        let llvm = self.cg.llvm;
        let t = self.cg.types;
        let b = llvm.builder();
        for (&status, &block) in &self.error_blocks {
            b.position_at_end(block);
            b.store(llvm.i32(status), self.exit_status);
            b.br(self.finish_block);
        }

        let scoped = self.cg.bindings.freestanding
            && matches!(self.cg.width, IntegerWidth::Bits64)
            && scoped_region_method(&self.method.body);
        let prepare = llvm.block(self.function, "prepare");
        let depth_error = llvm.block(self.function, "depth.error");

        // Locals that a reference can reach live in runtime-owned slots so
        // they survive the frame; the rest are ordinary stack slots.
        let mut references = self.fields.clone();
        let uninitialized = self.cg.value_constant(0, llvm.null(), UNINITIALIZED_TYPE);
        for (index, local) in self.locals.iter().enumerate() {
            let Some(local) = *local else { continue };
            if self.referenced_locals & (1 << index) != 0 {
                references.push(local);
            } else {
                self.entry_builder.store(uninitialized, local);
            }
        }
        for (index, &arg) in self.args.iter().enumerate() {
            if self.referenced_args & (1 << index) != 0 {
                references.push(arg);
            }
        }
        let e = &self.entry_builder;
        let depth_ok = e.icmp(ir::ULE, self.depth, llvm.i32(64));
        e.cond_br(depth_ok, prepare, depth_error);

        b.position_at_end(prepare);
        let mut marks = None;
        if scoped {
            let arena_mark = b.call(self.cg.runtime("acpi_arena_mark", t.i64, &[]), &[]);
            let allocations = b.gep(t.i64, self.ctx, &[llvm.i64(1)]);
            marks = Some((arena_mark, b.load(t.ptr, allocations)));
        }
        let allocation_error =
            (!references.is_empty()).then(|| llvm.block(self.function, "allocation.error"));
        let object_slot = self.cg.runtime("aml_object_slot", t.ptr, &[t.ptr]);
        let mut replaced = HashMap::new();
        for placeholder in references {
            let slot = b.call(object_slot, &[self.ctx]);
            let ready = llvm.block(self.function, "slot.ready");
            let ok = b.icmp(ir::NE, slot, llvm.null());
            b.cond_br(ok, ready, allocation_error.unwrap());
            b.position_at_end(ready);
            placeholder.replace_and_erase(slot);
            replaced.insert(placeholder, slot);
        }
        let resolve = |value: Value<'c>| replaced.get(&value).copied().unwrap_or(value);
        for index in 0..self.method.arg_count() {
            let first = self.signature.first_arg_param();
            let mut param = self.function.param(first + u32::from(index));
            if self.signature.scalar(usize::from(index)) {
                param = b.insert(llvm.zero(t.value), param, 0);
            }
            b.store(param, resolve(self.args[usize::from(index)]));
        }
        b.br(self.execute);

        let reset = |b: &Builder<'c>| {
            if let Some((arena_mark, allocations_mark)) = marks {
                let reset_allocations =
                    self.cg
                        .runtime("aml_reset_allocations", t.void, &[t.ptr, t.ptr]);
                let reset_arena = self.cg.runtime("acpi_arena_reset", t.void, &[t.i64]);
                b.call(reset_allocations, &[self.ctx, allocations_mark]);
                b.call(reset_arena, &[arena_mark]);
            }
        };
        b.position_at_end(self.finish_block);
        let retire = self.cg.runtime("aml_retire_region", t.void, &[t.ptr]);
        for &index in &self.local_regions {
            b.call(retire, &[resolve(self.fields[index])]);
        }
        reset(&b);
        let status = b.load(t.i32, self.exit_status);
        match self.return_value {
            Some(slot) => {
                let returned = b.load(t.i64, slot);
                let pair = llvm.zero(self.cg.status_type(self.signature));
                b.ret(b.insert(b.insert(pair, status, 0), returned, 1));
            }
            None => b.ret(status),
        }
        b.position_at_end(depth_error);
        b.ret(self.cg.status_constant(self.signature, EXECUTION_LIMIT));
        if let Some(block) = allocation_error {
            b.position_at_end(block);
            reset(&b);
            b.ret(self.cg.status_constant(self.signature, OUT_OF_MEMORY));
        }
        // The body may end in an unterminated block when nothing reaches it.
        if !self.b.current_block().is_terminated() {
            self.b.br(self.finish_block);
        }
        Ok(())
    }

    // ---- small helpers -------------------------------------------------

    fn llvm(&self) -> &'c Context {
        self.cg.llvm
    }

    fn integer(&mut self, value: u64) -> Value<'c> {
        let constant = self.cg.integer(value);
        self.integers.insert(constant);
        constant
    }

    fn is_integer(&self, value: Value<'c>) -> bool {
        self.integers.contains(&value)
    }

    fn fresh(&self, name: &str) -> Block<'c> {
        self.llvm().block(self.function, name)
    }

    fn start_block(&self, block: Block<'c>) {
        self.b.position_at_end(block);
    }

    fn jump(&self, target: Block<'c>) {
        self.b.br(target);
    }

    fn branch(&self, condition: Value<'c>, yes: Block<'c>, no: Block<'c>) {
        self.b.cond_br(condition, yes, no);
    }

    fn error_block(&mut self, status: u32) -> Block<'c> {
        if let Some(&block) = self.error_blocks.get(&status) {
            return block;
        }
        let name = match status {
            DIVISION_BY_ZERO => "division.error",
            EXECUTION_LIMIT => "limit.error",
            TYPE_MISMATCH => "type.error",
            UNINITIALIZED => "uninitialized.error",
            TABLE_NOT_LOADED => "table.unavailable",
            _ => "error",
        };
        let block = self.fresh(name);
        self.error_blocks.insert(status, block);
        block
    }

    /// Continues in a new block when `condition` holds and fails otherwise.
    fn expect(&mut self, condition: Value<'c>, name: &str, status: u32) {
        let valid = self.fresh(name);
        let error = self.error_block(status);
        self.branch(condition, valid, error);
        self.start_block(valid);
    }

    fn return_status(&self, status: Value<'c>) {
        self.b.store(status, self.exit_status);
        self.jump(self.finish_block);
    }

    fn return_constant(&self, status: u32) {
        self.return_status(self.llvm().i32(status));
    }

    fn value_tag(&self, value: Value<'c>) -> Value<'c> {
        self.b.extract(value, 2)
    }

    fn tag_is(&self, value: Value<'c>, tag: u64) -> Value<'c> {
        self.b
            .icmp(ir::EQ, self.value_tag(value), self.llvm().i64(tag))
    }

    /// Emits `fast` when `condition` holds and `slow` otherwise, joining
    /// their results. Statically decided conditions emit one side only.
    fn guarded(
        &mut self,
        condition: Value<'c>,
        fast: impl FnOnce(&mut Self) -> Result<Value<'c>, String>,
        slow: impl FnOnce(&mut Self) -> Result<Value<'c>, String>,
    ) -> Result<Value<'c>, String> {
        match condition.as_u64() {
            Some(1) => return fast(self),
            Some(_) => return slow(self),
            None => {}
        }
        let fast_block = self.fresh("fast");
        let slow_block = self.fresh("slow");
        let join = self.fresh("join");
        self.branch(condition, fast_block, slow_block);
        self.start_block(fast_block);
        let fast_value = fast(self)?;
        let fast_end = self.b.current_block();
        self.jump(join);
        self.start_block(slow_block);
        let slow_value = slow(self)?;
        let slow_end = self.b.current_block();
        self.jump(join);
        self.start_block(join);
        let ty = self.cg.types.value;
        Ok(self
            .b
            .phi(ty, &[(fast_value, fast_end), (slow_value, slow_end)]))
    }

    fn guarded_effect(
        &mut self,
        condition: Value<'c>,
        fast: impl FnOnce(&mut Self),
        slow: impl FnOnce(&mut Self),
    ) {
        let unit = self.cg.llvm.zero(self.cg.types.value);
        let _ = self.guarded(
            condition,
            |this| {
                fast(this);
                Ok(unit)
            },
            |this| {
                slow(this);
                Ok(unit)
            },
        );
    }

    fn check_budget(&mut self) {
        // Trusted freestanding kernel code owns its lifetime and idle loop.
        if self.cg.bindings.freestanding {
            return;
        }
        let consume = self.cg.module.function("aml.consume_step").unwrap();
        let available = self.b.call(consume, &[self.ctx]);
        self.expect(available, "budget.ok", EXECUTION_LIMIT);
    }

    fn check_status(&mut self, status: Value<'c>) {
        let ok = self.b.icmp(ir::EQ, status, self.llvm().i32(0));
        let success = self.fresh("object.ok");
        let failed = self.fresh("object.error");
        self.branch(ok, success, failed);
        self.start_block(failed);
        self.return_status(status);
        self.start_block(success);
    }

    fn statement_value(
        &mut self,
        offset: usize,
        expression: &Expression,
    ) -> Result<Value<'c>, String> {
        self.lower_value(expression)
            .map_err(|err| self.statement_error(offset, &err))
    }

    fn statement_error(&self, offset: usize, error: &str) -> String {
        format!(
            "method {} at file offset {offset:#06x}: {error}",
            self.method.name
        )
    }

    // ---- statements ----------------------------------------------------

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
                self.object_into(ObjectOp::InitNamed as u32, &[value], 0, address);
                Ok(false)
            }
            StatementKind::Return(expression) => {
                let result = self.statement_value(statement.offset, expression)?;
                if let Some(slot) = self.return_value {
                    // Analysis proved every return is an integer.
                    if !self.is_integer(result) {
                        let integer = self.tag_is(result, 0);
                        self.expect(integer, "return.integer", TYPE_MISMATCH);
                    }
                    let payload = self.b.extract(result, 0);
                    self.b.store(payload, slot);
                    self.return_constant(0);
                    return Ok(true);
                }
                let output = self.result.expect("general methods write a result");
                if self.is_integer(result) {
                    self.b.store(result, output);
                    self.return_constant(0);
                    return Ok(true);
                }
                let integer = self.tag_is(result, 0);
                let direct = self.fresh("return.integer");
                let copy = self.fresh("return.copy");
                self.branch(integer, direct, copy);
                self.start_block(direct);
                self.b.store(result, output);
                self.return_constant(0);
                self.start_block(copy);
                self.object_into(ObjectOp::Clone as u32, &[result], 0, output);
                self.return_constant(0);
                Ok(true)
            }
            StatementKind::Delay { sleep, duration } => {
                let duration = self.statement_value(statement.offset, duration)?;
                let null = self.llvm().null();
                self.object_into(ObjectOp::Delay as u32, &[duration], u64::from(*sleep), null);
                Ok(false)
            }
            StatementKind::Unload(handle) => {
                let handle = self.statement_value(statement.offset, handle)?;
                let null = self.llvm().null();
                self.object_into(ObjectOp::Unload as u32, &[handle], 0, null);
                Ok(false)
            }
            StatementKind::Release(target) => {
                let target = self.binding(target);
                let slot = self.cg.bindings.slots[&target] as u64;
                let null = self.llvm().null();
                self.object_into(ObjectOp::MutexRelease as u32, &[], slot, null);
                Ok(false)
            }
            StatementKind::EventControl { target, signal } => {
                let target = self.binding(target);
                let signal = self.integer(u64::from(*signal));
                let slot = self.cg.bindings.slots[&target] as u64;
                let null = self.llvm().null();
                self.object_into(ObjectOp::EventControl as u32, &[signal], slot, null);
                Ok(false)
            }
            StatementKind::Notify(target, value) => {
                let value = self.statement_value(statement.offset, value)?;
                let target = self.binding(target);
                if let Some(&state) = self.cg.bindings.namespace_states.get(&target) {
                    self.check_table_state(state);
                }
                let path = self.cg.byte_constant(target.to_string().as_bytes());
                let null = self.llvm().null();
                self.object_into(ObjectOp::Notify as u32, &[path, value], 0, null);
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
                let initialized = self.initialized_locals;
                let blocks = self
                    .loops
                    .last_mut()
                    .expect("parser requires an enclosing While");
                let target = if matches!(statement.kind, StatementKind::Break) {
                    blocks.exit_locals = merge_paths(blocks.exit_locals, Some(initialized));
                    blocks.exit
                } else {
                    blocks.header
                };
                self.jump(target);
                Ok(true)
            }
            StatementKind::Noop => Ok(false),
        }
    }

    fn lower_region(&mut self, region: &crate::aml::Region) -> Result<(), String> {
        let base = self.statement_value(region.offset, &region.base)?;
        let length = self.statement_value(region.offset, &region.length)?;
        let path = self.cg.byte_constant(region.name.to_string().as_bytes());
        let address = self.named_object_address(&region.name);
        if let Some(&index) = self.local_objects.get(&region.name) {
            self.local_regions.insert(index);
        }
        self.object_into(
            ObjectOp::RegionCreate as u32,
            &[base, length, path],
            u64::from(region.space),
            address,
        );
        Ok(())
    }

    fn field_binding(&mut self, name: Option<&AbsolutePath>, payload: Value<'c>) -> Value<'c> {
        let mut index = u64::MAX;
        let mut address = None;
        if let Some(name) = name {
            let target = self.binding(name);
            if let Some(&slot) = self.cg.bindings.slots.get(&target) {
                index = slot as u64;
            } else {
                address = Some(self.named_object_address(&target));
            }
        }
        let base = self.cg.value_constant(0, self.llvm().null(), index);
        let binding = self.b.insert(base, payload, 0);
        match address {
            Some(address) => self.b.insert(binding, address, 1),
            None => binding,
        }
    }

    fn lower_region_fields(&mut self, fields: &crate::aml::RegionFields) -> Result<(), String> {
        let zero = self.llvm().i64(0);
        let (region, selector, data, bank) = match &fields.backing {
            FieldBacking::Region(region) => (Some(region), None, None, zero),
            FieldBacking::Bank(region, selector, value) => {
                let value = self.statement_value(fields.offset, value)?;
                self.require_integer(value);
                let bank = self.b.extract(value, 0);
                (Some(region), Some(selector), None, bank)
            }
            FieldBacking::Index(index, data) => (None, Some(index), Some(data), zero),
        };
        let bank = self.field_binding(data, bank);
        for unit in &fields.units {
            let start = self.llvm().i64(unit.start);
            let bits = self.llvm().i64(unit.bits);
            let location = self.field_binding(region, start);
            let size = self.field_binding(selector, bits);
            let address = self.named_object_address(&unit.name);
            self.object_into(
                ObjectOp::RegionFieldCreate as u32,
                &[location, size, bank],
                u64::from(unit.flags),
                address,
            );
        }
        Ok(())
    }

    fn truth_value(&self, value: Value<'c>) -> Value<'c> {
        let zero = self.llvm().const_int(self.cg.types.int, 0);
        self.b.icmp(ir::NE, value, zero)
    }

    fn lower_if(
        &mut self,
        offset: usize,
        predicate: &Expression,
        body: &[Statement],
        otherwise: &[Statement],
    ) -> Result<bool, String> {
        if let Expression::Integer(value) = predicate {
            return self.lower_statements(if value.value(self.cg.width) != 0 {
                body
            } else {
                otherwise
            });
        }
        let value = self.statement_value(offset, predicate)?;
        let value = self.require_integer(value);
        let condition = self.truth_value(value);
        // Fold predicates that became constant during lowering.
        if let Some(truth) = condition.as_u64() {
            self.initialized_locals |= cond_ref_local(predicate, truth != 0);
            return self.lower_statements(if truth != 0 { body } else { otherwise });
        }
        let yes = self.fresh("if.then");
        let no = self.fresh("if.else");
        let end = self.fresh("if.end");
        self.branch(condition, yes, no);
        let before = self.initialized_locals;

        self.start_block(yes);
        self.initialized_locals |= cond_ref_local(predicate, true);
        let yes_locals = self.lower_to_join(body, end)?;
        self.initialized_locals = before | cond_ref_local(predicate, false);
        self.start_block(no);
        let no_locals = self.lower_to_join(otherwise, end)?;
        Ok(self.start_join(end, merge_paths(yes_locals, no_locals)))
    }

    fn lower_while(
        &mut self,
        offset: usize,
        predicate: &Expression,
        body: &[Statement],
    ) -> Result<bool, String> {
        let header = self.fresh("while.cond");
        let exit = self.fresh("while.end");
        let entry = self.fresh("while.body");
        self.jump(header);
        self.start_block(header);
        self.check_budget();
        let exit_locals = if let Expression::Integer(value) = predicate {
            if value.value(self.cg.width) == 0 {
                self.discard(&[exit, entry]);
                return Ok(false);
            }
            self.jump(entry);
            None
        } else {
            let value = self.statement_value(offset, predicate)?;
            let value = self.require_integer(value);
            let condition = self.truth_value(value);
            self.branch(condition, entry, exit);
            Some(self.initialized_locals | cond_ref_local(predicate, false))
        };

        // Backedges cannot uninitialize locals, and the first iteration
        // always enters with the state established by the predicate above.
        self.loops.push(LoopBlocks {
            header,
            exit,
            exit_locals,
        });
        self.start_block(entry);
        self.initialized_locals |= cond_ref_local(predicate, true);
        self.lower_to_join(body, header)?;
        let blocks = self.loops.pop().unwrap();
        Ok(self.start_join(exit, blocks.exit_locals))
    }

    fn lower_to_join(&mut self, body: &[Statement], end: Block<'c>) -> Result<Option<u8>, String> {
        if self.lower_statements(body)? {
            return Ok(None);
        }
        self.jump(end);
        Ok(Some(self.initialized_locals))
    }

    fn start_join(&mut self, block: Block<'c>, locals: Option<u8>) -> bool {
        if let Some(locals) = locals {
            self.start_block(block);
            self.initialized_locals = locals;
            return false;
        }
        self.discard(&[block]);
        true
    }

    /// Terminates blocks that no path reaches; LLVM deletes them.
    fn discard(&self, blocks: &[Block<'c>]) {
        let b = self.llvm().builder();
        for &block in blocks {
            b.position_at_end(block);
            b.unreachable();
        }
    }

    // ---- values --------------------------------------------------------

    fn pack_integer(&mut self, value: Value<'c>) -> Value<'c> {
        let t = self.cg.types;
        let wide = match self.cg.width {
            IntegerWidth::Bits32 => self.b.zext(value, t.i64),
            IntegerWidth::Bits64 => value,
        };
        let packed = self.b.insert(self.llvm().zero(t.value), wide, 0);
        self.integers.insert(packed);
        packed
    }

    fn object_into(&mut self, op: u32, values: &[Value<'c>], extra: u64, output: Value<'c>) {
        // Track whether this method can allocate runtime objects or acquire
        // mutexes. Non-allocating, mutex-free methods skip the per-call GC and
        // mutex-release walks in the outer wrapper.
        const ALLOCATING: [ObjectOp; 7] = [
            ObjectOp::Buffer,
            ObjectOp::String,
            ObjectOp::Package,
            ObjectOp::FieldCreate,
            ObjectOp::RegionCreate,
            ObjectOp::RegionFieldCreate,
            ObjectOp::NamespaceRef,
        ];
        if ALLOCATING.iter().any(|&allocating| op == allocating as u32) {
            self.allocates = true;
        } else if op == ObjectOp::MutexAcquire as u32 {
            self.acquires_mutex = true;
        }
        let llvm = self.llvm();
        let mut pointers = [llvm.null(); 3];
        for ((&value, &slot), pointer) in values.iter().zip(&self.operands).zip(&mut pointers) {
            self.b.store(value, slot);
            *pointer = slot;
        }
        let [a, b, c] = pointers;
        let extra = if op == ObjectOp::Load as u32 || op == ObjectOp::LoadTable as u32 {
            self.b.zext(self.depth, self.cg.types.i64)
        } else {
            llvm.i64(extra)
        };
        let status = self.b.call(
            self.cg.object_op(),
            &[self.ctx, output, llvm.i32(op), a, b, c, extra],
        );
        self.check_status(status);
    }

    fn object(&mut self, op: u32, values: &[Value<'c>], extra: u64) -> Value<'c> {
        self.object_into(op, values, extra, self.object_result);
        self.b.load(self.cg.types.value, self.object_result)
    }

    /// A runtime operation whose successful result is always an integer.
    fn integer_object(&mut self, op: u32, values: &[Value<'c>], extra: u64) -> Value<'c> {
        let value = self.object(op, values, extra);
        self.integers.insert(value);
        value
    }

    fn lower_string(&mut self, bytes: &[u8]) -> Result<Value<'c>, String> {
        let source = self.cg.byte_constant(bytes);
        Ok(self.object(ObjectOp::String as u32, &[source], 0))
    }

    fn payload(&self, value: Value<'c>) -> Value<'c> {
        let payload = self.b.extract(value, 0);
        match self.cg.width {
            IntegerWidth::Bits32 => self.b.trunc(payload, self.cg.types.i32),
            IntegerWidth::Bits64 => payload,
        }
    }

    fn require_integer(&mut self, value: Value<'c>) -> Value<'c> {
        if !self.is_integer(value) {
            let integer = self.tag_is(value, 0);
            self.expect(integer, "type.ok", TYPE_MISMATCH);
        }
        self.payload(value)
    }

    fn lower_value(&mut self, expression: &Expression) -> Result<Value<'c>, String> {
        let value = match expression {
            Expression::Integer(value) => self.integer(value.value(self.cg.width)),
            Expression::String(bytes) => self.lower_string(bytes)?,
            Expression::Buffer(size, bytes) => {
                let size = self.lower_value(size)?;
                let size = self.require_integer(size);
                let size = self.pack_integer(size);
                let bytes = self.cg.byte_constant(bytes);
                self.object(ObjectOp::Buffer as u32, &[size, bytes], 0)
            }
            Expression::Package(size, elements) => {
                let size = self.lower_value(size)?;
                let size = self.require_integer(size);
                let size = self.pack_integer(size);
                let package = self.object(ObjectOp::Package as u32, &[size], 0);
                let null = self.llvm().null();
                for (index, element) in elements.iter().enumerate() {
                    let element = self.lower_value(element)?;
                    self.object_into(
                        ObjectOp::PackageElement as u32,
                        &[package, element],
                        index as u64,
                        null,
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
                let index = self.require_integer(index);
                let index = self.pack_integer(index);
                let length = self.lower_value(length)?;
                let length = self.require_integer(length);
                let length = self.pack_integer(length);
                let address = self.named_object_address(name);
                self.object_into(
                    ObjectOp::FieldCreate as u32,
                    &[buffer, index, length],
                    u64::from(*mode),
                    address,
                );
                self.integer(0)
            }
            Expression::RegionSource(name) => {
                let address = self.named_object_address(name);
                self.b.load(self.cg.types.value, address)
            }
            Expression::Field(name) => {
                let integer = self.cg.facts.integer_name(&self.cg.bindings.resolve(name));
                let address = self.named_object_address(name);
                let field = self.b.load(self.cg.types.value, address);
                if integer {
                    self.integer_object(ObjectOp::Read as u32, &[field], 0)
                } else {
                    self.object(ObjectOp::Read as u32, &[field], 0)
                }
            }
            Expression::Local(_) | Expression::Arg(_) | Expression::Name(_) => {
                self.load(expression)?
            }
            Expression::Call(name, args) => self.lower_call(name, args, true)?.unwrap(),
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
    ) -> Result<Value<'c>, String> {
        let name = name.llvm_suffix();
        let builtin =
            self.cg.bindings.freestanding && intrinsics::BUILTIN_NAMES.contains(&name.as_str());
        let intrinsic = self.cg.bindings.intrinsics.get(&name).cloned();
        if intrinsic.is_none() && !builtin {
            for arg in args {
                self.lower_value(arg)?;
            }
            return Ok(self.object(ObjectOp::UnresolvedExternal as u32, &[], 0));
        }
        if !matches!(self.cg.width, IntegerWidth::Bits64) {
            return Err(format!("{name}: intrinsics require 64-bit AML integers"));
        }
        if let Some(intrinsic) = intrinsic {
            return self.lower_intrinsic(&name, &intrinsic, args);
        }
        let arity = match name.as_str() {
            "XGDT" => 3,
            "XADR" | "XIDT" => 1,
            _ => 0,
        };
        if args.len() != arity {
            return Err(format!("{name} requires {arity} argument(s)"));
        }
        let t = self.cg.types;
        if arity != 0 {
            let value = self.lower_value(&args[0])?;
            let is_buffer = self.tag_is(value, 3);
            let valid = if name == "XADR" {
                is_buffer
            } else {
                let size = self.b.extract(value, 0);
                let fits = self.b.icmp(ir::EQ, size, self.llvm().i64(10));
                self.b.and(is_buffer, fits)
            };
            self.expect(valid, "x86.buffer", TYPE_MISMATCH);
            let data = self.b.extract(value, 1);
            return match name.as_str() {
                "XADR" => {
                    let address = self.b.ptr_to_int(data, t.i64);
                    Ok(self.pack_integer(address))
                }
                "XGDT" => {
                    let code = self.lower_value(&args[1])?;
                    let code = self.require_integer(code);
                    let segments = self.lower_value(&args[2])?;
                    let segments = self.require_integer(segments);
                    let load_gdt = self
                        .cg
                        .runtime("acpi_load_gdt", t.void, &[t.ptr, t.i64, t.i64]);
                    self.b.call(load_gdt, &[data, code, segments]);
                    Ok(self.integer(0))
                }
                _ => {
                    let ty = t.void.function(&[t.ptr]);
                    let lidt = self.llvm().inline_asm(ty, "lidt ($0)", "r,~{memory}");
                    self.b.call_typed(ty, lidt, &[data]);
                    Ok(self.integer(0))
                }
            };
        }
        if !self.cg.bindings.breakpoint_handler {
            return Err(format!(
                "{name} requires a static one-argument \\BRKP method"
            ));
        }
        if name == "XHND" {
            let entry = self.cg.runtime("acpi_breakpoint_entry", t.void, &[]);
            let address = self.b.ptr_to_int(entry, t.i64);
            return Ok(self.pack_integer(address));
        }
        let trigger = self.cg.runtime("acpi_trigger_breakpoint", t.i32, &[t.ptr]);
        let status = self.b.call(trigger, &[self.ctx]);
        self.check_status(status);
        Ok(self.integer(0))
    }

    /// Lowers a call to a manifest intrinsic inline.
    fn lower_intrinsic(
        &mut self,
        name: &str,
        intrinsic: &Intrinsic,
        args: &[Expression],
    ) -> Result<Value<'c>, String> {
        let arity = intrinsic.arity();
        if args.len() != arity {
            return Err(format!("{name} requires {arity} argument(s)"));
        }
        let mut operands = Vec::with_capacity(arity);
        for arg in args {
            let value = self.lower_value(arg)?;
            operands.push(self.require_integer(value));
        }
        let t = self.cg.types;
        let llvm = self.llvm();
        let narrow = |b: &ir::Builder<'c>, value: Value<'c>, width: Width| match width {
            Width::U64 => value,
            _ => b.trunc(value, llvm.int(width.bits())),
        };
        let widen = |b: &ir::Builder<'c>, value: Value<'c>, width: Width| match width {
            Width::U64 => value,
            _ => b.zext(value, t.i64),
        };
        let result = match intrinsic {
            Intrinsic::Load { width, volatile } => {
                let address = self.b.int_to_ptr(operands[0], t.ptr);
                let value = self.b.load(llvm.int(width.bits()), address);
                value.set_alignment(1);
                if *volatile {
                    value.set_volatile();
                }
                widen(&self.b, value, *width)
            }
            Intrinsic::Store { width, volatile } => {
                let address = self.b.int_to_ptr(operands[0], t.ptr);
                let value = narrow(&self.b, operands[1], *width);
                let store = self.b.store(value, address);
                store.set_alignment(1);
                if *volatile {
                    store.set_volatile();
                }
                llvm.i64(0)
            }
            Intrinsic::Atomic { op, width } => {
                let address = self.b.int_to_ptr(operands[0], t.ptr);
                let value = narrow(&self.b, operands[1], *width);
                let op = match op {
                    AtomicOp::Xchg => ir::RMW_XCHG,
                    AtomicOp::Add => ir::RMW_ADD,
                    AtomicOp::Sub => ir::RMW_SUB,
                    AtomicOp::And => ir::RMW_AND,
                    AtomicOp::Or => ir::RMW_OR,
                    AtomicOp::Xor => ir::RMW_XOR,
                };
                let old = self.b.atomic_rmw(op, address, value);
                widen(&self.b, old, *width)
            }
            Intrinsic::CmpXchg { width } => {
                let address = self.b.int_to_ptr(operands[0], t.ptr);
                let expected = narrow(&self.b, operands[1], *width);
                let new = narrow(&self.b, operands[2], *width);
                let old = self.b.cmpxchg(address, expected, new);
                widen(&self.b, old, *width)
            }
            Intrinsic::Asm {
                template,
                constraints,
                pure,
                ..
            } => {
                let output = constraints
                    .split(',')
                    .any(|constraint| constraint.trim_start().starts_with('='));
                let ret = if output { t.i64 } else { t.void };
                let ty = ret.function(&vec![t.i64; arity]);
                let asm = llvm.inline_asm_with(ty, template, constraints, !pure);
                let value = self.b.call_typed(ty, asm, &operands);
                if *pure {
                    value.set_call_pure(llvm);
                }
                if output { value } else { llvm.i64(0) }
            }
            Intrinsic::Call { symbol, pure, .. } => {
                let function = self
                    .cg
                    .module
                    .declare(symbol, t.i64.function(&vec![t.i64; arity]))
                    .map_err(|error| format!("{name}: {error}"))?;
                let value = self.b.call(function, &operands);
                if *pure {
                    value.set_call_pure(llvm);
                }
                value
            }
        };
        Ok(self.pack_integer(result))
    }

    fn lower_call(
        &mut self,
        name: &AbsolutePath,
        args: &[Expression],
        needs_value: bool,
    ) -> Result<Option<Value<'c>>, String> {
        let args = args
            .iter()
            .map(|arg| self.lower_value(arg))
            .collect::<Result<Vec<_>, _>>()?;
        let name = self.binding(name);
        if name.is_osi() {
            return Ok(Some(self.integer_object(
                ObjectOp::Osi as u32,
                &[args[0]],
                0,
            )));
        }
        let symbol = format!("aml.impl.{}", name.llvm_suffix());
        let callee = self.cg.implementation(&symbol)?;
        let signature = self.cg.signature(&symbol)?;
        let depth = self.b.add(self.depth, self.llvm().i32(1));
        let mut operands = vec![self.ctx];
        if !signature.returns_integer {
            operands.push(self.call_result);
        }
        operands.push(depth);
        for (index, arg) in args.into_iter().enumerate() {
            // Analysis proved every caller passes an integer here.
            operands.push(if signature.scalar(index) {
                self.b.extract(arg, 0)
            } else {
                arg
            });
        }
        let returned = self.b.call(callee, &operands);
        let status = if signature.returns_integer {
            self.b.extract(returned, 0)
        } else {
            returned
        };
        let llvm = self.llvm();
        let success = self.b.icmp(ir::EQ, status, llvm.i32(0));
        let may_fall = signature.returns_integer && signature.falls_through;
        let success = if may_fall && !needs_value {
            // A statement call ignores whether the callee returned a value.
            let fell = self.b.icmp(ir::EQ, status, llvm.i32(FELL_THROUGH));
            self.b.or(success, fell)
        } else {
            success
        };
        let valid = self.fresh("call.ok");
        let error = self.fresh("call.error");
        self.branch(success, valid, error);
        self.start_block(error);
        if may_fall && needs_value {
            let fell = self.b.icmp(ir::EQ, status, llvm.i32(FELL_THROUGH));
            let status = self.b.select(fell, llvm.i32(NO_RETURN_STATUS), status);
            self.return_status(status);
        } else {
            self.return_status(status);
        }
        self.start_block(valid);
        if !needs_value {
            return Ok(None);
        }
        if signature.returns_integer {
            let payload = self.b.extract(returned, 1);
            let packed = self
                .b
                .insert(self.llvm().zero(self.cg.types.value), payload, 0);
            self.integers.insert(packed);
            return Ok(Some(packed));
        }
        let value = self.b.load(self.cg.types.value, self.call_result);
        if signature.falls_through {
            let present = self.b.icmp(
                ir::NE,
                self.value_tag(value),
                self.llvm().i64(NO_RETURN_TYPE),
            );
            let missing = self.fresh("result.missing");
            let valid = self.fresh("result.present");
            self.branch(present, valid, missing);
            self.start_block(missing);
            self.return_constant(NO_RETURN_STATUS);
            self.start_block(valid);
        }
        Ok(Some(value))
    }

    fn lower_cond_ref(
        &mut self,
        source: Option<&Expression>,
        target: &Expression,
    ) -> Result<Value<'c>, String> {
        let Some(source) = source else {
            return Ok(self.integer(0));
        };
        let true_value = self.cg.ones();
        let available = self.conditional_reference_available(source);
        let absent = self.fresh("condref.absent");
        let end = self.fresh("condref.end");
        let before = self.initialized_locals;
        if let Some(available) = available {
            let present = self.fresh("condref.present");
            self.branch(available, present, absent);
            self.start_block(present);
        }
        if matches!(target, Expression::NullTarget) {
            if matches!(source, Expression::Apply(..)) {
                self.reference_operand(source, false)?;
            }
        } else {
            let reference = if let Expression::NamespaceObject(name, kind) = source {
                let state = self.namespace_reference_state(name);
                self.binding(name);
                let kind = self.integer(u64::from(*kind));
                self.object(ObjectOp::NamespaceRef as u32, &[kind], state)
            } else {
                self.reference_operand(source, true)?
            };
            self.store(target, reference, false)?;
        }
        let Some(available) = available else {
            self.discard(&[absent, end]);
            return Ok(self.integer(true_value));
        };
        self.jump(end);
        self.start_block(absent);
        self.jump(end);
        self.start_block(end);
        self.initialized_locals = before;
        let llvm = self.llvm();
        let result = self.b.select(available, llvm.i64(true_value), llvm.i64(0));
        let packed = self.b.insert(llvm.zero(self.cg.types.value), result, 0);
        self.integers.insert(packed);
        Ok(packed)
    }

    fn namespace_reference_state(&self, name: &AbsolutePath) -> u64 {
        let bindings = &self.cg.bindings;
        let mut name = name;
        while let Some(alias) = bindings.aliases.get(name) {
            if let Some(state) = alias.state {
                return state as u64;
            }
            name = &alias.target;
        }
        bindings
            .namespace_states
            .get(name)
            .map_or(u64::MAX, |&state| state as u64)
    }

    fn table_active(&self, state: usize) -> Value<'c> {
        let t = self.cg.types;
        let active = self.cg.runtime("aml_table_active", t.i1, &[t.ptr, t.i64]);
        self.b
            .call(active, &[self.ctx, self.llvm().i64(state as u64)])
    }

    fn dynamic_slot(&self, index: usize) -> Value<'c> {
        let t = self.cg.types;
        let slot = self.cg.runtime("aml_dynamic_slot", t.ptr, &[t.ptr, t.i64]);
        self.b
            .call(slot, &[self.ctx, self.llvm().i64(index as u64)])
    }

    fn conditional_reference_available(&mut self, source: &Expression) -> Option<Value<'c>> {
        let (mut name, opaque) = match source {
            Expression::Name(name) | Expression::Field(name) | Expression::RegionSource(name) => {
                (name, false)
            }
            Expression::NamespaceObject(name, _) => (name, true),
            _ => return None,
        };
        let mut states = Vec::new();
        while let Some(alias) = self.cg.bindings.aliases.get(name) {
            states.extend(alias.state);
            name = &alias.target;
        }
        if let Some(&state) = self.cg.bindings.namespace_states.get(name) {
            states.push(state);
        }
        let mut available: Option<Value<'c>> = None;
        for state in states {
            let active = self.table_active(state);
            available = Some(match available {
                Some(previous) => self.b.and(previous, active),
                None => active,
            });
        }
        if !opaque
            && let Some(&slot) = self.cg.bindings.slots.get(name)
            && slot >= self.cg.bindings.static_slots
        {
            let address = self.dynamic_slot(slot);
            let exists = self.b.icmp(ir::NE, address, self.llvm().null());
            available = Some(match available {
                Some(previous) => self.b.and(previous, exists),
                None => exists,
            });
        }
        if !opaque && !self.cg.bindings.slots.contains_key(name) {
            let name = name.clone();
            let address = self.named_object_address(&name);
            let field = self.b.load(self.cg.types.value, address);
            let kind = self.value_tag(field);
            return Some(
                self.b
                    .icmp(ir::NE, kind, self.llvm().i64(UNINITIALIZED_TYPE)),
            );
        }
        available
    }

    /// Integer comparison and logic operators. Integer operands are compared
    /// inline; anything else defers to the runtime's general comparison.
    fn lower_logical(
        &mut self,
        op: u32,
        lhs: Value<'c>,
        rhs: Value<'c>,
    ) -> Result<Value<'c>, String> {
        let both = if self.is_integer(lhs) && self.is_integer(rhs) {
            self.llvm().i1(true)
        } else {
            let left = self.tag_is(lhs, 0);
            let right = self.tag_is(rhs, 0);
            self.b.and(left, right)
        };
        let value = self.guarded(
            both,
            |this| {
                let b = &this.b;
                let llvm = this.cg.llvm;
                let zero = llvm.i64(0);
                let (left, right) = (b.extract(lhs, 0), b.extract(rhs, 0));
                let truth = match op {
                    LEQUAL => b.icmp(ir::EQ, left, right),
                    LGREATER => b.icmp(ir::UGT, left, right),
                    LLESS => b.icmp(ir::ULT, left, right),
                    LAND => b.and(b.icmp(ir::NE, left, zero), b.icmp(ir::NE, right, zero)),
                    _ => b.or(b.icmp(ir::NE, left, zero), b.icmp(ir::NE, right, zero)),
                };
                let result = b.select(truth, llvm.i64(this.cg.ones()), zero);
                Ok(this.b.insert(llvm.zero(this.cg.types.value), result, 0))
            },
            |this| Ok(this.object(op, &[lhs, rhs], 0)),
        )?;
        self.integers.insert(value);
        Ok(value)
    }

    /// Increment and Decrement. Scalar slots and integer-valued named
    /// objects are updated inline.
    fn lower_step(&mut self, target: &Expression, increment: bool) -> Result<Value<'c>, String> {
        let op = if increment { INCREMENT } else { DECREMENT };
        let step = |this: &mut Self, old: Value<'c>| {
            let payload = this.payload(old);
            let one = this.llvm().const_int(this.cg.types.int, 1);
            let next = if increment {
                this.b.add(payload, one)
            } else {
                this.b.sub(payload, one)
            };
            this.pack_integer(next)
        };
        if self.scalar_slot(target) {
            let address = self.slot_address(target)?;
            let old = self.load(target)?;
            let next = step(self, old);
            self.b.store(next, address);
            return Ok(next);
        }
        if let Expression::Name(name) = target {
            self.binding(name);
            if let Some(index) = self.alias_reference_target(name) {
                let address = self.named_address(index);
                let old = self.b.load(self.cg.types.value, address);
                if self.cg.facts.integer_name(&self.cg.bindings.resolve(name)) {
                    self.expect_named_ready(name, old);
                    let next = step(self, old);
                    let payload = self.payload(next);
                    self.store_named_payload(address, payload);
                    return Ok(next);
                }
                let integer = self.tag_is(old, 0);
                let value = self.guarded(
                    integer,
                    |this| {
                        let next = step(this, old);
                        this.b.store(next, address);
                        Ok(next)
                    },
                    |this| {
                        let reference = this.reference_to_slot(index, address);
                        Ok(this.object(op, &[reference], 0))
                    },
                )?;
                self.integers.insert(value);
                return Ok(value);
            }
        }
        let reference = self.reference_operand(target, false)?;
        Ok(self.integer_object(op, &[reference], 0))
    }

    fn lower_operator(
        &mut self,
        operator: &Operator,
        args: &[Expression],
    ) -> Result<Value<'c>, String> {
        use Operator::*;
        let int = self.cg.types.int;
        let value = match (operator, args) {
            (Load, [source, target]) => {
                let source = self.lower_value(source)?;
                let handle = self.object(ObjectOp::Load as u32, &[source], 0);
                self.store(target, handle, false)?;
                return Ok(handle);
            }
            (LoadTable, [signature, oem, table, root, parameter, data]) => {
                let signature = self.lower_value(signature)?;
                let oem = self.lower_value(oem)?;
                let table = self.lower_value(table)?;
                let root = self.lower_value(root)?;
                let parameter = self.lower_value(parameter)?;
                self.lower_value(data)?;
                let null = self.llvm().null();
                self.object_into(ObjectOp::LoadPaths as u32, &[root, parameter], 0, null);
                return Ok(self.object(ObjectOp::LoadTable as u32, &[signature, oem, table], 0));
            }
            (Acquire(target, _), []) => {
                let target = self.binding(target);
                let slot = self.cg.bindings.slots[&target] as u64;
                return Ok(self.integer_object(ObjectOp::MutexAcquire as u32, &[], slot));
            }
            (Wait(target), [timeout]) => {
                let timeout = self.lower_value(timeout)?;
                let target = self.binding(target);
                let path = self.cg.byte_constant(target.to_string().as_bytes());
                let slot = self.cg.bindings.slots[&target] as u64;
                return Ok(self.integer_object(ObjectOp::EventWait as u32, &[path, timeout], slot));
            }
            (Timer, []) => return Ok(self.integer_object(ObjectOp::Timer as u32, &[], 0)),
            (Store | CopyObject, [source, target]) => {
                let value = self.lower_value(source)?;
                self.store(target, value, matches!(operator, CopyObject))?;
                return Ok(value);
            }
            (RefOf, [source]) => return self.reference_operand(source, true),
            (DerefOf, [Expression::Apply(Index, operands)])
                if matches!(operands.as_slice(), [_, _, Expression::NullTarget]) =>
            {
                let (source, index) = self.binary_objects(&operands[0], &operands[1])?;
                let index = self.require_integer(index);
                let index = self.pack_integer(index);
                return Ok(self.object(ObjectOp::IndexRead as u32, &[source, index], 0));
            }
            (DerefOf, [source]) => {
                let source = self.lower_value(source)?;
                return Ok(self.object(DEREF_OF, &[source], 0));
            }
            (Index, [source, index, target]) => {
                let (source, index) = self.binary_objects(source, index)?;
                let index = self.require_integer(index);
                let index = self.pack_integer(index);
                let reference = self.object(INDEX, &[source, index], 0);
                self.store(target, reference, false)?;
                return Ok(reference);
            }
            (Concatenate, [left, right, target]) => {
                let (left, right) = self.binary_objects(left, right)?;
                let destination = self.indirect_target(target)?;
                let result = self.object(CONCATENATE, &[left, right], 0);
                self.store_result(target, destination, result)?;
                return Ok(result);
            }
            (Mid, [source, index, length, target]) => {
                let value = if matches!(source, Expression::Name(_)) {
                    None
                } else {
                    Some(self.lower_value(source)?)
                };
                let index = self.lower_value(index)?;
                let index = self.require_integer(index);
                let index = self.pack_integer(index);
                let length = self.lower_value(length)?;
                let length = self.require_integer(length);
                let length = self.pack_integer(length);
                let destination = self.indirect_target(target)?;
                let source = match value {
                    Some(value) => value,
                    None => self.lower_value(source)?,
                };
                let result = self.object(MID, &[source, index, length], 0);
                self.store_result(target, destination, result)?;
                return Ok(result);
            }
            (NamespaceType(name, object_type), []) => {
                let name = self.binding(name);
                if let Some(&state) = self.cg.bindings.namespace_states.get(&name) {
                    self.check_table_state(state);
                } else if let Some(&index) = self.cg.bindings.slots.get(&name) {
                    self.named_address(index);
                } else if *object_type == 10 {
                    let address = self.named_object_address(&name);
                    let region = self.b.load(self.cg.types.value, address);
                    return Ok(self.integer_object(ObjectOp::Type as u32, &[region], 0));
                }
                return Ok(self.integer(u64::from(*object_type)));
            }
            (SizeOf | ObjectType, [source]) => {
                let source = self.raw_value(source, matches!(operator, ObjectType))?;
                let op = if matches!(operator, SizeOf) {
                    SIZE_OF
                } else {
                    ObjectOp::Type as u32
                };
                return Ok(self.integer_object(op, &[source], 0));
            }
            (Convert(op), [source, target]) => {
                let source = self.lower_value(source)?;
                let result = if *op == 0x99 {
                    self.integer_object(u32::from(*op), &[source], 0)
                } else {
                    self.object(u32::from(*op), &[source], 0)
                };
                self.store(target, result, false)?;
                return Ok(result);
            }
            (Convert(op), [source, length, target]) => {
                let (source, length) = self.binary_objects(source, length)?;
                let length = self.require_integer(length);
                let length = self.pack_integer(length);
                let result = self.object(u32::from(*op), &[source, length], 0);
                self.store(target, result, false)?;
                return Ok(result);
            }
            (LAnd | LOr | LEqual | LGreater | LLess, [lhs, rhs]) => {
                let (lhs, rhs) = self.binary_objects(lhs, rhs)?;
                let op = match operator {
                    LAnd => LAND,
                    LOr => LOR,
                    LEqual => LEQUAL,
                    LGreater => LGREATER,
                    _ => LLESS,
                };
                return self.lower_logical(op, lhs, rhs);
            }
            (Increment | Decrement, [target]) => {
                return self.lower_step(target, matches!(operator, Increment));
            }
            (LNot, [source]) => {
                let source = self.lower_value(source)?;
                let source = self.require_integer(source);
                let zero = self.llvm().const_int(int, 0);
                let comparison = self.b.icmp(ir::EQ, source, zero);
                self.b.sext(comparison, int)
            }
            (Not | FindSetLeftBit | FindSetRightBit, [source, target]) => {
                let source = self.lower_value(source)?;
                let source = self.require_integer(source);
                let value = match operator {
                    Not => self.complement(source),
                    _ => self.find_set_bit(source, matches!(operator, FindSetLeftBit)),
                };
                self.store_integer(target, value)?;
                value
            }
            (Divide, [lhs, rhs, remainder_target, quotient_target]) => {
                let (lhs, rhs) = self.binary_values(lhs, rhs)?;
                self.check_divisor(rhs);
                let quotient = self.b.udiv(lhs, rhs);
                let remainder = self.b.urem(lhs, rhs);
                // The result is the quotient. uACPI writes the quotient
                // first, so an aliased target ends up holding the remainder.
                self.store_integer(quotient_target, quotient)?;
                self.store_integer(remainder_target, remainder)?;
                quotient
            }
            (operator, [lhs, rhs, target]) => {
                if !matches!(
                    operator,
                    Add | Subtract
                        | Multiply
                        | And
                        | Nand
                        | Or
                        | Nor
                        | Xor
                        | ShiftLeft
                        | ShiftRight
                        | Mod
                ) {
                    return Err(format!("invalid operands for {operator:?}"));
                }
                let (lhs, rhs) = self.binary_values(lhs, rhs)?;
                if matches!(operator, Mod) {
                    self.check_divisor(rhs);
                }
                let b = &self.b;
                let value = match operator {
                    Add => b.add(lhs, rhs),
                    Subtract => b.sub(lhs, rhs),
                    Multiply => b.mul(lhs, rhs),
                    And | Nand => b.and(lhs, rhs),
                    Or | Nor => b.or(lhs, rhs),
                    Xor => b.xor(lhs, rhs),
                    Mod => b.urem(lhs, rhs),
                    _ => {
                        // AML defines oversized shifts as producing zero.
                        let bits = u64::from(self.cg.width.bits());
                        let llvm = self.cg.llvm;
                        let in_range = b.icmp(ir::ULT, rhs, llvm.const_int(int, bits));
                        let count = b.and(rhs, llvm.const_int(int, bits - 1));
                        let shifted = if matches!(operator, ShiftLeft) {
                            b.shl(lhs, count)
                        } else {
                            b.lshr(lhs, count)
                        };
                        b.select(in_range, shifted, llvm.const_int(int, 0))
                    }
                };
                let value = if matches!(operator, Nand | Nor) {
                    self.complement(value)
                } else {
                    value
                };
                self.store_integer(target, value)?;
                value
            }
            _ => return Err(format!("invalid operands for {operator:?}")),
        };
        Ok(self.pack_integer(value))
    }

    fn check_table(&mut self, available: Value<'c>) {
        self.expect(available, "table.available", TABLE_NOT_LOADED);
    }

    fn check_table_state(&mut self, state: usize) {
        let active = self.table_active(state);
        self.check_table(active);
    }

    fn check_divisor(&mut self, divisor: Value<'c>) {
        let nonzero = self.truth_value(divisor);
        self.expect(nonzero, "division.ok", DIVISION_BY_ZERO);
    }

    fn complement(&self, value: Value<'c>) -> Value<'c> {
        let ones = self.llvm().const_int(self.cg.types.int, u64::MAX);
        self.b.xor(value, ones)
    }

    fn find_set_bit(&self, source: Value<'c>, left: bool) -> Value<'c> {
        let int = self.cg.types.int;
        let llvm = self.llvm();
        let bits = u64::from(self.cg.width.bits());
        let name = if left { "llvm.ctlz" } else { "llvm.cttz" };
        let intrinsic = self.cg.module.intrinsic(name, &[int]);
        let count = self.b.call(intrinsic, &[source, llvm.i1(false)]);
        if left {
            return self.b.sub(llvm.const_int(int, bits), count);
        }
        let position = self.b.add(count, llvm.const_int(int, 1));
        let nonzero = self.truth_value(source);
        self.b.select(nonzero, position, llvm.const_int(int, 0))
    }

    fn binary_values(
        &mut self,
        lhs: &Expression,
        rhs: &Expression,
    ) -> Result<(Value<'c>, Value<'c>), String> {
        let (left, right) = self.binary_objects(lhs, rhs)?;
        Ok((self.require_integer(left), self.require_integer(right)))
    }

    fn binary_objects(
        &mut self,
        lhs: &Expression,
        rhs: &Expression,
    ) -> Result<(Value<'c>, Value<'c>), String> {
        // A named integer operand retains the object until the operator reads
        // it. Evaluating the right operand can mutate that same object.
        if matches!(lhs, Expression::Name(_)) {
            let right = self.lower_value(rhs)?;
            return Ok((self.lower_value(lhs)?, right));
        }
        let left = self.lower_value(lhs)?;
        Ok((left, self.lower_value(rhs)?))
    }

    // ---- slots and references -----------------------------------------

    /// A local or argument proven to hold only integers and never referenced.
    fn scalar_slot(&self, slot: &Expression) -> bool {
        match slot {
            Expression::Local(index) => self.facts.scalar_locals & (1 << index) != 0,
            Expression::Arg(index) => {
                *index < self.method.arg_count() && self.facts.scalar_args & (1 << index) != 0
            }
            _ => false,
        }
    }

    fn reference_operand(
        &mut self,
        target: &Expression,
        escapes: bool,
    ) -> Result<Value<'c>, String> {
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
        debug_assert!(!self.scalar_slot(target), "scalar slots never escape");
        if let Expression::Name(name) | Expression::Field(name) = target {
            self.binding(name);
            if let Some(index) = self.alias_reference_target(name) {
                return Ok(self.named_reference(index));
            }
        }
        let slot = self.slot_address(target)?;
        let base = self
            .cg
            .value_constant(0, self.llvm().null(), REFERENCE_TYPE);
        Ok(self.b.insert(base, slot, 1))
    }

    fn alias_reference_target(&self, name: &AbsolutePath) -> Option<usize> {
        let mut name = name;
        loop {
            if let Some(&index) = self.cg.bindings.slots.get(name) {
                return Some(index);
            }
            name = &self.cg.bindings.aliases.get(name)?.target;
        }
    }

    fn reference_to_slot(&self, index: usize, slot: Value<'c>) -> Value<'c> {
        let storage = if index < self.cg.bindings.static_slots {
            1
        } else {
            2
        };
        let base = self
            .cg
            .value_constant(storage, self.llvm().null(), REFERENCE_TYPE);
        self.b.insert(base, slot, 1)
    }

    fn named_reference(&mut self, index: usize) -> Value<'c> {
        let slot = self.named_address(index);
        self.reference_to_slot(index, slot)
    }

    fn placeholder(&self, name: &str) -> Value<'c> {
        self.entry_builder.alloca(self.cg.types.value, name)
    }

    fn slot_address(&mut self, slot: &Expression) -> Result<Value<'c>, String> {
        match slot {
            Expression::Local(index) => {
                let index = usize::from(*index);
                if self.locals[index].is_none() {
                    self.locals[index] = Some(self.placeholder(&format!("local{index}")));
                }
                Ok(self.locals[index].unwrap())
            }
            Expression::Arg(index) if *index < self.method.arg_count() => {
                Ok(self.args[usize::from(*index)])
            }
            Expression::Arg(index) => Err(format!("Arg{index} is outside the method signature")),
            Expression::Name(name) | Expression::Field(name) | Expression::RegionSource(name) => {
                Ok(self.named_object_address(name))
            }
            _ => Err("expected a local, argument, or named value slot".into()),
        }
    }

    fn binding(&mut self, name: &AbsolutePath) -> AbsolutePath {
        let mut target = name;
        let mut states = Vec::new();
        while let Some(alias) = self.cg.bindings.aliases.get(target) {
            states.extend(alias.state);
            target = &alias.target;
        }
        let target = target.clone();
        for state in states {
            self.check_table_state(state);
        }
        target
    }

    fn named_address(&mut self, index: usize) -> Value<'c> {
        if index >= self.cg.bindings.static_slots {
            let address = self.dynamic_slot(index);
            let loaded = self.b.icmp(ir::NE, address, self.llvm().null());
            self.check_table(loaded);
            return address;
        }
        let llvm = self.llvm();
        self.b.gep(
            self.cg.types.context,
            self.ctx,
            &[llvm.i32(0), llvm.i32(9), llvm.i64(index as u64)],
        )
    }

    fn named_object_address(&mut self, name: &AbsolutePath) -> Value<'c> {
        let name = self.binding(name);
        if let Some(&index) = self.cg.bindings.slots.get(&name) {
            return self.named_address(index);
        }
        let next = self.local_objects.len();
        let index = *self.local_objects.entry(name).or_insert(next);
        if index == self.fields.len() {
            let placeholder = self.placeholder(&format!("field{index}"));
            self.fields.push(placeholder);
        }
        self.fields[index]
    }

    fn raw_value(
        &mut self,
        slot: &Expression,
        allow_uninitialized: bool,
    ) -> Result<Value<'c>, String> {
        if matches!(
            slot,
            Expression::Local(_) | Expression::Arg(_) | Expression::Name(_) | Expression::Field(_)
        ) {
            if !allow_uninitialized {
                return self.load(slot);
            }
            let address = self.slot_address(slot)?;
            return Ok(self.b.load(self.cg.types.value, address));
        }
        self.lower_value(slot)
    }

    fn load(&mut self, slot: &Expression) -> Result<Value<'c>, String> {
        let address = self.slot_address(slot)?;
        let value = self.b.load(self.cg.types.value, address);
        let initialized = match slot {
            Expression::Local(index) => self.initialized_locals & (1 << index) != 0,
            _ => true,
        };
        if self.scalar_slot(slot) {
            // A scalar slot holds an integer or, for locals, nothing at all.
            if !initialized {
                let present = self.b.icmp(
                    ir::NE,
                    self.value_tag(value),
                    self.llvm().i64(UNINITIALIZED_TYPE),
                );
                self.expect(present, "local.ready", UNINITIALIZED);
            }
            let payload = self.b.extract(value, 0);
            let packed = self
                .b
                .insert(self.llvm().zero(self.cg.types.value), payload, 0);
            self.integers.insert(packed);
            return Ok(packed);
        }
        if let Expression::Name(name) = slot
            && self.cg.facts.integer_name(&self.cg.bindings.resolve(name))
        {
            // A proven named integer is an integer once module-level code
            // has initialized it; the runtime rejects reads before that.
            self.expect_named_ready(name, value);
            let payload = self.b.extract(value, 0);
            let packed = self
                .b
                .insert(self.llvm().zero(self.cg.types.value), payload, 0);
            self.integers.insert(packed);
            return Ok(packed);
        }
        if matches!(slot, Expression::Name(_)) || !initialized {
            // Plain data reads as itself; fields and empty slots need the
            // runtime.
            let tag = self.value_tag(value);
            let plain = self.b.icmp(ir::ULT, tag, self.llvm().i64(REFERENCE_TYPE));
            return self.guarded(
                plain,
                |_| Ok(value),
                |this| Ok(this.object(ObjectOp::Read as u32, &[value], 0)),
            );
        }
        Ok(value)
    }

    /// Fails with `UNINITIALIZED` unless `value`, read from a proven named
    /// integer, is an integer. Methods that cannot run during static
    /// initialization skip the check.
    fn expect_named_ready(&mut self, name: &AbsolutePath, value: Value<'c>) {
        let resolved = self.cg.bindings.resolve(name);
        if !(self.names_ready && self.cg.facts.static_integer(&resolved)) {
            let integer = self.tag_is(value, 0);
            self.expect(integer, "named.ready", UNINITIALIZED);
        }
    }

    /// Overwrites the payload of a slot that already holds an integer. The
    /// runtime never stores data alongside an integer, so the rest of the
    /// slot is already in place.
    fn store_named_payload(&mut self, address: Value<'c>, payload: Value<'c>) {
        let wide = match self.cg.width {
            IntegerWidth::Bits32 => self.b.zext(payload, self.cg.types.i64),
            IntegerWidth::Bits64 => payload,
        };
        let llvm = self.llvm();
        let field = self
            .b
            .gep(self.cg.types.value, address, &[llvm.i32(0), llvm.i32(0)]);
        self.b.store(wide, field);
    }

    fn store_integer(&mut self, slot: &Expression, value: Value<'c>) -> Result<(), String> {
        let value = self.pack_integer(value);
        self.store(slot, value, false)
    }

    fn indirect_target(&mut self, target: &Expression) -> Result<Option<Value<'c>>, String> {
        if matches!(target, Expression::Apply(..)) {
            return self.reference_operand(target, false).map(Some);
        }
        Ok(None)
    }

    fn store_result(
        &mut self,
        target: &Expression,
        reference: Option<Value<'c>>,
        value: Value<'c>,
    ) -> Result<(), String> {
        if let Some(reference) = reference {
            let null = self.llvm().null();
            self.object_into(ObjectOp::StoreRef as u32, &[value, reference], 0, null);
            return Ok(());
        }
        self.store(target, value, false)
    }

    fn store(&mut self, slot: &Expression, value: Value<'c>, copy: bool) -> Result<(), String> {
        // Debug evaluates the source and discards the resulting diagnostic value.
        if matches!(slot, Expression::NullTarget | Expression::DebugTarget) {
            return Ok(());
        }
        if matches!(slot, Expression::Apply(_, _)) {
            let reference = self.reference_operand(slot, false)?;
            let null = self.llvm().null();
            self.object_into(ObjectOp::StoreRef as u32, &[value, reference], 0, null);
            return Ok(());
        }
        let address = self.slot_address(slot)?;
        if let Expression::Local(index) = slot {
            self.initialized_locals |= 1 << index;
        }
        if self.scalar_slot(slot) {
            debug_assert!(self.is_integer(value), "analysis proved an integer store");
            self.b.store(value, address);
            return Ok(());
        }
        let op = match slot {
            Expression::Field(_) => ObjectOp::StoreNamed,
            _ if copy => ObjectOp::CopySlot,
            Expression::Name(_) => ObjectOp::StoreNamed,
            _ => ObjectOp::StoreSlot,
        };
        let extra = u64::from(matches!(slot, Expression::Arg(_)));
        let runtime = |this: &mut Self| {
            this.object_into(op as u32, &[value], extra, address);
        };
        if matches!(slot, Expression::Field(_)) {
            runtime(self);
            return Ok(());
        }
        // Integers overwrite plain data in place: the runtime would do the
        // same after ruling out fields, references, and retired slots.
        let llvm = self.llvm();
        let source_integer = if self.is_integer(value) {
            llvm.i1(true)
        } else {
            self.tag_is(value, 0)
        };
        let current = self.b.load(self.cg.types.value, address);
        let tag = self.value_tag(current);
        if op == ObjectOp::StoreNamed
            && self.is_integer(value)
            && let Expression::Name(name) = slot
            && self.cg.facts.integer_name(&self.cg.bindings.resolve(name))
        {
            // Only initialization can be missing; integers truncate to width.
            self.expect_named_ready(name, current);
            let payload = self.payload(value);
            self.store_named_payload(address, payload);
            return Ok(());
        }
        let overwritable = if op == ObjectOp::StoreNamed {
            // Named integers keep their type and truncate to the table width.
            self.b.icmp(ir::EQ, tag, llvm.i64(0))
        } else {
            let plain = self.b.icmp(ir::ULT, tag, llvm.i64(REFERENCE_TYPE));
            let empty = self.b.icmp(ir::EQ, tag, llvm.i64(UNINITIALIZED_TYPE));
            self.b.or(plain, empty)
        };
        let condition = self.b.and(source_integer, overwritable);
        self.guarded_effect(
            condition,
            |this| {
                let stored = if op == ObjectOp::StoreNamed {
                    let payload = this.payload(value);
                    this.pack_integer(payload)
                } else {
                    value
                };
                this.b.store(stored, address);
            },
            runtime,
        );
        Ok(())
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use crate::aml::parse_table;

    /// Encodes an AML PkgLength for `body` bytes that follow it.
    fn package(body: &[u8]) -> Vec<u8> {
        let mut bytes = Vec::new();
        if body.len() + 1 < 64 {
            bytes.push((body.len() + 1) as u8);
        } else {
            let length = body.len() + 2;
            assert!(length < 4096);
            bytes.extend([0x40 | (length & 0xf) as u8, (length >> 4) as u8]);
        }
        bytes.extend_from_slice(body);
        bytes
    }

    /// `Method (name, args) { body }`.
    pub(crate) fn method(name: &[u8; 4], args: u8, body: &[u8]) -> Vec<u8> {
        let mut inner = name.to_vec();
        inner.push(args);
        inner.extend_from_slice(body);
        let mut bytes = vec![0x14];
        bytes.extend(package(&inner));
        bytes
    }

    /// A DSDT holding `declarations`.
    pub(crate) fn table(declarations: &[u8]) -> Table {
        let mut bytes = include_bytes!("../example.aml")[..36].to_vec();
        bytes.extend_from_slice(declarations);
        let length = u32::try_from(bytes.len()).unwrap();
        bytes[4..8].copy_from_slice(&length.to_le_bytes());
        bytes[9] = 0;
        bytes[9] = 0u8.wrapping_sub(bytes.iter().copied().fold(0, u8::wrapping_add));
        parse_table(&bytes).unwrap()
    }

    fn emit_table(declarations: &[u8]) -> Result<String, String> {
        emit_with_intrinsics(declarations, Manifest::default())
    }

    fn emit_with_intrinsics(declarations: &[u8], intrinsics: Manifest) -> Result<String, String> {
        let table = table(declarations);
        let width = table.integer_width();
        let context = Context::new();
        emit(&context, &[table], width, 1, false, intrinsics).map(|module| module.print())
    }

    fn emit_method(body: &[u8]) -> Result<String, String> {
        emit_table(&method(b"TEST", 1, body))
    }

    /// The text of the function implementing `name`.
    fn function<'a>(ir: &'a str, name: &str) -> &'a str {
        let start = ir
            .find(&format!("@aml.impl.{name}("))
            .expect("method is defined");
        let end = start + ir[start..].find("\n}\n").unwrap();
        &ir[start..end]
    }

    /// Calls to the runtime for one operation code.
    fn runtime_calls(ir: &str, op: u32) -> usize {
        ir.lines()
            .filter(|line| {
                line.contains("@aml_object_op(") && line.contains(&format!("i32 {op}, ptr"))
            })
            .count()
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
        assert!(!ir.contains("uninitialized.error"));

        body[3..5].copy_from_slice(&[0xa3, 0xa3]); // Replace the first Return with Noops.
        let ir = emit_method(&body).unwrap();
        assert!(ir.contains("uninitialized.error"));
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
        assert!(!ir.contains("uninitialized.error"));
        body[2] = 0x68; // An Arg0 predicate can skip the initialization.
        let ir = emit_method(&body).unwrap();
        assert!(ir.contains("uninitialized.error"));
    }

    #[test]
    fn integer_locals_never_reach_the_runtime() {
        // Store (Zero, Local0)
        // While (LLess (Local0, Arg0)) { Increment (Local0) }
        // Return (Local0)
        let body = [
            0x70, 0x00, 0x60, //
            0xa2, 6, 0x95, 0x60, 0x68, 0x75, 0x60, //
            0xa4, 0x60,
        ];
        let ir = emit_method(&body).unwrap();
        let ir = function(&ir, "TEST");
        assert!(!ir.contains("@aml_object_op"), "{ir}");
        assert!(!ir.contains("@aml_object_slot"), "{ir}");
    }

    #[test]
    fn referenced_locals_stay_in_runtime_slots() {
        // Store (Zero, Local0); Store (RefOf (Local0), Local1); Return (Local0)
        let body = [0x70, 0x00, 0x60, 0x70, 0x71, 0x60, 0x61, 0xa4, 0x60];
        let ir = emit_method(&body).unwrap();
        assert!(ir.contains("@aml_object_slot"));
        assert!(runtime_calls(&ir, ObjectOp::StoreSlot as u32) > 0);
    }

    #[test]
    fn comparisons_of_unknown_values_keep_a_runtime_fallback() {
        // Store ("A", Local0); Return (LEqual (Local0, Arg0))
        let body = [0x70, 0x0d, b'A', 0x00, 0x60, 0xa4, 0x93, 0x60, 0x68];
        let ir = emit_method(&body).unwrap();
        assert!(runtime_calls(&ir, LEQUAL) > 0);
        assert!(ir.contains("fast"));

        // Return (LEqual (Arg0, One)) compares integers inline.
        let ir = emit_method(&[0xa4, 0x93, 0x68, 0x01]).unwrap();
        assert_eq!(runtime_calls(&ir, LEQUAL), 0);
    }

    #[test]
    fn named_integers_are_read_and_written_inline() {
        let mut declarations = vec![0x08, b'C', b'N', b'T', b'_', 0x0a, 5]; // Name (CNT, 5)
        // Increment (CNT); Store (Add (CNT, Arg0), CNT); Return (CNT)
        let body = [
            0x75, b'C', b'N', b'T', b'_', //
            0x70, 0x72, b'C', b'N', b'T', b'_', 0x68, 0x00, b'C', b'N', b'T', b'_', //
            0xa4, b'C', b'N', b'T', b'_',
        ];
        declarations.extend(method(b"TEST", 1, &body));
        let ir = emit_table(&declarations).unwrap();
        assert!(!function(&ir, "TEST").contains("@aml_object_op"), "{ir}");

        // CopyObject (Arg0, CNT) can retype the object.
        declarations.extend(method(b"COPY", 1, &[0x9d, 0x68, b'C', b'N', b'T', b'_']));
        let ir = emit_table(&declarations).unwrap();
        assert!(runtime_calls(function(&ir, "TEST"), ObjectOp::Read as u32) > 0);
    }

    #[test]
    fn manifest_intrinsics_lower_inline() {
        // External (XLDQ, MethodObj, 1); External (XSTW, MethodObj, 2)
        let mut declarations = vec![0x15, b'X', b'L', b'D', b'Q', 0x08, 1];
        declarations.extend([0x15, b'X', b'S', b'T', b'W', 0x08, 2]);
        // Store (XLDQ (Arg0), Local0); XSTW (Arg0, Local0); Return (Local0)
        let body = [
            0x70, b'X', b'L', b'D', b'Q', 0x68, 0x60, //
            b'X', b'S', b'T', b'W', 0x68, 0x60, //
            0xa4, 0x60,
        ];
        declarations.extend(method(b"TEST", 1, &body));
        let manifest = Manifest::parse("XLDQ load u64 volatile\nXSTW store u16 volatile").unwrap();
        let ir = emit_with_intrinsics(&declarations, manifest).unwrap();
        let test = function(&ir, "TEST");
        assert!(test.contains("load volatile i64"), "{test}");
        assert!(test.contains("store volatile i16"), "{test}");
        // The loaded value is an integer, so Local0 never reaches the runtime.
        assert!(!test.contains("@aml_object_op"), "{test}");

        // Without a manifest the names stay unresolved externals.
        let ir = emit_table(&declarations).unwrap();
        let test = function(&ir, "TEST");
        assert_eq!(
            runtime_calls(test, ObjectOp::UnresolvedExternal as u32),
            2,
            "{test}"
        );

        let manifest = Manifest::parse("XLDQ load u64\nXSTW load u16").unwrap();
        let error = emit_with_intrinsics(&declarations, manifest).unwrap_err();
        assert!(error.contains("XSTW requires 1 argument"), "{error}");
    }
}
