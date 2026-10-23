CC     ?= cc
CFLAGS ?= -O2
CFLAGS += -std=c99 -Wall -Wextra -D_DEFAULT_SOURCE

BINS := niinit niinit-sv niinit-svdir svctl niinit-parallel

all: $(BINS:%=bin/%)

bin:
	@mkdir -p bin

bin/niinit: src/niinit.c | bin
	$(CC) $(CFLAGS) -o $@ $<

bin/niinit-sv: src/sv.c | bin
	$(CC) $(CFLAGS) -o $@ $<

bin/niinit-svdir: src/svdir.c | bin
	$(CC) $(CFLAGS) -o $@ $<

bin/svctl: src/svctl.c | bin
	$(CC) $(CFLAGS) -o $@ $<

bin/niinit-parallel: src/parallel.c | bin
	$(CC) $(CFLAGS) -o $@ $<

install: all
	install -Dm755 bin/niinit $(DESTDIR)/sbin/niinit
	install -Dm755 bin/niinit-sv $(DESTDIR)/sbin/niinit-sv
	install -Dm755 bin/niinit-svdir $(DESTDIR)/sbin/niinit-svdir
	install -Dm755 bin/svctl $(DESTDIR)/usr/bin/svctl
	install -Dm755 bin/niinit-parallel $(DESTDIR)/usr/bin/niinit-parallel
	ln -sf svctl $(DESTDIR)/usr/bin/reboot
	ln -sf svctl $(DESTDIR)/usr/bin/poweroff
	ln -sf svctl $(DESTDIR)/usr/bin/halt
	install -Dm755 skel/etc/niinit/1 $(DESTDIR)/etc/niinit/1
	install -Dm755 skel/etc/niinit/3 $(DESTDIR)/etc/niinit/3
	install -d $(DESTDIR)/etc/niinit/1.d
	for f in skel/etc/niinit/1.d/*; do \
		case "$$f" in \
		*.deps) install -m644 "$$f" $(DESTDIR)/etc/niinit/1.d/ ;; \
		*) install -m755 "$$f" $(DESTDIR)/etc/niinit/1.d/ ;; \
		esac; \
	done
	for tty in 1 2 3 4 5 6; do \
		install -Dm755 skel/etc/niinit/services/getty-tty$$tty/run \
		    $(DESTDIR)/etc/niinit/services/getty-tty$$tty/run; \
	done

clean:
	rm -rf bin

.PHONY: all install clean
