# Porting Firefox to the ASL kernel

Goal: Firefox ESR opens `https://example.com/` in a window on the X.Org
desktop, is usable for ordinary browsing, and is built from our own recipes.
Chromium comes after Firefox (phase Z).

The work is split into small steps. Each step should leave the kernel booting
and `make -C acpi-kernel check` passing. A step is ticked only once a guest
test proves that it works. Browser tests live in `userspace/firefox-tests/`
and run with `scripts/run-guest-test.sh <name>` (the harness from
`JAVA_PORT.md`, which also has to search that directory).

Strategy: **probe first, then build.** Alpine Linux is musl-based, so its
prebuilt `firefox-esr` and dependency packages run against our musl. Running
them first shows which kernel features are missing within days instead of
after weeks of recipe work. The kernel fixes from the probe are then reused
unchanged by our own build.

## Starting point

### What already exists and can be reused

Kernel (see `JAVA_PORT.md` and `NETPLAN.md`):

- **Dynamic linking:** PIE, `PT_INTERP`, shared musl 1.2.5 (`musl-runtime`,
  with `libstdc++.so.6`, `libgcc_s.so.1` and `libatomic.so.1`), and
  `dlopen`. Also `/proc/<pid>/exe` and `$ORIGIN`.
- **Memory:** a 128 TiB user space, lazy `MAP_NORESERVE` memory, RWX and
  `PROT_EXEC` (SpiderMonkey's JIT works like HotSpot's), `MAP_FIXED`,
  partial `munmap` and `mprotect`, `madvise`, `mremap`, and a vDSO
  `clock_gettime`.
- **Shared memory between processes:** `memfd_create` with seals,
  `MAP_SHARED` of memfds, and `SCM_RIGHTS` over AF_UNIX streams. Firefox
  uses this for its shared memory, and it does not need `/dev/shm`.
- **Signals:** `SA_SIGINFO`, fault-to-signal for `SIGSEGV`, `SIGBUS` and the
  others (the wasm and JIT guard pages need it), `sigaltstack`, and
  `tgkill`.
- **Threads and processes:** clone threads, futex, `sched_getaffinity` and
  `getcpu`. `fork` and `execve` work, and musl's `posix_spawn` vfork path
  works for single-threaded processes.
- **I/O:** `epoll`, `ppoll`, `eventfd`, `pipe2`, socketpair (AF_UNIX
  `SOCK_STREAM` only), and `fcntl` record locks (`F_SETLK`, used by SQLite
  and the profile lock).
- **Network:** a full IPv4 TCP/UDP stack, DNS through musl, OpenSSL 3 with
  the CA bundle, and curl. Firefox brings its own NSS, but uses the same
  sockets.
- **Graphics:** X.Org on the framebuffer, and Mesa 26 llvmpipe with Xlib GLX
  (`libGL.so.1`, OpenGL 4.6).
- **Limits:** 1024 descriptors per process, and 8 GiB of guest RAM in
  `run-xorg-uefi`.

Userspace recipes:

- **Already shared:** libX11, libxcb (with libxcb-shm), libXau, libXdmcp,
  libXext, libXrender, libXfixes, libXcursor, libXi, libXrandr, Mesa libGL,
  alsa-lib, OpenSSL, zlib (`zlib-shared`) and curl.
- **Static only, so a `*-shared` recipe is needed:** freetype, fontconfig,
  expat, libpng, libjpeg-turbo, pixman, pcre2, libffi (PIC, but static),
  libXinerama, libXft, libXtst, sqlite3 and python.
- **Data:** DejaVu fonts, the CA bundle, and the xkb keymap.
- **Browser today:** NetSurf (framebuffer frontend on xcb). It stays as the
  lightweight browser.

Build container (Jinx, Debian snapshot 2025-11-01): `rustc`, `cargo`,
`clang`, `lld`, `cmake`, `meson`, `ninja`, `perl` and `python3` are already
used as imagedeps. Debian also packages `cbindgen`, `nodejs`, `nasm` and
`libclang-dev`. The cross toolchain is bootlin's musl GCC (`musl-cxx`,
`/opt/acpi-musl-cxx`, triple `x86_64-buildroot-linux-musl`). The host has 12
threads, 23 GiB of RAM plus 23 GiB of swap, and 380 GB free.

### What is missing

Kernel. The probe confirms or rejects each item, and any it does not need
are dropped:

