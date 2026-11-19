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

#include "config.h"
#include "jit.h"
#include "dstack.h"
#include "outf.h"

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
  printf ("[1/6] jit_map_code_space OK (%p, page=%zu)\n",
	  code, (jit_page_size ()));

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
    printf ("[2/6] nested write brackets + execute add #42 OK\n");

    /* 3. Self-modification over cached line: patch to `add w0, w0, #100`. */
    jit_write_begin ();
    insns[0] = 0x11019000U;	/* add w0, w0, #100 */
    jit_flush_icache (code, (sizeof (uint32_t)));
    jit_write_end ();
    CHECK ((jit_write_nesting_depth ()) == 0);
    CHECK ((fn (10)) == 110);
    printf ("[3/6] patch + icache invalidate + re-execute #100 OK\n");

#ifdef SCM_JIT_APPLE
    /* 4. Confirm RX enforcement via child write fault in RX mode. */
    CHECK (child_faults_writing (&insns[2]));
    printf ("[4/6] RX hardware write fault verified in child\n");

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
      printf ("[5/6] siglongjmp APRR_EL0 / jit_force_execute_mode recovery OK\n");
    }
#else
    printf ("[4/6] skipped RX child fault test (non-SCM_JIT_APPLE)\n");
    printf ("[5/6] skipped siglongjmp APRR_EL0 test (non-SCM_JIT_APPLE)\n");
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
      printf ("[6/6] dstack write-scope unwind OK\n");
    }
  }
#else
  printf ("[2-6/6] skipped aarch64 instruction checks (non-aarch64 host)\n");
#endif

  jit_unmap_code_space (code, region_size);
  return (0);
}
