# Blimp Compilation: AST to Native Code

> This is a living document. It describes the compilation pipeline from our existing AST through a new intermediate representation to LLVM IR and native executables. Decisions are recorded as they're made; open questions live at the bottom.

## Where We Are

We have a working frontend: lexer (`src/lexer.zig`), parser (`src/parser.zig`), AST (`src/ast.zig`), type checker with a 2-pass cross-actor registry (`src/checker.zig`), and a tree-walking interpreter (`src/eval.zig`) that runs actors, message sends, `become`, `reply`, `situation`, pipes, dot access, and guards in the REPL.

The interpreter works but it's slow and boxed. Every value is a heap-allocated tagged union (`src/value.zig`). Every operation dispatches through a switch. There's no way to target WASM, no way to emit a binary, and no path to the performance characteristics actors need (millions of messages per second).

The next step is compilation. The decision is made: **use the LLVM C API directly from Zig via `@cImport`**. No text-based IR emission, no shelling out to `llc`. Zig's C interop makes this trivial.

## Pipeline Overview

```
source
  |
  v
lexer (src/lexer.zig) ............ exists
  |
  v
parser (src/parser.zig) .......... exists
  |
  v
AST (src/ast.zig) ................ exists
  |
  v
type checker (src/checker.zig) ... exists (2-pass, cross-actor)
  |
  v
lowering (src/lower.zig) ......... NEW -- AST -> Blimp IR
  |
  v
Blimp IR (src/ir.zig) ............ NEW -- typed SSA, basic blocks
  |
  v
codegen (src/codegen.zig) ........ NEW -- Blimp IR -> LLVM IR via C API
  |
  v
LLVM IR
  |
  v
LLVM optimization passes ......... LLVM handles this
  |
  v
object file (.o)
  |
  v
linker -> executable .............. link against runtime
```

**What exists:** Everything above the `lower.zig` line. The lexer tokenizes, the parser builds the AST (tagged union with source locations), the checker validates types and builds an `ActorRegistry` mapping actor names to their state fields and handler signatures. The `eval.zig` interpreter walks the AST directly -- this is what gets replaced by compilation.

**What gets built:** Four new files. `ir.zig` defines a lower-level IR with basic blocks, SSA locals, and explicit control flow. `lower.zig` transforms the AST into this IR. `codegen.zig` walks the Blimp IR and emits LLVM IR through the C API. A small runtime (`runtime.zig` or `runtime.c`) provides actor scheduling, mailbox operations, and memory management.

---

## Blimp IR Design

### Why not emit LLVM directly from the AST?

The AST is too high-level. It has `become` statements, pipe expressions, `situation` branches with pattern matching, actor definitions with handler tables. LLVM speaks basic blocks, phi nodes, and `getelementptr`. Trying to go straight from one to the other produces tangled code that's impossible to optimize or debug.

The Blimp IR sits in between. It's low enough that each IR operation maps cleanly to one or two LLVM instructions. It's high enough that it still carries type information and you can read it.

### Shape of the IR

```
Module
  functions: [Function]
  globals: [Global]
  actor_descriptors: [ActorDescriptor]

Function
  name: []const u8
  params: [Param]
  return_type: IRType
  blocks: [BasicBlock]

BasicBlock
  label: u32
  instructions: [Instruction]
  terminator: Terminator

Instruction
  dest: ?Local          -- SSA target (%0, %1, ...)
  op: Op

Local
  id: u32               -- %0, %1, %2, ...
  ty: IRType
```

### Instruction set

```
-- Arithmetic
%2 = add i64 %0, %1
%2 = sub i64 %0, %1
%2 = mul i64 %0, %1
%2 = div i64 %0, %1
%2 = fadd f64 %0, %1
%2 = fsub f64 %0, %1
%2 = fmul f64 %0, %1
%2 = fdiv f64 %0, %1

-- Comparison
%2 = icmp eq i64 %0, %1
%2 = icmp lt i64 %0, %1
%2 = fcmp oeq f64 %0, %1
%2 = fcmp olt f64 %0, %1

-- Logical
%2 = and i1 %0, %1
%2 = or i1 %0, %1
%1 = not i1 %0

-- Memory
%1 = alloca IRType
store IRType %0, ptr %1
%2 = load IRType, ptr %1
%2 = gep ptr %0, i64 %1            -- struct/array field access

-- Function
%1 = call RetType @name(%0, ...)
ret IRType %0

-- Constants
%0 = const_int i64 42
%0 = const_float f64 3.14
%0 = const_bool i1 true
%0 = const_atom i32 <intern_id>
%0 = const_nil

-- Actor operations (lowered to runtime calls in codegen)
%1 = actor_create @descriptor
%2 = actor_send %1, atom_id, [args...]
%1 = actor_become ptr %state, [field_values...]
%1 = handler_lookup ptr %table, i32 %atom_id

-- Conversion
%1 = int_to_float %0
```

