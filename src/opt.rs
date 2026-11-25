//! High-level AML optimizations that LLVM cannot perform on its own.
//!
//! Generated code keeps every AML value in a tagged `%aml.value` and routes
//! stores, comparisons, and reference updates through the opaque
//! `aml_object_op` runtime entry point. Once a local's address reaches that
//! call, LLVM must assume the runtime can change its type, so the slot stays
//! in memory and every operation remains a call.
//!
//! This pass runs an interprocedural type analysis on the AML tree. It
//! proves which method locals and arguments only ever hold integers, which
//! methods return only integers, and therefore which values the code
//! generator may manipulate directly. Proven slots never escape to the
//! runtime, so LLVM's SROA and mem2reg promote them to SSA registers.
//!
//! The analysis is optimistic. It starts by assuming every slot is a scalar
//! integer and every method returns an integer, then repeatedly demotes facts
//! that some program construct contradicts until it reaches a fixed point.
//! Every remaining fact is justified by the others, so by induction over any
//! execution each proven slot holds only integers (or is uninitialized).

use std::collections::{HashMap, HashSet};

use crate::aml::{
    AbsolutePath, Declaration, Expression, FieldBacking, IntegerWidth, Literal, Method, Operator,
    Statement, StatementKind, Table,
};

/// Convert opcode for ToInteger. Its runtime result is always an integer.
const TO_INTEGER: u8 = 0x99;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct MethodFacts {
    /// Locals that only ever hold integers and are never referenced.
    pub scalar_locals: u8,
    /// Arguments that only ever hold integers and are never referenced.
    pub scalar_args: u8,
    /// Every successful `Return` produces an integer.
    pub returns_integer: bool,
}

#[derive(Default)]
pub struct Facts {
    methods: HashMap<AbsolutePath, MethodFacts>,
    /// Named objects whose reads always produce integers: static `Name`
    /// objects initialized with an integer that nothing can retype, and
    /// region fields no wider than an AML integer.
    integer_names: HashSet<AbsolutePath>,
    /// Methods that module-level code of the static tables can reach, and so
    /// may run before every static named object is initialized. Context
    /// creation fails unless that code completes, so every other method only
    /// ever observes initialized static names.
    init_methods: HashSet<AbsolutePath>,
    /// The subset of `integer_names` declared by static integer `Name`s,
    /// whose slots hold a plain integer once initialization completes.
    static_integers: HashSet<AbsolutePath>,
}

impl Facts {
    pub fn method(&self, name: &AbsolutePath) -> Option<MethodFacts> {
        self.methods.get(name).copied()
    }

    /// Whether reading the (alias-resolved) named object yields an integer.
    pub fn integer_name(&self, name: &AbsolutePath) -> bool {
        self.integer_names.contains(name)
    }

    /// Counts proven facts, for diagnostics and tests.
    pub fn summary(&self) -> (usize, usize, usize) {
        self.methods
            .values()
            .fold((0, 0, 0), |(locals, args, returns), facts| {
                (
                    locals + facts.scalar_locals.count_ones() as usize,
                    args + facts.scalar_args.count_ones() as usize,
                    returns + usize::from(facts.returns_integer),
                )
            })
    }

    pub fn integer_names(&self) -> usize {
        self.integer_names.len()
    }

    /// Whether the method can run while static initialization is underway.
    pub fn runs_during_init(&self, name: &AbsolutePath) -> bool {
        self.init_methods.contains(name)
    }

    /// Whether the named object is a static integer `Name` that nothing can
    /// retype, so after initialization its slot always holds an integer.
    pub fn static_integer(&self, name: &AbsolutePath) -> bool {
        self.static_integers.contains(name)
    }

    pub fn init_methods(&self) -> usize {
        self.init_methods.len()
    }
}

