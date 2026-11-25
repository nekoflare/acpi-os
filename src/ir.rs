//! A small, safe wrapper over the LLVM C API.
//!
//! Only the subset of LLVM that the AML code generator needs is exposed.
//! Every handle borrows the [`Context`] that created it, so the borrow checker
//! keeps types, values, and blocks from outliving their owning context.

use std::ffi::{CStr, CString, c_char, c_uint};
use std::marker::PhantomData;
use std::path::Path;
use std::ptr;

use ffi::*;

/// An `LLVMIntPredicate` value.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
#[repr(transparent)]
pub struct IntPredicate(c_uint);

/// An `LLVMLinkage` value.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
#[repr(transparent)]
pub struct Linkage(c_uint);

fn cstring(text: &str) -> CString {
    CString::new(text).expect("LLVM names cannot contain NUL bytes")
}

/// Takes ownership of a message allocated by LLVM.
unsafe fn take_message(message: *mut c_char) -> String {
    if message.is_null() {
        return String::new();
    }
    let text = unsafe { CStr::from_ptr(message) }
        .to_string_lossy()
        .into_owned();
    unsafe { LLVMDisposeMessage(message) };
    text
}

pub struct Context(LLVMContextRef);

impl Context {
    pub fn new() -> Self {
        Self(unsafe { LLVMContextCreate() })
    }

    pub fn module(&self, name: &str) -> Module<'_> {
        let name = cstring(name);
        Module {
            raw: unsafe { LLVMModuleCreateWithNameInContext(name.as_ptr(), self.0) },
            _context: PhantomData,
        }
    }

    pub fn builder(&self) -> Builder<'_> {
        Builder {
            raw: unsafe { LLVMCreateBuilderInContext(self.0) },
            _context: PhantomData,
        }
    }

    /// Reads a bitcode file into a new module owned by this context.
    pub fn parse_bitcode(&self, path: &Path) -> Result<Module<'_>, String> {
        let file = cstring(&path.to_string_lossy());
        let mut buffer = ptr::null_mut();
        let mut message = ptr::null_mut();
        if unsafe {
            LLVMCreateMemoryBufferWithContentsOfFile(file.as_ptr(), &mut buffer, &mut message)
        } != 0
        {
            return Err(format!("{}: {}", path.display(), unsafe {
                take_message(message)
            }));
        }
        let mut module = ptr::null_mut();
        let failed = unsafe { LLVMParseBitcodeInContext2(self.0, buffer, &mut module) };
        unsafe { LLVMDisposeMemoryBuffer(buffer) };
        if failed != 0 {
            return Err(format!("{}: invalid LLVM bitcode", path.display()));
        }
        Ok(Module {
            raw: module,
            _context: PhantomData,
        })
    }

    fn wrap_type(&self, raw: LLVMTypeRef) -> Type<'_> {
        Type(raw, PhantomData)
    }

    pub fn void(&self) -> Type<'_> {
        self.wrap_type(unsafe { LLVMVoidTypeInContext(self.0) })
    }

    pub fn int(&self, bits: u32) -> Type<'_> {
        self.wrap_type(unsafe { LLVMIntTypeInContext(self.0, bits) })
    }

    pub fn ptr(&self) -> Type<'_> {
        self.wrap_type(unsafe { LLVMPointerTypeInContext(self.0, 0) })
    }

    pub fn struct_type(&self, fields: &[Type<'_>]) -> Type<'_> {
        let mut raw: Vec<_> = fields.iter().map(|field| field.0).collect();
        self.wrap_type(unsafe {
            LLVMStructTypeInContext(self.0, raw.as_mut_ptr(), raw.len() as c_uint, 0)
        })
    }

    pub fn named_struct(&self, name: &str, fields: &[Type<'_>]) -> Type<'_> {
        let name = cstring(name);
        let mut raw: Vec<_> = fields.iter().map(|field| field.0).collect();
        unsafe {
            let ty = LLVMStructCreateNamed(self.0, name.as_ptr());
            LLVMStructSetBody(ty, raw.as_mut_ptr(), raw.len() as c_uint, 0);
            self.wrap_type(ty)
        }
    }

    /// Appends a basic block to `function`.
    pub fn block<'c>(&'c self, function: Value<'c>, name: &str) -> Block<'c> {
        let name = cstring(name);
        Block(
            unsafe { LLVMAppendBasicBlockInContext(self.0, function.0, name.as_ptr()) },
            PhantomData,
        )
    }

    pub fn const_int<'c>(&'c self, ty: Type<'c>, value: u64) -> Value<'c> {
        Value(unsafe { LLVMConstInt(ty.0, value, 0) }, PhantomData)
    }

    pub fn i1(&self, value: bool) -> Value<'_> {
        self.const_int(self.int(1), u64::from(value))
    }

    pub fn i32(&self, value: u32) -> Value<'_> {
        self.const_int(self.int(32), u64::from(value))
    }

    pub fn i64(&self, value: u64) -> Value<'_> {
        self.const_int(self.int(64), value)
    }

    pub fn null(&self) -> Value<'_> {
        Value(unsafe { LLVMConstNull(self.ptr().0) }, PhantomData)
    }

    pub fn zero<'c>(&'c self, ty: Type<'c>) -> Value<'c> {
        Value(unsafe { LLVMConstNull(ty.0) }, PhantomData)
    }

    pub fn const_struct<'c>(&'c self, ty: Type<'c>, fields: &[Value<'c>]) -> Value<'c> {
        let mut raw: Vec<_> = fields.iter().map(|field| field.0).collect();
        Value(
            unsafe { LLVMConstNamedStruct(ty.0, raw.as_mut_ptr(), raw.len() as c_uint) },
            PhantomData,
        )
    }

    pub fn const_array<'c>(&'c self, element: Type<'c>, items: &[Value<'c>]) -> Value<'c> {
        let mut raw: Vec<_> = items.iter().map(|item| item.0).collect();
        Value(
            unsafe { LLVMConstArray2(element.0, raw.as_mut_ptr(), raw.len() as u64) },
            PhantomData,
        )
    }

    /// A NUL-terminated byte array constant.
    pub fn const_bytes(&self, bytes: &[u8]) -> Value<'_> {
        Value(
            unsafe { LLVMConstStringInContext2(self.0, bytes.as_ptr().cast(), bytes.len(), 0) },
            PhantomData,
        )
    }

    /// The store size of `ty` as an `i64` constant expression.
    pub fn size_of<'c>(&'c self, ty: Type<'c>) -> Value<'c> {
        Value(unsafe { LLVMSizeOf(ty.0) }, PhantomData)
    }

    pub fn inline_asm<'c>(&'c self, ty: Type<'c>, code: &str, constraints: &str) -> Value<'c> {
        self.inline_asm_with(ty, code, constraints, true)
    }

    /// Inline assembly; without `side_effects` LLVM may merge or delete it.
    pub fn inline_asm_with<'c>(
        &'c self,
        ty: Type<'c>,
        code: &str,
        constraints: &str,
        side_effects: bool,
    ) -> Value<'c> {
        Value(
            unsafe {
                LLVMGetInlineAsm(
                    ty.0,
                    code.as_ptr().cast(),
                    code.len(),
                    constraints.as_ptr().cast(),
                    constraints.len(),
                    LLVMBool::from(side_effects),
                    0,
                    INLINE_ASM_DIALECT_ATT,
                    0,
                )
            },
            PhantomData,
        )
    }
}

