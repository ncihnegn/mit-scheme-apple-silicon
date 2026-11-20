/* -*-C-*-

Copyright (C) 1986, 1987, 1988, 1989, 1990, 1991, 1992, 1993, 1994,
    1995, 1996, 1997, 1998, 1999, 2000, 2001, 2002, 2003, 2004, 2005,
    2006, 2007, 2008, 2009, 2010, 2011, 2012, 2013, 2014, 2015, 2016,
    2017, 2018, 2019, 2020, 2021, 2022 Massachusetts Institute of
    Technology

This file is part of MIT/GNU Scheme.

MIT/GNU Scheme is free software; you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation; either version 2 of the License, or (at
your option) any later version.

MIT/GNU Scheme is distributed in the hope that it will be useful, but
WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
General Public License for more details.

You should have received a copy of the GNU General Public License
along with MIT/GNU Scheme; if not, write to the Free Software
Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA 02110-1301,
USA.

*/

/* Standalone smoke test for compiler_utilities, closure trampolines, and trap PC lookup. */

#include "scheme.h"
#include "cmpint.h"
#include "cmpgc.h"
#include "gccode.h"
#include "code_arena.h"
#include "jit.h"
#include "lookup.h"
#include "history.h"
#include "prims.h"
#include "prim.h"
#include "ostop.h"

