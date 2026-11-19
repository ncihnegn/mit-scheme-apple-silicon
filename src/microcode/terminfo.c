/* Interface from Emacs to terminfo.
   Copyright (C) 1985, 1986 Free Software Foundation, Inc.

Copyright (C) 1986, 1987, 1988, 1989, 1990, 1991, 1992, 1993, 1994,
    1995, 1996, 1997, 1998, 1999, 2000, 2001, 2002, 2003, 2004, 2005,
    2006, 2007, 2008, 2009, 2010, 2011, 2012, 2013, 2014, 2015, 2016,
    2017, 2018, 2019, 2020, 2021, 2022 Massachusetts Institute of
    Technology

This file is part of GNU Emacs.

GNU Emacs is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY.  No author or distributor
accepts responsibility to anyone for the consequences of using it
or for whether it serves any particular purpose or works at all,
unless he says so in writing.  Refer to the GNU Emacs General Public
License for full details.

Everyone is granted permission to copy, modify and redistribute
GNU Emacs, but only under the conditions described in the
GNU Emacs General Public License.   A copy of this license is
supposed to have been given to you along with GNU Emacs so you
can know your rights and responsibilities.  It should be in a
file named COPYING.  Among other things, the copyright notice
and this notice must be preserved on all copies.  */

#include "config.h"
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>

#if defined(HAVE_NCURSES_H) || defined(HAVE_CURSES_H)
#  undef false
#  undef true
#  ifdef HAVE_TERMIOS_H
#    include <termios.h>
#  endif
#  if defined(HAVE_NCURSES_H)
#    include <ncurses.h>
#  elif defined(HAVE_CURSES_H)
#    include <curses.h>
#  endif
#endif

#if defined(HAVE_TERM_H)
#  include <term.h>
#else
   extern char * tparm (const char *, ...);
#endif

extern char * tparam (const char *, char *, int, ...);

/* Interface to curses/terminfo library.
   Turns out that all of the terminfo-level routines look
   like their termcap counterparts except for tparm, which replaces
   tgoto.  Not only is the calling sequence different, but the string
   format is different too.  */

char *
tparam (const char * string, char * outstring, int len, ...)
{
  va_list ap;
  long arg1, arg2, arg3, arg4;
  char * temp;
  size_t needed;

  va_start (ap, len);
  arg1 = (va_arg (ap, int));
  arg2 = (va_arg (ap, int));
  arg3 = (va_arg (ap, int));
  arg4 = (va_arg (ap, int));
  va_end (ap);

  /* NCURSES_CONST expands to empty on macOS SDK headers, so cast away const. */
  temp = (tparm (((char *) string),
		 arg1, arg2, arg3, arg4, 0L, 0L, 0L, 0L, 0L));
  if (temp == 0)
    return (0);
  needed = ((strlen (temp)) + 1);
  if ((outstring == 0) || (len <= 0) || (needed > ((size_t) len)))
    {
      outstring = ((char *) (malloc (needed)));
      if (outstring == 0)
	return (0);
    }
  memcpy (outstring, temp, needed);
  return (outstring);
}
