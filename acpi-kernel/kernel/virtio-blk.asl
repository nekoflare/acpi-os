    // Transitional PCI virtio-blk. One synchronous request is in flight.
    Name (VBAR, Zero)
    Name (VQUE, Zero)
    Name (VDMA, Zero)
    Name (VSEQ, Zero)
    Name (VCAP, Zero)
    Name (VFEA, Zero)

    External (XPIO, MethodObj)
    Method (VBIO, 3, NotSerialized)
    {
        Return (XPIO (VBAR + Arg0, Arg1, Arg2))
    }

    Method (VBIN, 0, NotSerialized)
    {
        Local0 = 0x80000000
        While (Local0 < 0x80010000)
        {
            PCIX = Local0
            If (PCDT == 0x10011AF4) { Break }
            Local0 += 0x800
        }
        If (Local0 == 0x80010000) { Return (Zero) }
        PCIX = Local0 + 0x10
        Local1 = PCDT
        If (!(Local1 & One) || Local1 >= 0x10000) { Return (Zero) }
        VBAR = Local1 & 0xFFFC
        PCIX = Local0 + 4
        PCDT = (PCDT & 0xFFFF) | 0x405 // I/O, bus mastering, INTx disabled
        VBIO (18, One, Zero)
        VBIO (18, One, 3)
        VFEA = VBIO (Zero, 4, Ones)
        VBIO (4, 4, VFEA & 0x200) // FLUSH
        VBIO (14, 2, Zero)
        Local1 = VBIO (12, 2, Ones)
        If (Local1 < 3 || Local1 > 128) { Return (Zero) }

        // Reserve consecutive physical pages for the descriptor and used rings.
        Local3 = Zero
        While (PEND - PNXT < 2 * PGSZ)
        {
            Local2 = PALC ()
            If (!Local2) { Return (Zero) }
            // Hold any tail pages until the next usable range has been found.
            XSTQ (HHDO + Local2, Local3)
            Local3 = Local2
        }
        VQUE = PNXT + HHDO
        PNXT += 2 * PGSZ
        PUSE += 2
        While (Local3)
        {
            Local2 = XVWD (HHDO + Local3, Ones)
            PDEL (Local3)
            Local3 = Local2
        }
        Local2 = PALC ()
        If (!Local2 || (VQUE - HHDO) >> 44) { Return (Zero) }
        VDMA = Local2 + HHDO
        XCLR (VQUE)
        XCLR (VQUE + PGSZ)
        XCLR (VDMA)
        // Header/status occupy unused space beyond the available ring.
        XSTQ (VQUE, VQUE - HHDO + 0xC00)
        XSTQ (VQUE + 16, Local2)
        XSTQ (VQUE + 32, VQUE - HHDO + 0xC10)
        VBIO (8, 4, (VQUE - HHDO) >> 12)
        VBIO (18, One, 7)
        VCAP = VBIO (20, 4, Ones) | (VBIO (24, 4, Ones) << 32)
        // Save the available-ring address, which depends on the queue size.
        XSTQ (VQUE + 0xC18, VQUE + Local1 * 16)
        Return (VCAP)
    }

    // type 0 read, 1 write, 4 flush. Data transfers use the DMA page.
    Method (VBRQ, 3, NotSerialized)
    {
        If (!VCAP || Arg1 >= VCAP || Arg2 > PGSZ || (Arg2 & 511) ||
            Arg2 / 512 > VCAP - Arg1) { Return (Zero) }
        XSTQ (VQUE + 0xC00, Arg0)
        XSTQ (VQUE + 0xC08, Arg1)
        XSTB (VQUE + 0xC10, 0xFF)
        Local0 = 0x0001000100000010
        If (Arg0 == 4) { Local0 = 0x0002000100000010 }
        XSTQ (VQUE + 8, Local0)
        Local0 = 0x0002000100000000
        If (!Arg0) { Local0 |= 0x0000000200000000 }
        XSTQ (VQUE + 24, Local0 | Arg2)
        XSTQ (VQUE + 40, 0x0000000200000001)
        Local0 = XVWD (VQUE + 0xC18, Ones)
        // Every available entry is descriptor zero. Publish only the index.
        VSEQ = (VSEQ + One) & 0xFFFF
        XSTB (Local0 + 3, VSEQ >> 8)
        XSTB (Local0 + 2, VSEQ)
        VBIO (16, 2, Zero)
        Local1 = 10000000
        While (ELWD (VQUE + PGSZ, 2, 2) != VSEQ)
        {
            Decrement (Local1)
            If (!Local1)
            {
                VCAP = Zero
                VBIO (18, One, Zero)
                Return (Zero)
            }
        }
        VBIO (19, One, Ones) // acknowledge device interrupt status
        Return (!XBYT (VQUE + 0xC10))
    }