/// Runs the analysis over every method in `tables`.
///
/// `resolve` maps a called name through aliases to the method it invokes.
/// `untyped_entries` lists methods that external code may enter with
/// non-integer arguments (the breakpoint bridge passes a buffer).
pub fn analyze(
    tables: &[Table],
    static_count: usize,
    width: IntegerWidth,
    resolve: impl Fn(&AbsolutePath) -> AbsolutePath,
    untyped_entries: &[AbsolutePath],
) -> Facts {
    let methods: Vec<&Method> = tables
        .iter()
        .flat_map(|table| &table.declarations)
        .filter_map(|declaration| match declaration {
            Declaration::Method(method) => Some(method),
            _ => None,
        })
        .collect();
    let (integer_names, static_integers) = integer_names(tables, static_count, width, &resolve);
    let mut facts = Facts {
        integer_names,
        static_integers,
        init_methods: init_methods(tables, static_count, &resolve, untyped_entries),
        ..Facts::default()
    };
    for method in &methods {
        let args = ((1u16 << method.arg_count()) - 1) as u8;
        let untyped = untyped_entries.contains(&method.name);
        facts.methods.insert(
            method.name.clone(),
            MethodFacts {
                scalar_locals: u8::MAX,
                // Host entry points always pass integers.
                scalar_args: if untyped { 0 } else { args },
                returns_integer: true,
            },
        );
    }
    // Module-level code and declaration operands can call methods with
    // arbitrary values too.
    let mut module_code: Vec<&[Statement]> = Vec::new();
    let mut module_values: Vec<&Expression> = Vec::new();
    for declaration in tables.iter().flat_map(|table| &table.declarations) {
        match declaration {
            Declaration::Executable(body) => module_code.push(body),
            Declaration::Field(expression) => module_values.push(expression),
            Declaration::Region(region) => module_values.extend([&region.base, &region.length]),
            Declaration::RegionFields(fields) => {
                if let crate::aml::FieldBacking::Bank(_, _, value) = &fields.backing {
                    module_values.push(value);
                }
            }
            Declaration::Name(name) => {
                if let crate::aml::Literal::Aggregate(expression) = &name.initializer {
                    module_values.push(expression);
                }
            }
            _ => {}
        }
    }
    loop {
        let mut next = facts.methods.clone();
        for method in &methods {
            let current = facts.methods[&method.name];
            let mut walker = Walker {
                facts: &facts,
                resolve: &resolve,
                own: current,
                arg_count: method.arg_count(),
                demoted: current,
                calls: Vec::new(),
            };
            walker.statements(&method.body);
            let own = next.get_mut(&method.name).unwrap();
            own.scalar_locals &= walker.demoted.scalar_locals;
            own.scalar_args &= walker.demoted.scalar_args;
            own.returns_integer &= walker.demoted.returns_integer;
            apply_calls(&mut next, walker.calls);
        }
        // Module-level code has no locals or arguments of its own that the
        // method facts describe; only its calls matter.
        let none = MethodFacts {
            scalar_locals: 0,
            scalar_args: 0,
            returns_integer: false,
        };
        let mut walker = Walker {
            facts: &facts,
            resolve: &resolve,
            own: none,
            arg_count: 0,
            demoted: none,
            calls: Vec::new(),
        };
        module_code.iter().for_each(|body| walker.statements(body));
        module_values.iter().for_each(|value| walker.value(value));
        apply_calls(&mut next, walker.calls);
        if next == facts.methods {
            return facts;
        }
        facts.methods = next;
    }
}

fn apply_calls(facts: &mut HashMap<AbsolutePath, MethodFacts>, calls: Vec<(AbsolutePath, u8)>) {
    for (callee, untyped) in calls {
        if let Some(callee) = facts.get_mut(&callee) {
            callee.scalar_args &= !untyped;
        }
    }
}

struct Walker<'a, F> {
    facts: &'a Facts,
    resolve: &'a F,
    /// The facts currently assumed for the method being walked.
    own: MethodFacts,
    arg_count: u8,
    /// The facts that survive this walk.
    demoted: MethodFacts,
    /// Call sites, with a mask of arguments that may not be integers.
    calls: Vec<(AbsolutePath, u8)>,
}