### Terminators

Every basic block ends with exactly one terminator:

```
br label %target                            -- unconditional jump
br_cond i1 %cond, label %then, label %else  -- conditional branch
ret IRType %value                            -- return
unreachable                                  -- dead code
```

### Types

```zig
pub const IRType = union(enum) {
    i1,          // Bool
    i8,          // byte (for string data)
    i32,         // Atom (interned index)
    i64,         // Int
    f64,         // Float
    ptr,         // generic pointer
    void,
    structure: []const IRType,  // Tuple, actor struct, etc.
    tagged_union: struct {      // Value (Any type)
        tag_type: *const IRType,
        variants: []const IRType,
    },
};
```

---

## How Blimp Constructs Lower to IR

### Pure expressions: `1 + 2 * 3`

The AST for this is a `binary_op(add, integer_lit(1), binary_op(mul, integer_lit(2), integer_lit(3)))`. Lowering walks the tree bottom-up:

```
%0 = const_int i64 2
%1 = const_int i64 3
%2 = mul i64 %0, %1
%3 = const_int i64 1
%4 = add i64 %3, %2
```

In LLVM, this becomes:

```llvm
%0 = add i64 1, 6   ; LLVM constant-folds 2*3
```

### Assignment: `x = 1 + 2`

Locals are SSA. Assignment creates a new local:

```
%0 = const_int i64 1
%1 = const_int i64 2
%2 = add i64 %0, %1
; x is now %2 in the local name table
```

No alloca needed for simple locals. The lowering pass maintains a map of variable names to SSA locals.

### Pipe expressions: `items |> length(_)`

Pipes desugar to function calls during lowering. The `_` placeholder is replaced by the left-hand value:

```blimp
items |> calculate_tax(_, region) |> finalize(_, payment)
```

Becomes:

```
%0 = load [Item] %items
%1 = load Atom %region
%2 = call Float @calculate_tax(%0, %1)
%3 = load Payment %payment
%4 = call Receipt @finalize(%2, %3)
```

This happens in `lower.zig` -- by the time we reach `codegen.zig`, there are no pipe expressions. Just calls.

### `situation` / `case`: conditional branches

```blimp
situation color do
  :red -> become color: :green
  :green -> become color: :yellow
  :yellow -> become color: :red
end
```

Lowers to a chain of conditional branches:

```
entry:
  %0 = load i32 %color_atom
  %1 = const_atom i32 :red
  %2 = icmp eq i32 %0, %1
  br_cond %2, label %branch_red, label %check_green

check_green:
  %3 = const_atom i32 :green
  %4 = icmp eq i32 %0, %3
  br_cond %4, label %branch_green, label %check_yellow

check_yellow:
  %5 = const_atom i32 :yellow
  %6 = icmp eq i32 %0, %5
  br_cond %6, label %branch_yellow, label %no_match

branch_red:
  ; become color: :green
  ...
  br label %merge

branch_green:
  ; become color: :yellow
  ...
  br label %merge

branch_yellow:
  ; become color: :red
  ...
  br label %merge

no_match:
  ; return nil or unreachable
  br label %merge

merge:
  ; phi or void -- depends on whether situation produces a value
```

For integer/string matching, the same pattern applies. For `_` wildcard branches, the last `check_*` just falls through to the wildcard body.

### `become`: state transition

`become` is the actor's state transition. In the compiled representation, an actor's state is a struct allocated on the heap. `become` allocates a new state struct (or reuses the old one via Perceus) and swaps the actor's state pointer.

```blimp
actor Counter do
  state count: Int :: 0
  on :increment do
    become count: count + 1
    reply count + 1
  end
end
```

The handler compiles to a function:

