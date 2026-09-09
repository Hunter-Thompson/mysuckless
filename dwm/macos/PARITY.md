# Source correspondence and parity

This is a function-level inventory, **not a claim that every original line has a
native equivalent or that native behavior has been runtime-tested**. “Implemented”
below means a source implementation exists. Only the portable C model has been
executed locally. X11 protocols are not translated into fake macOS protocols.

## Configured behavior

| Feature | Native correspondence | Difference / limitation |
| --- | --- | --- |
| Five tags, multitag, view history | `dwm_tags`, `action:value:`, `arrange` | Per-window minimize instead of offscreen XMoveWindow; apps may refuse |
| Rules | `rules[]`, `sync` | Bundle ID/title, not X class/instance; no transient-parent tag inheritance |
| Tile, master count/factor, zoom | `dwm_tile`, `action:value:` | Apps constrain final sizes; logical-point rounding |
| Floating and monocle | `arrange`, `action:value:` | No X11 restack; AX raise controls selected window only |
| Focus stack/history/sloppy focus | `focus:`, `sync`, `event:type:` | AX activation/raise is asynchronous; cannot override OS focus ownership |
| Monitor focus, transfer, hotplug | `monitorAt:`, `screensChanged:`, `action:value:` | NSScreen order; no Spaces control |
| Mouse move, resize, snap, float | `event:type:` | Public AX geometry requests; no custom resize cursor or pointer warping |
| All effective configured key actions | `keys[]`, `action:value:` | Physical macOS key codes; protected keys/Secure Input unavailable |
| All configured bar/client buttons | `Bar click:`, `event:type:` | No X root window button context |
| Close client | AX close-button press | Does not forcibly kill an uncooperative client/application |
| Spawn and launcher | `NSTask`, Spotlight, Terminal | dmenu/slstatus not ported; shell configuration separate |
| Status | Bounded UTF-8 status file | Not X root WM_NAME; half-second updates |
| Bar height patch | `barHeight = 25` | Logical points, not physical pixels |
| Fullscreen patch | saved geometry + full-display resize | Simulated; no native Space; OS may clamp; bar hidden while simulated fullscreen visible |
| Fullscreen focus lock | `focus:` | Applies to dwm-initiated focus only |
| Fonts/colors/tag occupancy/title | AppKit `Bar` | Monospaced 14-point native font, native clipping; no Xft fontconfig syntax |
| Borders/urgency/size hints | Not directly reproduced | No public border replacement or ICCCM urgency/aspect/increment protocol; apps enforce constraints |
| Lifecycle/error handling | AX observers, reconciliation, ARC, signals, flock | No takeover of WindowServer; crash recovery not persistent |

## dwm.c function inventory

Each function declared in the original `dwm.c` appears below. Related protocol
functions share rows; their native equivalents are not line-by-line translations.

