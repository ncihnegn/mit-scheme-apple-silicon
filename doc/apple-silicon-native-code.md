# Native code on Apple silicon

Apple silicon enforces W^X: no memory page may be writable and executable at the
same time, and `mmap` with `PROT_WRITE|PROT_EXEC` fails.  MIT/GNU Scheme's
existing native-code runtime and AArch64 backend assume the opposite, so they
cannot run directly on Darwin/arm64.  This document records the target
architecture, required invariants, implementation phases, and prototype findings
(which were exercised on the SVM1 interpreter, not yet on native AArch64
machine code).

## Why the current design cannot just be ported

MIT/GNU Scheme treats the Scheme heap as stack, data store, and executable
code store at once, moves compiled code on garbage collection, emits
instructions into data space, and writes into its own instruction stream.

| Assumption in the current code | Where |
| --- | --- |
| Heap is one contiguous `mmap` requested with `PROT_READ\|PROT_WRITE\|PROT_EXEC` when `CC_IS_NATIVE` is defined | `src/microcode/ux.c` (`mmap_heap_malloc_try`) |
| If executable `mmap` fails, fall back to `OS_malloc` and warn that native code "will probably fail" | `src/microcode/ux.c` (`mmap_heap_malloc`) |
| `[stack][constant space][heap]` share one contiguous block; band-loaded compiled code lives in constant space | `src/microcode/memmag.c` (`reset_allocator_parameters`), `src/microcode/object.h` (`allocate_heap_space`) |
| `TC_COMPILED_CODE_BLOCK` uses the copying aligned-vector GC handler, so code blocks move at every collection | `src/microcode/gcloop.c` (`gc_handle_aligned_vector`) |
| Runtime-compiled and cross-linked blocks are allocated in the ordinary heap (`flo:vector-cons` / `make-vector`) | `src/compiler/back/bittop.scm`, `src/compiler/base/crsend.scm` |
| Compiled code and C utilities write into code blocks at run time (variable caches, UUO link code, linkage-section headers) | `src/microcode/cmpint.c`, `src/microcode/cmpintmd/aarch64.c` |
| Compiled AArch64 blocks execute inline `STR` stores into their own `CC_BLOCK_ADDR_END(block)[-1]` environment slot while executing in that block | `src/compiler/machines/aarch64/rules3.scm` (`generate/quotation-header`, `generate/remote-link`, `generate/remote-links`) |
| Trampolines (`compiler_utilities` in `constant_space` and dynamic trampolines at `Free`) emit and execute machine instructions in non-arena memory | `src/microcode/cmpint.c` (`make_compiler_utilities`, `make_trampoline`), `src/microcode/cmpintmd/aarch64.c` (`store_trampoline_insns`) |
| Pre-existing AArch64 and FASL bugs: broken `ADRP` assertions and ±4 GiB UUO limit, raw `CTR_EL0` log2 shift in cache-line calculation, `[constant_start, Free)`-only I-cache flush, disabled `ADRP-ADD` macro, `TBZ`/`TBNZ` unsigned 14-bit offset and broken forward jump `(B (@PCO 4))`, off-by-one `(* 4 (- offset 2))` in backward branch relaxations (`B.`, `CBZ`/`CBNZ`, `TBZ`/`TBNZ`), `(LDR.V X ...)` width mismatch, and `faslhdr_utilities_end` checking `VECTOR_P` on the dumper's `compiler_utilities` pointer instead of `CC_BLOCK_P` | `src/microcode/cmpintmd/aarch64.c` (`write_uuo_target`, `aarch64_cache_line_sizes`, `aarch64_flush_i_cache`), `src/compiler/machines/aarch64/instr1.scm`, `src/compiler/machines/aarch64/instrf.scm`, `src/compiler/machines/aarch64/TODO`, `src/microcode/fasl.c` |
| The aarch64 protection hook is a stub (`XXX Make sure we're mapped write and execute`), and `HAVE_SIGCONTEXT` has no Darwin arm64 entry (`SSP`=`x28`, `Free`=`x20`) | `src/microcode/cmpintmd/aarch64.c` (`aarch64_reset_hook`), `src/microcode/uxtrap.h`, `src/microcode/cmpauxmd/aarch64.m4` |
| The only Mach `vm_protect`/`vm_region` path is x86-64/i386-only | `src/microcode/cmpintmd/x86-64.c` |
| Configure mapped only `i386`/`x86_64` host CPUs, rejecting `--enable-native-code=yes` on arm64 | `src/microcode/aclocal.m4` |

`MAP_JIT` alone is not sufficient: while Scheme executes, code pages must be
RX (non-writable), yet the linker, GC, loader, and compiler must write and
relocate code blocks, and compiled instructions cannot write to themselves
without jumping out to C.

## Architecture and Core Invariants

### 1. Split Data and Code Mappings

Separate writable Scheme data from executable native code:

```
[ Scheme stack | constant space | data heap ]   RW, NX   (plain mmap/malloc; C stack sp is separate on AArch64)
[ code arena: compiled-code blocks only ]       MAP_JIT, RX steady-state (RW only inside C write brackets)
```

- Data memory (`stack`, `constant_space`, `heap`) stays permanently
  read-write and non-executable (`PROT_READ | PROT_WRITE`).
- Executable code lives in a dedicated `code_arena` (`MAP_JIT` on Darwin/arm64,
  toggled per-thread between RX and RW via `pthread_jit_write_protect_np`, with
  `sys_icache_invalidate`; on other platforms, `mprotect` or RWX as configured).

### 2. Immovable, Mark-Sweep-Reclaimed Code Arena

- **Immovable**: Compiled-code blocks never move across GC, preserving entry
  addresses, UUO branch targets, and internal PC-relative offsets without
  rewiring live code pointers at every flip.
- **Arena reservation and overflow chunks**: Reserve a generous initial
  `MAP_JIT` chunk (`max(DEFAULT_CODE_ARENA_SIZE, band_code_size + runtime_code_headroom)`,
  e.g. 64–256 MiB virtual reservation—physical pages fault in lazily up to
  `code_alloc_next`), and chain additional `MAP_JIT` chunks if post-GC allocation
  still overflows so existing blocks remain permanently immovable (`code_address_p`
  checks all active chunks).
