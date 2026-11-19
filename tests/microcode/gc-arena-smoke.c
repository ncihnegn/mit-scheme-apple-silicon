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

/* Smoke test for gcloop + code_arena mark-sweep, weak pairs, and ephemerons. */

#include "scheme.h"
#include "gccode.h"
#include "code_arena.h"
#include "jit.h"
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

/* Minimal runtime stubs for linking gcloop.o + code_arena.o + cmpintmd.o. */
SCHEME_OBJECT * Free = 0;
SCHEME_OBJECT * constant_start = 0;
SCHEME_OBJECT ephemeron_array = SHARP_F;
unsigned long ephemeron_count = 0;

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

SCHEME_OBJECT *
cc_entry_address_to_block_address (insn_t * entry)
{
  insn_t * p = entry;
  while (1)
    {
      cc_entry_offset_t ceo;
      read_cc_entry_offset ((&ceo), p);
      p -= (ceo.offset);
      if (! (ceo.continued_p))
	{
	  CHECK ((((uintptr_t) p) % (sizeof (SCHEME_OBJECT))) == 0);
	  return ((SCHEME_OBJECT *) p);
	}
    }
}

SCHEME_OBJECT *
cc_entry_to_block_address (SCHEME_OBJECT entry)
{
  return (cc_entry_address_to_block_address (CC_ENTRY_ADDRESS (entry)));
}

SCHEME_OBJECT
cc_entry_to_block (SCHEME_OBJECT entry)
{
  return (MAKE_CC_BLOCK (cc_entry_to_block_address (entry)));
}

SCHEME_OBJECT *
cc_return_address_to_block_address (insn_t * addr)
{
  return
    (cc_entry_address_to_block_address
     (CC_RETURN_ADDRESS_TO_ENTRY_ADDRESS (addr)));
}

SCHEME_OBJECT *
cc_return_to_block_address (SCHEME_OBJECT ret)
{
  return (cc_return_address_to_block_address (CC_RETURN_ADDRESS (ret)));
}

SCHEME_OBJECT
cc_return_to_block (SCHEME_OBJECT ret)
{
  return (MAKE_CC_BLOCK (cc_return_to_block_address (ret)));
}

bool
decode_old_style_format_word (cc_entry_type_t * cet, unsigned short fw)
{
  (void) cet;
  (void) fw;
  return (false);
}

bool
encode_old_style_format_word (cc_entry_type_t * cet, unsigned short * fwp)
{
  (void) cet;
  (void) fwp;
  return (false);
}

linkage_section_type_t
linkage_section_type (SCHEME_OBJECT marker)
{
  (void) marker;
  return (LINKAGE_SECTION_TYPE_OPERATOR);
}

unsigned long
linkage_section_count (SCHEME_OBJECT marker)
{
  (void) marker;
  return (0);
}

/* Simulated copying heap and GC callbacks. */
#define SIM_HEAP_WORDS 4096
static SCHEME_OBJECT sim_heap [SIM_HEAP_WORDS];
static SCHEME_OBJECT * sim_heap_start = sim_heap;
static SCHEME_OBJECT * sim_free = sim_heap;

#define EPH_ARRAY_LEN 23
static SCHEME_OBJECT sim_eph_vec [1 + EPH_ARRAY_LEN];

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

static void
reset_ephemeron_table (void)
{
  unsigned int i;
  sim_eph_vec[0] = (make_vector_header (EPH_ARRAY_LEN));
  for (i = 1; i <= EPH_ARRAY_LEN; i += 1)
    sim_eph_vec[i] = SHARP_F;
  ephemeron_array = (make_pointer_object (TC_VECTOR, sim_eph_vec));
  ephemeron_count = 0;
}

static SCHEME_OBJECT
alloc_sim_pair (unsigned int tc, SCHEME_OBJECT car_obj, SCHEME_OBJECT cdr_obj)
{
  SCHEME_OBJECT * p = sim_free;
  sim_free += 2;
  CHECK (sim_free <= (sim_heap + SIM_HEAP_WORDS));
  (p[0]) = car_obj;
  (p[1]) = cdr_obj;
  return (make_pointer_object (tc, p));
}