| Gap | Who needs it | Today |
|---|---|---|
| Writable `MAP_SHARED` file mappings | SQLite WAL `-shm` files (`places.sqlite`, `cookies.sqlite`, ...) | `ENODEV` |
| `prctl` (157): `PR_SET_NAME`, `PR_SET_DUMPABLE`, `PR_SET_PDEATHSIG`, `PR_GET_SECCOMP`, `PR_SET_NO_NEW_PRIVS` | Firefox, GLib | `ENOSYS` |
| Fork of a big multithreaded process (copying, no COW) | content-process launch from the parent | slow and uses memory |
| `/proc/self/task/<tid>/comm` and `/proc/self/task`, `/proc/self/fd`, `/proc/self/status` fields | musl `pthread_setname_np`, Firefox's fd cleanup before exec, memory reporters | partly missing |
| `getrusage` (98), `times` (100), `sched_setaffinity` (203), `setpriority`/`getpriority` (140/141), `sched_get_priority_*` (146/147), `sched_setscheduler` (144) | thread priorities, telemetry, profiler | `ENOSYS` |
| `inotify_init1`/`inotify_add_watch` (294/254) | GIO file monitors, Firefox's file watcher | `ENOSYS` (GLib falls back to polling) |
| `utimensat` (280), `fallocate` (285), `fadvise64` (221) | profile files, cache2, SQLite | `ENOSYS` (callers mostly fall back) |
| AF_UNIX `SOCK_SEQPACKET`/`SOCK_DGRAM` | possibly Firefox IPC or fork server; Chromium's zygote (phase Z) | `ESOCKTNOSUPPORT` |
| SysV shm (`shmget`/`shmat`/`shmdt`/`shmctl`, 29-31 and 67) | MIT-SHM in Xorg, GTK and Firefox (`nsShmImage`) | `ENOSYS`, so X falls back to `XPutImage` (slower) |
| `/dev/null`, `/dev/urandom`, `/dev/shm`, and `/dev/zero` if missing | many libraries | check |
| `waitid` (247), `close_range` (436), `pidfd_open` (434) | GLib spawn (falls back) | `ENOSYS` |
| `statx` (332) | Rust std (falls back on `ENOSYS`) | `ENOSYS` |

Userspace:

- The GTK3 stack: glib, cairo, pango, harfbuzz, fribidi, gdk-pixbuf,
  libepoxy, at-spi2-core (atk and atk-bridge), and gtk+3. The memory note
  also listed nss/nspr; Firefox bundles its own copies, so they are not
  needed.
- Shared builds of the static libraries above, plus libdbus (at-spi2-core
  needs it), libXcomposite, libXdamage, libXinerama, libXtst and
  libxkbcommon (the probe shows whether GTK3 on X11 loads it).
- GSettings schemas compiled into `/usr/share/glib-2.0/schemas`. The GTK
  file chooser aborts without them.
- The Firefox build toolchain: a Rust toolchain with the
  `x86_64-unknown-linux-musl` std, built for dynamic linking. Debian's
  `rustc` has no musl std. Also cbindgen, nodejs, libclang (for bindgen),
  and nasm.
- A Firefox recipe, a mozconfig, musl patches (take Alpine's aports
  `community/firefox-esr` patches as the reference), and a prefs file.

## Design decisions

- **Version:** the ESR that Alpine ships at probe time (read it from
  `APKINDEX`). The source build uses the same ESR, so Alpine's patches
  apply and the probe's results carry over.
- **Toolkit:** `--enable-default-toolkit=cairo-gtk3-x11-only`. No Wayland,
  since the desktop is X.Org.
- **Rendering:** software WebRender (`gfx.webrender.software=true`), shown
  through GTK and X11 with `XPutImage`. WebGL through Mesa llvmpipe GLX
  comes later (phase X). The `glxtest` probe process may stay on, because
  libGL exists.
- **Sandbox:** none. The kernel has no seccomp or namespaces. The probe uses
  `MOZ_DISABLE_CONTENT_SANDBOX=1`, `MOZ_DISABLE_RDD_SANDBOX=1`,
  `MOZ_DISABLE_SOCKET_PROCESS_SANDBOX=1` and `MOZ_DISABLE_GMP_SANDBOX=1`;
  the build uses `--disable-sandbox`.
- **Processes:** multiprocess stays on, because Firefox cannot turn it off.
  Start small, with prefs `dom.ipc.processCount=2` and
  `fission.autostart=false`, and raise them once processes are cheap
  (K3).
- **Compiler:** bootlin GCC from `musl-cxx` for C/C++ (it already builds
  OpenJDK and Mesa), and rustc for the musl target with
  `-C target-feature=-crt-static` and `musl-cxx` as the linker. Debian
  clang is used only by bindgen, with `--target` and the musl sysroot. If
  GCC hits Firefox-specific problems, switch to Debian clang with
  `--target=x86_64-linux-musl --sysroot` and `--gcc-toolchain` pointing at
  `musl-cxx`.
