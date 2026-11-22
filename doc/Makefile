# Copyright (C) 1986, 1987, 1988, 1989, 1990, 1991, 1992, 1993, 1994,
#     1995, 1996, 1997, 1998, 1999, 2000, 2001, 2002, 2003, 2004, 2005,
#     2006, 2007, 2008, 2009, 2010, 2011, 2012, 2013, 2014, 2015, 2016,
#     2017, 2018, 2019, 2020, 2021, 2022 Massachusetts Institute of
#     Technology
#
# This file is part of MIT/GNU Scheme.
#
# MIT/GNU Scheme is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or (at
# your option) any later version.
#
# MIT/GNU Scheme is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with MIT/GNU Scheme; if not, write to the Free Software
# Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA 02110-1301,
# USA.

# **** BEGIN BOILERPLATE ****

SHELL ?= /bin/sh

srcdir = .
top_srcdir = .
VPATH = $(srcdir)
prefix ?= /usr/local
exec_prefix ?= $(prefix)

bindir ?= $(exec_prefix)/bin
sbindir ?= $(exec_prefix)/sbin
libexecdir ?= $(exec_prefix)/libexec
datarootdir ?= $(prefix)/share
datadir ?= $(datarootdir)
sysconfdir ?= $(prefix)/etc
sharedstatedir ?= $(prefix)/com
localstatedir ?= $(prefix)/var
libdir ?= $(exec_prefix)/lib
infodir ?= $(datarootdir)/info
mandir ?= $(datarootdir)/man
includedir ?= $(prefix)/include
PROJECT ?= mit-scheme
docdir ?= $(datarootdir)/doc/$(PROJECT)
oldincludedir = /usr/include

PACKAGE_TARNAME = $(PROJECT)

DESTDIR ?=
top_builddir = .

INSTALL ?= install
INSTALL_PROGRAM ?= $(INSTALL)
INSTALL_DATA ?= $(INSTALL) -m 644
INSTALL_SCRIPT ?= $(INSTALL)

LN_S ?= ln -s
mkinstalldirs = mkdir -p

# **** END BOILERPLATE ****

htmldir ?= $(docdir)/html
pdfdir ?= $(docdir)/pdf
psdir ?= $(docdir)/ps

ENABLE_HTML ?= yes
ENABLE_PDF ?= yes
ENABLE_PS ?= no

INST_TARGETS =
ifneq ($(ENABLE_HTML),no)
INST_TARGETS += install-html
endif
ifneq ($(ENABLE_PDF),no)
INST_TARGETS += install-pdf
endif
ifneq ($(ENABLE_PS),no)
INST_TARGETS += install-ps
endif

SUBDIRS = ffi ref-manual sos user-manual

all:
	@for D in $(SUBDIRS); do \
	    echo "making $@ in $${D}";\
	    ( cd $${D} && $(MAKE) $@ ) || exit 1;\
	done

mostlyclean:
	@for D in $(SUBDIRS); do \
	    echo "making $@ in $${D}";\
	    ( cd $${D} && $(MAKE) $@ ) || exit 1;\
	done

clean:
	@for D in $(SUBDIRS); do \
	    echo "making $@ in $${D}";\
	    ( cd $${D} && $(MAKE) $@ ) || exit 1;\
	done

distclean:
	@for D in $(SUBDIRS); do \
	    echo "making $@ in $${D}";\
	    ( cd $${D} && $(MAKE) $@ ) || exit 1;\
	done

maintainer-clean:
	@for D in $(SUBDIRS); do \
	    echo "making $@ in $${D}";\
	    ( cd $${D} && $(MAKE) $@ ) || exit 1;\
	done

tags TAGS:

install: install-info-gz install-man $(INST_TARGETS)

install-info-gz install-info:
	$(mkinstalldirs) $(DESTDIR)$(infodir)
	if [ ! -e $(DESTDIR)$(infodir)/dir ]; then \
	    $(INSTALL_DATA) info-dir $(DESTDIR)$(infodir)/dir; fi
	@for D in $(SUBDIRS); do \
	    echo "making $@ in $${D}";\
	    ( cd $${D} && $(MAKE) $@ ) || exit 1;\
	done

install-man:
	$(mkinstalldirs) $(DESTDIR)$(mandir)/man1
	$(INSTALL_DATA) $(PROJECT).1 $(DESTDIR)$(mandir)/man1/.

install-html:
	$(mkinstalldirs) $(DESTDIR)$(htmldir)
	$(INSTALL_DATA) index.html $(DESTDIR)$(htmldir)/.
	@for D in $(SUBDIRS); do \
	    echo "making $@ in $${D}";\
	    ( cd $${D} && $(MAKE) $@ ) || exit 1;\
	done

install-pdf:
	$(mkinstalldirs) $(DESTDIR)$(pdfdir)
	@for D in $(SUBDIRS); do \
	    echo "making $@ in $${D}";\
	    ( cd $${D} && $(MAKE) $@ ) || exit 1;\
	done

install-ps:
	$(mkinstalldirs) $(DESTDIR)$(psdir)
	@for D in $(SUBDIRS); do \
	    echo "making $@ in $${D}";\
	    ( cd $${D} && $(MAKE) $@ ) || exit 1;\
	done

.PHONY: all mostlyclean clean distclean maintainer-clean tags TAGS
.PHONY: install install-man install-info install-info-gz install-html install-pdf install-ps
