    // 4 KiB ext4 with 32-bit block numbers and filetype/extent features.
    // Each mount keeps its geometry. The scheduler serializes metadata I/O.
    Name (EXVL, Zero)
    Name (EXIN, Zero)
    Name (EXIX, Zero)
    Name (EXBL, 8)
    Name (EXBG, 16)
    Name (EXIG, 24)
    Name (EXIS, 32)
    Name (EXIC, 40)
    Name (EXRW, 48)

    Method (EXRD, 2, NotSerialized)
    {
        If (Arg0 >= XVWD (EXVL + EXBL, Ones) ||
            !VBRQ (Zero, XVWD (EXVL, Ones) + Arg0 * 8, PGSZ))
        {
            Return (Zero)
        }
        XMOV (Arg1, VDMA, PGSZ)
        Return (One)
    }

    // Select a numbered GPT entry. Only the primary table is needed at boot.
    Method (EXGP, 1, NotSerialized)
    {
        If (!Arg0 || !VBRQ (Zero, One, 512) ||
            XVWD (VDMA, Ones) != 0x5452415020494645 ||
            ELWD (VDMA, 84, 4) != 128 || Arg0 > ELWD (VDMA, 80, 4))
        {
            Return (Zero)
        }
        Local0 = XVWD (VDMA + 72, Ones) + (Arg0 - One) / 4
        If (!VBRQ (Zero, Local0, 512)) { Return (Zero) }
        Local0 = VDMA + ((Arg0 - One) % 4) * 128
        If (!XVWD (Local0, Ones) && !XVWD (Local0 + 8, Ones)) { Return (Zero) }
        Local1 = XVWD (Local0 + 32, Ones)
        Local2 = XVWD (Local0 + 40, Ones)
        If (!Local1 || Local1 > Local2 || Local2 >= VCAP) { Return (Zero) }
        XSTQ (EXVL, Local1)
        Return (Local2 - Local1 + One)
    }

    Method (EXSB, 1, NotSerialized)
    {
        If (Arg0 < 8) { Return (Zero) }
        If (!VBRQ (Zero, XVWD (EXVL, Ones), PGSZ)) { Return (Zero) }
        Local0 = VDMA + 1024
        If (ELWD (Local0, 56, 2) != 0xEF53 || ELWD (Local0, 58, 2) != One ||
            ELWD (Local0, 24, 4) != 2 || ELWD (Local0, 20, 4) ||
            ELWD (Local0, 92, 4) || ELWD (Local0, 96, 4) != 0x42 ||
            ELWD (Local0, 100, 4))
        {
            Return (Zero)
        }
        Local1 = ELWD (Local0, 4, 4)
        Local2 = ELWD (Local0, 32, 4)
        Local3 = ELWD (Local0, 40, 4)
        Local4 = ELWD (Local0, 88, 2)
        Local5 = ELWD (Local0, Zero, 4)
        If (Local1 < 2 || Local1 > Arg0 / 8 || !Local2 || !Local3 ||
            (Local4 != 128 && Local4 != 256) || Local5 < 2 ||
            (Local5 + Local3 - One) / Local3 > (Local1 + Local2 - One) / Local2)
        {
            Return (Zero)
        }
        XSTQ (EXVL + EXBL, Local1)
        XSTQ (EXVL + EXBG, Local2)
        XSTQ (EXVL + EXIG, Local3)
        XSTQ (EXVL + EXIS, Local4)
        XSTQ (EXVL + EXIC, Local5)
        Return (One)
    }

    Method (EXIR, 1, NotSerialized)
    {
        If (!Arg0 || Arg0 > XVWD (EXVL + EXIC, Ones)) { Return (Zero) }
        Decrement (Arg0)
        Local0 = XVWD (EXVL + EXIG, Ones)
        Local1 = Arg0 / Local0
        Local2 = (Arg0 % Local0) * XVWD (EXVL + EXIS, Ones)
        If (!EXRD (One + Local1 / 128, EXIN)) { Return (Zero) }
        Local3 = ELWD (EXIN, (Local1 % 128) * 32 + 8, 4)
        EXIB = Local3 + Local2 / PGSZ
        If (!Local3 || !EXRD (EXIB, EXIN)) { Return (Zero) }
        Return (EXIN + Local2 % PGSZ)
    }

    // Find the physical block for a logical block. Ones denotes a hole.
    Method (EXMP, 2, NotSerialized)
    {
        Local0 = Arg0 + 40
        Local1 = 4
        Local2 = ELWD (Local0, 6, 2)
        If (!(ELWD (Arg0, 32, 4) & 0x80000) || Local2 > 5) { Return (Zero) }
        While (One)
        {
            Local3 = ELWD (Local0, 2, 2)
            If (ELWD (Local0, Zero, 2) != 0xF30A || Local3 > Local1 ||
                ELWD (Local0, 6, 2) != Local2) { Return (Zero) }
            Local0 += 12
            Local4 = Zero
            While (Local3)
            {
                Local5 = ELWD (Local0, Zero, 4)
                If (Local5 > Arg1) { Break }
                Local4 = Local0
                Local0 += 12
                Decrement (Local3)
            }
            If (!Local4) { Return (Ones) }
            If (!Local2)
            {
                Local5 = Arg1 - ELWD (Local4, Zero, 4)
                Local6 = ELWD (Local4, 4, 2)
                If (Local6 > 0x8000 || Local5 >= Local6) { Return (Ones) }
                If (ELWD (Local4, 6, 2)) { Return (Zero) }
                Local7 = ELWD (Local4, 8, 4) + Local5
                If (Local7 >= XVWD (EXVL + EXBL, Ones)) { Return (Zero) }
                Return (Local7)
            }
            Local5 = ELWD (Local4, 4, 4)
            If (!Local5 || ELWD (Local4, 8, 2) || !EXRD (Local5, EXIX)) { Return (Zero) }
            Local0 = EXIX
            Local1 = (PGSZ - 12) / 12
            Decrement (Local2)
        }
        Return (Zero)
    }

    Method (EXLD, 3, NotSerialized)
    {
        Local0 = Zero
        While (Local0 < Arg2)
        {
            Local1 = EXMP (Arg0, Local0 / PGSZ)
            If (!Local1 || (Local1 != Ones && !EXRD (Local1, Arg1 + Local0))) { Return (Zero) }
            Local0 += PGSZ
        }
        Return (One)
    }

    // Populate the existing VFS and cache file bytes for ELF and read calls.
    Method (EXFL, 2, NotSerialized)
    {
        Local0 = EXIR (Arg1)
        If (!Local0 || (ELWD (Local0, Zero, 2) & 0xF000) != 0x8000 ||
            ELWD (Local0, 108, 4)) { Return (Zero) }
        Local1 = ELWD (Local0, 4, 4)
        If (Local1 > 0x4000000) { Return (Zero) }
        If (Local1)
        {
            Local2 = WRIT
            If (XNXE ()) { Local2 |= NOEX }
            Local3 = VALL (Local1, Local2)
            If (!Local3) { Return (Zero) }
            If (!EXLD (Local0, Local3, Local1))
            {
                VUNM (Local3, Local1)
                Return (Zero)
            }
            Local4 = Local1
            While (Local4 % PGSZ)
            {
                XSTB (Local3 + Local4, Zero)
                Increment (Local4)
            }
            XSTQ (Arg0 + VNDA, Local3)
            XSTQ (Arg0 + VNCP, (Local1 + PGSZ - One) & ~(PGSZ - One))
        }
        XSTQ (Arg0 + VNSZ, Local1)
        XSTQ (Arg0 + VNFS, EXVL)
        XSTQ (Arg0 + VNMD, ELWD (Local0, Zero, 2))
        // A private cache per VFS node cannot keep hard links coherent.
        If (ELWD (Local0, 26, 2) == One && !(ELWD (Local0, 32, 4) & 0x30))
        {
            XSTQ (Arg0 + VNFO, Arg1)
        }
        Return (One)
    }

    Method (EXDE, 5, NotSerialized)
    {
        Local0 = XBYT (Arg1 + 7)
        If (Local0 != One && Local0 != 2) { Return (One) }
        If (SHMT (Arg1 + 8, Arg2, ".") || SHMT (Arg1 + 8, Arg2, "..")) { Return (One) }
        If (!Arg2 || VFIN (Arg0, Arg1 + 8, Arg2)) { Return (Zero) }
        Local1 = 8
        If (Local0 == 2) { Local1 = 4 }
        Local2 = VNOD (Arg0, Arg1 + 8, Arg2, Local1)
        If (!Local2) { Return (Zero) }
        If (Local0 == 2) { Return (EXDR (Local2, Arg3, Arg4 + One)) }
        Return (EXFL (Local2, Arg3))
    }

    Method (EXDR, 3, NotSerialized)
    {
        If (Arg2 > 16) { Return (Zero) }
        Local0 = EXIR (Arg1)
        If (!Local0 || (ELWD (Local0, Zero, 2) & 0xF000) != 0x4000) { Return (Zero) }
        Local1 = ELWD (Local0, 4, 4)
        If (!Local1 || (Local1 % PGSZ) || Local1 > 0x100000) { Return (Zero) }
        Local2 = WRIT
        If (XNXE ()) { Local2 |= NOEX }
        Local3 = VALL (Local1, Local2)
        If (!Local3) { Return (Zero) }
        XSTQ (Arg0 + VNFS, EXVL)
        XSTQ (Arg0 + VNFO, Arg1)
        XSTQ (Arg0 + VNMD, ELWD (Local0, Zero, 2))
        Local7 = EXLD (Local0, Local3, Local1)
        If (Local7)
        {
            Local0 = Zero
            While (Local0 < Local1)
            {
                Local4 = Local3 + Local0
                Local5 = ELWD (Local4, 4, 2)
                Local6 = XBYT (Local4 + 6)
                If (Local5 < 8 || (Local5 & 3) || Local5 > PGSZ - Local0 % PGSZ ||
                    Local6 > Local5 - 8)
                {
                    Local7 = Zero
                    Break
                }
                Local2 = ELWD (Local4, Zero, 4)
                If (Local2 && !EXDE (Arg0, Local4, Local6, Local2, Arg2))
                {
                    Local7 = Zero
                    Break
                }
                Local0 += Local5
            }
        }
        VUNM (Local3, Local1)
        Return (Local7)
    }

    // Stage a tree before publishing it. Existing synthetic nodes and fstab
    // are kept when mounting over the bootstrap root.
    Method (EXMT, 3, NotSerialized)
    {
        Local0 = PALC ()
        If (!Local0) { Return (Zero) }
        EXVL = HHDO + Local0
        Local1 = EXGP (Arg0)
        If (!EXSB (Local1))
        {
            PDEL (Local0)
            Return (Zero)
        }
        XSTQ (EXVL + EXRW, Arg2 && !(VFEA & 0x20) &&
            XVWD (EXVL + EXBG, Ones) <= PGSZ * 8 &&
            XVWD (EXVL + EXIG, Ones) <= PGSZ * 8)
        Local1 = VNOD (Zero, Zero, Zero, 4)
        If (!Local1) { PDEL (Local0) Return (Zero) }
        If (!EXDR (Local1, 2, Zero))
        {
            EXFR (Local1)
            PDEL (Local0)
            Return (Zero)
        }
        Local2 = XVWD (Local1 + VNCH, Ones)
        While (Local2)
        {
            If (VFIN (Arg1, XVWD (Local2 + VNNA, Ones), XVWD (Local2 + VNNL, Ones)))
            {
                EXFR (Local1)
                PDEL (Local0)
                Return (Zero)
            }
            Local2 = XVWD (Local2 + VNXT, Ones)
        }
        Local2 = XVWD (Local1 + VNCH, Ones)
        XSTQ (Arg1 + VNFS, EXVL)
        XSTQ (Arg1 + VNFO, 2)
        XSTQ (Arg1 + VNMD, XVWD (Local1 + VNMD, Ones))
        If (!Local2) { Return (One) }
        Local3 = XVWD (Arg1 + VNCH, Ones)
        XSTQ (Arg1 + VNCH, Local2)
        While (Local2)
        {
            XSTQ (Local2 + VNPA, Arg1)
            Local4 = XVWD (Local2 + VNXT, Ones)
            If (!Local4)
            {
                XSTQ (Local2 + VNXT, Local3)
                Break
            }
            Local2 = Local4
        }
        Return (One)
    }

    Method (EXFR, 1, NotSerialized)
    {
        Local0 = XVWD (Arg0 + VNCH, Ones)
        While (Local0)
        {
            EXFR (Local0)
            Local0 = XVWD (Local0 + VNXT, Ones)
        }
        Local1 = XVWD (Arg0 + VNSZ, Ones)
        If (Local1) { VUNM (XVWD (Arg0 + VNDA, Ones), Local1) }
    }

    Method (EXWR, 1, NotSerialized)
    {
        Local0 = XVWD (Arg0 + VNFS, Ones)
        If (!Local0 || !XVWD (Arg0 + VNFO, Ones) ||
            XVWD (Arg0 + VNTY, Ones) != 8) { Return (Zero) }
        Return (XVWD (Local0 + EXRW, Ones))
    }

    // Complete the Linux stat record with the disk inode's metadata.
    Method (EXSA, 2, NotSerialized)
    {
        EXVL = XVWD (Arg0 + VNFS, Ones)
        Local0 = EXIR (XVWD (Arg0 + VNFO, Ones))
        If (!Local0) { Return (Zero) }
        XSTQ (Arg1, XVWD (EXVL, Ones))
        XSTQ (Arg1 + 16, ELWD (Local0, 26, 2))
        XSTQ (Arg1 + 48, ELWD (Local0, 4, 4))
        XSTQ (Arg1 + 64, ELWD (Local0, 28, 4))
        XSTQ (Arg1 + 72, ELWD (Local0, 8, 4))
        XSTQ (Arg1 + 88, ELWD (Local0, 16, 4))
        XSTQ (Arg1 + 104, ELWD (Local0, 12, 4))
        Return (One)
    }

    Method (EXTR, 1, NotSerialized)
    {
        EXVL = XVWD (Arg0 + VNFS, Ones)
        Local0 = EXSZ (XVWD (Arg0 + VNFO, Ones), Zero)
        If (Local0) { Return (Local0) }
        VTRN (Arg0)
        If (!EXSY ()) { Return (Zero - 5) }
        Return (Zero)
    }

    // Resize the shared cache before touching disk. Each call writes at most
    // one block, and publishes its bytes to readers only after disk I/O.
    Method (EXIO, 4, NotSerialized)
    {
        Local0 = XVWD (Arg1, Ones)
        Local1 = XVWD (Arg1 + 40, Ones)
        If (!(Local1 & 3)) { Return (Zero - 9) }
        If (!Arg3) { Return (Zero) }
        Local2 = XVWD (Arg1 + 8, Ones)
        Local3 = XVWD (Local0 + VNSZ, Ones)
        If (Local1 & 0x400) { Local2 = Local3 }
        Local4 = PGSZ - Local2 % PGSZ
        If (Arg3 > Local4) { Arg3 = Local4 }
        If (Local2 > 0x4000000 - Arg3) { Return (Zero - 27) }
        If (!URNG (Arg0, Arg2, Arg3, Zero)) { Return (Zero - 14) }
        Local4 = Local2 + Arg3
        If (!VGRW (Local0, Local4)) { Return (Zero - 12) }
        EXVL = XVWD (Local0 + VNFS, Ones)
        Local5 = XVWD (Local0 + VNFO, Ones)
        If (Local4 > Local3)
        {
            If ((Local3 % PGSZ) && Local2 / PGSZ > Local3 / PGSZ)
            {
                Local6 = EXMP (EXIR (Local5), Local3 / PGSZ)
                If (!Local6 || Local6 == Ones) { Return (Zero - 5) }
                If (!EXBW (Local6, XVWD (Local0 + VNDA, Ones) + (Local3 & ~(PGSZ - One))))
                {
                    Return (Zero - 5)
                }
            }
            Local6 = EXSZ (Local5, Local4)
            If (Local6) { Return (Local6) }
        }
        Local6 = EXMP (EXIR (Local5), Local2 / PGSZ)
        If (Local6 == Ones) { Return (Zero - 95) }
        If (!Local6) { Return (Zero - 5) }
        Local7 = XVWD (Local0 + VNDA, Ones) + (Local2 & ~(PGSZ - One))
        XMOV (EXDB, Local7, PGSZ)
        If (!UCPY (Arg0, EXDB + Local2 % PGSZ, Arg2, Arg3)) { Return (Zero - 14) }
        If (!EXBW (Local6, EXDB)) { Return (Zero - 5) }
        XMOV (Local7, EXDB, PGSZ)
        If (Local4 > Local3) { XSTQ (Local0 + VNSZ, Local4) }
        If (!EXSY ()) { Return (Zero - 5) }
        XSTQ (Arg1 + 8, Local4)
        Return (Arg3)
    }