- **Bundled versus system libraries:** use Firefox's bundled NSS, NSPR, ICU,
  SQLite, libvpx, libwebp, dav1d, harfbuzz and zlib, which keeps the system
  dependency list to GTK, X11, freetype, fontconfig and alsa. Shared system
  libraries follow [prefer shared libraries]: every new recipe builds
  `.so` files.
- **Optional features off at first:** crash reporter, updater, tests, EME,
  the WebRTC camera, dbus (`--disable-dbus`; a11y still loads libdbus
  through at-spi), `--without-wasm-sandboxed-libraries` (no WASI SDK), and
  necko-wifi. Audio uses `--enable-audio-backends=alsa` (no sound card, so
  the null device).
- **Location:** `/usr/lib/firefox`, with `/bin/firefox` as a wrapper script
  that sets the environment, plus `defaults/pref/acpi.js` for the prefs. The
  profile lives on the persistent volume, like `/minecraft`.

## Phase P: probe with Alpine's binaries

- [x] P1. Syscall gap logger. Add a kernel switch (a boot option or a
      compile-time `Name`) that logs every `-ENOSYS` return once per
      (process name, syscall number). It should also log the unsupported
      `prctl`/`ioctl`/`fcntl`/`socket` sub-codes. Without it, the probe's
      failures stay silent. Test: a guest program that calls three unknown
      syscalls sees three log lines, each printed once.
      Done: `NSYC` in `kernel/kernel.asl`, called at the end of `SYSC` for
      negative results while `NSYL` is One (the default; there are no boot
      options, so it is a compile-time `Name`). It prints to the serial port
      only, as `nosys: <comm> pid=<n> nr=<n> [sub=0x<hex>] err=<errno>`.
      Logged cases: any `-ENOSYS` (sub-code is the option for `prctl`),
      `ioctl`/`fcntl` with `ENOTTY`/`EINVAL` (sub-code is the request),
      `socket`/`socketpair` with `EINVAL` or `EPROTONOSUPPORT`..`EAFNOSUPPORT`
      (sub-code is `domain << 32 | type`), and `setsockopt`/`getsockopt`
      with `ENOPROTOOPT` (sub-code is `level << 32 | optname`). Duplicates
      are dropped through a 1024-slot hash table (`NSYT`); once it is full,
      new keys print every time. Test `firefox-tests/nosys-log` makes each
      call twice and uses the new `// expect-once:` runner directive. Seen
      in older tests: musl's `brk` (nr 12) fallback, which is harmless.
