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

/* This is a "starter" program to be placed in a MacOS X application
   bundle.  It calls the real executable in the "Resources/" directory
   of the bundle, passing appropriate arguments to it.  */

#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>
#include <CoreServices/CoreServices.h>

static bool
x11_edwin_available_p (const char * scheme_path)
{
  const char * slash = (strrchr (scheme_path, '/'));
  char check_path [4096];
  int n;
  const char * display;

  if (slash == 0)
    return (false);

  n = (snprintf (check_path, (sizeof (check_path)),
		 "%.*s/x11-screen/x11-screen.com",
		 ((int) (slash - scheme_path)), scheme_path));
  if ((n <= 0) || (((size_t) n) >= (sizeof (check_path))))
    return (false);

  if ((access (check_path, R_OK)) != 0)
    return (false);

  display = (getenv ("DISPLAY"));
  return (((display != 0) && (display[0] != '\0'))
	  || ((access ("/opt/X11/bin/Xquartz", X_OK)) == 0)
	  || ((access ("/Applications/Utilities/XQuartz.app", F_OK)) == 0));
}

static bool
write_sh_single_quoted (FILE * fp, const char * s)
{
  for (; (*s) != '\0'; s += 1)
    {
      if ((*s) == '\'')
	{
	  if ((fputs ("'\\''", fp)) == EOF)
	    return (false);
	}
      else if ((putc ((*s), fp)) == EOF)
	return (false);
    }
  return (true);
}

static int
launch_in_terminal (const char * scheme_path)
{
  const char * tmpdir = (getenv ("TMPDIR"));
  size_t tmpdir_len;
  char script_path [4096];
  int n;
  int fd;
  FILE * fp;
  pid_t pid;
  int status = 0;

  if ((tmpdir == 0) || (tmpdir[0] == '\0'))
    tmpdir = "/tmp";
  tmpdir_len = (strlen (tmpdir));
  while ((tmpdir_len > 1) && (tmpdir[tmpdir_len - 1] == '/'))
    tmpdir_len -= 1;

  n = (snprintf (script_path, (sizeof (script_path)),
		 "%.*s/mit-scheme-XXXXXX.command",
		 ((int) tmpdir_len), tmpdir));
  if ((n <= 0) || (((size_t) n) >= (sizeof (script_path))))
    return (4);

  fd = (mkstemps (script_path, 8));
  if (fd < 0)
    return (4);

  if ((fchmod (fd, 0700)) != 0)
    {
      close (fd);
      unlink (script_path);
      return (4);
    }

  fp = (fdopen (fd, "w"));
  if (fp == 0)
    {
      close (fd);
      unlink (script_path);
      return (4);
    }

  if (((fputs ("#!/bin/sh\nrm -f -- \"$0\"\nexec '", fp)) == EOF)
      || (!write_sh_single_quoted (fp, scheme_path))
      || ((fputs ("' --macosx-application --edit\n", fp)) == EOF)
      || ((fflush (fp)) != 0))
    {
      fclose (fp);
      unlink (script_path);
      return (4);
    }
  if ((fclose (fp)) != 0)
    {
      unlink (script_path);
      return (4);
    }

  pid = (fork ());
  if (pid < 0)
    {
      unlink (script_path);
      return (3);
    }
  if (pid == 0)
    {
      execl ("/usr/bin/open", "open", "-a", "Terminal", script_path, ((char *) 0));
      _exit (1);
    }
  if (((waitpid (pid, (&status), 0)) == pid)
      && ((!WIFEXITED (status)) || ((WEXITSTATUS (status)) != 0)))
    {
      unlink (script_path);
      return (5);
    }
  return (0);
}

int
main (int argc, const char ** argv)
{
  CFBundleRef bundle;
  CFURLRef url;
  UInt8 buffer [4096];
  char * bp;
  pid_t pid;

  (void) argc;
  (void) argv;

  bundle = (CFBundleGetMainBundle());
  if (bundle == 0)
    return (1);

  url = (CFBundleCopyResourceURL (bundle,
				  (CFSTR ("mit-scheme")),
				  (CFSTR ("")),
				  0));
  if (url == 0)
    return (2);

  if (!CFURLGetFileSystemRepresentation (url, true, buffer, (sizeof (buffer))))
    {
      CFRelease (url);
      return (3);
    }
  CFRelease (url);

  bp = ((char *) buffer);
  if (x11_edwin_available_p (bp))
    {
      pid = (fork ());
      if (pid == 0)
	{
	  execl (bp, bp, "--macosx-application", "--edit", ((char *) 0));
	  _exit (1);
	}
      return ((pid > 0) ? 0 : 3);
    }

  return (launch_in_terminal (bp));
}
