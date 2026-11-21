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

/* OUTF system

   outf_channel I/O is a substitute for <stdio.h>.  On text-based
   systems it is implemented in terms of stdio.  On windowing systems,
   however, we have to be able to report problems without having an
   obvious text output.

   There are three channels for output:

   CONSOLE_OUTPUT - for normal output to the user
   ERROR_OUTPUT   - for output of exceptional things
   FATAL_OUTPUT   - for details of an impending crash

   Use outf where you would normally think of using fprintf and
   outf_flush where you would normally use fflush.  */

#include <stdarg.h>
#include <stdio.h>

typedef struct
{
  enum { OUTF_CONSOLE, OUTF_ERROR, OUTF_FATAL, OUTF_FILE } type;
  void * cookie;
} outf_channel;

extern outf_channel CONSOLE_OUTPUT;
extern outf_channel ERROR_OUTPUT;
extern outf_channel FATAL_OUTPUT;

extern outf_channel FILE_OUTPUT (FILE *);
extern void outf (outf_channel, const char *, ...);
extern void voutf (outf_channel, const char *, va_list);
extern void outf_flush (outf_channel);
extern void outf_console (const char *, ...);
extern void outf_error (const char *, ...);
extern void outf_error_line (const char *, ...);
extern void outf_fatal (const char *, ...);
extern void voutf_console (const char *, va_list);
extern void outf_flush_console (void);
extern void voutf_error (const char *, va_list);
extern void outf_flush_error (void);
extern void voutf_error_line (const char *, va_list);
extern void voutf_fatal (const char *, va_list);
extern void outf_flush_fatal (void);

outf_channel CONSOLE_OUTPUT = { .type = OUTF_CONSOLE };
outf_channel ERROR_OUTPUT = { .type = OUTF_ERROR };
outf_channel FATAL_OUTPUT = { .type = OUTF_FATAL };

outf_channel
FILE_OUTPUT (FILE * fp)
{
  return ((outf_channel) { .type = OUTF_FILE, .cookie = fp });
}

void
outf (outf_channel chan, const char * format, ...)
{
    va_list ap;
    va_start (ap, format);
    voutf (chan, format, ap);
    va_end (ap);
}

void
voutf (outf_channel chan, const char * format, va_list ap)
{
  switch (chan.type)
    {
    case OUTF_CONSOLE: voutf_console (format, ap); break;
    case OUTF_ERROR: voutf_error (format, ap); break;
    case OUTF_FATAL: voutf_fatal (format, ap); break;
    case OUTF_FILE: vfprintf ((chan.cookie), format, ap); break;
    }
}

void
outf_flush (outf_channel chan)
{
  switch (chan.type)
    {
    case OUTF_CONSOLE: outf_flush_console (); break;
    case OUTF_ERROR: outf_flush_error (); break;
    case OUTF_FATAL: outf_flush_fatal (); break;
    case OUTF_FILE: fflush (chan.cookie); break;
    }
}

void
outf_console (const char * format, ...)
{
  va_list args;
  va_start (args, format);
  voutf_console (format, args);
  va_end (args);
}

void
outf_error (const char * format, ...)
{
  va_list args;
  va_start (args, format);
  voutf_error (format, args);
  va_end (args);
}

void
outf_error_line (const char * format, ...)
{
  va_list args;
  va_start (args, format);
  voutf_error_line (format, args);
  va_end (args);
}

void
outf_fatal (const char * format, ...)
{
  va_list args;
  va_start (args, format);
  voutf_fatal (format, args);
  va_end (args);
}

void
voutf_console (const char * format, va_list args)
{
  vfprintf (stdout, format, args);
}

void
outf_flush_console (void)
{
  fflush (stdout);
}

void
voutf_error (const char * format, va_list args)
{
  vfprintf (stderr, format, args);
}

void
outf_flush_error (void)
{
  fflush (stderr);
}

void
voutf_error_line (const char * format, va_list args)
{
  vfprintf (stderr, format, args);
  fputc ('\n', stderr);
  fflush (stderr);
}

void
voutf_fatal (const char * format, va_list args)
{
  vfprintf (stderr, format, args);
}

void
outf_flush_fatal (void)
{
  fflush (stderr);
}
