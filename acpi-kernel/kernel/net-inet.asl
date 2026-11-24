    // IPv4, ICMP and UDP. Frames are Ethernet (14 bytes), then the IPv4
    // header. Outgoing headers are always 20 bytes, so a frame's payload
    // starts at +34. Packets to our own addresses never reach the NIC: NOBF
    // gives them a buffer of their own and NIPO queues it on lo (NLOX), whose
    // MTU of 65536 fits any datagram. eth0's MTU is 1500: bigger datagrams
    // are built in NFSB and sent as fragments, and fragments that arrive are
    // reassembled (NIPF) before anything else looks at them.
    Name (NMSK, 0xFFFFFF00) // on-link 10.0.2.0/24
    Name (NDNS, 0x0A000203) // 10.0.2.3
    Name (NIPD, Zero)       // IP identification counter
    Name (NICN, Zero)       // echo requests answered
    Name (NUNS, Zero)       // ICMP port unreachables sent
    Name (NIER, Zero)       // ICMP errors received
    Name (NIEC, Zero)       // last error: type << 8 | code
    Name (NIEQ, Zero)       // last error's quoted datagram: protocol << 32 | dst
    Name (NPID, 0x4143)     // identifier of the kernel's echo requests
    Name (NPSQ, Zero)       // sequence number of the outstanding request
    Name (NPTS, Zero)       // MNOW when it was sent
    Name (NPRT, Zero)       // MNOW when its reply arrived, zero until then
    Name (NLQH, Zero)       // lo queue of NOBF buffers, linked through their +0
    Name (NLQT, Zero)
    Name (NLBY, Zero)       // Set while the lo queue is being drained
    Name (NLPK, Zero)       // lo packets (each is both sent and received)
    Name (NLBT, Zero)       // lo bytes, a 14-byte Ethernet header included
    Name (NFSB, Zero)       // Frame buffer for datagrams that will be fragmented
    Name (NFRG, Zero)       // Fragments sent
    Name (NRAS, Zero)       // Datagrams reassembled
    Name (NRAF, Zero)       // Reassemblies that failed or timed out
    // Reassembly contexts, NRQN of NRQZ bytes in NRQT:
    //   +0  source, zero when free   +8  destination
    //   +16 protocol << 16 | identification
    //   +24 buffer: an 8-byte-unit bitmap of 1 KiB, then the data at NRQD
    //   +32 units received           +40 data length once the last fragment came, else Ones
    //   +48 MNOW deadline            +56 header length once the first fragment came
    //   +64 set if from lo           +72 highest end of any fragment so far
    Name (NRQT, Zero)
    Name (NRQN, 8)
    Name (NRQZ, 80)
    Name (NRQD, 1152)       // data offset; the first fragment's header ends here
    Name (NRQS, 66688)      // buffer size: NRQD + 65536

    // True for our own addresses: 127.0.0.0/8, and eth0's while it is up.
    Method (NLOC, 1, NotSerialized)
    {
        If ((Arg0 >> 24) == 127) { Return (One) }
        If (NBAR && Arg0 == NIPA) { Return (One) }
        Return (Zero)
    }

    // Source address for a packet to Arg0 from an unbound socket.
    Method (NSRC, 1, NotSerialized)
    {
        If ((Arg0 >> 24) == 127) { Return (0x7F000001) }
        Return (NIPA)
    }

    // Frame buffer for a packet carrying Arg1 bytes of IP payload to Arg0,
    // filled from +34 and handed to NIPO, which consumes it. A local
    // destination gets a buffer of its own: a page, or contiguous pages for
    // a large datagram, with 32 bytes before the frame for the lo queue link
    // (+0), the allocation size (+8) and the frame length (+16). Otherwise a
    // TX buffer, or NFSB when the packet needs fragments. Zero if none is
    // available or the packet cannot fit in one datagram.
    Method (NOBF, 2, NotSerialized)
    {
        If (Arg1 > 65515) { Return (Zero) }
        If (NLOC (Arg0))
        {
            Local1 = Arg1 + 66
            If (Local1 <= PGSZ)
            {
                Local0 = PALC ()
                If (!Local0) { Return (Zero) }
                Local0 += HHDO
            }
            Else
            {
                Local0 = VALL (Local1, WRIT)
                If (!Local0) { Return (Zero) }
            }
            XSTQ (Local0 + 8, Local1)
            Return (Local0 + 32)
        }
        If (Arg1 <= 1480) { Return (NTXA ()) }
        If (!NBAR) { Return (Zero) }
        If (!NFSB)
        {
            NFSB = VALL (65536 + 32, WRIT)
            If (!NFSB) { Return (Zero) }
        }
        Return (NFSB + 32)
    }

    // Abandon NOBF buffer Arg0 for Arg1 without sending it. TX buffers and
    // NFSB are simply reused; a local buffer is freed.
    Method (NOAB, 2, NotSerialized)
    {
        If (NLOC (Arg1)) { NOFR (Arg0) }
    }

    Method (NOFR, 1, NotSerialized)
    {
        Local0 = Arg0 - 32
        Local1 = XLDQ (Local0 + 8)
        If (Local1 <= PGSZ) { PDEL (Local0 - HHDO) }
        Else { VUNM (Local0, Local1) }
    }

    // Queue local NOBF buffer Arg0 holding an Arg1-byte frame on lo and
    // deliver it. Delivery can send more (an echo reply, a port unreachable,
    // later TCP segments); those join the queue and the outermost call
    // delivers them in order, so nothing recurses.
    Method (NLOX, 2, NotSerialized)
    {
        XSTQ (Arg0, Zero)
        XSTQ (Arg0 + 4, Zero)
        NB16 (Arg0 + 12, 0x0800)
        Local1 = Arg0 - 32
        XSTQ (Local1, Zero)
        XSTQ (Local1 + 16, Arg1)
        Increment (NLPK)
        NLBT += Arg1
        If (NLQT) { XSTQ (NLQT, Local1) }
        Else { NLQH = Local1 }
        NLQT = Local1
        If (NLBY) { Return () }
        NLBY = One
        // ACKs TCP holds for the end of a batch go out once the queue is empty.
        While (NLQH || TPFP)
        {
            If (!NLQH)
            {
                TPFL ()
                Continue
            }
            Local0 = NLQH
            NLQH = XLDQ (Local0)
            If (!NLQH) { NLQT = Zero }
            NIPV (Local0 + 32, XLDQ (Local0 + 16), One)
            NOFR (Local0 + 32)
        }
        NLBY = Zero
    }

    // Value of the Internet checksum field for Arg1 bytes at Arg0 whose
    // field is zero, starting from partial sum Arg2.
    Method (NCSM, 3, NotSerialized)
    {
        Return (~XCSM (Arg0, Arg1, Arg2) & 0xFFFF)
    }

    // Partial sum of the TCP/UDP pseudo header.
    Method (NPSH, 4, NotSerialized)
    {
        Return ((Arg0 >> 16) + (Arg0 & 0xFFFF) + (Arg1 >> 16) +
            (Arg1 & 0xFFFF) + Arg2 + Arg3)
    }

    Method (NBRD, 1, NotSerialized)
    {
        Return (Arg0 == 0xFFFFFFFF || Arg0 == (NIPA | (~NMSK & 0xFFFFFFFF)))
    }

    // Send NOBF frame Arg2 carrying Arg3 bytes of protocol Arg1 at +34 from
    // Arg4 to Arg0. Local destinations go to lo, off-link ones through the
    // gateway. A datagram that fits in one frame has DF set, like Linux's
    // default IP_PMTUDISC_WANT; a bigger one goes out in fragments.
    Method (NIPO, 5, NotSerialized)
    {
        Local0 = Arg2 + 14
        XSTB (Local0, 0x45)
        XSTB (Local0 + One, Zero)
        NB16 (Local0 + 2, Arg3 + 20)
        NB16 (Local0 + 4, NIPD)
        NIPD = (NIPD + One) & 0xFFFF
        NB16 (Local0 + 6, 0x4000) // DF
        XSTB (Local0 + 8, 64)
        XSTB (Local0 + 9, Arg1)
        NB16 (Local0 + 10, Zero)
        NB32 (Local0 + 12, Arg4)
        NB32 (Local0 + 16, Arg0)
        If (NLOC (Arg0))
        {
            NB16 (Local0 + 10, NCSM (Local0, 20, Zero))
            NLOX (Arg2, Arg3 + 34)
            Return (One)
        }
        If (Arg3 > 1480) { Return (NIPG (Arg0, Arg2, Arg3)) }
        NB16 (Local0 + 10, NCSM (Local0, 20, Zero))
        Return (NIPW (Arg0, Arg2, Arg3 + 20))
    }

    // Put IPv4 frame Arg1 of Arg2 bytes (header included) to non-local Arg0
    // on the wire: broadcast, on-link, or through the gateway.
    Method (NIPW, 3, NotSerialized)
    {
        If (NBRD (Arg0))
        {
            NEHD (Arg1, 0xFFFFFFFFFFFF, 0x0800)
            NTXP (Arg2 + 14)
            Return (One)
        }
        Local1 = Arg0
        If ((Arg0 & NMSK) != (NIPA & NMSK)) { Local1 = NGWA }
        Return (NETX (Local1, 0x0800, Arg1, Arg2))
    }

    // Send the datagram NIPO built in NFSB frame Arg1, with Arg2 bytes of
    // payload, to Arg0 as fragments of up to 1480 bytes in TX buffers.
    Method (NIPG, 3, NotSerialized)
    {
        Local0 = Arg1 + 14
        Local1 = Zero
        While (Local1 < Arg2)
        {
            Local2 = Arg2 - Local1
            Local3 = Zero
            If (Local2 > 1480)
            {
                Local2 = 1480
                Local3 = 0x2000 // MF
            }
            Local4 = NTXA ()
            If (!Local4) { Return (Zero) }
            Local5 = Local4 + 14
            XMOV (Local5, Local0, 20)
            XMOV (Local5 + 20, Local0 + 20 + Local1, Local2)
            NB16 (Local5 + 2, Local2 + 20)
            NB16 (Local5 + 6, Local3 | (Local1 >> 3))
            NB16 (Local5 + 10, NCSM (Local5, 20, Zero))
            If (!NIPW (Arg0, Local4, Local2 + 20)) { Return (Zero) }
            Increment (NFRG)
            Local1 += Local2
        }
        Return (One)
    }

    // Received IPv4 frame Arg0 of Arg1 bytes, from lo if Arg2 is set.
    Method (NIPV, 3, NotSerialized)
    {
        If (Arg1 < 34) { Return () }
        Local0 = Arg0 + 14
        Local1 = XBYT (Local0)
        If ((Local1 >> 4) != 4) { Return () }
        Local1 = (Local1 & 0xF) * 4
        If (Local1 < 20) { Return () }
        Local2 = NL16 (Local0 + 2)
        If (Local2 < Local1 || Local2 > Arg1 - 14) { Return () }
        If (XCSM (Local0, Local1, Zero) != 0xFFFF) { Return () }
        Local3 = NL32 (Local0 + 16)
        Local4 = NL32 (Local0 + 12)
        If (Arg2)
        {
            If (!NLOC (Local3)) { Return () }
        }
        Else
        {
            If (Local3 != NIPA && !NBRD (Local3)) { Return () }
        }
        If (!Local4 || NBRD (Local4) || (Local4 >> 28) == 0xE) { Return () }
        Local5 = XBYT (Local0 + 9)
        // A loopback source from the wire is a martian, except that slirp
        // relays the host's ICMP errors from 127.0.0.1. Those only reach the
        // socket their quoted datagram came from.
        If (!Arg2 && (Local4 >> 24) == 127 && Local5 != One) { Return () }
        If (NL16 (Local0 + 6) & 0x3FFF) // MF or an offset
        {
            NIPF (Local0, Local1, Local2, Arg2)
            Return ()
        }
        If (Local5 == One) { NICI (Local0, Local1, Local2, Local4, Local3) }
        ElseIf (Local5 == 17) { NUDI (Local0, Local1, Local2, Local4, Local3) }
        ElseIf (Local5 == 6) { TPIN (Local0, Local1, Local2, Local4, Local3) }
    }

    // Fragment with IPv4 header Arg0 (Arg1 bytes, Arg2 in total), from lo if
    // Arg3 is set. Its data is copied to the context for its datagram; when
    // every 8-byte unit up to the last fragment's end is there, the datagram
    // goes through NIPV as if it had arrived whole. Overlaps keep the later
    // data, as on Linux.
    Method (NIPF, 4, NotSerialized)
    {
        Local0 = NL16 (Arg0 + 6)
        Local1 = (Local0 & 0x1FFF) * 8 // offset
        Local2 = Arg2 - Arg1            // length
        Local3 = Local0 & 0x2000        // more fragments
        If (!Local2 || Local1 + Local2 + Arg1 > 65535) { Return () }
        If (Local3 && (Local2 & 7)) { Return () }
        Local4 = NRQF (NL32 (Arg0 + 12), NL32 (Arg0 + 16),
            (XBYT (Arg0 + 9) << 16) | NL16 (Arg0 + 4), Arg3)
        If (!Local4) { Return () }
        Local5 = Local1 + Local2 // end
        Local6 = XLDQ (Local4 + 40)
        // The last fragment fixes the length, which must hold everything.
        If (!Local3)
        {
            If ((Local6 != Ones && Local6 != Local5) || XLDQ (Local4 + 72) > Local5)
            {
                NRQK (Local4, Zero)
                Return ()
            }
            XSTQ (Local4 + 40, Local5)
        }
        ElseIf (Local6 != Ones && Local5 > Local6)
        {
            NRQK (Local4, Zero)
            Return ()
        }
        If (Local5 > XLDQ (Local4 + 72)) { XSTQ (Local4 + 72, Local5) }
        Local7 = XLDQ (Local4 + 24)
        If (!Local1)
        {
            XMOV (Local7 + NRQD - Arg1, Arg0, Arg1)
            XSTQ (Local4 + 56, Arg1)
        }
        XMOV (Local7 + NRQD + Local1, Arg0 + Arg1, Local2)
        // Count the units this fragment adds.
        Local0 = Local1 >> 3
        Local5 = (Local5 + 7) >> 3
        Local6 = Zero
        While (Local0 < Local5)
        {
            If (!(Local0 & 7) && Local0 + 8 <= Local5 && !XBYT (Local7 + (Local0 >> 3)))
            {
                XSTB (Local7 + (Local0 >> 3), 0xFF)
                Local6 += 8
                Local0 += 8
                Continue
            }
            Local1 = One << (Local0 & 7)
            Local2 = XBYT (Local7 + (Local0 >> 3))
            If (!(Local2 & Local1))
            {
                XSTB (Local7 + (Local0 >> 3), Local2 | Local1)
                Increment (Local6)
            }
            Increment (Local0)
        }
        Local6 += XLDQ (Local4 + 32)
        XSTQ (Local4 + 32, Local6)
        Local5 = XLDQ (Local4 + 40)
        If (Local5 == Ones || !XLDQ (Local4 + 56) || Local6 != (Local5 + 7) / 8) { Return () }
        // Complete: rebuild the header in front of the data and deliver.
        Local1 = XLDQ (Local4 + 56)
        Local0 = Local7 + NRQD - Local1
        NB16 (Local0 + 2, Local1 + Local5)
        NB16 (Local0 + 6, Zero)
        NB16 (Local0 + 10, Zero)
        NB16 (Local0 + 10, NCSM (Local0, Local1, Zero))
        Local2 = XLDQ (Local4 + 64)
        XSTQ (Local4, Zero)
        Increment (NRAS)
        NIPV (Local0 - 14, Local1 + Local5 + 14, Local2)
        VUNM (Local7, NRQS)
    }

    // Reassembly context for source Arg0, destination Arg1 and protocol and
    // identification Arg2, created (from lo if Arg3) when there is none. A
    // new one evicts the oldest when all are busy. Zero if out of memory.
    Method (NRQF, 4, NotSerialized)
    {
        If (!NRQT)
        {
            Local0 = PALC ()
            If (!Local0) { Return (Zero) }
            NRQT = Local0 + HHDO
            XCLR (NRQT)
        }
        Local0 = Zero
        Local1 = Zero
        Local2 = Zero
        While (Local0 < NRQN)
        {
            Local3 = NRQT + Local0 * NRQZ
            If (XLDQ (Local3))
            {
                If (XLDQ (Local3) == Arg0 && XLDQ (Local3 + 8) == Arg1 &&
                    XLDQ (Local3 + 16) == Arg2)
                {
                    Return (Local3)
                }
                If (!Local2 || XLDQ (Local3 + 48) < XLDQ (Local2 + 48)) { Local2 = Local3 }
            }
            ElseIf (!Local1) { Local1 = Local3 }
            Increment (Local0)
        }
        If (!Local1)
        {
            NRQK (Local2, Zero)
            Local1 = Local2
        }
        Local0 = VALL (NRQS, WRIT)
        If (!Local0) { Return (Zero) }
        XSTQ (Local1, Arg0)
        XSTQ (Local1 + 8, Arg1)
        XSTQ (Local1 + 16, Arg2)
        XSTQ (Local1 + 24, Local0)
        XSTQ (Local1 + 32, Zero)
        XSTQ (Local1 + 40, Ones)
        Local2 = MNOW () + 30000000000 // ipfrag_time
        XSTQ (Local1 + 48, Local2)
        XSTQ (Local1 + 56, Zero)
        XSTQ (Local1 + 64, Arg3)
        XSTQ (Local1 + 72, Zero)
        NTIM (Local2)
        Return (Local1)
    }

    // Give up on reassembly context Arg0. With Arg1 set and the first
    // fragment present, tell the sender its time ran out, like Linux.
    Method (NRQK, 2, NotSerialized)
    {
        Local0 = XLDQ (Arg0 + 24)
        Local1 = XLDQ (Arg0 + 56)
        XSTQ (Arg0, Zero)
        Increment (NRAF)
        If (Arg1 && Local1) { NICU (Local0 + NRQD - Local1, Local1, 11, One) }
        VUNM (Local0, NRQS)
    }

    // Expire reassemblies whose 30 s are up at MNOW Arg0 and rearm the timer
    // for the rest.
    Method (NRQX, 1, NotSerialized)
    {
        If (!NRQT) { Return () }
        Local0 = Zero
        While (Local0 < NRQN)
        {
            Local1 = NRQT + Local0 * NRQZ
            If (XLDQ (Local1))
            {
                If (Arg0 >= XLDQ (Local1 + 48)) { NRQK (Local1, One) }
                Else { NTIM (XLDQ (Local1 + 48)) }
            }
            Increment (Local0)
        }
    }

    // ICMP in IPv4 header Arg0 (Arg1 bytes, Arg2 in total) from Arg3 to Arg4.
    Method (NICI, 5, NotSerialized)
    {
        Local0 = Arg0 + Arg1
        Local1 = Arg2 - Arg1
        If (Local1 < 8 || XCSM (Local0, Local1, Zero) != 0xFFFF) { Return () }
        Local2 = XBYT (Local0)
        If (Local2 == 8)
        {
            // Echo request: answer unicast ones with the same data.
            If (!NLOC (Arg4)) { Return () }
            Local3 = NOBF (Arg3, Local1)
            If (!Local3) { Return () }
            XMOV (Local3 + 34, Local0, Local1)
            XSTB (Local3 + 34, Zero)
            NB16 (Local3 + 36, Zero)
            NB16 (Local3 + 36, NCSM (Local3 + 34, Local1, Zero))
            NIPO (Arg3, One, Local3, Local1, Arg4)
            Increment (NICN)
        }
        ElseIf (Local2 == Zero)
        {
            If (NL16 (Local0 + 4) == NPID && NL16 (Local0 + 6) == NPSQ && !NPRT)
            {
                NPRT = MNOW ()
            }
        }
        ElseIf (Local2 == 3 || Local2 == 11)
        {
            // Destination unreachable or time exceeded, quoting our header
            // and at least 8 bytes of its payload. Connected UDP sockets get
            // hard unreachable errors through INIE.
            If (Local1 < 36 || !NLOC (NL32 (Local0 + 20))) { Return () }
            Increment (NIER)
            NIEC = (Local2 << 8) | XBYT (Local0 + One)
            NIEQ = (XBYT (Local0 + 17) << 32) | NL32 (Local0 + 24)
            If (Local2 == 3) { INIE (Local0 + 8, Local1 - 8, XBYT (Local0 + One)) }
        }
    }

    // UDP in IPv4 header Arg0 (Arg1 bytes, Arg2 in total) from Arg3 to Arg4.
    Method (NUDI, 5, NotSerialized)
    {
        Local0 = Arg0 + Arg1
        If (Arg2 - Arg1 < 8) { Return () }
        Local1 = NL16 (Local0 + 4)
        If (Local1 < 8 || Local1 > Arg2 - Arg1) { Return () }
        If (NL16 (Local0 + 6) &&
            XCSM (Local0, Local1, NPSH (Arg3, Arg4, 17, Local1)) != 0xFFFF)
        {
            Return ()
        }
        Local2 = NL16 (Local0)
        Local3 = INUL (Arg4, NL16 (Local0 + 2), Arg3, Local2)
        If (Local3) { INEN (Local3, Arg3, Local2, Local0 + 8, Local1 - 8) }
        ElseIf (NLOC (Arg4)) { NICU (Arg0, Arg1, 3, 3) } // Port unreachable
    }

    // Send ICMP error type Arg2 code Arg3 about the datagram whose Arg1-byte
    // header is at Arg0, quoting that header and 8 bytes of its payload. The
    // error comes from the address the datagram was sent to.
    Method (NICU, 4, NotSerialized)
    {
        Local1 = Arg1 + 8
        Local0 = NOBF (NL32 (Arg0 + 12), Local1 + 8)
        If (!Local0) { Return () }
        XSTB (Local0 + 34, Arg2)
        XSTB (Local0 + 35, Arg3)
        NB16 (Local0 + 36, Zero)
        NB32 (Local0 + 38, Zero)
        XMOV (Local0 + 42, Arg0, Local1)
        NB16 (Local0 + 36, NCSM (Local0 + 34, Local1 + 8, Zero))
        NIPO (NL32 (Arg0 + 12), One, Local0, Local1 + 8, NL32 (Arg0 + 16))
        Increment (NUNS)
    }

    // Send Arg4 bytes of UDP data, already at Arg3 + 42 in a NOBF frame,
    // from Arg5 port Arg1 to Arg0 port Arg2.
    Method (NUDO, 6, NotSerialized)
    {
        Local0 = Arg3 + 34
        NB16 (Local0, Arg1)
        NB16 (Local0 + 2, Arg2)
        NB16 (Local0 + 4, Arg4 + 8)
        NB16 (Local0 + 6, Zero)
        Local1 = NCSM (Local0, Arg4 + 8, NPSH (Arg5, Arg0, 17, Arg4 + 8))
        If (!Local1) { Local1 = 0xFFFF }
        NB16 (Local0 + 6, Local1)
        Return (NIPO (Arg0, 17, Arg3, Arg4 + 8, Arg5))
    }

    // Send echo request Arg1 with 56 bytes of data to Arg0.
    Method (NPNG, 2, NotSerialized)
    {
        Local0 = NOBF (Arg0, 64)
        If (!Local0) { Return (Zero) }
        Local1 = Local0 + 34
        XSTB (Local1, 8)
        XSTB (Local1 + One, Zero)
        NB16 (Local1 + 2, Zero)
        NB16 (Local1 + 4, NPID)
        NB16 (Local1 + 6, Arg1)
        Local2 = Zero
        While (Local2 < 56)
        {
            XSTB (Local1 + 8 + Local2, Local2)
            Increment (Local2)
        }
        NB16 (Local1 + 2, NCSM (Local1, 64, Zero))
        NPSQ = Arg1
        NPRT = Zero
        NPTS = MNOW ()
        Return (NIPO (Arg0, One, Local0, 64, NSRC (Arg0)))
    }

    Method (PDEC, 1, NotSerialized)
    {
        Local0 = 1000000000000000000
        Local1 = Arg0
        While (Local0 > One && Local0 > Local1) { Local0 /= 10 }
        While (Local0)
        {
            PUTC (0x30 + (Local1 / Local0))
            Local1 %= Local0
            Local0 /= 10
        }
    }

    // Wait for one interrupt on the BSP during boot and dispatch it.
    Method (NWT1, 0, NotSerialized)
    {
        Local0 = XWAI (10000000)
        TACK (Local0)
        // Comparisons yield Ones; callers add this up.
        If (Local0 == NIVC) { Return (One) }
        Return (Zero)
    }

    // Ping Arg0 with sequence Arg1 and log the round trip. Returns the
    // number of NIVC interrupts seen while waiting, zero on a timeout.
    Method (NPWT, 2, NotSerialized)
    {
        If (!NPNG (Arg0, Arg1)) { Return (Zero) }
        Local0 = 300
        Local1 = Zero
        While (!NPRT && Local0)
        {
            Local1 += NWT1 ()
            Decrement (Local0)
        }
        If (!NPRT) { Return (Zero) }
        PUTT ("virtio-net ping ")
        PDEC (Arg0 >> 24)
        PUTC (0x2E)
        PDEC ((Arg0 >> 16) & 0xFF)
        PUTC (0x2E)
        PDEC ((Arg0 >> 8) & 0xFF)
        PUTC (0x2E)
        PDEC (Arg0 & 0xFF)
        PUTT (" seq=")
        PDEC (Arg1)
        PUTT (" time=")
        PDEC ((NPRT - NPTS) / 1000)
        PUTS (" us")
        Return (Local1 + One)
    }

    // Feed a frame from the gateway into the receive path, as if it had
    // arrived: an echo request, or with Arg0 set a UDP datagram to port 7.
    Method (NIJT, 1, NotSerialized)
    {
        Local0 = PALC ()
        If (!Local0) { Return () }
        Local0 += HHDO
        XCLR (Local0)
        NSMC (Local0, NMAC)
        NSMC (Local0 + 6, NRES (NGWA))
        NB16 (Local0 + 12, 0x0800)
        Local1 = Local0 + 14
        XSTB (Local1, 0x45)
        NB16 (Local1 + 2, 48)
        NB16 (Local1 + 4, 0x1234)
        XSTB (Local1 + 8, 64)
        NB32 (Local1 + 12, NGWA)
        NB32 (Local1 + 16, NIPA)
        Local2 = Local1 + 20
        If (Arg0)
        {
            XSTB (Local1 + 9, 17)
            NB16 (Local2, 40000)
            NB16 (Local2 + 2, 7)
            NB16 (Local2 + 4, 28)
            NB16 (Local2 + 6, NCSM (Local2, 28, NPSH (NGWA, NIPA, 17, 28)))
        }
        Else
        {
            XSTB (Local1 + 9, One)
            XSTB (Local2, 8)
            NB16 (Local2 + 4, 0x5A5A)
            NB16 (Local2 + 6, One)
            NB16 (Local2 + 2, NCSM (Local2, 28, Zero))
        }
        NB16 (Local1 + 10, NCSM (Local1, 20, Zero))
        NETH (Local0, 62)
        PDEL (Local0 - HHDO)
    }

    // Feed fragments of a 3000-byte UDP datagram from the gateway to closed
    // port 7, out of order and with a duplicate, so that only a correct
    // reassembly passes the UDP checksum and draws a port unreachable.
    Method (NIJR, 0, NotSerialized)
    {
        Local0 = PALC ()
        If (!Local0) { Return () }
        Local0 += HHDO
        Local1 = Zero
        While (Local1 < 3000)
        {
            XSTB (Local0 + Local1, Local1 ^ (Local1 >> 8))
            Increment (Local1)
        }
        NB16 (Local0, 40002)
        NB16 (Local0 + 2, 7)
        NB16 (Local0 + 4, 3000)
        NB16 (Local0 + 6, Zero)
        NB16 (Local0 + 6, NCSM (Local0, 3000, NPSH (NGWA, NIPA, 17, 3000)))
        NIJF (Local0, 2960, 40, Zero)
        NIJF (Local0, 1480, 1480, One)
        NIJF (Local0, 1480, 1480, One)
        NIJF (Local0, Zero, 1480, One)
        PDEL (Local0 - HHDO)
    }

    // Inject the Arg2 bytes at offset Arg1 of datagram Arg0 as a fragment,
    // with MF if Arg3 is set.
    Method (NIJF, 4, NotSerialized)
    {
        Local0 = PALC ()
        If (!Local0) { Return () }
        Local0 += HHDO
        XCLR (Local0)
        NSMC (Local0, NMAC)
        NSMC (Local0 + 6, NRES (NGWA))
        NB16 (Local0 + 12, 0x0800)
        Local1 = Local0 + 14
        XSTB (Local1, 0x45)
        NB16 (Local1 + 2, Arg2 + 20)
        NB16 (Local1 + 4, 0x4321)
        NB16 (Local1 + 6, (Arg3 << 13) | (Arg1 >> 3))
        XSTB (Local1 + 8, 64)
        XSTB (Local1 + 9, 17)
        NB32 (Local1 + 12, NGWA)
        NB32 (Local1 + 16, NIPA)
        NB16 (Local1 + 10, NCSM (Local1, 20, Zero))
        XMOV (Local1 + 20, Arg0 + Arg1, Arg2)
        NETH (Local0, Arg2 + 34)
        PDEL (Local0 - HHDO)
    }

    // Boot self-test, all of it driven by the MSI-X vector: resolve the
    // gateway, ping the DNS address unresolved (its request waits in the
    // ARP queue) and the gateway, answer injected ICMP and UDP, and receive
    // an ICMP error for our own UDP datagram.
    Method (NTST, 0, NotSerialized)
    {
        Local0 = NANW (NGWA)
        Local1 = XTSC ()
        NARQ (Local0)
        Local2 = 100
        Local4 = Zero
        While (!NRES (NGWA) && Local2)
        {
            Local4 += NWT1 ()
            Decrement (Local2)
        }
        If (!Local4) { Return (NVFL ("no MSI-X interrupt for ARP reply")) }
        Local3 = NRES (NGWA)
        If (!Local3) { Return (NVFL ("gateway did not answer ARP")) }
        PNUM ("virtio-net ARP round trip TSC=0x", XTSC () - Local1)
        PUTS ("")
        PUTT ("virtio-net gateway 10.0.2.2 is ")
        PMAC (Local3)
        PUTS ("")
        If (NRES (NDNS)) { Return (NVFL ("10.0.2.3 resolved before its ping")) }
        If (!NPWT (NDNS, One)) { Return (NVFL ("no echo reply from 10.0.2.3")) }
        If (!NPWT (NGWA, 2)) { Return (NVFL ("no echo reply from 10.0.2.2")) }
        NIJT (Zero)
        NIJT (One)
        If (NICN != One || NUNS != One)
        {
            Return (NVFL ("injected echo request or UDP datagram unanswered"))
        }
        PUTS ("virtio-net answered an echo request and a closed UDP port")
        NIJR ()
        If (NRAS != One || NUNS != 2)
        {
            Return (NVFL ("out-of-order fragments were not reassembled"))
        }
        PUTS ("virtio-net reassembled out-of-order fragments")
        // slirp relays the host's port unreachable for the discard port,
        // which is closed on any ordinary host.
        Local5 = NTXA ()
        If (!Local5 || !NUDO (NGWA, 40001, 9, Local5, 4, NIPA)) { Return (NVFL ("UDP send failed")) }
        Local2 = 100
        While (!NIER && Local2)
        {
            NWT1 ()
            Decrement (Local2)
        }
        If (NIEC != 0x303 || NIEQ != ((17 << 32) | NGWA))
        {
            Return (NVFL ("no port unreachable for UDP to 10.0.2.2:9"))
        }
        PUTS ("virtio-net UDP to 10.0.2.2:9 got port unreachable")
        Return (One)
    }