#define CHECK(cond) do							\
{									\
  if (!(cond))								\
    {									\
      fprintf (stderr, "CHECK failed at %s:%d: %s\n",			\
	       __FILE__, __LINE__, #cond);				\
      abort ();								\
    }									\
} while (0)

/* Interpreter globals & stubs required by cmpint.o + gcloop.o + wind.o. */
SCHEME_OBJECT * Free = 0;
SCHEME_OBJECT * Free_primitive = 0;
SCHEME_OBJECT * heap_alloc_limit = 0;
SCHEME_OBJECT * heap_start = 0;
SCHEME_OBJECT * heap_end = 0;
SCHEME_OBJECT * constant_start = 0;
SCHEME_OBJECT * constant_end = 0;
SCHEME_OBJECT * stack_start = 0;
SCHEME_OBJECT * stack_end = 0;
SCHEME_OBJECT * stack_pointer = 0;
SCHEME_OBJECT * stack_guard = 0;
SCHEME_OBJECT * memory_block_start = 0;
SCHEME_OBJECT fixed_objects = SHARP_F;
SCHEME_OBJECT ephemeron_array = SHARP_F;
unsigned long ephemeron_count = 0;
unsigned long gc_space_needed = 0;
SCHEME_OBJECT * last_return_code = 0;
long prim_apply_error_code = 0;
primitive_procedure_t * Primitive_Procedure_Table = 0;
int * Primitive_Arity_Table = 0;

static SCHEME_OBJECT dummy_stack[256];

void *
OS_malloc (size_t size)
{
  return (malloc (size));
}

void
block_signals (void)
{
}

void
unblock_signals (void)
{
}

void
OS_expect_sequential_access (void * start, void * end)
{
  (void) start;
  (void) end;
}

void
OS_expect_normal_access (void * start, void * end)
{
  (void) start;
  (void) end;
}

void
OS_free_pages (void * start, void * end)
{
  (void) start;
  (void) end;
}

void
voutf_fatal (const char * format, va_list ap)
{
  vfprintf (stderr, format, ap);
}

void
outf_fatal (const char * format, ...)
{
  va_list ap;
  va_start (ap, format);
  vfprintf (stderr, format, ap);
  va_end (ap);
}

void
outf_flush_fatal (void)
{
  fflush (stderr);
}

void NORETURN
Microcode_Termination (int code)
{
  fprintf (stderr, "Microcode_Termination(%d)\n", code);
  abort ();
}

void NORETURN
termination_init_error (void)
{
  fprintf (stderr, "termination_init_error\n");
  abort ();
}

void NORETURN
stack_death (const char * name)
{
  fprintf (stderr, "stack_death(%s)\n", name);
  abort ();
}

void NORETURN
error_external_return (void)
{
  fprintf (stderr, "error_external_return\n");
  abort ();
}

void NORETURN
abort_to_interpreter (int code)
{
  fprintf (stderr, "abort_to_interpreter(%d)\n", code);
  abort ();
}

void
signal_interrupt_from_primitive (void)
{
  abort ();
}

void
end_subproblem (void)
{
}

void
compiler_new_subproblem (void)
{
}

void
compiler_new_reduction (void)
{
}

void
apply_primitive_external (SCHEME_OBJECT prim)
{
  (void) prim;
  abort ();
}

SCHEME_OBJECT
Prim_unimplemented (void)
{
  abort ();
}

SCHEME_OBJECT
make_vector (unsigned long length, SCHEME_OBJECT contents, bool gc_check_p)
{
  (void) length;
  (void) contents;
  (void) gc_check_p;
  abort ();
}

SCHEME_OBJECT
record_applicator (SCHEME_OBJECT record)
{
  (void) record;
  return (SHARP_F);
}

SCHEME_OBJECT
char_pointer_to_string (const char * s)
{
  (void) s;
  return (SHARP_F);
}

long
lookup_variable (SCHEME_OBJECT env, SCHEME_OBJECT sym, SCHEME_OBJECT * cell)
{
  (void) env;
  (void) sym;
  (void) cell;
  return (PRIM_DONE);
}

long
safe_lookup_variable (SCHEME_OBJECT env, SCHEME_OBJECT sym, SCHEME_OBJECT * cell)
{
  (void) env;
  (void) sym;
  (void) cell;
  return (PRIM_DONE);
}

long
variable_unassigned_p (SCHEME_OBJECT env, SCHEME_OBJECT sym, SCHEME_OBJECT * cell)
{
  (void) env;
  (void) sym;
  (void) cell;
  return (PRIM_DONE);
}

long
assign_variable (SCHEME_OBJECT env,
		 SCHEME_OBJECT sym,
		 SCHEME_OBJECT val,
		 SCHEME_OBJECT * cell)
{
  (void) env;
  (void) sym;
  (void) val;
  (void) cell;
  return (PRIM_DONE);
}

long
compiler_cache_lookup (SCHEME_OBJECT s, SCHEME_OBJECT b, unsigned long o)
{
  (void) s;
  (void) b;
  (void) o;
  return (PRIM_DONE);
}

long
compiler_cache_assignment (SCHEME_OBJECT s, SCHEME_OBJECT b, unsigned long o)
{
  (void) s;
  (void) b;
  (void) o;
  return (PRIM_DONE);
}

long
compiler_cache_operator (SCHEME_OBJECT s, SCHEME_OBJECT b, unsigned long o)
{
  (void) s;
  (void) b;
  (void) o;
  return (PRIM_DONE);
}

long
compiler_cache_global_operator (SCHEME_OBJECT s, SCHEME_OBJECT b, unsigned long o)
{
  (void) s;
  (void) b;
  (void) o;
  return (PRIM_DONE);
}

SCHEME_OBJECT
compiler_var_error (SCHEME_OBJECT cache, SCHEME_OBJECT block, enum cache_ref_kind k)
{
  (void) cache;
  (void) block;
  (void) k;
  return (SHARP_F);
}

long
compiler_lookup_trap (SCHEME_OBJECT cache, SCHEME_OBJECT * val)
{
  (void) cache;
  (void) val;
  return (PRIM_DONE);
}

long
compiler_operator_reference_trap (SCHEME_OBJECT cache, SCHEME_OBJECT * val)
{
  (void) cache;
  (void) val;
  return (PRIM_DONE);
}

long
compiler_safe_lookup_trap (SCHEME_OBJECT cache, SCHEME_OBJECT * val)
{
  (void) cache;
  (void) val;
  return (PRIM_DONE);
}

long
compiler_unassigned_p_trap (SCHEME_OBJECT cache, SCHEME_OBJECT * val)
{
  (void) cache;
  (void) val;
  return (PRIM_DONE);
}

long
compiler_assignment_trap (SCHEME_OBJECT cache, SCHEME_OBJECT v, SCHEME_OBJECT * val)
{
  (void) cache;
  (void) v;
  (void) val;
  return (PRIM_DONE);
}

#define SIM_HEAP_WORDS 4096
static SCHEME_OBJECT sim_heap[SIM_HEAP_WORDS];

static void
test_allocate_tospace (unsigned long n_words,
		       SCHEME_OBJECT ** start_r,
		       SCHEME_OBJECT ** end_r)
{
  if (n_words > 0)
    {
      SCHEME_OBJECT * p
	= (((*start_r) == 0)
	   ? (malloc (n_words * SIZEOF_SCHEME_OBJECT))
	   : (realloc ((*start_r), (n_words * SIZEOF_SCHEME_OBJECT))));
      CHECK (p != 0);
      (*start_r) = p;
      (*end_r) = (p + n_words);
    }
  else if ((*start_r) != 0)
    {
      free (*start_r);
      (*start_r) = 0;
      (*end_r) = 0;
    }
}

static void NORETURN
test_abort_gc (void)
{
  fprintf (stderr, "test_abort_gc invoked\n");
  abort ();
}

static bool
save_tospace_copy (SCHEME_OBJECT * start, SCHEME_OBJECT * end, void * p)
{
  (void) p;
  memmove ((tospace_to_newspace (start)),
	   start,
	   ((size_t) (end - start)) * SIZEOF_SCHEME_OBJECT);
  return (true);
}

#if defined(__aarch64__) && defined(CC_IS_NATIVE)
static void
run_closure_trampoline (uint64_t entry_arg,
			insn_t * target_pc,
			void * hook_stub,
			uint64_t out[2])
{
  register uint64_t x1_reg asm ("x1") = entry_arg;
  register uint64_t x2_reg asm ("x2") = ((uint64_t) ((uintptr_t) out));
  register uint64_t x16_reg asm ("x16") = ((uint64_t) ((uintptr_t) target_pc));
  register uint64_t x9_reg asm ("x9") = ((uint64_t) ((uintptr_t) hook_stub));
  asm volatile ("str x23, [sp, #-16]!\n\t"
		"mov x23, %3\n\t"
		"blr %2\n\t"
		"ldr x23, [sp], #16"
		: "+r" (x1_reg)
		: "r" (x2_reg), "r" (x16_reg), "r" (x9_reg)
		: "x17", "x30", "memory");
}
#endif

int
main (void)
{
  void * mock_hook_page;

  dstack_initialize ();
  transaction_initialize ();
  heap_start = sim_heap;
  Free = sim_heap;
  heap_end = (sim_heap + SIM_HEAP_WORDS);
  heap_alloc_limit = (heap_end - 64);
  stack_start = dummy_stack;
  stack_end = (dummy_stack + 256);
  stack_pointer = stack_end;
  stack_guard = stack_start;

  code_arena_setup (2048);
  initialize_gc (SIM_HEAP_WORDS, (&heap_start), (&Free),
		 test_allocate_tospace, test_abort_gc);

  /* 1. compiler_initialize allocates compiler_utilities in code_arena. */
  compiler_initialize (true);
  CHECK (compiler_utilities != SHARP_F);
  CHECK (code_address_p (object_address (compiler_utilities)));
  CHECK (CC_RETURN_P (return_to_interpreter));
  CHECK (CC_RETURN_P (reflect_to_interface));
  CHECK (code_address_p (CC_RETURN_ADDRESS (return_to_interpreter)));
  CHECK (code_address_p (CC_RETURN_ADDRESS (reflect_to_interface)));
  printf ("[1/5] compiler_utilities in code_arena OK (%p)\n",
	  ((void *) (object_address (compiler_utilities))));

  /* 2. make_trampoline creates a 1-entry TC_MANIFEST_CLOSURE in RW heap. */
  {
    SCHEME_OBJECT tramp = SHARP_F;
    SCHEME_OBJECT * blk;
    SCHEME_OBJECT * store;
    SCHEME_OBJECT * util_addr;
    insn_t * entry2;
    insn_t * resolved_pc;

    /* Leave 32 dead words before blk so GC visibly moves blk on relocation. */
    Free = (heap_start + 32);
    CHECK ((coerce_to_compiled ((ULONG_TO_FIXNUM (999)), 2, (&tramp)))
	   == PRIM_DONE);
    CHECK (CC_ENTRY_P (tramp));
    blk = (cc_entry_to_block_address (tramp));
    CHECK (blk == (heap_start + 32));
    CHECK (!code_address_p (blk));
    CHECK ((object_type (blk[0])) == TC_MANIFEST_CLOSURE);
    CHECK ((1 + (object_datum (blk[0]))) == 7);
    CHECK (cc_entry_closure_p (tramp));

    util_addr = (object_address (compiler_utilities));
    entry2 = (trampoline_entry_addr (util_addr, 2));
    resolved_pc = (CC_ENTRY_ADDRESS_PC (CC_ENTRY_ADDRESS (tramp)));
    CHECK (resolved_pc == entry2);

    store = (trampoline_storage (blk));
    CHECK (store == (blk + 4));
    CHECK ((blk[3]) == (ULONG_TO_FIXNUM (TRAMPOLINE_K_APPLY)));
    CHECK ((store[0]) == (ULONG_TO_FIXNUM (999)));
    CHECK ((store[1]) == (ULONG_TO_FIXNUM (3)));
    CHECK ((blk[6]) == tramp);
    printf ("[2/5] heap TC_MANIFEST_CLOSURE trampoline layout OK\n");

    /* 3. Execute trampoline_to_interface natively via mock hook in MAP_JIT. */
#if defined(__aarch64__) && defined(CC_IS_NATIVE)
    mock_hook_page = (jit_map_code_space (16384));
    CHECK (mock_hook_page != 0);
    {
      volatile uint32_t * insns = ((volatile uint32_t *) mock_hook_page);
      uint64_t out[2] = { 0, 0 };

      jit_write_begin ();
      insns[0] = 0xa9000451U;	/* stp x17, x1, [x2] */
      insns[1] = 0xd65f03c0U;	/* ret */
      jit_flush_icache (mock_hook_page, (2 * sizeof (uint32_t)));
      jit_write_end ();

      /* Test untagged x1 (UUO closure path). */
      run_closure_trampoline (((uint64_t) ((uintptr_t) (CC_ENTRY_ADDRESS (tramp)))),
			      resolved_pc,
			      mock_hook_page,
			      out);
      CHECK (out[0] == ((uint64_t) TRAMPOLINE_K_APPLY));
      CHECK (out[1] == ((uint64_t) ((uintptr_t) store)));

      /* Test tagged TC_COMPILED_ENTRY x1 (apply_setup path). */
      out[0] = 0;
      out[1] = 0;
      run_closure_trampoline (((uint64_t) tramp),
			      resolved_pc,
			      mock_hook_page,
			      out);
      CHECK (out[0] == ((uint64_t) TRAMPOLINE_K_APPLY));
      CHECK (out[1] == ((uint64_t) ((uintptr_t) store)));
    }
    printf ("[3/5] native arm64 trampoline_to_interface (untagged & tagged x1) OK\n");
#else
    mock_hook_page = 0;
    printf ("[3/5] skipped native arm64 trampoline execution (non-native)\n");
#endif

    /* 4. Copying GC relocates closure trampoline (-32 words) and preserves target PC. */
    {
      SCHEME_OBJECT * saved_to;
      SCHEME_OBJECT rel_tramp;
      SCHEME_OBJECT * rel_blk;

      open_tospace (heap_start);
      initialize_weak_chain ();
      current_gc_table = (std_gc_table ());
      saved_to = (get_newspace_ptr ());
      add_to_tospace (tramp);
      gc_drain_tospace_and_code_arena (saved_to);
      update_weak_pointers ();
      Free = (get_newspace_ptr ());
      CHECK (save_tospace (save_tospace_copy, 0));
      CHECK (code_address_p (object_address (compiler_utilities)));
      CHECK (code_arena_marked_p (util_addr));
      code_arena_mark_block (util_addr);
      code_arena_sweep ();

      rel_tramp = (heap_start[0]);
      CHECK (CC_ENTRY_P (rel_tramp));
      rel_blk = (cc_entry_to_block_address (rel_tramp));
      CHECK (rel_blk == (heap_start + 1));
      CHECK (rel_blk != blk);
      CHECK (((trampoline_storage (rel_blk))[0]) == (ULONG_TO_FIXNUM (999)));
      CHECK (((trampoline_storage (rel_blk))[1]) == (ULONG_TO_FIXNUM (3)));
      CHECK ((rel_blk[6]) == rel_tramp);
      CHECK ((CC_ENTRY_ADDRESS_PC (CC_ENTRY_ADDRESS (rel_tramp))) == entry2);

#if defined(__aarch64__) && defined(CC_IS_NATIVE)
      {
	uint64_t out[2] = { 0, 0 };
	run_closure_trampoline (((uint64_t) rel_tramp),
				(CC_ENTRY_ADDRESS_PC (CC_ENTRY_ADDRESS (rel_tramp))),
				mock_hook_page,
				out);
	CHECK (out[0] == ((uint64_t) TRAMPOLINE_K_APPLY));
	CHECK (out[1] == ((uint64_t) ((uintptr_t) (trampoline_storage (rel_blk)))));
      }
      jit_unmap_code_space (mock_hook_page, 16384);
#endif
      printf ("[4/5] GC relocation of heap closure trampoline + re-exec OK\n");
    }

    /* 5. code_arena_find_block finds live blocks & rejects headers/holes/heap. */
    {
      SCHEME_OBJECT * hole_blk = (code_arena_alloc (8));
      SCHEME_OBJECT * live_blk = (code_arena_alloc (8));

      CHECK ((code_arena_find_block (CC_RETURN_ADDRESS (return_to_interpreter)))
	     == util_addr);
      CHECK ((code_arena_find_block (util_addr)) == 0);
      CHECK ((code_arena_find_block (util_addr + 1)) == 0);
      CHECK ((code_arena_find_block (code_alloc_next)) == 0);
      CHECK ((code_arena_find_block (blk)) == 0);

      CHECK ((hole_blk != 0) && (live_blk != 0));
      code_arena_write_begin ();
      (hole_blk[0]) = (make_vector_header (7));
      (hole_blk[1]) = (make_nmv_header (6));
      (live_blk[0]) = (make_vector_header (7));
      (live_blk[1]) = (make_nmv_header (6));
      code_arena_write_end ();

      CHECK ((code_arena_find_block (hole_blk + 3)) == hole_blk);
      CHECK ((code_arena_find_block (live_blk + 3)) == live_blk);

      code_arena_mark_begin ();
      CHECK (code_arena_mark_block (util_addr));
      CHECK (code_arena_mark_block (live_blk));
      code_arena_sweep ();

      /* Interior swept block becomes a TC_MANIFEST_NM_VECTOR hole -> fail closed. */
      CHECK ((object_type (hole_blk[0])) == TC_MANIFEST_NM_VECTOR);
      CHECK ((code_arena_find_block (hole_blk + 3)) == 0);
      CHECK ((code_arena_find_block (live_blk + 3)) == live_blk);
      printf ("[5/5] code_arena_find_block (live, headers, swept holes) OK\n");
    }
  }

  code_arena_teardown ();
  return (0);
}
