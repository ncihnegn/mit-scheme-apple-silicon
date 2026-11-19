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

/* This file contains code for fasdump and dump-band. */

#include "scheme.h"
#include "prims.h"
#include "osscheme.h"
#include "osio.h"
#include "osfile.h"
#include "osfs.h"
#define In_Fasdump
#include "gccode.h"
#include "trap.h"
#include "lookup.h"
#include "fasl.h"
#include "code_arena.h"
#include <setjmp.h>

#ifdef ENABLE_GC_DEBUGGING_TOOLS
#  define SAVE_GC_VARS save_gc_vars
   static void save_gc_vars (void);
#  define COMPARE_GC_VARS compare_gc_vars
   static void compare_gc_vars (void);
#  include <md5.h>
#  define SAVE_MEMORY_CHECKSUM save_memory_checksum
   static void save_memory_checksum (void);
#  define COMPARE_MEMORY_CHECKSUM compare_memory_checksum
   static void compare_memory_checksum (void);
   static void * compute_memory_checksum (void);
#else
#  define SAVE_GC_VARS() do {} while (false)
#  define COMPARE_GC_VARS() do {} while (false)
#endif

#ifndef SAVE_MEMORY_CHECKSUM
#  define SAVE_MEMORY_CHECKSUM() do {} while (false)
#  define COMPARE_MEMORY_CHECKSUM() do {} while (false)
#endif

typedef enum { FE_ERROR, FE_DUMP, FE_DROP_CC } env_mode_t;

typedef struct
{
  const char * filename;
  fasl_file_handle_t handle;
} fasl_file_info_t;

static void close_fasl_file (void *);
static void abort_fasdump (void *);
static gc_walk_proc_t save_fasdump_tospace;

static fasl_header_t fasl_header;
static fasl_header_t * fh;
static env_mode_t current_env_mode;
static prim_renumber_t * current_pr;
static bool cc_seen_p;
static unsigned long dumped_ephemeron_count;

static gc_table_t * fasdump_table (void);
static gc_handler_t handle_primitive;
static gc_handler_t handle_manifest_closure;
static gc_handler_t handle_linkage_section;
static gc_handler_t handle_symbol;
static gc_handler_t handle_broken_heart;
static gc_handler_t handle_environment;
static gc_handler_t handle_ephemeron;
static gc_handler_t handle_compiled_code_block;

static gc_object_handler_t fasdump_cc_entry;
static gc_object_handler_t fasdump_cc_return;
static gc_precheck_from_t fasdump_precheck_from;
static gc_transport_words_t fasdump_transport_words;
static gc_transport_words_t fasdump_transport_code_words;
static SCHEME_OBJECT * fasdump_transport_cc_block (SCHEME_OBJECT *);

static void initialize_fixups (void);
static void add_fixup (SCHEME_OBJECT *);
static void run_fixups (void *);

static void initialize_fasl_header (bool, bool);
static void finalize_fasl_header (unsigned long);
static bool write_fasl_file
  (SCHEME_OBJECT *, SCHEME_OBJECT *, fasl_file_handle_t);

/* FASDUMP:

   In order to dump an object it must be traced (as in a garbage
   collection), but with some significant differences.  First, the
   copy must have the global value cell of symbols set to UNBOUND.
   Second, and worse, all the broken hearts created during the process
   must be restored to their original values.  This last is done by
   growing the copy of the object in the bottom of spare heap, keeping
   track of the locations of broken hearts and original contents at
   the top of the spare heap.  */

