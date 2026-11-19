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

/* Standalone W^X smoke test for jit.c / MAP_JIT on Apple silicon. */

#include "scheme.h"
#include "jit.h"

#include <sys/wait.h>
#include <unistd.h>

#define CHECK(cond) do							\
{									\
  if (!(cond))								\
    {									\
      fprintf (stderr, "CHECK failed at %s:%d: %s\n",			\
	       __FILE__, __LINE__, #cond);				\
      abort ();								\
    }									\
} while (0)

/* Minimal runtime stubs required by wind.o / jit.o outside libmicrocode. */
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

#if defined(__aarch64__) && defined(CC_IS_NATIVE)
SCHEME_OBJECT * Free = 0;
SCHEME_OBJECT * constant_start = 0;

extern void * tospace_to_newspace (void *);
extern void * newspace_to_tospace (void *);

void *
tospace_to_newspace (void * addr)
{
  return (addr);
}

void *
newspace_to_tospace (void * addr)
{
  return (addr);
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
#endif /* __aarch64__ && CC_IS_NATIVE */

static sigjmp_buf sigusr1_env;
static volatile sig_atomic_t sigusr1_seen = 0;

static void
sigusr1_handler (int signo)
{
  (void) signo;
  sigusr1_seen = 1;
  siglongjmp (sigusr1_env, 1);
}

#ifdef SCM_JIT_APPLE
static bool
child_faults_writing (volatile uint32_t * target)
{
  pid_t pid;
  int status = 0;

  fflush (0);
  pid = (fork ());
  if (pid < 0)
    {
      perror ("fork");
      abort ();
    }
  if (pid == 0)
    {
      *target = 0U;
      _exit (0);
    }
  if ((waitpid (pid, (&status), 0)) != pid)
    {
      perror ("waitpid");
      abort ();
    }
  return (WIFSIGNALED (status));
}
#endif

#if defined(__aarch64__) && defined(CC_IS_NATIVE)
#  define JIT_SMOKE_TOTAL 9
#else
#  define JIT_SMOKE_TOTAL 6
#endif

int
main (void)
{
  const size_t region_size = 65536;
  void * code;

  dstack_initialize ();

  CHECK (jit_available_p ());
  CHECK ((jit_page_size ()) >= 4096);

  /* 1. Map MAP_JIT code space in RX steady state. */
  code = (jit_map_code_space (region_size));
  CHECK (code != 0);
  CHECK ((jit_write_nesting_depth ()) == 0);
  printf ("[1/%d] jit_map_code_space OK (%p, page=%zu)\n",
	  JIT_SMOKE_TOTAL, code, (jit_page_size ()));

#ifdef __aarch64__
  {
    typedef int (* add_fn_t) (int);
    volatile uint32_t * insns = ((volatile uint32_t *) code);
    add_fn_t fn = ((add_fn_t) code);

    /* 2. Nested write brackets, emit `add w0, w0, #42; ret`, flush, execute. */
    jit_write_begin ();
    CHECK ((jit_write_nesting_depth ()) == 1);
    jit_write_begin ();
    CHECK ((jit_write_nesting_depth ()) == 2);
    insns[0] = 0x1100a800U;	/* add w0, w0, #42 */
    insns[1] = 0xd65f03c0U;	/* ret */
    jit_flush_icache (code, (2 * sizeof (uint32_t)));
    jit_write_end ();
    CHECK ((jit_write_nesting_depth ()) == 1);
    jit_write_end ();
    CHECK ((jit_write_nesting_depth ()) == 0);
    CHECK ((fn (10)) == 52);
    printf ("[2/%d] nested write brackets + execute add #42 OK\n",
	    JIT_SMOKE_TOTAL);

    /* 3. Self-modification over cached line: patch to `add w0, w0, #100`. */
    jit_write_begin ();
    insns[0] = 0x11019000U;	/* add w0, w0, #100 */
    jit_flush_icache (code, (sizeof (uint32_t)));
    jit_write_end ();
    CHECK ((jit_write_nesting_depth ()) == 0);
    CHECK ((fn (10)) == 110);
    printf ("[3/%d] patch + icache invalidate + re-execute #100 OK\n",
	    JIT_SMOKE_TOTAL);

#ifdef SCM_JIT_APPLE
    /* 4. Confirm RX enforcement via child write fault in RX mode. */
    CHECK (child_faults_writing (&insns[2]));
    printf ("[4/%d] RX hardware write fault verified in child\n",
	    JIT_SMOKE_TOTAL);

    /* 5. Recover from siglongjmp inside an open write bracket. */
    {
      struct sigaction sa;
      struct sigaction old_sa;
      memset ((&sa), 0, (sizeof (sa)));
      sa.sa_handler = sigusr1_handler;
      sigemptyset (&sa.sa_mask);
      CHECK ((sigaction (SIGUSR1, (&sa), (&old_sa))) == 0);

      if ((sigsetjmp (sigusr1_env, 1)) == 0)
	{
	  jit_write_begin ();
	  CHECK ((jit_write_nesting_depth ()) == 1);
	  raise (SIGUSR1);
	  abort ();
	}
      CHECK (sigusr1_seen == 1);
      CHECK ((jit_write_nesting_depth ()) == 1);
      jit_force_execute_mode ();
      CHECK ((jit_write_nesting_depth ()) == 0);
      CHECK ((fn (10)) == 110);
      CHECK (child_faults_writing (&insns[2]));
      CHECK ((sigaction (SIGUSR1, (&old_sa), 0)) == 0);
      printf ("[5/%d] siglongjmp APRR_EL0 / jit_force_execute_mode recovery OK\n",
	      JIT_SMOKE_TOTAL);
    }
#else
    printf ("[4/%d] skipped RX child fault test (non-SCM_JIT_APPLE)\n",
	    JIT_SMOKE_TOTAL);
    printf ("[5/%d] skipped siglongjmp APRR_EL0 test (non-SCM_JIT_APPLE)\n",
	    JIT_SMOKE_TOTAL);
#endif

    /* 6. dstack scope unwind protection (normal exit, bulk unwind, and post-force unwind). */
    {
      void * s1 = (jit_write_scope_begin ());
      void * s2 = (jit_write_scope_begin ());
      void * outer;
      CHECK ((jit_write_nesting_depth ()) == 2);
      jit_write_scope_end (s2);
      CHECK ((jit_write_nesting_depth ()) == 1);
      jit_write_scope_end (s1);
      CHECK ((jit_write_nesting_depth ()) == 0);

      outer = dstack_position;
      (void) jit_write_scope_begin ();
      (void) jit_write_scope_begin ();
      CHECK ((jit_write_nesting_depth ()) == 2);
      dstack_set_position (outer);
      CHECK ((jit_write_nesting_depth ()) == 0);

      outer = dstack_position;
      (void) jit_write_scope_begin ();
      CHECK ((jit_write_nesting_depth ()) == 1);
      jit_force_execute_mode ();
      CHECK ((jit_write_nesting_depth ()) == 0);
      dstack_set_position (outer);
      CHECK ((jit_write_nesting_depth ()) == 0);
      CHECK ((fn (10)) == 110);
      printf ("[6/%d] dstack write-scope unwind OK\n", JIT_SMOKE_TOTAL);
    }

#ifdef CC_IS_NATIVE
    /* 7-9. Native AArch64 UUO dispatch tests (near, far br x1, RW NX closure). */
    {
      typedef uint64_t (* uuo_fn_t) (uint64_t, uint64_t, uint64_t *);
      const size_t far_size = (144UL * 1024UL * 1024UL);
      void * far_code = (jit_map_code_space (far_size));
      char * far_base;
      SCHEME_OBJECT * saddr;
      uuo_fn_t uuo_entry;
      int64_t * near_hdr;
      insn_t * target_near;
      insn_t * target_closure_rx;
      int64_t * far_hdr;
      insn_t * target_far;
      SCHEME_OBJECT * rw_closure;
      insn_t * closure_entry;
      uint64_t seen_x1 = 0;

      CHECK (far_code != 0);
      far_base = ((char *) far_code);
      saddr = ((SCHEME_OBJECT *) far_base);
      uuo_entry = ((uuo_fn_t) (((insn_t *) saddr) + 3));

      near_hdr = ((int64_t *) (far_base + 64));
      target_near = ((insn_t *) (near_hdr + 1));
      target_closure_rx = ((insn_t *) (far_base + 128));
      far_hdr = ((int64_t *) (far_base + (136UL * 1024UL * 1024UL)));
      target_far = ((insn_t *) (far_hdr + 1));

      jit_write_begin ();
      (*near_hdr) = 0;
      target_near[0] = 0xf9000041U;	/* str x1, [x2] */
      target_near[1] = 0x11001c00U;	/* add w0, w0, #7 */
      target_near[2] = 0xd65f03c0U;	/* ret */

      target_closure_rx[0] = 0xf9000041U;	/* str x1, [x2] */
      target_closure_rx[1] = 0x11005c00U;	/* add w0, w0, #23 */
      target_closure_rx[2] = 0xd65f03c0U;	/* ret */

      (*far_hdr) = 0;
      target_far[0] = 0xf9000041U;	/* str x1, [x2] */
      target_far[1] = 0x11004c00U;	/* add w0, w0, #19 */
      target_far[2] = 0xd65f03c0U;	/* ret */

      jit_flush_icache (far_base, 256);
      jit_flush_icache (target_far, (3 * (sizeof (insn_t))));

      /* 7. Near open procedure (<= 128 MiB): b target_near. */
      write_uuo_target (target_near, saddr);
      aarch64_flush_i_cache_region (saddr, UUO_LINK_SIZE);
      CHECK (((((insn_t *) saddr)[4]) & 0xfc000000U) == 0x14000000U);
      jit_write_end ();

      seen_x1 = 0;
      CHECK ((uuo_entry (100, 0, (&seen_x1))) == 107);
      CHECK (seen_x1 == ((uint64_t) target_near));
      printf ("[7/%d] write_uuo_target near open procedure OK\n",
	      JIT_SMOKE_TOTAL);

      /* 8. Far open procedure (> 128 MiB): br x1. */
      jit_write_begin ();
      write_uuo_target (target_far, saddr);
      aarch64_flush_i_cache_region (saddr, UUO_LINK_SIZE);
      CHECK ((((insn_t *) saddr)[4]) == 0xd61f0020U);
      jit_write_end ();

      seen_x1 = 0;
      CHECK ((uuo_entry (100, 0, (&seen_x1))) == 119);
      CHECK (seen_x1 == ((uint64_t) target_far));
      printf ("[8/%d] write_uuo_target far br x1 (>128 MiB) OK\n",
	      JIT_SMOKE_TOTAL);

      /* 9. Split RW NX closure target -> RX code entry with x1 == closure_entry. */
      rw_closure = (OS_malloc (4 * (sizeof (SCHEME_OBJECT))));
      CHECK (rw_closure != 0);
      memset (rw_closure, 0, (4 * (sizeof (SCHEME_OBJECT))));
      closure_entry = ((insn_t *) (rw_closure + 2));
      (((int64_t *) closure_entry)[-1])
	= (((char *) target_closure_rx) - ((char *) closure_entry));

      jit_write_begin ();
      write_uuo_target (closure_entry, saddr);
      aarch64_flush_i_cache_region (saddr, UUO_LINK_SIZE);
      CHECK ((((insn_t *) saddr)[4]) == 0xd1002031U);
      jit_write_end ();

      seen_x1 = 0;
      CHECK ((uuo_entry (100, 0, (&seen_x1))) == 123);
      CHECK (seen_x1 == ((uint64_t) closure_entry));
      free (rw_closure);

      /* Also verify aarch64_reset_hook() and aarch64_flush_i_cache(). */
      jit_write_begin ();
      CHECK ((jit_write_nesting_depth ()) == 1);
      aarch64_reset_hook ();
      CHECK ((jit_write_nesting_depth ()) == 0);
      constant_start = ((SCHEME_OBJECT *) far_code);
      Free = (constant_start + 8);
      aarch64_flush_i_cache ();
      Free = 0;
      constant_start = 0;

      jit_unmap_code_space (far_code, far_size);
      printf ("[9/%d] write_uuo_target split RW NX closure -> RX OK\n",
	      JIT_SMOKE_TOTAL);
    }
#endif /* CC_IS_NATIVE */
  }
#else
  printf ("[2-6/6] skipped aarch64 instruction checks (non-aarch64 host)\n");
#endif

  jit_unmap_code_space (code, region_size);
  return (0);
}