- [x] P2. `scripts/fetch-alpine-firefox.sh`. It downloads the current stable
      Alpine `APKINDEX` for `main` and `community`, then resolves
      `firefox-esr`'s dependencies transitively (`D:` and `so:` provides). It
      downloads the `.apk` files, checks each one against the index checksum,
      and unpacks them into `target/alpine-firefox/root`. It skips `musl`
      itself, because our `musl-runtime` is the same 1.2.5. If Alpine's is
      newer, fall back to shipping Alpine's `ld-musl` under `/opt/alpine`.
      It prints the package count and the size.
      Done: `scripts/fetch-alpine-firefox.py` (Python, since the dependency
      resolution is too awkward in sh). It reads the branch from
      `latest-stable` (override with `ALPINE_BRANCH`; mirror with
      `ALPINE_MIRROR`), resolves `D:` against package names and `P:`
      provides (highest `k:` priority wins, `/bin/sh` maps to `cmd:sh`), and
      checks each `.apk` twice: the index `C:` checksum (SHA-1 of the
      control segment) and the `.PKGINFO` `datahash` (SHA-256 of the data
      segment). A corrupt cached `.apk` is downloaded again. Packages are
      cached in `target/alpine-firefox/apk/<branch>/`, the tree is rebuilt
      from scratch in `target/alpine-firefox/root` each run, and
      `target/alpine-firefox/manifest.txt` lists the packages and versions.
      Result on 2026-11-25: Alpine v3.24, `firefox-esr` 153.7.0-r0,
      117 packages, 153 MiB downloaded, 412.5 MiB unpacked (libxul alone is
      152 MiB). A cached rerun takes about 4 s.
      musl: Alpine has 1.2.6, so the script keeps `musl` in the tree. But
      1.2.6 adds only four symbols (`__getauxval`, `posix_getdents`,
      `pthread_mutexattr_setprioceiling`, `renameat2`), and no ELF file in the
      tree imports any of them. P3 can therefore run everything with our
      `/lib/ld-musl-x86_64.so.1` (1.2.5), which is the binaries' `PT_INTERP`
      anyway, and ignore Alpine's copy. Only if the probe hits a musl
      behaviour difference does P3 need Alpine's loader (by `patchelf
      --set-interpreter`, because Firefox re-executes its own binary for
      child processes).
      Notable packages it pulls in: busybox (for `/bin/sh`), bubblewrap,
      libseccomp, scudo-malloc, gtk+3.0, the wayland client libraries,
      ffmpeg7 codecs, nss/nspr, icu, libgcc and libstdc++.
- [x] P3. Pack the tree into the desktop image under `/opt/alpine` (and into
      a test disk via `// disk-dir:`). Add `/bin/firefox-probe`, which sets
      `LD_LIBRARY_PATH`, the sandbox variables, `NO_AT_BRIDGE=1`,
      `GDK_BACKEND=x11`, `MOZ_ENABLE_WAYLAND=0`,
      `MOZ_CRASHREPORTER_DISABLE=1` and `XDG_*` directories on the
      persistent volume.
      Test `firefox-version`: `firefox --version` prints the ESR version.
      This step loads libxul and runs static constructors, but starts no
      child processes.
      Done: the desktop image gets `/opt/alpine` (`XORG_ALPINE_FILES` in the
      Makefile, fetched through `$(XORG_ALPINE)/.fetched`) and
      `/bin/firefox-probe` (`config/firefox-probe`). The wrapper also sets
      `MOZ_DISABLE_UTILITY_SANDBOX`/`MOZ_DISABLE_GPU_SANDBOX`, `HOME` and
      `XDG_*` under `/firefox` (`FIREFOX_DIR` overrides it),
      `XDG_RUNTIME_DIR=/tmp/firefox-runtime`, and the GIO, GSettings and
      fontconfig paths into `/opt/alpine`. It runs Firefox with our musl
      1.2.5 loader. The fetch script now turns absolute symbolic links
      (`bin/sh -> /bin/busybox`, `firefox-esr-bin`) into relative ones so
      they stay inside `/opt/alpine`. The runner's `// disk-file:` keeps the
      source file's mode, so the wrapper stays executable.
      Test `firefox-tests/firefox-version` passes: `Mozilla Firefox
      153.7.0esr` in about 2.4 s; the expected version comes from
      `application.ini`. Gaps the logger found on the way (inputs for phase K):
      - `prctl(PR_SET_NAME)` (`sub=0xf`) returns ENOSYS. It is cheap to add
        and `/proc/<pid>/comm` should follow it.
      - `prctl(PR_SET_SECCOMP)` (`sub=0x16`) returns ENOSYS, which is
        expected; it is harmless with the sandboxes off.
      - `readahead` (nr 187) returns ENOSYS, which is harmless.
      - `fcntl(F_DUPFD)` on the implicit console (an fd with no file behind
        it) returns ENOSYS (`nr=72 sub=0x0`). It should duplicate it, or
        return EBADF.
      - `brk` (nr 12) returns ENOSYS; musl falls back, as everywhere.
      - `ioctl(TIOCGWINSZ)` on a pipe returns ENOTTY, which is correct.
      The logger now always prints the `ioctl`/`fcntl` sub-code, even 0.
- [ ] P4. Headless: `firefox --headless --screenshot /tmp/s.png
      http://10.0.2.2:8000/test.html` against the runner's `// http-server`.
      This exercises child-process launch, IPC, the JS JIT, layout, software
      WebRender, fonts and networking, all without X. Test
      `firefox-headless` checks that the PNG exists and that its size and a
      few pixels match. Record every P1 log line in the "Probe results"
      section below.
- [ ] P5. On Xvfb: open the same page in a window, save the screen with
      GetImage (as the `minecraft` test does), and check the pixels. Then on
      the desktop: `firefox-probe https://example.com/` in `st`.

The probe binaries are never committed and never become the shipped
browser. Phase B replaces them.

## Phase K: kernel work

The order follows need. Each item names the probe symptom it fixes. Items
the probe shows are unnecessary are struck rather than built.

- [ ] K1. Cheap syscalls: `prctl` with the codes in the table (names
      stored in the task for `/proc/<pid>/task/<tid>/comm`; others accepted
      or `EINVAL`), `getrusage`, `times`, `get/setpriority`,
      `sched_setaffinity` (accept masks that contain an online CPU),
      `sched_get_priority_min/max`, `sched_setscheduler`/`sched_getparam`
      (`SCHED_OTHER` only), `utimensat`, `fadvise64` (no-op), `fallocate`
      (extend with zeros, mode 0 only), and `close_range`. Test
      `fx-syscalls`.
- [ ] K2. procfs: `/proc/self/task/` listing, `task/<tid>/comm` and `stat`
      (read and write), `/proc/self/fd/` listing (readlink already?),
      `/proc/self/status` with `VmRSS`, `VmSize`, `Threads` and
      `SigBlk`, and `/proc/self/statm`. Test `fx-procfs`.
