all:
	$(MAKE) -C niinit
	$(MAKE) -C kipki

install:
	$(MAKE) -C niinit install
	$(MAKE) -C kipki install

clean:
	$(MAKE) -C niinit clean
	$(MAKE) -C kipki clean

.PHONY: all install clean
