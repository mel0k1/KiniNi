CC     ?= cc
CFLAGS ?= -O2
CFLAGS += -std=c99 -Wall -Wextra -D_GNU_SOURCE

XBPS_CFLAGS := $(shell pkg-config --cflags libarchive 2>/dev/null)
XBPS_LIBS   := $(shell pkg-config --libs libarchive 2>/dev/null || \
	echo -larchive -lz -lbz2 -llzma -llz4 -lzstd -lcrypto -lpthread)

all: bin/kipki

bin:
	@mkdir -p bin

bin/kipki: src/kipki.c | bin
	$(CC) $(CFLAGS) $(CPPFLAGS) $(XBPS_CFLAGS) -o $@ $< $(LDFLAGS) -lxbps $(XBPS_LIBS)

install: all
	install -Dm755 bin/kipki $(DESTDIR)/usr/bin/kipki
	install -Dm644 skel/kipki.conf $(DESTDIR)/etc/kipki/kipki.conf

clean:
	rm -rf bin

.PHONY: all install clean