static SCHEME_OBJECT
alloc_sim_ephemeron (SCHEME_OBJECT key, SCHEME_OBJECT datum)
{
  SCHEME_OBJECT * p = sim_free;
  sim_free += EPHEMERON_SIZE;
  CHECK (sim_free <= (sim_heap + SIM_HEAP_WORDS));
  (p[0]) = MARKED_EPHEMERON_MANIFEST;
  (p[EPHEMERON_KEY]) = key;
  (p[EPHEMERON_DATUM]) = datum;
  (p[EPHEMERON_LIST]) = SHARP_F;
  (p[EPHEMERON_NEXT]) = SHARP_F;
  return (make_pointer_object (TC_EPHEMERON, p));
}

static SCHEME_OBJECT *
make_arena_code_block (SCHEME_OBJECT slot6,
		       SCHEME_OBJECT slot7,
		       SCHEME_OBJECT * entry_r)
{
  SCHEME_OBJECT * block = (code_arena_alloc (8));
  insn_t * entry;
  cc_entry_offset_t ceo;

  CHECK (block != 0);
  entry = (((insn_t *) (block + 2)) + 4);
  (ceo.offset) = ((unsigned long) (entry - ((insn_t *) block)));
  (ceo.continued_p) = false;

  code_arena_write_begin ();
  (block[0]) = (make_vector_header (7));
  (block[1]) = (make_nmv_header (4));
  (block[2]) = 0;
  (block[3]) = 0;
  (block[4]) = 0;
  (block[5]) = 0;
  CHECK (!write_cc_entry_offset ((&ceo), entry));
  (entry[-2]) = 0;
  (entry[-1]) = 0;
  (block[6]) = slot6;
  (block[7]) = slot7;
  code_arena_write_end ();

  (*entry_r) = (MAKE_CC_ENTRY (entry));
  CHECK ((cc_entry_to_block_address (*entry_r)) == block);
  return (block);
}

static SCHEME_OBJECT *
begin_sim_gc (SCHEME_OBJECT * roots, size_t n_roots)
{
  SCHEME_OBJECT * saved_to;
  size_t i;

  reset_ephemeron_table ();
  open_tospace (sim_heap_start);
  initialize_weak_chain ();
  current_gc_table = (std_gc_table ());

  saved_to = (get_newspace_ptr ());
  for (i = 0; i < n_roots; i += 1)
    add_to_tospace (roots[i]);

  gc_drain_tospace_and_code_arena (saved_to);
  update_weak_pointers ();
  return (get_newspace_ptr ());
}

static void
finish_sim_gc (SCHEME_OBJECT * new_free)
{
  CHECK (save_tospace (save_tospace_copy, 0));
  sim_free = new_free;
  code_arena_sweep ();
}

