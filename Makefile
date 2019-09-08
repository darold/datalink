EXTENSION  = datalink
EXTVERSION = $(shell grep default_version $(EXTENSION).control | \
		sed -e "s/default_version[[:space:]]*=[[:space:]]*'\([^']*\)'/\1/")

PGFILEDESC = "datalink - SQL/MED Datalink for PostgreSQL"

PG_CONFIG = pg_config

# Test that we can install the extension, PG >= 10
PG10 = $(shell $(PG_CONFIG) --version | egrep " [89]\." > /dev/null && echo no || echo yes)
ifneq ($(PG10),yes)
	$(error Minimum version of PostgreSQL required is 9.4.0)
endif

PG_CPPFLAGS = -I$(libpq_srcdir)
PG_LDFLAGS = -L$(libpq_builddir) -lpq
SHLIB_LINK = $(libpq)

DOCS = $(wildcard README*)
MODULES = datalink
MODULE_big = datalink_bgw
OBJS = datalink_bgw.o datalink.o

DATA = $(wildcard updates/*--*.sql) sql/$(EXTENSION)--$(EXTVERSION).sql
TESTS   = $(wildcard test/*.sql)
REGRESS = datalink

ifndef NO_PGXS
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
else
subdir = contrib/datalink
top_builddir = ../..
include $(top_builddir)/src/Makefile.global
include $(top_srcdir)/contrib/contrib-global.mk
endif
