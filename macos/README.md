# Native macOS backends

All native macOS implementation code and configuration lives here, separate
from the original X11 tools at the repository root:

- [`dwm/`](dwm/README.md): native window manager and bar.
- [`slstatus/`](slstatus/README.md): native metrics producer for that bar.

Requires macOS 11+ and Xcode Command Line Tools (`xcode-select --install`).
From the repository root:

```sh
make -C macos/dwm
make -C macos/slstatus
make -C macos/dwm install PREFIX="$HOME/.local"
make -C macos/slstatus install PREFIX="$HOME/.local"
```

On macOS, the original `make -C dwm` and `make -C slstatus` entry points
delegate here as well. On Linux they still build the original X11 versions.
Spotlight remains dwm's launcher; dmenu is unchanged.

Run `dwm-macos` and `slstatus-macos` from your installation's `bin` directory
in separate terminals. See each backend's README for permissions, configuration,
shortcuts and limitations. slstatus publishes to
`~/Library/Application Support/dwm/status`, which dwm reads automatically.

Portable tests (also runnable on Linux):

```sh
make -C macos/dwm test
make -C macos/slstatus test
```