DEFINE_PRIMITIVE ("PRIMITIVE-FASDUMP", Prim_prim_fasdump, 3, 3,
		  "(OBJECT NAMESTRING FLAG)\n\
Writes a binary representation of OBJECT to the file NAMESTRING.\n\
Returns #T if the operation is successful, or #F otherwise.\n\
\n\
FLAG specifies how to handle environment objects that OBJECT points\n\
to: #F means generate an error; #T means write them as ordinary\n\
objects; any other value is like #F except that environments pointed\n\
at by compiled code are ignored (and discarded).")
{
  fasl_file_info_t ff_info;
  SCHEME_OBJECT * new_heap_start;
  SCHEME_OBJECT * new_heap_end;
  SCHEME_OBJECT * new_code_start;
  SCHEME_OBJECT * new_code_end;
  SCHEME_OBJECT * heap_scan;
  SCHEME_OBJECT * code_scan;
  SCHEME_OBJECT * prim_table_start;
  unsigned long prim_table_length;
  unsigned long n_primitives;
  unsigned long max_code_words;
  bool ok;
  PRIMITIVE_HEADER (3);

  SAVE_GC_VARS ();
  SAVE_MEMORY_CHECKSUM ();

  transaction_begin ();		/* 1 */
  (ff_info . filename) = (STRING_ARG (2));
  if (!open_fasl_output_file ((ff_info . filename), (& (ff_info . handle))))
    error_bad_range_arg (2);
  transaction_record_action (tat_always, close_fasl_file, (&ff_info));

  open_tospace (heap_start);
  /* This must be _before_ the call to initialize_fixups(): */
  transaction_record_action (tat_abort, abort_fasdump, 0);
  max_code_words
    = ((code_arena_live_words ())
       + ((unsigned long) (Free - heap_start))
       + ((unsigned long) (constant_alloc_next - constant_start))
       + 1024);
  if (!open_code_tospace (max_code_words))
    signal_error_from_primitive (ERR_FASDUMP_OBJECT_TOO_LARGE);
  initialize_fixups ();

  new_heap_start = (get_newspace_ptr ());
  add_to_tospace (ARG_REF (1));
  dumped_ephemeron_count = 0;

  transaction_begin ();		/* 2 */

  current_gc_table = (fasdump_table ());
  current_env_mode
    = (((ARG_REF (3)) == SHARP_F)
       ? FE_ERROR
       : ((ARG_REF (3)) == SHARP_T)
       ? FE_DUMP
       : FE_DROP_CC);
  current_pr = (make_prim_renumber ());
  cc_seen_p = false;

  heap_scan = new_heap_start;
  code_scan = (get_code_newspace_start ());
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

  new_heap_end = (get_newspace_ptr ());
  new_code_start = (get_code_newspace_start ());
  new_code_end = (get_code_newspace_ptr ());

  prim_table_start = new_heap_end;
  prim_table_length = (renumbered_primitives_export_length (current_pr));
  increment_tospace_ptr (prim_table_length);
  export_renumbered_primitives
    ((newspace_to_tospace (prim_table_start)), current_pr);
  n_primitives = (current_pr->next_code);
  current_pr = 0;

  transaction_commit ();	/* 2 */

  initialize_fasl_header (cc_seen_p, false);
  (FASLHDR_CONSTANT_START (fh)) = new_heap_start;
  (FASLHDR_CONSTANT_END (fh)) = new_heap_start;
  (FASLHDR_HEAP_START (fh)) = new_heap_start;
  (FASLHDR_HEAP_END (fh)) = new_heap_end;
  (FASLHDR_CODE_START (fh)) = new_code_start;
  (FASLHDR_CODE_END (fh)) = new_code_end;
  (FASLHDR_ROOT_POINTER (fh)) = new_heap_start;
  (FASLHDR_N_PRIMITIVES (fh)) = n_primitives;
  (FASLHDR_PRIMITIVE_TABLE_SIZE (fh)) = prim_table_length;
  finalize_fasl_header (dumped_ephemeron_count);

  ok = ((write_fasl_header (fh, (ff_info . handle)))
	&& (save_tospace (save_fasdump_tospace, (&ff_info))));
  discard_code_tospace ();
  transaction_commit ();	/* 1 */

  COMPARE_GC_VARS ();
  COMPARE_MEMORY_CHECKSUM ();

  PRIMITIVE_RETURN (BOOLEAN_TO_OBJECT (ok));
}

static void
close_fasl_file (void * p)
{
  fasl_file_info_t * ff_info = p;
  if (!close_fasl_output_file (ff_info->handle))
    OS_file_remove (ff_info->filename);
}

static void
abort_fasdump (void * p)
{
  (void) p;
  discard_code_tospace ();
  discard_tospace ();
}

static bool
save_fasdump_tospace (SCHEME_OBJECT * start, SCHEME_OBJECT * end, void * p)
{
  fasl_file_info_t * ff_info = p;
  unsigned long heap_words = (FASLHDR_HEAP_SIZE (fh));
  unsigned long code_words = (FASLHDR_CODE_SIZE (fh));
  unsigned long prim_words = (FASLHDR_PRIMITIVE_TABLE_SIZE (fh));

  if (((unsigned long) (end - start)) != (heap_words + prim_words))
    return (false);
  if (!write_to_fasl_file (start, heap_words, (ff_info->handle)))
    return (false);
  if ((code_words > 0)
      && (!write_to_fasl_file
	  ((newspace_to_tospace (FASLHDR_CODE_START (fh))),
	   code_words,
	   (ff_info->handle))))
    return (false);
  return (write_to_fasl_file
	  ((start + heap_words), prim_words, (ff_info->handle)));
}

#ifdef ENABLE_GC_DEBUGGING_TOOLS

