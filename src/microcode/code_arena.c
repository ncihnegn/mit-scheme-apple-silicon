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

/* Immovable mark-sweep arena for executable compiled code blocks. */

#include "code_arena.h"
#include "jit.h"
#include "outf.h"
#include "sdata.h"

#define CODE_ARENA_MIN_OVERFLOW_WORDS 262144UL
#define CODE_MARK_STACK_INITIAL_CAP 4096U

typedef struct code_arena_chunk
{
  SCHEME_OBJECT * start;
  SCHEME_OBJECT * alloc_next;
  SCHEME_OBJECT * end;
  size_t byte_size;
  unsigned long total_words;
  uint64_t * mark_bits;
  struct code_arena_chunk * next;
} code_arena_chunk_t;

SCHEME_OBJECT * code_start = 0;
SCHEME_OBJECT * code_alloc_next = 0;
SCHEME_OBJECT * code_end = 0;

static code_arena_chunk_t primary_chunk;
static bool primary_initialized_p = false;
static code_arena_chunk_t * code_overflow_chunks = 0;
static SCHEME_OBJECT * code_free_list = 0;

static SCHEME_OBJECT ** mark_stack = 0;
static size_t mark_stack_top = 0;
static size_t mark_stack_capacity = 0;

static code_arena_chunk_t *
first_chunk (void)
{
  return (primary_initialized_p ? (&primary_chunk) : 0);
}

static code_arena_chunk_t *
next_chunk (code_arena_chunk_t * c)
{
  return ((c == (&primary_chunk)) ? code_overflow_chunks : (c->next));
}

static void
sync_primary_alloc_next (code_arena_chunk_t * c)
{
  if (c == (&primary_chunk))
    code_alloc_next = (c->alloc_next);
}

static code_arena_chunk_t *
find_chunk_for_addr (const void * addr)
{
  uintptr_t target = ((uintptr_t) addr);
  code_arena_chunk_t * c;
  if (addr == 0)
    return (0);
  for (c = (first_chunk ()); (c != 0); c = (next_chunk (c)))
    {
      uintptr_t lo = ((uintptr_t) (c->start));
      uintptr_t hi = ((uintptr_t) (c->alloc_next));
      if ((target >= lo) && (target < hi))
	return (c);
    }
  return (0);
}

static void
init_chunk (code_arena_chunk_t * c, unsigned long requested_words)
{
  size_t page_size = (jit_page_size ());
  unsigned long words = ((requested_words == 0) ? 2048UL : requested_words);
  size_t raw_bytes;
  size_t byte_size;
  void * mapped;
  size_t n_bit_words;

  if (words > ((SIZE_MAX - page_size) / (sizeof (SCHEME_OBJECT))))
    {
      outf_fatal ("Requested code arena size overflows address space.\n");
      outf_flush_fatal ();
      exit (1);
    }
  raw_bytes = (((size_t) words) * (sizeof (SCHEME_OBJECT)));
  byte_size = (((raw_bytes + (page_size - 1)) / page_size) * page_size);
  mapped = (jit_map_code_space (byte_size));
  if (mapped == 0)
    {
      outf_fatal ("Unable to allocate %zu-byte JIT code arena.\n", byte_size);
      outf_flush_fatal ();
      exit (1);
    }
  (c->start) = ((SCHEME_OBJECT *) mapped);
  (c->alloc_next) = (c->start);
  (c->byte_size) = byte_size;
  (c->total_words) = ((unsigned long) (byte_size / (sizeof (SCHEME_OBJECT))));
  (c->end) = ((c->start) + (c->total_words));
  (c->next) = 0;

  if ((address_to_datum (c->end)) > DATUM_MASK)
    {
      jit_unmap_code_space (mapped, byte_size);
      (c->start) = 0;
      (c->alloc_next) = 0;
      (c->end) = 0;
      outf_fatal ("Code arena exceeds tagged datum range.\n");
      outf_flush_fatal ();
      exit (1);
    }

  n_bit_words = (((c->total_words) + 63UL) / 64UL);
  (c->mark_bits) = (calloc (n_bit_words, (sizeof (uint64_t))));
  if ((c->mark_bits) == 0)
    {
      jit_unmap_code_space (mapped, byte_size);
      (c->start) = 0;
      (c->alloc_next) = 0;
      (c->end) = 0;
      outf_fatal ("Unable to allocate code arena mark bitmap.\n");
      outf_flush_fatal ();
      exit (1);
    }
}

