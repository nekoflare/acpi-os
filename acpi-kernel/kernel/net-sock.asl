    // AF_INET sockets. An open description is one page whose first fields
    // match the VFS header (identity at 0, reference count at 16) and whose
    // O_NONBLOCK flag sits at SKFL like an AF_UNIX endpoint, so SKFC serves
    // fcntl for both. Addresses and ports are kept in host order.
    Name (INND, Buffer (432) {}) // AF_INET socket vnode identity; VNSL bytes, see MFND
    Name (INHD, Zero)  // Bound sockets
    Name (INEP, Zero)  // Last ephemeral port handed out
    Name (INAD, Buffer (16) {}) // sockaddr_in staging
    Name (INTY, 56)  // 1 SOCK_STREAM, 2 SOCK_DGRAM
    Name (INPT, 64)  // IPPROTO_TCP (6) or IPPROTO_UDP (17)
    Name (INLA, 72)  // Local address, zero for INADDR_ANY
    Name (INLP, 80)  // Local port, zero while unbound
    Name (INRA, 88)  // Peer address
    Name (INRP, 96)  // Peer port, zero while unconnected
    Name (INNX, 104) // Bound-list link
    Name (INER, 112) // Pending error (SO_ERROR) as a negative errno
    Name (INQH, 120) // Received datagrams, oldest first
    Name (INQT, 128)
    Name (INQN, 136) // Queued datagram count
    Name (INOB, 144) // Boolean options: bit n is SOL_SOCKET option n, bit 33 TCP_NODELAY
    Name (INRB, 152) // SO_RCVBUF as getsockopt reports it, zero for the default
    Name (INSB, 160) // SO_SNDBUF, likewise
    Name (INSH, 168) // shutdown: 1 receive, 2 send
    Name (INLG, 176) // SO_LINGER: l_onoff in bit 0, l_linger in the high half
    Name (INKI, 184) // TCP_KEEPIDLE, zero for the default 7200
    Name (INKV, 192) // TCP_KEEPINTVL, zero for 75
    Name (INKC, 200) // TCP_KEEPCNT, zero for 9
    Name (INMS, 208) // TCP_MAXSEG, zero for 536
    Name (INQM, 64)  // Receive queue limit in datagrams
    Name (INMX, 65507) // Largest UDP payload: 65535 less the IPv4 and UDP headers
    Name (INQB, 216) // Bytes of queued datagrams, held to SO_RCVBUF
    Name (INAL, Buffer (8) {}) // socklen_t staging
    Name (INIV, Buffer (4096) {}) // Kernel copy of up to 256 struct iovec
    Name (INMH, Buffer (56) {}) // Linux x86-64 struct msghdr
    Name (INTF, Zero) // MSG_TRUNC when the last receive cut a datagram short

    // True for descriptions that are sockets of either family; such
    // identities are not real nodes.
    Method (SKLK, 1, NotSerialized)
    {
        Return (Arg0 == XADR (SKND) || Arg0 == XADR (INND))
    }

    // The AF_INET description of descriptor Arg1, or zero.
    Method (INFD, 2, NotSerialized)
    {
        Local0 = UFDL (Arg0, Arg1 & 0xFFFFFFFF)
        If (!Local0) { Return (Zero) }
        If (XVWD (Local0, Ones) != XADR (INND)) { Return (Zero) }
        Return (Local0)
    }

    // socket(AF_INET, Arg1, Arg2).
    Method (INSO, 3, NotSerialized)
    {
        Local0 = Arg1 & ~0x80800
        If (Local0 != One && Local0 != 2) { Return (Zero - 94) } // ESOCKTNOSUPPORT
        Local1 = 6
        If (Local0 == 2) { Local1 = 17 }
        If (Arg2 && Arg2 != Local1) { Return (Zero - 93) } // EPROTONOSUPPORT
        Local2 = PALC ()
        If (!Local2) { Return (Zero - 12) }
        Local2 += HHDO
        XCLR (Local2)
        XSTQ (Local2, XADR (INND))
        XSTQ (Local2 + 16, One)
        XSTQ (Local2 + SKFL, Arg1 & 0x800)
        XSTQ (Local2 + INTY, Local0)
        XSTQ (Local2 + INPT, Local1)
        Local3 = FINS (Arg0, Local2, Arg1)
        If (Local3 >= Zero - 4095) { PDEL (Local2 - HHDO) }
        Return (Local3)
    }

    // Final close.
    Method (INCL, 1, NotSerialized)
    {
        If (XVWD (Arg0 + INTY, Ones) == One)
        {
            TPCL (Arg0)
            Return ()
        }
        While (XVWD (Arg0 + INQH, Ones)) { INDQ (Arg0) }
        INUB (Arg0)
        PDEL (Arg0 - HHDO)
    }

    // Take bound socket Arg0 off the bound list.
    Method (INUB, 1, NotSerialized)
    {
        If (!XVWD (Arg0 + INLP, Ones)) { Return () }
        Local0 = Zero
        Local1 = INHD
        While (Local1 && Local1 != Arg0)
        {
            Local0 = Local1
            Local1 = XVWD (Local1 + INNX, Ones)
        }
        If (!Local1) { Return () }
        Local2 = XVWD (Arg0 + INNX, Ones)
        If (Local0) { XSTQ (Local0 + INNX, Local2) }
        Else { INHD = Local2 }
        XSTQ (Arg0 + INLP, Zero)
    }

    // A socket of protocol Arg0 bound to port Arg1 whose address overlaps
    // Arg2 (equal, or either is INADDR_ANY), or zero. Sockets that share
    // SO_REUSEADDR or SO_REUSEPORT with option bits Arg3 do not conflict.
    // A TCP listener conflicts unless both set SO_REUSEPORT.
    Method (INFN, 4, NotSerialized)
    {
        Local0 = INHD
        While (Local0)
        {
            If (XVWD (Local0 + INPT, Ones) == Arg0 && XVWD (Local0 + INLP, Ones) == Arg1)
            {
                Local1 = XVWD (Local0 + INLA, Ones)
                If (!Local1 || !Arg2 || Local1 == Arg2)
                {
                    Local2 = 0x8004
                    If (Arg0 == 6)
                    {
                        If (XVWD (Local0 + TBST, Ones) == One) { Local2 = 0x8000 }
                    }
                    If (!(XVWD (Local0 + INOB, Ones) & Arg3 & Local2)) { Return (Local0) }
                }
            }
            Local0 = XVWD (Local0 + INNX, Ones)
        }
        Return (Zero)
    }

    // Bind socket Arg0 to address Arg1 and port Arg2 (zero picks an
    // ephemeral port in 32768-60999). Returns zero or a negative errno.
    Method (INBN, 3, NotSerialized)
    {
        Local0 = XVWD (Arg0 + INPT, Ones)
        If (!Arg2)
        {
            Local1 = 28232
            While (Local1)
            {
                Increment (INEP)
                If (INEP < 32768 || INEP > 60999) { INEP = 32768 }
                If (!INFN (Local0, INEP, Arg1, Zero)) { Break }
                Decrement (Local1)
            }
            If (!Local1) { Return (Zero - 98) } // EADDRINUSE
            Arg2 = INEP
        }
        ElseIf (INFN (Local0, Arg2, Arg1, XVWD (Arg0 + INOB, Ones))) { Return (Zero - 98) }
        XSTQ (Arg0 + INLA, Arg1)
        XSTQ (Arg0 + INLP, Arg2)
        XSTQ (Arg0 + INNX, INHD)
        INHD = Arg0
        Return (Zero)
    }

    // Copy a sockaddr_in of user length Arg2 from Arg1 into INAD. Returns
    // zero or a negative errno.
    Method (INCA, 3, NotSerialized)
    {
        If (Arg2 < 16) { Return (Zero - 22) }
        If (!UCPY (Arg0, XADR (INAD), Arg1, 16)) { Return (Zero - 14) }
        If (ELWD (XADR (INAD), Zero, 2) != 2) { Return (Zero - 97) } // EAFNOSUPPORT
        Return (Zero)
    }

    // bind(Arg1, Arg2, Arg3).
    Method (INBD, 4, NotSerialized)
    {
        Local0 = INFD (Arg0, Arg1)
        Local1 = INCA (Arg0, Arg2, Arg3)
        If (Local1) { Return (Local1) }
        If (XVWD (Local0 + INLP, Ones)) { Return (Zero - 22) }
        Local2 = NL32 (XADR (INAD) + 4)
        If (Local2 && !NLOC (Local2)) { Return (Zero - 99) } // EADDRNOTAVAIL
        Return (INBN (Local0, Local2, NL16 (XADR (INAD) + 2)))
    }

    // getsockname (Arg4 zero) or getpeername into user Arg2, length at Arg3.
    Method (INGN, 5, NotSerialized)
    {
        Local0 = UFDL (Arg0, Arg1 & 0xFFFFFFFF)
        If (!Local0) { Return (Zero - 9) }
        If (XVWD (Local0, Ones) != XADR (INND))
        {
            If (XVWD (Local0, Ones) == XADR (SKND)) { Return (Zero - 95) }
            Return (Zero - 88) // ENOTSOCK
        }
        Local1 = XADR (INAL)
        If (!UCPY (Arg0, Local1, Arg3, 4) || !URNG (Arg0, Arg3, 4, WRIT)) { Return (Zero - 14) }
        Local2 = ELWD (Local1, Zero, 4)
        If (Local2 >> 31) { Return (Zero - 22) }
        Local3 = XVWD (Local0 + INLA, Ones)
        Local4 = XVWD (Local0 + INLP, Ones)
        If (Arg4)
        {
            Local3 = XVWD (Local0 + INRA, Ones)
            Local4 = XVWD (Local0 + INRP, Ones)
            If (!Local4) { Return (Zero - 107) } // ENOTCONN
            If (XVWD (Local0 + INTY, Ones) == One)
            {
                Local5 = XVWD (Local0 + TBST, Ones)
                If (Local5 < 3) { Return (Zero - 107) } // CLOSED, LISTEN, SYN_SENT
            }
        }
        INSA (Local3, Local4)
        If (Local2 > 16) { Local2 = 16 }
        If (Local2 && !UCOP (Arg0, Arg2, XADR (INAD), Local2)) { Return (Zero - 14) }
        XSTQ (Local1, 16)
        If (!UCOP (Arg0, Arg3, Local1, 4)) { Return (Zero - 14) }
        Return (Zero)
    }

    // Fill INAD with the sockaddr_in for address Arg0, port Arg1.
    Method (INSA, 2, NotSerialized)
    {
        Local0 = XADR (INAD)
        XSTQ (Local0, 2 | ((Arg1 >> 8) << 16) | ((Arg1 & 0xFF) << 24) |
            ((Arg0 >> 24) << 32) | (((Arg0 >> 16) & 0xFF) << 40) |
            (((Arg0 >> 8) & 0xFF) << 48) | ((Arg0 & 0xFF) << 56))
        XSTQ (Local0 + 8, Zero)
    }

    // read (Arg4 zero) or write of Arg3 bytes at Arg2 on description Arg1.
    Method (INRW, 5, NotSerialized)
    {
        INV1 (Arg2, Arg3)
        If (Arg4) { Return (INSN (Arg0, Arg1, One, Zero, Zero, Zero)) }
        Return (INRC (Arg0, Arg1, One, Zero, Zero, Zero))
    }

    // Poll events.
    Method (INRD, 1, NotSerialized)
    {
        If (XVWD (Arg0 + INTY, Ones) != 2) { Return (TPPL (Arg0)) }
        Local0 = 0x104 // POLLOUT | POLLWRNORM
        If (XVWD (Arg0 + INQH, Ones)) { Local0 |= 0x41 } // POLLIN | POLLRDNORM
        If (XVWD (Arg0 + INER, Ones)) { Local0 |= 8 } // POLLERR
        Local1 = XVWD (Arg0 + INSH, Ones)
        If (Local1 & One) { Local0 |= 0x2041 } // POLLRDHUP | POLLIN | POLLRDNORM
        If (Local1 == 3) { Local0 |= 0x10 } // POLLHUP
        Return (Local0)
    }

    // connect(Arg1, Arg2, Arg3). UDP only records the default peer; AF_UNSPEC
    // removes it. As on Linux, 0.0.0.0 means 127.0.0.1.
    Method (INCN, 4, NotSerialized)
    {
        Local0 = INFD (Arg0, Arg1)
        If (XVWD (Local0 + INTY, Ones) == One)
        {
            Local1 = INCA (Arg0, Arg2, Arg3)
            If (Local1) { Return (Local1) }
            Local2 = NL32 (XADR (INAD) + 4)
            If (!Local2) { Local2 = 0x7F000001 }
            Return (TPCN (Local0, Local2, NL16 (XADR (INAD) + 2), XVWD (Local0 + SKFL, Ones)))
        }
        If (Arg3 < 2) { Return (Zero - 22) }
        If (!UCPY (Arg0, XADR (INAD), Arg2, 2)) { Return (Zero - 14) }
        If (!ELWD (XADR (INAD), Zero, 2))
        {
            XSTQ (Local0 + INRA, Zero)
            XSTQ (Local0 + INRP, Zero)
            Return (Zero)
        }
        Local1 = INCA (Arg0, Arg2, Arg3)
        If (Local1) { Return (Local1) }
        Local2 = NL32 (XADR (INAD) + 4)
        Local3 = NL16 (XADR (INAD) + 2)
        If (!Local2) { Local2 = 0x7F000001 }
        Local1 = INRT (Local0, Local2)
        If (Local1) { Return (Local1) }
        If (!XVWD (Local0 + INLP, Ones))
        {
            Local1 = INBN (Local0, Zero, Zero)
            If (Local1) { Return (Local1) }
        }
        // Like Linux, a wildcard local address becomes the source address.
        If (!XVWD (Local0 + INLA, Ones)) { XSTQ (Local0 + INLA, NSRC (Local2)) }
        XSTQ (Local0 + INRA, Local2)
        XSTQ (Local0 + INRP, Local3)
        XSTQ (Local0 + INER, Zero)
        Return (Zero)
    }

    // Whether socket Arg0 can reach Arg1: zero or a negative errno. Only
    // lo exists without the NIC, and lo addresses cannot leave the host.
    Method (INRT, 2, NotSerialized)
    {
        If (NLOC (Arg1)) { Return (Zero) }
        If (!NBAR) { Return (Zero - 101) } // ENETUNREACH
        If ((XVWD (Arg0 + INLA, Ones) >> 24) == 127) { Return (Zero - 22) }
        Return (Zero)
    }

    // Set INIV to the single iovec Arg0, Arg1.
    Method (INV1, 2, NotSerialized)
    {
        XSTQ (XADR (INIV), Arg0)
        XSTQ (XADR (INIV) + 8, Arg1)
    }

    // Copy Arg2 user iovecs from Arg1 into INIV. Returns zero or a negative errno.
    Method (INVL, 3, NotSerialized)
    {
        If (Arg2 > 256) { Return (Zero - 22) }
        If (Arg2)
        {
            If (!UCPY (Arg0, XADR (INIV), Arg1, Arg2 * 16)) { Return (Zero - 14) }
        }
        Return (Zero)
    }

    // Total length of the Arg0 iovecs in INIV, or -EINVAL for a negative one.
    // Lengths of 2 GiB and more report 2 GiB, which is too long to send.
    Method (INVS, 1, NotSerialized)
    {
        Local0 = Zero
        Local1 = XADR (INIV)
        While (Arg0)
        {
            Local2 = XVWD (Local1 + 8, Ones)
            If (Local2 >> 63) { Return (Zero - 22) }
            If (Local2 >> 31) { Return (0x80000000) }
            Local0 += Local2
            Local1 += 16
            Decrement (Arg0)
        }
        Return (Local0)
    }

    // Gather the Arg2 user iovecs in INIV to kernel Arg1. Zero on a fault.
    Method (INGA, 3, NotSerialized)
    {
        Local0 = XADR (INIV)
        While (Arg2)
        {
            Local1 = XVWD (Local0 + 8, Ones)
            If (Local1)
            {
                If (!UCPY (Arg0, Arg1, XVWD (Local0, Ones), Local1)) { Return (Zero) }
            }
            Arg1 += Local1
            Local0 += 16
            Decrement (Arg2)
        }
        Return (One)
    }

    // Scatter Arg2 kernel bytes at Arg1 over the Arg3 user iovecs in INIV.
    // Returns the bytes copied or -EFAULT.
    Method (INSC, 4, NotSerialized)
    {
        Local0 = XADR (INIV)
        Local2 = Zero
        While (Arg3 && Arg2)
        {
            Local1 = XVWD (Local0 + 8, Ones)
            If (Local1 > Arg2) { Local1 = Arg2 }
            If (Local1)
            {
                If (!UCOP (Arg0, XVWD (Local0, Ones), Arg1, Local1)) { Return (Zero - 14) }
            }
            Arg1 += Local1
            Arg2 -= Local1
            Local2 += Local1
            Local0 += 16
            Decrement (Arg3)
        }
        Return (Local2)
    }

    // Send the Arg2 iovecs in INIV with flags Arg3 to user sockaddr Arg4
    // (length Arg5), or to the connected peer when Arg4 is zero.
    Method (INSN, 6, NotSerialized)
    {
        If (XVWD (Arg1 + INTY, Ones) != 2) { Return (TPSN (Arg0, Arg1, Arg2, Arg3)) }
        If (Arg3 & One) { Return (Zero - 95) } // MSG_OOB
        Local0 = XVWD (Arg1 + INRA, Ones)
        Local1 = XVWD (Arg1 + INRP, Ones)
        If (Arg4)
        {
            Local2 = INCA (Arg0, Arg4, Arg5)
            If (Local2) { Return (Local2) }
            Local0 = NL32 (XADR (INAD) + 4)
            Local1 = NL16 (XADR (INAD) + 2)
            If (!Local1) { Return (Zero - 22) }
        }
        ElseIf (!Local1) { Return (Zero - 89) } // EDESTADDRREQ
        Local2 = XVWD (Arg1 + INER, Ones)
        If (Local2)
        {
            XSTQ (Arg1 + INER, Zero)
            Return (Local2)
        }
        If (XVWD (Arg1 + INSH, Ones) & 2) { Return (Zero - 32) } // EPIPE, without SIGPIPE for UDP
        Local3 = INVS (Arg2)
        If (Local3 >= Zero - 4095) { Return (Local3) }
        If (Local3 > INMX) { Return (Zero - 90) } // EMSGSIZE
        If (!Local0) { Local0 = 0x7F000001 }
        Local2 = INRT (Arg1, Local0)
        If (Local2) { Return (Local2) }
        If (!XVWD (Arg1 + INLP, Ones))
        {
            Local2 = INBN (Arg1, Zero, Zero)
            If (Local2) { Return (Local2) }
        }
        Local5 = XVWD (Arg1 + INLA, Ones)
        If (!Local5) { Local5 = NSRC (Local0) }
        Local4 = NOBF (Local0, Local3 + 8)
        If (!Local4) { Return (Zero - 105) } // ENOBUFS
        If (!INGA (Arg0, Local4 + 42, Arg2))
        {
            NOAB (Local4, Local0)
            Return (Zero - 14)
        }
        NUDO (Local0, XVWD (Arg1 + INLP, Ones), Local1, Local4, Local3, Local5)
        Return (Local3)
    }

    // Receive one datagram into the Arg2 iovecs in INIV with flags Arg3. A
    // nonzero Arg4 receives the source address, with its length at Arg5.
    // Returns the length (the full one with MSG_TRUNC), a negative errno,
    // or Ones to block.
    Method (INRC, 6, NotSerialized)
    {
        If (XVWD (Arg1 + INTY, Ones) != 2) { Return (TPRV (Arg0, Arg1, Arg2, Arg3, Arg4, Arg5)) }
        If (Arg3 & One) { Return (Zero - 95) } // MSG_OOB
        Local0 = XVWD (Arg1 + INER, Ones)
        If (Local0)
        {
            XSTQ (Arg1 + INER, Zero)
            Return (Local0)
        }
        Local1 = XVWD (Arg1 + INQH, Ones)
        If (!Local1)
        {
            If ((Arg3 & 0x40) || XVWD (Arg1 + SKFL, Ones)) { Return (Zero - 11) } // EAGAIN
            // Like Linux, only a blocking receive sees end of file after SHUT_RD.
            If (XVWD (Arg1 + INSH, Ones) & One)
            {
                INTF = Zero
                Return (Zero)
            }
            Return (Ones)
        }
        Local2 = XVWD (Local1 + 24, Ones)
        Local3 = Zero
        If (Arg4)
        {
            If (!UCPY (Arg0, XADR (INAL), Arg5, 4)) { Return (Zero - 14) }
            Local3 = ELWD (XADR (INAL), Zero, 4)
            If (Local3 >> 31) { Return (Zero - 22) }
        }
        Local4 = INSC (Arg0, Local1 + 32, Local2, Arg2)
        If (Local4 >= Zero - 4095) { Return (Local4) }
        If (Arg4)
        {
            INSA (XVWD (Local1 + 8, Ones), XVWD (Local1 + 16, Ones))
            If (Local3 > 16) { Local3 = 16 }
            If (Local3)
            {
                If (!UCOP (Arg0, Arg4, XADR (INAD), Local3)) { Return (Zero - 14) }
            }
            XSTQ (XADR (INAL), 16)
            If (!UCOP (Arg0, Arg5, XADR (INAL), 4)) { Return (Zero - 14) }
        }
        INTF = Zero
        If (Local4 < Local2) { INTF = 0x20 }
        If (!(Arg3 & 2)) { INDQ (Arg1) } // MSG_PEEK leaves it queued.
        If (Arg3 & 0x20) { Return (Local2) }
        Return (Local4)
    }

    // read, write, readv, writev, sendto, recvfrom, sendmsg and recvmsg on
    // an AF_INET descriptor, for task Arg0 with syscall frame Arg1. Also
    // retries blocked receives from SKWK.
    Method (INIO, 2, NotSerialized)
    {
        Local0 = XVWD (Arg1 + 14 * 8, Ones)
        Local1 = INFD (Arg0, XVWD (Arg1 + 8 * 8, Ones))
        If (!Local1)
        {
            XSTQ (Arg0 + TSNP, Zero)
            Return (Zero - 9) // Closed while blocked
        }
        Local2 = XVWD (Arg1 + 9 * 8, Ones)
        Local3 = XVWD (Arg1 + 12 * 8, Ones)
        If (Local0 == 43 || Local0 == 288)
        {
            If (XVWD (Local1 + INTY, Ones) != One) { Return (Zero - 95) } // EOPNOTSUPP
            Local4 = Zero
            If (Local0 == 288) { Local4 = XVWD (Arg1 + 5 * 8, Ones) & 0xFFFFFFFF }
            Return (TPAC (Arg0, Local1, Local2, Local3, Local4))
        }
        If (Local0 == 42) { Return (TPCW (Local1)) } // a blocked connect
        If (Local0 <= One || Local0 == 44 || Local0 == 45)
        {
            INV1 (Local2, Local3)
            Local4 = XVWD (Arg1 + 5 * 8, Ones) & 0xFFFFFFFF
            Local5 = XVWD (Arg1 + 7 * 8, Ones)
            Local6 = XVWD (Arg1 + 6 * 8, Ones)
            If (Local0 <= One)
            {
                Local4 = Zero
                Local5 = Zero
            }
            If (Local0 == One || Local0 == 44)
            {
                Return (INSN (Arg0, Local1, One, Local4, Local5, Local6 & 0xFFFFFFFF))
            }
            Return (INRC (Arg0, Local1, One, Local4, Local5, Local6))
        }
        If (Local0 == 19 || Local0 == 20)
        {
            Local3 &= 0xFFFFFFFF
            Local5 = INVL (Arg0, Local2, Local3)
            If (Local5) { Return (Local5) }
            If (Local0 == 20) { Return (INSN (Arg0, Local1, Local3, Zero, Zero, Zero)) }
            Return (INRC (Arg0, Local1, Local3, Zero, Zero, Zero))
        }
        // sendmsg or recvmsg; control messages are ignored.
        Local3 &= 0xFFFFFFFF
        Local5 = XADR (INMH)
        If (!UCPY (Arg0, Local5, Local2, 56)) { Return (Zero - 14) }
        Local6 = XVWD (Local5 + 24, Ones)
        Local7 = INVL (Arg0, XVWD (Local5 + 16, Ones), Local6)
        If (Local7) { Return (Local7) }
        Local7 = XVWD (Local5, Ones)
        If (Local0 == 46)
        {
            Return (INSN (Arg0, Local1, Local6, Local3, Local7,
                XVWD (Local5 + 8, Ones) & 0xFFFFFFFF))
        }
        If (!URNG (Arg0, Local2, 56, WRIT)) { Return (Zero - 14) }
        Local4 = Zero
        If (Local7) { Local4 = Local2 + 8 }
        Local0 = INRC (Arg0, Local1, Local6, Local3, Local7, Local4)
        If (Local0 >= Zero - 4095) { Return (Local0) }
        Local5 = XADR (INAL)
        XSTQ (Local5, Zero)
        If (!Local7) { UCOP (Arg0, Local2 + 8, Local5, 4) } // msg_namelen
        UCOP (Arg0, Local2 + 40, Local5, 8) // msg_controllen
        XSTQ (Local5, INTF)
        UCOP (Arg0, Local2 + 48, Local5, 4) // msg_flags
        Return (Local0)
    }

    // Drop the oldest queued datagram of Arg0.
    Method (INDQ, 1, NotSerialized)
    {
        Local0 = XVWD (Arg0 + INQH, Ones)
        Local1 = XVWD (Local0, Ones)
        XSTQ (Arg0 + INQH, Local1)
        If (!Local1) { XSTQ (Arg0 + INQT, Zero) }
        XSTQ (Arg0 + INQN, XVWD (Arg0 + INQN, Ones) - One)
        Local1 = XVWD (Local0 + 24, Ones)
        XSTQ (Arg0 + INQB, XVWD (Arg0 + INQB, Ones) - Local1)
        Local1 += 32
        If (Local1 <= PGSZ) { PDEL (Local0 - HHDO) }
        Else { VUNM (Local0, Local1) }
    }

    // Queue Arg4 bytes of data at Arg3 from Arg1 port Arg2 on socket Arg0.
    // A datagram holds the link, address, port and length, then data: one
    // page, or contiguous pages for a big one. Like Linux, a datagram is
    // dropped while the queue already holds more than SO_RCVBUF.
    Method (INEN, 5, NotSerialized)
    {
        If (XVWD (Arg0 + INQN, Ones) >= INQM) { Return () }
        Local1 = XVWD (Arg0 + INRB, Ones)
        If (!Local1) { Local1 = 212992 }
        If (XVWD (Arg0 + INQB, Ones) > Local1) { Return () }
        If (Arg4 + 32 <= PGSZ)
        {
            Local0 = PALC ()
            If (!Local0) { Return () }
            Local0 += HHDO
        }
        Else
        {
            Local0 = VALL (Arg4 + 32, WRIT)
            If (!Local0) { Return () }
        }
        XSTQ (Arg0 + INQB, XVWD (Arg0 + INQB, Ones) + Arg4)
        XSTQ (Local0, Zero)
        XSTQ (Local0 + 8, Arg1)
        XSTQ (Local0 + 16, Arg2)
        XSTQ (Local0 + 24, Arg4)
        XMOV (Local0 + 32, Arg3, Arg4)
        Local1 = XVWD (Arg0 + INQT, Ones)
        If (Local1) { XSTQ (Local1, Local0) }
        Else { XSTQ (Arg0 + INQH, Local0) }
        XSTQ (Arg0 + INQT, Local0)
        XSTQ (Arg0 + INQN, XVWD (Arg0 + INQN, Ones) + One)
        SKCH = One
    }

    // The UDP socket for a datagram to Arg0 port Arg1 from Arg2 port Arg3:
    // bound to that port and address (or the wildcard), and if connected,
    // connected to the source. Zero if none.
    Method (INUL, 4, NotSerialized)
    {
        Local0 = INHD
        While (Local0)
        {
            If (XVWD (Local0 + INPT, Ones) == 17 && XVWD (Local0 + INLP, Ones) == Arg1)
            {
                Local1 = XVWD (Local0 + INLA, Ones)
                Local2 = XVWD (Local0 + INRP, Ones)
                If (!Local1 || Local1 == Arg0)
                {
                    If (!Local2) { Return (Local0) }
                    If (Local2 == Arg3 && XVWD (Local0 + INRA, Ones) == Arg2) { Return (Local0) }
                }
            }
            Local0 = XVWD (Local0 + INNX, Ones)
        }
        Return (Zero)
    }

    // ICMP destination unreachable code Arg2 quoting the IPv4 header at
    // Arg0, of which Arg1 bytes were quoted. Hard errors go to the connected UDP
    // socket that sent the datagram, as on Linux without IP_RECVERR.
    Method (INIE, 3, NotSerialized)
    {
        Local0 = (XBYT (Arg0) & 0xF) * 4
        If (Local0 < 20 || Arg1 < Local0 + 4) { Return () }
        If (XBYT (Arg0 + 9) == 6)
        {
            TPIC (Arg0, Arg1, Arg2)
            Return ()
        }
        If (XBYT (Arg0 + 9) != 17) { Return () }
        If (Arg2 == 3) { Local1 = Zero - 111 } // ECONNREFUSED
        ElseIf (Arg2 == 2) { Local1 = Zero - 92 } // ENOPROTOOPT
        ElseIf (Arg2 == 6 || Arg2 == 9) { Local1 = Zero - 101 } // ENETUNREACH
        ElseIf (Arg2 == 7) { Local1 = Zero - 112 } // EHOSTDOWN
        ElseIf (Arg2 == 10 || Arg2 == 13) { Local1 = Zero - 113 } // EHOSTUNREACH
        Else { Return () }
        Local2 = Arg0 + Local0
        Local3 = INUL (NL32 (Arg0 + 12), NL16 (Local2), NL32 (Arg0 + 16), NL16 (Local2 + 2))
        If (!Local3) { Return () }
        If (!XVWD (Local3 + INRP, Ones)) { Return () }
        XSTQ (Local3 + INER, Local1)
        SKCH = One
    }

    // shutdown, setsockopt or getsockopt for task Arg0 with syscall frame
    // Arg1. AF_UNIX sockets do not support them yet.
    Method (INSY, 2, NotSerialized)
    {
        Local0 = XVWD (Arg1 + 14 * 8, Ones)
        Local1 = XVWD (Arg1 + 8 * 8, Ones) & 0xFFFFFFFF
        Local2 = UFDL (Arg0, Local1)
        If (!Local2)
        {
            If (SSTD (Arg0, Local1)) { Return (Zero - 88) } // The console
            Return (Zero - 9)
        }
        Local1 = Local2
        If (XVWD (Local1, Ones) != XADR (INND))
        {
            If (XVWD (Local1, Ones) == XADR (SKND))
            {
                If (Local0 == 48) { Return (Zero - 38) } // shutdown
                Return (SKOP (Arg0, Local1, Local0 == 55, XVWD (Arg1 + 9 * 8, Ones) & 0xFFFFFFFF,
                    XVWD (Arg1 + 12 * 8, Ones) & 0xFFFFFFFF, XVWD (Arg1 + 5 * 8, Ones),
                    XVWD (Arg1 + 7 * 8, Ones)))
            }
            Return (Zero - 88) // ENOTSOCK
        }
        Local2 = XVWD (Arg1 + 9 * 8, Ones) & 0xFFFFFFFF
        If (Local0 == 48) { Return (INSD (Local1, Local2)) }
        Local3 = XVWD (Arg1 + 12 * 8, Ones) & 0xFFFFFFFF
        Local4 = XVWD (Arg1 + 5 * 8, Ones)
        Local5 = XVWD (Arg1 + 7 * 8, Ones)
        If (Local0 == 54) { Return (INOS (Arg0, Local1, Local2, Local3, Local4, Local5 & 0xFFFFFFFF)) }
        Return (INOG (Arg0, Local1, Local2, Local3, Local4, Local5))
    }

    // shutdown(Arg0, Arg1). Like Linux, an unconnected socket records the
    // shutdown but reports ENOTCONN.
    Method (INSD, 2, NotSerialized)
    {
        If (Arg1 > 2) { Return (Zero - 22) }
        If (XVWD (Arg0 + INTY, Ones) == One) { Return (TPSH (Arg0, Arg1)) }
        XSTQ (Arg0 + INSH, XVWD (Arg0 + INSH, Ones) | (Arg1 + One))
        SKCH = One
        If (XVWD (Arg0 + INTY, Ones) != 2 || !XVWD (Arg0 + INRP, Ones)) { Return (Zero - 107) }
        Return (Zero)
    }

    // setsockopt(Arg1, level Arg2, name Arg3, user Arg4, length Arg5).
    // Options are recorded and reported back; only SO_REUSEADDR and
    // SO_REUSEPORT change behaviour so far.
    Method (INOS, 6, NotSerialized)
    {
        Local0 = XVWD (Arg1 + INPT, Ones)
        If (Arg2 != One && (Arg2 != 6 || Local0 != 6)) { Return (Zero - 92) } // ENOPROTOOPT
        If (Arg5 >> 31 || Arg5 < 4) { Return (Zero - 22) }
        Local1 = 4
        If (Arg2 == One && Arg3 == 13) // SO_LINGER
        {
            If (Arg5 < 8) { Return (Zero - 22) }
            Local1 = 8
        }
        XSTQ (XADR (INAL), Zero)
        If (!UCPY (Arg0, XADR (INAL), Arg4, Local1)) { Return (Zero - 14) }
        Local2 = ELWD (XADR (INAL), Zero, 4)
        If (Arg2 == One)
        {
            If (INBO (Arg3))
            {
                Local3 = XVWD (Arg1 + INOB, Ones) & ~(One << Arg3)
                If (Local2) { Local3 |= One << Arg3 }
                XSTQ (Arg1 + INOB, Local3)
                If (Arg3 == 9 && Local0 == 6) { TPKS (Arg1) } // SO_KEEPALIVE
                Return (Zero)
            }
            If (Arg3 == 7 || Arg3 == 8) // SO_SNDBUF, SO_RCVBUF: doubled and clamped like Linux
            {
                If (Local2 > 212992) { Local2 = 212992 }
                Local2 *= 2
                If (Arg3 == 7)
                {
                    If (Local2 < 4608) { Local2 = 4608 }
                    XSTQ (Arg1 + INSB, Local2)
                }
                Else
                {
                    If (Local2 < 2304) { Local2 = 2304 }
                    XSTQ (Arg1 + INRB, Local2)
                }
                Return (Zero)
            }
            If (Arg3 == 13)
            {
                Local3 = XVWD (Arg1 + INLG, Ones) & ~One
                If (Local2)
                {
                    Local3 = One | (ELWD (XADR (INAL), 4, 4) << 32)
                }
                XSTQ (Arg1 + INLG, Local3)
                Return (Zero)
            }
            Return (Zero - 92)
        }
        If (Arg3 == One) // TCP_NODELAY
        {
            Local3 = XVWD (Arg1 + INOB, Ones) & ~0x200000000
            If (Local2) { Local3 |= 0x200000000 }
            XSTQ (Arg1 + INOB, Local3)
            Return (Zero)
        }
        If (Arg3 == 2) // TCP_MAXSEG
        {
            If (Local2 < 88 || Local2 > 32767) { Return (Zero - 22) }
            XSTQ (Arg1 + INMS, Local2)
            Return (Zero)
        }
        If (Arg3 == 4 || Arg3 == 5) // TCP_KEEPIDLE, TCP_KEEPINTVL
        {
            If (!Local2 || Local2 > 32767) { Return (Zero - 22) }
            If (Arg3 == 4) { XSTQ (Arg1 + INKI, Local2) }
            Else { XSTQ (Arg1 + INKV, Local2) }
            Return (Zero)
        }
        If (Arg3 == 6) // TCP_KEEPCNT
        {
            If (!Local2 || Local2 > 127) { Return (Zero - 22) }
            XSTQ (Arg1 + INKC, Local2)
            Return (Zero)
        }
        If (Arg3 == 7) // TCP_SYNCNT
        {
            If (!Local2 || Local2 > 127) { Return (Zero - 22) }
            XSTQ (Arg1 + TBSC, Local2)
            Return (Zero)
        }
        If (Arg3 == 18) // TCP_USER_TIMEOUT in ms
        {
            If (Local2 >> 31) { Return (Zero - 22) }
            XSTQ (Arg1 + TBUT, Local2)
            Return (Zero)
        }
        If (Arg3 == 12 || Arg3 == 3) { Return (Zero) } // TCP_QUICKACK, TCP_CORK: accepted
        // This kernel's own debug switch: drop every Nth outgoing segment.
        If (Arg3 == 0x4E44)
        {
            XSTQ (Arg1 + TBDN, Local2)
            XSTQ (Arg1 + TBDC, Zero)
            Return (Zero)
        }
        Return (Zero - 92)
    }

    // True for the boolean SOL_SOCKET options kept in INOB: SO_REUSEADDR,
    // SO_DONTROUTE, SO_BROADCAST, SO_KEEPALIVE, SO_OOBINLINE, SO_REUSEPORT.
    Method (INBO, 1, NotSerialized)
    {
        If (Arg0 >= 16) { Return (Zero) }
        Return ((0x8664 >> Arg0) & One)
    }

    // getsockopt(Arg1, level Arg2, name Arg3, user Arg4, length at Arg5).
    // Like Linux, a short length truncates the value.
    Method (INOG, 6, NotSerialized)
    {
        Local0 = XVWD (Arg1 + INPT, Ones)
        If (Arg2 != One && (Arg2 != 6 || Local0 != 6)) { Return (Zero - 92) }
        If (!UCPY (Arg0, XADR (INAL), Arg5, 4) || !URNG (Arg0, Arg5, 4, WRIT)) { Return (Zero - 14) }
        Local1 = ELWD (XADR (INAL), Zero, 4)
        If (Local1 >> 31) { Return (Zero - 22) }
        Local2 = 4
        Local3 = Ones
        If (Arg2 == One)
        {
            If (Arg3 == 3) { Local3 = XVWD (Arg1 + INTY, Ones) } // SO_TYPE
            ElseIf (Arg3 == 4) // SO_ERROR, which it clears
            {
                Local3 = (Zero - XVWD (Arg1 + INER, Ones)) & 0xFFFFFFFF
                XSTQ (Arg1 + INER, Zero)
            }
            ElseIf (Arg3 == 39) { Local3 = 2 } // SO_DOMAIN
            ElseIf (Arg3 == 38) { Local3 = Local0 } // SO_PROTOCOL
            ElseIf (Arg3 == 30) // SO_ACCEPTCONN
            {
                Local3 = Zero
                If (Local0 == 6)
                {
                    If (XVWD (Arg1 + TBST, Ones) == One) { Local3 = One }
                }
            }
            ElseIf (INBO (Arg3))
            {
                Local3 = (XVWD (Arg1 + INOB, Ones) >> Arg3) & One
            }
            ElseIf (Arg3 == 7) // SO_SNDBUF
            {
                Local3 = XVWD (Arg1 + INSB, Ones)
                If (!Local3)
                {
                    Local3 = 212992
                    If (Local0 == 6) { Local3 = 16384 }
                }
            }
            ElseIf (Arg3 == 8) // SO_RCVBUF
            {
                Local3 = XVWD (Arg1 + INRB, Ones)
                If (!Local3)
                {
                    Local3 = 212992
                    If (Local0 == 6) { Local3 = 131072 }
                }
            }
            ElseIf (Arg3 == 13)
            {
                Local3 = XVWD (Arg1 + INLG, Ones)
                Local2 = 8
            }
            ElseIf (Arg3 == 18 || Arg3 == 19) { Local3 = One } // SO_RCVLOWAT, SO_SNDLOWAT
        }
        ElseIf (Arg3 == One) { Local3 = (XVWD (Arg1 + INOB, Ones) >> 33) & One }
        ElseIf (Arg3 == 2)
        {
            Local3 = XVWD (Arg1 + INMS, Ones)
            If (!Local3) { Local3 = 536 }
            If (XVWD (Arg1 + TBST, Ones) >= 4) { Local3 = XVWD (Arg1 + TBMS, Ones) }
        }
        ElseIf (Arg3 == 7)
        {
            Local3 = XVWD (Arg1 + TBSC, Ones)
            If (!Local3) { Local3 = 6 }
        }
        ElseIf (Arg3 == 18) { Local3 = XVWD (Arg1 + TBUT, Ones) }
        ElseIf (Arg3 == 0x4E44) { Local3 = XVWD (Arg1 + TBDS, Ones) } // drops done
        ElseIf (Arg3 == 0x4E45) { Local3 = XVWD (Arg1 + TBPC, Ones) } // persist probes
        ElseIf (Arg3 == 4)
        {
            Local3 = XVWD (Arg1 + INKI, Ones)
            If (!Local3) { Local3 = 7200 }
        }
        ElseIf (Arg3 == 5)
        {
            Local3 = XVWD (Arg1 + INKV, Ones)
            If (!Local3) { Local3 = 75 }
        }
        ElseIf (Arg3 == 6)
        {
            Local3 = XVWD (Arg1 + INKC, Ones)
            If (!Local3) { Local3 = 9 }
        }
        If (Local3 == Ones) { Return (Zero - 92) }
        If (Local1 > Local2) { Local1 = Local2 }
        XSTQ (XADR (INAL), Local3)
        If (Local1 && !UCOP (Arg0, Arg4, XADR (INAL), Local1)) { Return (Zero - 14) }
        XSTQ (XADR (INAL), Local1)
        If (!UCOP (Arg0, Arg5, XADR (INAL), 4)) { Return (Zero - 14) }
        Return (Zero)
    }

    // ioctl Arg2 with argument Arg3 on AF_INET description Arg1.
    Method (INIC, 4, NotSerialized)
    {
        If (Arg2 == 0x5421) // FIONBIO
        {
            If (!UCPY (Arg0, XADR (INAL), Arg3, 4)) { Return (Zero - 14) }
            Local0 = Zero
            If (ELWD (XADR (INAL), Zero, 4)) { Local0 = 0x800 }
            XSTQ (Arg1 + SKFL, Local0)
            SKCH = One
            Return (Zero)
        }
        If (Arg2 == 0x541B || Arg2 == 0x5411) // FIONREAD (SIOCINQ), SIOCOUTQ
        {
            // A datagram socket reports the next datagram's length and has
            // nothing waiting to be sent; a stream its unread and unacknowledged
            // bytes.
            Local0 = Zero
            If (XVWD (Arg1 + INTY, Ones) == One)
            {
                If (XVWD (Arg1 + TBST, Ones) == One) { Return (Zero - 22) }
                Local0 = XVWD (Arg1 + TBSL, Ones)
                If (Arg2 == 0x541B) { Local0 = XVWD (Arg1 + TBRL, Ones) }
            }
            ElseIf (Arg2 == 0x541B)
            {
                Local1 = XVWD (Arg1 + INQH, Ones)
                If (Local1) { Local0 = XVWD (Local1 + 24, Ones) }
            }
            XSTQ (XADR (INAL), Local0)
            If (!UCOP (Arg0, Arg3, XADR (INAL), 4)) { Return (Zero - 14) }
            Return (Zero)
        }
        Return (NIFI (Arg0, Arg2, Arg3))
    }