- [ ] K3. Cheap process creation from a multithreaded parent. Choose one,
      after measuring the probe's content-process launch time:
      (a) copy-on-write fork, which helps everything; or (b) real
      `CLONE_VM | CLONE_VFORK` for a thread of a multithreaded process,
      suspending only the calling thread, so musl `posix_spawn` never
      copies. (b) is smaller and is what Firefox's launcher and GLib use.
      Check whether this Firefox launches through its fork server, which
      forks from a small process and makes this matter less. Test: spawn
      `/bin/true` 100 times from a process with 30 threads and a 1 GiB
      heap, then compare the time.
- [ ] K4. Writable `MAP_SHARED` file mappings on ext4 and the initramfs:
      one set of pages per vnode, shared by every mapping (reusing
      memfd's `MFPG` page lists), written back on `msync`, `munmap`, the
      last close, and `fsync`. `read`/`write` on a mapped vnode have to see
      the shared pages. Test `fx-mmap-shared`: two processes share a file
      mapping, plus SQLite in WAL mode with two connections (the `sqlite3`
      recipe can run it).
- [ ] K5. `/dev` gaps found by the probe: `/dev/null`, `/dev/zero`,
      `/dev/urandom`/`random` (RDRAND, like `getrandom`), and `/dev/shm` as
      a writable directory if some library insists on it.
- [ ] K6. inotify stub: `inotify_init1` returns a descriptor that never
      becomes readable, and `inotify_add_watch` returns a watch number.
      This is better than `ENOSYS` only if some caller treats that as fatal.
      Real events come later, if ever.
- [x] K7. AF_UNIX `SOCK_SEQPACKET` (and `SOCK_DGRAM` socketpair). Done on
      2026-11-25, pulled ahead because a plain `firefox-probe` segfaulted:
      every start except `--version` crashed after
      `socketpair(AF_UNIX, SOCK_SEQPACKET, 0)` failed with
      `EPROTONOSUPPORT`. The crash is libxul 0x4a9e61a,
      `MOZ_CRASH(can't create crash reporter socketpair())`: Breakpad's
      channel is socketpair, `SO_PASSCRED`, then `O_NONBLOCK`. The Rust
      crash helper also uses `SOCK_SEQPACKET`, and libxul has five more
      sites. (My first reading of the crash site was wrong: I searched for
      the wrong store encoding.)
      Implementation (`kernel/kernel.asl`):
      - `SKTY` holds the endpoint type. For 2/5, each message sits in the
        receive ring behind an 8-byte header (length, sender pid).
      - `MSGS` sends all or nothing (blocks or `EAGAIN` until the whole
        message fits; `EMSGSIZE` above 128 KiB).
      - `MSGR` takes exactly one message. It drops what does not fit and
        reports `MSG_TRUNC` in `msg_flags`. It supports the `MSG_PEEK` and
        `MSG_TRUNC` flags.
      - `read`/`write`/`send`/`recv`/`sendmsg`/`recvmsg`/`readv`/`writev`
        all route there (hooks in `SKRW`, `SKRV`, `SYWV`).
      - `socket(AF_UNIX, SOCK_SEQPACKET)` works with
        `bind`/`listen`/`connect`/`accept`. A type mismatch gives
        `EPROTOTYPE`.
      - SCM_RIGHTS may now carry sockets. The crash helper passes its
        connectors this way. Without cycle collection, a socket queued
        inside its own peer and never received leaks until reboot.
      - An SCM_RIGHTS message with zero descriptors is accepted, as on
        Linux. Rust's nix sends one, and the crash helper's rendezvous
        failed on `EINVAL`.
      - AF_UNIX socket options (`SKOP`):
        - setsockopt accepts `SO_PASSCRED`, `SO_REUSEADDR`, `SO_SNDBUF` and
          `SO_RCVBUF`; the buffer sizes are ignored because the ring is fixed.
        - getsockopt answers `SO_TYPE`, `SO_ERROR`, `SO_SNDBUF`,
          `SO_RCVBUF`, `SO_PASSCRED`, `SO_PEERCRED` (the creator's pid, uid
          and gid 0; `SKOW`), `SO_ACCEPTCONN`, `SO_PROTOCOL` and `SO_DOMAIN`.
        - With `SO_PASSCRED` set, `recvmsg` on a message socket appends
          `SCM_CREDENTIALS`.
        - AF_UNIX `shutdown` is still ENOSYS.
      Test `firefox-tests/unix-seqpacket`.
      Fixed on the way to a running browser (test `firefox-tests/firefox-gaps`):
      - Minimal `prctl` (`SYPC`). `PR_SET_NAME` is accepted but not stored
        yet (K1). `PR_GET_NAME` returns the process name.
        `PR_SET_PTRACER`, `PDEATHSIG`, `DUMPABLE` and `NO_NEW_PRIVS` are
        accepted. `PR_SET_SECCOMP` and `PR_SET_VMA` return `EINVAL`, as on a
        kernel built without them. Unknown options stay ENOSYS so the logger
        reports them.
      - `getrlimit`/`prlimit64` answer every resource (RLIM_INFINITY;
        `CORE`, `NICE` and `RTPRIO` are 0).
      - ICU: Firefox crashed with `ICU4CLibrary::Initialize() failed` because
        Alpine's ICU looks in `/usr/share/icu/<ver>`. `firefox-probe` now
        sets `ICU_DATA`.
      - The desktop's `/bin/sh` (our bash 5.2.37 on mlibc) segfaulted in
        `strlen(0x1)` on every `${name}` expansion, including
        `firefox-probe`'s `${icu%/}`. With `--enable-minimal-config` there
        is no `ARRAY_VARS`, so `FREE (tt)` in `parameter_brace_expand_word`
        read an uninitialized `tt`, and clang removed that path as
        unreachable. `recipes/bash/build.sh` now sets `tt` to NULL
        (revision 3). `firefox-version` runs the launcher through bash as
        `/bin/sh`; it used busybox sh before, which hid the bug.
      - `memfd_create` takes `MFD_NOEXEC_SEAL` (which adds `F_SEAL_EXEC`)
        and `MFD_EXEC`. `F_ADD_SEALS` takes `F_SEAL_EXEC`. `F_SEAL_WRITE`
        and `F_SEAL_FUTURE_WRITE` are refused because nothing enforces them;
        Firefox retries without `FUTURE_WRITE`.
      - `open("/proc/self/fd/<n>")` and `/proc/<own pid>/fd/<n>` (`PFDN` in
        `SYOP`). Firefox's parent requires it to use memfd at all (it makes
        read-only copies of shared memory this way); otherwise it falls back
        to `shm_open` and crashes with "failed to create shared memory".
        Known gap: the new descriptor *shares* fd n's open description, so
        a read-only reopen of a memfd stays writable and shares the offset.
        A real reopen needs memfd objects separate from their descriptions.
        There is still no `/proc/<pid>/fd` directory.
      - User GS base: `ARCH_SET_GS`/`ARCH_GET_GS` (plus `ARCH_GET_FS`).
        `TSGS` is copied on fork and clone, cleared on exec, and written to
        `IA32_KERNEL_GS_BASE` before each dispatch and zeroed after it. The
        ring-3 return's `swapgs` makes it live. wasm2c's segue
        (`wasm_rt_syscall_set_segue_base`) aborted without it.
      - Kernel page fault in `EPCT` (epoll_ctl). Deleting the last interest
        entry shrank the high-water mark with
        `While (Local7 && !XVWD (table + (Local7 - 1) * 32))`. ASL's `&&`
        does not short-circuit, so it read entry -1, which faults once the
        table starts a fresh mapping. This bug was there before this work.
        Other `While (a && <read>)` loops in `vfs-files.asl` read one byte
        before a buffer the same way; those reads are always mapped.
      Diagnostics added:
      - The logger prints `ioctl`/`fcntl` sub-codes even when they are 0,
        and the `setsockopt`/`getsockopt` level and name on ENOSYS.
      - `NSYV` (default Zero) logs every failing syscall, except EAGAIN,
        EINTR, ETIMEDOUT and EINPROGRESS, once per process, number,
        second argument, errno and path. Path syscalls print their path.
        Turn it on for probes.
      - `gMozCrashReason` is exported by the `firefox-esr` executable. A
        preload library with a SIGSEGV handler can `dlsym` it and print the
        MOZ_CRASH reason, because release builds print nothing.
      Result: `firefox-probe --headless --screenshot` no longer crashes. It
      runs content processes and `glxtest` and keeps going until the test
      times out (P4 continues from here). Next gaps it showed:
      - `/dev/urandom` (missing on test disks);
      - `/proc/self/task/<tid>/stat` and `/proc/self/fd` listing (K2);
      - `/sys/devices/system/cpu/...` and `/sys/bus/pci`;
      - `getresuid` (118), `getpriority` (140), `getrusage` (98) (K1);
      - `AF_NETLINK` sockets;
      - no `libGL.so.1` in the Alpine tree for glxtest;
      - ~~fontconfig has no fonts or writable cache under `/opt/alpine`~~
        (fixed below).
      Fonts (after the first desktop run drew every glyph as a hex box):
      - Alpine's `fonts.conf` only searches `/usr/share/fonts`; the image's
        DejaVu fonts are in `/fonts`. `config/firefox-fonts.conf`, installed
        as `/etc/fonts/firefox.conf`, includes Alpine's file and adds `/fonts`
        and Firefox's bundled Twemoji. `firefox-probe` points
        `FONTCONFIG_FILE` at it (and `FONTCONFIG_PATH` at Alpine's
        `etc/fonts` for its relative `conf.d`). The cache goes to
        `$XDG_CACHE_HOME/fontconfig` on the persistent volume.
      - `link`/`linkat` were ENOSYS, so fontconfig never wrote its cache
        (its lock takes a hard link and only falls back to `mkdir` on
        EPERM/ENOTSUP/EACCES). They now return EPERM, as Linux does on a
        filesystem without hard links. `fadvise64` is accepted as a no-op.
      - `FIREFOX_BIN` makes `firefox-probe` run another program in the same
        environment. Test `firefox-fonts` runs Alpine's `fc-match` through it
        and checks sans-serif, serif, monospace, system-ui and emoji, and
        that a cache was written. `firefox-gaps` checks link and fadvise.
