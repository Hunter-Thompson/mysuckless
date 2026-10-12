# dwm for macOS

A native backend for dwm that manages ordinary macOS application windows.
It uses only public APIs: Accessibility to move and focus windows, a CoreGraphics
event tap for keys and mouse, and AppKit for the bar. No XQuartz, no SIP changes,
no injection into WindowServer. The X11 code in `dwm/` at the repository root is untouched.

## Build and run

Requires macOS 11+ and the Xcode Command Line Tools (`xcode-select --install`).

    cd dwm
    make                                # builds ../macos/dwm/dwm-macos on Darwin
    make install PREFIX="$HOME/.local"
    "$HOME/.local/bin/dwm-macos"        # -v logs every decision, -h lists the flags

On first start macOS asks for Accessibility access (System Settings → Privacy &
Security). dwm waits and starts working as soon as access is granted; no restart
needed. Only one instance runs per user.

Stop it with Command-Shift-Q, Ctrl-C, SIGTERM or by closing its terminal. On exit
dwm brings back the windows it hid and leaves everything else where it is. Tags,
layouts and window placement are remembered in
`~/Library/Application Support/dwm/state.plist`, so a restart (or a relaunch after a
crash) picks up where it left off. If an instance is ever killed outright,
`dwm-macos --restore` (or simply starting dwm again) fetches the windows it had
parked in the display corners.

### Running at login

    make -C macos/dwm install-agent PREFIX="$HOME/.local"

installs a LaunchAgent that starts the installed binary at login, restarts it
after a crash (not after Command-Shift-Q) and logs to `~/Library/Logs/dwm-macos.log`.
`make uninstall-agent` removes it. The agent runs dwm as its own process, so
macOS grants Accessibility to `dwm-macos` itself rather than to your terminal,
and an ad-hoc signed binary loses that grant on every rebuild. To keep it,
sign with a certificate of your own: in Keychain Access choose Certificate
Assistant → Create a Certificate, name it `dwm`, type Self-Signed Root,
certificate type Code Signing, then build with

    make CODESIGN_IDENTITY=dwm

Started from a terminal, dwm uses the terminal's Accessibility grant instead,
and rebuilds need nothing.

## How it maps to macOS

- **Tags** work like dwm: windows on unselected tags are parked one point inside
  a bottom corner of a display (the trick AeroSpace uses; dwm does the same off
  the X screen). Nothing is minimized, so the Dock stays clean. The corner is
  chosen so that no other display continues past it; with stacked displays the
  lowest one's corners are used. A one-point sliver of each parked window
  remains, usually behind the Dock. Reaching a hidden window through Cmd-Tab, the
  Dock or Mission Control views its tag, unless the application already has a
  window in the current view, which is focused instead.
- **Focus** follows what macOS reports. Clicking a window selects it in dwm;
  closing the selected window focuses the previous one in dwm's focus history.
  New windows take focus as in dwm, except windows an application opens on a tag
  that is not in view: those neither take focus nor switch the view
  (`focusNewWindows` in `config.h`). Focus-follows-mouse is available
  (`sloppyFocus`) but off by default: on macOS the menu bar belongs to the
  active app, so crossing windows on the way to a menu would switch apps.
- **Tiled windows moved with their own title bar** swap places with the window
  they are dropped on, move to the display they are dropped on, or snap back.
  Resizing a tiled window's width with its edge sets the master factor;
  anything else snaps back. Floating windows go where you put them. Windows an
  application moves by itself go back into the layout; one that keeps insisting
  on its own geometry (some refuse sizes or the corner) is left alone after one
  retry instead of flickering forever.
- **Spaces, Mission Control and the green button** stay macOS's. dwm only
  manages windows on the current Space; a window in a native fullscreen Space is
  left alone. Simulated fullscreen (Command-Shift-F) fills the visible screen
  below the menu bar. The lock screen pauses dwm.
- **Minimized windows and hidden apps (Cmd-H)** keep their tags but are left
  alone until they come back.
- **Sizes are requests.** Applications may enforce minimum sizes or refuse to
  move; dwm logs the first refusal per window. Non-resizable windows, dialogs and
  panels start floating and non-resizable ones stay floating. Tooltips, menus and
  other chrome that report as windows are ignored. A tab torn off Chrome or
  Safari becomes a window once it is dropped.
