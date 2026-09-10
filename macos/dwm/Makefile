CC = clang
PREFIX ?= /usr/local
CFLAGS = -O2 -Wall -Wextra
MACFLAGS = -fobjc-arc -mmacosx-version-min=11.0 -Wno-deprecated-declarations
FRAMEWORKS = -framework AppKit -framework ApplicationServices

all: dwm-macos

dwm-macos: dwm.m config.h model.c model.h
	$(CC) $(CFLAGS) $(MACFLAGS) $(FRAMEWORKS) dwm.m model.c -o $@

model-test: model.c model.h model_test.c
	$(CC) $(CFLAGS) -std=c99 -pedantic model.c model_test.c -lm -o $@

test: model-test
	./model-test

install: all
	mkdir -p "$(DESTDIR)$(PREFIX)/bin"
	cp -f dwm-macos "$(DESTDIR)$(PREFIX)/bin/dwm-macos"
	chmod 755 "$(DESTDIR)$(PREFIX)/bin/dwm-macos"

uninstall:
	rm -f "$(DESTDIR)$(PREFIX)/bin/dwm-macos"

clean:
	rm -f dwm-macos model-test

.PHONY: all test install uninstall clean