static SCHEME_OBJECT * fasdump_saved_Free;
static SCHEME_OBJECT * fasdump_saved_heap_alloc_limit;
static SCHEME_OBJECT * fasdump_saved_heap_start;
static SCHEME_OBJECT * fasdump_saved_heap_end;
static SCHEME_OBJECT * fasdump_saved_stack_pointer;
static SCHEME_OBJECT * fasdump_saved_stack_guard;
static SCHEME_OBJECT * fasdump_saved_stack_start;
static SCHEME_OBJECT * fasdump_saved_stack_end;
static SCHEME_OBJECT * fasdump_saved_constant_alloc_next;
static SCHEME_OBJECT * fasdump_saved_constant_start;
static SCHEME_OBJECT * fasdump_saved_constant_end;

#define SAVE_GC_VAR(name) fasdump_saved_##name = name

static void
save_gc_vars (void)
{
  SAVE_GC_VAR (Free);
  SAVE_GC_VAR (heap_alloc_limit);
  SAVE_GC_VAR (heap_start);
  SAVE_GC_VAR (heap_end);
  SAVE_GC_VAR (stack_pointer);
  SAVE_GC_VAR (stack_guard);
  SAVE_GC_VAR (stack_start);
  SAVE_GC_VAR (stack_end);
  SAVE_GC_VAR (constant_alloc_next);
  SAVE_GC_VAR (constant_start);
  SAVE_GC_VAR (constant_end);
}