- [ ] K8. SysV shared memory (`shmget`, `shmat`, `shmdt`, `shmctl` with
      `IPC_RMID`/`IPC_STAT`), built on memfd pages. This lets Xorg enable
      MIT-SHM, so Firefox, Mesa's Xlib GLX and Minecraft stop copying every
      frame through the socket. It is not needed for correctness; it is
      phase G work that also speeds up the existing desktop.

## Phase B: shared libraries and the GTK3 stack

Every recipe here builds shared libraries in the `*-shared` style when a
static recipe already exists. Each recipe gets a small probe test that
`dlopen`s it or runs one call, in the style of `net-crypto`.

- [ ] B1. Base shared libraries: `libffi-shared`, `pcre2-shared`,
      `expat-shared`, `libpng-shared`, `libjpeg-turbo-shared`,
      `freetype-shared` (with png and zlib; no harfbuzz yet, then rebuilt
      after B3 if GTK wants that cycle), and `fontconfig-shared`. Ship
      `/etc/fonts/fonts.conf` pointing at the DejaVu directory, and run
      `fc-cache` at image pack time.
- [ ] B2. `glib` (2.8x, meson): gio included; `-Dlibmount=disabled
      -Dselinux=disabled -Dintrospection=disabled -Dtests=false`. Ship
      `glib-compile-schemas`. Test: a GMainLoop with a timeout, a
      `GSubprocess` spawn, and a GIO file read.