void
code_arena_setup (unsigned long initial_words)
{
  if (primary_initialized_p)
    code_arena_teardown ();

  init_chunk ((&primary_chunk), initial_words);

  mark_stack = (malloc (CODE_MARK_STACK_INITIAL_CAP * (sizeof (SCHEME_OBJECT *))));
  if (mark_stack == 0)
    {
      jit_unmap_code_space ((primary_chunk.start), (primary_chunk.byte_size));
      free (primary_chunk.mark_bits);
      memset ((&primary_chunk), 0, (sizeof (primary_chunk)));
      outf_fatal ("Unable to allocate code arena mark stack.\n");
      outf_flush_fatal ();
      exit (1);
    }
  mark_stack_capacity = CODE_MARK_STACK_INITIAL_CAP;
  mark_stack_top = 0;

  code_start = (primary_chunk.start);
  code_alloc_next = (primary_chunk.alloc_next);
  code_end = (primary_chunk.end);
  code_overflow_chunks = 0;
  code_free_list = 0;
  primary_initialized_p = true;
}

void
code_arena_teardown (void)
{
  code_arena_chunk_t * c = code_overflow_chunks;
  while (c != 0)
    {
      code_arena_chunk_t * following = (c->next);
      jit_unmap_code_space ((c->start), (c->byte_size));
      free (c->mark_bits);
      free (c);
      c = following;
    }
  code_overflow_chunks = 0;

  if (primary_initialized_p)
    {
      jit_unmap_code_space ((primary_chunk.start), (primary_chunk.byte_size));
      free (primary_chunk.mark_bits);
      memset ((&primary_chunk), 0, (sizeof (primary_chunk)));
      primary_initialized_p = false;
    }

  free (mark_stack);
  mark_stack = 0;
  mark_stack_top = 0;
  mark_stack_capacity = 0;

  code_start = 0;
  code_alloc_next = 0;
  code_end = 0;
  code_free_list = 0;
}

bool
code_address_p (const void * addr)
{
  return ((find_chunk_for_addr (addr)) != 0);
}

bool
code_range_valid_p (const SCHEME_OBJECT * start, const SCHEME_OBJECT * end)
{
  uintptr_t s = ((uintptr_t) start);
  uintptr_t e = ((uintptr_t) end);
  code_arena_chunk_t * c;
  if ((start == 0) || (end == 0) || (s > e))
    return (false);
  for (c = (first_chunk ()); (c != 0); c = (next_chunk (c)))
    {
      uintptr_t lo = ((uintptr_t) (c->start));
      uintptr_t hi = ((uintptr_t) (c->alloc_next));
      if ((s >= lo) && (e <= hi))
	return (true);
    }
  return (false);
}

unsigned long
code_arena_chunk_count (void)
{
  unsigned long count = 0;
  code_arena_chunk_t * c;
  for (c = (first_chunk ()); (c != 0); c = (next_chunk (c)))
    count += 1;
  return (count);
}

unsigned long
code_arena_live_words (void)
{
  unsigned long live = 0;
  code_arena_chunk_t * c;
  for (c = (first_chunk ()); (c != 0); c = (next_chunk (c)))
    {
      const SCHEME_OBJECT * scan = (c->start);
      while (scan < (c->alloc_next))
	{
	  SCHEME_OBJECT hdr = (*scan);
	  unsigned long len = (1 + (object_datum (hdr)));
	  if ((object_type (hdr)) == TC_MANIFEST_VECTOR)
	    live += len;
	  scan += len;
	}
    }
  return (live);
}

static SCHEME_OBJECT *
bump_alloc_in_chunk (code_arena_chunk_t * c, unsigned long alloc_words)
{
  unsigned long pad
    = (((!FLOATING_ALIGNED_P (c->alloc_next)) && ((c->alloc_next) < (c->end)))
       ? 1UL
       : 0UL);
  if (((unsigned long) ((c->end) - (c->alloc_next))) < (alloc_words + pad))
    return (0);

  jit_write_begin ();
  if (pad != 0)
    (*(c->alloc_next)++) = (make_nmv_header (0));
  {
    SCHEME_OBJECT * result = (c->alloc_next);
    (result[0]) = (make_nmv_header (alloc_words - 1));
    (result[1]) = 0;
    (c->alloc_next) = (result + alloc_words);
    sync_primary_alloc_next (c);
    jit_write_end ();
    return (result);
  }
}

