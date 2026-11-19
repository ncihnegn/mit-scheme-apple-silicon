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

#ifndef SCM_CODE_ARENA_H
#define SCM_CODE_ARENA_H 1

#include "config.h"
#include "object.h"

extern SCHEME_OBJECT * code_start;
extern SCHEME_OBJECT * code_alloc_next;
extern SCHEME_OBJECT * code_end;

extern void code_arena_setup (unsigned long initial_words);
extern void code_arena_teardown (void);

extern bool code_address_p (const void * addr);
extern bool code_range_valid_p (const SCHEME_OBJECT * start,
				const SCHEME_OBJECT * end);
extern unsigned long code_arena_chunk_count (void);
extern unsigned long code_arena_live_words (void);

extern SCHEME_OBJECT * code_arena_alloc (unsigned long n_words);

extern void code_arena_mark_begin (void);
extern bool code_arena_mark_block (SCHEME_OBJECT * block);
extern bool code_arena_marked_p (const SCHEME_OBJECT * block);
extern bool code_arena_mark_stack_empty_p (void);
extern SCHEME_OBJECT * code_arena_pop_mark_stack (void);
extern void code_arena_sweep (void);
extern void code_arena_rebuild_free_list (void);

extern void code_arena_write_begin (void);
extern void code_arena_write_end (void);
extern void * code_arena_write_scope_begin (void);
extern void code_arena_write_scope_end (void * saved_dstack_pos);
extern void code_arena_flush_icache (void);

#endif /* SCM_CODE_ARENA_H */
