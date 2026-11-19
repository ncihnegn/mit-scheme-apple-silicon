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

/* Smoke test for FASL_VERSION_CODE_SPACE, closure routing, and band compaction. */

#include "scheme.h"
#include "fasl.h"
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

SCHEME_OBJECT * Free = 0;
SCHEME_OBJECT * constant_start = 0;
SCHEME_OBJECT compiler_utilities = SHARP_F;
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

#define SIM_HEAP_WORDS 4096
static SCHEME_OBJECT sim_heap [SIM_HEAP_WORDS];
static SCHEME_OBJECT * sim_heap_start = sim_heap;
static SCHEME_OBJECT * sim_free = sim_heap;

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

static SCHEME_OBJECT *
make_arena_code_block (unsigned long n_words, SCHEME_OBJECT * entry_r)
{
  SCHEME_OBJECT * block = (code_arena_alloc (n_words));
  insn_t * entry;
  cc_entry_offset_t ceo;

  CHECK (block != 0);
  CHECK (n_words >= 6);
  entry = (((insn_t *) (block + 2)) + 4);
  (ceo.offset) = ((unsigned long) (entry - ((insn_t *) block)));
  (ceo.continued_p) = false;

  code_arena_write_begin ();
  (block[0]) = (make_vector_header (n_words - 1));
  (block[1]) = (make_nmv_header (n_words - 2));
  memset ((block + 2), 0, ((n_words - 2) * SIZEOF_SCHEME_OBJECT));
  CHECK (!write_cc_entry_offset ((&ceo), entry));
  (entry[-2]) = 0;
  (entry[-1]) = 0;
  code_arena_write_end ();

  (*entry_r) = (MAKE_CC_ENTRY (entry));
  CHECK ((cc_entry_to_block_address (*entry_r)) == block);
  return (block);
}

static SCHEME_OBJECT *
make_heap_closure (insn_t * target, SCHEME_OBJECT slot0, SCHEME_OBJECT * entry_r)
{
  SCHEME_OBJECT * blk = sim_free;
  insn_t * start;
  insn_t * entry0;

  sim_free += 6;
  CHECK (sim_free <= (sim_heap + SIM_HEAP_WORDS));
  (blk[0]) = (make_object (TC_MANIFEST_CLOSURE, 5));
  (blk[1]) = 0;
  (* ((uint32_t *) (blk + 1))) = 1;
  (blk[2]) = 0;
  (blk[3]) = 0;
  (blk[4]) = slot0;

  start = (compiled_closure_start (blk + 1));
  entry0 = (compiled_closure_entry (start));
  CHECK (entry0 == ((insn_t *) (blk + 3)));
  (blk[5]) = (MAKE_CC_ENTRY (entry0));

  {
    cc_entry_offset_t ceo;
    (ceo.offset) = ((unsigned long) (entry0 - ((insn_t *) blk)));
    (ceo.continued_p) = false;
    CHECK (!write_cc_entry_offset ((&ceo), entry0));
  }
  write_compiled_closure_target (target, start);
  (*entry_r) = (MAKE_CC_ENTRY (entry0));
  return (blk);
}

struct fixup_rec
{
  SCHEME_OBJECT * addr;
  SCHEME_OBJECT orig;
};

static struct fixup_rec test_fixups[128];
static size_t n_test_fixups = 0;

static void
record_and_transport_to_code (SCHEME_OBJECT * block,
			      unsigned long n_words,
			      void * ctx)
{
  (void) ctx;
  CHECK (n_test_fixups < 128);
  CHECK (code_tospace_available_p (n_words));
  (test_fixups[n_test_fixups].addr) = block;
  (test_fixups[n_test_fixups].orig) = (*block);
  n_test_fixups += 1;
  (void) gc_transport_words_to_code_tospace (block, n_words, false);
}

static DEFINE_GC_TUPLE_HANDLER (test_compact_tuple)
{
  (void) n_words;
  return (tuple);
}

static DEFINE_GC_VECTOR_HANDLER (test_compact_vector)
{
  (void) align_p;
  if ((object_type (vector)) == TC_COMPILED_CODE_BLOCK)
    {
      SCHEME_OBJECT * old_addr = (object_address (vector));
      if ((code_address_p (old_addr)) && (BROKEN_HEART_P (*old_addr)))
	return (object_new_address (vector, (object_address (*old_addr))));
    }
  return (vector);
}