- **Mark-sweep reclamation (required)**: Scanning the entire used prefix
  `[code_start, code_alloc_next)` unconditionally as a GC root
  (`gc_scan_oldspace`) is acceptable only as an initial bring-up simplification
  and **must be replaced by mark-sweep reclamation** before native builds are
  usable:
  1. `DEFAULT_CONSTANT_SIZE` is only 8 MiB (`1024` 1024-word blocks in
     `src/microcode/option.c`), and a bump-only arena never frees dead code
     from `compile-file`, REPL evaluations, or reloaded files. (For native
     builds `compiler:cross-compiling?` is `#f`, so `compile-file` goes
     through `assemble-objects` too.)
  2. Every `TC_COMPILED_CODE_BLOCK` holds its evaluation `TC_ENVIRONMENT`
     (`CC_BLOCK_ADDR_END(block)[-1]`), variable caches (`TC_HUNK3`), UUO-linked closures,
     and literals (`compiled-code-block/marked-start` .. `constants-end` in
     `src/runtime/microcode-data.scm`). Treating every allocated arena block as
     an unconditional root keeps every environment, closure, and literal ever
     referenced by compiled code alive forever.
  - **External RW mark bitmap & mark worklist**: Maintain a `uint64_t * mark_bits`
    bitmap (1 bit per `SCHEME_OBJECT` word at the block header index) and an
    explicit `code_mark_stack` in ordinary RW C memory so marking live blocks
    needs no `MAP_JIT` write toggle and does not disturb `TC_MANIFEST_VECTOR`
    headers.
    - During `std_gc_pt1` (`src/microcode/memmag.c` / `src/microcode/gcloop.c`),
      when `gc_vector`, `gc_cc_entry`, or `gc_cc_return` encounters a `from`
      satisfying `code_address_p(from)`, mark it in `mark_bits` (if newly marked,
      push `from` onto `code_mark_stack`, and if `scanning_ephemerons_p` is set,
      call `queue_ephemerons_for_key(from)`) and return `from` without copying.
    - Drain `gc_scan_tospace` and `code_mark_stack` in an alternating loop until
      both are empty; popping a marked block scans its pointer region
      (`block + 2 + object_datum(block[1])` .. `block + 1 + object_datum(block[0])`)
      via `gc_scan_oldspace` inside a `code_arena` write bracket.
  - **Weak pairs and ephemerons (`src/microcode/gcloop.c`)**:
    `gc_transport_weak_pair` and `gc_transport_ephemeron` currently assume
    `!ADDRESS_IN_FROMSPACE_P(addr)` means immortal/GC-invariant. Define
    `ADDRESS_COLLECTABLE_P(addr)` as `(ADDRESS_IN_FROMSPACE_P(addr) || code_address_p(addr))`
    and use it instead of `ADDRESS_IN_FROMSPACE_P` in `gc_transport_weak_pair`,
    `gc_transport_ephemeron`, and `queue_ephemerons_for_key`:
    - In `weak_referent_forward`, when `code_address_p(addr)` holds, return
      `object` unchanged if `code_arena_marked_p(addr)` is true, or `collected`
      (`GC_RECLAIMED` / `SHARP_F`) if unmarked.
    - In `scan_ephemerons`, drain both `gc_scan_tospace` and `code_mark_stack`
      after `scan_newspace_addr`. Without this integration, ephemerons keyed by
      compiled procedures keep dead arena blocks alive forever, and `weak-cons`
      pairs retain dangling `TC_COMPILED_ENTRY` pointers into swept/reused
      executable memory.
  - **Self-describing swept holes**: Sweep unmarked blocks in `std_gc_pt2`
    (`CC_TRANSPORT_END`, after `update_weak_pointers()`) under a write bracket:
    write `make_nmv_header(hole_words - 1)` (`TC_MANIFEST_NM_VECTOR`) at
    `hole[0]`, coalesce adjacent `TC_MANIFEST_NM_VECTOR` holes, and thread
    `>= 2`-word holes onto the free list via `hole[1]` (1-word remainders carry
    `make_nmv_header(0)`). Because live arena blocks (`TC_COMPILED_CODE_BLOCK`
    and `compiler_utilities`) always start with `TC_MANIFEST_VECTOR` at `block[0]`
    whereas holes start with `TC_MANIFEST_NM_VECTOR` at `hole[0]`, linear
    walkers (`gc_scan_oldspace`, `Prim_band_dump`, `fasload`, and
    `find_code_address` in `src/microcode/uxtrap.c`) all skip free holes
    unambiguously.
  - **Band startup sizing (`src/microcode/option.c`)**: `option.c` currently
    sizes `constant_space` to exact `FASLHDR_CONSTANT_SIZE(&h)` (leaving only
    `CONSTANT_SPACE_FUDGE` = 128 words in `src/microcode/memmag.c`) because
    runtime `.com` loads and REPL compilations went into `heap`. Update
    `read_band_sizes` (`src/microcode/option.c`) to also read `FASLHDR_CODE_SIZE(&h)`
    and size the initial code arena to `band_code_size + runtime_code_headroom`
    (adding `--code` / `MITSCHEME_CODE_SIZE` while preserving `--constant` for
    `constant_space`).
  - In addition, when `compile-bin-file` / `compile-file` compiles solely to
    dump a `.com` file (`compiler-file-output`), installing transient blocks into
    the live executable arena should be skipped when the fasdumper can serialize
    heap-staged blocks directly (or freed promptly on sweep).

### 3. Separating Executable Blocks from Mutable Data, Quotation Headers, and Trampolines

1. **Ordinary literals and closures already live in writable memory**:
   A `TC_COMPILED_CODE_BLOCK`'s constants region (`compiled-code-block/marked-start`
   through `compiled-code-block/constants-end`, plus debugging-info and
   environment slots) holds only tagged pointers (`SCHEME_OBJECT` words) and
   linkage sections—not inline pairs, strings, vectors, or `TC_MANIFEST_CLOSURE`
   headers. Mutating `(set-car! '(1 2) 3)` or capturing closure free variables
   writes to the RW/NX data heap or constant space, never to the code block
   itself. No layout split of the constants section is required for literal
   mutation.
