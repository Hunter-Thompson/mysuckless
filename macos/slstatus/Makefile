CC = clang
PREFIX ?= /usr/local
CFLAGS = -O2 -Wall -Wextra
MACFLAGS = -fobjc-arc -mmacosx-version-min=11.0
FRAMEWORKS = -framework Foundation -framework IOKit -framework SystemConfiguration

all: slstatus-macos

slstatus-macos: slstatus.m config.h support.c support.h
	$(CC) $(CPPFLAGS) $(CFLAGS) $(MACFLAGS) slstatus.m support.c $(LDFLAGS) $(FRAMEWORKS) -o $@

support-test: support.c support.h support_test.c
	$(CC) $(CPPFLAGS) $(CFLAGS) -std=c99 -pedantic support.c support_test.c $(LDFLAGS) -o $@

test: support-test
	./support-test

install: all
	mkdir -p "$(DESTDIR)$(PREFIX)/bin"
	cp -f slstatus-macos "$(DESTDIR)$(PREFIX)/bin/slstatus-macos"
	chmod 755 "$(DESTDIR)$(PREFIX)/bin/slstatus-macos"

uninstall:
	rm -f "$(DESTDIR)$(PREFIX)/bin/slstatus-macos"

clean:
	rm -f slstatus-macos support-test

.PHONY: all test install uninstall clean
