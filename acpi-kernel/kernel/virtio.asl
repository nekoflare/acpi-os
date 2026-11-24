    // PCI and transitional (legacy I/O BAR) virtio helpers shared by the
    // virtio-blk and virtio-net drivers.
    External (XPIO, MethodObj)

    // Config address of the first bus-0 device whose ID dword is Arg0, or zero.
    Method (PCFD, 1, NotSerialized)
    {
        Local0 = 0x80000000
        While (Local0 < 0x80010000)
        {
            PCIX = Local0
            If (PCDT == Arg0) { Return (Local0) }
            Local0 += 0x800
        }
        Return (Zero)
    }

    // Enable I/O and memory decoding and bus mastering with INTx disabled
    // (memory decoding is for an MSI-X table BAR). Returns the
    // legacy virtio I/O BAR0 base, or zero if BAR0 is not an I/O BAR.
    Method (VIOB, 1, NotSerialized)
    {
        PCIX = Arg0 + 0x10
        Local0 = PCDT
        If (!(Local0 & One) || Local0 >= 0x10000) { Return (Zero) }
        PCIX = Arg0 + 4
        PCDT = (PCDT & 0xFFFF) | 0x407
        Return (Local0 & 0xFFFC)
    }

    // Reserve Arg0 physically consecutive, zeroed pages below 2^44 (legacy
    // virtio queue PFNs are 32 bits). Returns the physical address or zero.
    Method (PCON, 1, NotSerialized)
    {
        Local0 = Arg0 * PGSZ
        Local3 = Zero
        Local4 = One
        While (PEND - PNXT < Local0)
        {
            Local2 = PALC ()
            If (!Local2)
            {
                Local4 = Zero
                Break
            }
            // Hold any tail pages until the next usable range has been found.
            XSTQ (HHDO + Local2, Local3)
            Local3 = Local2
        }
        Local1 = Zero
        If (Local4 && !(PNXT >> 44))
        {
            Local1 = PNXT
            PNXT += Local0
            PUSE += Arg0
        }
        While (Local3)
        {
            Local2 = XVWD (HHDO + Local3, Ones)
            PDEL (Local3)
            Local3 = Local2
        }
        If (Local1)
        {
            Local2 = Zero
            While (Local2 < Local0)
            {
                XCLR (HHDO + Local1 + Local2)
                Local2 += PGSZ
            }
        }
        Return (Local1)
    }

    // Queue size of the last VQST call.
    Name (VQSZ, Zero)

    // Select legacy queue Arg1 on I/O base Arg0, allocate a ring for its
    // device-chosen size and register it. Returns the ring's virtual address
    // (descriptors; available ring at size * 16; used ring at VQUO) or zero.
    Method (VQST, 2, NotSerialized)
    {
        XPIO (Arg0 + 14, 2, Arg1)
        VQSZ = XPIO (Arg0 + 12, 2, Ones)
        If (!VQSZ || VQSZ > 1024 || (VQSZ & (VQSZ - One))) { Return (Zero) }
        Local0 = (VQUO (VQSZ) + 6 + 8 * VQSZ + PGSZ - One) / PGSZ
        Local1 = PCON (Local0)
        If (!Local1) { Return (Zero) }
        XPIO (Arg0 + 8, 4, Local1 >> 12)
        Return (Local1 + HHDO)
    }

    // Offset of the used ring in a legacy ring of Arg0 entries.
    Method (VQUO, 1, NotSerialized)
    {
        Return ((Arg0 * 18 + 6 + PGSZ - One) & ~(PGSZ - One))
    }

    // Program MSI-X table entry zero of the device at config address Arg0 to
    // deliver vector Arg1 to the BSP, map the table at Arg2 and enable MSI-X
    // with every other entry masked. Returns the entry's virtual address or
    // zero. Must run on the BSP.
    Method (PMSX, 3, NotSerialized)
    {
        PCIX = Arg0 + 4
        If (!(PCDT & 0x100000)) { Return (Zero) } // no capability list
        PCIX = Arg0 + 0x34
        Local0 = PCDT & 0xFC
        Local1 = 48
        While (Local0 && Local1)
        {
            PCIX = Arg0 + Local0
            Local2 = PCDT
            If ((Local2 & 0xFF) == 0x11) { Break }
            Local0 = (Local2 >> 8) & 0xFC
            Decrement (Local1)
        }
        If (!Local0 || !Local1) { Return (Zero) }
        PCIX = Arg0 + Local0 + 4
        Local3 = PCDT
        PCIX = Arg0 + 0x10 + (Local3 & 7) * 4
        Local4 = PCDT
        If (Local4 & One) { Return (Zero) }
        If ((Local4 & 6) == 4)
        {
            PCIX = Arg0 + 0x14 + (Local3 & 7) * 4
            Local4 |= PCDT << 32
        }
        Local4 = (Local4 & ~0xF) + (Local3 & ~7)
        If (!(Local4 & ~0xFFF) || !MMIO (Arg2, Local4 & ~0xFFF)) { Return (Zero) }
        Local5 = Arg2 + (Local4 & 0xFFF)
        // Mask the function while the table is written.
        PCIX = Arg0 + Local0
        PCDT = (Local2 & 0xFFFF) | 0xC0000000
        Local6 = LREG (0x20, Ones)
        If (!X2EN) { Local6 >>= 24 }
        Local7 = ((Local2 >> 16) & 0x7FF) + One
        // Only the mapped page of the table is touched.
        If (Local7 > (PGSZ - (Local4 & 0xFFF)) / 16)
        {
            Local7 = (PGSZ - (Local4 & 0xFFF)) / 16
        }
        While (Local7)
        {
            Decrement (Local7)
            XDWD (Local5 + Local7 * 16 + 12, One)
        }
        XDWD (Local5, 0xFEE00000 | ((Local6 & 0xFF) << 12))
        XDWD (Local5 + 4, Zero)
        XDWD (Local5 + 8, Arg1)
        XDWD (Local5 + 12, Zero)
        PCIX = Arg0 + Local0
        PCDT = (Local2 & 0xFFFF) | 0x80000000
        Return (Local5)
    }
