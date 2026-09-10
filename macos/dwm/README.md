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
    "$HOME/.local/bin/dwm-macos"

On first start macOS asks for Accessibility access; if key capture still fails
it also needs Input Monitoring (System Settings → Privacy & Security). dwm waits
and starts working as soon as access is granted; no restart needed. Rebuilding
the binary may require granting access again. Only one instance runs per user.

Stop it with Option-Shift-Q, Ctrl-C or SIGTERM. On exit dwm brings back windows
it hid and leaves everything else where it is.

## How it maps to macOS

- **Tags** work like dwm: windows on unselected tags are parked one point inside
  the bottom-right corner of their display (the same trick AeroSpace uses; dwm
  does the same off the X screen). Nothing is minimized, so the Dock stays clean.
  Reaching a hidden window through Cmd-Tab or the Dock views its tag.
- **Focus** follows what macOS reports. Clicking a window selects it in dwm.
  Focus-follows-mouse is available (`sloppyFocus` in `config.h`) but off by
  default: on macOS the menu bar belongs to the active app, so crossing windows
  on the way to a menu would switch apps.
- **Spaces, Mission Control and the green button** stay macOS's. dwm only
  manages windows on the current Space; a window in a native fullscreen Space is
  left alone. Simulated fullscreen (Option-Shift-F) fills the visible screen
  below the menu bar.
- **Minimized windows and hidden apps (Cmd-H)** keep their tags but are left
  alone until they come back.
- **Sizes are requests.** Applications may enforce minimum sizes or refuse to
  move; dwm logs the first refusal per window. Non-resizable windows, dialogs and
  panels start floating.
- **The bar** sits at the top of each display's visible area, below the menu bar
  and clear of the Dock. With the menu bar set to auto-hide, the bar and the
  tiles use the full height (the auto-hidden menu bar slides over them). On a
  MacBook with a notch, macOS keeps windows out of the strip beside the notch
  even when the menu bar is hidden, so dwm puts its bar there instead: tags,
  layout and title left of the notch, status right of it, and windows get the
  whole area below. dwm logs each display's work area at startup; `menuBarInset`
  in `config.h` overrides the detection. Layout: tags, layout symbol, title, status.
  Status text is read every half second from
  `~/Library/Application Support/dwm/status` (UTF-8, first 4 KiB), e.g.

      mkdir -p "$HOME/Library/Application Support/dwm"
      date '+%a %H:%M' > "$HOME/Library/Application Support/dwm/status"

- **No borders, urgency hints or size-increment handling**: macOS offers no
  public API for them.

## Configuration

Edit `config.h` and rebuild, as with dwm. Option replaces Mod1; key codes are
physical ANSI positions. Defaults mirror `../../dwm/config.h`: five tags, master factor
0.55, one master, tile/float/monocle, a 25-point top bar and the same colors.
Rules match an exact bundle identifier and/or a title substring; monitors are
zero-based in `NSScreen` order.

| Shortcut | Action |
| --- | --- |
| Option-P | launcher: dwm presses `launcherKey` (Cmd-Space, Spotlight) |
| Option-Shift-Return | terminal (`commands[0]`) |
| Option-B | toggle bar |
| Option-J / K | focus next / previous window |
| Option-I / D | more / fewer masters |
| Option-H / L | shrink / grow master area |
| Option-Return | zoom (swap with master) |
| Option-Tab | previous tag view |
| Option-Shift-C | close window (presses its close button) |
| Option-T / F / M | tile / floating / monocle |
| Option-Space | previous layout |
| Option-Shift-Space | toggle floating |
| Option-Shift-F | toggle fullscreen |
| Option-1…5 | view tag; Control adds to view |
| Option-Shift-1…5 | move window to tag; Control toggles membership |
| Option-0 / Option-Shift-0 | view all / put window on all tags |
| Option-, / . | focus previous / next monitor; Shift sends the window |
| Option-Shift-Q | quit |

Mouse: Option-left-drag moves (snaps to edges, tiled windows float after 32
points), Option-right-drag resizes, Option-middle-click toggles floating, and
dropping a window on another display moves it there. Bar: left/right click a
tag to view/toggle it (with Option: tag/toggle the window), click the layout
symbol for the previous layout (right click: monocle), middle-click the title to
zoom and the status to open a terminal.

## Known limits

- Some apps expose incomplete Accessibility trees (Electron, Java, games) and
  may not be managed or may refuse geometry. Secure Input (password fields) and
  a few protected system shortcuts bypass the event tap.
- Parked windows are still real windows: Mission Control shows them and the
  1-point sliver is in the display corner, usually behind the Dock.
- State lives in memory; a restart re-manages every window on the current view.
- `make test-native` checks the shared layout model on any platform. CI builds
  the backend on macOS with `-Werror`. Interactive behavior needs a Mac to test.