SCHEME_OBJECT *
code_arena_alloc (unsigned long n_words)
{
  unsigned long alloc_words;
  SCHEME_OBJECT * prev_hole = 0;
  SCHEME_OBJECT * curr;
  code_arena_chunk_t * c;
  code_arena_chunk_t * tail_chunk = 0;

  if (n_words == 0)
    return (0);
  if (!primary_initialized_p)
    {
      outf_fatal ("code_arena_alloc: code arena not initialized.\n");
      outf_flush_fatal ();
      abort ();
    }
  alloc_words = ((n_words < 2) ? 2 : n_words);

  curr = code_free_list;
  while (curr != 0)
    {
      unsigned long hole_words = (1 + (object_datum (curr[0])));
      SCHEME_OBJECT * next_free
	= ((SCHEME_OBJECT *) ((uintptr_t) (curr[1])));
      if ((FLOATING_ALIGNED_P (curr)) && (hole_words >= alloc_words))
	{
	  unsigned long rem = (hole_words - alloc_words);
	  SCHEME_OBJECT * replacement = next_free;

	  jit_write_begin ();
	  (curr[0]) = (make_nmv_header (alloc_words - 1));
	  (curr[1]) = 0;
	  if (rem >= 2)
	    {
	      SCHEME_OBJECT * tail = (curr + alloc_words);
	      (tail[0]) = (make_nmv_header (rem - 1));
	      (tail[1]) = ((SCHEME_OBJECT) ((uintptr_t) next_free));
	      replacement = tail;
	    }
	  else if (rem == 1)
	    (curr[alloc_words]) = (make_nmv_header (0));

	  if (prev_hole == 0)
	    code_free_list = replacement;
	  else
	    (prev_hole[1]) = ((SCHEME_OBJECT) ((uintptr_t) replacement));
	  jit_write_end ();
	  return (curr);
	}
      prev_hole = curr;
      curr = next_free;
    }

  for (c = (first_chunk ()); (c != 0); c = (next_chunk (c)))
    {
      SCHEME_OBJECT * block = (bump_alloc_in_chunk (c, alloc_words));
      if (block != 0)
	return (block);
      tail_chunk = c;
    }

  {
    unsigned long half_primary = ((primary_chunk.total_words) / 2);
    unsigned long min_words
      = ((half_primary > CODE_ARENA_MIN_OVERFLOW_WORDS)
	 ? half_primary
	 : CODE_ARENA_MIN_OVERFLOW_WORDS);
    unsigned long overflow_words
      = (((alloc_words + 1) > min_words) ? (alloc_words + 1) : min_words);
    code_arena_chunk_t * extra = (malloc (sizeof (code_arena_chunk_t)));
    if (extra == 0)
      {
	outf_fatal ("Unable to allocate overflow code arena chunk header.\n");
	outf_flush_fatal ();
	exit (1);
      }
    init_chunk (extra, overflow_words);
    if (tail_chunk == (&primary_chunk))
      code_overflow_chunks = extra;
    else
      (tail_chunk->next) = extra;
    return (bump_alloc_in_chunk (extra, alloc_words));
  }
}

void
code_arena_mark_begin (void)
{
  code_arena_chunk_t * c;
  for (c = (first_chunk ()); (c != 0); c = (next_chunk (c)))
    {
      size_t n_bit_words = (((c->total_words) + 63UL) / 64UL);
      memset ((c->mark_bits), 0, (n_bit_words * (sizeof (uint64_t))));
    }
  mark_stack_top = 0;
}

bool
code_arena_mark_block (SCHEME_OBJECT * block)
{
  code_arena_chunk_t * c = (find_chunk_for_addr (block));
  size_t idx;
  size_t word_idx;
  uint64_t mask;

  if ((c == 0)
      || ((((uintptr_t) block) % (sizeof (SCHEME_OBJECT))) != 0)
      || ((object_type (block[0])) != TC_MANIFEST_VECTOR))
    {
      outf_fatal ("code_arena_mark_block: invalid block %p\n",
		  ((const void *) block));
      outf_flush_fatal ();
      abort ();
    }

  {
    unsigned long len = (1 + (object_datum (block[0])));
    if ((block + len) > (c->alloc_next))
      {
	outf_fatal ("code_arena_mark_block: block %p exceeds chunk bounds\n",
		    ((const void *) block));
	outf_flush_fatal ();
	abort ();
      }
  }

  idx = ((size_t) (block - (c->start)));
  word_idx = (idx >> 6);
  mask = ((UINT64_C (1)) << (idx & 63U));
  if (((c->mark_bits)[word_idx] & mask) != 0)
    return (false);

  (c->mark_bits)[word_idx] |= mask;
  if (mark_stack_top == mark_stack_capacity)
    {
      size_t new_cap = (mark_stack_capacity * 2);
      SCHEME_OBJECT ** grown
	= (realloc (mark_stack, (new_cap * (sizeof (SCHEME_OBJECT *)))));
      if (grown == 0)
	{
	  outf_fatal ("code_arena_mark_block: mark stack overflow\n");
	  outf_flush_fatal ();
	  exit (1);
	}
      mark_stack = grown;
      mark_stack_capacity = new_cap;
    }
  (mark_stack[mark_stack_top++]) = block;
  return (true);
}

