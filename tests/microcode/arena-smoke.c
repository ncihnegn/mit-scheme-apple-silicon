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

/* Standalone smoke test for code_arena mark-sweep reclamation. */

#include "config.h"
#include "code_arena.h"
#include "jit.h"
#include "dstack.h"
#include "outf.h"
#include "sdata.h"

#define CHECK(cond) do							\
{									\
  if (!(cond))								\
    {									\
      fprintf (stderr, "CHECK failed at %s:%d: %s\n",			\
	       __FILE__, __LINE__, #cond);				\
      abort ();								\
    }									\
} while (0)

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

typedef int (* const_fn_t) (void);

static void
emit_const_fn (SCHEME_OBJECT * block, uint32_t movz_insn)
{
#ifdef __aarch64__
  uint32_t * insns = ((uint32_t *) (block + 2));
  insns[0] = movz_insn;		/* movz w0, #imm */
  insns[1] = 0xd65f03c0U;	/* ret */
#else
  (void) block;
  (void) movz_insn;
#endif
}

static int
call_const_fn (SCHEME_OBJECT * block)
{
#ifdef __aarch64__
  const_fn_t fn = ((const_fn_t) (block + 2));
  return (fn ());
#else
  (void) block;
  return (-1);
#endif
}

int
main (void)
{
  const unsigned long a_words = 6;
  const unsigned long b_words = 8;
  const unsigned long c_words = 6;
  const unsigned long d_words = 10;
  SCHEME_OBJECT * a;
  SCHEME_OBJECT * b;
  SCHEME_OBJECT * c;
  SCHEME_OBJECT * d;
  SCHEME_OBJECT * b2;
  SCHEME_OBJECT * b3;
  SCHEME_OBJECT * filler;
  SCHEME_OBJECT * e;

  dstack_initialize ();

  /* 1. 16 KiB primary arena setup and RX steady state. */
  code_arena_setup (2048);
  CHECK (code_start != 0);
  CHECK (code_alloc_next == code_start);
  CHECK (code_end >= (code_start + 2048));
  CHECK ((jit_write_nesting_depth ()) == 0);
  CHECK ((code_arena_chunk_count ()) == 1);
  CHECK ((code_arena_live_words ()) == 0);
  printf ("[1/5] code_arena_setup OK (%p..%p, %lu words)\n",
	  ((void *) code_start), ((void *) code_end),
	  ((unsigned long) (code_end - code_start)));

  /* 2. Allocate 4 live blocks A, B, C, D and execute RX AArch64 stubs. */
  a = (code_arena_alloc (a_words));
  b = (code_arena_alloc (b_words));
  c = (code_arena_alloc (c_words));
  d = (code_arena_alloc (d_words));
  CHECK (a != 0 && b != 0 && c != 0 && d != 0);
  CHECK (b == (a + a_words));
  CHECK (c == (b + b_words));
  CHECK (d == (c + c_words));
  CHECK (code_alloc_next == (d + d_words));

  code_arena_write_begin ();
  (a[0]) = (make_vector_header (a_words - 1));
  emit_const_fn (a, 0x52800160U);	/* movz w0, #11 */
  (b[0]) = (make_vector_header (b_words - 1));
  (c[0]) = (make_vector_header (c_words - 1));
  emit_const_fn (c, 0x528002c0U);	/* movz w0, #22 */
  (d[0]) = (make_vector_header (d_words - 1));
  code_arena_write_end ();
  CHECK ((jit_write_nesting_depth ()) == 0);
  code_arena_flush_icache ();

#ifdef __aarch64__
  CHECK ((call_const_fn (a)) == 11);
  CHECK ((call_const_fn (c)) == 22);
#endif
  CHECK ((code_arena_live_words ()) == (a_words + b_words + c_words + d_words));
  CHECK (code_range_valid_p (a, (d + d_words)));
  CHECK (!code_range_valid_p (code_start, (code_alloc_next + 1)));
  printf ("[2/5] allocate + RX execute A & C OK\n");

  /* 3. Mark A & C, pop mark stack, sweep B (free hole) and D (retract top). */
  code_arena_mark_begin ();
  CHECK (code_arena_mark_block (a));
  CHECK (!code_arena_mark_block (a));
  CHECK (code_arena_mark_block (c));
  CHECK (code_arena_marked_p (a));
  CHECK (!code_arena_marked_p (b));
  CHECK (code_arena_marked_p (c));
  CHECK (!code_arena_marked_p (d));
  CHECK (!code_arena_mark_stack_empty_p ());
  CHECK ((code_arena_pop_mark_stack ()) == c);
  CHECK ((code_arena_pop_mark_stack ()) == a);
  CHECK (code_arena_mark_stack_empty_p ());

  code_arena_sweep ();
  CHECK ((jit_write_nesting_depth ()) == 0);
  CHECK (code_alloc_next == (c + c_words));
  CHECK (!code_address_p (d));
  CHECK (code_address_p (b));
  CHECK ((object_type (b[0])) == TC_MANIFEST_NM_VECTOR);
  CHECK ((1 + (object_datum (b[0]))) == b_words);
  CHECK ((code_arena_live_words ()) == (a_words + c_words));
#ifdef __aarch64__
  CHECK ((call_const_fn (a)) == 11);
  CHECK ((call_const_fn (c)) == 22);
#endif
  printf ("[3/5] mark-sweep retract tail D + free-hole B OK\n");

  /* 4. Split hole B -> 1-word remainder, then sweep & coalesce back to B_words. */
  b2 = (code_arena_alloc (b_words - 1));
  CHECK (b2 == b);
  CHECK ((b2[b_words - 1]) == (make_nmv_header (0)));
  code_arena_write_begin ();
  (b2[0]) = (make_vector_header (b_words - 2));
  code_arena_write_end ();

  code_arena_mark_begin ();
  CHECK (code_arena_mark_block (a));
  CHECK (code_arena_mark_block (c));
  code_arena_sweep ();
  CHECK ((object_type (b[0])) == TC_MANIFEST_NM_VECTOR);
  CHECK ((1 + (object_datum (b[0]))) == b_words);

  b3 = (code_arena_alloc (b_words));
  CHECK (b3 == b);
  code_arena_write_begin ();
  (b3[0]) = (make_vector_header (b_words - 1));
  code_arena_write_end ();
  printf ("[4/5] 1-word remainder split + coalesce + exact reuse OK\n");

  /* 5. Overflow chunk creation, cross-chunk mark-sweep, and rebuild_free_list. */
  {
    unsigned long remaining = ((unsigned long) (code_end - code_alloc_next));
    SCHEME_OBJECT * x;
    SCHEME_OBJECT * y;
    SCHEME_OBJECT * z;

    if (remaining >= 2)
      {
	filler = (code_arena_alloc (remaining));
	CHECK (filler != 0);
	code_arena_write_begin ();
	(filler[0]) = (make_vector_header (remaining - 1));
	code_arena_write_end ();
      }
    CHECK (code_alloc_next == code_end);

    e = (code_arena_alloc (16));
    CHECK (e != 0);
    CHECK ((code_arena_chunk_count ()) == 2);
    CHECK (code_address_p (e));
    code_arena_write_begin ();
    (e[0]) = (make_vector_header (15));
    emit_const_fn (e, 0x52800420U);	/* movz w0, #33 */
    code_arena_write_end ();
    code_arena_flush_icache ();
#ifdef __aarch64__
    CHECK ((call_const_fn (e)) == 33);
#endif

    code_arena_mark_begin ();
    CHECK (code_arena_mark_block (a));
    CHECK (code_arena_mark_block (c));
    CHECK (code_arena_mark_block (e));
    code_arena_sweep ();

    CHECK (code_alloc_next == (c + c_words));
    CHECK ((object_type (b[0])) == TC_MANIFEST_NM_VECTOR);
    CHECK ((1 + (object_datum (b[0]))) == b_words);
    CHECK (code_address_p (e));
    CHECK ((code_arena_live_words ()) == (a_words + c_words + 16));

    /* Split B into two 4-word NMV allocations and coalesce via rebuild. */
    x = (code_arena_alloc (4));
    y = (code_arena_alloc (4));
    CHECK (x == b && y == (b + 4));
    code_arena_rebuild_free_list ();
    CHECK ((object_type (b[0])) == TC_MANIFEST_NM_VECTOR);
    CHECK ((1 + (object_datum (b[0]))) == b_words);
    z = (code_arena_alloc (b_words));
    CHECK (z == b);
    printf ("[5/5] overflow chunk + cross-chunk sweep + rebuild_free_list OK\n");
  }

  code_arena_teardown ();
  CHECK (code_start == 0 && code_alloc_next == 0 && code_end == 0);
  CHECK ((code_arena_chunk_count ()) == 0);
  CHECK (!code_address_p (a));
  return (0);
}
