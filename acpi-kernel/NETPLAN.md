# Networking for the ASL kernel

Goal: `curl https://example.com/` prints the page in the guest, first on a
plain QEMU boot and then on the X.Org desktop.

The work is split into small steps. Each step should leave the kernel booting
and `make -C acpi-kernel check` passing. A step is ticked only once a guest
test proves that it works. Network tests live in `userspace/net-tests/` and
run with `scripts/run-guest-test.sh <name>` (the harness from `JAVA_PORT.md`,
which also searches that directory).

## Starting point

What already exists and can be reused:

- `kernel/virtio-blk.asl`: a transitional (legacy, I/O BAR) virtio PCI
  driver with one virtqueue, physically contiguous ring pages from `PALC`,
  and polled completion. virtio-net uses the same handshake and ring layout.
- Sockets: `SKND` stream endpoints (AF_UNIX and pipes) with 128 KiB receive
  rings, `SKIO` for send/recv/accept, `SKWH`/`SKCH` for blocking waits, and
  readiness through `ppoll` (`SYPP`), `epoll` (`EPWT`) and `PWAK`.
  `socket(AF_INET, ...)` returns `EAFNOSUPPORT` on purpose (JAVA_PORT D4).
- `getrandom` and `AT_RANDOM` from RDRAND, which TLS needs.
- `CLOCK_REALTIME` from the CMOS RTC plus the monotonic clock, which
  certificate validity checks need.
