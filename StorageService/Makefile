# Snowfell Storage Service — portable C99, sqlite3 the only dependency.
# `make service` builds only the service; the test targets reference
# the test harnesses (sfvectors.c / sfauth_test.c) and are never a
# dependency of the service target.

CC      ?= cc
CFLAGS  ?= -std=c99 -O2 -Wall -Wextra
LDLIBS  ?= -lsqlite3

SERVICE_SRC = sfcommon.c sfsha256.c sfjson.c sfstore.c sfauth.c \
              sfhttp.c sfadapter.c sfadapter_fs.c sfadapter_s3.c sfroutes.c \
              sfblob.c sfcms.c
HEADERS     = sfcommon.h sfsha256.h sfjson.h sfstore.h sfauth.h \
              sfadapter.h sfhttp.h sfroutes.h sfblob.h sfcms.h

.PHONY: service vectors authtest clean

service: snowfell-storage-service

snowfell-storage-service: $(SERVICE_SRC) service_main.c $(HEADERS)
	$(CC) $(CFLAGS) -o $@ $(SERVICE_SRC) service_main.c $(LDLIBS)

# Crypto vector harness (SF-T12c test file; not part of the service).
# Build line follows the harness's own header comment.
vectors: sfvectors
sfvectors: sfvectors.c sfsha256.c sfcommon.c sfjson.c sfsha256.h sfcommon.h sfjson.h
	$(CC) $(CFLAGS) -DSF_VECTORS_MAIN -o $@ sfvectors.c sfsha256.c sfcommon.c sfjson.c

# Auth behavior harness (SF-T12c test file; not part of the service).
authtest: sfauth_test
sfauth_test: sfauth_test.c $(SERVICE_SRC) $(HEADERS)
	$(CC) $(CFLAGS) -o $@ sfauth_test.c $(SERVICE_SRC) $(LDLIBS)

clean:
	rm -f snowfell-storage-service sfvectors sfauth_test