static DEFINE_GC_OBJECT_HANDLER (test_compact_cc_entry)
{
  SCHEME_OBJECT * old_addr = (cc_entry_to_block_address (object));
  if ((code_address_p (old_addr)) && (BROKEN_HEART_P (*old_addr)))
    return (CC_ENTRY_NEW_BLOCK (object, (object_address (*old_addr)), old_addr));
  return (object);
}

static DEFINE_GC_OBJECT_HANDLER (test_compact_cc_return)
{
  SCHEME_OBJECT * old_addr = (cc_return_to_block_address (object));
  if ((code_address_p (old_addr)) && (BROKEN_HEART_P (*old_addr)))
    return (CC_RETURN_NEW_BLOCK (object, (object_address (*old_addr)), old_addr));
  return (object);
}

static gc_table_t *
make_test_compact_table (void)
{
  static gc_table_t t;
  static bool init_p = false;
  if (!init_p)
    {
      initialize_gc_table ((&t), false);
      (GCT_TUPLE (&t)) = test_compact_tuple;
      (GCT_VECTOR (&t)) = test_compact_vector;
      (GCT_CC_ENTRY (&t)) = test_compact_cc_entry;
      (GCT_CC_RETURN (&t)) = test_compact_cc_return;
      (GCT_ENTRY ((&t), TC_WEAK_CONS)) = gc_handle_pair;
      (GCT_ENTRY ((&t), TC_EPHEMERON)) = gc_handle_unaligned_vector;
      (GCT_ENTRY ((&t), TC_BROKEN_HEART)) = gc_handle_non_pointer;
      init_p = true;
    }
  return (&t);
}

static void
restore_test_fixups (void)
{
  size_t i;
  code_arena_write_begin ();
  for (i = 0; i < n_test_fixups; i += 1)
    (* (test_fixups[i].addr)) = (test_fixups[i].orig);
  code_arena_write_end ();
  n_test_fixups = 0;
}

static bool
copy_out_tospace (SCHEME_OBJECT * start, SCHEME_OBJECT * end, void * p)
{
  SCHEME_OBJECT * dst = p;
  memcpy (dst, start, ((size_t) (end - start)) * SIZEOF_SCHEME_OBJECT);
  return (true);
}