2. **Eliminate self-modifying environment stores in AArch64 compiled code**:
   In `src/compiler/machines/aarch64/rules3.scm`, `generate/quotation-header`
   (line 868), `generate/remote-link` (lines 899–901), and
   `generate/remote-links` (line 940) emit inline `STR` instructions inside the
   code block to store `reg:environment` into `CC_BLOCK_ADDR_END(block)[-1]`
   immediately before calling `comutil_link` (`code:compiler-link`). Because
   the CPU `PC` is inside the `MAP_JIT` arena when those `STR` instructions
   execute, keeping RX faults on the store, while toggling to RW would fault on
   the next instruction fetch.
   - **Fix**: Remove the environment `STR` instructions from `rules3.scm` and
     store `CC_BLOCK_ADDR_END(block_addr)[-1] = GET_ENV` inside `comutil_link`
     (`src/microcode/cmpint.c`, line 841) under a code-arena write bracket.
     `src/compiler/back/lapgn1.scm` always emits the `code:compiler-link` call
     even when `n_sections == 0`, and `generate/remote-links` iterates over its
     sub-block vector calling `comutil_link` once per block, so moving the
     store into `comutil_link` covers all three paths.
   - **Critical ordering**: `comutil_link` **must** store
     `CC_BLOCK_ADDR_END(block_addr)[-1] = GET_ENV` **before** calling
     `link_remaining_sections(&s)`—and **never** inside
     `comp_link_caches_restart` (`src/microcode/cmpint.c`, line 872)—because on
     a GC interrupt during linking, `comp_link_caches_restart` (line 878)
     restores `SET_ENV` by reading `cc_block_environment(MAKE_CC_BLOCK(s.block_address))`.
3. **Keep trampolines W^X-safe with exact GC & ASLR relocation**:
   `store_trampoline_insns` in `src/microcode/cmpintmd/aarch64.c` emits 3
   AArch64 instructions (`movz x17, #code; adr x1, storage; br x23`) with
   `pc_offset = 0` for two distinct consumers in `src/microcode/cmpint.c`.
   Dynamic trampolines cannot keep `TC_MANIFEST_NM_VECTOR` (`gc_handle_nmv` in
   `src/microcode/gcloop.c` skips `entry[-8]` without relocating `pc_offset`),
   and a `TC_MANIFEST_CLOSURE` trampoline cannot target a C `.text` label
   (`gc_handle_manifest_closure` calls `cc_entry_to_block_address` on the target,
   and `relocate_address` cannot relocate `.text` across ASLR). Use a closed
   two-part layout:
   - **`compiler_utilities` (`make_compiler_utilities` in `src/microcode/cmpint.c`)**:
     Allocate in `code_arena` (instead of `copy_to_constant_space`) with **3
     entries** on AArch64: Entry 0 (`return_to_interpreter`), Entry 1
     (`reflect_to_interface`), and **Entry 2 (`trampoline_to_interface`)**, a
     4-instruction (16-byte, fitting `OBJECTS_PER_TRAMPOLINE_ENTRY = 4`) stub
     with `pc_offset = 0`:
     ```asm
     and x1, x1, #DATUM_MASK   // untag x1 -> entry0 (block + 3) if entered via apply_setup
     ldr x17, [x1], #8         // x17 := block[3] (fixnum code); x1 := block + 4 (trampoline_storage)
     and x17, x17, #0xff       // strip TC_FIXNUM tag -> uint8_t utility index
     br  x23                   // jump to hook_scheme_to_interface
     ```
     (`pop-return` in `src/compiler/machines/aarch64/rules3.scm` executes `RET`
     directly to Entry 0 without loading `x1`, so keeping `compiler_utilities`
     in `code_arena` preserves direct RX execution.)
   - **Dynamic trampolines (`make_trampoline` in `src/microcode/cmpint.c`)**:
     Keep dynamic trampolines as pure data in the copying heap formatted as a
     **1-entry `TC_MANIFEST_CLOSURE`** targeting Entry 2 (`trampoline_to_interface`)
     of `compiler_utilities`:
     - `block[0]` = `make_object(TC_MANIFEST_CLOSURE, 3 + n_values + 1)`
     - `block[1..2]` = `count = 1`, `type_arity` + `block_offset`, and
       `pc_offset = (char *)trampoline_to_interface - (char *)entry0` (where
       `entry0 = (insn_t *)(block + 3)`)
     - `block[3]` = `ULONG_TO_FIXNUM(kind_code)`
     - `block[4 .. 4 + n_values - 1]` = `trampoline_storage` slots
     - `block[4 + n_values]` (`CC_BLOCK_ADDR_END(block)[-1]`) = `MAKE_CC_ENTRY(entry0)`
       (the self-tag read by `start_closure_relocation` in
       `src/microcode/cmpintmd/aarch64.c`)
     Update `trampoline_storage(block)` (`src/microcode/cmpint.c`) to return
     `block + 4` when `object_type(block[0]) == TC_MANIFEST_CLOSURE` (preserving
     `comp_op_lookup_trap_restart`), and fix `faslhdr_utilities_end`
     (`src/microcode/fasl.c`, line 358) to compute
     `FASLHDR_UTILITIES_START(h) + 1 + object_datum(memory_ref(compiler_utilities, 0))`
     when `FASLHDR_UTILITIES_START(h) != 0 && CC_BLOCK_P(compiler_utilities)`
     rather than calling `VECTOR_P`/`vector_length` on the dumper's pointer.
4. **Restrict post-install Scheme writes**:
   Do not wrap `VECTOR_SET_PRIMITIVE` (`system-vector-set!`) in
   `src/microcode/vector.c` with write brackets—doing so allows arbitrary Scheme
   code to overwrite raw AArch64 instructions in executable memory. Instead,
   replace the `system-vector-set!` call in
   `set-compiled-code-block/debugging-info!` (`src/runtime/microcode-data.scm`)
   with a dedicated C primitive that brackets writes solely to the debugging-info
   slot (`CC_BLOCK_ADDR_END(block)[-2]`, i.e., `vector_length(block) - 2`, and
   requires no I-cache invalidation).