```
define i64 @Counter_handler_increment(ptr %actor_ptr) {
entry:
  ; Load current state
  %state_ptr = gep ptr %actor_ptr, 0         ; actor.state_ptr
  %old_state = load ptr %state_ptr
  %old_count = gep ptr %old_state, 0          ; state.count
  %count_val = load i64 %old_count

  ; Compute new count
  %new_count = add i64 %count_val, 1

  ; Allocate new state (or reuse if refcount == 1)
  %new_state = call ptr @blimp_alloc_state(i64 8)   ; sizeof(CounterState)
  store i64 %new_count, ptr %new_state

  ; Swap state pointer
  store ptr %new_state, ptr %state_ptr

  ; Reply: count + 1 (uses the value computed in this scope, not the new state)
  %reply_val = add i64 %count_val, 1
  ret i64 %reply_val
}
```

Key detail: `reply` in the same handler as `become` uses the **old** scope values. The lowering pass captures old-scope locals before processing `become`, matching the interpreter's semantics in `eval.zig` where `become` mutates the actor instance but the handler's local scope keeps the old bindings.

### Message send: `Cart <- :add(item)`

A message send lowers to a handler table lookup followed by a function call (synchronous) or a mailbox enqueue (async):

```
; Synchronous (reply-expected) path:
%0 = load ptr %Cart_actor_ptr
%1 = gep ptr %0, 1                             ; actor.handler_table_ptr
%2 = load ptr %1
%3 = const_atom i32 :add
%4 = call ptr @blimp_lookup_handler(%2, %3)     ; returns function pointer
%5 = call i64 %4(%0, %item_val)                 ; call handler with actor + args
```

In Phase 4 (actor runtime), this becomes asynchronous: enqueue the message into the target actor's mailbox, and the scheduler calls the handler when the actor processes the message. The synchronous version works for Phase 1-3 where everything is single-threaded.

### Actor definition

An actor definition produces three things:

1. A **state struct type** derived from the `state` declarations
2. A **handler table** (array of `{atom_id, fn_ptr, param_count}`)
3. An **initialization function** that allocates state with defaults and builds the handler table

```blimp
actor Counter do
  state count: Int :: 0
  on :increment do ... end
  on :get do ... end
end
```

Produces:

```
; State struct
%CounterState = type { i64 }   ; { count: i64 }

; Handler table (global constant)
@Counter_handlers = constant [2 x {i32, ptr, i32}] [
  { i32 <atom_id_increment>, ptr @Counter_handler_increment, i32 0 },
  { i32 <atom_id_get>, ptr @Counter_handler_get, i32 0 }
]

; Init function
define ptr @Counter_init() {
  %actor = call ptr @blimp_alloc_actor(i64 24)   ; sizeof(ActorStruct)
  %state = call ptr @blimp_alloc_state(i64 8)    ; sizeof(CounterState)
  store i64 0, ptr %state                         ; count = 0
  store ptr %state, gep ptr %actor, 0             ; actor.state_ptr
  store ptr @Counter_handlers, gep ptr %actor, 1  ; actor.handler_table_ptr
  store ptr null, gep ptr %actor, 2               ; actor.mailbox_ptr (Phase 4)
  ret ptr %actor
}
```

### Guards: `when payment > 0`

Guards compile to a conditional branch at the top of the handler. If the guard fails, the handler returns a sentinel indicating "no match" (or, with multi-clause handlers, falls through to the next clause):

```
define {i1, i64} @Checkout_handler_charge(ptr %actor_ptr, i64 %payment) {
entry:
  %guard = icmp sgt i64 %payment, 0
  br_cond %guard, label %body, label %guard_fail

body:
  ; ... handler body ...
  ret {i1, i64} {true, %result}

guard_fail:
  ret {i1, i64} {false, 0}
}
```

The caller checks the `i1` flag. With multiple clauses for the same message name, the dispatch code tries each clause in order until one's guard passes.

---

## LLVM C API Integration

### How Zig talks to LLVM

Zig has first-class C interop. We import LLVM's C API headers directly:

```zig
const c = @cImport({
    @cInclude("llvm-c/Core.h");
    @cInclude("llvm-c/Analysis.h");
    @cInclude("llvm-c/Target.h");
    @cInclude("llvm-c/TargetMachine.h");
});
```

This gives us all of LLVM's C API functions as Zig functions. No bindings to write, no FFI overhead.

### Build system integration

In `build.zig`, we add LLVM as a system dependency:

