    // Interface configuration as tools read it: the SIOCGIF* socket ioctls
    // and /proc/net/dev and /proc/net/route. Interface 1 is lo, interface 2
    // is eth0 and exists only while the virtio-net device is up. The
    // configuration is static, so the setters are refused.
    Name (NIFR, Buffer (40) {}) // struct ifreq staging
    Name (NRXB, Zero) // Bytes received, Ethernet header included
    Name (NTXF, Zero) // Frames sent
    Name (NTXB, Zero) // Bytes sent

    Method (NIFX, 0, NotSerialized)
    {
        If (NBAR) { Return (2) }
        Return (One)
    }

    // Interface index named by the ifr_name at NIFR, or zero.
    Method (NIFN, 0, NotSerialized)
    {
        Local0 = XVWD (XADR (NIFR), Ones)
        If ((Local0 & 0xFFFFFF) == 0x6F6C) { Return (One) }
        If (NBAR)
        {
            If ((Local0 & 0xFFFFFFFFFF) == 0x30687465) { Return (2) }
        }
        Return (Zero)
    }

    // Byte-swap a 32-bit address so a little-endian store lays it out in
    // network order.
    Method (NBSW, 1, NotSerialized)
    {
        Return (((Arg0 & 0xFF) << 24) | ((Arg0 & 0xFF00) << 8) |
            ((Arg0 >> 8) & 0xFF00) | ((Arg0 >> 24) & 0xFF))
    }

    Method (NIFA, 1, NotSerialized)
    {
        If (Arg0 == One) { Return (0x7F000001) }
        Return (NIPA)
    }

    Method (NIFM, 1, NotSerialized)
    {
        If (Arg0 == One) { Return (0xFF000000) }
        Return (NMSK)
    }

    // Write interface Arg0's NUL-padded name to Arg1 (16 bytes).
    Method (NIFW, 2, NotSerialized)
    {
        XSTQ (Arg1 + 8, Zero)
        If (Arg0 == One) { XSTQ (Arg1, 0x6F6C) }
        Else { XSTQ (Arg1, 0x30687465) }
    }

    // sockaddr_in for address Arg1 at Arg0.
    Method (NIFS, 2, NotSerialized)
    {
        XSTQ (Arg0, 2 | (NBSW (Arg1) << 32))
        XSTQ (Arg0 + 8, Zero)
    }

    // ifreq ioctls on any socket. Returns the syscall result.
    Method (NIFI, 3, NotSerialized)
    {
        If (Arg1 == 0x8912) { Return (NIFC (Arg0, Arg2)) } // SIOCGIFCONF
        If (Arg1 == 0x8946) { Return (Zero - 95) } // SIOCETHTOOL: EOPNOTSUPP
        Local0 = Arg1 == 0x8910 || Arg1 == 0x8913 || Arg1 == 0x8914 ||
            Arg1 == 0x8915 || Arg1 == 0x8917 || Arg1 == 0x8919 ||
            Arg1 == 0x891B || Arg1 == 0x891D || Arg1 == 0x8921 ||
            Arg1 == 0x8927 || Arg1 == 0x8933 || Arg1 == 0x8942 || Arg1 == 0x8970
        Local1 = Arg1 == 0x8916 || Arg1 == 0x8918 || Arg1 == 0x891A ||
            Arg1 == 0x891C || Arg1 == 0x891E || Arg1 == 0x8922 ||
            Arg1 == 0x8924 || Arg1 == 0x8943 || Arg1 == 0x8971
        If (!Local0 && !Local1) { Return (Zero - 25) } // ENOTTY
        Local2 = XADR (NIFR)
        If (!UCPY (Arg0, Local2, Arg2, 40)) { Return (Zero - 14) }
        If (Arg1 == 0x8910) // SIOCGIFNAME
        {
            Local3 = ELWD (Local2, 16, 4)
            If (Local3 < One || Local3 > NIFX ()) { Return (Zero - 19) }
            NIFW (Local3, Local2)
            If (!UCOP (Arg0, Arg2, Local2, 40)) { Return (Zero - 14) }
            Return (Zero)
        }
        Local3 = NIFN ()
        If (!Local3) { Return (Zero - 19) } // ENODEV
        If (Arg1 == 0x8914) // SIOCSIFFLAGS: only "up" is possible
        {
            If (ELWD (Local2, 16, 2) & One) { Return (Zero) }
            Return (Zero - 95)
        }
        If (Local1) { Return (Zero - 95) }
        XSTQ (Local2 + 16, Zero)
        XSTQ (Local2 + 24, Zero)
        XSTQ (Local2 + 32, Zero)
        If (Arg1 == 0x8913) // SIOCGIFFLAGS
        {
            // lo: UP LOOPBACK RUNNING; eth0: UP BROADCAST RUNNING MULTICAST
            Local4 = 0x1043
            If (Local3 == One) { Local4 = 0x49 }
            XSTQ (Local2 + 16, Local4)
        }
        ElseIf (Arg1 == 0x8915 || Arg1 == 0x8917) { NIFS (Local2 + 16, NIFA (Local3)) }
        ElseIf (Arg1 == 0x8919) // SIOCGIFBRDADDR
        {
            Local4 = Zero
            If (Local3 == 2) { Local4 = NIPA | (~NMSK & 0xFFFFFFFF) }
            NIFS (Local2 + 16, Local4)
        }
        ElseIf (Arg1 == 0x891B) { NIFS (Local2 + 16, NIFM (Local3)) }
        ElseIf (Arg1 == 0x8921) // SIOCGIFMTU
        {
            Local4 = 1500
            If (Local3 == One) { Local4 = 65536 }
            XSTQ (Local2 + 16, Local4)
        }
        ElseIf (Arg1 == 0x8927) // SIOCGIFHWADDR: ARPHRD_LOOPBACK or ARPHRD_ETHER
        {
            If (Local3 == One) { XSTQ (Local2 + 16, 772) }
            Else { XSTQ (Local2 + 16, One | (NMAC << 16)) }
        }
        ElseIf (Arg1 == 0x8933) { XSTQ (Local2 + 16, Local3) } // SIOCGIFINDEX
        ElseIf (Arg1 == 0x8942) { XSTQ (Local2 + 16, 1000) } // SIOCGIFTXQLEN
        // SIOCGIFMETRIC and SIOCGIFMAP report zeros.
        If (!UCOP (Arg0, Arg2, Local2, 40)) { Return (Zero - 14) }
        Return (Zero)
    }

    // SIOCGIFCONF: one ifreq with the IPv4 address per interface. A null
    // buffer asks for the length needed.
    Method (NIFC, 2, NotSerialized)
    {
        Local0 = XADR (NIFR)
        If (!UCPY (Arg0, Local0, Arg1, 16)) { Return (Zero - 14) }
        Local1 = ELWD (Local0, Zero, 4)
        Local2 = XVWD (Local0 + 8, Ones)
        Local3 = NIFX ()
        If (!Local2) { Local4 = Local3 * 40 }
        Else
        {
            If (Local1 & 0x80000000) { Return (Zero - 22) }
            Local4 = Zero
            Local5 = One
            While (Local5 <= Local3 && Local4 + 40 <= Local1)
            {
                NIFW (Local5, Local0)
                NIFS (Local0 + 16, NIFA (Local5))
                XSTQ (Local0 + 32, Zero)
                If (!UCOP (Arg0, Local2 + Local4, Local0, 40)) { Return (Zero - 14) }
                Local4 += 40
                Increment (Local5)
            }
        }
        XSTQ (Local0, Local4)
        If (!UCOP (Arg0, Arg1, Local0, 4)) { Return (Zero - 14) }
        Return (Zero)
    }

    // Decimal right-aligned in a field of Arg2 characters.
    Method (NPRJ, 3, NotSerialized)
    {
        Local0 = One
        Local1 = Arg1
        While (Local1 >= 10)
        {
            Local1 /= 10
            Increment (Local0)
        }
        While (Local0 < Arg2)
        {
            XSTB (Arg0, 0x20)
            Increment (Arg0)
            Increment (Local0)
        }
        Return (CDEC (Arg0, Arg1))
    }

    // One /proc/net/dev row: name, then receive bytes and packets and
    // transmit bytes and packets; the error, drop and other columns are zero.
    Method (NPDR, 6, NotSerialized)
    {
        Local0 = Arg0
        Local1 = 6 - SizeOf (Arg1)
        While (Local1)
        {
            XSTB (Local0, 0x20)
            Increment (Local0)
            Decrement (Local1)
        }
        Local0 = PCAT (Local0, Arg1)
        XSTB (Local0, 0x3A)
        Local0 = NPRJ (Local0 + One, Arg2, 8)
        Local0 = NPRJ (PCAT (Local0, " "), Arg3, 7)
        Local0 = PCAT (Local0, "    0    0    0     0          0         0 ")
        Local0 = NPRJ (Local0, Arg4, 8)
        Local0 = NPRJ (PCAT (Local0, " "), Arg5, 7)
        Local0 = PCAT (Local0, "    0    0    0     0       0          0")
        XSTB (Local0, 10)
        Return (Local0 + One)
    }

    Method (NPDV, 1, NotSerialized)
    {
        Local0 = PCAT (Arg0, "Inter-|   Receive                                                |  Transmit")
        XSTB (Local0, 10)
        Local0 = PCAT (Local0 + One, " face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed")
        XSTB (Local0, 10)
        Local0 = NPDR (Local0 + One, "lo", NLBT, NLPK, NLBT, NLPK)
        If (NBAR) { Local0 = NPDR (Local0, "eth0", NRXB, NFRM, NTXB, NTXF) }
        Return (Local0 - Arg0)
    }

    // Uppercase hexadecimal, Arg2 digits.
    Method (NHXU, 3, NotSerialized)
    {
        Local0 = Arg2
        While (Local0)
        {
            Local0 -= One
            Local1 = (Arg1 >> (Local0 * 4)) & 0xF
            If (Local1 < 10) { Local1 += 0x30 }
            Else { Local1 += 0x37 }
            XSTB (Arg0, Local1)
            Increment (Arg0)
        }
        Return (Arg0)
    }

    // Linux pads every /proc/net/route line to 127 characters.
    Method (NPPD, 2, NotSerialized)
    {
        While (Arg1 - Arg0 < 127)
        {
            XSTB (Arg1, 0x20)
            Increment (Arg1)
        }
        XSTB (Arg1, 10)
        Return (Arg1 + One)
    }

    Method (NPRR, 5, NotSerialized)
    {
        Local0 = PCAT (Arg0, "eth0")
        XSTB (Local0, 9)
        Local0 = NHXU (Local0 + One, NBSW (Arg1), 8)
        XSTB (Local0, 9)
        Local0 = NHXU (Local0 + One, NBSW (Arg2), 8)
        XSTB (Local0, 9)
        Local0 = NHXU (Local0 + One, Arg3, 4)
        Local0 = PCAT (Local0, "\t0\t0\t0\t")
        Local0 = NHXU (Local0, NBSW (Arg4), 8)
        Local0 = PCAT (Local0, "\t0\t0\t0")
        Return (NPPD (Arg0, Local0))
    }

    Method (NPRO, 1, NotSerialized)
    {
        Local0 = NPPD (Arg0, PCAT (Arg0,
            "Iface\tDestination\tGateway \tFlags\tRefCnt\tUse\tMetric\tMask\t\tMTU\tWindow\tIRTT"))
        If (NBAR)
        {
            Local0 = NPRR (Local0, Zero, NGWA, 3, Zero) // RTF_UP | RTF_GATEWAY
            Local0 = NPRR (Local0, NIPA & NMSK, Zero, One, NMSK)
        }
        Return (Local0 - Arg0)
    }
