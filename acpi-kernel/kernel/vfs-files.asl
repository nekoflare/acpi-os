    // Disk-backed VFS nodes keep their mode and a shared page cache.
    Name (VNMD, 344) // Linux mode, or zero for synthetic nodes
    Name (VNCP, 352) // Allocated data capacity
    Name (VNRF, 360) // Open descriptions and working directories
    Name (VFRN, Zero)
    Name (TSWD, 720)
    Name (TSUM, 728) // Umask with bit 9 marking an explicit value

    Method (VMSK, 1, NotSerialized)
    {
        Local0 = XVWD (Arg0 + TSUM, Ones)
        If (!Local0) { Return (0x12) } // 0022
        Return (Local0 & 0x1FF)
    }

    Method (VCWD, 1, NotSerialized)
    {
        Local0 = XVWD (Arg0 + TSWD, Ones)
        If (!Local0) { Return (VROT) }
        Return (Local0)
    }

    Method (VMUT, 1, NotSerialized)
    {
        If (EXWR (Arg0)) { Return (One) }
        Local0 = XVWD (Arg0 + VNFS, Ones)
        // AML evaluates both operands of LAnd. Synthetic nodes have no ext4 volume.
        If (!Local0 || XVWD (Arg0 + VNTY, Ones) != 4) { Return (Zero) }
        Return (XVWD (Local0 + EXRW, Ones) != Zero)
    }

    Method (VREF, 1, NotSerialized)
    {
        If (Arg0 && (XVWD (Arg0 + VNMD, Ones) || XVWD (Arg0 + VNPR, Ones)))
        {
            XSTQ (Arg0 + VNRF, XVWD (Arg0 + VNRF, Ones) + One)
        }
    }

    Method (VREC, 1, NotSerialized)
    {
        If (!(XVWD (Arg0 + VNMD, Ones) || XVWD (Arg0 + VNPR, Ones)) ||
            XVWD (Arg0 + VNPA, Ones) ||
            XVWD (Arg0 + VNRF, Ones)) { Return (Zero) }
        VDIS (Arg0)
        Return (One)
    }

    Method (VDIS, 1, NotSerialized)
    {
        VTRN (Arg0)
        XSTQ (Arg0 + VNXT, VFRN)
        VFRN = Arg0
    }

    Method (VREL, 1, NotSerialized)
    {
        If (Arg0 && (XVWD (Arg0 + VNMD, Ones) || XVWD (Arg0 + VNPR, Ones)))
        {
            XSTQ (Arg0 + VNRF, XVWD (Arg0 + VNRF, Ones) - One)
            VREC (Arg0)
        }
    }

    // Split the copied path at its final component. The caller resolves and
    // edits it in the same syscall, before UPTH can be reused.
    Name (VBNM, Zero)
    Name (VBLN, Zero)
    Name (VBTR, Zero)
    Method (VPAR, 4, NotSerialized)
    {
        Local0 = Arg2
        While (Local0 && XBYT (Arg1 + Local0 - One) == 0x2F) { Decrement (Local0) }
        VBTR = Local0 != Arg2
        If (!Local0) { Return (Zero - 16) }
        Local1 = Local0
        While (Local1 && XBYT (Arg1 + Local1 - One) != 0x2F) { Decrement (Local1) }
        VBNM = Arg1 + Local1
        VBLN = Local0 - Local1
        If (VBLN > 255) { Return (Zero - 36) }
        Local2 = VWAT (Arg0, Arg1, Local1, Arg3, Zero)
        If (Local2 >= Zero - 4095) { Return (Local2) }
        If (XVWD (Local2 + VNTY, Ones) != 4) { Return (Zero - 20) }
        Return (Local2)
    }

    Method (VCRE, 4, NotSerialized)
    {
        Local0 = UPAR (Arg0, Arg1, Arg2)
        If (Local0 == Zero - 16) { Return (Zero - 17) }
        If (Local0 >= Zero - 4095) { Return (Local0) }
        If (SHMT (VBNM, VBLN, ".") || SHMT (VBNM, VBLN, "..") ||
            VFIN (Local0, VBNM, VBLN)) { Return (Zero - 17) }
        If (VBTR && !(Arg3 & 0x4000)) { Return (Zero - 21) }
        If (!VMUT (Local0)) { Return (Zero - 30) }
        Local1 = 8
        If (Arg3 & 0x4000) { Local1 = 4 }
        Local2 = VNOD (Local0, VBNM, VBLN, Local1)
        If (!Local2) { Return (Zero - 12) }
        Local3 = EXCR (Local2, Arg3)
        If (Local3)
        {
            VDET (Local0, Local2)
            VDIS (Local2)
            Return (Local3)
        }
        Return (Local2)
    }

    Method (VCHM, 2, NotSerialized)
    {
        EXVL = XVWD (Arg0 + VNFS, Ones)
        If (!EXVL) { Return (Zero - 30) } // EROFS
        If (!XVWD (EXVL + EXRW, Ones)) { Return (Zero - 30) }
        Local0 = EXIR (XVWD (Arg0 + VNFO, Ones))
        If (!Local0) { Return (Zero - 5) } // EIO
        Local1 = (ELWD (Local0, Zero, 2) & 0xF000) | (Arg1 & 0xFFF)
        EXLE (Local0, Zero, Local1, 2)
        If (!EXBW (EXIB, EXIN)) { Return (Zero - 5) }
        XSTQ (Arg0 + VNMD, Local1)
        If (!EXSY ()) { Return (Zero - 5) }
        Return (Zero)
    }

    Method (VUNL, 4, NotSerialized)
    {
        If (Arg3 & ~0x200) { Return (Zero - 22) }
        Local0 = UPAR (Arg0, Arg1, Arg2)
        If (Local0 >= Zero - 4095) { Return (Local0) }
        If (SHMT (VBNM, VBLN, ".")) { Return (Zero - 22) }
        If (SHMT (VBNM, VBLN, "..")) { Return (Zero - 39) }
        Local2 = VFIN (Local0, VBNM, VBLN)
        If (!Local2) { Return (Zero - 2) }
        Local3 = XVWD (Local2 + VNTY, Ones) == 4
        If (Arg3 && !Local3) { Return (Zero - 20) }
        If (!Arg3 && Local3) { Return (Zero - 21) }
        If (VBTR && !Local3) { Return (Zero - 20) }
        If (!VMUT (Local0) || !XVWD (Local2 + VNFO, Ones)) { Return (Zero - 30) }
        If (XVWD (Local0 + VNFS, Ones) != XVWD (Local2 + VNFS, Ones)) { Return (Zero - 16) }
        If (Local3 && XVWD (Local2 + VNCH, Ones)) { Return (Zero - 39) }
        If (Local3 && XVWD (Local2 + VNRF, Ones)) { Return (Zero - 16) }
        EXVL = XVWD (Local2 + VNFS, Ones)
        If (EXEC (EXIR (XVWD (Local2 + VNFO, Ones))) == Ones) { Return (Zero - 95) }
        Local4 = EXUL (Local0, Local2)
        If (Local4) { Return (Local4) }
        Return (VDEL (Local0, Local2))
    }

    Method (VDET, 2, NotSerialized)
    {
        Local0 = Arg0 + VNCH
        While (XVWD (Local0, Ones) != Arg1) { Local0 = XVWD (Local0, Ones) + VNXT }
        XSTQ (Local0, XVWD (Arg1 + VNXT, Ones))
        XSTQ (Arg1 + VNPA, Zero)
    }

    // Free the on-disk inode once it has no name. Open descriptions keep
    // the anonymous file's cache alive until their last close.
    Method (VDEL, 2, NotSerialized)
    {
        EXVL = XVWD (Arg1 + VNFS, Ones)
        Local0 = EXDL (XVWD (Arg1 + VNFO, Ones), XVWD (Arg1 + VNTY, Ones) == 4)
        XSTQ (Arg1 + VNFO, Zero)
        VDET (Arg0, Arg1)
        VREC (Arg1)
        If (!Local0) { Return (Zero - 5) }
        Return (Zero)
    }

    Method (VCHD, 2, NotSerialized)
    {
        Local0 = UENT (Arg0, Arg1, 0xFFFFFF9C)
        If (Local0 >= Zero - 4095) { Return (Local0) }
        If (XVWD (Local0 + VNTY, Ones) != 4) { Return (Zero - 20) }
        Local1 = VCWD (Arg0)
        VREF (Local0)
        XSTQ (Arg0 + TSWD, Local0)
        VREL (Local1)
        Return (Zero)
    }

    Method (VGCD, 3, NotSerialized)
    {
        Local0 = VCWD (Arg0)
        Local1 = XADR (UPTH)
        Local2 = Local1 + SizeOf (UPTH) - One
        Local3 = Local2
        XSTB (Local2, Zero)
        While (Local0 != VROT)
        {
            If (!XVWD (Local0 + VNPA, Ones)) { Return (Zero - 2) }
            Local4 = XVWD (Local0 + VNNL, Ones)
            If (Local2 - Local1 <= Local4) { Return (Zero - 36) }
            Local2 -= Local4
            XMOV (Local2, XVWD (Local0 + VNNA, Ones), Local4)
            Decrement (Local2)
            XSTB (Local2, 0x2F)
            Local0 = XVWD (Local0 + VNPA, Ones)
        }
        If (Local2 == Local3)
        {
            Decrement (Local2)
            XSTB (Local2, 0x2F)
        }
        Local4 = Local3 - Local2 + One
        If (Arg2 < Local4) { Return (Zero - 34) }
        If (!UCOP (Arg0, Arg1, Local2, Local4)) { Return (Zero - 14) }
        Return (Local4)
    }

    Method (VTRN, 1, NotSerialized)
    {
        Local0 = XVWD (Arg0 + VNCP, Ones)
        If (Local0) { VUNM (XVWD (Arg0 + VNDA, Ones), Local0) }
        XSTQ (Arg0 + VNDA, Zero)
        XSTQ (Arg0 + VNCP, Zero)
        XSTQ (Arg0 + VNSZ, Zero)
    }

    Method (VGRW, 2, NotSerialized)
    {
        Local0 = XVWD (Arg0 + VNCP, Ones)
        If (Arg1 <= Local0) { Return (One) }
        Local1 = PGSZ
        If (Local0) { Local1 = Local0 * 2 }
        While (Local1 < Arg1) { Local1 *= 2 }
        Local2 = WRIT
        If (XNXE ()) { Local2 |= NOEX }
        Local3 = VALL (Local1, Local2)
        If (!Local3) { Return (Zero) }
        If (Local0)
        {
            Local4 = XVWD (Arg0 + VNDA, Ones)
            XMOV (Local3, Local4, XVWD (Arg0 + VNSZ, Ones))
            VUNM (Local4, Local0)
        }
        XSTQ (Arg0 + VNDA, Local3)
        XSTQ (Arg0 + VNCP, Local1)
        Return (One)
    }

    Method (VOWR, 4, NotSerialized)
    {
        Local0 = XVWD (Arg1, Ones)
        Local1 = XVWD (Arg1 + 40, Ones)
        If (!(Local1 & 3)) { Return (Zero - 9) }
        If (!Arg3) { Return (Zero) }
        If (Arg3 > PGSZ) { Arg3 = PGSZ }
        If (!URNG (Arg0, Arg2, Arg3, Zero)) { Return (Zero - 14) }
        Local2 = XVWD (Arg1 + 8, Ones)
        Local3 = XVWD (Local0 + VNSZ, Ones)
        If (Local1 & 0x400) { Local2 = Local3 }
        If (Local2 > 0x4000000 - Arg3) { Return (Zero - 27) }
        Local4 = Local2 + Arg3
        If (!VGRW (Local0, Local4)) { Return (Zero - 12) }
        If (!UCPY (Arg0, XVWD (Local0 + VNDA, Ones) + Local2, Arg2, Arg3))
        {
            Return (Zero - 14)
        }
        If (Local4 > Local3) { XSTQ (Local0 + VNSZ, Local4) }
        XSTQ (Arg1 + 8, Local4)
        Return (Arg3)
    }

    Method (VREN, 5, NotSerialized)
    {
        Local0 = UPAR (Arg0, Arg1, Arg2)
        If (Local0 >= Zero - 4095) { Return (Local0) }
        If (SHMT (VBNM, VBLN, ".") || SHMT (VBNM, VBLN, "..")) { Return (Zero - 16) }
        Local1 = VFIN (Local0, VBNM, VBLN)
        If (!Local1) { Return (Zero - 2) }
        Local2 = XVWD (Local1 + VNTY, Ones) == 4
        If (VBTR && !Local2) { Return (Zero - 20) }
        If (!VMUT (Local0) || !XVWD (Local1 + VNFO, Ones)) { Return (Zero - 30) }
        If (XVWD (Local0 + VNFS, Ones) != XVWD (Local1 + VNFS, Ones)) { Return (Zero - 16) }
        Local3 = UPAR (Arg0, Arg3, Arg4)
        If (Local3 >= Zero - 4095) { Return (Local3) }
        If (SHMT (VBNM, VBLN, ".") || SHMT (VBNM, VBLN, "..")) { Return (Zero - 16) }
        If (VBTR && !Local2) { Return (Zero - 20) }
        If (!VMUT (Local3)) { Return (Zero - 30) }
        If (XVWD (Local0 + VNFS, Ones) != XVWD (Local3 + VNFS, Ones)) { Return (Zero - 18) }
        Local4 = VFIN (Local3, VBNM, VBLN)
        If (Local4 == Local1) { Return (Zero) }
        If (Local2)
        {
            Local5 = Local3
            While (Local5 != VROT)
            {
                If (Local5 == Local1) { Return (Zero - 22) }
                Local5 = XVWD (Local5 + VNPA, Ones)
            }
        }
        If (Local4)
        {
            Local5 = XVWD (Local4 + VNTY, Ones) == 4
            If (Local2 && !Local5) { Return (Zero - 20) }
            If (!Local2 && Local5) { Return (Zero - 21) }
            If (!XVWD (Local4 + VNFO, Ones)) { Return (Zero - 30) }
            If (XVWD (Local3 + VNFS, Ones) != XVWD (Local4 + VNFS, Ones)) { Return (Zero - 16) }
            EXVL = XVWD (Local3 + VNFS, Ones)
            If (EXEC (EXIR (XVWD (Local4 + VNFO, Ones))) == Ones) { Return (Zero - 95) }
            If (Local5 && XVWD (Local4 + VNCH, Ones)) { Return (Zero - 39) }
            If (Local5 && XVWD (Local4 + VNRF, Ones)) { Return (Zero - 16) }
        }
        XSTQ (XADR (EXNM) + VNNA, VBNM)
        XSTQ (XADR (EXNM) + VNNL, VBLN)
        Local5 = EXRN (Local0, Local1, Local3, Local4)
        If (Local5) { Return (Local5) }
        Local5 = Zero
        If (Local4) { Local5 = VDEL (Local3, Local4) }
        VDET (Local0, Local1)
        XMOV (XVWD (Local1 + VNNA, Ones), VBNM, VBLN)
        XSTQ (Local1 + VNNL, VBLN)
        XSTQ (Local1 + VNPA, Local3)
        XSTQ (Local1 + VNXT, XVWD (Local3 + VNCH, Ones))
        XSTQ (Local3 + VNCH, Local1)
        Return (Local5)
    }

    Name (SFST, Buffer (120) {}) // Linux x86-64 struct statfs

    Method (SYFT, 4, NotSerialized)
    {
        If (Arg3)
        {
            Local0 = UFDL (Arg0, Arg1 & 0xFFFFFFFF)
            If (!Local0) { Return (Zero - 9) }
            Local0 = XVWD (Local0, Ones)
        }
        Else
        {
            Local0 = UENT (Arg0, Arg1, 0xFFFFFF9C)
            If (Local0 >= Zero - 4095) { Return (Local0) }
        }
        Local1 = XADR (SFST)
        XMOV (Local1, XADR (EXZR), SizeOf (SFST))
        Local2 = 0x01021994 // RAM filesystem
        Local3 = 0x21 // ST_VALID | ST_RDONLY
        If (Local0 != XADR (SKND) && Local0 != XADR (MFND))
        {
            If (XVWD (Local0 + VNPR, Ones)) { Local2 = 0x9FA0 }
            Local4 = XVWD (Local0 + VNFS, Ones)
            If (Local4)
            {
                EXVL = Local4
                If (!EXRD (Zero, EXDB)) { Return (Zero - 5) }
                Local5 = EXDB + 1024
                Local6 = ELWD (Local5, 12, 4)
                Local7 = ELWD (Local5, 8, 4)
                XSTQ (Local1 + 16, XVWD (Local4 + EXBL, Ones))
                XSTQ (Local1 + 24, Local6)
                If (Local6 < Local7) { Local6 = Local7 }
                XSTQ (Local1 + 32, Local6 - Local7)
                XSTQ (Local1 + 40, XVWD (Local4 + EXIC, Ones))
                XSTQ (Local1 + 48, ELWD (Local5, 16, 4))
                XSTQ (Local1 + 56, XVWD (Local4, Ones))
                Local2 = 0xEF53
                If (XVWD (Local4 + EXRW, Ones)) { Local3 = 0x20 }
            }
        }
        XSTQ (Local1, Local2)
        XSTQ (Local1 + 8, PGSZ)
        XSTQ (Local1 + 64, 255)
        XSTQ (Local1 + 72, PGSZ)
        XSTQ (Local1 + 80, Local3)
        If (!UCOP (Arg0, Arg2, Local1, SizeOf (SFST))) { Return (Zero - 14) }
        Return (Zero)
    }