### 4. Write Brackets, I-Cache Coherence, and Unwind / Signal Safety

- **Centralize toggles and cache flushes**: All arena mutations go through
  `jit.c` / `code_arena.c` (`code_arena_write_begin_for` /
  `code_arena_write_end_for`).
  - On Darwin/arm64, `FLUSH_I_CACHE_REGION(ptr, nwords)` and `FLUSH_I_CACHE()`
    in `src/microcode/cmpintmd/aarch64.c` must call `sys_icache_invalidate` over
    the written region or `[code_start, code_alloc_next)` instead of the
    current `[constant_start, Free)` range in `aarch64_flush_i_cache`.
  - On non-Darwin AArch64, fix `aarch64_cache_line_sizes` in
    `src/microcode/cmpintmd/aarch64.c`: `CTR_EL0` `DminLine` and `IminLine`
    encode `log2(words)`, so the byte line sizes are `4U << dsize` and
    `4U << isize`, not `dsize` and `isize`.
- **Protect against `longjmp` and signal-handler `APRR_EL0` drift**:
  MIT Scheme is single-threaded when running Scheme, so a per-thread steady
  state of RX (`pthread_jit_write_protect_np(1)`) is sound **only if** non-local
  exits cannot leave the thread writable or desynchronize a software nesting
  depth counter:
  1. `signal_error_from_primitive` (e.g., `ERR_FASDUMP_OBJECT_TOO_LARGE` inside
     `fasdump_transport_words` or allocation/file errors in `fasload`),
     primitive interrupts, and `trap_recover` unwind via `abort_to_interpreter`
     -> `longjmp` (`src/microcode/interp.c`, `src/microcode/uxtrap.c`), skipping
     lexical `code_arena_write_end` calls.
  2. XNU saves and modifies `APRR_EL0` on signal delivery and restores it on
     `sigreturn`; `longjmp`ing out of `trap_handler` bypasses `sigreturn`.
  - **Fix**: Register write-bracket restoration on `dstack`
    (`dstack_protect` / `transaction_record_action`) for open C brackets, and
    unconditionally reset the bracket nesting depth to 0 and call
    `pthread_jit_write_protect_np(1)` in `abort_to_interpreter`, `trap_recover`,
    and `C_to_interface`.

### 5. Unified FASL and Band Format (First-Class Code Segment)

The initial prototype avoided modifying the FASL format by scanning `.com` files
in `fasload` (`!FASLHDR_BAND_P`) while refusing `dump-band` whenever
`!OS_heap_executable_p` and leaving `FASLHDR_BAND_P` bands in constant space.
That approach does not work for native Apple silicon:

1. **Bands are mandatory**: `make` builds and reloads `lib/runtime.com` and
   `lib/all.com`, and normal startup loads `all.com`. On Darwin/arm64,
   `OS_heap_executable_p` is always `#F`, so refusing `dump-band` prevents
   building or running native Scheme at all.
2. **Bands already relocate**: Contrary to an earlier assumption in this design,
   `fasload.c` (lines 418–433) does **not** require a band's `heap`, `constant`,
   and `stack` addresses to match the process—that check only skips relocation
   when addresses happen to match. Under ASLR they differ, and `load_file`
   already relocates the entire band through `relocate_block_table()`.
3. **Two-pass `.com` block-discovery hazards**: Reserving arena blocks before
   relocation and copying them after `relocate_block_table()` /
   `intern_block_table()` breaks if a FASL ever contains a linked
   `TC_LINKAGE_SECTION`, because `write_uuo_target` (`src/microcode/cmpintmd/aarch64.c`)
   computes PC-relative `b` / `adrp` offsets using the temporary heap `scan`
   address and inspects `target[-1]` in the uncopied arena reservation.

**Target fix**: Bump `fasl_version_t` in `src/microcode/fasl.h` (as
`FASL_VERSION_EPHEMERONS` did) to `FASL_VERSION_CODE_SPACE` (13), adding a
first-class code-arena segment (`FASL_OFFSET_CODE_SIZE = 19`,
`FASL_OFFSET_CODE_BASE = 20`, segment layout `[header][heap][constant][code][primitive table][C code table]`):
- **Cross-bootstrap compatibility (`src/microcode/fasl.h`, `src/microcode/fasl.c`)**:
  Keep `OLDEST_INPUT_FASL_VERSION = FASL_VERSION_C_CODE` (10) and set
  `NEWEST_INPUT_FASL_VERSION = FASL_VERSION_CODE_SPACE` (13), defaulting
  `FASLHDR_CODE_SIZE(h) = 0` when `version < FASL_VERSION_CODE_SPACE`, because
  cross-bootstrap `portable-fasdump` (`src/compiler/base/fasdump.scm`, line 58)
  emits version 10 `.bin`/`.ext`/`.moc` files (which contain no
  `TC_COMPILED_CODE_BLOCK`s).
- **Two-tospace `Prim_prim_fasdump` (`src/microcode/fasdump.c`, `src/microcode/gcloop.c`)**:
  `gcloop.c` currently uses a single global `tospace`. Add a secondary
  `code_tospace` buffer (`open_code_tospace`) with a disjoint synthetic
  `code_newspace_start` (e.g., `heap_end`), and extend `tospace_to_newspace`,
  `newspace_to_tospace`, `read_tospace`, and `write_tospace` in
  `src/microcode/gcloop.c` to dispatch across both `[newspace_start, newspace_end)`
  and `[code_newspace_start, code_newspace_end)` so `write_uuo_target` and
  `start_closure_relocation` work unchanged. Route `TC_COMPILED_CODE_BLOCK`s
  (except `compiler_utilities`) in `fasdump_table()` into `code_tospace`
  (recording `add_fixup` inside a write bracket when `code_address_p(old_addr)`),
  and alternate `gc_scan_tospace` across `heap_tospace` and `code_tospace`
  until both reach fixed point—leaving heap and constant segments free of
  code blocks.