impl Drop for Context {
    fn drop(&mut self) {
        unsafe { LLVMContextDispose(self.0) }
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
pub struct Type<'c>(LLVMTypeRef, PhantomData<&'c Context>);

impl<'c> Type<'c> {
    pub fn array(self, count: u64) -> Type<'c> {
        Type(unsafe { LLVMArrayType2(self.0, count) }, PhantomData)
    }

    pub fn function(self, params: &[Type<'c>]) -> Type<'c> {
        let mut raw: Vec<_> = params.iter().map(|param| param.0).collect();
        Type(
            unsafe { LLVMFunctionType(self.0, raw.as_mut_ptr(), raw.len() as c_uint, 0) },
            PhantomData,
        )
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Hash)]
pub struct Value<'c>(LLVMValueRef, PhantomData<&'c Context>);

impl<'c> Value<'c> {
    pub fn param(self, index: u32) -> Value<'c> {
        Value(unsafe { LLVMGetParam(self.0, index) }, PhantomData)
    }

    pub fn set_name(self, name: &str) {
        unsafe { LLVMSetValueName2(self.0, name.as_ptr().cast(), name.len()) }
    }

    pub fn set_linkage(self, linkage: Linkage) {
        unsafe { LLVMSetLinkage(self.0, linkage) }
    }

    pub fn set_initializer(self, value: Value<'c>) {
        unsafe { LLVMSetInitializer(self.0, value.0) }
    }

    pub fn set_constant(self) {
        unsafe { LLVMSetGlobalConstant(self.0, 1) }
    }

    pub fn set_unnamed_addr(self) {
        unsafe { LLVMSetUnnamedAddress(self.0, GLOBAL_UNNAMED_ADDR) }
    }