impl<F: Fn(&AbsolutePath) -> AbsolutePath> Walker<'_, F> {
    fn statements(&mut self, statements: &[Statement]) {
        for statement in statements {
            self.statement(statement);
        }
    }

    fn statement(&mut self, statement: &Statement) {
        match &statement.kind {
            StatementKind::Name(_, initializer) => self.value(initializer),
            StatementKind::Region(region) => {
                self.value(&region.base);
                self.value(&region.length);
            }
            StatementKind::RegionFields(fields) => {
                if let crate::aml::FieldBacking::Bank(_, _, value) = &fields.backing {
                    self.value(value);
                }
            }
            StatementKind::If {
                predicate,
                body,
                otherwise,
            } => {
                self.value(predicate);
                self.statements(body);
                if let Some(otherwise) = otherwise {
                    self.statements(&otherwise.body);
                }
            }
            StatementKind::While(predicate, body) => {
                self.value(predicate);
                self.statements(body);
            }
            StatementKind::Return(value) => {
                self.value(value);
                if !self.is_integer(value) {
                    self.demoted.returns_integer = false;
                }
            }
            StatementKind::Evaluate(value)
            | StatementKind::Delay {
                duration: value, ..
            }
            | StatementKind::Notify(_, value)
            | StatementKind::Unload(value) => self.value(value),
            StatementKind::Break
            | StatementKind::Continue
            | StatementKind::Noop
            | StatementKind::Release(_)
            | StatementKind::EventControl { .. } => {}
        }
    }

    /// Whether evaluating `expression` successfully always yields an integer.
    fn is_integer(&self, expression: &Expression) -> bool {
        use Operator::*;
        match expression {
            Expression::Integer(_) => true,
            Expression::Local(index) => self.own.scalar_locals & (1 << index) != 0,
            Expression::Arg(index) => {
                *index < self.arg_count && self.own.scalar_args & (1 << index) != 0
            }
            Expression::CondRefOf { .. } => true,
            // Intrinsics and kernel built-ins return integers, and any other
            // unresolved external fails before producing a value.
            Expression::UnresolvedCall(..) => true,
            Expression::Name(name) | Expression::Field(name) => {
                self.facts.integer_name(&(self.resolve)(name))
            }
            Expression::Call(name, _) => {
                let name = (self.resolve)(name);
                name.is_osi()
                    || self
                        .facts
                        .method(&name)
                        .is_some_and(|facts| facts.returns_integer)
            }
            Expression::Apply(operator, args) => match operator {
                Store | CopyObject => self.is_integer(&args[0]),
                Convert(op) => *op == TO_INTEGER,
                Add | Subtract | Multiply | Divide | Mod | ShiftLeft | ShiftRight | And | Nand
                | Or | Nor | Xor | Not | FindSetLeftBit | FindSetRightBit | LNot | LAnd | LOr
                | LEqual | LGreater | LLess | Increment | Decrement | SizeOf | ObjectType
                | NamespaceType(..) | Timer | Acquire(..) | Wait(_) => true,
                Load | LoadTable | RefOf | DerefOf | Index | Mid | Concatenate => false,
            },
            _ => false,
        }
    }

    fn demote(&mut self, slot: &Expression) {
        match slot {
            Expression::Local(index) => self.demoted.scalar_locals &= !(1 << index),
            Expression::Arg(index) if *index < 8 => self.demoted.scalar_args &= !(1 << index),
            _ => {}
        }
    }

    /// A slot written with a value of the given integer-ness.
    fn target(&mut self, target: &Expression, integer: bool) {
        match target {
            Expression::Local(_) | Expression::Arg(_) if !integer => self.demote(target),
            Expression::Apply(..) => self.reference(target),
            _ => {}
        }
    }

    /// Mirrors `reference_operand`: an operand whose address the runtime sees.
    fn reference(&mut self, target: &Expression) {
        match target {
            Expression::Apply(Operator::Index | Operator::RefOf, _) => self.value(target),
            Expression::Apply(Operator::DerefOf, args) => self.value(&args[0]),
            Expression::Local(_) | Expression::Arg(_) => self.demote(target),
            _ => {}
        }
    }

    fn value(&mut self, expression: &Expression) {
        use Operator::*;
        match expression {
            Expression::Buffer(size, _) => self.value(size),
            Expression::Package(size, elements) => {
                self.value(size);
                elements.iter().for_each(|element| self.value(element));
            }
            Expression::CreateField {
                buffer,
                index,
                length,
                ..
            } => {
                self.value(buffer);
                self.value(index);
                self.value(length);
            }
            Expression::Call(name, args) => {
                let mut untyped = 0u8;
                for (index, arg) in args.iter().enumerate() {
                    self.value(arg);
                    if !self.is_integer(arg) && index < 8 {
                        untyped |= 1 << index;
                    }
                }
                self.calls.push(((self.resolve)(name), untyped));
            }
            Expression::UnresolvedCall(_, args) => args.iter().for_each(|arg| self.value(arg)),
            Expression::CondRefOf { source, target } => {
                if let Some(source) = source {
                    match **source {
                        Expression::NamespaceObject(..) => {}
                        Expression::Apply(..) => self.reference(source),
                        _ => self.demote(source),
                    }
                }
                self.target(target, false);
            }
            Expression::Apply(operator, args) => match (operator, args.as_slice()) {
                (Load, [source, target]) => {
                    self.value(source);
                    self.target(target, false);
                }
                (Store | CopyObject, [source, target]) => {
                    self.value(source);
                    let integer = self.is_integer(source);
                    self.target(target, integer);
                }
                (RefOf, [source]) => self.reference(source),
                (DerefOf, [Expression::Apply(Index, operands)])
                    if matches!(operands.as_slice(), [_, _, Expression::NullTarget]) =>
                {
                    self.value(&operands[0]);
                    self.value(&operands[1]);
                }
                (Index | Concatenate, [left, right, target]) => {
                    self.value(left);
                    self.value(right);
                    self.target(target, false);
                }
                (Mid, [source, index, length, target]) => {
                    self.value(source);
                    self.value(index);
                    self.value(length);
                    self.target(target, false);
                }
                (Convert(op), [operands @ .., target]) if !operands.is_empty() => {
                    operands.iter().for_each(|operand| self.value(operand));
                    self.target(target, *op == TO_INTEGER);
                }
                (Increment | Decrement, [target]) => {
                    // Scalar slots are updated inline; the result stays an integer.
                    if !matches!(target, Expression::Local(_) | Expression::Arg(_)) {
                        self.reference(target);
                    }
                }
                (Not | FindSetLeftBit | FindSetRightBit, [source, target]) => {
                    self.value(source);
                    self.target(target, true);
                }
                (Divide, [left, right, remainder, quotient]) => {
                    self.value(left);
                    self.value(right);
                    self.target(remainder, true);
                    self.target(quotient, true);
                }
                (_, [left, right, target]) => {
                    self.value(left);
                    self.value(right);
                    self.target(target, true);
                }
                (_, operands) => operands.iter().for_each(|operand| self.value(operand)),
            },
            _ => {}
        }
    }
}

