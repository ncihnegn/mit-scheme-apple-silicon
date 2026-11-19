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

/* Platform W^X JIT memory mapping and I-cache maintenance. */

#include "config.h"
#include "jit.h"
#include "dstack.h"
#include "outf.h"

#ifdef HAVE_UNISTD_H
#  include <unistd.h>
#endif

#ifdef HAVE_PTHREAD_H
#  include <pthread.h>
#endif

#ifdef HAVE_LIBKERN_OSCACHECONTROL_H
#  include <libkern/OSCacheControl.h>
#endif

#ifndef MAP_FAILED
#  define MAP_FAILED ((void *) (-1))
#endif

unsigned int jit_write_depth = 0;

bool
jit_available_p (void)
{
#if (defined(SCM_JIT_APPLE) && defined(CC_IS_NATIVE)) || defined(HAVE_MMAP)
  return (true);
#else
  return (false);
#endif
}

size_t
jit_page_size (void)
{
  static size_t cached = 0;
  if (cached == 0)
    {
      long ps = 0;
#ifdef HAVE_SYSCONF
      ps = (sysconf (_SC_PAGESIZE));
#elif defined(HAVE_GETPAGESIZE)
      ps = (getpagesize ());
#endif
#ifdef SCM_JIT_APPLE
      cached = ((ps > 0) ? ((size_t) ps) : 0x4000UL);
#else
      cached = ((ps > 0) ? ((size_t) ps) : 0x1000UL);
#endif
    }
  return (cached);
}

static size_t
jit_round_up_pages (size_t byte_length)
{
  size_t ps = (jit_page_size ());
  if (byte_length == 0)
    return (ps);
  if (byte_length > (SIZE_MAX - (ps - 1)))
    return (0);
  return (((byte_length + (ps - 1)) / ps) * ps);
}

void *
jit_map_code_space (size_t byte_length)
{
  size_t size = (jit_round_up_pages (byte_length));
  if (size == 0)
    return (0);

#if defined(SCM_JIT_APPLE) && defined(CC_IS_NATIVE)
  {
    void * addr
      = (mmap (0, size, (PROT_READ | PROT_WRITE | PROT_EXEC),
	       (MAP_PRIVATE | MAP_ANONYMOUS | MAP_JIT), -1, 0));
    if (addr == MAP_FAILED)
      return (0);
    if (jit_write_depth == 0)
      pthread_jit_write_protect_np (1);
    return (addr);
  }
#elif defined(HAVE_MMAP)
  {
#ifdef CC_IS_NATIVE
    int prot = (PROT_READ | PROT_WRITE | PROT_EXEC);
#else
    int prot = (PROT_READ | PROT_WRITE);
#endif
    void * addr
      = (mmap (0, size, prot, (MAP_PRIVATE | MAP_ANONYMOUS), -1, 0));
    return ((addr == MAP_FAILED) ? 0 : addr);
  }
#else
  return (malloc (size));
#endif
}

void
jit_unmap_code_space (void * addr, size_t byte_length)
{
  if (addr == 0)
    return;
#if (defined(SCM_JIT_APPLE) && defined(CC_IS_NATIVE)) || defined(HAVE_MMAP)
  {
    size_t size = (jit_round_up_pages (byte_length));
    if (size != 0)
      (void) munmap (addr, size);
  }
#else
  (void) byte_length;
  free (addr);
#endif
}

void
jit_write_begin (void)
{
  if (jit_write_depth == UINT_MAX)
    {
      outf_fatal ("jit_write_begin: nesting overflow\n");
      outf_flush_fatal ();
      abort ();
    }
  if (jit_write_depth == 0)
    {
#if defined(SCM_JIT_APPLE) && defined(CC_IS_NATIVE)
      pthread_jit_write_protect_np (0);
#endif
    }
  jit_write_depth += 1;
}

void
jit_write_end (void)
{
  if (jit_write_depth == 0)
    {
      outf_fatal ("jit_write_end: unmatched call\n");
      outf_flush_fatal ();
      abort ();
    }
  jit_write_depth -= 1;
  if (jit_write_depth == 0)
    {
#if defined(SCM_JIT_APPLE) && defined(CC_IS_NATIVE)
      pthread_jit_write_protect_np (1);
#endif
    }
}

unsigned int
jit_write_nesting_depth (void)
{
  return (jit_write_depth);
}

static void
jit_unwind_write_end (void * env)
{
  (void) env;
  if (jit_write_depth > 0)
    jit_write_end ();
}

void *
jit_write_scope_begin (void)
{
  void * saved = dstack_position;
  dstack_protect (jit_unwind_write_end, 0);
  jit_write_begin ();
  return (saved);
}

void
jit_write_scope_end (void * saved_dstack_pos)
{
  dstack_set_position (saved_dstack_pos);
}

void
jit_force_execute_mode (void)
{
  jit_write_depth = 0;
#if defined(SCM_JIT_APPLE) && defined(CC_IS_NATIVE)
  pthread_jit_write_protect_np (1);
#endif
}

void
jit_flush_icache (void * addr, size_t byte_length)
{
  if ((addr == 0) || (byte_length == 0))
    return;

#if defined(SCM_JIT_APPLE) || defined(HAVE_SYS_ICACHE_INVALIDATE)
  sys_icache_invalidate (addr, byte_length);
#elif defined(__aarch64__) && defined(__GNUC__)
  {
    uint64_t ctr_el0;
    size_t dsize;
    size_t isize;
    uintptr_t start = ((uintptr_t) addr);
    uintptr_t end = (start + byte_length);
    uintptr_t p;

    asm volatile ("mrs %0, ctr_el0" : "=r" (ctr_el0));
    dsize = (((size_t) 4U) << ((unsigned) ((ctr_el0 >> 16) & 0xf)));
    isize = (((size_t) 4U) << ((unsigned) (ctr_el0 & 0xf)));

    for (p = (start &~ (dsize - 1)); (p < end); p += dsize)
      asm volatile ("dc cvau, %0" : : "r" (p));
    asm volatile ("dsb ish" : : : "memory");

    for (p = (start &~ (isize - 1)); (p < end); p += isize)
      asm volatile ("ic ivau, %0" : : "r" (p));
    asm volatile ("dsb ish\n\tisb" : : : "memory");
  }
#else
  (void) addr;
  (void) byte_length;
#endif
}