- [ ] B3. Text and drawing: `pixman-shared`, `cairo` (meson: xlib, xcb, png,
      freetype, fontconfig; no gl), `harfbuzz` (with glib and freetype),
      `fribidi`, `pango` (cairo, fontconfig and freetype; Xft off). Test:
      `pango-view` (or a tiny C program) renders "Hello" to a PNG, and the
      ink extents are checked.
- [ ] B4. GTK dependencies: `gdk-pixbuf` (png and jpeg loaders built in,
      no tiff, no introspection), `libepoxy` (GLX on, EGL off),
      `libdbus` (library only, no daemon), `at-spi2-core` (includes atk
      and atk-bridge), and the missing X libraries as shared:
      `libxcomposite`, `libxdamage`, `libxinerama-shared`, `libxtst-shared`
      and `libxkbcommon` if needed.
- [ ] B5. `gtk+3` (3.24.x): the X11 backend only, no Wayland, CUPS, colord
      or introspection. Compile GSettings schemas (GTK's own plus
      `gsettings-desktop-schemas` if the file chooser asks for it). Ship
      the Adwaita theme GTK carries and `hicolor-icon-theme`. Tests: a GTK3
      window with a button and a label on Xvfb, with the pixels checked;
      then `gtk3-demo` (or `gtk3-widget-factory`) on the desktop.

## Phase F: Firefox from source

- [ ] F1. Toolchain recipe `rust-musl`: the official standalone Rust
      installer for the Firefox ESR's required version, with the
      `rust-std-x86_64-unknown-linux-musl` component. Check its SHA-256
      like the other downloads, and install it into the build container's
      sysroot as a host tool. Add imagedeps `cbindgen nodejs nasm
      libclang-dev`, and check that the cbindgen and Python versions meet
      the ESR's minimums. Test: a cdylib crate built with
      `-C target-feature=-crt-static` and `musl-cxx` as the linker, loaded
      in the guest by a C program.
- [ ] F2. `firefox` recipe: the source tarball (about 600 MB, from
      archive.mozilla.org, checked by SHA-256), Alpine's musl patches, and a
      mozconfig following the design decisions. Build with `MOZ_OBJDIR` in
      the build dir and `-j` at the Jinx parallelism. Expect hours for the
      first build and 10+ GB of build tree. The per-package cache means it
      is built once (see the Jinx notes); never touch `clang`/`musl` while
      doing this. Package with `./mach package` (or `make -C objdir/browser
      /installer`), and unpack into `/usr/lib/firefox`.
