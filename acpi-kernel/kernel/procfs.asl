    Name (PCRT, Zero)
    Name (PCSL, Zero)
    Name (PCNM, Buffer (24) {})
    Name (PCUS, Buffer (64 * 8) {}) // TSC cycles spent in user mode per CPU
    Name (PCSY, Buffer (64 * 8) {}) // TSC cycles spent handling syscalls
    Name (PCMT, Buffer (4048) {})
    Name (PCML, Zero)
    Name (SYMT, Buffer (64) {})
    Name (VNPR, 368) // Procfs entry kind
    Name (VNPD, 376) // Process record for live PID entries
    Name (PRND, 64)
    Name (PRTM, 72) // User-mode TSC cycles
    Name (PRBT, 80) // Start time in Linux clock ticks
    Name (PRSY, 88) // Syscall TSC cycles
    Name (PRNL, 96)
    Name (PRCL, 104)
    Name (PRNM, 112) // 16-byte comm field
    Name (PRCM, 128) // NUL-separated argv

    Method (PCAT, 2, NotSerialized)
    {
        Local0 = SizeOf (Arg1)
        Local1 = Zero
        While (Local1 < Local0)
        {
            XSTB (Arg0 + Local1, DerefOf (Index (Arg1, Local1)))
            Increment (Local1)
        }
        Return (Arg0 + Local0)
    }

    // Linux sysfs CPU lists use compact ranges such as "0-3\n".
    Method (SYCP, 2, NotSerialized)
    {
        Local0 = XADR (SYMT)
        If (Arg1 == One)
        {
            Local1 = CDEC (Local0, Zero)
        }
        Else
        {
            Local1 = CDEC (Local0, Zero)
            XSTB (Local1, 0x2D)
            Local1 = CDEC (Local1 + One, Arg1 - One)
        }
        XSTB (Local1, 10)
        Local1 += One
        XSTQ (Arg0 + VNDA, Local0)
        XSTQ (Arg0 + VNSZ, Local1 - Local0)
        Return (Arg0)
    }

    Method (SCIN, 0, NotSerialized)
    {
        Local0 = PCNO (VROT, "sys", 4, Zero)
        If (!Local0) { Return (Zero) }
        Local1 = PCNO (Local0, "devices", 4, Zero)
        If (!Local1) { Return (Zero) }
        Local2 = PCNO (Local1, "system", 4, Zero)
        If (!Local2) { Return (Zero) }
        Local3 = PCNO (Local2, "cpu", 4, Zero)
        If (!Local3) { Return (Zero) }
        Local4 = XCPU ()
        If (!Local4) { Local4 = One }
        Local5 = PCNO (Local3, "possible", 8, Zero)
        If (!Local5) { Return (Zero) }
        SYCP (Local5, Local4)
        Local5 = PCNO (Local3, "present", 8, Zero)
        If (!Local5) { Return (Zero) }
        SYCP (Local5, Local4)
        Local5 = PCNO (Local3, "online", 8, Zero)
        If (!Local5) { Return (Zero) }
        SYCP (Local5, Local4)
        Local5 = PCNO (Local3, "offline", 8, Zero)
        If (!Local5) { Return (Zero) }
        Local6 = XADR (SYMT) + 32
        XSTB (Local6, 10)
        XSTQ (Local5 + VNDA, Local6)
        XSTQ (Local5 + VNSZ, One)
        Return (SCFS (Local3, Local4))
    }

    Method (PCNO, 4, NotSerialized)
    {
        Local0 = XADR (PCNM)
        Local1 = PCAT (Local0, Arg1)
        Local2 = VNOD (Arg0, Local0, Local1 - Local0, Arg2)
        If (Local2) { XSTQ (Local2 + VNPR, Arg3) }
        Return (Local2)
    }

    Method (PCIN, 0, NotSerialized)
    {
        PCRT = PCNO (VROT, "proc", 4, One)
        If (!PCRT) { Return (Zero) }
        PCSL = PCNO (PCRT, "self", 10, One)
        If (!PCSL || !PCNO (PCRT, "meminfo", Zero, 2) ||
            !PCNO (PCRT, "stat", Zero, 3) || !PCNO (PCRT, "uptime", Zero, 4) ||
            !PCNO (PCRT, "mounts", Zero, 8) || !PCNO (PCRT, "filesystems", Zero, 9) ||
            !PCNO (PCRT, "loadavg", Zero, 11))
        {
            Return (Zero)
        }
        Local0 = XADR (PCMT)
        Local1 = PCAT (Local0, "proc /proc proc ro 0 0")
        XSTB (Local1, 10)
        PCML = Local1 + One - Local0
        If (!SCIN ()) { Return (Zero) }
        Local0 = PCNO (PCRT, "cpuinfo", 8, One)
        If (!Local0) { Return (Zero) }
        Local2 = VALL (XCPU () * PGSZ, WRIT)
        If (!Local2) { Return (Zero) }
        XSTQ (Local0 + VNDA, Local2)
        XSTQ (Local0 + VNSZ, CGEN (Local2))
        // pciutils' legacy backend enumerates this Linux-compatible index.
        Local0 = PCNO (PCRT, "bus", 4, One)
        If (!Local0) { Return (Zero) }
        Local0 = PCNO (Local0, "pci", 4, One)
        If (!Local0) { Return (Zero) }
        Return (PCIB (Local0))
    }

    Method (PCDE, 1, NotSerialized)
    {
        Local0 = XVWD (Arg0 + PRND, Ones)
        If (!Local0) { Return (Zero) }
        While (XVWD (Local0 + VNCH, Ones))
        {
            Local1 = XVWD (Local0 + VNCH, Ones)
            VDET (Local0, Local1)
            VREC (Local1)
        }
        VDET (PCRT, Local0)
        VREC (Local0)
        XSTQ (Arg0 + PRND, Zero)
        Return (One)
    }

    Method (PCPD, 1, NotSerialized)
    {
        Local0 = XADR (PCNM)
        Local1 = CDEC (Local0, XVWD (Arg0 + PRID, Ones))
        Local2 = VNOD (PCRT, Local0, Local1 - Local0, 4)
        If (!Local2) { Return (Zero) }
        XSTQ (Arg0 + PRND, Local2)
        XSTQ (Local2 + VNPR, One)
        If (!PCPF (Local2, Arg0, "stat", 5) ||
            !PCPF (Local2, Arg0, "status", 6) ||
            !PCPF (Local2, Arg0, "cmdline", 7) ||
            !PCNO (Local2, "mounts", Zero, 8) ||
            !PCPF (Local2, Arg0, "statm", 10) ||
            !PCPF (Local2, Arg0, "comm", 12))
        {
            PCDE (Arg0)
            Return (Zero)
        }
        Return (One)
    }

    Method (PCPF, 4, NotSerialized)
    {
        Local0 = PCNO (Arg0, Arg2, Zero, Arg3)
        If (Local0) { XSTQ (Local0 + VNPD, Arg1) }
        Return (Local0)
    }

    // Capture argv from the freshly constructed stack before entering user mode.
    Method (PCEX, 4, NotSerialized)
    {
        Local0 = Arg0 + PRNM
        Local1 = Zero
        While (Local1 < Arg3 && Local1 < 15)
        {
            Local2 = XBYT (Arg2 + Local1)
            If (Local2 == 10) { Local2 = 0x20 }
            XSTB (Local0 + Local1, Local2)
            Increment (Local1)
        }
        XSTB (Local0 + Local1, Zero)
        XSTQ (Arg0 + PRNL, Local1)

        Local0 = UPHY (Arg1, USTP - PGSZ, Zero)
        Local1 = XVWD (Local0, Ones)
        Local2 = Zero
        Local3 = Zero
        While (Local3 < Local1 && Local2 < PGSZ - PRCM - 48)
        {
            Local4 = XVWD (Local0 + 8 + Local3 * 8, Ones) - (USTP - PGSZ)
            While (Local4 < PGSZ && Local2 < PGSZ - PRCM - 48)
            {
                Local5 = XBYT (Local0 + Local4)
                XSTB (Arg0 + PRCM + Local2, Local5)
                Increment (Local2)
                Increment (Local4)
                If (!Local5) { Break }
            }
            Increment (Local3)
        }
        XSTQ (Arg0 + PRCL, Local2)
    }

    Method (PCNS, 1, NotSerialized)
    {
        If (!CTMH) { Return (Zero) }
        Return ((Arg0 / CTMH) * 1000 + ((Arg0 % CTMH) * 1000) / CTMH)
    }

    Method (PCAC, 3, NotSerialized)
    {
        Local0 = XADR (PCUS)
        Local1 = PRTM
        If (Arg2)
        {
            Local0 = XADR (PCSY)
            Local1 = PRSY
        }
        Local0 += XIDX () * 8
        XSTQ (Local0, XVWD (Local0, Ones) + Arg1)
        If (Arg0)
        {
            Local0 = XVWD (Arg0 + TSPR, Ones) + Local1
            XSTQ (Local0, XVWD (Local0, Ones) + Arg1)
        }
    }

    Method (PCID, 2, NotSerialized)
    {
        Local0 = PCNS (XVWD (XADR (PCUS) + Arg0 * 8, Ones) +
            XVWD (XADR (PCSY) + Arg0 * 8, Ones))
        If (Local0 >= Arg1) { Return (Zero) }
        Return (Arg1 - Local0)
    }

    Method (PCVL, 2, NotSerialized)
    {
        XSTB (Arg0, 0x20)
        Return (CDEC (Arg0 + One, Arg1))
    }

    Method (PCLN, 4, NotSerialized)
    {
        Local0 = PCVL (Arg0, Arg1 / 10000000)
        Local0 = PCVL (PCAT (Local0, " 0"), Arg2 / 10000000)
        Local0 = PCVL (Local0, Arg3 / 10000000)
        Local0 = PCAT (Local0, " 0 0 0 0 0 0")
        XSTB (Local0, 10)
        Return (Local0 + One)
    }

    Method (PCST, 1, NotSerialized)
    {
        Local0 = MNOW ()
        Local1 = Zero
        Local2 = Zero
        Local3 = Zero
        Local5 = Zero
        While (Local1 < XCPU ())
        {
            Local2 += XVWD (XADR (PCUS) + Local1 * 8, Ones)
            Local3 += PCID (Local1, Local0)
            Local5 += XVWD (XADR (PCSY) + Local1 * 8, Ones)
            Increment (Local1)
        }
        Local4 = PCLN (PCAT (Arg0, "cpu "), PCNS (Local2), PCNS (Local5), Local3)
        Local1 = Zero
        While (Local1 < XCPU ())
        {
            Local4 = CDEC (PCAT (Local4, "cpu"), Local1)
            Local4 = PCLN (Local4, PCNS (XVWD (XADR (PCUS) + Local1 * 8, Ones)),
                PCNS (XVWD (XADR (PCSY) + Local1 * 8, Ones)), PCID (Local1, Local0))
            Increment (Local1)
        }
        Return (Local4 - Arg0)
    }

    Method (PCFR, 2, NotSerialized)
    {
        Local0 = CDEC (Arg0, Arg1 / 1000000000)
        Local1 = (Arg1 / 10000000) % 100
        XSTB (Local0, 0x2E)
        XSTB (Local0 + One, 0x30 + Local1 / 10)
        XSTB (Local0 + 2, 0x30 + Local1 % 10)
        Return (Local0 + 3)
    }

    Method (PCUP, 1, NotSerialized)
    {
        Local0 = MNOW ()
        Local1 = Zero
        Local2 = Zero
        While (Local1 < XCPU ())
        {
            Local2 += PCID (Local1, Local0)
            Increment (Local1)
        }
        Local3 = PCFR (Arg0, Local0)
        XSTB (Local3, 0x20)
        Local3 = PCFR (Local3 + One, Local2)
        XSTB (Local3, 10)
        Return (Local3 + One - Arg0)
    }

    // All range-list mappings are backed eagerly. The stack has its own
    // reservation and gets backing pages on demand.
    Method (PCVM, 1, NotSerialized)
    {
        If (!Arg0) { Return (Zero) }
        Local0 = XVWD (Arg0 + TSUL, Ones)
        Local1 = Zero
        While (Local0)
        {
            Local2 = HHDO + Local0
            Local1 += XVWD (Local2 + 16, Ones) - XVWD (Local2 + 8, Ones)
            Local0 = XVWD (Local2, Ones)
        }
        Return (Local1)
    }

    Method (PCBK, 2, NotSerialized)
    {
        While (Arg1)
        {
            If (Arg1 == Arg0) { Return (One) }
            Arg1 = XVWD (Arg1, Ones)
        }
        Return (Zero)
    }

    Method (PCSN, 2, NotSerialized)
    {
        Local0 = 0x5A // Z
        If (Arg0)
        {
            Local0 = 0x52 // R
            If (XVWD (Arg1 + PRWT, Ones)) { Return (0x53) }
            If (PCBK (Arg0, SLHD) || PCBK (Arg0, PLHD) || PCBK (Arg0, SKWH) || PCBK (Arg0, KRHD))
            {
                Return (0x53)
            }
        }
        Return (Local0)
    }

    Method (PCPS, 2, NotSerialized)
    {
        Local0 = XVWD (Arg1 + PRTK, Ones)
        Local1 = CDEC (Arg0, XVWD (Arg1 + PRID, Ones))
        Local1 = PCAT (Local1, " (")
        Local2 = XVWD (Arg1 + PRNL, Ones)
        XMOV (Local1, Arg1 + PRNM, Local2)
        Local1 = PCAT (Local1 + Local2, ") ")
        XSTB (Local1, PCSN (Local0, Arg1))
        Local2 = XVWD (Arg1 + PRPA, Ones)
        Local3 = Zero
        If (Local2) { Local3 = XVWD (Local2 + PRID, Ones) }
        Local1 = PCVL (Local1 + One, Local3)
        Local1 = PCVL (PCVL (Local1, UPID), UPID)
        Local1 = PCAT (Local1, " 0 0 0 0 0 0 0")
        Local1 = PCVL (Local1, PCNS (XVWD (Arg1 + PRTM, Ones)) / 10000000)
        Local1 = PCVL (Local1, PCNS (XVWD (Arg1 + PRSY, Ones)) / 10000000)
        Local1 = PCAT (Local1, " 0 0 20 0 1 0")
        Local1 = PCVL (Local1, XVWD (Arg1 + PRBT, Ones))
        Local2 = PCVM (Local0)
        Local3 = Zero
        Local4 = Zero
        If (Local0)
        {
            Local3 = USSZ
            Local4 = XVWD (Local0 + TSSG, Ones)
        }
        Local1 = PCVL (Local1, Local2 + Local3)
        Local1 = PCVL (Local1, Local2 / PGSZ + Local4)
        Local1 = PCAT (Local1, " 18446744073709551615")
        XSTB (Local1, 10)
        Return (Local1 + One - Arg0)
    }

    Method (PCSS, 2, NotSerialized)
    {
        Local0 = PCAT (Arg0, "Name:")
        XSTB (Local0, 9)
        Local1 = XVWD (Arg1 + PRNL, Ones)
        XMOV (Local0 + One, Arg1 + PRNM, Local1)
        Local0 += One + Local1
        XSTB (Local0, 10)
        Local0 = PCAT (Local0 + One, "Uid:")
        Local1 = 4
        While (Local1)
        {
            XSTB (Local0, 9)
            XSTB (Local0 + One, 0x30)
            Local0 += 2
            Decrement (Local1)
        }
        XSTB (Local0, 10)
        Return (Local0 + One - Arg0)
    }

    Method (PCMM, 2, NotSerialized)
    {
        Local0 = XVWD (Arg1 + PRTK, Ones)
        Local1 = PCVM (Local0) / PGSZ
        Local3 = Zero
        Local4 = Zero
        If (Local0)
        {
            Local3 = USSZ / PGSZ
            Local4 = XVWD (Local0 + TSSG, Ones)
        }
        Local2 = PCVL (CDEC (Arg0, Local1 + Local3), Local1 + Local4)
        Local2 = PCAT (Local2, " 0 0 0 0 0")
        XSTB (Local2, 10)
        Return (Local2 + One - Arg0)
    }

    Method (PCGE, 2, NotSerialized)
    {
        Local0 = XVWD (Arg0 + VNPR, Ones)
        Local1 = XVWD (Arg0 + VNPD, Ones)
        If (Local0 == 2) { Return (MGEN (Arg1)) }
        If (Local0 == 3) { Return (PCST (Arg1)) }
        If (Local0 == 4) { Return (PCUP (Arg1)) }
        If (Local0 == 5) { Return (PCPS (Arg1, Local1)) }
        If (Local0 == 6) { Return (PCSS (Arg1, Local1)) }
        If (Local0 == 7)
        {
            If (!XVWD (Local1 + PRTK, Ones)) { Return (Zero) }
            Local2 = XVWD (Local1 + PRCL, Ones)
            XMOV (Arg1, Local1 + PRCM, Local2)
            Return (Local2)
        }
        If (Local0 == 8)
        {
            XMOV (Arg1, XADR (PCMT), PCML)
            Return (PCML)
        }
        If (Local0 == 9)
        {
            Local2 = PCAT (Arg1, "nodev proc")
            XSTB (Local2, 10)
            Local2 = PCAT (Local2 + One, "ext4")
            XSTB (Local2, 10)
            Return (Local2 + One - Arg1)
        }
        If (Local0 == 10) { Return (PCMM (Arg1, Local1)) }
        If (Local0 == 11) { Return (PCLO (Arg1)) }
        If (Local0 == 12)
        {
            Local2 = XVWD (Local1 + PRNL, Ones)
            XMOV (Arg1, Local1 + PRNM, Local2)
            XSTB (Arg1 + Local2, 10)
            Return (Local2 + One)
        }
        If (Local0 == 14)
        {
            Local2 = Zero
            While (Local2 < 256)
            {
                Local3 = PCIR (Local1, Local2)
                Local3 |= PCIR (Local1, Local2 + 4) << 32
                XSTQ (Arg1 + Local2, Local3)
                Local2 += 8
            }
            Return (256)
        }
        Return (Zero)
    }

    Method (PCIR, 2, NotSerialized)
    {
        PCIX = 0x80000000 | (Arg0 << 8) | Arg1
        Return (PCDT)
    }

    // Publish one config file for each function and size the device index
    // from the discovered functions, independently of the open-file buffer.
    Method (PCIB, 1, NotSerialized)
    {
        Local0 = Zero
        Local1 = Zero
        While (Local1 < 256)
        {
            Local2 = Zero
            Local3 = Zero
            While (Local3 < 256)
            {
                Local4 = (Local1 << 8) | Local3
                If ((PCIR (Local4, Zero) & 0xFFFF) != 0xFFFF)
                {
                    Local5 = XADR (PCNM)
                    If (!Local2)
                    {
                        PCXH (Local5, Local1, 2)
                        Local2 = VNOD (Arg0, Local5, 2, 4)
                        If (!Local2) { Return (Zero) }
                    }
                    PCXH (Local5, Local3 >> 3, 2)
                    XSTB (Local5 + 2, 0x2E)
                    XSTB (Local5 + 3, 0x30 + (Local3 & 7))
                    Local6 = VNOD (Local2, Local5, 4, Zero)
                    If (!Local6) { Return (Zero) }
                    XSTQ (Local6 + VNPR, 14)
                    XSTQ (Local6 + VNPD, Local4)
                    XSTQ (Local6 + VNSZ, 256)
                    Increment (Local0)
                    // Header type is byte 0x0E within the aligned dword.
                    If (!(Local3 & 7) && !(PCIR (Local4, 0x0C) & 0x00800000))
                    {
                        Local3 += 7
                    }
                }
                ElseIf (!(Local3 & 7)) { Local3 += 7 }
                Increment (Local3)
            }
            Increment (Local1)
        }

        Local1 = PCNO (Arg0, "devices", 8, One)
        If (!Local1) { Return (Zero) }
        If (!Local0) { Return (One) }
        // Each row contains at most 4 + 9 + 3 + 7 * 17 + 1 bytes.
        Local2 = VALL (Local0 * 136, WRIT)
        If (!Local2) { Return (Zero) }
        Local3 = Local2
        Local4 = XVWD (Arg0 + VNCH, Ones)
        While (Local4)
        {
            Local5 = XVWD (Local4 + VNCH, Ones)
            While (Local5)
            {
                Local3 = PCDV (Local3, XVWD (Local5 + VNPD, Ones))
                Local5 = XVWD (Local5 + VNXT, Ones)
            }
            Local4 = XVWD (Local4 + VNXT, Ones)
        }
        XSTQ (Local1 + VNDA, Local2)
        XSTQ (Local1 + VNSZ, Local3 - Local2)
        Return (One)
    }

    // Linux /proc/bus/pci/devices row: slot, IDs, IRQ, six BARs and ROM.
    Method (PCDV, 2, NotSerialized)
    {
        Local0 = PCXH (Arg0, Arg1, 4)
        XSTB (Local0, 0x20)
        Local1 = PCIR (Arg1, Zero)
        Local0 = PCXH (Local0 + One, ((Local1 & 0xFFFF) << 16) | (Local1 >> 16), 8)
        XSTB (Local0, 0x20)
        Local0 = PCXH (Local0 + One, PCIR (Arg1, 0x3C) & 0xFF, 2)
        Local1 = (PCIR (Arg1, 0x0C) >> 16) & 0x7F
        Local2 = Zero
        Local3 = Zero
        If (!Local1) { Local2 = 6 }
        ElseIf (Local1 == One) { Local2 = 2 }
        ElseIf (Local1 == 2) { Local2 = One }
        While (Local3 < 6)
        {
            Local4 = Zero
            If (Local3 < Local2)
            {
                Local4 = PCIR (Arg1, 0x10 + Local3 * 4)
                If ((Local4 & 7) == 4 && Local3 + One < Local2)
                {
                    Local4 |= PCIR (Arg1, 0x14 + Local3 * 4) << 32
                    XSTB (Local0, 0x20)
                    Local0 = PCXH (Local0 + One, Local4, 16)
                    Increment (Local3)
                    Local4 = Zero
                }
            }
            XSTB (Local0, 0x20)
            Local0 = PCXH (Local0 + One, Local4, 16)
            Increment (Local3)
        }
        Local4 = Zero
        If (!Local1) { Local4 = PCIR (Arg1, 0x30) }
        ElseIf (Local1 == One) { Local4 = PCIR (Arg1, 0x38) }
        XSTB (Local0, 0x20)
        Local0 = PCXH (Local0 + One, Local4, 16)
        XSTB (Local0, 10)
        Return (Local0 + One)
    }

    Method (PCXH, 3, NotSerialized)
    {
        Local0 = Arg0
        Local1 = Arg2
        While (Local1)
        {
            Local1 -= One
            Local2 = (Arg1 >> (Local1 * 4)) & 0xF
            If (Local2 < 10) { Local2 += 0x30 }
            Else { Local2 += 0x57 }
            XSTB (Local0, Local2)
            Increment (Local0)
        }
        Return (Local0)
    }

    Method (PCRL, 5, NotSerialized)
    {
        If (!Arg4) { Return (Zero - 22) }
        Local0 = UPRS (Arg0, Arg2, Arg1, 2)
        If (Local0 >= Zero - 4095) { Return (Local0) }
        If (Local0 != PCSL) { Return (Zero - 22) }
        Local1 = XADR (PCNM)
        Local2 = CDEC (Local1, XVWD (XVWD (Arg0 + TSPR, Ones) + PRID, Ones)) - Local1
        If (Local2 > Arg4) { Local2 = Arg4 }
        If (!UCOP (Arg0, Arg3, Local1, Local2)) { Return (Zero - 14) }
        Return (Local2)
    }

    // Fstab mounts are permanent. Record each successful mount for procfs.
    Method (PCMR, 4, NotSerialized)
    {
        Local0 = XADR (PCMT) + PCML
        Local1 = Arg2 - Arg1
        If (Local1 > SizeOf (PCMT) - PCML ||
            SizeOf (PCMT) - PCML - Local1 < 32) { Return (Zero) }
        Local2 = PCAT (Local0, "/dev/vda")
        Local2 = CDEC (Local2, Arg0)
        XSTB (Local2, 0x20)
        XMOV (Local2 + One, Arg1, Local1)
        Local2 += One + Local1
        Local2 = PCAT (Local2, " ext4 ro 0 0")
        If (XVWD (XVWD (Arg3 + VNFS, Ones) + EXRW, Ones))
        {
            XSTB (Local2 - 5, 0x77)
        }
        XSTB (Local2, 10)
        PCML += Local2 + One - Local0
        Return (One)
    }

    Name (PCLT, Zero)
    Name (PCLA, Buffer (24) {}) // 1, 5 and 15 minute averages, scaled by 2048
    Name (PCLD, Package () {1884, 2014, 2037})

    Method (PCLK, 0, NotSerialized)
    {
        If (!PCRT) { Return () }
        Local0 = MNOW ()
        If (Local0 < PCLT) { Return () }
        PCLT = Local0 + 5000000000
        Local1 = PCRQ () * 2048
        Local2 = Zero
        While (Local2 < 3)
        {
            Local3 = XADR (PCLA) + Local2 * 8
            Local4 = DerefOf (Index (PCLD, Local2))
            XSTQ (Local3, (XVWD (Local3, Ones) * Local4 +
                Local1 * (2048 - Local4) + 1024) / 2048)
            Increment (Local2)
        }
    }

    Method (PCRQ, 0, NotSerialized)
    {
        Local0 = SACT
        Local1 = SQHD
        While (Local1)
        {
            Increment (Local0)
            Local1 = XVWD (Local1, Ones)
        }
        Return (Local0)
    }

    Method (PCLO, 1, NotSerialized)
    {
        Local0 = Arg0
        Local1 = Zero
        While (Local1 < 3)
        {
            Local0 = PCFR (Local0, XVWD (XADR (PCLA) + Local1 * 8, Ones) *
                1000000000 / 2048)
            XSTB (Local0, 0x20)
            Increment (Local0)
            Increment (Local1)
        }
        Local0 = CDEC (Local0, PCRQ () + One) // Includes the caller in the kernel.
        XSTB (Local0, 0x2F)
        Local0 = CDEC (Local0 + One, PCNT ())
        Local0 = PCVL (Local0, PNID - One)
        XSTB (Local0, 10)
        Return (Local0 + One - Arg0)
    }

    Method (PCNT, 0, NotSerialized)
    {
        Local0 = PRHD
        Local1 = Zero
        While (Local0)
        {
            Increment (Local1)
            Local0 = XVWD (Local0, Ones)
        }
        Return (Local1)
    }

    Name (SINF, Buffer (112) {}) // Linux x86-64 struct sysinfo

    Method (SYSN, 2, NotSerialized)
    {
        Local0 = XADR (SINF)
        XSTQ (Local0, MNOW () / 1000000000)
        Local1 = Zero
        While (Local1 < 3)
        {
            XSTQ (Local0 + 8 + Local1 * 8, XVWD (XADR (PCLA) + Local1 * 8, Ones) * 32)
            Increment (Local1)
        }
        XSTQ (Local0 + 32, PTOT * PGSZ)
        XSTQ (Local0 + 40, (PTOT - PUSE) * PGSZ)
        Local2 = PCNT ()
        If (Local2 > 65535) { Local2 = 65535 }
        XSTQ (Local0 + 80, Local2)
        XSTQ (Local0 + 104, One)
        If (!UCOP (Arg0, Arg1, Local0, SizeOf (SINF))) { Return (Zero - 14) }
        Return (Zero)
    }

    Name (SAFB, Buffer (8) {})

    Method (SYAF, 4, NotSerialized)
    {
        If (Arg2 < 8 || Arg2 & 7) { Return (Zero - 22) }
        If (Arg1)
        {
            Local0 = PRHD
            While (Local0)
            {
                If (XVWD (Local0 + PRID, Ones) == Arg1) { Break }
                Local0 = XVWD (Local0, Ones)
            }
            If (!Local0) { Return (Zero - 3) }
        }
        Local0 = XCPU ()
        Local1 = Ones
        If (Local0 < 64) { Local1 = (One << Local0) - One }
        XSTQ (XADR (SAFB), Local1)
        If (!UCOP (Arg0, Arg3, XADR (SAFB), 8)) { Return (Zero - 14) }
        Return (8)
    }

    Name (MTOT, Buffer () {0x4D, 0x65, 0x6D, 0x54, 0x6F, 0x74, 0x61, 0x6C, 0x3A, 0x20})
    Name (MFRE, Buffer () {0x4D, 0x65, 0x6D, 0x46, 0x72, 0x65, 0x65, 0x3A, 0x20})
    Name (MAVL, Buffer () {0x4D, 0x65, 0x6D, 0x41, 0x76, 0x61, 0x69, 0x6C, 0x61, 0x62, 0x6C, 0x65, 0x3A, 0x20})

    Method (MLIN, 3, NotSerialized)
    {
        Local0 = SizeOf (Arg1)
        XMOV (Arg0, XADR (Arg1), Local0)
        Arg0 += Local0
        Local1 = One
        While (Local1 <= Arg2 / 10) { Local1 *= 10 }
        While (Local1)
        {
            XSTB (Arg0, 0x30 + (Arg2 / Local1) % 10)
            Increment (Arg0)
            Local1 /= 10
        }
        XSTB (Arg0, 0x20)
        XSTB (Arg0 + One, 0x6B)
        XSTB (Arg0 + 2, 0x42)
        XSTB (Arg0 + 3, 0x0A)
        Return (Arg0 + 4)
    }

    // Free pages are the only reclaimable memory in the physical allocator.
    Method (MGEN, 1, NotSerialized)
    {
        Local0 = (PTOT - PUSE) * (PGSZ / 1024)
        Local1 = MLIN (Arg0, MTOT, PTOT * (PGSZ / 1024))
        Local1 = MLIN (Local1, MFRE, Local0)
        Local1 = MLIN (Local1, MAVL, Local0)
        Local1 = PCAT (Local1, "Cached: 0 kB")
        XSTB (Local1, 10)
        Local1 = PCAT (Local1 + One, "SwapTotal: 0 kB")
        XSTB (Local1, 10)
        Local1 = PCAT (Local1 + One, "SwapFree: 0 kB")
        XSTB (Local1, 10)
        Return (Local1 + One - Arg0)
    }

    Name (CIDB, Buffer (4096) {})

    Method (CDEC, 2, NotSerialized)
    {
        Local0 = One
        While (Local0 <= Arg1 / 10) { Local0 *= 10 }
        While (Local0)
        {
            XSTB (Arg0, 0x30 + (Arg1 / Local0) % 10)
            Increment (Arg0)
            Local0 /= 10
        }
        Return (Arg0)
    }

    Method (CNUM, 3, NotSerialized)
    {
        Local0 = CDEC (PCAT (Arg0, Arg1), Arg2)
        XSTB (Local0, 10)
        Return (Local0 + One)
    }

    Method (CWRD, 2, NotSerialized)
    {
        Local0 = Zero
        While (Local0 < 4)
        {
            XSTB (Arg0 + Local0, (Arg1 >> (Local0 * 8)) & 0xFF)
            Increment (Local0)
        }
    }

    Method (CIDE, 1, NotSerialized)
    {
        Local0 = PCAT (Arg0, "vendor_id : ")
        CWRD (Local0, XCPD (Zero, One))
        CWRD (Local0 + 4, XCPD (Zero, 3))
        CWRD (Local0 + 8, XCPD (Zero, 2))
        XSTB (Local0 + 12, 10)
        Local0 += 13
        Local1 = XCPD (One, Zero)
        Local2 = (Local1 >> 8) & 0xF
        Local3 = (Local1 >> 4) & 0xF
        If (Local2 == 6 || Local2 == 15) { Local3 |= (Local1 >> 12) & 0xF0 }
        If (Local2 == 15) { Local2 += (Local1 >> 20) & 0xFF }
        Local0 = CNUM (Local0, "cpu family : ", Local2)
        Local0 = CNUM (Local0, "model : ", Local3)
        Local0 = CNUM (Local0, "stepping : ", Local1 & 0xF)
        If (XCPD (0x80000000, Zero) >= 0x80000004)
        {
            Local1 = PCAT (Local0, "model name : ")
            Local2 = Zero
            While (Local2 < 12)
            {
                CWRD (Local1 + Local2 * 4, XCPD (0x80000002 + Local2 / 4, Local2 % 4))
                Increment (Local2)
            }
            If (XBYT (Local1))
            {
                Local0 = Local1
                While (Local0 < Local1 + 48 && XBYT (Local0)) { Increment (Local0) }
                XSTB (Local0, 10)
                Increment (Local0)
            }
        }
        Local0 = PCAT (Local0, "flags : ")
        Local0 += XCFL (Local0)
        XSTB (Local0, 10)
        Increment (Local0)
        Local1 = XFRQ ()
        If (Local1) { Local0 = CNUM (Local0, "cpu MHz static : ", Local1) }
        If (XCPD (0x80000000, Zero) >= 0x80000008)
        {
            Local1 = XCPD (0x80000008, Zero)
            Local0 = CDEC (PCAT (Local0, "address sizes : "), Local1 & 0xFF)
            Local0 = CDEC (PCAT (Local0, " bits physical, "), (Local1 >> 8) & 0xFF)
            Local0 = PCAT (Local0, " bits virtual")
            XSTB (Local0, 10)
            Increment (Local0)
        }
        Return (Local0)
    }

    Method (CGEN, 1, NotSerialized)
    {
        Local0 = Arg0
        Local1 = XCPU ()
        Local2 = Zero
        Local3 = XADR (CIDB)
        Local4 = CIDE (Local3) - Local3
        While (Local2 < Local1)
        {
            Local0 = CNUM (Local0, "processor : ", Local2)
            XMOV (Local0, Local3, Local4)
            Local0 += Local4
            XSTB (Local0, 10)
            Increment (Local0)
            Increment (Local2)
        }
        Return (Local0 - Arg0)
    }

    Method (SFIL, 4, NotSerialized)
    {
        Local0 = PCNO (Arg0, Arg1, 8, Zero)
        If (!Local0) { Return (Zero) }
        XSTQ (Local0 + VNDA, Arg2)
        XSTQ (Local0 + VNSZ, Arg3 - Arg2)
        Return (Arg3)
    }

    Method (SFNM, 4, NotSerialized)
    {
        Local0 = CDEC (Arg2, Arg3)
        XSTB (Local0, 10)
        Return (SFIL (Arg0, Arg1, Arg2, Local0 + One))
    }

    Method (SDIR, 3, NotSerialized)
    {
        Local0 = XADR (PCNM)
        Local1 = CDEC (PCAT (Local0, Arg1), Arg2)
        Return (VNOD (Arg0, Local0, Local1 - Local0, 4))
    }

    // Deterministic cache descriptors give sharing in APIC ID space.
    Method (SCDS, 4, NotSerialized)
    {
        Local0 = XCCH (Arg1, Zero)
        Local1 = (Local0 >> 14) & 0xFFF
        Local2 = Zero
        While (Local1)
        {
            Increment (Local2)
            Local1 >>= One
        }
        Local1 = XCID (Arg2) >> Local2
        Local3 = Zero
        Local4 = Zero
        While (Local4 < XCPU ())
        {
            If ((XCID (Local4) >> Local2) == Local1) { Local3 |= One << Local4 }
            Increment (Local4)
        }

        Local4 = SFNM (Arg0, "id", Arg3, Local1)
        If (Local4) { Local4 = SFNM (Arg0, "level", Local4, (Local0 >> 5) & 7) }
        If (!Local4) { Return (Zero) }
        Local0 &= 31
        If (Local0 == One) { Local5 = PCAT (Local4, "Data") }
        ElseIf (Local0 == 2) { Local5 = PCAT (Local4, "Instruction") }
        Else { Local5 = PCAT (Local4, "Unified") }
        XSTB (Local5, 10)
        Local4 = SFIL (Arg0, "type", Local4, Local5 + One)
        If (!Local4) { Return (Zero) }
        Local5 = PCXH (Local4, Local3 >> 32, 8)
        XSTB (Local5, 0x2C)
        Local5 = PCXH (Local5 + One, Local3 & 0xFFFFFFFF, 8)
        XSTB (Local5, 10)
        Local4 = SFIL (Arg0, "shared_cpu_map", Local4, Local5 + One)

        Local0 = XCCH (Arg1, One)
        Local1 = (Local0 & 0xFFF) + One
        Local2 = ((Local0 >> 12) & 0x3FF) + One
        Local3 = (Local0 >> 22) + One
        Local5 = XCCH (Arg1, 2) + One
        If (Local4) { Local4 = SFNM (Arg0, "coherency_line_size", Local4, Local1) }
        If (Local4) { Local4 = SFNM (Arg0, "physical_line_partition", Local4, Local2) }
        If (Local4) { Local4 = SFNM (Arg0, "ways_of_associativity", Local4, Local3) }
        If (Local4) { Local4 = SFNM (Arg0, "number_of_sets", Local4, Local5) }
        If (Local4) { Local4 = SFNM (Arg0, "size", Local4, Local1 * Local2 * Local3 * Local5) }
        Return (Local4)
    }

    Method (SCFS, 2, NotSerialized)
    {
        Local0 = Zero
        While (Local0 < Arg1)
        {
            Local1 = SDIR (Arg0, "cpu", Local0)
            Local2 = VALL (PGSZ, WRIT)
            If (!Local1 || !Local2) { Return (Zero) }
            If (XCPD (Zero, Zero) >= 0x16)
            {
                Local3 = XCPD (0x16, One) & 0xFFFF
                If (Local3)
                {
                    Local4 = PCNO (Local1, "cpufreq", 4, Zero)
                    If (!Local4) { Return (Zero) }
                    Local2 = SFNM (Local4, "cpuinfo_max_freq", Local2, Local3 * 1000)
                    If (!Local2) { Return (Zero) }
                }
            }
            If (XCCH (Zero, Zero) & 31)
            {
                Local3 = PCNO (Local1, "cache", 4, Zero)
                If (!Local3) { Return (Zero) }
                Local4 = Zero
                While (Local4 < 32 && (XCCH (Local4, Zero) & 31))
                {
                    Local5 = SDIR (Local3, "index", Local4)
                    If (!Local5) { Return (Zero) }
                    Local2 = SCDS (Local5, Local4, Local0, Local2)
                    If (!Local2) { Return (Zero) }
                    Increment (Local4)
                }
            }
            Increment (Local0)
        }
        Return (One)
    }