```zig
// Link against LLVM installed via brew
const codegen_mod = b.addModule("codegen", .{
    .root_source_file = b.path("src/codegen.zig"),
    .target = target,
});
codegen_mod.addSystemIncludePath(.{ .cwd_relative = "/opt/homebrew/opt/llvm/include" });
codegen_mod.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/opt/llvm/lib" });
codegen_mod.linkSystemLibrary("LLVM");
```

On macOS: `brew install llvm`. On Linux: `apt install llvm-dev`. The LLVM version doesn't matter much for the C API -- it's been stable for years.

### Key LLVM concepts

| LLVM Concept | What it is | Blimp equivalent |
|---|---|---|
| `LLVMModuleRef` | A compilation unit | One `.blimp` file |
| `LLVMContextRef` | Thread-local state for types/constants | One per compilation |
| `LLVMBuilderRef` | Cursor that emits instructions | Walks one Blimp IR function at a time |
| `LLVMBasicBlockRef` | Sequence of instructions with one entry | Blimp IR `BasicBlock` |
| `LLVMTypeRef` | A type (i64, struct, ptr, ...) | Maps from `IRType` |
| `LLVMValueRef` | An instruction, constant, or argument | Maps from `Local` or literal |

### Example: compiling `1 + 2` end-to-end

Here's the actual Zig code that would create an LLVM module, define a function, and emit an add instruction:

```zig
const c = @cImport({
    @cInclude("llvm-c/Core.h");
    @cInclude("llvm-c/Analysis.h");
    @cInclude("llvm-c/Target.h");
    @cInclude("llvm-c/TargetMachine.h");
});

pub fn compileOnePlusTwo() void {
    // Create context, module, builder
    const ctx = c.LLVMContextCreate();
    defer c.LLVMContextDispose(ctx);

    const module = c.LLVMModuleCreateWithNameInContext("blimp_main", ctx);
    defer c.LLVMDisposeModule(module);

    const builder = c.LLVMCreateBuilderInContext(ctx);
    defer c.LLVMDisposeBuilder(builder);

    // Define function: i64 @main()
    const i64_type = c.LLVMInt64TypeInContext(ctx);
    const fn_type = c.LLVMFunctionType(i64_type, null, 0, 0);
    const func = c.LLVMAddFunction(module, "main", fn_type);

    // Create entry basic block
    const entry = c.LLVMAppendBasicBlockInContext(ctx, func, "entry");
    c.LLVMPositionBuilderAtEnd(builder, entry);

    // Emit: %result = add i64 1, 2
    const one = c.LLVMConstInt(i64_type, 1, 0);
    const two = c.LLVMConstInt(i64_type, 2, 0);
    const sum = c.LLVMBuildAdd(builder, one, two, "result");

    // Emit: ret i64 %result
    _ = c.LLVMBuildRet(builder, sum);

    // Verify the module
    _ = c.LLVMVerifyModule(module, c.LLVMAbortProcessAction, null);

    // Emit to object file
    c.LLVMInitializeNativeTarget();
    c.LLVMInitializeNativeAsmPrinter();

    var target: c.LLVMTargetRef = null;
    var err_msg: [*c]u8 = null;
    _ = c.LLVMGetTargetFromTriple(
        c.LLVMGetDefaultTargetTriple(),
        &target,
        &err_msg,
    );

    const machine = c.LLVMCreateTargetMachine(
        target,
        c.LLVMGetDefaultTargetTriple(),
        "generic",
        "",
        c.LLVMCodeGenLevelDefault,
        c.LLVMRelocDefault,
        c.LLVMCodeModelDefault,
    );

    _ = c.LLVMTargetMachineEmitToFile(
        machine,
        module,
        "output.o",
        c.LLVMObjectFile,
        &err_msg,
    );
}
```

That's the entire codegen for a trivial program. The `codegen.zig` module will follow this pattern but walk the Blimp IR instead of hardcoding constants.

### The codegen walker

The structure of `codegen.zig`:

```zig
pub const Codegen = struct {
    ctx: c.LLVMContextRef,
    module: c.LLVMModuleRef,
    builder: c.LLVMBuilderRef,
    locals: std.AutoHashMap(u32, c.LLVMValueRef),  // SSA local id -> LLVM value
    atom_table: *AtomTable,

    pub fn emitModule(self: *Codegen, ir_module: *const ir.Module) void {
        for (ir_module.functions) |func| {
            self.emitFunction(func);
        }
    }

    fn emitFunction(self: *Codegen, func: ir.Function) void {
        // Create LLVM function type from IR param/return types
        // Create basic blocks
        // Emit instructions for each block
        // Wire up terminators
    }

    fn emitInstruction(self: *Codegen, inst: ir.Instruction) c.LLVMValueRef {
        return switch (inst.op) {
            .add_i64 => c.LLVMBuildAdd(self.builder, ...),
            .fadd_f64 => c.LLVMBuildFAdd(self.builder, ...),
            .icmp_eq => c.LLVMBuildICmp(self.builder, c.LLVMIntEQ, ...),
            .call => c.LLVMBuildCall2(self.builder, ...),
            .alloca => c.LLVMBuildAlloca(self.builder, ...),
            .load => c.LLVMBuildLoad2(self.builder, ...),
            .store => c.LLVMBuildStore(self.builder, ...),
            .const_int => c.LLVMConstInt(self.i64_type, ...),
            // ...
        };
    }
};
```

---

## Runtime Type Representation

How Blimp's type system (from `src/types.zig`) maps to LLVM types at runtime:

| Blimp Type | LLVM Type | Size | Notes |
|---|---|---|---|
| `Int` | `i64` | 8 bytes | Signed 64-bit integer |
| `Float` | `f64` (double) | 8 bytes | IEEE 754 double |
| `Bool` | `i1` | 1 bit | LLVM optimizes to i8 in memory |
| `Atom` | `i32` | 4 bytes | Index into global atom intern table |
| `String` | `{i64, ptr}` | 16 bytes | `{length, data_pointer}`. Immutable. |
| `Nil` | `i1` (constant 0) | - | Sentinel value, often a null pointer |
| `List` | `ptr` | 8 bytes | Pointer to cons cell `{ptr head, ptr tail}` or array `{i64 len, ptr data}` |
| `Tuple` | `{T0, T1, ...}` | varies | LLVM struct with element types. `{:ok, 42}` is `{i32, i64}`. |
| `Map` | `ptr` | 8 bytes | Pointer to runtime hash map structure |
| `Actor` | `ptr` | 8 bytes | Pointer to actor struct (see below) |
| `Any` | `{i8, i64}` | 9-16 bytes | Tagged union: tag byte + payload. See below. |
| `Hole` | not representable | - | Compile error if a Hole reaches codegen |

### The `Any` type (boxed value)

When the type checker can't resolve a type to a concrete one (or when `Any` is explicitly declared), values are boxed into a tagged union:

```
%BlimpValue = type { i8, i64 }
;                    ^    ^
;                    |    payload (or pointer for heap types)
;                    tag: 0=int, 1=float, 2=bool, 3=atom, 4=string, 5=list, ...
```

For types that fit in 8 bytes (Int, Float, Bool, Atom), the payload holds the value directly. For heap types (String, List, Map, Actor), the payload holds a pointer.

The monomorphization question (see Open Questions) determines how often we need `Any`. If we can resolve most types at compile time, `Any` is rare. If handlers accept `Any` parameters, every call site boxes.

### Atom interning

Atoms (`:ok`, `:error`, `:increment`) are interned at compile time into a global table. Each unique atom string gets an `i32` ID. The compiler builds this table during lowering:

```zig
pub const AtomTable = struct {
    entries: std.StringHashMap(u32),
    next_id: u32 = 0,

    pub fn intern(self: *AtomTable, name: []const u8) u32 {
        if (self.entries.get(name)) |id| return id;
        const id = self.next_id;
        self.next_id += 1;
        self.entries.put(name, id);
        return id;
    }
};
```

At runtime, atom comparison is `i32 == i32` -- a single instruction. The atom table is emitted as a global constant for debugging and `format()`.

### String representation

Strings are immutable `{length, pointer}` pairs. The pointer refers to UTF-8 data. String concatenation (if we add it) allocates a new buffer. The length-prefixed representation avoids null terminator issues and makes slicing O(1).

```
%BlimpString = type { i64, ptr }
; Example: "hello" -> { 5, @str_hello }
; @str_hello = private constant [5 x i8] c"hello"
```

String literals are stored as global constants. Runtime-created strings are heap-allocated.

---