- **`Prim_band_dump`**: For a single-chunk arena, write
  `[code_start, code_alloc_next)` directly without mutating live heap words in
  place (swept `TC_MANIFEST_NM_VECTOR` holes are skipped automatically by
  `gc_scan_oldspace` during `fasload` and re-threaded onto the arena free list
  on band restore); if multiple arena chunks exist at `dump-band` time,
  compact live arena blocks into a contiguous staging buffer via fixups.
- **`fasload` (`src/microcode/fasload.c`)**: Read the code segment directly
  into newly allocated arena blocks under a write bracket **before** running
  `relocate_address`, add `[FASLHDR_CODE_START(fh), FASLHDR_CODE_END(fh))` ->
  `new_code_start` to `relocate_address` (checked before
  `FASLHDR_UTILITIES_START..END` for bands so the band's `compiler_utilities`
  resolves within `new_code_start`), scan `[new_code_start, new_code_end)` in
  `relocate_block_table` / `intern_block_table` inside a write bracket, and call
  `FLUSH_I_CACHE_REGION` so both `.com` files and bands relocate cleanly in one
  pass at their final RX addresses.
- Once both `.com` files and bands store all `TC_COMPILED_CODE_BLOCK`s in the
  code arena, `TC_COMPILED_CODE_BLOCK` can be removed from the copying heap GC
  path altogether, and constant space holds pure/constant data only.

### 6. AArch64 Addressing and Branch Range

- **Datum range**: On 64-bit targets (`src/microcode/object.h`), `DATUM_LENGTH`
  is 58 (`DATUM_MASK = 0x03FFFFFFFFFFFFFF`), while arm64 user space is 47–48
  bits (`0x00007fffffffffff`). Any userspace `mmap` already fits in a datum;
  mapping hints under `DATUM_MASK` are only needed if porting to a 32-bit
  `DATUM_LENGTH=26` architecture or >58-bit pointers.
- **UUO target distance (`write_uuo_target`)**: `src/microcode/cmpintmd/aarch64.c`
  (lines 266–314) branches via `b` within ±128 MiB and otherwise falls back to
  `adrp x17` + `add x17` + `br x17` (±4 GiB ceiling, calling
  `error_external_return()` beyond ±4 GiB). That `ADRP` branch also has two
  pre-existing assertion bugs (`to_pg + lo12` missing `<< 12`, and unsigned
  `pghi19` failing on negative `pgoff`) that abort whenever the code arena and a
  far block/trampoline exceed 128 MiB apart.
  - **Fix**: Because `write_uuo_target` already emits `ldr x1, PC-ioff`
    loading the 64-bit `target` into `x1` (`iaddr[0]`), replace the broken
    `adrp`/`add`/`br x17` sequence for out-of-range non-closure targets with a
    single `br x1` (`0xd61f0020`). That eliminates both broken assertions and the
    ±4 GiB distance restriction between the arena and heap closures/trampolines.
- **Single-block relaxation (`ADRP-ADD` replacement & assembler bug fixes)**:
  In `src/compiler/machines/aarch64/instr1.scm` (lines 1098–1114, noted in
  `src/compiler/machines/aarch64/TODO`), `ADRP-ADD` is commented out with `#;`,
  so any individual compiled block requiring internal `ADR`/`B` relaxation beyond
  ±1 MiB fails assembly. Because `code_arena` blocks are only 8-byte aligned
  (not page-aligned), `PC mod 4096` is unknown at assembly time and `ADRP`
  cannot compute PC-relative offsets. Every `@PCR` caller in `instr1.scm` and
  `src/compiler/machines/aarch64/instrf.scm` already provides a scratch register.
  - **Replacement sequence**: Replace `ADRP-ADD` with an exact 64-bit
    (2-instruction) `ADR` + shifted `ADD`/`SUB` macro preserving the `(MACRO 64 ...)`
    width and `*PC*` anchor:
    - For `0 <= offset <= #x10fefff`: emit `(ADR X ,Rd (@PCO ,lo))` +
      `(ADD X ,Rd ,Rd (LSL (&U ,hi) 12))` with
      `hi = min(#xfff, quotient offset #x1000)` and `lo = offset - hi * #x1000`
      (`0 <= lo <= #xfffff`, valid signed-21).
    - For `-#x10ff000 <= offset < 0`: emit `(ADR X ,Rd (@PCO ,lo))` +
      `(SUB X ,Rd ,Rd (LSL (&U ,hi) 12))` with
      `hi = min(#xfff, quotient (- offset) #x1000)` and `lo = offset + hi * #x1000`
      (`-#x100000 <= lo <= 0`, valid signed-21).
    Narrow outer `VARIABLE-WIDTH` bounds in `instr1.scm` / `instrf.scm` to fit
    ±17 MiB (`[-#x10ff000, #x10fefff]` bytes, or equivalent 4-byte word bounds
    adjusted by `-2`/`-1` for branch wrappers), and keep unconditional `B` / `BL`
    unrelaxed within their native ±128 MiB single-instruction range so
    `cc_return_address_to_entry_address` (`src/microcode/cmpintmd/aarch64.c`,
    lines 96–105) always sees a single `B` instruction at `invoke-interface/call`
    return sites (`src/compiler/machines/aarch64/lapgen.scm`).
  - **Pre-existing assembler bugs to fix alongside `ADRP-ADD`**:
    1. `TBZ`/`TBNZ` (`instr1.scm`, lines 150 and 159): add `SIGNED` coercion to
       `(14 offset)` (and `signed-14` pattern predicate).
    2. `TBZ`/`TBNZ` forward relaxation (`instr1.scm`, line 174): change
       `(B (@PCO 4))` to `(B (@PCO (* 4 4)))`.
    3. Backward branch relaxations in `B.`, `CBZ`/`CBNZ`, and `TBZ`/`TBNZ`
       (`instr1.scm`, lines 86, 126, 186): change `(* 4 (- offset 2))` to
       `(* 4 (- offset 1))` because `2:` begins at `*PC* + 4`, not `*PC* + 8`.
    4. `LDR.V` literal relaxation (`instrf.scm`, line 306): change
       `(LDR.V X ,Vt ,temp)` to `(LDR.V ,size ,Vt ,temp)`.