/// Finds named objects that always read as integers.
fn integer_names(
    tables: &[Table],
    static_count: usize,
    width: IntegerWidth,
    resolve: &impl Fn(&AbsolutePath) -> AbsolutePath,
) -> (HashSet<AbsolutePath>, HashSet<AbsolutePath>) {
    let width = u64::from(width.bits());
    let mut candidates = HashSet::new();
    let mut fields: HashMap<AbsolutePath, u64> = HashMap::new();
    let mut note_fields = |units: &[crate::aml::FieldUnit]| {
        for unit in units {
            let bits = fields.entry(unit.name.clone()).or_default();
            *bits = (*bits).max(unit.bits);
        }
    };
    for (index, table) in tables.iter().enumerate() {
        for declaration in &table.declarations {
            match declaration {
                // Dynamic tables can retire their slots, so only static
                // named integers qualify.
                Declaration::Name(name)
                    if index < static_count && matches!(name.initializer, Literal::Integer(_)) =>
                {
                    candidates.insert(name.name.clone());
                }
                Declaration::RegionFields(region) if index < static_count => {
                    note_fields(&region.units)
                }
                Declaration::Method(method) => {
                    for_each_statement(&method.body, &mut |statement| {
                        if let StatementKind::RegionFields(region) = &statement.kind {
                            note_fields(&region.units);
                        }
                    });
                }
                _ => {}
            }
        }
    }
    let names = candidates.clone();
    let field_names: HashSet<_> = fields.keys().cloned().collect();
    // Region fields no wider than an integer read back as integers.
    candidates.extend(
        fields
            .into_iter()
            .filter(|&(_, bits)| bits <= width)
            .map(|(name, _)| name),
    );

    // CopyObject replaces the object outright, and a stored reference lets
    // a later CopyObject through an argument do the same. Aliases hold
    // references to their targets.
    let mut excluded = HashSet::new();
    for table in tables {
        excluded.extend(table.aliases.iter().map(|(_, target)| resolve(target)));
    }
    let mut exclude = |expression: &Expression| {
        let name = match expression {
            Expression::Apply(Operator::CopyObject, args) => &args[1],
            Expression::Apply(Operator::RefOf, args) => &args[0],
            Expression::CondRefOf {
                source: Some(source),
                target,
            } if !matches!(**target, Expression::NullTarget) => source,
            _ => return,
        };
        if let Expression::Name(name) | Expression::Field(name) | Expression::RegionSource(name) =
            name
        {
            excluded.insert(resolve(name));
        }
    };
    for declaration in tables.iter().flat_map(|table| &table.declarations) {
        match declaration {
            Declaration::Method(method) => {
                for_each_statement(&method.body, &mut |statement| {
                    statement_expressions(statement, &mut |expression| {
                        for_each_expression(expression, &mut exclude)
                    })
                });
            }
            Declaration::Executable(body) => {
                for_each_statement(body, &mut |statement| {
                    statement_expressions(statement, &mut |expression| {
                        for_each_expression(expression, &mut exclude)
                    })
                });
            }
            Declaration::Field(expression) => for_each_expression(expression, &mut exclude),
            Declaration::Region(region) => {
                for_each_expression(&region.base, &mut exclude);
                for_each_expression(&region.length, &mut exclude);
            }
            Declaration::RegionFields(region) => {
                if let FieldBacking::Bank(_, _, value) = &region.backing {
                    for_each_expression(value, &mut exclude);
                }
            }
            Declaration::Name(name) => {
                if let Literal::Aggregate(expression) = &name.initializer {
                    for_each_expression(expression, &mut exclude);
                }
            }
            _ => {}
        }
    }
    candidates.retain(|name| !excluded.contains(name));
    // A path declared both ways is not a plain integer slot.
    let names = names
        .into_iter()
        .filter(|name| candidates.contains(name) && !field_names.contains(name))
        .collect();
    (candidates, names)
}