bool
code_arena_marked_p (const SCHEME_OBJECT * block)
{
  code_arena_chunk_t * c = (find_chunk_for_addr (block));
  size_t idx;
  if ((c == 0)
      || ((((uintptr_t) block) % (sizeof (SCHEME_OBJECT))) != 0))
    return (false);
  idx = ((size_t) (block - (c->start)));
  return ((((c->mark_bits)[idx >> 6]) & ((UINT64_C (1)) << (idx & 63U))) != 0);
}

bool
code_arena_mark_stack_empty_p (void)
{
  return (mark_stack_top == 0);
}

SCHEME_OBJECT *
code_arena_pop_mark_stack (void)
{
  if (mark_stack_top == 0)
    {
      outf_fatal ("code_arena_pop_mark_stack: stack underflow\n");
      outf_flush_fatal ();
      abort ();
    }
  return (mark_stack[--mark_stack_top]);
}

static void
code_arena_coalesce_pass (bool check_marks_p)
{
  code_arena_chunk_t * c;
  SCHEME_OBJECT * free_tail = 0;

  code_free_list = 0;
  jit_write_begin ();
  for (c = (first_chunk ()); (c != 0); c = (next_chunk (c)))
    {
      SCHEME_OBJECT * scan = (c->start);
      SCHEME_OBJECT * hole_start = 0;

      while (scan < (c->alloc_next))
	{
	  SCHEME_OBJECT hdr = (*scan);
	  unsigned long hdr_type = (object_type (hdr));
	  unsigned long words = (1 + (object_datum (hdr)));
	  size_t idx = ((size_t) (scan - (c->start)));
	  bool live_p;

	  if (((hdr_type != TC_MANIFEST_VECTOR)
	       && (hdr_type != TC_MANIFEST_NM_VECTOR))
	      || (words == 0)
	      || ((scan + words) > (c->alloc_next)))
	    {
	      jit_write_end ();
	      outf_fatal ("code_arena sweep: corrupt header %#lx at %p\n",
			  ((unsigned long) hdr), ((const void *) scan));
	      outf_flush_fatal ();
	      abort ();
	    }

	  live_p
	    = ((hdr_type == TC_MANIFEST_VECTOR)
	       && ((!check_marks_p)
		   || ((((c->mark_bits)[idx >> 6])
			& ((UINT64_C (1)) << (idx & 63U)))
		       != 0)));

	  if (live_p)
	    {
	      if (hole_start != 0)
		{
		  unsigned long hole_words
		    = ((unsigned long) (scan - hole_start));
		  (hole_start[0]) = (make_nmv_header (hole_words - 1));
		  if (hole_words >= 2)
		    {
		      (hole_start[1]) = 0;
		      if (free_tail == 0)
			code_free_list = hole_start;
		      else
			(free_tail[1])
			  = ((SCHEME_OBJECT) ((uintptr_t) hole_start));
		      free_tail = hole_start;
		    }
		  hole_start = 0;
		}
	      scan += words;
	    }
	  else
	    {
	      if (hole_start == 0)
		hole_start = scan;
	      scan += words;
	    }
	}

      if (hole_start != 0)
	{
	  (c->alloc_next) = hole_start;
	  sync_primary_alloc_next (c);
	}

      if (check_marks_p)
	{
	  size_t n_bit_words = (((c->total_words) + 63UL) / 64UL);
	  memset ((c->mark_bits), 0, (n_bit_words * (sizeof (uint64_t))));
	}
    }
  jit_write_end ();
  mark_stack_top = 0;
}

void
code_arena_sweep (void)
{
  code_arena_coalesce_pass (true);
}

void
code_arena_rebuild_free_list (void)
{
  code_arena_coalesce_pass (false);
}

void
code_arena_write_begin (void)
{
  jit_write_begin ();
}

void
code_arena_write_end (void)
{
  jit_write_end ();
}

void *
code_arena_write_scope_begin (void)
{
  return (jit_write_scope_begin ());
}

void
code_arena_write_scope_end (void * saved_dstack_pos)
{
  jit_write_scope_end (saved_dstack_pos);
}

void
code_arena_flush_icache (void)
{
  code_arena_chunk_t * c;
  for (c = (first_chunk ()); (c != 0); c = (next_chunk (c)))
    if ((c->alloc_next) > (c->start))
      jit_flush_icache ((c->start),
			(((size_t) ((c->alloc_next) - (c->start)))
			 * (sizeof (SCHEME_OBJECT))));
}