| Original function(s) | Native correspondence / explicit limitation |
| --- | --- |
| `applyrules` | `sync` applies bundle/title rules; no X instance matching or transient-parent inheritance |
| `applysizehints`, `updatesizehints` | AX settable-size check and application-enforced bounds; no ICCCM aspect/increment API |
| `arrange`, `arrangemon` | `arrange` |
| `attach`, `detach` | Monitor `clients` array insertion/removal |
| `attachstack`, `detachstack` | Monitor `history` array insertion/removal |
| `buttonpress` | `event:type:` and `Bar click:` |
| `checkotherwm` | Per-user `flock`; does not detect unrelated native managers |
| `cleanup`, `cleanupmon` | `applicationWillTerminate:`, ARC ownership and panel close |
| `clientmessage` | No EWMH message bus; AX notifications/state reads cover focus and native fullscreen observation, not EWMH commands |
| `configure`, `configurerequest`, `configurenotify` | `resize:frame:`, `screensChanged:`; native applications keep geometry authority, no synthetic ConfigureNotify |
| `createmon` | `Monitor init`, `screensChanged:` |
| `destroynotify`, `unmapnotify`, `unmanage` | AX observer and `sync` remove vanished/terminated clients |
| `dirtomon` | `dwm_monitor` |
| `drawbar`, `drawbars`, `expose` | `Bar drawRect:`, `setNeedsDisplay:` |
| `enternotify`, `motionnotify` | Coalesced pointer hit testing in `event:type:`, AX focus on client entry |
| `focus`, `focusin`, `setfocus` | `focus:`, `sync` observe active app's focused AX window |
| `focusmon`, `focusstack` | Corresponding `action:value:` branches |
| `getatomprop` | No X atoms; typed AX attribute access in `attribute` |
| `getrootptr` | `CGEventGetLocation` |
| `getstate`, `setclientstate` | AX minimized/native fullscreen reads and per-client state; no ICCCM state property |
| `gettextprop` | `attribute`, NSString |
| `grabbuttons`, `grabkeys`, `keypress` | CoreGraphics event tap and `keys[]`; no exclusive X grabs |
| `incnmaster` | `action:value:` |
| `killclient` | AX close-button press; intentionally no process-wide kill fallback |
| `manage`, `maprequest`, `scan` | `sync` discovers AX windows of regular GUI apps |
| `mappingnotify`, `updatenumlockmask` | Modifier filtering ignores Caps/Num Lock; physical virtual-key map, no X keymap |
| `monocle` | `arrange` gives every visible tiled client the work area |
| `movemouse`, `resizemouse` | `event:type:` drag handling |
| `nexttiled` | `visible:tiled:` |
| `pop`, `zoom` | `action:value:` changes client order and focuses promoted client |
| `propertynotify` | `observed`, `sync` |
| `quit` | NSApplication termination |
| `recttomon` | `monitorAt:` uses window center / pointer, not maximum intersection area |
| `resize`, `resizeclient` | `resize:frame:` sends AX size and position requests |
| `restack` | `focus:` uses AXRaise; exact below-bar/client stacking unavailable |
| `run` | AppKit main run loop |
| `sendevent` | No X ClientMessage transport; AX actions instead |
| `sendmon`, `tagmon` | `action:value:` monitor transfer and mouse-drop transfer |
| `setfullscreen`, `togglefullscr` | `action:value:`, saved geometry and floating state; no native Space switching |
| `setlayout`, `setmfact` | `action:value:` |
| `setup` | `applicationDidFinishLaunching:` |
| `seturgent`, `updatewmhints` | No portable AX urgency/neverfocus equivalent; urgency indication not implemented |
| `showhide` | `arrange` minimizes/restores individual windows, remembering ownership |
| `sigchld` | NSTask owns child-process lifecycle; SIGINT/SIGTERM use dispatch sources |
| `spawn` | `spawn:` with trusted shell command |
| `tag`, `toggletag`, `toggleview`, `view` | `action:value:`, `dwm_tags` |
| `tile` | Shared C `dwm_tile` |
| `togglebar`, `togglefloating` | `action:value:` |
| `unfocus` | Selection/history updates; no X border redraw or root focus |
| `updatebarpos`, `updatebars`, `updategeom` | `screensChanged:`, `arrange` |
| `updateclientlist` | Internal arrays; no EWMH root client list |
| `updatestatus` | `tick:` reads bounded UTF-8 status file |
| `updatetitle` | `sync` reads AX title |
| `updatewindowtype` | AX subrole/non-resizable check and native fullscreen observation; no EWMH type taxonomy |
| `wintoclient` | AX element equality search in `sync` / `clientAt:` |
| `wintomon` | `Client.monitor`, `monitorAt:` |
| `xerror`, `xerrordummy`, `xerrorstart` | AX error returns and rate-limited refusal logging; no X error handler |
| `main` | AppKit accessory application entry point |

## Drawing, utilities and test program

| Original function(s) | Native correspondence / explicit limitation |
| --- | --- |
| `utf8decodebyte`, `utf8validate`, `utf8decode` | Foundation NSString decoding; invalid status UTF-8 displays fallback |
| `drw_create`, `drw_resize`, `drw_free` | NSPanel/NSView lifecycle and ARC |
| `xfont_create`, `xfont_free`, `drw_fontset_create`, `drw_fontset_free`, `drw_setfontset` | NSFont and AppKit text fallback, not Xft patterns |
| `drw_clr_create`, `drw_scm_create`, `drw_setscheme` | NSColor and attributed text dictionaries |
| `drw_rect` | NSRectFill / NSFrameRect |
| `drw_text`, `drw_fontset_getwidth`, `drw_font_getexts` | NSString draw/measure methods |
| `drw_map` | AppKit view invalidation/compositing |
| `drw_cur_create`, `drw_cur_free` | System cursor retained; no dwm-specific cursor replacement |
| `ecalloc`, `die` | Objective-C allocation/ARC; startup diagnostics and termination |
| `transient.c` test `main` | X11-only demonstration retained, not a native transient-window test |

Original headers, X11 manual and patch files remain historical X11 artifacts.
Native setup and validation instructions are in README.md; there is no claim that
X11 protocol definitions, atom lists, event union members or their individual
lines can operate on macOS native windows.