    /// The function type of a function declaration or definition.
    pub fn function_type(self) -> Type<'c> {
        Type(unsafe { LLVMGlobalGetValueType(self.0) }, PhantomData)
    }

    /// The value of an integer constant, if this is one.
    /// Marks a load or store volatile.
    pub fn set_volatile(self) {
        unsafe { LLVMSetVolatile(self.0, 1) }
    }

    /// Sets the alignment of a load, store, or atomic instruction.
    pub fn set_alignment(self, bytes: u32) {
        unsafe { LLVMSetAlignment(self.0, bytes) }
    }

    /// Declares that a call neither reads nor writes memory (`memory(none)`),
    /// always returns, and never unwinds.
    pub fn set_call_pure(self, context: &'c Context) {
        unsafe {
            for (name, value) in [("memory", 0), ("willreturn", 0), ("nounwind", 0)] {
                let kind = LLVMGetEnumAttributeKindForName(name.as_ptr().cast(), name.len());
                let attribute = LLVMCreateEnumAttribute(context.0, kind, value);
                LLVMAddCallSiteAttribute(self.0, FUNCTION_INDEX, attribute);
            }
        }
    }

    pub fn as_u64(self) -> Option<u64> {
        unsafe {
            if LLVMIsAConstantInt(self.0).is_null() {
                return None;
            }
            Some(LLVMConstIntGetZExtValue(self.0))
        }
    }

    /// Replaces every use of this instruction with `other` and deletes it.
    pub fn replace_and_erase(self, other: Value<'c>) {
        unsafe {
            LLVMReplaceAllUsesWith(self.0, other.0);
            LLVMInstructionEraseFromParent(self.0);
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
pub struct Block<'c>(LLVMBasicBlockRef, PhantomData<&'c Context>);

impl Block<'_> {
    pub fn is_terminated(self) -> bool {
        unsafe { !LLVMGetBasicBlockTerminator(self.0).is_null() }
    }
}

pub struct Module<'c> {
    raw: LLVMModuleRef,
    _context: PhantomData<&'c Context>,
}

impl<'c> Module<'c> {
    pub fn function(&self, name: &str) -> Option<Value<'c>> {
        let name = cstring(name);
        let raw = unsafe { LLVMGetNamedFunction(self.raw, name.as_ptr()) };
        (!raw.is_null()).then_some(Value(raw, PhantomData))
    }

    pub fn add_function(&self, name: &str, ty: Type<'c>, linkage: Linkage) -> Value<'c> {
        let name = cstring(name);
        let function = Value(
            unsafe { LLVMAddFunction(self.raw, name.as_ptr(), ty.0) },
            PhantomData,
        );
        function.set_linkage(linkage);
        function
    }

    /// Returns the existing function `name` or declares it with `ty`.
    pub fn declare(&self, name: &str, ty: Type<'c>) -> Result<Value<'c>, String> {
        match self.function(name) {
            Some(function) if function.function_type() == ty => Ok(function),
            Some(_) => Err(format!("conflicting signatures for @{name}")),
            None => Ok(self.add_function(name, ty, EXTERNAL)),
        }
    }

    pub fn intrinsic(&self, name: &str, overloads: &[Type<'c>]) -> Value<'c> {
        let mut raw: Vec<_> = overloads.iter().map(|ty| ty.0).collect();
        unsafe {
            let id = LLVMLookupIntrinsicID(name.as_ptr().cast(), name.len());
            assert_ne!(id, 0, "unknown LLVM intrinsic {name}");
            Value(
                LLVMGetIntrinsicDeclaration(self.raw, id, raw.as_mut_ptr(), raw.len()),
                PhantomData,
            )
        }
    }

    pub fn add_global(&self, ty: Type<'c>, name: &str, initializer: Value<'c>) -> Value<'c> {
        let name = cstring(name);
        let global = Value(
            unsafe { LLVMAddGlobal(self.raw, ty.0, name.as_ptr()) },
            PhantomData,
        );
        global.set_initializer(initializer);
        global
    }

    pub fn verify(&self) -> Result<(), String> {
        let mut message = ptr::null_mut();
        let failed = unsafe { LLVMVerifyModule(self.raw, RETURN_STATUS_ACTION, &mut message) };
        let message = unsafe { take_message(message) };
        if failed != 0 {
            return Err(format!("generated invalid LLVM IR: {}", message.trim()));
        }
        Ok(())
    }

    /// Links `other` into this module, consuming it.
    pub fn link(&self, other: Module<'c>) -> Result<(), String> {
        let raw = other.raw;
        std::mem::forget(other);
        if unsafe { LLVMLinkModules2(self.raw, raw) } != 0 {
            return Err("linking LLVM modules failed".into());
        }
        Ok(())
    }

    pub fn print(&self) -> String {
        unsafe { take_message(LLVMPrintModuleToString(self.raw)) }
    }

    /// Gives every function defined in the module without a
    /// `target-features` attribute the code-generation attributes of
    /// `template`, and marks it `nounwind` when `template` is.
    ///
    /// LLVM refuses to inline a function whose target attributes differ
    /// from its caller's, so generated code must match the runtime it calls.
    pub fn inherit_target_attributes(&self, template: &str) {
        const KEYS: [&str; 3] = ["target-cpu", "target-features", "tune-cpu"];
        let Some(template) = self.function(template) else {
            return;
        };
        unsafe {
            let string = |function: LLVMValueRef, key: &str| {
                LLVMGetStringAttributeAtIndex(
                    function,
                    FUNCTION_INDEX,
                    key.as_ptr().cast(),
                    key.len() as c_uint,
                )
            };
            let attributes: Vec<_> = KEYS
                .iter()
                .map(|key| string(template.0, key))
                .filter(|attribute| !attribute.is_null())
                .collect();
            let nounwind = LLVMGetEnumAttributeKindForName(c"nounwind".as_ptr(), 8);
            let nounwind = (!LLVMGetEnumAttributeAtIndex(template.0, FUNCTION_INDEX, nounwind)
                .is_null())
            .then(|| LLVMCreateEnumAttribute(LLVMGetModuleContext(self.raw), nounwind, 0));
            let mut function = LLVMGetFirstFunction(self.raw);
            while !function.is_null() {
                if LLVMIsDeclaration(function) == 0 && string(function, "target-features").is_null()
                {
                    for &attribute in attributes.iter().chain(&nounwind) {
                        LLVMAddAttributeAtIndex(function, FUNCTION_INDEX, attribute);
                    }
                }
                function = LLVMGetNextFunction(function);
            }
        }
    }
}

impl Drop for Module<'_> {
    fn drop(&mut self) {
        unsafe { LLVMDisposeModule(self.raw) }
    }
}

pub struct Builder<'c> {
    raw: LLVMBuilderRef,
    _context: PhantomData<&'c Context>,
}

