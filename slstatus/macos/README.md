# slstatus for macOS

An isolated native backend using public macOS APIs. No XQuartz, shell commands,
private APIs, Accessibility permission, or root access is needed. The original
Linux/BSD sources and configuration are unchanged. Spotlight remains the
launcher; this backend makes no dmenu or dwm keybinding changes.

## Build and install

Requires macOS 11+ and the Xcode Command Line Tools (`xcode-select --install`).

```sh
make -C slstatus                         # Darwin: macos/slstatus-macos
make -C slstatus install PREFIX="$HOME/.local"
"$HOME/.local/bin/slstatus-macos"
```

Alternatively build directly with `make -C slstatus/macos`. Only the binary
`slstatus-macos` is installed; the Linux executable/man page is not replaced.
`PREFIX` defaults to `/usr/local`. Staging is supported with
`make -C slstatus/macos install DESTDIR=/tmp/stage PREFIX=/usr/local`.
Use the same prefix with `make -C slstatus uninstall` to remove the binary.
`make -C slstatus/macos clean` removes build/test binaries, not configuration.

## Usage

```sh
slstatus-macos       # foreground: update dwm's status file every second
slstatus-macos -s    # continuously print and flush one UTF-8 line per update
slstatus-macos -1    # print one line to stdout and exit (also accepts -s -1)
```

Default output is `~/Library/Application Support/dwm/status`, exactly the path
read by `dwm/macos/README.md`'s backend every half second (first 4 KiB, UTF-8).
Parent directories are created as needed. Each update writes a unique mode-0600
temporary file in the same directory, closes it, and renames it over `status`.
Readers see a whole old or new line, never a partial update. This is atomic
visibility, not crash-durable storage: there is no per-update `fsync`. Stdout
modes do not create directories or touch the status file. Lines larger than
4096 bytes are rejected rather than truncating UTF-8.

Run one producer per status file. Stop with Ctrl-C, SIGTERM, or SIGHUP; SIGUSR1
requests an early update. Signals are handled between samples, including during
the interruptible wait. SIGPIPE is converted to a reported stdout write error.
Output/setup failures are reported on stderr and exit nonzero; unavailable
metrics display `n/a` and are retried on the next update. The last status file is
left on exit (and can be removed manually). SIGKILL or a crash can leave a
`status.XXXXXX` temporary file. There is no daemonization or automatic login
startup; launch it from your session or your own LaunchAgent if desired.

## Compile-time configuration

Edit **this directory's `config.h`**, then rebuild; the Linux `../config.h` is
not used. Configure the positive update interval in milliseconds, unknown text,
disk path, home-relative output path, date format, timezone names and status
format. `status_format` takes eight Objective-C `%@` fields in this order: CPU,
RAM, disk used, battery, RX, TX, Berlin time, Kolkata time. Dates use Foundation's
Unicode date patterns, not `strftime`. Defaults are `Europe/Berlin` and
`Asia/Kolkata`, with DST applied by the OS and a fixed POSIX locale.

Set `network_interface = @"en0"` (or another BSD interface name) to pin an
interface. The empty default queries SystemConfiguration's primary IPv4
interface, falling back to primary IPv6 when no IPv4 primary exists. Selection
is refreshed each sample, so connection changes are picked up automatically.
There is no arbitrary fallback to loopback or summation across interfaces. Set
the interface explicitly for VPNs or a secondary link whose traffic you want.

## Metrics and limits

- **CPU:** public Mach `host_statistics` CPU tick deltas, normalized to 0–100%
  across all CPUs; user + system + nice count as busy. The initial sample is
  `n/a`, including `-1`, because no measurement interval has elapsed. Tick
  counters wrap modulo 32 bits; normal interval wrap is handled.
- **RAM:** Mach `host_statistics64` active + wired + physically compressed pages,
  multiplied by the actual host page size, in GiB. This is an approximation,
  not Activity Monitor's “Memory Used” or memory pressure; inactive/file-cache
  pages and swap are not included.
- **Disk:** `statvfs`, used blocks (`f_blocks - f_bfree`) in GiB for the configured
  mount, default `/`. APFS shared containers, snapshots and purgeable space make
  this differ from Finder's available space. Use `/System/Volumes/Data` if that
  volume is the one you want to monitor; usage is not summed across volumes.
- **Battery:** IOKit Power Sources, the first present internal battery's current
  capacity / maximum capacity plus charging, AC or battery state. Desktops,
  missing batteries and unavailable readings show `n/a`; external UPS units and
  battery health/time-remaining estimates are not included.
- **Network:** public routing `sysctl` (`NET_RT_IFLIST2`) 64-bit interface byte
  counters, divided by elapsed monotonic time, shown as KiB/s RX/TX. The initial
  sample, an interface switch, counter reset, missing/down interface or failed
  query shows `n/a` and establishes a fresh baseline. It is interface traffic,
  not per-process or application payload throughput. Auto selection is not a
  per-destination route lookup and may not select a split-tunnel VPN. Suspend
  and long scheduling gaps can affect averages. Sampling time is added to the
  configured delay; throughput uses actual elapsed time, not that delay.

## Verification

```sh
make -C slstatus/macos test CFLAGS='-O2 -Wall -Wextra -Werror'
make -C slstatus test-native             # same portable tests
```

These run on Linux or macOS and cover CPU deltas/wrap, 64-bit network rates and
counter resets, atomic file replacement (including concurrent readers), file
permissions, empty output, failed file creation/renames and temporary-file cleanup.
They do not simulate the macOS APIs. On a Mac, additionally run:

```sh
make -C slstatus/macos CFLAGS='-O2 -Wall -Wextra -Werror'
slstatus/macos/slstatus-macos -1
slstatus/macos/slstatus-macos -s
```

The second continuous sample should show CPU/network rates when available.
Check file output with dwm running, stop/refresh signals, interface switching,
battery/AC changes and sleep/wake on real hardware. No native macOS build or
hardware smoke test can be performed by the portable test target.