## Actor Runtime Architecture

### Actor struct layout

Every actor instance in memory has this shape:

```
%ActorStruct = type {
    ptr,    ; 0: state_ptr      -- pointer to the actor's current state struct
    ptr,    ; 1: handler_table  -- pointer to array of handler entries
    ptr,    ; 2: mailbox_ptr    -- pointer to mailbox (Phase 4, null until then)
    i32,    ; 3: atom_id        -- this actor's name as interned atom
    i8      ; 4: status         -- 0=idle, 1=processing, 2=dead
}
```

The state pointer points to a type-specific struct. For `Counter` with `state count: Int :: 0`, the state struct is `{ i64 }`. For `Checkout` with `state items: [Item] :: [], total: Float :: 0.0`, it's `{ ptr, f64 }`.

### Handler table

The handler table is a flat array of entries, one per message handler:

```
%HandlerEntry = type {
    i32,    ; atom_id of the message name (:increment, :get, etc.)
    ptr,    ; function pointer to the handler implementation
    i32     ; parameter count (for arity dispatch)
}
```

Handler lookup is linear search over the table. For actors with many handlers, we could switch to a hash map, but most actors have 2-5 handlers and linear search is cache-friendly.

The handler function signature follows a convention:

```
; Handler with 0 args:
define {i1, i64} @Actor_handler_name(ptr %actor_ptr)

; Handler with N args (boxed for now):
define {i1, i64} @Actor_handler_name(ptr %actor_ptr, i64 %arg0, i64 %arg1, ...)

; The i1 in the return is "did this clause match?" (for guarded multi-clause dispatch)
; The i64 is the reply value (or 0 if no reply)
```

### Mailbox (Phase 4)

The mailbox is a lock-free SPSC (single-producer, single-consumer) queue for Phase 4. Initially it's simpler:

```
%Message = type {
    i32,          ; handler atom_id
    i32,          ; arg_count
    ptr           ; pointer to args array
}

%Mailbox = type {
    ptr,          ; buffer (ring buffer of Message)
    i64,          ; capacity
    i64,          ; head (producer writes here)
    i64           ; tail (consumer reads here)
}
```

### Scheduler (Phase 4)

Simple round-robin cooperative scheduler. Each actor yields after processing one message. The scheduler maintains a run queue of actors with non-empty mailboxes:

```
while (run_queue not empty) {
    actor = dequeue(run_queue)
    msg = actor.mailbox.pop()
    handler = lookup(actor.handler_table, msg.atom_id)
    result = handler(actor, msg.args)
    if (actor.mailbox.non_empty()) {
        enqueue(run_queue, actor)
    }
}
```

For WASM, the scheduler is fully cooperative (no preemption). For native, we can eventually use OS threads with work-stealing, one scheduler per core.

### `become` at runtime

`become` does not mutate state in place (that would violate immutability semantics and break time-travel debugging). Instead:

1. Allocate a new state struct (from the actor's arena)
2. Copy unchanged fields from old state
3. Write new field values
4. Atomic swap the actor's `state_ptr`
5. The old state is freed when its reference count drops to zero (Perceus) or when the arena is collected

With Perceus RC, if the old state has refcount 1 (no one else references it, which is the common case since actors are isolated), the allocator can reuse the memory in-place. This makes `become` effectively free in the steady state.

### Memory: per-actor arenas

Each actor gets its own arena allocator. All state structs, strings, lists, maps created by that actor are allocated from its arena. When the actor dies, the entire arena is freed at once.

Benefits:
- No cross-actor GC coordination (actors are isolated, no shared references)
- Actor death is O(1) regardless of how much state it accumulated
- Cache-friendly: an actor's working set is contiguous in memory
- Aligns perfectly with the "no shared memory" design decision (D8 in parser.md)

The arena grows in pages (e.g., 4KB). Small actors never need more than one page. Perceus RC operates within the arena to reuse freed blocks without returning them to the OS.

---

## Build Phases

### Phase 1: Pure Expressions (no actors)

**Goal:** `blimp compile hello.blimp -o hello && ./hello` works for programs with no actors.

What's in:
- Integer and float arithmetic
- Comparisons, logical operators
- Local variables and assignment
- Function calls (builtins: `length`, `max`, `min`, etc.)
- Pipe expressions (desugared to calls)
- `situation`/`case` (conditional branches)
- String, atom, bool, nil literals
- A minimal C runtime: `blimp_print_int`, `blimp_print_string`, `blimp_print_atom`

What's NOT in:
- Actors, `become`, `reply`, message send
- Lists, tuples, maps (heap-allocated data structures)
- The `Any` boxed type

**Files:**
- `src/ir.zig` -- IR data structures
- `src/lower.zig` -- AST -> IR for expressions and control flow
- `src/codegen.zig` -- IR -> LLVM IR
- `src/runtime.c` -- `blimp_print_int`, `blimp_print_string`, `blimp_print_atom`

**Test:** Compile and run `1 + 2 * 3`, print the result, exit.

### Phase 2: Data Structures

**Goal:** Lists, tuples, maps, and strings work with heap allocation.

What's added:
- Tagged union `BlimpValue` type for `Any`
- String heap allocation and comparison
- List as cons cells or contiguous arrays
- Tuple as LLVM structs (known at compile time)
- Map as runtime hash map (robin hood or similar)
- Dot access on maps/tuples
- Reference counting (Perceus) for heap-allocated values

**The Perceus question gets real here.** This phase forces us to decide the RC strategy. See Open Questions.

### Phase 3: Functions and Pattern Matching

**Goal:** Handlers compile as functions with pattern matching dispatch.

What's added:
- Handlers -> LLVM functions with the handler calling convention
- Multi-clause dispatch (try each clause's guard in order)
- `situation`/`case` with pattern matching (not just atom equality -- structural)
- Handler tables as global constants
- The checker's `ActorRegistry` feeds into codegen for handler table construction

### Phase 4: Actor Runtime

**Goal:** Actors run, send messages, `become`, `reply`. Single-threaded scheduler.

What's added:
- Actor struct allocation and initialization
- Handler dispatch via table lookup
- `become` with state snapshot allocation
- `reply` return value propagation
- Mailbox queue (SPSC)
- Round-robin scheduler
- Per-actor arena allocators
- Supervision basics: detect actor death, restart with initial state

**Test:** The `Shop` example from `core-language-feel.md` compiles and runs. `Checkout <- :add(item)` sends a message, `become` updates state, `reply` returns a value.

### Phase 5: WASM Target

**Goal:** Same compiler, `--target wasm32` flag.

What's added:
- LLVM targets `wasm32-unknown-unknown`
- Cooperative scheduler in userland (no OS threads in WASM)
- Minimal WASI imports for I/O
- Browser integration: export actor init/send functions for JS to call
- Linear memory management (WASM has no mmap, arenas must use `memory.grow`)

---

## Open Questions

### Q1: Perceus RC vs tracing GC vs arena-only?

Decision D3 in parser.md chose Perceus RC. But the implementation options have tradeoffs:

- **Perceus RC (current plan):** Deterministic deallocation, optimal reuse when refcount is 1 (common for actors due to isolation). Requires the compiler to insert `inc_ref`/`dec_ref` at every value transfer. Compile-time analysis can elide many of these. Cycles are impossible if actors don't share references (and they shouldn't by D8).
- **Arena-only (simplest):** Each actor just grows its arena forever and frees on death. No ref counting, no GC. Works great for short-lived actors. For long-lived actors that process millions of messages, the arena grows unbounded unless `become` reuses old state. Maybe arena + reuse analysis?
- **Tracing GC:** Most flexible but introduces pauses. Per-actor tracing GC is feasible (small heaps, isolated) but adds complexity.

Leaning toward: **Perceus for Phase 2-3, with per-actor arenas as the backing allocator.** The arena handles bulk deallocation on actor death. Perceus handles within-lifetime reuse. No cycles possible due to actor isolation.

### Q2: Closure representation

Blimp doesn't have closures in the traditional sense -- "everything is an actor" (D9). But handlers implicitly capture the actor's state fields. When we lower a handler to an LLVM function, the state fields are accessed through the actor pointer passed as the first argument. This is effectively a closure where the "captured environment" is the actor struct.

But what about nested actors? In `core-language-feel.md`, `Checkout` has children `TaxCalculator` and `PaymentProcessor`. Do children capture parent state? Currently in the interpreter (`eval.zig`), nested actors don't have access to parent state -- they're fully independent. This seems right. Children communicate with parents via message sends, not by capturing their variables.

### Q3: Stack vs heap allocation for locals

Simple locals (`x = 1 + 2`) can live in SSA registers -- no allocation needed. But what about locals that hold heap types (strings, lists)? If a string local is never captured, it can live on the stack. If it escapes (passed to another actor via message send), it needs to be heap-allocated.

LLVM's `mem2reg` pass can promote `alloca` to registers when safe. So the simple strategy is: `alloca` everything, let LLVM optimize. Only worry about this if compile times or code quality suffer.

### Q4: How does `Any` work at compile time?

When a handler parameter is typed as `Any`, the caller must box the value. When the handler body uses the value, it must unbox (runtime type check).

Options:
- **Box everything:** All values are `BlimpValue` tagged unions. Simple but slow -- no unboxed arithmetic.
- **Monomorphize:** Generate specialized handler variants for common concrete types. `handler_add_Int`, `handler_add_Float`, etc. Fast but code size explodes.
- **Box at boundaries only:** Concrete types inside a handler are unboxed. Boxing happens only when passing to/from `Any`-typed interfaces. This is the Rust/Swift approach.

Leaning toward: **Box at boundaries only.** Within an actor's handler body, the type checker knows concrete types (D11 requires explicit annotations). Boxing only happens at actor boundaries when types are `Any`.

### Q5: Tail call optimization for recursive handlers?

An actor that sends a message to itself (`Self <- :process(next_item)`) is conceptually a loop. Can we optimize this to avoid growing the call stack? LLVM supports tail calls (`musttail` annotation), but only with the right calling convention.

For self-sends that are the last operation in a handler, we can lower them as tail calls. The scheduler then doesn't need to return from the handler -- it jumps directly to the next invocation. This matters for actors that process long streams of messages.

### Q6: Bubble (error) propagation at the IR level

`bubble` creates a failure signal that propagates up the supervision tree. At the IR level, this could be:
- A special return value (like Go's error return)
- A setjmp/longjmp pair
- An exception-like mechanism using LLVM's landingpad

Leaning toward: **Error return values.** Every handler that `bubbles(Strategy)` returns `{i1 ok, i64 value}`. The caller checks the `ok` flag. `orelse` desugars to checking this flag and calling the fallback. This is the simplest, most predictable approach. No hidden control flow.

### Q7: Debug information

LLVM supports DWARF debug info. If we emit it, you can step through compiled Blimp code in lldb/gdb and see Blimp source lines, variable names, and types. This requires mapping Blimp source locations (which we already track in `ast.Loc`) through to LLVM debug metadata.

Not critical for Phase 1, but important eventually. The REPL/time-travel debugger could use this for native debugging instead of the interpreter.

---

## Files That Will Be Created

```
chunks/lang/src/ir.zig          -- Blimp IR data structures (Module, Function,
                                   BasicBlock, Instruction, IRType, Local)
chunks/lang/src/lower.zig       -- AST -> Blimp IR lowering pass. Walks checked AST,
                                   produces IR functions. Desugars pipes, lowers
                                   situation/case to branches, lowers actors to
                                   structs + handler tables.
chunks/lang/src/codegen.zig     -- Blimp IR -> LLVM IR via @cImport of llvm-c/Core.h.
                                   Walks IR module, emits LLVM instructions, handles
                                   type mapping, atom table emission, object file output.
chunks/lang/src/runtime.zig     -- Runtime support functions called by compiled code.
                                   Actor allocation, handler dispatch, mailbox operations,
                                   arena allocator, atom table lookup, print functions.
                                   (May be runtime.c if pure C is simpler for linking.)
```

The existing files are untouched. `main.zig` will gain a `compile` subcommand alongside the existing `--repl` mode. The build system (`build.zig`) will gain an LLVM linkage option.

---

## References

- **LLVM C API docs:** https://llvm.org/doxygen/group__LLVMC.html
- **Perceus RC:** "Perceus: Garbage Free Reference Counting with Reuse" (Reinking et al., 2021)
- **Zig C interop:** https://ziglang.org/documentation/master/#cImport
- **BEAM scheduler:** https://www.erlang.org/doc/apps/erts/ (inspiration for actor scheduling)
- **Pony runtime:** https://www.ponylang.io (per-actor GC, no shared memory)
- **Cranelift vs LLVM:** We chose LLVM because Zig already uses it and the C API is stable. Cranelift would be faster for JIT but we want AOT.
