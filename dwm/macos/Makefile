CC = clang
PREFIX ?= /usr/local
CFLAGS = -O2 -Wall -Wextra -Werror
MACFLAGS = -fobjc-arc -mmacosx-version-min=11.0

all: dwm-macos

dwm-macos: dwm.m config.h model.c model.h
	$(CC) $(CFLAGS) $(MACFLAGS) -Wno-deprecated-declarations -framework AppKit -framework ApplicationServices dwm.m model.c -o $@

model-test: model.c model.h model_test.c
	$(CC) $(CFLAGS) -std=c99 -pedantic model.c model_test.c -lm -o $@

test: model-test
	./model-test

install: all
	mkdir -p "$(DESTDIR)$(PREFIX)/bin"
	cp dwm-macos "$(DESTDIR)$(PREFIX)/bin/dwm-macos"
	chmod 755 "$(DESTDIR)$(PREFIX)/bin/dwm-macos"

uninstall:
	rm -f "$(DESTDIR)$(PREFIX)/bin/dwm-macos"

clean:
	rm -f dwm-macos model-test

.PHONY: all test install uninstall clean