## Phases and Current Status

### Phase 0: configure and platform detection (Implemented)

- `src/microcode/aclocal.m4`: Resolve `arm`/`arm64`/`aarch64` on Darwin to
  `aarch64le` when `--enable-native-code=yes`, accept `arm64` as a compiler
  architecture alias, and update `src/configure.ac` / `src/microcode/configure.ac`
  so plain `./configure` on Apple silicon fails with an actionable error until
  native arm64 support is complete rather than emitting a crashing binary.
- Detect `MAP_JIT`, `pthread_jit_write_protect_np`, and `sys_icache_invalidate`
  in `src/microcode/configure.ac`, defining `SCM_JIT_APPLE` for arm64 Darwin,
  and pass `-arch arm64` for `aarch64le` on macOS.
- **Important note on `--disable-native-code`**: In `src/microcode/aclocal.m4`
  and `src/microcode/cmpintmd/none-config.h`, `--disable-native-code` sets
  `mit_scheme_native_code=none` (`NO_CC_SUPPORT_P`), which disables **all**
  compiled-code and SVM support and cannot run `.com` files or build the
  compiler. Interim Apple silicon builds must configure with
  `--enable-native-code=svm1` (portable SVM bytecode) or `--enable-native-code=c`
  (LIARC), **not** `--disable-native-code`.

### Phase 1: JIT primitive layer (Implemented)

- Add `src/microcode/jit.c` + `jit.h` (`code_space_map`,
  `code_space_write_begin/end`, `code_space_execute_begin`, `code_space_flush`,
  and `dstack` unwind hooks) backed by `MAP_JIT` + `pthread_jit_write_protect_np`
  + `sys_icache_invalidate` on Darwin/arm64.
- Add standalone microcode smoke test `tests/microcode/jit-smoke.c` (mapping
  an AArch64 stub, toggling RW->RX, flushing I-cache, and calling it).
- Route `mmap_heap_malloc_try` (`src/microcode/ux.c`) and the `_MACH_UNIX`
  protection path in `src/microcode/cmpintmd/x86-64.c` through `jit.c`.
- Verify code-signing rules on macOS: ad-hoc-signed binaries can use `MAP_JIT`;
  Hardened Runtime / notarized binaries require
  `com.apple.security.cs.allow-jit`.

### Phase 2: Immovable Code Arena, Memory Management, and FASL Segment (Implemented)

- `code_arena.c` + `code_arena.h`: mark-sweep reclamation with chained `MAP_JIT`
  overflow chunks, external RW `mark_bits` bitmap + `code_mark_stack` worklist,
  and `TC_MANIFEST_NM_VECTOR` self-describing swept free holes; tested via
  `tests/microcode/arena-smoke.c` and `tests/microcode/gc-arena-smoke.c`.
- `setup_memory` / `reset_memory` (`src/microcode/memmag.c`),
  `INSTALL-COMPILED-CODE-BLOCK` wired into `assemble-objects`
  (`src/compiler/back/bittop.scm`), `cross-link/finish-assembly`
  (`src/compiler/base/crsend.scm`), and `%copy-compiled-code-block`
  (`src/runtime/prgcop.scm`).
- Mark-sweep `code_arena` liveness integrated into weak/ephemeron GC
  (`src/microcode/gcloop.c`: `ADDRESS_COLLECTABLE_P`, `weak_referent_forward`,
  and alternating `gc_scan_tospace` / `code_mark_stack` drain in
  `scan_ephemerons`).
- `fasl_version_t` in `src/microcode/fasl.h` bumped to
  `FASL_VERSION_CODE_SPACE` (13) while keeping `OLDEST_INPUT_FASL_VERSION =
  FASL_VERSION_C_CODE`, `faslhdr_utilities_end` fixed (`src/microcode/fasl.c`),
  two-tospace (`heap_tospace` + `code_tospace`) `Prim_prim_fasdump` and direct
  / compacted `Prim_band_dump` in `fasdump.c`, and single-pass `fasload.c`
  code-segment loading and relocation; tested via
  `tests/microcode/fasl-code-smoke.c`.
- `compiler_utilities` (`make_compiler_utilities`) moved into `code_arena`;
  dynamic `make_trampoline` objects live in the heap as 1-entry
  `TC_MANIFEST_CLOSURE`s targeting `trampoline_to_interface` (Entry 2 of
  `compiler_utilities`).
- Dedicated `SET-COMPILED-CODE-BLOCK/DEBUGGING-INFO!` primitive used by
  `set-compiled-code-block/debugging-info!` (`src/runtime/microcode-data.scm`),
  leaving general `VECTOR_SET_PRIMITIVE` unbracketed.
- `read_band_sizes` and startup sizing (`src/microcode/option.c`) read
  `FASLHDR_CODE_SIZE(&h)` and reserve runtime code-arena headroom
  (`--code` / `MITSCHEME_CODE_SIZE`), while keeping `--constant` for
  `constant_space`.
- GC/fasdump checks (`VALID_ADDRESS_P` in `src/microcode/debug.c`,
  `compute_memory_checksum` in `src/microcode/fasdump.c`) updated for
  `[code_start, code_alloc_next)` and active chunks.

### Phase 3: Native AArch64 Write Bracketing and Backend Fixes (Implemented)

- Removed inline environment `STR` stores from `generate/quotation-header`,
  `generate/remote-link`, and `generate/remote-links` in
  `src/compiler/machines/aarch64/rules3.scm`, and wrote
  `CC_BLOCK_ADDR_END(block_addr)[-1] = GET_ENV` in `comutil_link`
  (`src/microcode/cmpint.c`) inside a write bracket **before** calling
  `link_remaining_sections(&s)`.
- Emitted `trampoline_to_interface` as Entry 2 of `compiler_utilities`
  (`src/microcode/cmpint.c`, `store_trampoline_to_interface_insns` in
  `src/microcode/cmpintmd/aarch64.c`), formatted dynamic `make_trampoline`
  blocks as 1-entry `TC_MANIFEST_CLOSURE`s in the heap, and updated
  `trampoline_storage` (`src/microcode/cmpint.c`); verified via
  `tests/microcode/trampoline-smoke.c`.