/// Whether control can reach the end of `statements`, conservatively: a
/// method whose body cannot fall through always produces a return value.
pub fn falls_through(statements: &[Statement], width: IntegerWidth) -> bool {
    statements
        .iter()
        .all(|statement| completes(statement, width))
}

fn completes(statement: &Statement, width: IntegerWidth) -> bool {
    match &statement.kind {
        StatementKind::Return(_) | StatementKind::Break | StatementKind::Continue => false,
        StatementKind::If {
            body, otherwise, ..
        } => {
            falls_through(body, width)
                || otherwise
                    .as_ref()
                    .is_none_or(|otherwise| falls_through(&otherwise.body, width))
        }
        StatementKind::While(Expression::Integer(value), body) if value.value(width) != 0 => {
            breaks(body)
        }
        _ => true,
    }
}

/// Whether a loop body contains a `Break` that leaves this loop.
fn breaks(statements: &[Statement]) -> bool {
    statements.iter().any(|statement| match &statement.kind {
        StatementKind::Break => true,
        StatementKind::If {
            body, otherwise, ..
        } => breaks(body) || otherwise.as_ref().is_some_and(|o| breaks(&o.body)),
        _ => false,
    })
}

/// What a body can set in motion: the methods it calls, whether it can enter
/// the breakpoint bridge, and whether it can load a dynamic table.
#[derive(Default)]
struct Reach {
    calls: Vec<AbsolutePath>,
    breakpoint: bool,
    loads: bool,
}