- `/etc/hosts` with `localhost`, pthreads (curl's threaded resolver) and
  `socketpair` (curl's wakeup pair).
- Device interrupts: only PIT, LAPIC and PS/2 are wired. They are latched in
  `x86.S` and handled in `TACK`. I/O APIC routing for legacy IRQs targets the
  BSP.

## Design decisions

- **Device:** `virtio-net-pci` with `disable-modern=on`, like virtio-blk:
  I/O-port BAR0, a 20-byte legacy header (24 with MSI-X enabled), queue 0 RX
  and queue 1 TX. Features: only `VIRTIO_NET_F_MAC` at first. No offloads,
  checksums in software, a 10-byte `virtio_net_hdr` (no
  `MRG_RXBUF`).
- **QEMU network:** user-mode (slirp): `-netdev user,id=n0 -device
  virtio-net-pci,netdev=n0,disable-modern=on`. The guest is `10.0.2.15/24`,
  the gateway `10.0.2.2` and DNS `10.0.2.3`. Static configuration comes
  first; DHCP is a later step.
- **Stack location:** all of it is in ASL, split into includes like the VFS:
  `net-virtio.asl` (driver), `net-ip.asl` (Ethernet, ARP, IPv4, ICMP, UDP),
  `net-tcp.asl` (TCP) and `net-sock.asl` (the AF_INET socket layer). Native
  glue stays limited to what AML cannot express (see N2).
- **Interrupts:** MSI-X from the start, no RX polling. Table entry 0 sends
  vector `NIVC` (0x27, same APIC priority class as the other device IRQs)
  to the BSP; `x86.S` latches it like PS/2 and `TACK` harvests the RX ring.
  The RX queue uses that entry; TX and config changes have `NO_VECTOR` (TX
  buffers are reclaimed when a new one is needed). The BSP tick only
  compares the earliest network timer deadline (`NATT`).
- **Locking:** all network state is touched under the existing scheduler
  lock, like the rest of ASL state. Packet processing runs on the BSP from
  `TACK` or inline from a syscall that sends.
- **Sockets:** a new vnode identity `INND` (separate from `SKND`) with its
  own open-description layout. `read`/`write`/`close`/`fcntl`/`poll`/`epoll`
  dispatch on it the way they dispatch on `SKND`. Receive data goes into a
  ring the size of `SKRB`.
- **Userland:** curl with TLS from its first build: OpenSSL 3, plus the
  Mozilla CA bundle at `/etc/ssl/certs/ca-certificates.crt`. Everything is
  linked dynamically against musl's `libc.so` (from `musl-runtime`), so
  `libssl.so`, `libcrypto.so`, `libz.so` and `libcurl.so` are shared libraries
  that Python's `ssl` module and git's HTTPS transport can reuse later. musl's
  resolver needs only `/etc/resolv.conf` and UDP sockets.
- **IPv6:** out of scope. `AF_INET6` sockets keep returning `EAFNOSUPPORT`,
  and curl and musl fall back to IPv4.

## Phase N: device and link layer

- [x] N1. Find virtio-net on PCI (`1AF4:1000`, transitional), reset it,
      negotiate `VIRTIO_NET_F_MAC`, read the MAC, set up RX/TX virtqueues,
      DRIVER_OK. Log `virtio-net MAC=52:54:00:12:34:56` on serial. Generalize
      the PCI scan and contiguous-page allocation out of `VBIN` into shared
      helpers instead of copying them. Add the net device to
      `run-guest-test.sh` (`// net` directive) and to `run-xorg-uefi`.
      Done: `kernel/virtio.asl` (`PCFD`, `VIOB`, `PCON`, `VQST`),
      `kernel/net-virtio.asl` (`NVIN`), harness `// net` and `// expect:`
      directives, test `net-probe`. QEMU fixes both queues at 256 entries.
- [x] N2. Packet I/O. Post RX buffers (one page each: 10-byte header plus a
      1514-byte frame), harvest the used ring from the BSP tick, recycle
      buffers, and transmit through a TX descriptor pool with completion
      reclaim. Measure the per-packet cost. If byte loops for the Internet
      checksum or frame copies are too slow in AML, add native helpers
      (`XCSM` for one's-complement sums, already-existing `XMOV` for copies)
      lowered in `src/llvm.rs` like the other kernel intrinsics.
      Test: dump the first received frame (slirp sends nothing unsolicited,
      so send a broadcast ARP and log the reply's header).
      Done: 64 RX and 32 TX pages (`NBUF`, `NRXP`, `NTXA`/`NTXP`), ring
      indices published with one aligned qword store (`NIDX`). `NRXP` runs
      from `TACK` on the MSI-X vector (see Interrupts; `PMSX` in
      `virtio.asl`). The boot self-test `NTST` waits for that interrupt and
      fails without it. `XCSM` is deferred to I1, where the first checksum is
      needed.
- [x] N3. Ethernet and ARP: answer ARP requests for 10.0.2.15, resolve the
      gateway with a small cache (8 entries, timeout, a queue of one pending
      packet per entry). Test: gateway MAC logged.
      Done in `kernel/net-ip.asl`: `NETH` filters on our MAC/broadcast,
      `NARP` answers requests and learns senders, `NETX` sends or queues one
      frame per unresolved entry, `NATK` retries every 1 s for 3 s from the
      tick hook `NTIK`. Resolved entries expire after 60 s. Boot logs
      `virtio-net gateway 10.0.2.2 is 52:55:0a:00:02:02` (round trip ~155k
      TSC cycles). The queued-frame flush is first exercised in I2 (ping the
      not yet resolved 10.0.2.3).

## Phase I: IPv4, ICMP and UDP inside the kernel

- [x] I1. IPv4 input and output: header checksum, routing (on-link
      `10.0.2.0/24`, otherwise the gateway), drop fragments for now (set DF
      on output; slirp's MTU is 1500), TTL 64, IP ID counter.
      Done in `kernel/net-inet.asl` (`NIPO` out, `NIPV` in). Checksums use
      the native `XCSM` (`acpi_checksum` in `boot.c`, lowered in
      `src/llvm.rs`): a folded one's-complement sum that `NCSM` complements.
      Input also drops multicast/broadcast sources and accepts the limited
      and subnet broadcast destinations.
- [x] I2. ICMP: answer echo requests, and parse echo replies for the kernel
      self-test. Test: the kernel pings `10.0.2.2` at boot and logs the RTT.
      Done (`NICI`, `NPNG`). The self-test pings 10.0.2.3 while it is still
      unresolved, which sends the request from the ARP queue, then pings
      10.0.2.2. It also feeds an echo request through `NETH` and checks
      the reply. Both RTTs are about 30 to 100 us.
- [x] I3. ICMP destination unreachable / port unreachable for UDP, mapped to
      `ECONNREFUSED` on connected UDP sockets later (S2).
      Done: `NUDI` checks the UDP checksum and answers every unicast
      datagram with port unreachable (`NICU`) until sockets exist. Incoming
      unreachable and time-exceeded errors that quote our header are kept in
      `NIER`/`NIEC`/`NIEQ` for the socket layer. The self-test sends UDP to
      10.0.2.2:9 and expects slirp to relay the host's port unreachable.
      `NUDO` sends UDP with a checksum. `// net` tests also write a pcap of
      the NIC's traffic (`<build>/<name>.pcap`); the frames above were
      checked there.

## Phase S: socket layer, UDP and DNS

- [x] S1. `INND` vnode and `socket(AF_INET, SOCK_DGRAM | SOCK_STREAM, 0 or
      IPPROTO_UDP/TCP)` with `SOCK_NONBLOCK`/`SOCK_CLOEXEC`. `close`,
      `fcntl(O_NONBLOCK)`, `dup`, fork inheritance, and `bind` with port
      allocation (ephemeral range 32768-60999). `AF_INET6` still returns
      `EAFNOSUPPORT`.
      Done in `kernel/net-sock.asl`: one page per open description, laid
      out so `SKFC` serves `fcntl` for both families. `SKLK` replaces the
      "is this an AF_UNIX socket" checks wherever a socket must not be
      treated as a node (fstat gives `S_IFSOCK`, lseek/pread give `ESPIPE`,
      mmap `ENODEV`, epoll accepts it). Bound sockets are on a list (`INHD`);
      ports conflict per protocol when the addresses overlap. `bind` accepts
      `INADDR_ANY` and 10.0.2.15. `getsockname`/`getpeername` (from S3) came
      early for the test. Until S2, `connect` returns `EOPNOTSUPP`,
      read/write return `ENOTCONN` (`EDESTADDRREQ` for a UDP write), and poll
      reports `POLLOUT` (plus `POLLHUP` for streams). Test `net-socket`. The
      JDK test `net-eventfd` no longer expects `AF_INET` to fail.
- [x] S2. UDP sockets: `sendto`, `recvfrom`, `sendmsg`, `recvmsg`, `connect`
      (default peer), `send`/`recv`/`read`/`write`, a per-socket datagram
      queue, and `MSG_DONTWAIT`, `MSG_PEEK` and `MSG_TRUNC`. Readiness for
      `ppoll`, `select` and `epoll`. Blocking waits use the `SKWH`/`SKCH`
      mechanism.
      Connected sockets report a matching ICMP port unreachable (`NIER`
      etc. from I3) as `ECONNREFUSED`.
      Done in `kernel/net-sock.asl`. `NUDI` looks up the socket (`INUL`:
      port, local address or wildcard, and the peer if connected) and
      queues the datagram as one page (`INEN`, at most 64 per socket);
      unmatched unicast still gets port unreachable. `INIO` serves every
      data syscall from the syscall frame, so `SKWK` retries a blocked
      receive through `SKIO`; readv/writev move one datagram. Sends are
      limited to 1472 bytes (`EMSGSIZE`, no fragmentation; lifted after
      S6, see "Datagrams up to 64 KiB" below); 127/8 and
      0.0.0.0 give `ENETUNREACH` until S6. `connect` binds an ephemeral
      port and, like Linux, turns a wildcard local address into 10.0.2.15.
      `INIE` maps hard unreachable codes to the connected socket's pending
      error (port 3 to `ECONNREFUSED`, protocol 2 to `ENOPROTOOPT`, ...),
      which poll reports as `POLLERR` and the next send or receive
      returns once. `sendto` without an address now also works on
      connected AF_UNIX streams (musl's `send`). Fixed S1's `getsockname`
      writing 8 bytes into the 4-byte `SKAL`. Test `net-udp` uses the
      runner's new `// udp-echo` host echo server.
- [x] S3. Socket options and queries that libc and curl call:
      `getsockname`, `getpeername`, `getsockopt(SO_ERROR, SO_TYPE)`,
      `setsockopt` for `SO_REUSEADDR`, `SO_KEEPALIVE`, `SO_RCVBUF`/`SO_SNDBUF`,
      `TCP_NODELAY` and `TCP_KEEP*` (accepted, mostly no-ops), and
      `shutdown`. `ioctl(FIONREAD)`.
      Done in `kernel/net-sock.asl` (`INSY`, `INOS`, `INOG`, `INSD`, `INIC`).
      SOL_SOCKET: `SO_TYPE`, `SO_ERROR` (reads and clears the pending
      error), `SO_DOMAIN`, `SO_PROTOCOL`, `SO_ACCEPTCONN`, `SO_RCV/SNDLOWAT`,
      booleans `SO_REUSEADDR`, `SO_REUSEPORT`, `SO_KEEPALIVE`,
      `SO_BROADCAST`, `SO_DONTROUTE`, `SO_OOBINLINE`, buffer sizes doubled
      and clamped like Linux, and `SO_LINGER`. IPPROTO_TCP (TCP sockets
      only): `TCP_NODELAY`, `TCP_MAXSEG`, `TCP_KEEPIDLE/INTVL/CNT` with
      Linux's ranges. Values are stored and read back; only the reuse
      options change behaviour (sockets that both set one may share a port;
      phase T must still reject a listening socket). Others give
      `ENOPROTOOPT`, including every `SOL_IP` option, which Java tolerates.
      `SO_RCVTIMEO`/`SO_SNDTIMEO` are not supported yet. `shutdown` follows
      Linux UDP: recorded even when it reports `ENOTCONN`; after `SHUT_RD`
      a blocking receive returns 0 once the queue is empty (nonblocking
      still gives `EAGAIN`), poll adds `POLLRDHUP | POLLIN`, and `POLLHUP`
      after both; `SHUT_WR` makes sends fail with `EPIPE` (no SIGPIPE, as
      for UDP). Shutdown wakes blocked receivers. ioctl: `FIONREAD` (next
      datagram's length), `SIOCOUTQ` (0), `FIONBIO`, and `ENOTTY` for the
      rest, so `isatty` on an AF_INET socket is now false. AF_UNIX sockets
      still return `ENOSYS` for these three syscalls. Test `net-sockopt`.
- [x] S4. Interface configuration that tools look for: `ioctl`
      `SIOCGIFCONF`, `SIOCGIFADDR`, `SIOCGIFFLAGS`, `SIOCGIFHWADDR`,
      `SIOCGIFINDEX` and `SIOCGIFMTU` for `lo` and `eth0`; `/proc/net/route`
      and `/proc/net/dev` in `procfs.asl`. Enough for busybox `ifconfig` and
      `route` to print sensible output. (Setting addresses is N/A while the
      configuration is static.)
      Done in `kernel/net-if.asl`. Interface 1 is `lo` (127.0.0.1/8, MTU
      65536); interface 2 is `eth0` and exists only while the NIC is up.
      `SIOCGIFCONF` (a null buffer returns the length needed),
      `SIOCGIFNAME`, `FLAGS`, `ADDR`, `DSTADDR`, `BRDADDR`, `NETMASK`,
      `METRIC`, `MTU`, `HWADDR`, `INDEX`, `TXQLEN` and `MAP` answer on
      AF_INET and AF_UNIX sockets. An unknown name gives `ENODEV`.
      `SIOCSIFFLAGS` succeeds only when it keeps the interface up; the other
      setters and `SIOCETHTOOL` give `EOPNOTSUPP`. `/proc/net/dev` reports
      live frame and byte counters for eth0 (`NRXB`, `NTXF`, `NTXB` beside
      `NFRM`); `lo` is all zeros until S6. `/proc/net/route` has the default
      route and the on-link /24, padded to 127 columns as Linux does. Test
      `net-ifconf` checks the ioctls and both files, and runs busybox
      `ifconfig -a` and `route -n`. Gaps: musl's `if_nametoindex` and
      `if_nameindex` fail because they need an AF_UNIX `SOCK_DGRAM` socket,
      and `getifaddrs` needs rtnetlink. Neither blocks curl.
- [x] S5. DNS: ship `/etc/resolv.conf` (`nameserver 10.0.2.3`) in the
      initramfs and desktop image. Test: a C guest test calls `getaddrinfo`
      for `example.com` and prints the A records; busybox `nslookup` works.
      Done with no kernel changes: `config/resolv.conf` goes into every
      fstab (desktop) initramfs beside `/etc/hosts` (`kernel/build.mk`) and
      into every guest-test initramfs (`scripts/run-guest-test.sh`). Test
      `net-dns` resolves `example.com` as A only and as A+AAAA (musl's
      address sorting connects a UDP socket per answer), a trailing-dot
      name, `localhost` from `/etc/hosts`, NXDOMAIN (answered at once),
      `gethostbyname`, and runs busybox `nslookup` for a name and for
      NXDOMAIN. Lookups take 30-100 ms through slirp. Without a NIC a DNS
      lookup fails after musl's 5 s timeout (`EAI_AGAIN`): `sendto` gives
      `ENETUNREACH`, which musl ignores, then polls until timeout. Before S5
      it was the same, since musl's default nameserver is 127.0.0.1.
- [x] S6. Loopback: `127.0.0.0/8` goes through a software interface without
      touching the NIC. Needed for UDP/TCP tests without slirp and for
      programs that talk to themselves (Minecraft's integrated server uses a
      local channel, not TCP, so this is not urgent).
      Done in `kernel/net-inet.asl`. Local addresses (`NLOC`) are 127/8
      always and 10.0.2.15 while eth0 is up. `NOBF` gives a packet to a
      local address a fresh page instead of a virtio TX buffer, and `NIPO`
      hands it to `NLOX`, which queues it on `lo` and delivers it through
      `NIPV` with a from-lo flag. Whatever delivery sends (echo replies,
      port unreachables, later TCP segments) joins the queue, and only the
      outermost call drains it, so nothing recurses; T can reuse this
      as is. `NIPO` and `NUDO` take the source address: a bound socket's,
      else 127.0.0.1 for 127/8 and 10.0.2.15 otherwise (`NSRC`). Sockets
      route through `INRT`: without the NIC anything off `lo` is
      `ENETUNREACH` (`connect` too, now), and a socket bound to 127/8
      cannot send off-host (`EINVAL`, as on Linux). `bind` accepts any
      127/8 address and 10.0.2.15 only while eth0 is up; destination
      0.0.0.0 means 127.0.0.1 for `sendto` and `connect`. The wire may not
      claim a 127/8 source, except ICMP: slirp relays the host's port
      unreachables from 127.0.0.1, and those only reach the socket whose
      datagram they quote. `/proc/net/dev` counts `lo` traffic. Test
      `net-loopback` (no NIC) covers unbound and bound sockets, any 127.x
      address, 0.0.0.0, `ECONNREFUSED` via ICMP over `lo`, a 40-datagram
      burst to self, waking a blocked receiver in
      another process, `localhost`, `ENETUNREACH`/`EADDRNOTAVAIL` off
      `lo`, and an exact `lo` packet count. `net-udp` checks that a
      datagram to 10.0.2.15 goes over `lo`, not eth0, and that a socket
      bound to 127.0.0.1 cannot reach 10.0.2.2. `net-socket` binds 127.0.0.1
      instead of 10.0.2.15, since it runs without a NIC.
- [x] Datagrams up to 64 KiB, as on Linux: UDP payloads up to 65507 bytes
      (65508 gives `EMSGSIZE`) on any route. `NOBF` takes the payload size:
      a local destination gets a page or, if bigger, contiguous pages
      (`VALL`) with the lo queue header in front, so `lo` (MTU 65536) always
      carries one packet. To eth0 (MTU 1500), up to 1480 bytes of IP payload
      go in one TX buffer with DF set (Linux's `IP_PMTUDISC_WANT`); a bigger
      datagram is built in `NFSB` and `NIPG` sends it as fragments of 1480
      bytes without DF. The ARP queue holds up to 64 frames per neighbour
      instead of one, so every fragment survives resolution. Input
      fragments are reassembled by `NIPF` in up to 8 contexts keyed by
      source, destination, protocol and ID, each with an 8-byte-unit bitmap.
      Overlaps keep the later data, and a last fragment that contradicts the
      length drops the datagram. After 30 s a context expires and, if its
      first fragment came, sends ICMP time exceeded (code 1). When every
      unit is present, the rebuilt datagram goes through `NIPV` again.
      Socket queues hold big datagrams in contiguous pages and, like Linux,
      drop new ones while more than `SO_RCVBUF` bytes are queued. Tests:
      `net-udp` echoes 1472 to 65507 bytes through slirp at both sides of
      every fragment boundary, checks the eth0 frame count per size, and
      checks `FIONREAD` and `MSG_TRUNC` on a 40000-byte datagram.
      `net-loopback` sends up to 65507 bytes to itself as one `lo` packet
      and checks the `SO_RCVBUF` limit. The boot self-test injects a
      3000-byte datagram as out-of-order fragments with a duplicate, and
      only a correct reassembly passes the UDP checksum. TCP (phase T) takes
      its MSS from the route: 1460 on eth0, 65483 on `lo` (65495 without
      timestamps), and builds its segments with `NOBF`.

## Phase T: TCP

Slirp's network is lossless and in order, so correctness comes first and
performance tuning later. Each sub-step gets a guest test against a host
server reached through `10.0.2.2` (the `// tcp-server` directive of
`run-guest-test.sh`).

- [x] T1. TCB and connection setup: active open (`connect`, blocking and
      nonblocking with `EINPROGRESS`, completion visible as `POLLOUT` plus
      `SO_ERROR`), the SYN with MSS option 1460, the three-way handshake, RST
      handling (`ECONNREFUSED`), and the 4-tuple lookup. ISN from RDRAND.
      Done in `kernel/net-tcp.asl`. The TCB lives in the socket's page after
      the S fields (`TBST` on); connections are found on the bound list
      (`TPLK`, exact 4-tuple first, then a specific listener before a
      wildcard one, with a one-entry cache). A blocking connect returns
      `Ones` to wait like a receive (the connect syscall now calls `SKBK`)
      and `INIO` retries it through `TPCW`; a second nonblocking connect
      gives `EALREADY`, then 0 once, then `EISCONN`. Segments for no socket
      get a reset (RFC 793), so `lo` refuses like slirp does. When ARP for
      an on-link host gives up after 3 s, a connect to it fails with
      `EHOSTUNREACH` (`TPHU`), as on Linux; ICMP unreachables for TCP are
      hard errors in SYN_SENT and soft ones otherwise (`TPIC`). Test
      `net-tcp-connect` with the runner's new `// tcp-server` directive
      (`scripts/tcp-test-server.py`: echo, send N, sink, rst, wait, slow,
      idle, sinklog and query).
- [x] T2. Data transfer: send buffer (128 KiB) segmented by MSS, receive
      ring (128 KiB) and advertised window, cumulative ACKs, delayed ACK
      (on the tick, at most 2 segments), and `PSH`. Out-of-order segments are
      dropped and re-ACKed at first. Test: download 10 MB from the host and
      compare a checksum.
      Done: two rings per connection (`TBSB`, `TBRB`; 256 KiB since T6).
      The send ring holds everything from SND.UNA on, so retransmission
      reads it again. Output (`TPOU`/`TPO1`) follows cwnd and the peer's
      window with Nagle (off with `TCP_NODELAY`) and sender SWS avoidance;
      the receiver moves its window edge only by an MSS or half the ring
      (RFC 1122) and never back. ACKs: after more than one segment, at the
      end of the RX batch (`TPFL` from `NRXP` and the `lo` drain), else on a
      40 ms delayed-ACK timer, at once for anything out of order, and as a
      window update once a read doubles the window (like Linux's
      `tcp_cleanup_rbuf`). The MSS is 1460 on eth0 and 65495 on `lo`, or
      `TCP_MAXSEG`. A blocking send or a `MSG_WAITALL` receive that has to
      wait keeps its progress in the task (`TSNP`), so a retry continues
      where it stopped and a signal returns the partial count, as on Linux.
      `MSG_PEEK`, `MSG_TRUNC` (discards), `MSG_DONTWAIT`, `FIONREAD` (unread
      bytes), `SIOCOUTQ` (unacknowledged bytes) and Linux's `tcp_poll`
      readiness. Test `net-tcp-data`: 10 MB each way checked byte for byte
      (about 200 MB/s down and 100 MB/s up through slirp), a single 4 MiB
      `send`, `MSG_WAITALL`, `MSG_PEEK`, `MSG_TRUNC`, readv/writev,
      sendmsg/recvmsg, and a full send ring (`EAGAIN`, then `POLLOUT`).
- [x] T3. Timers on the BSP tick: retransmission with RTO from RTT
      estimation (RFC 6298, a 200 ms minimum), exponential backoff, a
      connect timeout (`ETIMEDOUT`), zero-window probes, and TIME_WAIT
      (shortened to a few seconds). Test with QEMU's `-netdev ...` plus a
      host-side `tc netem` loss setup only if available; otherwise a kernel
      debug switch that drops every Nth outgoing segment.
      Done: `NTIK` runs `TPTK`, which walks the TCBs with timers (`TPHD`).
      RTO per RFC 6298 (Karn's rule, 200 ms floor, 120 s cap), doubled per
      timeout and recomputed from SRTT on the next new ACK, like Linux.
      A timeout goes back to SND.UNA with cwnd at one MSS. Gives up with
      `ETIMEDOUT` (or a soft ICMP/ARP error seen meanwhile) after
      `TCP_SYNCNT` (6) SYNs, 5 SYN-ACKs, 15 retransmissions, or
      `TCP_USER_TIMEOUT`. Congestion control is NewReno (RFC 5681, 6582)
      with limited transmit (RFC 3042): slirp ACKs every segment at once,
      so after a loss only a few segments are in flight. Duplicate ACKs
      count even when the window moved, since slirp's moves with every ACK.
      Data that arrives ahead of a hole waits in the receive ring at its
      final place (up to 8 ranges, `TPOI`/`TPOM`). The persist timer probes
      a closed window and, as RFC 1122 asks, uses a small open one. Keepalive
      (`SO_KEEPALIVE`, `TCP_KEEPIDLE/INTVL/CNT`). TIME_WAIT lasts 5 s;
      an orphan's FIN_WAIT_2 60 s. Socket option `TCP_DBGDROP` (0x4E44,
      this kernel only) drops every Nth outgoing segment, and with N << 16
      every Nth incoming one; getsockopt returns the drops, and 0x4E45 the
      persist probes. Test `net-tcp-timers`: SYN loss (ETIMEDOUT after
      3 s with `TCP_SYNCNT` 1, a retried SYN after 1 s), uploads losing
      every 7th (3 MB in 0.45 s) and every 3rd segment, a download losing
      incoming data, lost ACKs, a peer that stops reading, `TCP_USER_TIMEOUT`,
      keepalive answered and unanswered, and TIME_WAIT in the new
      `/proc/net/tcp`. Gap: slirp's own sender (BSD without limited
      transmit) often recovers incoming losses only by its 1 s timeout.
- [x] T4. Teardown: FIN in both directions, half-close through
      `shutdown(SHUT_WR)`, all close states, `EPIPE`/`SIGPIPE` and
      `MSG_NOSIGNAL`, RST on close with unread data, socket reclaim once the
      TCB is closed.
      Done: close turns a connection into an orphan (`TPCL`) that still
      sends what is queued and its FIN; closing with unread data, or with
      `SO_LINGER` {1, 0}, resets instead, as on Linux. Data for an orphan
      resets it. Closed orphans and children nobody accepted are freed on
      the next tick (`TPZH`), when no TCP code can still hold them. A reset
      reports `ECONNRESET` once, then end of file and `EPIPE`; sends after
      `SHUT_WR` or a reset raise `SIGPIPE` unless `MSG_NOSIGNAL`. A blocking
      `SO_LINGER` close with a timeout does not wait. Test `net-tcp-close`.
- [x] T5. Passive open: `listen`, `accept`/`accept4` with a backlog, so a
      guest server can be reached through slirp `hostfwd`. Not needed for
      curl, but cheap once T1-T4 exist and useful for testing.
      Done: a SYN to a listener makes a child in SYN_RCVD (options
      inherited); once established it waits in the accept queue. Children
      beyond the backlog drop the SYN, so the client retries. Listeners
      conflict on bind and listen unless both set `SO_REUSEPORT`; closing
      one resets the children nobody accepted. `POLLIN`/epoll on pending
      connections, `SO_ACCEPTCONN`. Test `net-tcp-listen`: client and server
      over `lo` (also across `fork`), backlog 1, port conflicts, 50 MB
      between two processes (about 130 MB/s), deterministic zero-window
      probes, and the host reaching a guest server through the runner's new
      `// tcp-fwd: <port>` directive (`scripts/tcp-fwd-client.py`).
- [x] T6. Speed: window scaling, a larger receive window, and fewer copies.
      Target: a sustained download of at least 10 MB/s through slirp.
      Profile with `KPRF` if it is still around.
      Done: window scaling (RFC 7323, shift 7 like Linux) and 256 KiB rings,
      so `lo` connections keep up to 256 KiB in flight (`net-tcp-listen`
      checks it). slirp does not scale windows, so through it the window
      stays at 64 KiB; downloads already run at about 200 MB/s, twenty
      times the target. Data is copied once into each ring and once out;
      checksums use the native `XCSM`. `/proc/net/snmp` has Linux's `Tcp`
      lines (`ActiveOpens`, `RetransSegs`, `OutRsts`, ...).

## Phase C: curl

- [x] C1. Shared libraries: an `openssl` recipe (OpenSSL 3.x,
      `linux-x86_64` target, `shared no-static-engine`, `--openssldir=/etc/ssl`;
      the Jinx build container needs Perl for `Configure`) and a `zlib-shared`
      recipe in the style of `libxau-shared`, leaving the static `zlib` alone.
      Add a `ca-certificates` recipe (or fetch `cacert.pem` and check its
      SHA-256 like the Minecraft files) installed as
      `/etc/ssl/certs/ca-certificates.crt`. Test: a dynamic guest program
      links `libcrypto.so` and prints a SHA-256 and RAND bytes.
      Done: `openssl` 3.5.9 (the 3.x LTS; shared, built with the musl-cxx
      toolchain, `openssl` tool included, static archives dropped),
      `zlib-shared` (libz.so.1 only; headers come from `zlib`) and
      `ca-certificates` (Mozilla's bundle from the certifi 2026.11.20 source
      tarball, since Jinx fetches only archives), installed as
      `/etc/ssl/certs/ca-certificates.crt` with `/etc/ssl/cert.pem`, OpenSSL's
      default file, linked to it. Test `net-crypto`: a dynamic probe checks
      SHA-256("abc"), RAND_bytes, loads the 113 CA certificates, creates a TLS
      client context with the default verify paths and round-trips zlib; then
      `openssl version -a`, `dgst -sha256` and `genpkey ed25519` run. The
      runner gained `// disk-libs: <flags>`. Kernel fix: mounting an ext4
      root used to fail when the disk had a name the initramfs root also had,
      so no package could ship `/etc`; EXMT now merges two such directories
      (EXMG), keeping the bootstrap entries (fstab, hosts, resolv.conf), which
      win over disk files of the same name. The desktop image carries
      libssl, libcrypto, libz, `/bin/openssl`, the legacy provider and
      `/etc/ssl` (pack-xorg-disk.sh no longer removes a disk `/etc`).
- [x] C2. A `curl` recipe built with `--with-openssl --with-zlib
      --with-ca-bundle=/etc/ssl/certs/ca-certificates.crt`, shared `libcurl.so`
      and a dynamically linked `curl`. IPv6 can stay enabled; curl falls back
      to IPv4. Guest test against a host HTTPS server (`openssl s_server` or
      Python's `http.server` with a self-signed certificate, passed to curl
      with `--cacert`), plus plain `http://10.0.2.2:8000/`. Check the RTC date
      in the guest, or certificate checks fail.
      Done: recipes/curl (8.23.0, shared libcurl.so.4 on the shared OpenSSL
      and zlib, CA bundle /etc/ssl/certs/ca-certificates.crt, threaded
      resolver). net-tests/net-curl.c with the new "// http-server" runner
      directive (scripts/http-test-server.py, a fresh self-signed certificate
      for 10.0.2.2 whose notBefore is a day early): guest clock check, plain
      HTTP, HTTPS with --cacert, HTTPS without it refused (exit 60), 1 MiB
      over HTTPS byte-exact, --compressed gzip, a 200 kB upload checked by
      CRC-32, and the libcurl API (curl/curl-probe.c). The desktop image
      carries /bin/curl and libcurl.so.4.
- [x] C3. `curl https://example.com/` prints the page. Guest test: `curl -sS
      https://example.com/ | grep "Example Domain"`, skipped when the host
      has no internet. Then on the desktop in `st`, with the libraries and the
      CA bundle in the desktop image.
      Done on the desktop: the user ran `curl https://example.com/` in `st`
      and it printed the page; Minecraft's multiplayer list also reaches its
      servers. The automated guest test (skipped without internet) is not
      written yet.

## Phase L: later

Not needed for the curl goal, but they follow naturally:

- [x] L1. MSI-X interrupts for virtio-net: done in phase N (see
      Interrupts above).
- [ ] L2. DHCP client in the kernel (or `AF_PACKET` so busybox `udhcpc`
      works), so non-slirp setups (tap/bridge) get an address.
- [ ] L3. ICMP ping sockets (`SOCK_DGRAM`, `IPPROTO_ICMP`) so busybox `ping`
      works without raw sockets.
- [ ] L4. Minecraft multiplayer and the auth servers, `git clone https://`,
      `pip install`.
- [ ] L5. Checksum and segmentation offload (`VIRTIO_NET_F_CSUM`,
      `GUEST_CSUM`, `MRG_RXBUF`), if T6 shows that software checksums matter.

## Risks and open questions

- **AML speed:** per-byte loops over packets cost a lot. Every copy should go
  through `XMOV` and the checksum through a native helper from the start
  (N2) rather than retrofitting later.
- **The early allocator does not reclaim:** packet buffers, TCBs and socket
  rings must come from `PALC`/`PDEL` pages, never the 512 KiB early arena.
- **Scheduler lock hold time:** processing RX under the global lock from
  the tick competes with Minecraft-style workloads. That is fine for now;
  stage 3 of G3 (splitting the lock by subsystem) would give the network its
  own lock.
- **Time:** TLS fails if the RTC is wrong or the guest clock drifts. QEMU's
  default RTC is the host's UTC, which is right.
- **Recipe cache:** new recipes (openssl, zlib-shared, curl, ca-certificates) do not
  rebuild clang (see the jinx seed/resume notes); do not touch the musl
  recipe.

Saved from Claudey:
Gaps:
- Window scaling only applies over lo, because slirp doesn't support it.
- slirp's own sender often recovers lost incoming segments only by its 1 s timeout, so that test uses a small transfer.
- A close() with SO_LINGER and a nonzero timeout doesn't block.