int
main (void)
{
  dstack_initialize ();
  initialize_gc (SIM_HEAP_WORDS, (&sim_heap_start), (&sim_free),
		 test_allocate_tospace, test_abort_gc);

  /* 1. FASL_VERSION_CODE_SPACE (13) header round-trip. */
  {
    fasl_header_t out_h;
    fasl_header_t in_h;
    FILE * f = (tmpfile ());

    CHECK (f != 0);
    memset ((&out_h), 0, (sizeof (out_h)));
    memset ((&in_h), 0, (sizeof (in_h)));

    (FASLHDR_VERSION (&out_h)) = FASL_VERSION_CODE_SPACE;
    (FASLHDR_ARCH (&out_h)) = CURRENT_FASL_ARCH;
    (FASLHDR_CC_VERSION (&out_h)) = COMPILER_INTERFACE_VERSION;
    (FASLHDR_CC_ARCH (&out_h)) = COMPILER_PROCESSOR_TYPE;
    (FASLHDR_BAND_P (&out_h)) = true;
    (FASLHDR_MEMORY_BASE (&out_h)) = 0;
    (FASLHDR_HEAP_START (&out_h)) = ((SCHEME_OBJECT *) 0x100000000UL);
    (FASLHDR_HEAP_END (&out_h)) = ((SCHEME_OBJECT *) 0x100008000UL);
    (FASLHDR_ROOT_POINTER (&out_h)) = (FASLHDR_HEAP_START (&out_h));
    (FASLHDR_HEAP_RESERVED (&out_h)) = 4500;
    (FASLHDR_CONSTANT_START (&out_h)) = ((SCHEME_OBJECT *) 0x100010000UL);
    (FASLHDR_CONSTANT_END (&out_h)) = ((SCHEME_OBJECT *) 0x100012000UL);
    (FASLHDR_CODE_START (&out_h)) = ((SCHEME_OBJECT *) 0x104000000UL);
    (FASLHDR_CODE_END (&out_h)) = ((SCHEME_OBJECT *) 0x104020000UL);
    (FASLHDR_STACK_START (&out_h)) = ((SCHEME_OBJECT *) 0x100020000UL);
    (FASLHDR_STACK_END (&out_h)) = ((SCHEME_OBJECT *) 0x100024000UL);
    (FASLHDR_N_PRIMITIVES (&out_h)) = 5;
    (FASLHDR_PRIMITIVE_TABLE_SIZE (&out_h)) = 12;
    (FASLHDR_UTILITIES_VECTOR (&out_h)) = SHARP_F;
    (FASLHDR_EPHEMERON_COUNT (&out_h)) = 7;

    CHECK (write_fasl_header ((&out_h), f));
    rewind (f);
    CHECK (read_fasl_header ((&in_h), f));
    CHECK ((check_fasl_version (&in_h)) == FASL_FILE_FINE);
    CHECK ((FASLHDR_VERSION (&in_h)) == FASL_VERSION_CODE_SPACE);
    CHECK ((FASLHDR_CODE_START (&in_h)) == (FASLHDR_CODE_START (&out_h)));
    CHECK ((FASLHDR_CODE_END (&in_h)) == (FASLHDR_CODE_END (&out_h)));
    CHECK ((FASLHDR_CODE_SIZE (&in_h)) == (FASLHDR_CODE_SIZE (&out_h)));
    CHECK ((FASLHDR_EPHEMERON_COUNT (&in_h)) == 7);
    fclose (f);
    printf ("[1/5] FASL_VERSION_CODE_SPACE header round-trip OK\n");
  }

  /* 2. Backward-compatible FASL_VERSION_C_CODE (10) defaults. */
  {
    fasl_header_t out_h;
    fasl_header_t in_h;
    FILE * f = (tmpfile ());

    CHECK (f != 0);
    memset ((&out_h), 0, (sizeof (out_h)));
    memset ((&in_h), 0xff, (sizeof (in_h)));

    (FASLHDR_VERSION (&out_h)) = FASL_VERSION_C_CODE;
    (FASLHDR_ARCH (&out_h)) = CURRENT_FASL_ARCH;
    (FASLHDR_CC_VERSION (&out_h)) = COMPILER_INTERFACE_VERSION;
    (FASLHDR_CC_ARCH (&out_h)) = COMPILER_PROCESSOR_TYPE;
    (FASLHDR_BAND_P (&out_h)) = false;
    (FASLHDR_HEAP_START (&out_h)) = ((SCHEME_OBJECT *) 0x100000000UL);
    (FASLHDR_HEAP_END (&out_h)) = ((SCHEME_OBJECT *) 0x100001000UL);
    (FASLHDR_ROOT_POINTER (&out_h)) = (FASLHDR_HEAP_START (&out_h));
    (FASLHDR_UTILITIES_VECTOR (&out_h)) = SHARP_F;
    (FASLHDR_EPHEMERON_COUNT (&out_h)) = 99;

    CHECK (write_fasl_header ((&out_h), f));
    rewind (f);
    CHECK (read_fasl_header ((&in_h), f));
    CHECK ((check_fasl_version (&in_h)) == FASL_FILE_FINE);
    CHECK ((FASLHDR_VERSION (&in_h)) == FASL_VERSION_C_CODE);
    CHECK ((FASLHDR_CODE_SIZE (&in_h)) == 0);
    CHECK ((FASLHDR_CODE_START (&in_h)) == 0);
    CHECK ((FASLHDR_EPHEMERON_COUNT (&in_h)) == 0);
    fclose (f);
    printf ("[2/5] FASL_VERSION_C_CODE (10) defaults OK\n");
  }

  /* 3. ASLR-safe faslhdr_utilities_end + code_arena_reset/mark_hole. */
  {
    SCHEME_OBJECT * util_blk;
    fasl_header_t aslr_h;
    SCHEME_OBJECT * util_end;

    code_arena_setup (2048);
    util_blk = (code_arena_alloc (16));
    CHECK (util_blk != 0);
    code_arena_write_begin ();
    (util_blk[0]) = (make_vector_header (15));
    code_arena_write_end ();
    compiler_utilities = (MAKE_CC_BLOCK (util_blk));

    memset ((&aslr_h), 0, (sizeof (aslr_h)));
    (FASLHDR_UTILITIES_START (&aslr_h))
      = ((SCHEME_OBJECT *) 0x700012340000UL);
    (FASLHDR_UTILITIES_VECTOR (&aslr_h))
      = (MAKE_CC_BLOCK (FASLHDR_UTILITIES_START (&aslr_h)));

    util_end = (faslhdr_utilities_end (&aslr_h));
    CHECK (util_end == ((FASLHDR_UTILITIES_START (&aslr_h)) + 16));

    code_arena_reset (4096);
    CHECK ((code_arena_chunk_count ()) == 1);
    CHECK (((unsigned long) (code_end - code_start)) >= 4096);
    CHECK (code_alloc_next == code_start);

    {
      SCHEME_OBJECT * hole = (code_arena_alloc (10));
      code_arena_write_begin ();
      (hole[0]) = (make_vector_header (9));
      code_arena_write_end ();
      code_arena_mark_hole (hole, 10);
      CHECK ((object_type (hole[0])) == TC_MANIFEST_NM_VECTOR);
      CHECK ((1 + (object_datum (hole[0]))) == 10);
    }

    code_arena_teardown ();
    compiler_utilities = SHARP_F;
    printf ("[3/5] ASLR-safe faslhdr_utilities_end + code_arena_reset OK\n");
  }

  /* 4. TC_MANIFEST_CLOSURE stays in heap while code target goes to code_tospace. */
  {
    SCHEME_OBJECT * code_blk;
    SCHEME_OBJECT code_entry;
    SCHEME_OBJECT * cls_blk;
    SCHEME_OBJECT cls_entry;
    SCHEME_OBJECT * new_cls_blk;
    SCHEME_OBJECT * new_code_blk;
    SCHEME_OBJECT dumped_heap[16];
    SCHEME_OBJECT * heap_scan;
    SCHEME_OBJECT * code_scan;
    insn_t * target_pc;

    sim_free = sim_heap_start;
    code_arena_setup (2048);
    code_blk = (make_arena_code_block (8, (&code_entry)));
    cls_blk = (make_heap_closure ((CC_ENTRY_ADDRESS (code_entry)),
				  (ULONG_TO_FIXNUM (123)),
				  (&cls_entry)));
    CHECK (!code_address_p (cls_blk));
    CHECK (code_address_p (code_blk));

    /* Dump closure to heap tospace and target code block to code_tospace. */
    open_tospace (sim_heap_start);
    CHECK (open_code_tospace (64));

    new_cls_blk = (gc_transport_words (cls_blk, 6, true));
    record_and_transport_to_code (code_blk, 8, 0);
    (void) new_cls_blk;

    /* Scan both spaces using two-tospace compaction table. */
    heap_scan = sim_heap_start;
    code_scan = (get_code_newspace_start ());
    current_gc_table = (make_test_compact_table ());
    while ((heap_scan < (get_newspace_ptr ()))
	   || (code_scan < (get_code_newspace_ptr ())))
      {
	if (heap_scan < (get_newspace_ptr ()))
	  {
	    SCHEME_OBJECT * target = (get_newspace_ptr ());
	    gc_scan_tospace (heap_scan, target);
	    heap_scan = target;
	  }
	if (code_scan < (get_code_newspace_ptr ()))
	  {
	    SCHEME_OBJECT * target = (get_code_newspace_ptr ());
	    gc_scan_code_tospace (code_scan, target);
	    code_scan = target;
	  }
      }

    /* Check closure remains in heap and targets relocated block in code_newspace. */
    new_code_blk = (get_code_newspace_start ());
    CHECK ((get_code_newspace_ptr ()) == (new_code_blk + 8));
    CHECK (save_tospace (copy_out_tospace, dumped_heap));
    restore_test_fixups ();

    {
      SCHEME_OBJECT * loaded_cls = dumped_heap;
      SCHEME_OBJECT * fresh_code_blk;
      reloc_ref_t ref;
      insn_t * read_target;

      CHECK ((object_type (loaded_cls[0])) == TC_MANIFEST_CLOSURE);
      CHECK (!code_address_p (loaded_cls));
      (ref.old_addr) = (CC_ENTRY_ADDRESS (loaded_cls[5]));
      (ref.new_addr) = (compiled_closure_entry (compiled_closure_start (loaded_cls + 1)));
      read_target = (read_compiled_closure_target (compiled_closure_start (loaded_cls + 1),
						   (&ref)));
      target_pc = (((insn_t *) (new_code_blk + 2)) + 4);
      CHECK (read_target == target_pc);

      /* Simulate reload into fresh code_arena and mark-sweep. */
      fresh_code_blk = (code_arena_alloc (8));
      CHECK (fresh_code_blk != 0);
      code_arena_write_begin ();
      memcpy (fresh_code_blk,
	      (newspace_to_tospace (new_code_blk)),
	      (8 * SIZEOF_SCHEME_OBJECT));
      code_arena_write_end ();

      code_arena_mark_begin ();
      CHECK (code_arena_mark_block (fresh_code_blk));
      code_arena_sweep ();
      CHECK ((object_type (fresh_code_blk[0])) == TC_MANIFEST_VECTOR);
      CHECK ((object_type (code_blk[0])) == TC_MANIFEST_NM_VECTOR);
    }

    discard_code_tospace ();
    code_arena_teardown ();
    printf ("[4/5] closure in heap + target block in code_arena OK\n");
  }

  /* 5. Multi-chunk code_arena compaction preserves cross-chunk closure targets. */
  {
    SCHEME_OBJECT * blk_a;
    SCHEME_OBJECT entry_a;
    SCHEME_OBJECT * blk_b;
    SCHEME_OBJECT entry_b;
    SCHEME_OBJECT * cls_blk;
    SCHEME_OBJECT cls_entry;
    SCHEME_OBJECT staged_heap[16];
    unsigned long heap_words;
    SCHEME_OBJECT compacted_code[128];
    unsigned long code_words;

    sim_free = sim_heap_start;
    code_arena_setup (2048);
    blk_a = (make_arena_code_block (8, (&entry_a)));
    /* Large allocation exceeding remaining primary chunk forces overflow chunk. */
    blk_b = (make_arena_code_block (4096, (&entry_b)));
    (void) blk_a;
    CHECK (code_address_p (blk_b));
    CHECK ((code_arena_nonempty_chunk_count ()) == 2);

    cls_blk = (make_heap_closure ((CC_ENTRY_ADDRESS (entry_b)),
				  (ULONG_TO_FIXNUM (55)),
				  (&cls_entry)));
    heap_words = ((unsigned long) (sim_free - sim_heap_start));
    CHECK (heap_words == 6);

    CHECK (open_code_tospace ((code_arena_live_words ()) + 64));
    n_test_fixups = 0;
    code_arena_for_each_live_block (record_and_transport_to_code, 0);
    CHECK (n_test_fixups == 2);

    code_words = ((unsigned long) ((get_code_newspace_ptr ())
				   - (get_code_newspace_start ())));
    CHECK (code_words == (8 + 4096));

    memcpy (staged_heap, sim_heap_start, (heap_words * SIZEOF_SCHEME_OBJECT));
    open_stage_tospace (sim_heap_start, staged_heap, heap_words);
    current_gc_table = (make_test_compact_table ());
    gc_scan_stage_tospace ();
    close_stage_tospace ();

    gc_scan_code_tospace ((get_code_newspace_start ()),
			  (get_code_newspace_ptr ()));

    memcpy (compacted_code,
	    (newspace_to_tospace (get_code_newspace_start ())),
	    (16 * SIZEOF_SCHEME_OBJECT));
    restore_test_fixups ();

    /* Verify closure now points to Block B at offset 8 inside compacted space. */
    {
      reloc_ref_t ref;
      insn_t * compacted_b_entry
	= (((insn_t *) ((get_code_newspace_start ()) + 8 + 2)) + 4);
      insn_t * resolved;

      (ref.old_addr) = (CC_ENTRY_ADDRESS (cls_blk[5]));
      (ref.new_addr)
	= (compiled_closure_entry (compiled_closure_start (staged_heap + 1)));
      resolved = (read_compiled_closure_target
		  (compiled_closure_start (staged_heap + 1), (&ref)));
      CHECK (resolved == compacted_b_entry);
    }

    (void) compacted_code;
    discard_code_tospace ();
    code_arena_reset (code_words + 64);
    CHECK ((code_arena_nonempty_chunk_count ()) == 0);
    {
      SCHEME_OBJECT * reloaded = (code_arena_alloc (code_words));
      CHECK (reloaded != 0);
      code_arena_write_begin ();
      (reloaded[0]) = (make_vector_header (7));
      ((reloaded + 8)[0]) = (make_vector_header (4095));
      code_arena_write_end ();
      CHECK ((code_arena_nonempty_chunk_count ()) == 1);
    }

    code_arena_teardown ();
    printf ("[5/5] multi-chunk code_arena compaction OK\n");
  }

  return (0);
}