#define COMPARE_GC_VAR(name) do						\
{									\
  if (fasdump_saved_##name != name)					\
    outf_error ("GC variable changed: " #name ": %p -> %p\n",		\
		fasdump_saved_##name, name);				\
} while (false)

static void
compare_gc_vars (void)
{
  COMPARE_GC_VAR (Free);
  COMPARE_GC_VAR (heap_alloc_limit);
  COMPARE_GC_VAR (heap_start);
  COMPARE_GC_VAR (heap_end);
  COMPARE_GC_VAR (stack_pointer);
  COMPARE_GC_VAR (stack_guard);
  COMPARE_GC_VAR (stack_start);
  COMPARE_GC_VAR (stack_end);
  COMPARE_GC_VAR (constant_alloc_next);
  COMPARE_GC_VAR (constant_start);
  COMPARE_GC_VAR (constant_end);
}

static void * fasdump_original_digest;

static void
save_memory_checksum (void)
{
  fasdump_original_digest = (compute_memory_checksum ());
  if (fasdump_original_digest == 0)
    outf_error ("Unable to compute fasdump memory checksum.");
}

static void
compare_memory_checksum (void)
{
  if (fasdump_original_digest != 0)
    {
      void * digest = (compute_memory_checksum ());
      if (digest == 0)
	outf_error ("Unable to recompute fasdump memory checksum.");
      else
	{
	  if ((memcmp (digest, fasdump_original_digest, MD5_HASHLEN)) != 0)
	    outf_error ("Memory mismatch after fasdump.");
	  free (digest);
	}
      free (fasdump_original_digest);
    }
}

static void *
compute_memory_checksum (void)
{
  struct md5 ctx;
  void * hash;
  md5_init (&ctx);
  md5_update ((&ctx),
	      fasdump_saved_constant_start,
	      ((fasdump_saved_constant_alloc_next
		- fasdump_saved_constant_start)
	       * SIZEOF_SCHEME_OBJECT));
  md5_update ((&ctx),
	      fasdump_saved_heap_start,
	      ((fasdump_saved_Free - fasdump_saved_heap_start)
	       * SIZEOF_SCHEME_OBJECT));
  if ((code_start != 0) && (code_alloc_next > code_start))
    md5_update ((&ctx),
		code_start,
		((code_alloc_next - code_start) * SIZEOF_SCHEME_OBJECT));
  hash = (malloc (MD5_HASHLEN));
  if (hash == NULL)
    return NULL;
  md5_final ((&ctx), hash);
  return hash;
}

#endif /* ENABLE_GC_DEBUGGING_TOOLS */

static gc_table_t *
fasdump_table (void)
{
  static bool initialized_p = false;
  static gc_table_t table;

  if (!initialized_p)
    {
      initialize_gc_table ((&table), true);

      (GCT_CC_ENTRY ((&table))) = fasdump_cc_entry;
      (GCT_CC_RETURN ((&table))) = fasdump_cc_return;
      (GCT_PRECHECK_FROM ((&table))) = fasdump_precheck_from;
      (GCT_TRANSPORT_WORDS ((&table))) = fasdump_transport_words;

      (GCT_ENTRY ((&table), TC_COMPILED_CODE_BLOCK))
	= handle_compiled_code_block;
      (GCT_ENTRY ((&table), TC_PRIMITIVE)) = handle_primitive;
      (GCT_ENTRY ((&table), TC_MANIFEST_CLOSURE)) = handle_manifest_closure;
      (GCT_ENTRY ((&table), TC_LINKAGE_SECTION)) = handle_linkage_section;
      (GCT_ENTRY ((&table), TC_INTERNED_SYMBOL)) = handle_symbol;
      (GCT_ENTRY ((&table), TC_BROKEN_HEART)) = handle_broken_heart;
      (GCT_ENTRY ((&table), TC_UNINTERNED_SYMBOL)) = handle_symbol;
      (GCT_ENTRY ((&table), TC_ENVIRONMENT)) = handle_environment;
      (GCT_ENTRY ((&table), TC_WEAK_CONS)) = gc_handle_pair;
      (GCT_ENTRY ((&table), TC_EPHEMERON)) = handle_ephemeron;

      initialized_p = true;
    }
  return (&table);
}

static SCHEME_OBJECT *
fasdump_transport_cc_block (SCHEME_OBJECT * old_addr)
{
  SCHEME_OBJECT * new_addr;
  if ((compiler_utilities != SHARP_F)
      && (old_addr == (object_address (compiler_utilities))))
    return (old_addr);
  new_addr = (GC_PRECHECK_FROM (old_addr));
  if (new_addr == 0)
    {
      unsigned long length = (object_datum (*old_addr));
      if ((object_type (*old_addr)) == TC_MANIFEST_CLOSURE)
	new_addr = (GC_TRANSPORT_WORDS (old_addr, (1 + length), true));
      else
	{
	  SCHEME_OBJECT * eptr;
	  new_addr
	    = (fasdump_transport_code_words (old_addr, (1 + length), true));
	  eptr = (new_addr + length);
	  if ((current_env_mode == FE_DROP_CC)
	      && ((object_type (read_tospace (eptr))) == TC_ENVIRONMENT))
	    write_tospace (eptr, SHARP_F);
	}
    }
  return (new_addr);
}

static
DEFINE_GC_OBJECT_HANDLER (fasdump_cc_entry)
{
#ifdef CC_SUPPORT_P
  SCHEME_OBJECT * old_addr;
  SCHEME_OBJECT * new_addr;

  cc_seen_p = true;
  old_addr = (cc_entry_to_block_address (object));
  new_addr = (fasdump_transport_cc_block (old_addr));
  return (CC_ENTRY_NEW_BLOCK (object, new_addr, old_addr));
#else
  gc_no_cc_support ();
  return (object);
#endif
}

static
DEFINE_GC_OBJECT_HANDLER (fasdump_cc_return)
{
#ifdef CC_SUPPORT_P
  SCHEME_OBJECT * old_addr;
  SCHEME_OBJECT * new_addr;

  cc_seen_p = true;
  old_addr = (cc_return_to_block_address (object));
  new_addr = (fasdump_transport_cc_block (old_addr));
  return (CC_RETURN_NEW_BLOCK (object, new_addr, old_addr));
#else
  gc_no_cc_support ();
  return (object);
#endif
}

static
DEFINE_GC_HANDLER (handle_compiled_code_block)
{
#ifdef CC_SUPPORT_P
  SCHEME_OBJECT * old_addr = (object_address (object));
  SCHEME_OBJECT * new_addr;

  cc_seen_p = true;
  new_addr = (fasdump_transport_cc_block (old_addr));
  (*scan) = (object_new_address (object, new_addr));
  return (scan + 1);
#else
  (void) scan;
  (void) object;
  gc_no_cc_support ();
  return (scan);
#endif
}

static
DEFINE_GC_PRECHECK_FROM (fasdump_precheck_from)
{
  return ((BROKEN_HEART_P (*from)) ? (object_address (*from)) : 0);
}

static
DEFINE_GC_TRANSPORT_WORDS (fasdump_transport_words)
{
  /* Signal error here if insufficient space -- otherwise
     gc_transport_words() might terminate the microcode.  */
  if (!tospace_available_p (n_words))
    signal_error_from_primitive (ERR_FASDUMP_OBJECT_TOO_LARGE);
  add_fixup (from);
  return (gc_transport_words (from, n_words, align_p));
}

static
DEFINE_GC_TRANSPORT_WORDS (fasdump_transport_code_words)
{
  if (!code_tospace_available_p (n_words))
    signal_error_from_primitive (ERR_FASDUMP_OBJECT_TOO_LARGE);
  add_fixup (from);
  return (gc_transport_words_to_code_tospace (from, n_words, align_p));
}

static
DEFINE_GC_HANDLER (handle_primitive)
{
  (*scan) = (renumber_primitive (object, current_pr));
  return (scan + 1);
}

static
DEFINE_GC_HANDLER (handle_manifest_closure)
{
  cc_seen_p = true;
  return (gc_handle_manifest_closure (scan, object));
}

static
DEFINE_GC_HANDLER (handle_linkage_section)
{
  cc_seen_p = true;
  return (gc_handle_linkage_section (scan, object));
}

static
DEFINE_GC_HANDLER (handle_symbol)
{
  SCHEME_OBJECT * from = (object_address (object));
  SCHEME_OBJECT * new_address = (GC_PRECHECK_FROM (from));
  if (new_address == 0)
    {
      new_address = (GC_TRANSPORT_WORDS (from, 2, false));
      write_tospace ((new_address + SYMBOL_GLOBAL_VALUE),
		     (((object_type (object)) == TC_INTERNED_SYMBOL)
		      ? BROKEN_HEART_ZERO
		      : UNBOUND_OBJECT));
    }
  (*scan) = (object_new_address (object, new_address));
  return (scan + 1);
}

static
DEFINE_GC_HANDLER (handle_broken_heart)
{
  return
    (((object_datum (object)) == 0)
     ? (scan + 1)
     : (gc_handle_broken_heart (scan, object)));
}

static
DEFINE_GC_HANDLER (handle_environment)
{
  if (current_env_mode != FE_DUMP)
    signal_error_from_primitive (ERR_FASDUMP_ENVIRONMENT);
  (*scan) = (GC_HANDLE_VECTOR (object, false));
  return (scan + 1);
}

static
DEFINE_GC_HANDLER (handle_ephemeron)
{
  /* Count each one once by counting only if there is no borken heart.  */
  if (0 == (GC_PRECHECK_FROM (object_address (object))))
    dumped_ephemeron_count += 1;
  return (gc_handle_unaligned_vector (scan, object));
}

typedef struct
{
  SCHEME_OBJECT * addr;
  SCHEME_OBJECT object;
} fixup_t;

static fixup_t * fixups_start;
static fixup_t * fixups_next;
static fixup_t * fixups_end;

static void
initialize_fixups (void)
{
  fixup_t * data = (OS_malloc (64 * (sizeof (fixup_t))));
  fixups_start = data;
  fixups_next = data;
  fixups_end = (data + 64);
  transaction_record_action (tat_always, run_fixups, 0);
}

static void
add_fixup (SCHEME_OBJECT * addr)
{
  if (fixups_next >= fixups_end)
    {
      unsigned long n = ((fixups_end - fixups_start) * 2);
      unsigned long m = (fixups_next - fixups_start);
      fixup_t * data = (OS_realloc (fixups_start, (n * (sizeof (fixup_t)))));
      fixups_start = data;
      fixups_next = (data + m);
      fixups_end = (data + n);
    }
  (fixups_next -> addr) = addr;
  (fixups_next -> object) = (*addr);
  fixups_next += 1;
}

static void
run_fixups (void * p)
{
  fixup_t * scan = fixups_start;
  (void) p;
  code_arena_write_begin ();
  while (scan < fixups_next)
    {
      (* (scan->addr)) = (scan->object);
      scan += 1;
    }
  code_arena_write_end ();
  OS_free (fixups_start);
}

typedef struct
{
  SCHEME_OBJECT * heap_buf;
  SCHEME_OBJECT * const_buf;
} band_compact_ctx_t;

static DEFINE_GC_TUPLE_HANDLER (band_compact_tuple)
{
  (void) n_words;
  return (tuple);
}

static DEFINE_GC_VECTOR_HANDLER (band_compact_vector)
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

static DEFINE_GC_OBJECT_HANDLER (band_compact_cc_entry)
{
#ifdef CC_SUPPORT_P
  SCHEME_OBJECT * old_addr = (cc_entry_to_block_address (object));
  if ((code_address_p (old_addr)) && (BROKEN_HEART_P (*old_addr)))
    return (CC_ENTRY_NEW_BLOCK (object, (object_address (*old_addr)), old_addr));
#endif
  return (object);
}

static DEFINE_GC_OBJECT_HANDLER (band_compact_cc_return)
{
#ifdef CC_SUPPORT_P
  SCHEME_OBJECT * old_addr = (cc_return_to_block_address (object));
  if ((code_address_p (old_addr)) && (BROKEN_HEART_P (*old_addr)))
    return (CC_RETURN_NEW_BLOCK (object, (object_address (*old_addr)), old_addr));
#endif
  return (object);
}

static gc_table_t *
band_compact_table (void)
{
  static bool initialized_p = false;
  static gc_table_t table;

  if (!initialized_p)
    {
      initialize_gc_table ((&table), false);

      (GCT_TUPLE (&table)) = band_compact_tuple;
      (GCT_VECTOR (&table)) = band_compact_vector;
      (GCT_CC_ENTRY (&table)) = band_compact_cc_entry;
      (GCT_CC_RETURN (&table)) = band_compact_cc_return;

      (GCT_ENTRY ((&table), TC_WEAK_CONS)) = gc_handle_pair;
      (GCT_ENTRY ((&table), TC_EPHEMERON)) = gc_handle_unaligned_vector;
      (GCT_ENTRY ((&table), TC_BROKEN_HEART)) = gc_handle_non_pointer;

      initialized_p = true;
    }
  return (&table);
}

static void
band_compact_transport_block (SCHEME_OBJECT * block,
			      unsigned long n_words,
			      void * ctx)
{
  (void) ctx;
  if (!code_tospace_available_p (n_words))
    signal_error_from_primitive (ERR_FASDUMP_OBJECT_TOO_LARGE);
  add_fixup (block);
  (void) gc_transport_words_to_code_tospace (block, n_words, false);
}

static void
cleanup_band_compact (void * p)
{
  band_compact_ctx_t * ctx = p;
  close_stage_tospace ();
  discard_code_tospace ();
  if ((ctx->const_buf) != 0)
    {
      OS_free (ctx->const_buf);
      (ctx->const_buf) = 0;
    }
  if ((ctx->heap_buf) != 0)
    {
      OS_free (ctx->heap_buf);
      (ctx->heap_buf) = 0;
    }
}

static bool
write_compacted_band_file (const char * filename,
			   SCHEME_OBJECT * prim_table_start,
			   SCHEME_OBJECT * c_code_table_start)
{
  band_compact_ctx_t * ctx;
  unsigned long heap_words = (FASLHDR_HEAP_SIZE (fh));
  unsigned long const_words = (FASLHDR_CONSTANT_SIZE (fh));
  unsigned long live_words = (code_arena_live_words ());
  fasl_file_handle_t handle;
  bool ok;

  transaction_begin ();
  ctx = (dstack_alloc (sizeof (band_compact_ctx_t)));
  (ctx->heap_buf) = 0;
  (ctx->const_buf) = 0;
  transaction_record_action (tat_always, cleanup_band_compact, ctx);

  if (!open_code_tospace (live_words + 64))
    {
      transaction_commit ();
      return (false);
    }
  initialize_fixups ();

  code_arena_for_each_live_block (band_compact_transport_block, 0);
  (FASLHDR_CODE_START (fh)) = (get_code_newspace_start ());
  (FASLHDR_CODE_END (fh)) = (get_code_newspace_ptr ());

  if ((compiler_utilities != SHARP_F) && (CC_BLOCK_P (compiler_utilities)))
    {
      SCHEME_OBJECT * uaddr = (object_address (compiler_utilities));
      if ((code_address_p (uaddr)) && (BROKEN_HEART_P (*uaddr)))
	(FASLHDR_UTILITIES_VECTOR (fh))
	  = (object_new_address (compiler_utilities,
				 (object_address (*uaddr))));
    }
  finalize_fasl_header (ephemeron_count);

  if (heap_words > 0)
    {
      (ctx->heap_buf) = (OS_malloc (heap_words * SIZEOF_SCHEME_OBJECT));
      memcpy ((ctx->heap_buf),
	      (FASLHDR_HEAP_START (fh)),
	      (heap_words * SIZEOF_SCHEME_OBJECT));
      open_stage_tospace
	((FASLHDR_HEAP_START (fh)), (ctx->heap_buf), heap_words);
      current_gc_table = (band_compact_table ());
      gc_scan_stage_tospace ();
      close_stage_tospace ();
    }

  if (const_words > 0)
    {
      (ctx->const_buf) = (OS_malloc (const_words * SIZEOF_SCHEME_OBJECT));
      memcpy ((ctx->const_buf),
	      (FASLHDR_CONSTANT_START (fh)),
	      (const_words * SIZEOF_SCHEME_OBJECT));
      open_stage_tospace
	((FASLHDR_CONSTANT_START (fh)), (ctx->const_buf), const_words);
      current_gc_table = (band_compact_table ());
      gc_scan_stage_tospace ();
      close_stage_tospace ();
    }

  if ((FASLHDR_CODE_SIZE (fh)) > 0)
    {
      current_gc_table = (band_compact_table ());
      gc_scan_code_tospace
	((FASLHDR_CODE_START (fh)), (FASLHDR_CODE_END (fh)));
    }

  OS_file_remove_link (filename);
  if (!open_fasl_output_file (filename, (&handle)))
    error_bad_range_arg (2);

  ok = ((write_fasl_header (fh, handle))
	&& ((heap_words == 0)
	    || (write_to_fasl_file ((ctx->heap_buf), heap_words, handle)))
	&& ((const_words == 0)
	    || (write_to_fasl_file ((ctx->const_buf), const_words, handle)))
	&& (((FASLHDR_CODE_SIZE (fh)) == 0)
	    || (write_to_fasl_file
		((newspace_to_tospace (FASLHDR_CODE_START (fh))),
		 (FASLHDR_CODE_SIZE (fh)),
		 handle)))
	&& (write_to_fasl_file (prim_table_start,
				(FASLHDR_PRIMITIVE_TABLE_SIZE (fh)),
				handle))
	&& (write_to_fasl_file (c_code_table_start,
				(FASLHDR_C_CODE_TABLE_SIZE (fh)),
				handle)));

  if (!close_fasl_output_file (handle))
    OS_file_remove (filename);
  transaction_commit ();
  return (ok);
}

DEFINE_PRIMITIVE ("DUMP-BAND*", Prim_band_dump, 2, 2,
		  "(PROCEDURE NAMESTRING)\n\
Saves an image of the current world to the file NAMESTRING.\n\
When the file is reloaded, PROCEDURE is called with an argument of #F.")
{
  SCHEME_OBJECT * to = Free;
  SCHEME_OBJECT * prim_table_start;
  SCHEME_OBJECT * c_code_table_start;
  const char * filename;
  bool result;
  PRIMITIVE_HEADER (2);

  CHECK_ARG (1, interpreter_applicable_p);
  filename = ((const char *) (arg_extended_string (2, NULL)));

  Primitive_GC_If_Needed (5);
  initialize_fasl_header (true, true);
  {
    SCHEME_OBJECT comb = make_pointer_object (TC_COMBINATION, to);
    *to++ = make_vector_header (2);
    *to++ = ARG_REF (1);
    *to++ = SHARP_F;

    SCHEME_OBJECT root = (make_pointer_object (TC_LIST, to));
    (*to++) = comb;
    (*to++) = compiler_utilities;

    (FASLHDR_ROOT_POINTER (fh)) = to;
    (*to++) = root;
  }

  prim_table_start = to;
  (FASLHDR_N_PRIMITIVES (fh)) = MAX_PRIMITIVE;
  (FASLHDR_PRIMITIVE_TABLE_SIZE (fh)) = (primitive_table_export_length ());
  to += (FASLHDR_PRIMITIVE_TABLE_SIZE (fh));

  c_code_table_start = to;
#ifdef CC_IS_C
  (FASLHDR_C_CODE_TABLE_SIZE (fh))
    = (c_code_table_export_length (& (FASLHDR_N_C_CODE_BLOCKS (fh))));
  to += (FASLHDR_C_CODE_TABLE_SIZE (fh));
#endif

  if (to > heap_end)
    result = false;
  else
    {
      unsigned long nonempty = (code_arena_nonempty_chunk_count ());

      export_primitive_table (prim_table_start);
#ifdef CC_IS_C
      export_c_code_table (c_code_table_start);
#endif

      (FASLHDR_HEAP_START (fh)) = heap_start;
      (FASLHDR_HEAP_END (fh)) = prim_table_start;
      (FASLHDR_CONSTANT_START (fh)) = constant_start;
      (FASLHDR_CONSTANT_END (fh)) = constant_alloc_next;

      if ((nonempty == 0)
	  || ((nonempty == 1)
	      && (code_start != 0)
	      && (code_alloc_next > code_start)))
	{
	  fasl_file_handle_t handle;

	  if ((code_start != 0) && (code_alloc_next > code_start))
	    {
	      (FASLHDR_CODE_START (fh)) = code_start;
	      (FASLHDR_CODE_END (fh)) = code_alloc_next;
	    }
	  finalize_fasl_header (ephemeron_count);

	  OS_file_remove_link (filename);
	  if (!open_fasl_output_file (filename, (&handle)))
	    error_bad_range_arg (2);

	  result
	    = (write_fasl_file (prim_table_start, c_code_table_start, handle));

	  if (!close_fasl_output_file (handle))
	    OS_file_remove (filename);
	}
      else
	result
	  = (write_compacted_band_file
	     (filename, prim_table_start, c_code_table_start));
    }
  PRIMITIVE_RETURN (BOOLEAN_TO_OBJECT (result));
}

static void
initialize_fasl_header (bool cc_p, bool band_p)
{
  fh = (&fasl_header);
  /* Provisionally set the version -- later, finalize_fasl_header will
     change it to the EPHEMERON format if there were any ephemerons.
     The difference between the older C_CODE format and the newer
     STACK_END format applies only to bands.  */
  (FASLHDR_VERSION (fh))
    = (band_p ? FASL_VERSION_STACK_END : FASL_VERSION_C_CODE);
  (FASLHDR_ARCH (fh)) = CURRENT_FASL_ARCH;
  (FASLHDR_BAND_P (fh)) = band_p;

#ifdef HEAP_IN_LOW_MEMORY
  (FASLHDR_MEMORY_BASE (fh)) = 0;
#else
  (FASLHDR_MEMORY_BASE (fh)) = memory_block_start;
#endif
  (FASLHDR_HEAP_RESERVED (fh)) = (band_p ? heap_reserved : 0);

  (FASLHDR_STACK_START (fh)) = stack_start;
  (FASLHDR_STACK_END (fh)) = stack_end;

  if (cc_p)
    {
      (FASLHDR_CC_VERSION (fh)) = compiler_interface_version;
      (FASLHDR_CC_ARCH (fh)) = compiler_processor_type;
      (FASLHDR_UTILITIES_VECTOR (fh)) = compiler_utilities;
    }
  else
    {
      (FASLHDR_CC_VERSION (fh)) = 0;
      (FASLHDR_CC_ARCH (fh)) = COMPILER_NONE_TYPE;
      (FASLHDR_UTILITIES_VECTOR (fh)) = SHARP_F;
    }
  (FASLHDR_N_C_CODE_BLOCKS (fh)) = 0;
  (FASLHDR_C_CODE_TABLE_SIZE (fh)) = 0;
  (FASLHDR_EPHEMERON_COUNT (fh)) = 0;
  (FASLHDR_CODE_START (fh)) = 0;
  (FASLHDR_CODE_END (fh)) = 0;
}

static void
finalize_fasl_header (unsigned long ephemeron_count)
{
  (FASLHDR_EPHEMERON_COUNT (fh)) = ephemeron_count;
  if ((FASLHDR_CODE_SIZE (fh)) != 0)
    (FASLHDR_VERSION (fh)) = FASL_VERSION_CODE_SPACE;
  else if (ephemeron_count != 0)
    (FASLHDR_VERSION (fh)) = FASL_VERSION_EPHEMERONS;
}

/* Stage file writes through an ordinary stack buffer so kernel copyin()
   never reads directly from a MAP_JIT VMA.  */
static bool
write_code_to_fasl_file (const SCHEME_OBJECT * src,
			 size_t n_words,
			 fasl_file_handle_t handle)
{
  SCHEME_OBJECT buf [512];
  size_t remaining = n_words;

  while (remaining > 0)
    {
      size_t chunk
	= ((remaining > ((sizeof (buf)) / SIZEOF_SCHEME_OBJECT))
	   ? ((sizeof (buf)) / SIZEOF_SCHEME_OBJECT)
	   : remaining);
      memcpy (buf, src, (chunk * SIZEOF_SCHEME_OBJECT));
      if (!write_to_fasl_file (buf, chunk, handle))
	return (false);
      src += chunk;
      remaining -= chunk;
    }
  return (true);
}

static bool
write_fasl_file (SCHEME_OBJECT * prim_table_start,
		 SCHEME_OBJECT * c_code_table_start,
		 fasl_file_handle_t handle)
{
  return
    ((write_fasl_header (fh, handle))
     && (write_to_fasl_file ((FASLHDR_HEAP_START (fh)),
			     (FASLHDR_HEAP_SIZE (fh)),
			     handle))
     && (write_to_fasl_file ((FASLHDR_CONSTANT_START (fh)),
			     (FASLHDR_CONSTANT_SIZE (fh)),
			     handle))
     && (((FASLHDR_CODE_SIZE (fh)) == 0)
	 || (write_code_to_fasl_file ((FASLHDR_CODE_START (fh)),
				      (FASLHDR_CODE_SIZE (fh)),
				      handle)))
     && (write_to_fasl_file (prim_table_start,
			     (FASLHDR_PRIMITIVE_TABLE_SIZE (fh)),
			     handle))
     && (write_to_fasl_file (c_code_table_start,
			     (FASLHDR_C_CODE_TABLE_SIZE (fh)),
			     handle)));
}
