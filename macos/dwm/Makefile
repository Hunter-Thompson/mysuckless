CC = clang
PREFIX ?= /usr/local
CFLAGS = -O2 -Wall -Wextra
MACFLAGS = -fobjc-arc -mmacosx-version-min=11.0 -Wno-deprecated-declarations
FRAMEWORKS = -framework AppKit -framework ApplicationServices -framework Carbon
# An identity from your login keychain makes the Accessibility grant survive
# rebuilds (see README.md); empty keeps the linker's ad-hoc signature.
CODESIGN_IDENTITY ?=
AGENT = org.suckless.dwm-macos
AGENT_PLIST = $(HOME)/Library/LaunchAgents/$(AGENT).plist

all: dwm-macos

dwm-macos: dwm.m config.h model.c model.h Info.plist
	$(CC) $(CFLAGS) $(MACFLAGS) $(FRAMEWORKS) -sectcreate __TEXT __info_plist Info.plist dwm.m model.c -o $@
	@if [ -n "$(CODESIGN_IDENTITY)" ]; then codesign --force --sign "$(CODESIGN_IDENTITY)" --identifier $(AGENT) $@; fi

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

# runs the installed binary at login and after a crash, logging to ~/Library/Logs
install-agent:
	mkdir -p "$(HOME)/Library/LaunchAgents" "$(HOME)/Library/Logs"
	-launchctl bootout gui/$$(id -u) "$(AGENT_PLIST)" 2>/dev/null
	printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
		'<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
		'<plist version="1.0"><dict>' \
		'	<key>Label</key><string>$(AGENT)</string>' \
		'	<key>ProgramArguments</key><array><string>$(PREFIX)/bin/dwm-macos</string></array>' \
		'	<key>RunAtLoad</key><true/>' \
		'	<key>KeepAlive</key><dict><key>SuccessfulExit</key><false/><key>Crashed</key><true/></dict>' \
		'	<key>ProcessType</key><string>Interactive</string>' \
		'	<key>StandardOutPath</key><string>$(HOME)/Library/Logs/dwm-macos.log</string>' \
		'	<key>StandardErrorPath</key><string>$(HOME)/Library/Logs/dwm-macos.log</string>' \
		'</dict></plist>' > "$(AGENT_PLIST)"
	launchctl enable gui/$$(id -u)/$(AGENT)
	launchctl bootstrap gui/$$(id -u) "$(AGENT_PLIST)"

uninstall-agent:
	-launchctl bootout gui/$$(id -u) "$(AGENT_PLIST)" 2>/dev/null
	rm -f "$(AGENT_PLIST)"

clean:
	rm -f dwm-macos model-test

.PHONY: all test install uninstall install-agent uninstall-agent clean
