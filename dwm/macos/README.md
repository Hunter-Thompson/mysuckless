# dwm for native macOS applications

This is a separate, experimental native backend, not XQuartz and not a replacement
for WindowServer. It uses AppKit, Accessibility (AX), and a CoreGraphics event tap.
The X11 source and configuration remain unchanged. **Native runtime parity is not
verified.** Public APIs cannot provide all dwm/X11 semantics; see [PARITY.md](PARITY.md).

## Build and run

Requires macOS 11+ and Xcode Command Line Tools (`xcode-select --install`).

```sh
cd dwm
make                       # selects macos/ on Darwin, original X11 elsewhere
make test-native
make install PREFIX="$HOME/.local"
"$HOME/.local/bin/dwm-macos"
```

On first launch, grant the installed executable Accessibility access in System
Settings → Privacy & Security → Accessibility. Restart it after granting access.
If input capture fails, also grant Input Monitoring access. Launch from the same
path each time; replacing/rebuilding the executable may require reauthorizing it.
Do not run as root. Do not disable SIP. Quit any other tiling window manager first.
A per-user advisory lock prevents duplicate instances of this backend, not other
window managers. Stop with Option-Shift-Q, Ctrl-C in the launching terminal, or
SIGTERM. dwm restores only windows it minimized and exits simulated fullscreen.
It does not restore all pre-tiling positions. Force kill/crash cannot run cleanup;
restore minimized windows from the Dock manually. No auto-start is installed.

## Configuration and controls

Edit `macos/config.h`, then rebuild. X11's `config.h` cannot be included in a native
backend; its X keysyms, shell programs and class rules are not macOS APIs.
Native defaults mirror the five effective tags, 0.55 master factor, one master,
three layouts and 25-point top bar. Option replaces Mod1. Key codes are physical
ANSI positions, not translated characters; change `keys[]` for another layout.
Colors and bar drawing are in `Bar` in `dwm.m`. Rule bundle identifiers match
exactly, optional titles match substrings, and monitor numbers are zero-based in
NSScreen order. Gimp floats. The original Firefox rule's tag 9 is outside the
five-tag mask, so it is not copied as a functioning rule.

| Shortcut | Action |
| --- | --- |
| Option-P | Spotlight launcher (`launcherCommand`) |
| Option-Shift-Return | Terminal (`terminalCommand`) |
| Option-B | Toggle selected monitor's bar |
| Option-J / K | Next / previous visible client |
| Option-I / D | Increase / decrease master count |
| Option-H / L | Change master factor by 0.05 |
| Option-Return | Promote selected tiled client to master; swap when already master |
| Option-Tab | Previous tag view |
| Option-Shift-C | Press window close button (never kill the whole application) |
| Option-T / F / M | Tile / floating / monocle |
| Option-Space | Previous layout |
| Option-Shift-Space | Toggle selected window floating |
| Option-Shift-F | Simulated fullscreen / restore |
| Option-1…5 | View tag |
| Option-Control-1…5 | Toggle tag in view (cannot clear final tag) |
| Option-Shift-1…5 | Assign selected client to tag |
| Option-Control-Shift-1…5 | Toggle selected client's tag membership |
| Option-0 / Option-Shift-0 | View / assign all five tags |
| Option-comma / period | Previous / next monitor |
| Option-Shift-comma / period | Send selected client to previous / next monitor |
| Option-Shift-Q | Restore managed minimizations and quit |

Option-left-drag moves, Option-right-drag resizes, and Option-middle-click toggles
floating. Dragging a tiled window beyond 32 points makes it floating. Moving snaps
to work-area edges and dropping across displays transfers monitor ownership.
The bar supports left/right tag clicks (Option applies to selected client),
left/right layout clicks (previous/monocle), middle title click (zoom), and middle
status click (terminal). Title and occupied/selected tag indicators are drawn.
Bars do not accept keyboard focus.

`terminalCommand` and `launcherCommand` are trusted shell commands, just like dwm's
spawn configuration; status text is never executed. Sibling `dmenu` and `slstatus`
remain X11/Linux software and are **not** ported by this change. To supply status,
write UTF-8 text to `~/Library/Application Support/dwm/status`; at most 4096 bytes
are read every half second. For example:

```sh
mkdir -p "$HOME/Library/Application Support/dwm"
date '+%a %H:%M' > "$HOME/Library/Application Support/dwm/status"
```

## Operational limitations

- Tags minimize individual windows, with Dock animations and possible app focus
  changes. User-minimized windows are left minimized. Non-minimizable windows can
  remain visible on another tag; a diagnostic is logged. No entire app is hidden.
- Native Spaces, Stage Manager, app hide/unhide, Mission Control and native green-
  button fullscreen remain macOS-owned. There is no Space creation, switching or
  cross-Space movement. Native-fullscreen windows are excluded from geometry/tag
  operations. Use a single ordinary Space per display for initial testing.
- Window sizes are requests. Apps can reject or clamp them. Non-resizable windows
  and nonstandard/dialog windows start floating. Simulated fullscreen may be
  clamped below the menu bar; it is not a native fullscreen Space.
- Ordering is best-effort AX raise, not X11 restacking. No application border
  replacement, enforced focus lock against other apps, or ICCCM urgency protocol.
- AX observers plus a 500 ms reconciliation timer track regular GUI apps. Some
  apps expose incomplete AX trees, and apps/windows on other Spaces may be absent.
  Window state is in memory and does not survive restart. A vanished AX window
  later reappearing is treated as a new client.
- Protected system shortcuts and Secure Input can prevent the event tap from
  receiving keys. Focus-follows-mouse is limited; see the parity inventory.
- The bar uses the visible work area, leaving the system menu bar and Dock alone.
  It does not reserve that area for unmanaged apps. Mixed-DPI displays use logical
  screen coordinates. Display hotplug migrates orphaned clients; fullscreen saved
  geometry and floating geometry may need manual adjustment after disconnection.

## Validation

`make test-native` compiles shared C model code with `-Wall -Wextra -Werror` and
checks tag invariants, monitor wrapping and 8,740 tile configurations for bounds,
coverage and non-overlap. It does **not** test AX, Cocoa, input capture or rendering.
GitHub Actions builds the native backend and an Intel cross-build on a macOS host,
then stages installation. CI cannot grant interactive permissions or validate UI.

Before treating this as a working desktop replacement, test on a Mac:

1. Deny permissions, verify a diagnostic and clean exit; grant and restart. Start
   a second instance and verify it cannot take ownership.
2. Open multiple Terminal, Safari and Finder windows; create/close windows while
   running. Exercise tile, zero/multiple masters, factor limits, monocle, zoom,
   focus cycling, layout history and floating.
3. Exercise all tag combinations and view history on two displays. User-minimize
   a window before switching tags; verify it stays minimized. Test an app refusing
   minimization, and confirm unrelated windows of the same app are not hidden.
4. Verify all shortcuts, key-up suppression, bar buttons, drag thresholds,
   snapping, right-drag resize and cross-monitor transfers.
5. Toggle simulated fullscreen and restore tiled/floating state. Enter native
   fullscreen separately, switch Spaces, and verify dwm does not manipulate it.
6. Change resolution/scaling, move the Dock, disconnect a display, and check bars
   and client migration. Verify Unicode/long status and missing status file.
7. Quit by shortcut, SIGINT and SIGTERM; verify dwm-owned minimized windows return
   and user-minimized ones do not. Test app relaunch, permission revocation and
   Secure Input without assuming the event tap can bypass OS restrictions.

These interactive checks have not been executed on the Linux implementation host.