impl Reach {
    fn expression(
        &mut self,
        expression: &Expression,
        resolve: &impl Fn(&AbsolutePath) -> AbsolutePath,
    ) {
        for_each_expression(expression, &mut |expression| match expression {
            Expression::Call(name, _) => self.calls.push(resolve(name)),
            Expression::UnresolvedCall(name, _) => {
                // XBRK traps into the bridge; XHND exposes its entry point.
                if matches!(name.llvm_suffix().as_str(), "XBRK" | "XHND") {
                    self.breakpoint = true;
                }
            }
            Expression::Apply(Operator::Load | Operator::LoadTable, _) => self.loads = true,
            _ => {}
        });
    }

    fn statements(&mut self, body: &[Statement], resolve: &impl Fn(&AbsolutePath) -> AbsolutePath) {
        for_each_statement(body, &mut |statement| {
            statement_expressions(statement, &mut |expression| {
                self.expression(expression, resolve)
            })
        });
    }

    /// Module-level code: executable bodies and declaration operands.
    fn declaration(
        &mut self,
        declaration: &Declaration,
        resolve: &impl Fn(&AbsolutePath) -> AbsolutePath,
    ) {
        match declaration {
            Declaration::Executable(body) => self.statements(body, resolve),
            Declaration::Field(expression) => self.expression(expression, resolve),
            Declaration::Region(region) => {
                self.expression(&region.base, resolve);
                self.expression(&region.length, resolve);
            }
            Declaration::RegionFields(fields) => {
                if let FieldBacking::Bank(_, _, value) = &fields.backing {
                    self.expression(value, resolve);
                }
            }
            Declaration::Name(name) => {
                if let Literal::Aggregate(expression) = &name.initializer {
                    self.expression(expression, resolve);
                }
            }
            _ => {}
        }
    }
}

/// Finds the methods static module-level code can reach through calls,
/// table loads, and the breakpoint bridge.
fn init_methods(
    tables: &[Table],
    static_count: usize,
    resolve: &impl Fn(&AbsolutePath) -> AbsolutePath,
    untyped_entries: &[AbsolutePath],
) -> HashSet<AbsolutePath> {
    let mut bodies = HashMap::new();
    for declaration in tables.iter().flat_map(|table| &table.declarations) {
        if let Declaration::Method(method) = declaration {
            bodies.insert(method.name.clone(), &method.body);
        }
    }
    let mut reach = Reach::default();
    for declaration in tables[..static_count]
        .iter()
        .flat_map(|table| &table.declarations)
    {
        reach.declaration(declaration, resolve);
    }
    let mut reached = HashSet::new();
    let (mut breakpoint, mut loads) = (false, false);
    loop {
        if reach.breakpoint && !breakpoint {
            breakpoint = true;
            reach.calls.extend(untyped_entries.iter().cloned());
        }
        if reach.loads && !loads {
            // A load during initialization runs that table's module code.
            loads = true;
            for declaration in tables[static_count..]
                .iter()
                .flat_map(|table| &table.declarations)
            {
                reach.declaration(declaration, resolve);
            }
        }
        let Some(name) = reach.calls.pop() else {
            return reached;
        };
        if let Some(body) = bodies.get(&name)
            && reached.insert(name)
        {
            reach.statements(body, resolve);
        }
    }
}