- Fixed `write_uuo_target` (`br x1` for far targets), `aarch64_cache_line_sizes`
  (`4U << dsize` / `4U << isize`), `FLUSH_I_CACHE` / `FLUSH_I_CACHE_REGION`
  (`sys_icache_invalidate`), and `plausible_cc_block_p` (`+ CC_ENTRY_PADDING_SIZE`).
- Replaced `ADRP-ADD` with the 2-instruction `ADR` + `ADD`/`SUB` (`LSL #12`)
  sequence and tightened `VARIABLE-WIDTH` bounds in
  `src/compiler/machines/aarch64/{insutl,instr1,instrf}.scm`, alongside
  fixing `TBZ`/`TBNZ` `SIGNED` offset + `(&U ,bit)` + `(B (@PCO (* 4 4)))`,
  backward-branch `(* 4 (- offset 1))`, `(LDRS X W ...)` / `(LDRS W X ...)`,
  and `(LDR.V ,size ,Vt ,temp)`.
- Wired `dstack` write-bracket cleanup and unconditional RX restoration in
  `abort_to_interpreter` (`src/microcode/interp.c`), `trap_recover`
  (`src/microcode/uxtrap.c`), `exit_interruption_extent` (`src/microcode/intext.c`),
  and `C_to_interface` (`src/microcode/cmpauxmd/aarch64.m4`, guarded by a
  `jit_write_depth != 0` fast-path check after profiling showed unconditional
  `pthread_jit_write_protect_np(1)` added ~45% non-GC runtime overhead).

### Phase 4: GC Cleanup, Trap Handling, and Runtime Tools (Implemented)

- Runtime GC guards in `src/microcode/gcloop.c` assert every non-closure
  `TC_COMPILED_CODE_BLOCK` / return address resides in `code_arena` on
  native Apple silicon builds (`SCM_JIT_APPLE && CC_IS_NATIVE`).
- Added Darwin arm64 `HAVE_SIGCONTEXT` definitions in `src/microcode/uxtrap.h`
  (`SIGCONTEXT_FIRST_REG`, `SIGCONTEXT_NREGS`, `SIGCONTEXT_PC`, `SIGCONTEXT_SP`,
  `SIGCONTEXT_SCHSP` = `__x[28]`, `SIGCONTEXT_RFREE` = `__x[20]`).
- Unified PC classification in `src/microcode/uxtrap.c` (`find_code_address` /
  `pcl_code` using `code_arena_find_block`), exposed `CODE-SPACE-BOUNDS` and
  `CODE-ADDRESS?` in `src/runtime/microcode-data.scm`, and annotated
  code-arena trap frames with `"(code space)"` in
  `src/runtime/continuation-parser.scm`.

### Phase 5: Packaging, CI, and Documentation (Implemented)

- Updated `dist/make-macosx-app` and `src/etc/macosx/make-app.sh` (with
  `src/etc/macosx/entitlements.plist` and the native SwiftUI workbench port in
  `src/etc/macosx/app/`, falling back to `macosx-starter` when `swift` is
  unavailable) for `aarch64le` (`arm64`) and code signing with
  `com.apple.security.cs.allow-jit`.
- Added Linux `aarch64` `HAVE_SIGCONTEXT` register/PC/SP definitions
  (`regs[28]` / `regs[20]`) in `src/microcode/uxtrap.h` so trap recovery and
  `"(code space)"` frame reporting match Darwin on Linux/aarch64.
- Documented `--code` and `MITSCHEME_CODE_SIZE` in `doc/user-manual/user.texinfo`.
- Added `.github/workflows/aarch64.yml` (`macos-latest` arm64 and `ubuntu-24.04-arm`
  Linux aarch64 jobs with Stage 2 bootstrap caching) and
  `.github/workflows/release-macos-dmg.yml` (tag/dispatch macOS DMG packaging and
  GitHub Release publishing) backed by reusable verification scripts in
  `tests/ci/` (`bootstrap-and-test.sh`, `run-microcode-smoke.sh`,
  `check-results.py`, `verify-native-aarch64.scm`, `verify-trap.scm`,
  `verify-wx-mappings.sh`, `verify-macos-app.sh`, and `build-macos-dmg.sh`).

## Verification

### What the SVM1 Prototype Already Demonstrated (and Its Limits)

On an SVM1 prototype build on Apple silicon, `vmmap` confirmed that the 128 MiB
Scheme heap was mapped `rw-/rwx` (NX) while the ~15.5 MiB code arena was the
sole anonymous `rwx/rwx` (`MAP_JIT`) mapping, and `release_arena_blocks` rolled
back failed `.com` loads. Because the SVM interpreter reads bytecode with load
instructions rather than fetching machine instructions into the CPU I-cache,
SVM1 could not exercise hardware RX execution, `sys_icache_invalidate`, inline
`STR` faults, `compiler_utilities`/trampoline execution, `SIGCONTEXT_SCHSP`/
`SIGCONTEXT_RFREE` trap recovery, or native `dump-band`/`load-band`.

### Required Native AArch64 Verification

- **Initial cross-bootstrap and self-hosted rebuild**:
  - From an existing `mit-scheme-c` host (`src/etc/make-native.sh --enable-native-code=aarch64le`),
    or via a 2-stage cross-build from `mit-scheme-svm1-64le`
    (Stage 1: `--enable-native-code=svm1 --with-compiler-target=aarch64le`;
    Stage 2: `--enable-native-code=aarch64le --enable-cross-compiling`;
    Stage 3: self-hosted `./configure && make`), native compilation completes
    end-to-end, including dumping and reloading `lib/runtime.com` and `lib/all.com`.
- `make check` passes on both arm64 macOS and aarch64 Linux.
- `vmmap` / `procstat` on a running native Scheme process shows RW/NX
  `stack`/`constant_space`/`heap` and no anonymous executable mappings outside
  the `MAP_JIT` code arena.
- Execution exercises UUO near/far links (>128 MiB and >4 GiB apart), closure
  invocation, dynamic trampolines (`apply`, lexprs, primitives, unbound traps),
  compiled `quotation` blocks, `eval`/REPL compilation, and Edwin.
