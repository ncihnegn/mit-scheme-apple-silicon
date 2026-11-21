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

#ifdef _WIN32
/* Native compiled-code transitions (C_to_interface / scheme_to_interface)
   do not emit SEH unwind tables; use MinGW's non-SEH setjmp/longjmp so
   unwinding out of compiled code does not invoke RtlUnwindEx. */
#  define __USE_MINGW_SETJMP_NON_SEH 1
#endif

#include <setjmp.h>

extern void scm_setjmp_loop (void **, void (*) (int, void *), void *);
extern int scm_setjmp_try (void **, void (*) (void *), void *);
extern void scm_longjmp (void *, int) __attribute__((noreturn));

void
scm_setjmp_loop (void ** env_slot, void (* body) (int, void *), void * ctx)
{
  void (* volatile vbody) (int, void *) = body;
  void * volatile vctx = ctx;
  jmp_buf env;
  *env_slot = &env;
  int code = setjmp (env);
  vbody (code, vctx);
}

int
scm_setjmp_try (void ** env_slot, void (* body) (void *), void * ctx)
{
  void (* volatile vbody) (void *) = body;
  void * volatile vctx = ctx;
  jmp_buf env;
  *env_slot = &env;
  int code = setjmp (env);
  if (code == 0)
    vbody (vctx);
  return code;
}

void
scm_longjmp (void * env, int code)
{
  longjmp (*(jmp_buf *) env, code);
}