/// Visits every statement, including those nested in control flow.
fn for_each_statement(statements: &[Statement], visit: &mut impl FnMut(&Statement)) {
    for statement in statements {
        visit(statement);
        match &statement.kind {
            StatementKind::If {
                body, otherwise, ..
            } => {
                for_each_statement(body, visit);
                if let Some(otherwise) = otherwise {
                    for_each_statement(&otherwise.body, visit);
                }
            }
            StatementKind::While(_, body) => for_each_statement(body, visit),
            _ => {}
        }
    }
}

/// Visits the expressions a single statement evaluates directly.
fn statement_expressions(statement: &Statement, visit: &mut impl FnMut(&Expression)) {
    match &statement.kind {
        StatementKind::Name(_, value)
        | StatementKind::Return(value)
        | StatementKind::Evaluate(value)
        | StatementKind::Delay {
            duration: value, ..
        }
        | StatementKind::Notify(_, value)
        | StatementKind::Unload(value)
        | StatementKind::If {
            predicate: value, ..
        }
        | StatementKind::While(value, _) => visit(value),
        StatementKind::Region(region) => {
            visit(&region.base);
            visit(&region.length);
        }
        StatementKind::RegionFields(fields) => {
            if let FieldBacking::Bank(_, _, value) = &fields.backing {
                visit(value);
            }
        }
        StatementKind::Break
        | StatementKind::Continue
        | StatementKind::Noop
        | StatementKind::Release(_)
        | StatementKind::EventControl { .. } => {}
    }
}