int
main (void)
{
  dstack_initialize ();
  code_arena_setup (2048);
  initialize_gc (SIM_HEAP_WORDS, (&sim_heap_start), (&sim_free),
		 test_allocate_tospace, test_abort_gc);

  /* 1. Live TC_COMPILED_ENTRY root marks block in place & forwards constants. */
  {
    SCHEME_OBJECT live_pair;
    SCHEME_OBJECT * old_pair_addr;
    SCHEME_OBJECT live_entry;
    SCHEME_OBJECT * live_block;
    SCHEME_OBJECT roots[1];
    SCHEME_OBJECT * new_free;

    sim_free = sim_heap_start;
    live_pair = (alloc_sim_pair (TC_LIST, (ULONG_TO_FIXNUM (77)), SHARP_F));
    old_pair_addr = (object_address (live_pair));
    live_block = (make_arena_code_block (live_pair, SHARP_F, (&live_entry)));

    roots[0] = live_entry;
    new_free = (begin_sim_gc (roots, 1));
    CHECK (BROKEN_HEART_P (old_pair_addr[0]));
    finish_sim_gc (new_free);

    CHECK ((sim_heap_start[0]) == live_entry);
    CHECK ((object_type (live_block[0])) == TC_MANIFEST_VECTOR);
    CHECK (PAIR_P (live_block[6]));
    CHECK ((object_address (live_block[6])) != old_pair_addr);
    CHECK ((pair_car (live_block[6])) == (ULONG_TO_FIXNUM (77)));
    CHECK ((jit_write_nesting_depth ()) == 0);
    printf ("[1/4] live TC_COMPILED_ENTRY marks in place & forwards constants OK\n");
  }

  /* 2. Dead code_arena block is swept & does not pin heap objects. */
  {
    SCHEME_OBJECT dead_pair;
    SCHEME_OBJECT * dead_pair_addr;
    SCHEME_OBJECT dead_entry;
    SCHEME_OBJECT * dead_block;
    SCHEME_OBJECT roots[1];
    SCHEME_OBJECT * new_free;

    sim_free = sim_heap_start;
    dead_pair = (alloc_sim_pair (TC_LIST, (ULONG_TO_FIXNUM (88)), SHARP_F));
    dead_pair_addr = (object_address (dead_pair));
    dead_block = (make_arena_code_block (dead_pair, SHARP_F, (&dead_entry)));

    roots[0] = SHARP_T;
    new_free = (begin_sim_gc (roots, 1));
    CHECK (!BROKEN_HEART_P (dead_pair_addr[0]));
    finish_sim_gc (new_free);

    CHECK ((sim_heap_start[0]) == SHARP_T);
    CHECK ((!code_address_p (dead_block))
	   || ((object_type (dead_block[0])) == TC_MANIFEST_NM_VECTOR));
    printf ("[2/4] unreferenced code_arena block swept without pinning heap OK\n");
  }

  /* 3. TC_WEAK_CONS keeps live code_arena entry and clears dead entry. */
  {
    SCHEME_OBJECT live_entry;
    SCHEME_OBJECT dead_entry;
    SCHEME_OBJECT * live_block;
    SCHEME_OBJECT * dead_block;
    SCHEME_OBJECT wp_live;
    SCHEME_OBJECT wp_dead;
    SCHEME_OBJECT root_list;
    SCHEME_OBJECT roots[1];
    SCHEME_OBJECT * new_free;

    sim_free = sim_heap_start;
    live_block = (make_arena_code_block (SHARP_F, SHARP_F, (&live_entry)));
    dead_block = (make_arena_code_block (SHARP_F, SHARP_F, (&dead_entry)));
    wp_live = (alloc_sim_pair (TC_WEAK_CONS, live_entry, (ULONG_TO_FIXNUM (1))));
    wp_dead = (alloc_sim_pair (TC_WEAK_CONS, dead_entry, (ULONG_TO_FIXNUM (2))));
    root_list
      = (alloc_sim_pair (TC_LIST, wp_live,
			 (alloc_sim_pair (TC_LIST, wp_dead, live_entry))));

    roots[0] = root_list;
    new_free = (begin_sim_gc (roots, 1));
    finish_sim_gc (new_free);

    {
      SCHEME_OBJECT rel_list = (sim_heap_start[0]);
      SCHEME_OBJECT rel_wp_live = (pair_car (rel_list));
      SCHEME_OBJECT rel_wp_dead = (pair_car (pair_cdr (rel_list)));
      CHECK ((pair_car (rel_wp_live)) == live_entry);
      CHECK ((pair_car (rel_wp_dead)) == GC_RECLAIMED);
      CHECK ((object_type (live_block[0])) == TC_MANIFEST_VECTOR);
      CHECK ((!code_address_p (dead_block))
	     || ((object_type (dead_block[0])) == TC_MANIFEST_NM_VECTOR));
    }
    printf ("[3/4] TC_WEAK_CONS live retained & dead cleared OK\n");
  }

  /* 4. TC_EPHEMERON live/dead code keys + transitive ephemeron->code->ephemeron. */
  {
    SCHEME_OBJECT live_entry;
    SCHEME_OBJECT dead_entry;
    SCHEME_OBJECT mid_entry;
    SCHEME_OBJECT * live_block;
    SCHEME_OBJECT * dead_block;
    SCHEME_OBJECT * mid_block;
    SCHEME_OBJECT k1;
    SCHEME_OBJECT k2;
    SCHEME_OBJECT live_pair;
    SCHEME_OBJECT dead_pair;
    SCHEME_OBJECT val2_pair;
    SCHEME_OBJECT * dead_pair_addr;
    SCHEME_OBJECT eph_dead;
    SCHEME_OBJECT eph_live;
    SCHEME_OBJECT eph1;
    SCHEME_OBJECT eph2;
    SCHEME_OBJECT * vec;
    SCHEME_OBJECT roots[1];
    SCHEME_OBJECT * new_free;

    sim_free = sim_heap_start;
    k1 = (alloc_sim_pair (TC_LIST, (ULONG_TO_FIXNUM (101)), SHARP_F));
    k2 = (alloc_sim_pair (TC_LIST, (ULONG_TO_FIXNUM (202)), SHARP_F));
    val2_pair = (alloc_sim_pair (TC_LIST, (ULONG_TO_FIXNUM (303)), SHARP_F));
    live_pair = (alloc_sim_pair (TC_LIST, (ULONG_TO_FIXNUM (404)), SHARP_F));
    dead_pair = (alloc_sim_pair (TC_LIST, (ULONG_TO_FIXNUM (505)), SHARP_F));
    dead_pair_addr = (object_address (dead_pair));

    live_block = (make_arena_code_block (SHARP_F, SHARP_F, (&live_entry)));
    dead_block = (make_arena_code_block (SHARP_F, SHARP_F, (&dead_entry)));
    mid_block = (make_arena_code_block (k2, SHARP_F, (&mid_entry)));

    eph_dead = (alloc_sim_ephemeron (dead_entry, dead_pair));
    eph_live = (alloc_sim_ephemeron (live_entry, live_pair));
    eph1 = (alloc_sim_ephemeron (k1, mid_entry));
    eph2 = (alloc_sim_ephemeron (k2, val2_pair));

    vec = sim_free;
    sim_free += 7;
    (vec[0]) = (make_vector_header (6));
    (vec[1]) = eph_dead;
    (vec[2]) = eph_live;
    (vec[3]) = eph1;
    (vec[4]) = eph2;
    (vec[5]) = live_entry;
    (vec[6]) = k1;

    roots[0] = (make_pointer_object (TC_VECTOR, vec));
    new_free = (begin_sim_gc (roots, 1));
    CHECK (!BROKEN_HEART_P (dead_pair_addr[0]));
    finish_sim_gc (new_free);

    {
      SCHEME_OBJECT rel_vec = (sim_heap_start[0]);
      SCHEME_OBJECT r_eph_dead = (vector_ref (rel_vec, 0));
      SCHEME_OBJECT r_eph_live = (vector_ref (rel_vec, 1));
      SCHEME_OBJECT r_eph1 = (vector_ref (rel_vec, 2));
      SCHEME_OBJECT r_eph2 = (vector_ref (rel_vec, 3));
      SCHEME_OBJECT r_k1 = (vector_ref (rel_vec, 5));

      CHECK ((memory_ref (r_eph_dead, EPHEMERON_KEY)) == SHARP_F);
      CHECK ((memory_ref (r_eph_dead, EPHEMERON_DATUM)) == SHARP_F);
      CHECK ((!code_address_p (dead_block))
	     || ((object_type (dead_block[0])) == TC_MANIFEST_NM_VECTOR));

      CHECK ((memory_ref (r_eph_live, EPHEMERON_KEY)) == live_entry);
      CHECK ((pair_car (memory_ref (r_eph_live, EPHEMERON_DATUM)))
	     == (ULONG_TO_FIXNUM (404)));
      CHECK ((object_type (live_block[0])) == TC_MANIFEST_VECTOR);

      CHECK ((memory_ref (r_eph1, EPHEMERON_KEY)) == r_k1);
      CHECK ((memory_ref (r_eph1, EPHEMERON_DATUM)) == mid_entry);
      CHECK ((object_type (mid_block[0])) == TC_MANIFEST_VECTOR);
      CHECK ((memory_ref (r_eph2, EPHEMERON_KEY)) == (mid_block[6]));
      CHECK ((pair_car (mid_block[6])) == (ULONG_TO_FIXNUM (202)));
      CHECK ((pair_car (memory_ref (r_eph2, EPHEMERON_DATUM)))
	     == (ULONG_TO_FIXNUM (303)));
    }
    printf ("[4/4] ephemerons (live/dead code keys + transitive chain) OK\n");
  }

  code_arena_teardown ();
  return (0);
}