- [ ] F3. Wrapper and prefs: `/bin/firefox`, and
      `defaults/pref/acpi.js` with telemetry, studies, updates,
      safe-browsing downloads and the default-browser check off, software
      WebRender, and the process counts from the design decisions.
      Test: rerun the P3 and P4 tests against the built Firefox instead of
      the Alpine one, with the same expectations.
- [ ] F4. Desktop: add Firefox and the GTK stack to the desktop image (like
      `XORG_NETSURF_FILES`), plus a dwm or menu entry. The user then opens
      `https://example.com/` on the desktop. Delete `/opt/alpine` from the
      image after this.
- [ ] F5. Everyday browsing: Wikipedia, a page heavy on JS, typing in a
      form, tabs, scrolling, downloads to the persistent volume, and a
      restart that keeps history and cookies (this proves K4 and SQLite).
      Write down what breaks.

## Phase G: speed

- [ ] G1. Measure cold start to first paint, content-process launch, and
      scrolling frame rate on a long page. Use `KPRF` while it still exists
      (JAVA_PORT G1 removes it).
- [ ] G2. MIT-SHM (K8) for Xorg and the clients.
- [ ] G3. Whatever the profile shows. Likely candidates: futex and wakeup
      costs with Firefox's many threads (JAVA_PORT G3, per-CPU run queues
      and a futex fast path), fault cost (JAVA_PORT G2), and the poll/epoll
      paths of the IPC sockets.
- [ ] G4. Raise `dom.ipc.processCount` and turn Fission back on if memory
      and launch time allow.

## Phase X: later

- [ ] X1. WebGL through Mesa llvmpipe GLX (`webgl.force-enabled`), then
      hardware-style compositing (`gfx.webrender.all`) on llvmpipe, if it
      beats software WebRender.
- [ ] X2. Media: ffmpeg recipe (Firefox `dlopen`s `libavcodec`) for H.264
      and AAC; the bundled dav1d and libvpx already cover AV1 and VP8/9.
- [ ] X3. Sound output, once the kernel has an audio device (alsa-lib is
      already shared).
- [ ] X4. dbus session bus and accessibility (`NO_AT_BRIDGE` off).
- [ ] X5. IPv6 (NETPLAN keeps it out of scope; Firefox falls back to IPv4).

## Phase Z: Chromium (after Firefox works)

Chromium reuses all of phases K and B. Additional needs: `--no-sandbox`
(no seccomp or namespaces), probably K7 (`SOCK_SEQPACKET`) for its zygote
and IPC, NSS and NSPR as shared system libraries (Chromium does not bundle
them), and a much larger build (GN and ninja, more hours and memory than
Firefox). Probe first with Alpine's `chromium` package, the same way as
phase P. Plan it in detail once F5 is done.

## Risks and open questions

- **Build cost:** Firefox is the largest recipe yet. Linking libxul uses
  several GiB, so use `-Wl,--no-keep-memory` and no LTO at first, and make
  sure swap is on. It must be built only once: get the mozconfig right in a
  scratch build outside Jinx before writing the recipe.
- **Rust on musl, dynamic:** the stock `x86_64-unknown-linux-musl` target
  defaults to static CRT. Alpine solves this with its own target triple;
  we use `-crt-static` and must check that `libxul.so`'s Rust parts link
  against `libc.so`, not a second, static musl.
- **GCC versus clang:** Mozilla tests mainly clang. If bootlin's GCC 13
  fails, the fallback is Debian clang targeting the musl sysroot.
- **mozjemalloc on this kernel:** it relies on `MAP_NORESERVE` reservations,
  `madvise(MADV_DONTNEED)` and `MADV_FREE`, which have to be correct (A4 and
  A5 exist). Alpine's flags show whether to keep mozjemalloc; if it
  misbehaves, try `--disable-jemalloc`.
- **Memory in the guest:** a parent and two content processes, plus GPU,
  RDD, socket and utility processes, need well over 1 GiB. The 8 GiB VM
  is enough, but a copying fork (K3) doubles the peak during a launch.
- **Global scheduler lock:** Firefox runs about 100 threads across its
  processes, more than Minecraft. Lock contention may be the first
  bottleneck (JAVA_PORT G3).
- **AML speed:** syscall-heavy IPC (small `sendmsg` calls with descriptors,
  `epoll_wait`) runs through the AML dispatcher. Measure in G1 before
  optimizing.
- **Recipe cache:** new recipes do not rebuild clang (see the Jinx notes).
  Do not change `musl`, `musl-cxx` or `clang`. The Rust toolchain is a new
  package, not a change to `aac`.

## Probe results

(Filled in during phase P: every logged `ENOSYS`, crash and missing file,
with the step that fixes it.)