/// Visits `expression` and every subexpression.
fn for_each_expression(expression: &Expression, visit: &mut impl FnMut(&Expression)) {
    visit(expression);
    match expression {
        Expression::Buffer(size, _) => for_each_expression(size, visit),
        Expression::Package(size, elements) => {
            for_each_expression(size, visit);
            elements
                .iter()
                .for_each(|element| for_each_expression(element, visit));
        }
        Expression::CreateField {
            buffer,
            index,
            length,
            ..
        } => {
            for_each_expression(buffer, visit);
            for_each_expression(index, visit);
            for_each_expression(length, visit);
        }
        Expression::Call(_, args)
        | Expression::UnresolvedCall(_, args)
        | Expression::Apply(_, args) => args.iter().for_each(|arg| for_each_expression(arg, visit)),
        Expression::CondRefOf { source, target } => {
            if let Some(source) = source {
                for_each_expression(source, visit);
            }
            for_each_expression(target, visit);
        }
        _ => {}
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::llvm::tests::{method, table};

    fn facts(declarations: &[u8]) -> (Facts, Table) {
        let table = table(declarations);
        let width = table.integer_width();
        let tables = [table];
        let facts = analyze(&tables, 1, width, |name| name.clone(), &[]);
        let [table] = tables;
        (facts, table)
    }

    fn method_facts(facts: &Facts, table: &Table, name: &str) -> MethodFacts {
        let method = table
            .declarations
            .iter()
            .find_map(|declaration| match declaration {
                Declaration::Method(method) if method.name.llvm_suffix() == name => Some(method),
                _ => None,
            })
            .unwrap();
        facts.method(&method.name).unwrap()
    }

    #[test]
    fn integer_arguments_and_returns_propagate_across_calls() {
        // Method (INCR, 1) { Return (Add (Arg0, One)) }
        let mut declarations = method(b"INCR", 1, &[0xa4, 0x72, 0x68, 0x01, 0x00]);
        // Method (MAIN, 0) { Store (INCR (5), Local0); Return (Local0) }
        declarations.extend(method(
            b"MAIN",
            0,
            &[0x70, b'I', b'N', b'C', b'R', 0x0a, 5, 0x60, 0xa4, 0x60],
        ));
        let (facts, table) = facts(&declarations);
        let incr = method_facts(&facts, &table, "INCR");
        assert_eq!(incr.scalar_args, 1);
        assert!(incr.returns_integer);
        let main = method_facts(&facts, &table, "MAIN");
        assert_eq!(main.scalar_locals & 1, 1);
        assert!(main.returns_integer);
    }

    #[test]
    fn a_string_argument_demotes_the_callee_and_its_callers() {
        // Method (ECHO, 1) { Return (Arg0) }
        let mut declarations = method(b"ECHO", 1, &[0xa4, 0x68]);
        // Method (MAIN, 0) { Store (ECHO ("x"), Local0); Return (Local0) }
        declarations.extend(method(
            b"MAIN",
            0,
            &[
                0x70, b'E', b'C', b'H', b'O', 0x0d, b'x', 0x00, 0x60, 0xa4, 0x60,
            ],
        ));
        let (facts, table) = facts(&declarations);
        let echo = method_facts(&facts, &table, "ECHO");
        assert_eq!(echo.scalar_args, 0);
        assert!(!echo.returns_integer);
        let main = method_facts(&facts, &table, "MAIN");
        assert_eq!(main.scalar_locals & 1, 0);
        assert!(!main.returns_integer);
    }

    #[test]
    fn methods_that_return_on_every_path_do_not_fall_through() {
        let body = |declarations: &[u8]| {
            let table = table(declarations);
            let width = table.integer_width();
            table
                .declarations
                .iter()
                .find_map(|declaration| match declaration {
                    Declaration::Method(method) => Some(falls_through(&method.body, width)),
                    _ => None,
                })
                .unwrap()
        };
        // If (Arg0) { Return (One) } Else { Return (2) }
        let both = [0xa0, 0x04, 0x68, 0xa4, 0x01, 0xa1, 0x04, 0xa4, 0x0a, 0x02];
        assert!(!body(&method(b"BOTH", 1, &both)));
        // If (Arg0) { Return (One) }
        assert!(body(&method(b"SOME", 1, &both[..5])));
        // While (One) { Return (One) }
        assert!(!body(&method(b"LOOP", 0, &[0xa2, 0x04, 0x01, 0xa4, 0x01])));
        // While (One) { Break }
        assert!(body(&method(b"EXIT", 0, &[0xa2, 0x03, 0x01, 0xa5])));
    }

    #[test]
    fn references_demote_locals() {
        // Store (Zero, Local0); Store (RefOf (Local0), Local1); Increment (Local2)
        let body = [0x70, 0x00, 0x60, 0x70, 0x71, 0x60, 0x61, 0x75, 0x62];
        let (facts, table) = facts(&method(b"MAIN", 0, &body));
        let main = method_facts(&facts, &table, "MAIN");
        assert_eq!(main.scalar_locals & 0b111, 0b100);
    }

    #[test]
    fn named_integers_lose_their_type_to_copies_and_references() {
        let names = [
            0x08, b'A', b'_', b'_', b'_', 0x01, // Name (A, One)
            0x08, b'B', b'_', b'_', b'_', 0x01, // Name (B, One)
            0x08, b'C', b'_', b'_', b'_', 0x01, // Name (C, One)
            0x08, b'S', b'_', b'_', b'_', 0x0d, b'x', 0x00, // Name (S, "x")
        ];
        let mut declarations = names.to_vec();
        // CopyObject (Arg0, B); Store (RefOf (C), Local0)
        declarations.extend(method(
            b"MAIN",
            1,
            &[
                0x9d, 0x68, b'B', b'_', b'_', b'_', 0x70, 0x71, b'C', b'_', b'_', b'_', 0x60,
            ],
        ));
        let (facts, _) = facts(&declarations);
        let name = |text: &str| {
            facts
                .integer_names
                .iter()
                .any(|name| name.llvm_suffix() == text)
        };
        assert!(name("A___"));
        assert!(!name("B___"));
        assert!(!name("C___"));
        assert!(!name("S___"));
    }
}
