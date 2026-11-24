    // Ethernet and ARP. IPv4, ICMP and UDP are in net-inet.asl.

    // ARP cache: NACN entries of 64 bytes in one page.
    //   +0  IPv4 address (zero: free)
    //   +8  station address, or zero while unresolved
    //   +16 MNOW deadline: expiry when resolved, next retry otherwise
    //   +24 requests sent while unresolved
    //   +32 frames queued while unresolved
    //   +40 first queued frame page (link at +4080, length at +4088)
    //   +48 last queued frame page
    // Up to NAQM frames wait, the oldest dropped first: enough for every
    // fragment of a 64 KiB datagram.
    Name (NARC, Zero)
    Name (NACN, 8)
    Name (NAQM, 64)
    Name (NATO, 60000000000) // resolved entries live 60 s

    Method (NARI, 0, NotSerialized)
    {
        Local0 = PALC ()
        If (!Local0) { Return (Zero) }
        NARC = Local0 + HHDO
        XCLR (NARC)
        Return (One)
    }

    Method (NAFN, 1, NotSerialized)
    {
        Local0 = Zero
        While (Local0 < NACN)
        {
            Local1 = NARC + Local0 * 64
            If (XLDQ (Local1) == Arg0) { Return (Local1) }
            Increment (Local0)
        }
        Return (Zero)
    }

    // Find or create the entry for Arg0, evicting the earliest deadline.
    Method (NANW, 1, NotSerialized)
    {
        Local1 = NAFN (Arg0)
        If (Local1) { Return (Local1) }
        Local0 = Zero
        Local1 = NARC
        While (Local0 < NACN)
        {
            Local2 = NARC + Local0 * 64
            If (!XLDQ (Local2))
            {
                Local1 = Local2
                Break
            }
            If (XLDQ (Local2 + 16) < XLDQ (Local1 + 16)) { Local1 = Local2 }
            Increment (Local0)
        }
        NAQF (Local1)
        XSTQ (Local1, Arg0)
        XSTQ (Local1 + 8, Zero)
        XSTQ (Local1 + 16, Zero)
        XSTQ (Local1 + 24, Zero)
        Return (Local1)
    }

    // Drop the frames queued on entry Arg0.
    Method (NAQF, 1, NotSerialized)
    {
        While (XLDQ (Arg0 + 40))
        {
            Local0 = XLDQ (Arg0 + 40)
            XSTQ (Arg0 + 40, XLDQ (Local0 + 4080))
            PDEL (Local0 - HHDO)
        }
        XSTQ (Arg0 + 32, Zero)
        XSTQ (Arg0 + 48, Zero)
    }

    // Station address for Arg0 if resolved and fresh, otherwise zero.
    Method (NRES, 1, NotSerialized)
    {
        // LOr evaluates both operands, so test the entry first.
        Local0 = NAFN (Arg0)
        If (!Local0) { Return (Zero) }
        If (MNOW () >= XLDQ (Local0 + 16)) { Return (Zero) }
        Return (XLDQ (Local0 + 8))
    }

    // Fill an Ethernet header at Arg0.
    Method (NEHD, 3, NotSerialized)
    {
        NSMC (Arg0, Arg1)
        NSMC (Arg0 + 6, NMAC)
        NB16 (Arg0 + 12, Arg2)
    }

    // Build ARP operation Arg1 in TX frame Arg0 to station Arg2 (also the
    // target hardware address) for target IP Arg3, and send it.
    Method (NAOP, 4, NotSerialized)
    {
        If (Arg1 == One) { NEHD (Arg0, 0xFFFFFFFFFFFF, 0x0806) }
        Else { NEHD (Arg0, Arg2, 0x0806) }
        NB32 (Arg0 + 14, 0x00010800) // Ethernet, IPv4
        NB16 (Arg0 + 18, 0x0604)     // address lengths
        NB16 (Arg0 + 20, Arg1)
        NSMC (Arg0 + 22, NMAC)
        NB32 (Arg0 + 28, NIPA)
        NSMC (Arg0 + 32, Arg2)
        NB32 (Arg0 + 38, Arg3)
        NTXP (42)
    }

    // Broadcast a request for entry Arg0 and schedule the retry in 1 s.
    Method (NARQ, 1, NotSerialized)
    {
        Local0 = NTXA ()
        If (Local0) { NAOP (Local0, One, Zero, XLDQ (Arg0)) }
        Local1 = MNOW () + 1000000000
        XSTQ (Arg0 + 16, Local1)
        NTIM (Local1)
        XSTQ (Arg0 + 24, XLDQ (Arg0 + 24) + One)
    }

    // Send the frame in TX buffer Arg2 (Ethernet header space first, Arg3
    // payload bytes after it) with ethertype Arg1 to on-link host Arg0. An
    // unresolved destination queues a copy and sends an ARP request.
    Method (NETX, 4, NotSerialized)
    {
        Local0 = NRES (Arg0)
        If (Local0)
        {
            NEHD (Arg2, Local0, Arg1)
            NTXP (Arg3 + 14)
            Return (One)
        }
        Local1 = NANW (Arg0)
        Local2 = PALC ()
        If (!Local2) { Return (Zero) }
        Local2 += HHDO
        NB16 (Arg2 + 12, Arg1)
        XMOV (Local2, Arg2, Arg3 + 14)
        XSTQ (Local2 + 4080, Zero)
        XSTQ (Local2 + 4088, Arg3 + 14)
        If (XLDQ (Local1 + 48)) { XSTQ (XLDQ (Local1 + 48) + 4080, Local2) }
        Else { XSTQ (Local1 + 40, Local2) }
        XSTQ (Local1 + 48, Local2)
        XSTQ (Local1 + 32, XLDQ (Local1 + 32) + One)
        If (XLDQ (Local1 + 32) > NAQM)
        {
            Local3 = XLDQ (Local1 + 40)
            XSTQ (Local1 + 40, XLDQ (Local3 + 4080))
            XSTQ (Local1 + 32, NAQM)
            PDEL (Local3 - HHDO)
        }
        // An expired entry is refreshed; a pending one keeps its retry timer.
        If (XLDQ (Local1 + 8) || !XLDQ (Local1 + 24))
        {
            XSTQ (Local1 + 8, Zero)
            XSTQ (Local1 + 24, Zero)
            NARQ (Local1)
        }
        Return (One)
    }

    // Record that cached Arg0 has station address Arg1 and send its queued
    // frames in order.
    Method (NAUP, 2, NotSerialized)
    {
        Local0 = NAFN (Arg0)
        If (!Local0) { Return () }
        XSTQ (Local0 + 8, Arg1)
        XSTQ (Local0 + 16, MNOW () + NATO)
        XSTQ (Local0 + 24, Zero)
        While (XLDQ (Local0 + 40))
        {
            Local1 = XLDQ (Local0 + 40)
            XSTQ (Local0 + 40, XLDQ (Local1 + 4080))
            Local2 = NTXA ()
            If (Local2)
            {
                XMOV (Local2, Local1, XLDQ (Local1 + 4088))
                NSMC (Local2, Arg1)
                NSMC (Local2 + 6, NMAC)
                NTXP (XLDQ (Local1 + 4088))
            }
            PDEL (Local1 - HHDO)
        }
        XSTQ (Local0 + 32, Zero)
        XSTQ (Local0 + 48, Zero)
    }

    // Retry unresolved entries for 3 s, then drop them and their frame.
    Method (NATK, 1, NotSerialized)
    {
        Local0 = Zero
        While (Local0 < NACN)
        {
            Local1 = NARC + Local0 * 64
            If (XLDQ (Local1) && !XLDQ (Local1 + 8) && XLDQ (Local1 + 24) &&
                Arg0 >= XLDQ (Local1 + 16))
            {
                If (XLDQ (Local1 + 24) >= 3)
                {
                    // Like Linux, a connection attempt to it fails at once.
                    TPHU (XLDQ (Local1), Zero - 113, One, Zero, Zero) // EHOSTUNREACH
                    XSTQ (Local1, Zero)
                    NAQF (Local1)
                }
                Else { NARQ (Local1) }
            }
            Increment (Local0)
        }
    }

    Method (NARP, 2, NotSerialized)
    {
        If (Arg1 < 42 || NL32 (Arg0 + 14) != 0x00010800 ||
            NL16 (Arg0 + 18) != 0x0604) { Return () }
        Local0 = NL16 (Arg0 + 20)
        Local1 = NLMC (Arg0 + 22)
        Local2 = NL32 (Arg0 + 28)
        If (!Local2 || Local2 == NIPA || (Local1 & One)) { Return () }
        // RFC 826: refresh a known sender; learn it when it asks for us.
        Local3 = NL32 (Arg0 + 38) == NIPA
        If (Local3 && !NAFN (Local2)) { NANW (Local2) }
        NAUP (Local2, Local1)
        If (Local0 == One && Local3)
        {
            Local4 = NTXA ()
            If (Local4) { NAOP (Local4, 2, Local1, Local2) }
        }
    }

    // Received Ethernet frame Arg0 of Arg1 bytes.
    Method (NETH, 2, NotSerialized)
    {
        If (Arg1 < 14) { Return () }
        Local0 = NLMC (Arg0)
        If (Local0 != NMAC && Local0 != 0xFFFFFFFFFFFF) { Return () }
        Local1 = NL16 (Arg0 + 12)
        If (Local1 == 0x0800) { NIPV (Arg0, Arg1, Zero) }
        ElseIf (Local1 == 0x0806) { NARP (Arg0, Arg1) }
    }
