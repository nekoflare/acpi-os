# Porting OpenJDK (and Minecraft) to the ASL kernel

The work is split into small steps. Each step should leave the kernel booting and
`make -C acpi-kernel check` passing. A step is ticked only once a guest test
proves that it works. Guest tests live in `userspace/jdk-tests/`, and
`scripts/run-guest-test.sh` boots each one as the init module and reads the
serial log.

## Phase A: virtual memory

- [x] A1. `PROT_EXEC` in `mmap` and `mprotect` for anonymous memory, including RWX
      (HotSpot's code cache is RWX). Test: write `ret` into a mapping, call it,
      then make it read-only and executable and call it again.
- [x] A2. `MAP_FIXED` / `MAP_FIXED_NOREPLACE` at an address the caller picks,
      replacing whatever was mapped there. The mmap address hint is honoured
      when the range is free.
- [x] A3. Partial `munmap` and `mprotect` ranges that span or split mappings.
- [x] A4. `MAP_NORESERVE` and lazy anonymous memory: back pages on first touch,
      so a 4 GiB reservation costs nothing until it is used.
- [x] A5. `madvise` (`MADV_DONTNEED` frees and zeroes pages; other advice is a
      no-op that succeeds) and `mremap`, at least as `-ENOMEM` so callers fall
      back.
- [x] A6. TLB shootdown IPI after `munmap`/`mprotect` while other CPUs are
      running the same address space.

## Phase B: signals

- [x] B1. `SA_SIGINFO`: three-argument handlers with a Linux-layout
      `siginfo_t` and `ucontext_t` (gregs, fpstate, sigmask).
      `rt_sigreturn` restores the possibly modified context.
- [x] B2. Synchronous faults (`#PF`, `#UD`, `#DE`, `#GP`) become `SIGSEGV`,
      `SIGILL`, `SIGFPE` or `SIGBUS` delivered to a handler, with `si_addr` set
      to the fault address. HotSpot relies on recovering from these.
- [x] B3. `sigaltstack` and `SA_ONSTACK`.
- [x] B4. Nested handlers, `sa_mask`, `SA_NODEFER`, `SA_RESETHAND`,
      `SA_RESTART`.

## Phase C: dynamic linking

- [x] C1. Load `ET_DYN` (PIE) executables at a random or fixed base, with a
      full auxv (`AT_PHDR`, `AT_PHNUM`, `AT_ENTRY`, `AT_BASE`, `AT_PAGESZ`,
      `AT_RANDOM`, `AT_HWCAP`).
- [x] C2. `PT_INTERP`: load `ld-musl-x86_64.so.1` and start it.
- [x] C3. File-backed `mmap` with `PROT_EXEC` and `MAP_FIXED` over existing
      ranges, which is what ld.so does when it maps segments.
- [x] C4. Shared musl build (`libc.so`) packaged in the image; a dynamic hello
      and a `dlopen`/`dlsym` test.
      Shared musl comes from `scripts/build-musl-shared.sh`, not a recipe,
      because changing any recipe forces a cold jinx rebuild. Move it into
      the musl recipe when E1 adds the OpenJDK recipe and the tree is
      re-seeded anyway.

## Phase D: other syscalls and limits

- [x] D1. Raise the per-process descriptor limit from 19 to at least 1024.
- [x] D2. `epoll_create1`, `epoll_ctl`, `epoll_wait`, `epoll_pwait`.
- [x] D3. `sysinfo`, `getrandom`, `membarrier`, `clock_getres`, `sched_yield`,
      `/proc/self/maps`, `/proc/self/stat`, `/proc/cpuinfo` fields that the
      JVM reads.
- [x] D4. `AF_INET` sockets return clean errors (`EAFNOSUPPORT`) and loopback
      decisions are documented.
      Also added `eventfd`/`eventfd2`, which the JDK 17+ NIO selector needs,
      and `/etc/hosts` so `localhost` resolves.

## Phase E: OpenJDK

- [x] E1. OpenJDK recipe built for x86_64-linux-musl (Zero VM first), and
      `java -version` running.
      `recipes/openjdk` builds JDK 21.0.13 twice (Server, then Zero's
      libjvm.so, since Zero cannot share a configuration) and packs one
      image with `lib/server` and `lib/zero`. New recipes: `libffi`,
      `alsa-lib`, and `musl-runtime` (the toolchain's shared musl, C++
      runtime and dynamic linker). That replaces the C4 plan to change the
      musl recipe, which would have rebuilt every package. The kernel needed
      `/proc/<pid>/exe` (musl's `$ORIGIN`) and `getcpu`; without it HotSpot
      jumps to the unmapped vsyscall page. `run-guest-test.sh` gained
      `// disk:` and `// timeout:` for tests that need packages on ext4.
- [x] E2. Server VM (template interpreter + C1/C2), `java -version`, then
      Hello World.
      Worked without kernel or recipe changes. `java-server` checks
      `-Xint`, C1 only and full tiered `-version` (about 0.3 s each once
      the disk cache is warm), then `java /tmp/Hello.java`, which compiles
      the source in-process with javac and runs a JIT-compiled loop: about
      10 s with 4 CPUs and 6 s with 1. Look at that SMP slowdown in E3.
      `run-guest-test.sh` gained `// disk-rw` and gives test disks a `/tmp`.
- [x] E3. A multithreaded, GC-heavy stress program runs for minutes without
      crashing.
      `java-stress` compiles `Stress.java` with javac and runs it for about
      five minutes: ZGC, Shenandoah, G1 (120 s), Parallel and Serial, all
      self-checking with no mismatches. ZGC needs heap addresses at 4 TiB
      and up, so user space grew from 512 GiB to the Linux 128 TiB
      (`USTP` = 0x7FFFFFFFF000). The SMP slowdown was `mmap` without a
      hint. `UFND` stepped down past every mapping under the stack and
      rescanned the range list each time, which is quadratic and ran under
      the scheduler lock: 3.4 ms per call, 8 of every 10 s in Hello.java,
      with the other CPUs spinning on the lock. It now tries the space below
      the lowest mapping in the top zone first. Hello.java went from 10 s to
      1.1 s with 4 CPUs (1.3 s with 1), javac Stress.java from 18 s to 3 s,
      and G1 throughput tripled. A kernel profiler (`KPRF`, KPROF lines)
      remains. The largest kernel costs left are `mmap` with `MAP_FIXED`
      over reserved ranges (about 200 µs each) and `clock_gettime` without a
      vDSO (17 M calls in five minutes, each taking the lock).

## Phase F: graphics, audio and Minecraft

- [x] F1. Mesa (llvmpipe) with `libGL`, GLX enabled in Xvfb, plus `libXrandr`.
      Changed plan: Mesa 26.2.7 is built with `-Dglx=xlib` instead of GLX in
      Xvfb. Xvfb is static and cannot load a DRI driver, and server-side GLX
      would only give indirect OpenGL 1.4, which Minecraft cannot use. Xlib
      GLX does GLX inside `libGL.so.1`, renders with llvmpipe and presents
      with `XPutImage`/MIT-SHM. New recipes: `llvm-libs` (PIC static LLVM
      from the clang source under `/opt/acpi-llvm`; the clang package is
      untouched), `mesa` (with a patch that drops the DRM/KMS assumption),
      `libxrandr`, and shared builds of libX11, libxcb, libXau, libXdmcp,
      libXext and libXrender (`*-shared`), since GLFW `dlopen`s them. Their
      `package()` copies `.libs/*.so*` instead of `make install`, whose
      libtool relink adds `-L/usr/lib`. `mesa-glx` passes: libGL loads in
      0.9 s, RANDR 1.6 lists one output, a 3.2 core context reports
      `4.6 (Core Profile) Mesa 26.2.7` on `llvmpipe (LLVM 23.1.6, 256 bits)`,
      the shader output is checked, and 120 frames at 256x256 take 0.73 s
      (164 fps). Kernel fix: `fstat` on a console stdio descriptor read node
      fields at NULL+0x158, because AML `LAnd` evaluates both operands; that
      test and three similar ones (`VREF`, `VREL`, an ext4 list walk and a
      socket name read) now use nested `If`s. `run-guest-test.sh` gained
      `// disk-dynamic:`. The desktop image carries libGL, the shared X
      libraries, libXrandr, `libstdc++.so.6` and `libgcc_s.so.1` in
      `/usr/lib`.
- [x] F2. `glxgears` runs on the desktop.
      New recipe `mesa-demos` (9.0.0) compiles only `glxgears` and
      `glxinfo` against Mesa's libGL, since the meson build wants GLU, GLUT
      and EGL for the other demos. Both are in the desktop image's `/bin`.
      The `glxgears` guest test runs `glxinfo -B` on Xvfb (llvmpipe, 4.6
      core and compatibility profiles), then waits for two glxgears frame
      rate reports: 448 and 482 frames per 5 s (about 90-96 fps) in the
      default 300x300 window. Kernel fix: the ITIMER_REAL tick crashed at
      NULL+0x3F8 in `TGLV`, which tested `!Arg0 || !(XVWD (Arg0 + TSGX) ...)`
      for a process whose task had exited; `LOr` evaluates both operands.
      A scan of all `&&`/`||` conditions that read through an operand found
      three more (a tty ioctl, the fstab mkdir walk and fstab's mount point
      check), all now split into separate `If`s.
- [x] F3. LWJGL 3 natives, GLFW and OpenAL Soft (null device) built for musl;
      an LWJGL demo opens a window.
      The target is Minecraft 1.20.1: it needs Java 17+, so it runs on our
      JDK 21, and it uses LWJGL 3.3.1. Releases from 26.x on need Java 25
      and SDL3. New recipes, all installing into `/usr/lib/lwjgl`:
      - `lwjgl`: liblwjgl, liblwjgl_opengl, liblwjgl_stb and
        liblwjgl_tinyfd, compiled straight from the generated C in the
        3.3.1 tarball (no Ant/Kotlin generator) with the
        `config/linux/build.xml` flags. Core links the static libffi
        against LWJGL's bundled `ffi.h`, which has the same `ffi_cif` and
        closure layout and x86-64 ABI values.
      - `lwjgl-glfw`, `lwjgl-openal` and `lwjgl-jemalloc`: the LWJGL-CI
        forks at the commits recorded in the official natives jars.
        - GLFW 3.4 dev, X11 only, compiled directly.
        - OpenAL Soft 1.21.1 with only the Null and WaveFile backends.
        - jemalloc 5.2.1 with the `je_` prefix and
          `--disable-initial-exec-tls`, since musl cannot give a dlopened
          library static TLS.
      - `libxinerama`, for GLFW's header.

      `scripts/fetch-lwjgl.sh` downloads Mojang's seven LWJGL jars and
      checks their SHA-1s from the 1.20.1 manifest. `run-guest-test.sh`
      gained `// prepare:` and `// disk-dir:`.

      The `lwjgl-demo` test runs `java/LwjglDemo.java` from source on Xvfb.
      Every library loads from `org.lwjgl.librarypath`, and these checks
      pass:
      - jemalloc becomes the MemoryUtil allocator.
      - An stb PNG round trip, through a native write callback (a libffi
        closure).
      - A 0.25 s tone plays on the OpenAL null device in 0.25 s.
      - A GLFW 320x240 window with a 3.2 core context gets 4.6 core on
        llvmpipe, and the first frame's pixels are checked.
      - 300 frames at about 110 fps.
      - tinyfd loads.

      The whole run takes 5 s. LWJGL needs `-Dos.name=Linux`, because
      `uname` reports "ASL kernel" and `Platform` rejects that. Minecraft's
      own OS check reads `os.name` too, so F4 passes the same flag.
      Harmless warnings:
      - ThreadLocalUtil does not know JDK 21's JNI version, as on any
        Linux.
      - OpenAL cannot set real-time priority (`ENOSYS`).

      The desktop image carries the natives, the jars in `/opt/lwjgl`,
      `/bin/lwjgl-demo` (which runs until its window is closed) and
      `libatomic.so.1`, which libopenal needs. The test disks have it from
      `musl-runtime`.
- [x] F4. Minecraft files fetched on the host and packed into the image,
      launched in offline mode.

      `scripts/fetch-minecraft.sh` downloads the 1.20.1 version JSON,
      `client.jar`, the 36 Java libraries and the 3,577 asset objects
      (about 700 MB), all checked by SHA-1. It skips the LWJGL jars (F3)
      and the glibc netty epoll natives; netty falls back to NIO.

      `config/minecraft` is installed as `/bin/minecraft`:
      - It derives the vanilla offline UUID from the player name.
      - It runs `net.minecraft.client.main.Main` with `-Xmx2G` and
        `-Dos.name=Linux`.
      - It keeps the game directory in `/minecraft`, on the persistent
        volume.

      The `minecraft` guest test runs the same arguments on Xvfb. It
      passes when the last texture atlas is created and the game is still
      running 60 s later. It then saves the screen to `/tmp/minecraft.ppm`
      on the test disk, with a raw X11 GetImage. The title screen,
      panorama included, is up about 40 s after the JVM starts. It also
      runs on the desktop.

      Expected errors, the same as on any offline Linux:
      - The auth server cannot be reached (no network sockets).
      - The narrator finds no `libflite`.
      - A vanilla missing-sound warning for the goat horn.

      JNA and oshi load. Packing the 3,600 new files into the desktop
      image took about 3 minutes the first time.

## Phase G: performance

In-world, Minecraft went from about 1 FPS to about 11 FPS (test settings,
854x480) and about 47 FPS on the desktop with low settings:
- a vDSO for `clock_gettime`;
- 64 KiB fault-around for lazy anonymous memory;
- 128 KiB socket and pipe buffers instead of 2 KB, so a frame reaches
  Xorg in about 13 transfers instead of about 800;
- tick-driven poll rescans limited to deadlines;
- epoll scans stop at the last used entry;
- a ticket scheduler lock;
- a TLB flush on lock acquire only after a kernel mapping changes.

The render thread now spends about 67% of its time in user mode, 17% in
the kernel and 4% waiting for the scheduler lock. Next steps, in the
recommended order:

- [ ] G1. Clean up: remove the TEMP profiling.
      - `KPRF`/`KPTT`/`KPTH`/`KPDM`/`KPSY` and their hooks in
        `kernel.asl`.
      - The `XLKP`/`XKMK` lock profiler in `boot.c`, `kernel.asl` and
        `src/llvm.rs`.
      - `GALLIUM_HUD` in `userspace/jdk-tests/minecraft.c`.
      - Decide what to keep of the scratch `minecraft-world` test.
      Rerun the suite, then commit. The probes run under the lock on
      every syscall and fault, so this alone should help a little.
- [ ] G2. Page faults and `munmap`.
      - About 12k faults/s at about 9 us each, and 780 munmaps/s at
        about 62 us each, which is most of the render thread's kernel
        time.
      - Probably per-frame mmap/munmap churn from malloc in Mesa.
      - Look at the synchronous TLB-shootdown IPIs done under the lock,
        and at how much fault-around zeroes for pages that are unmapped
        soon after.
- [ ] G3. Scheduler stage 2, then stage 3.
      - Stage 2: per-CPU run queues and a futex fast path.
      - Stage 3: split the global lock by subsystem (memory, sockets,
        VFS).
      - The expected gain is small now: lock wait is about 4% of the
        render thread. Going idle and waking (`SSTP` entry, `TACK`)
        are about 17% of lock hold time.