macro_rules! binary {
    ($($name:ident => $llvm:ident),* $(,)?) => {
        $(pub fn $name(&self, lhs: Value<'c>, rhs: Value<'c>) -> Value<'c> {
            self.wrap(unsafe { $llvm(self.raw, lhs.0, rhs.0, c"".as_ptr()) })
        })*
    };
}

macro_rules! cast {
    ($($name:ident => $llvm:ident),* $(,)?) => {
        $(pub fn $name(&self, value: Value<'c>, ty: Type<'c>) -> Value<'c> {
            self.wrap(unsafe { $llvm(self.raw, value.0, ty.0, c"".as_ptr()) })
        })*
    };
}

impl<'c> Builder<'c> {
    fn wrap(&self, raw: LLVMValueRef) -> Value<'c> {
        Value(raw, PhantomData)
    }

    pub fn position_at_end(&self, block: Block<'c>) {
        unsafe { LLVMPositionBuilderAtEnd(self.raw, block.0) }
    }

    pub fn current_block(&self) -> Block<'c> {
        Block(unsafe { LLVMGetInsertBlock(self.raw) }, PhantomData)
    }

    pub fn alloca(&self, ty: Type<'c>, name: &str) -> Value<'c> {
        let name = cstring(name);
        self.wrap(unsafe { LLVMBuildAlloca(self.raw, ty.0, name.as_ptr()) })
    }

    pub fn load(&self, ty: Type<'c>, pointer: Value<'c>) -> Value<'c> {
        self.wrap(unsafe { LLVMBuildLoad2(self.raw, ty.0, pointer.0, c"".as_ptr()) })
    }

    pub fn store(&self, value: Value<'c>, pointer: Value<'c>) -> Value<'c> {
        self.wrap(unsafe { LLVMBuildStore(self.raw, value.0, pointer.0) })
    }

    pub fn extract(&self, aggregate: Value<'c>, index: u32) -> Value<'c> {
        self.wrap(unsafe { LLVMBuildExtractValue(self.raw, aggregate.0, index, c"".as_ptr()) })
    }

    pub fn insert(&self, aggregate: Value<'c>, value: Value<'c>, index: u32) -> Value<'c> {
        self.wrap(unsafe {
            LLVMBuildInsertValue(self.raw, aggregate.0, value.0, index, c"".as_ptr())
        })
    }

    /// `getelementptr inbounds` with constant `i32`/`i64` indices.
    pub fn gep(&self, ty: Type<'c>, pointer: Value<'c>, indices: &[Value<'c>]) -> Value<'c> {
        let mut raw: Vec<_> = indices.iter().map(|index| index.0).collect();
        self.wrap(unsafe {
            LLVMBuildInBoundsGEP2(
                self.raw,
                ty.0,
                pointer.0,
                raw.as_mut_ptr(),
                raw.len() as c_uint,
                c"".as_ptr(),
            )
        })
    }

    pub fn icmp(&self, predicate: IntPredicate, lhs: Value<'c>, rhs: Value<'c>) -> Value<'c> {
        self.wrap(unsafe { LLVMBuildICmp(self.raw, predicate, lhs.0, rhs.0, c"".as_ptr()) })
    }

    binary! {
        add => LLVMBuildAdd,
        sub => LLVMBuildSub,
        mul => LLVMBuildMul,
        and => LLVMBuildAnd,
        or => LLVMBuildOr,
        xor => LLVMBuildXor,
        shl => LLVMBuildShl,
        lshr => LLVMBuildLShr,
        udiv => LLVMBuildUDiv,
        urem => LLVMBuildURem,
    }

    cast! {
        zext => LLVMBuildZExt,
        sext => LLVMBuildSExt,
        trunc => LLVMBuildTrunc,
        ptr_to_int => LLVMBuildPtrToInt,
        int_to_ptr => LLVMBuildIntToPtr,
    }

    /// A sequentially consistent `atomicrmw`; returns the old value.
    pub fn atomic_rmw(&self, op: AtomicRmwOp, pointer: Value<'c>, value: Value<'c>) -> Value<'c> {
        self.wrap(unsafe {
            LLVMBuildAtomicRMW(
                self.raw,
                op.0,
                pointer.0,
                value.0,
                SEQUENTIALLY_CONSISTENT,
                0,
            )
        })
    }

    /// A sequentially consistent `cmpxchg`; returns the old value.
    pub fn cmpxchg(&self, pointer: Value<'c>, expected: Value<'c>, new: Value<'c>) -> Value<'c> {
        let pair = self.wrap(unsafe {
            LLVMBuildAtomicCmpXchg(
                self.raw,
                pointer.0,
                expected.0,
                new.0,
                SEQUENTIALLY_CONSISTENT,
                SEQUENTIALLY_CONSISTENT,
                0,
            )
        });
        self.extract(pair, 0)
    }

    pub fn phi(&self, ty: Type<'c>, incoming: &[(Value<'c>, Block<'c>)]) -> Value<'c> {
        let phi = self.wrap(unsafe { LLVMBuildPhi(self.raw, ty.0, c"".as_ptr()) });
        let mut values: Vec<_> = incoming.iter().map(|(value, _)| value.0).collect();
        let mut blocks: Vec<_> = incoming.iter().map(|(_, block)| block.0).collect();
        unsafe {
            LLVMAddIncoming(
                phi.0,
                values.as_mut_ptr(),
                blocks.as_mut_ptr(),
                values.len() as c_uint,
            )
        };
        phi
    }

    pub fn select(&self, condition: Value<'c>, yes: Value<'c>, no: Value<'c>) -> Value<'c> {
        self.wrap(unsafe { LLVMBuildSelect(self.raw, condition.0, yes.0, no.0, c"".as_ptr()) })
    }

    pub fn call(&self, function: Value<'c>, args: &[Value<'c>]) -> Value<'c> {
        self.call_typed(function.function_type(), function, args)
    }

    pub fn call_typed(&self, ty: Type<'c>, callee: Value<'c>, args: &[Value<'c>]) -> Value<'c> {
        let mut raw: Vec<_> = args.iter().map(|arg| arg.0).collect();
        self.wrap(unsafe {
            LLVMBuildCall2(
                self.raw,
                ty.0,
                callee.0,
                raw.as_mut_ptr(),
                raw.len() as c_uint,
                c"".as_ptr(),
            )
        })
    }

    pub fn br(&self, target: Block<'c>) {
        unsafe { LLVMBuildBr(self.raw, target.0) };
    }

    pub fn cond_br(&self, condition: Value<'c>, yes: Block<'c>, no: Block<'c>) {
        unsafe { LLVMBuildCondBr(self.raw, condition.0, yes.0, no.0) };
    }

    pub fn ret(&self, value: Value<'c>) {
        unsafe { LLVMBuildRet(self.raw, value.0) };
    }

    pub fn unreachable(&self) {
        unsafe { LLVMBuildUnreachable(self.raw) };
    }

    pub fn ret_void(&self) {
        unsafe { LLVMBuildRetVoid(self.raw) };
    }
}

impl Drop for Builder<'_> {
    fn drop(&mut self) {
        unsafe { LLVMDisposeBuilder(self.raw) }
    }
}

// Values from llvm-c/Core.h.
pub const EQ: IntPredicate = IntPredicate(32);
pub const NE: IntPredicate = IntPredicate(33);
pub const UGT: IntPredicate = IntPredicate(34);
pub const ULT: IntPredicate = IntPredicate(36);
pub const ULE: IntPredicate = IntPredicate(37);

/// An `LLVMAtomicRMWBinOp` value.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
#[repr(transparent)]
pub struct AtomicRmwOp(c_uint);

pub const RMW_XCHG: AtomicRmwOp = AtomicRmwOp(0);
pub const RMW_ADD: AtomicRmwOp = AtomicRmwOp(1);
pub const RMW_SUB: AtomicRmwOp = AtomicRmwOp(2);
pub const RMW_AND: AtomicRmwOp = AtomicRmwOp(3);
pub const RMW_OR: AtomicRmwOp = AtomicRmwOp(5);
pub const RMW_XOR: AtomicRmwOp = AtomicRmwOp(6);

pub const EXTERNAL: Linkage = Linkage(0);
pub const INTERNAL: Linkage = Linkage(8);
pub const PRIVATE: Linkage = Linkage(9);

/// Declarations for the parts of the LLVM C API used above. `build.rs`
/// links the matching LLVM libraries via `llvm-config`.
#[allow(non_camel_case_types)]
mod ffi {
    use super::{IntPredicate, Linkage};
    use std::ffi::{c_char, c_int, c_uint, c_ulonglong};

    macro_rules! opaque {
        ($($name:ident => $reference:ident),* $(,)?) => {
            $(
                #[repr(C)]
                pub struct $name {
                    _private: [u8; 0],
                }
                pub type $reference = *mut $name;
            )*
        };
    }

    opaque! {
        LLVMOpaqueContext => LLVMContextRef,
        LLVMOpaqueModule => LLVMModuleRef,
        LLVMOpaqueType => LLVMTypeRef,
        LLVMOpaqueValue => LLVMValueRef,
        LLVMOpaqueBasicBlock => LLVMBasicBlockRef,
        LLVMOpaqueBuilder => LLVMBuilderRef,
        LLVMOpaqueMemoryBuffer => LLVMMemoryBufferRef,
        LLVMOpaqueAttributeRef => LLVMAttributeRef,
    }

    /// `LLVMAttributeFunctionIndex`.
    pub const FUNCTION_INDEX: c_uint = !0;

    pub type LLVMBool = c_int;

    pub const INLINE_ASM_DIALECT_ATT: c_uint = 0;
    pub const GLOBAL_UNNAMED_ADDR: c_uint = 2;
    /// `LLVMAtomicOrderingSequentiallyConsistent`.
    pub const SEQUENTIALLY_CONSISTENT: c_uint = 7;
    pub const RETURN_STATUS_ACTION: c_uint = 2;

    unsafe extern "C" {
        pub fn LLVMDisposeMessage(message: *mut c_char);
        pub fn LLVMContextCreate() -> LLVMContextRef;
        pub fn LLVMContextDispose(context: LLVMContextRef);

        pub fn LLVMModuleCreateWithNameInContext(
            name: *const c_char,
            context: LLVMContextRef,
        ) -> LLVMModuleRef;
        pub fn LLVMDisposeModule(module: LLVMModuleRef);
        pub fn LLVMPrintModuleToString(module: LLVMModuleRef) -> *mut c_char;
        pub fn LLVMGetNamedFunction(module: LLVMModuleRef, name: *const c_char) -> LLVMValueRef;
        pub fn LLVMGetModuleContext(module: LLVMModuleRef) -> LLVMContextRef;
        pub fn LLVMGetFirstFunction(module: LLVMModuleRef) -> LLVMValueRef;
        pub fn LLVMGetNextFunction(function: LLVMValueRef) -> LLVMValueRef;
        pub fn LLVMIsDeclaration(global: LLVMValueRef) -> LLVMBool;
        pub fn LLVMGetStringAttributeAtIndex(
            function: LLVMValueRef,
            index: c_uint,
            key: *const c_char,
            length: c_uint,
        ) -> LLVMAttributeRef;
        pub fn LLVMGetEnumAttributeKindForName(name: *const c_char, length: usize) -> c_uint;
        pub fn LLVMGetEnumAttributeAtIndex(
            function: LLVMValueRef,
            index: c_uint,
            kind: c_uint,
        ) -> LLVMAttributeRef;
        pub fn LLVMCreateEnumAttribute(
            context: LLVMContextRef,
            kind: c_uint,
            value: u64,
        ) -> LLVMAttributeRef;
        pub fn LLVMAddCallSiteAttribute(
            call: LLVMValueRef,
            index: c_uint,
            attribute: LLVMAttributeRef,
        );
        pub fn LLVMSetVolatile(instruction: LLVMValueRef, volatile: LLVMBool);
        pub fn LLVMSetAlignment(value: LLVMValueRef, bytes: c_uint);
        pub fn LLVMBuildAtomicRMW(
            builder: LLVMBuilderRef,
            op: c_uint,
            pointer: LLVMValueRef,
            value: LLVMValueRef,
            ordering: c_uint,
            single_thread: LLVMBool,
        ) -> LLVMValueRef;
        pub fn LLVMBuildAtomicCmpXchg(
            builder: LLVMBuilderRef,
            pointer: LLVMValueRef,
            expected: LLVMValueRef,
            new: LLVMValueRef,
            success: c_uint,
            failure: c_uint,
            single_thread: LLVMBool,
        ) -> LLVMValueRef;
        pub fn LLVMAddAttributeAtIndex(
            function: LLVMValueRef,
            index: c_uint,
            attribute: LLVMAttributeRef,
        );
        pub fn LLVMAddFunction(
            module: LLVMModuleRef,
            name: *const c_char,
            ty: LLVMTypeRef,
        ) -> LLVMValueRef;
        pub fn LLVMAddGlobal(
            module: LLVMModuleRef,
            ty: LLVMTypeRef,
            name: *const c_char,
        ) -> LLVMValueRef;
        pub fn LLVMLookupIntrinsicID(name: *const c_char, length: usize) -> c_uint;
        pub fn LLVMGetIntrinsicDeclaration(
            module: LLVMModuleRef,
            id: c_uint,
            overloads: *mut LLVMTypeRef,
            count: usize,
        ) -> LLVMValueRef;

        pub fn LLVMCreateMemoryBufferWithContentsOfFile(
            path: *const c_char,
            buffer: *mut LLVMMemoryBufferRef,
            message: *mut *mut c_char,
        ) -> LLVMBool;
        pub fn LLVMDisposeMemoryBuffer(buffer: LLVMMemoryBufferRef);
        pub fn LLVMParseBitcodeInContext2(
            context: LLVMContextRef,
            buffer: LLVMMemoryBufferRef,
            module: *mut LLVMModuleRef,
        ) -> LLVMBool;
        pub fn LLVMVerifyModule(
            module: LLVMModuleRef,
            action: c_uint,
            message: *mut *mut c_char,
        ) -> LLVMBool;
        pub fn LLVMLinkModules2(destination: LLVMModuleRef, source: LLVMModuleRef) -> LLVMBool;

        pub fn LLVMVoidTypeInContext(context: LLVMContextRef) -> LLVMTypeRef;
        pub fn LLVMIntTypeInContext(context: LLVMContextRef, bits: c_uint) -> LLVMTypeRef;
        pub fn LLVMPointerTypeInContext(context: LLVMContextRef, space: c_uint) -> LLVMTypeRef;
        pub fn LLVMStructTypeInContext(
            context: LLVMContextRef,
            fields: *mut LLVMTypeRef,
            count: c_uint,
            packed: LLVMBool,
        ) -> LLVMTypeRef;
        pub fn LLVMStructCreateNamed(context: LLVMContextRef, name: *const c_char) -> LLVMTypeRef;
        pub fn LLVMStructSetBody(
            ty: LLVMTypeRef,
            fields: *mut LLVMTypeRef,
            count: c_uint,
            packed: LLVMBool,
        );
        pub fn LLVMArrayType2(element: LLVMTypeRef, count: u64) -> LLVMTypeRef;
        pub fn LLVMFunctionType(
            result: LLVMTypeRef,
            params: *mut LLVMTypeRef,
            count: c_uint,
            variadic: LLVMBool,
        ) -> LLVMTypeRef;

        pub fn LLVMConstInt(
            ty: LLVMTypeRef,
            value: c_ulonglong,
            sign_extend: LLVMBool,
        ) -> LLVMValueRef;
        pub fn LLVMConstNull(ty: LLVMTypeRef) -> LLVMValueRef;
        pub fn LLVMConstNamedStruct(
            ty: LLVMTypeRef,
            fields: *mut LLVMValueRef,
            count: c_uint,
        ) -> LLVMValueRef;
        pub fn LLVMConstArray2(
            element: LLVMTypeRef,
            items: *mut LLVMValueRef,
            count: u64,
        ) -> LLVMValueRef;
        pub fn LLVMConstStringInContext2(
            context: LLVMContextRef,
            bytes: *const c_char,
            length: usize,
            no_nul: LLVMBool,
        ) -> LLVMValueRef;
        pub fn LLVMSizeOf(ty: LLVMTypeRef) -> LLVMValueRef;
        pub fn LLVMGetInlineAsm(
            ty: LLVMTypeRef,
            code: *const c_char,
            code_length: usize,
            constraints: *const c_char,
            constraints_length: usize,
            side_effects: LLVMBool,
            align_stack: LLVMBool,
            dialect: c_uint,
            can_throw: LLVMBool,
        ) -> LLVMValueRef;
        pub fn LLVMIsAConstantInt(value: LLVMValueRef) -> LLVMValueRef;
        pub fn LLVMConstIntGetZExtValue(value: LLVMValueRef) -> c_ulonglong;

        pub fn LLVMGetParam(function: LLVMValueRef, index: c_uint) -> LLVMValueRef;
        pub fn LLVMSetValueName2(value: LLVMValueRef, name: *const c_char, length: usize);
        pub fn LLVMSetLinkage(global: LLVMValueRef, linkage: Linkage);
        pub fn LLVMSetInitializer(global: LLVMValueRef, value: LLVMValueRef);
        pub fn LLVMSetGlobalConstant(global: LLVMValueRef, constant: LLVMBool);
        pub fn LLVMSetUnnamedAddress(global: LLVMValueRef, kind: c_uint);
        pub fn LLVMGlobalGetValueType(global: LLVMValueRef) -> LLVMTypeRef;
        pub fn LLVMReplaceAllUsesWith(old: LLVMValueRef, new: LLVMValueRef);
        pub fn LLVMInstructionEraseFromParent(instruction: LLVMValueRef);

        pub fn LLVMAppendBasicBlockInContext(
            context: LLVMContextRef,
            function: LLVMValueRef,
            name: *const c_char,
        ) -> LLVMBasicBlockRef;
        pub fn LLVMGetBasicBlockTerminator(block: LLVMBasicBlockRef) -> LLVMValueRef;

        pub fn LLVMCreateBuilderInContext(context: LLVMContextRef) -> LLVMBuilderRef;
        pub fn LLVMDisposeBuilder(builder: LLVMBuilderRef);
        pub fn LLVMPositionBuilderAtEnd(builder: LLVMBuilderRef, block: LLVMBasicBlockRef);
        pub fn LLVMGetInsertBlock(builder: LLVMBuilderRef) -> LLVMBasicBlockRef;
        pub fn LLVMBuildAlloca(
            builder: LLVMBuilderRef,
            ty: LLVMTypeRef,
            name: *const c_char,
        ) -> LLVMValueRef;
        pub fn LLVMBuildLoad2(
            builder: LLVMBuilderRef,
            ty: LLVMTypeRef,
            pointer: LLVMValueRef,
            name: *const c_char,
        ) -> LLVMValueRef;
        pub fn LLVMBuildStore(
            builder: LLVMBuilderRef,
            value: LLVMValueRef,
            pointer: LLVMValueRef,
        ) -> LLVMValueRef;
        pub fn LLVMBuildExtractValue(
            builder: LLVMBuilderRef,
            aggregate: LLVMValueRef,
            index: c_uint,
            name: *const c_char,
        ) -> LLVMValueRef;
        pub fn LLVMBuildInsertValue(
            builder: LLVMBuilderRef,
            aggregate: LLVMValueRef,
            value: LLVMValueRef,
            index: c_uint,
            name: *const c_char,
        ) -> LLVMValueRef;
        pub fn LLVMBuildInBoundsGEP2(
            builder: LLVMBuilderRef,
            ty: LLVMTypeRef,
            pointer: LLVMValueRef,
            indices: *mut LLVMValueRef,
            count: c_uint,
            name: *const c_char,
        ) -> LLVMValueRef;
        pub fn LLVMBuildICmp(
            builder: LLVMBuilderRef,
            predicate: IntPredicate,
            lhs: LLVMValueRef,
            rhs: LLVMValueRef,
            name: *const c_char,
        ) -> LLVMValueRef;
        pub fn LLVMBuildPhi(
            builder: LLVMBuilderRef,
            ty: LLVMTypeRef,
            name: *const c_char,
        ) -> LLVMValueRef;
        pub fn LLVMAddIncoming(
            phi: LLVMValueRef,
            values: *mut LLVMValueRef,
            blocks: *mut LLVMBasicBlockRef,
            count: c_uint,
        );
        pub fn LLVMBuildSelect(
            builder: LLVMBuilderRef,
            condition: LLVMValueRef,
            yes: LLVMValueRef,
            no: LLVMValueRef,
            name: *const c_char,
        ) -> LLVMValueRef;
        pub fn LLVMBuildCall2(
            builder: LLVMBuilderRef,
            ty: LLVMTypeRef,
            callee: LLVMValueRef,
            args: *mut LLVMValueRef,
            count: c_uint,
            name: *const c_char,
        ) -> LLVMValueRef;
        pub fn LLVMBuildBr(builder: LLVMBuilderRef, target: LLVMBasicBlockRef) -> LLVMValueRef;
        pub fn LLVMBuildCondBr(
            builder: LLVMBuilderRef,
            condition: LLVMValueRef,
            yes: LLVMBasicBlockRef,
            no: LLVMBasicBlockRef,
        ) -> LLVMValueRef;
        pub fn LLVMBuildRet(builder: LLVMBuilderRef, value: LLVMValueRef) -> LLVMValueRef;
        pub fn LLVMBuildRetVoid(builder: LLVMBuilderRef) -> LLVMValueRef;
        pub fn LLVMBuildUnreachable(builder: LLVMBuilderRef) -> LLVMValueRef;
    }

    macro_rules! builders {
        ($signature:ident: $($name:ident),* $(,)?) => {
            unsafe extern "C" {
                $(pub fn $name(
                    builder: LLVMBuilderRef,
                    a: LLVMValueRef,
                    b: builders!(@second $signature),
                    name: *const c_char,
                ) -> LLVMValueRef;)*
            }
        };
        (@second binary) => { LLVMValueRef };
        (@second cast) => { LLVMTypeRef };
    }

    builders!(binary: LLVMBuildAdd, LLVMBuildSub, LLVMBuildMul, LLVMBuildAnd, LLVMBuildOr,
        LLVMBuildXor, LLVMBuildShl, LLVMBuildLShr, LLVMBuildUDiv, LLVMBuildURem);
    builders!(cast: LLVMBuildZExt, LLVMBuildSExt, LLVMBuildTrunc, LLVMBuildPtrToInt,
        LLVMBuildIntToPtr);
}