- Repeated compile + UUO-link + GC + `compile-file` loops verify mark-sweep
  arena reclamation without exhausting the arena or pinning dead environments,
  and weak-pair (`weak-cons` / weak hash tables) plus ephemeron tests keyed by
  dynamically compiled procedures confirm collected `code_arena` blocks clear
  weak references to `#!reclaimed` / `#f` without dangling pointers.
- Hardware trap tests (`SIGSEGV` in compiled code and in a primitive) verify
  `x28`/`x20` state recovery, `APRR_EL0` restoration across `longjmp`, and
  code-arena PC annotation in trap frames.

## Appendix: Prototype Findings and Checking Traps

### Bootstrap Bug Fixed During Prototyping: `FASDUMP` `N_PRIMITIVES = 0`

When prototyping against a prebuilt `mit-scheme-svm1-64le` host, `syntax-runtime`
segfaulted inside `cref/generate-constructors` because every `.bin`/`.ext`
dumped by the host carried `N_PRIMITIVES = 0` in header word 8 despite having
an intact primitive table. In `src/microcode/fasdump.c`:
- `make_prim_renumber()` (`src/microcode/primutl.c`) registers
  `free_prim_renumber` as a `tat_always` transaction action;
- line 170 runs `transaction_commit()`, freeing `current_pr`;
- line 178 then reads `current_pr->next_code` from freed memory, which happened
  to read as 0 on this host.

Capturing `current_pr->next_code` before `transaction_commit()` fixes the C bug
in `fasdump.c`. Until prebuilt host binaries incorporate that fix, a temporary
hook in `src/runtime/host-adapter.scm` (loaded automatically by `Makefile.in`
tools) can patch header word 8 after host `fasdump` calls, and should be
removed once the host toolchain is rebuilt.

### `Prim_band_dump` Post-Mortem and Worktree Notes

- On the SVM1 prototype, before `dump-band*` was replaced by a first-class
  code-arena segment, copying arena code above `Free` and rewriting live
  pointers to the heap copy without restoring them caused a ~10% intermittent
  `SIGBUS`/`SIGSEGV` on the next GC; undoing the pointer rewrites and `Free`
  bump eliminated that flake (0/96 failures) and motivated adding the native
  FASL code-arena segment instead of mutating the live heap during dumps.
- Isolated git worktrees can be configured cleanly from source by running
  `./Setup.sh` inside `src/` (which runs `autoconf --include=microcode` against
  `src/microcode/aclocal.m4` and links `lib/`). When judging any build commit,
  always complete the full build and verify `--band lib/all.com` startup rather
  than testing an interrupted build.

### Checking a Trap Report

`HAVE_SIGCONTEXT` in `src/microcode/uxtrap.h` is required on arm64 so
`continue_from_trap` populates `extra_trap_info` with the faulting PC and
registers (and on native AArch64 restores `SSP` from `x28` and `Free` from
`x20`). To provoke and inspect a compiled-code trap:

```scheme
(compile-file "forge.scm" '() (->environment '(runtime microcode-data)))
```

where `forge.scm` uses `(ucode-primitive primitive-object-set-type 2)` to
construct a `TC_VECTOR` (type `0x0a`) pointing to an unmapped address and
dereferences `(vector-ref object 0)` in compiled code. Replacing
`hook/hardware-trap` in `(runtime garbage-collector)` lets a test inspect
`(continuation/first-subproblem k)` (described by `describe-hardware-trap-frame`
in `src/runtime/continuation-parser.scm`) and confirm whether the faulting PC
was classified inside the code area, constant space, or heap.

### XNU `MAP_JIT` Syscall `EFAULT` on Direct Code-Arena I/O

On macOS `arm64`, `pthread_jit_write_protect_np(0)` switches the userspace
thread's `APRR_EL0` permission register, but XNU's `copyout()`/`copyin()` for
`read(2)` and `write(2)` rejects `MAP_JIT` virtual addresses once `fread`/`fwrite`
bypasses `stdio`'s `BUFSIZ` (`>= 4096` bytes), failing large `.com` or band code
segments with `EFAULT`. `read_code_from_file` (`src/microcode/fasload.c`) and
`write_code_to_fasl_file` (`src/microcode/fasdump.c`) avoid this by staging code
segment I/O through a 512-word (`4096`-byte) userspace stack buffer.

### Observed Native AArch64 Verification Summary

- Clean cross-bootstrap (`svm1` -> native `aarch64le`) followed by a full
  self-hosted native `./configure && make` rebuild completed and dumped/reloaded
  `lib/runtime.com` and `lib/all.com`.
- All 5 C microcode test suites (`jit-smoke`, `arena-smoke`, `gc-arena-smoke`,
  `fasl-code-smoke`, `trampoline-smoke`) passed.
- `FAST=y make check` passed 101/102 suites (with `microcode/test-flonum-except`
  reporting only macOS's expected missing `untrap-float-exceptions` /
  `feenableexcept`).
- `vmmap` confirmed `rw-/rwx` (NX) `heap`, `constant_space`, and `stack`, with
  `MAP_JIT` `code_arena` as the sole anonymous executable region.
- Runtime verification exercised dynamic `eval`/`compile-procedure`, closures,
  lexprs, `apply` and primitive trampolines, unbound operator lookup traps +
  restarts, a 146.9 MB (>128 MiB) far UUO link, 0-byte arena growth across a
  50-iteration compile+GC loop, weak pairs and ephemerons keyed by compiled
  procedures, `copy-program`, and hardware `SIGSEGV` trap recovery (`SSP=x28`,
  `Free=x20`, `APRR_EL0` restoration, and `"(code space)"` frame reporting).

## Building on Apple Silicon

Plain `./configure && make` now auto-detects Apple silicon (`arm64`) as
`aarch64le`. Portable alternatives remain available via:

```sh
./configure --enable-native-code=svm1
```

(or `--enable-native-code=c` for LIARC) rather than `--disable-native-code`,
which disables compiled-code support entirely (`NO_CC_SUPPORT_P`).