- **The bar** sits at the top of each display's visible area, below the menu bar
  and clear of the Dock. With the menu bar set to auto-hide, the bar and the
  tiles use the full height (the auto-hidden menu bar slides over them). On a
  MacBook with a notch, macOS keeps windows out of the strip beside the notch
  even when the menu bar is hidden, so dwm puts its bar there instead: tags,
  layout and title left of the notch, status right of it, and windows get the
  whole area below. Moving or hiding the Dock and changing displays (also after
  sleep) re-layouts. dwm logs each display's work area; `menuBarInset` in
  `config.h` overrides the detection. Layout: tags, layout symbol, title, status.
  The status shows `secure input` while a password field or a terminal with
  Secure Keyboard Entry holds the keyboard, because shortcuts cannot work then.
  Status text is read every half second from
  `~/Library/Application Support/dwm/status` (UTF-8, first 4 KiB), e.g.

      mkdir -p "$HOME/Library/Application Support/dwm"
      date '+%a %H:%M' > "$HOME/Library/Application Support/dwm/status"

- **Tiles meet exactly**: the layout uses dwm's integer arithmetic, so there are
  no one-point gaps or overlaps between windows. Borders, urgency hints and size
  increments have no public API on macOS and are not emulated.

## Configuration

Edit `config.h` and rebuild, as with dwm. Command replaces Mod1; key codes are
physical ANSI positions. Defaults mirror `../../dwm/config.h`: five tags, master factor
0.55, one master, tile/float/monocle, a 25-point top bar and the same colors.
Rules match an exact bundle identifier and/or a title substring; all matching
rules apply in order and their tags are OR-ed, as in dwm. Displays are numbered
left to right (then top to bottom), for rules and for the monitor keys.

| Shortcut | Action |
| --- | --- |
| Command-P | launcher: dwm presses `launcherKey` (Cmd-Space, Spotlight) |
| Command-Shift-Return | terminal (`commands[0]`) |
| Command-B | toggle bar |
| Command-J / K | focus next / previous window |
| Command-I / D | more / fewer masters |
| Command-H / L | shrink / grow master area |
| Command-Return | zoom (swap with master) |
| Command-Tab | previous tag view |
| Command-Shift-C | close window (presses its close button) |
| Command-T / F / M | tile / floating / monocle |
| Command-Space | previous layout |
| Command-Shift-Space | toggle floating |
| Command-Shift-F | toggle fullscreen |
| Command-1…5 | view tag; Control adds to view |
| Command-Shift-1…5 | move window to tag; Control toggles membership |
| Command-0 / Command-Shift-0 | view all / put window on all tags |
| Command-, / . | focus previous / next display; Shift sends the window (only with several displays; otherwise the keys stay with the application) |
| Command-Shift-Q | quit |

Mouse: Control-Command-left-drag moves (snaps to edges, tiled windows float
after 32 points), Control-Command-right-drag resizes,
Control-Command-middle-click toggles floating, and dropping a window on another
display moves it there. dwm itself uses the bare modifier for this; plain
Command-click is taken by nearly every macOS application (links, selections, "go
to definition"), hence `MOUSEMOD` in `config.h`, which you can set back to
`MODKEY`. Bar: left/right click a tag to view/toggle it (with Command: tag/toggle
the window), click the layout symbol for the previous layout (right click:
monocle), middle-click the title to zoom and the status to open a terminal.

Command bindings take precedence over matching app and system shortcuts while dwm
is running (including Command-Tab and Command-H). Recent macOS versions hand
Command-Space to Spotlight before any event tap sees it; if Command-Space opens
Spotlight instead of switching layouts, give Spotlight another shortcut in
System Settings → Keyboard → Keyboard Shortcuts and set `launcherKey` to match.
Change `MODKEY` in `config.h` to choose a different modifier.

## Known limits

- Some apps expose incomplete Accessibility trees (Electron, Java, games) and
  may not be managed or may refuse geometry. Secure Input (password fields) and
  a few protected system shortcuts bypass the event tap.
- Parked windows are still real windows: Mission Control shows them (smaller
  with "Group windows by application" on) and the 1-point sliver sits in a
  display corner, usually behind the Dock.
- macOS raises all of an application's windows when it is activated, so a
  floating window of another application can end up under a tiled one until it
  is focused again. Stage Manager and macOS's own edge-drag tiling rearrange
  windows behind dwm's back; dwm warns at startup and puts tiles back, but turn
  them off for a quiet desktop
  (`defaults write com.apple.WindowManager EnableTilingByEdgeDrag -bool false`).
- Window state is keyed by process id and window id, so it survives restarts of
  dwm but not of the application or of the login session.
- `make test-native` checks the shared layout model on any platform. CI builds
  the backend on macOS with `-Werror`. Interactive behavior needs a Mac to test;
  `dwm-macos -v` logs what it decides about every window.
