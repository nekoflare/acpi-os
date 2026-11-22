# Recipe ideas

Candidate packages for `acpi-kernel/recipes`. Pick by ID and I'll add them.

## Tier 1 — quick wins

- [x] **R1 `busybox` (full default applet set)** — added at `recipes/busybox/recipe`. Uses BusyBox `defconfig` with static/installer build options; no applets pruned. Packaged as `usr/bin/busybox`; the Xorg image installs it as `/bin/busybox`.
- [ ] **R2 `procps-ng`** — `ps`, `free`, `uptime`, `vmstat`, `pgrep`, `pkill`, `watch`. Kernel already has `/proc`, `sysinfo` (99), and `kill`. `top` may need `select`.
- [ ] **R3 `ncdu` (1.x)** — curses disk-usage browser for the writable ext4 volume. Uses `stat`, `getdents`, `statfs`, all supported.
- [ ] **R4 `jq`** — JSON processor, no deps, useful for scripts and boot-check output.
- [ ] **R5 `mandoc`** — man-page renderer; `less` already exists. Pair with `man-pages`.

## Tier 2 — desktop / X11

- [ ] **R6 `xprop`** — core-protocol property inspector; invaluable for the guest X server.
- [ ] **R7 `xwininfo`** — window tree/geometry inspector.
- [ ] **R8 `xev`** — event dump; great for input debugging.
- [ ] **R9 `xlsfonts` + `xlsatoms`** — font/atom queries; tiny.
- [ ] **R10 `x11perf`** — core X11 benchmark; directly targets the desktop-lag work.
- [ ] **R11 `dmenu`** — launcher for dwm. Deps already present (`libx11`, `libxft`, `fontconfig`, `freetype`). May need keyboard grabs.
- [ ] **R12 `slstatus`** — clock/CPU/memory status for dwm; simple `libx11` build, reads `/proc`.
- [ ] **R13 `libxaw`** — unlocks classic X apps; deps `libxmu`, `libxt`, `libx11`.
- [ ] **R14 `xclock` / `xcalc` / `xmessage`** — after `libxaw`; stress arcs, lines, text, and fonts. `xlogo` needs only `libx11`.
- [ ] **R15 `xwd`** — in-guest screenshots; `libx11` only.
- [ ] **R16 `netpbm`** — convert `xwd`/PPM to PNG; also useful for boot-check artifacts.
- [ ] **R17 `xdotool`** — scripted X input for boot checks; `libxtst` already packaged.
- [ ] **R18 `xclip`** — clipboard support for st.

## Tier 3 — dev / tooling

- [ ] **R19 `tcc`** — tiny C compiler; big demo value and a VFS/`mmap` stress test. Needs musl headers + `crt1.o` + `libc.a` bundled in the guest.
- [ ] **R20 `m4`** — small; missing prerequisite for autoconf-style builds.
- [ ] **R21 `ninja` + `meson`** — meson runs on the packaged Python; makes the guest a real build environment.
- [ ] **R22 `tig`** — curses git browser; `git` already works.
- [x] **R23 `sqlite3`** — added at `recipes/sqlite3/recipe`; `/bin/sqlite3-test` exercises it. Needed kernel `fcntl` record locks, `pwrite64`, and `ftruncate` on regular files. Shared-memory WAL still needs `MAP_SHARED` file mappings.

## Tier 4 — fun / showpiece

- [ ] **R24 `nethack`** or **`bsdgames`** — classic ncurses stress test: `TIOCGWINSZ`, file I/O, signals.
- [ ] **R25 `timg`** or **`catimg`** — terminal image viewer using the existing `libjpeg`/`libpng`/`giflib`; shows off 24-bit SGR.
- [x] **R26 `cmatrix` / `nyancat`** — added at `recipes/cmatrix/recipe` and `recipes/nyancat/recipe`.

## Tier 5 — data / polish

- [ ] **R27 `terminus-font`** — excellent terminal font; small; works with fontconfig.
- [ ] **R28 `man-pages`** — pair with `mandoc`.
- [ ] **R29 `tzdata`** — only if `date`/`TZ` should show local time.

## Kernel prerequisites that unlock recipes

- **`select` (23)** — missing; many ncurses/event-loop apps assume it. A thin wrapper over the existing `poll` would pay off quickly.
- **`utimensat` (280) / `utimes` (235)** — needed by `touch` and `cp -p`.
- [x] **`symlink` (88) / `symlinkat` (266)** — implemented: ext4 `S_IFLNK` inodes (fast ≤60 B in `i_block`, slow via extents), `VNTY=10` nodes, `VWAT` follows with a 40-link `ELOOP` limit, `lstat`/`stat`/`readlink`/`unlink`/`rename` all handle links.
- [ ] **`link` (86) / `linkat` (265)** — hard links still missing; needed by some build tools.
- **`ftruncate` (77) on regular files** — currently memfd-oriented; needed by SQLite, `cp` overwrite semantics, and archive extraction.
- **PTY ioctls + job control** — prerequisite for `tmux`, `screen`, and full `xterm`; `st` already avoids this.
