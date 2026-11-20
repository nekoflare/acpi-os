DefinitionBlock ("", "DSDT", 2, "AMLAOT", "ACPIKRNL", 1)
{
    External (XADR, MethodObj)
    External (XGDT, MethodObj)
    External (XIDT, MethodObj)
    External (XDWD, MethodObj)
    External (XFBQ, MethodObj)
    External (XPRW, MethodObj)
    External (XFBL, MethodObj)
    External (XAPC, MethodObj)
    External (XMSR, MethodObj)
    External (XWAI, MethodObj)
    External (XRUN, MethodObj)
    External (XIMG, MethodObj)
    External (XCPY, MethodObj)
    External (XMOV, MethodObj)
    External (XBYT, MethodObj)
    External (XSTB, MethodObj)
    External (XTRG, MethodObj)
    External (XBRK, MethodObj)
    External (XMEM, MethodObj)
    External (XMAP, MethodObj)
    External (XCR3, MethodObj)
    External (XCLR, MethodObj)
    External (XINV, MethodObj)

    OperationRegion (COM1, SystemIO, 0x3F8, 8)
    Field (COM1, ByteAcc, NoLock, Preserve)
    {
        DATA, 8,
        IENA, 8,
        FIFO, 8,
        LINE, 8,
        MODE, 8,
        STAT, 8
    }

    OperationRegion (PIT0, SystemIO, 0x40, 4)
    Field (PIT0, ByteAcc, NoLock, Preserve)
    {
        PDAT, 8,
        Offset (3),
        PCMD, 8
    }

    OperationRegion (PICM, SystemIO, 0x21, 1)
    Field (PICM, ByteAcc, NoLock, Preserve) { MIMR, 8 }
    OperationRegion (PICS, SystemIO, 0xA1, 1)
    Field (PICS, ByteAcc, NoLock, Preserve) { SIMR, 8 }

    OperationRegion (PS2C, SystemIO, 0x60, 5)
    Field (PS2C, ByteAcc, NoLock, Preserve)
    {
        KDAT, 8,
        Offset (4),
        KSTA, 8
    }

    OperationRegion (VBIP, SystemIO, 0x1CE, 2)
    Field (VBIP, WordAcc, NoLock, Preserve) { VBIX, 16 }
    OperationRegion (VBDP, SystemIO, 0x1CF, 2)
    Field (VBDP, WordAcc, NoLock, Preserve) { VBDT, 16 }
    OperationRegion (PCIO, SystemIO, 0xCF8, 8)
    Field (PCIO, DWordAcc, NoLock, Preserve) { PCIX, 32, PCDT, 32 }

    Include ("font8x8.asl")
    Include ("virtio-blk.asl")
    Include ("ext4.asl")
    Include ("ext4-write.asl")
    Include ("fstab.asl")
    Include ("vfs-files.asl")

    Name (HHDO, Zero)
    Name (IVEC, Zero)
    Name (SYEA, Zero)
    Name (TEXA, Zero)
    Name (TSTA, Zero)

    Name (FBAD, Zero)
    Name (FBPT, Zero)
    Name (FBPP, Zero)
    Name (FBFG, 16) // Palette index 16 selects the default white.
    Name (FBBG, Zero)
    Name (FBHI, Zero)
    Name (FBCL, Zero) // Packed foreground and background pixels
    Name (FESC, Zero)
    Name (FNUM, Zero)
    Name (FARG, Zero)
    Name (FCSI, Buffer (16) {})
    Name (FPAL, Package ()
    {
        0x000000, 0xAA0000, 0x00AA00, 0xAA5500,
        0x0000AA, 0xAA00AA, 0x00AAAA, 0xAAAAAA,
        0x555555, 0xFF5555, 0x55FF55, 0xFFFF55,
        0x5555FF, 0xFF55FF, 0x55FFFF, 0xFFFFFF,
        0xFFFFFF
    })
    Name (FBCS, Zero)
    Name (FBRS, Zero)
    Name (FBCX, Zero)
    Name (FBCY, Zero)
    Name (FBWD, Zero)
    Name (FBHT, Zero)
    Name (FBSZ, Zero)
    Name (FBRD, Zero)
    Name (FBGR, Zero)
    Name (FBBL, Zero)
    Name (FRSZ, Zero)
    Name (FGSZ, Zero)
    Name (FBSW, Zero)
    Name (FBVA, 0xFFFFFF0020000000)
    Name (FBYT, Zero) // Rows between scanout pages, including alignment padding
    Name (FBPG, Zero) // Scanout page, with page zero reserved for the console
    Name (FBOW, Zero) // Open file description owning the visible desktop
    Name (FBCK, Zero) // Probe the display only once
    Name (FBIO, Buffer (4096) {})
    Name (FBVS, Buffer (160) {})
    Name (FBFS, Buffer (80) {})

    Method (XVWD, 2, NotSerialized)
    {
        OperationRegion (MEM0, SystemMemory, Arg0, 8)
        Field (MEM0, QWordAcc, NoLock, Preserve) { DATA, 64 }
        If (Arg1 == Ones) { Return (DATA) }
        DATA = Arg1
        Return (Zero)
    }

    Method (XSTQ, 2, NotSerialized)
    {
        OperationRegion (MEM0, SystemMemory, Arg0, 8)
        Field (MEM0, QWordAcc, NoLock, Preserve) { DATA, 64 }
        DATA = Arg1
        Return (Zero)
    }
    Name (DEVN, Buffer () {0x64, 0x65, 0x76})
    Name (FBNM, Buffer () {0x66, 0x62, 0x30})

    Method (FINI, 0, NotSerialized)
    {
        FBAD = XFBQ (Zero)
        If (!FBAD) { Return (Zero) }
        FBCS = XFBQ (One) / 8
        Local0 = XFBQ (2)
        FBRS = Local0 / 16
        FBPT = XFBQ (3)
        FBPP = XFBQ (4)
        FBWD = XFBQ (One)
        FBHT = XFBQ (2)
        FBSZ = FBPT * FBHT
        FBRD = XFBQ (6)
        FBGR = XFBQ (7)
        FBBL = XFBQ (8)
        FRSZ = XFBQ (9)
        FGSZ = XFBQ (10)
        FBSW = XFBQ (11)
        FBCL = XFBQ (5)
        XFBL (FBAD, Zero, Local0 * FBPT)
        Return (One)
    }

    // Scale an 8-bit channel to the framebuffer's channel width, rounding to nearest.
    Method (FPCK, 3, NotSerialized)
    {
        Return ((((Arg0 * ((One << Arg1) - One)) + 127) / 255) << Arg2)
    }

    Method (XRGB, 1, NotSerialized)
    {
        If (!FBAD) { Return (Zero) }
        Return (FPCK ((Arg0 >> 16) & 0xFF, FRSZ, FBRD) |
            FPCK ((Arg0 >> 8) & 0xFF, FGSZ, FBGR) |
            FPCK (Arg0 & 0xFF, FBSW, FBBL))
    }

    // Draw one cell using the 8x8 bitmap with each scanline doubled.
    Method (FGLY, 1, NotSerialized)
    {
        Local0 = FBAD + FBCY * 16 * FBPT + FBCX * 8 * FBPP
        Local1 = XADR (FONT) + (Arg0 - 0x20) * 8
        Local2 = Zero
        While (Local2 < 8)
        {
            Local3 = XBYT (Local1 + Local2)
            XPRW (Local0, Local3, FBCL, FBPP)
            Local0 += FBPT
            XPRW (Local0, Local3, FBCL, FBPP)
            Local0 += FBPT
            Increment (Local2)
        }
    }

    Method (FLIN, 0, NotSerialized)
    {
        FBCX = Zero
        If (FBCY + One < FBRS)
        {
            Increment (FBCY)
        }
        Else
        {
            Local0 = FBPT * 16
            Local1 = (FBRS - One) * Local0
            XFBL (FBAD, FBAD + Local0, Local1)
            XFBL (FBAD + Local1, Zero, Local0)
            If (FBBG)
            {
                While (FBCX < FBCS)
                {
                    FGLY (0x20)
                    Increment (FBCX)
                }
                FBCX = Zero
            }
        }
    }

    // Values above the 16-color palette carry a tagged RGB value.
    Method (F256, 1, NotSerialized)
    {
        If (Arg0 < 16) { Return (Arg0) }
        If (Arg0 >= 232) { Return (0x1000000 | ((8 + (Arg0 - 232) * 10) * 0x010101)) }
        Local0 = Arg0 - 16
        Local1 = Zero
        Local2 = Zero
        While (Local2 < 3)
        {
            Divide (Local0, 6, Local3, Local0)
            If (Local3) { Local3 = 55 + 40 * Local3 }
            Local1 |= Local3 << (Local2 * 8)
            Increment (Local2)
        }
        Return (0x1000000 | Local1)
    }

    Method (FCOL, 1, NotSerialized)
    {
        If (Arg0 > 16) { Return (XRGB (Arg0)) }
        Return (XRGB (DerefOf (Index (FPAL, Arg0))))
    }

    Method (FSGR, 0, NotSerialized)
    {
        Local0 = Zero
        While (Local0 <= FNUM)
        {
            Local1 = DerefOf (Index (FCSI, Local0))
            If (!Local1)
            {
                FBFG = 16
                FBBG = Zero
                FBHI = Zero
            }
            ElseIf (Local1 == One) { FBHI = One }
            ElseIf (Local1 == 22) { FBHI = Zero }
            ElseIf (Local1 >= 30 && Local1 <= 37) { FBFG = Local1 - 30 }
            ElseIf (Local1 == 39) { FBFG = 16 }
            ElseIf (Local1 >= 40 && Local1 <= 47) { FBBG = Local1 - 40 }
            ElseIf (Local1 == 49) { FBBG = Zero }
            ElseIf (Local1 >= 90 && Local1 <= 97) { FBFG = Local1 - 82 }
            ElseIf (Local1 >= 100 && Local1 <= 107) { FBBG = Local1 - 92 }
            ElseIf (Local1 == 38 || Local1 == 48)
            {
                If (Local0 == FNUM) { Break }
                Increment (Local0)
                Local2 = DerefOf (Index (FCSI, Local0))
                If (Local2 == 5 && Local0 + One <= FNUM)
                {
                    Increment (Local0)
                    Local3 = F256 (DerefOf (Index (FCSI, Local0)))
                }
                ElseIf (Local2 == 2 && Local0 + 3 <= FNUM)
                {
                    Local3 = 0x1000000 |
                             (DerefOf (Index (FCSI, Local0 + One)) << 16) |
                             (DerefOf (Index (FCSI, Local0 + 2)) << 8) |
                             DerefOf (Index (FCSI, Local0 + 3))
                    Local0 += 3
                }
                Else { Break }
                If (Local1 == 38) { FBFG = Local3 }
                Else { FBBG = Local3 }
            }
            Increment (Local0)
        }
        Local0 = FBFG
        If (FBHI && Local0 < 8) { Local0 += 8 }
        FBCL = FCOL (Local0) | (FCOL (FBBG) << 32)
    }

    // Consume escape sequences on the framebuffer path only.
    Method (FANS, 1, NotSerialized)
    {
        If (Arg0 == 0x1B)
        {
            FESC = One
            Return (One)
        }
        If (FESC == One)
        {
            FESC = Zero
            If (Arg0 == 0x5B)
            {
                FESC = 2
                FNUM = Zero
                FARG = Zero
                Return (One)
            }
            Return (Zero)
        }
        If (!FESC) { Return (Zero) }
        If (Arg0 >= 0x40 && Arg0 <= 0x7E)
        {
            If (FESC == 2 && Arg0 == 0x6D)
            {
                Store (FARG, Index (FCSI, FNUM))
                FSGR ()
            }
            FESC = Zero
        }
        ElseIf (Arg0 < 0x20)
        {
            FESC = Zero
            Return (Zero)
        }
        ElseIf (FESC == 2)
        {
            If (Arg0 >= 0x30 && Arg0 <= 0x39)
            {
                FARG = FARG * 10 + Arg0 - 0x30
                If (FARG > 255) { FESC = 3 }
            }
            ElseIf (Arg0 == 0x3B && FNUM + One < SizeOf (FCSI))
            {
                Store (FARG, Index (FCSI, FNUM))
                Increment (FNUM)
                FARG = Zero
            }
            Else { FESC = 3 }
        }
        Return (One)
    }

    Method (FPUT, 1, NotSerialized)
    {
        If (!FBAD) { Return (Zero) }
        If (FANS (Arg0)) { Return (One) }
        If (Arg0 == 0x0D)
        {
            FBCX = Zero
        }
        ElseIf (Arg0 == 0x0A)
        {
            FLIN ()
        }
        ElseIf (Arg0 == 8)
        {
            If (!FBCX && FBCY)
            {
                Decrement (FBCY)
                FBCX = FBCS
            }
            If (FBCX)
            {
                Decrement (FBCX)
                FGLY (0x20)
            }
        }
        ElseIf (Arg0 >= 0x20)
        {
            If (FBCX == FBCS) { FLIN () }
            Local0 = Arg0
            If (Local0 >= 0x7F) { Local0 = 0x3F }
            FGLY (Local0)
            Increment (FBCX)
        }
        Return (One)
    }

    Method (SPUT, 1, NotSerialized)
    {
        While (!(STAT & 0x20)) {}
        DATA = Arg0
    }

    Method (PUTC, 1, NotSerialized)
    {
        SPUT (Arg0)
        FPUT (Arg0)
    }

    Method (PUTT, 1, NotSerialized)
    {
        Local0 = Zero
        While (Local0 < SizeOf (Arg0))
        {
            PUTC (DerefOf (Index (Arg0, Local0)))
            Increment (Local0)
        }
    }

    Method (PUTS, 1, NotSerialized)
    {
        PUTT (Arg0)
        PUTC (0x0D)
        PUTC (0x0A)
    }

    Name (GDTA, Buffer (56) {})
    // Four bytes of padding align the hardware RSP0 field.
    Name (TSSA, Buffer (108) {})
    Name (IDTA, Buffer (4096) {})
    Name (GDTR, Buffer (10) {})
    Name (IDTR, Buffer (10) {})
    Name (CSLE, 0x08)
    Name (DSLE, 0x10)
    Name (UDSL, 0x1B)
    Name (UCSL, 0x23)
    Name (TRSL, 0x28)

    Method (SGDT, 0, Serialized)
    {
        CreateQWordField (GDTA, 8, CODE)
        CreateQWordField (GDTA, 16, DSEG)
        CODE = 0x00AF9A000000FFFF
        DSEG = 0x00CF92000000FFFF

        CreateQWordField (GDTA, 24, UDAT)
        CreateQWordField (GDTA, 32, UCOD)
        UDAT = 0x00CFF2000000FFFF
        UCOD = 0x00AFFA000000FFFF

        CreateQWordField (GDTA, 40, TSDL)
        CreateQWordField (GDTA, 48, TSDH)
        Local0 = XADR (TSSA) + 4
        TSDL = 103 | ((Local0 & 0xFFFFFF) << 16) | (0x89 << 40) |
            ((Local0 & 0xFF000000) << 32)
        TSDH = Local0 >> 32
        CreateWordField (TSSA, 106, IOPB)
        IOPB = 104

        CreateWordField (GDTR, Zero, GLIM)
        CreateQWordField (GDTR, 2, GBAS)
        GLIM = SizeOf (GDTA) - One
        GBAS = XADR (GDTA)
        XGDT (GDTR, CSLE, DSLE)
        XTRG (TRSL)
    }

    Method (SIDT, 0, Serialized)
    {
        Local0 = XADR (IDTA)
        Local1 = IVEC
        Local2 = Zero
        While (Local2 < 256)
        {
            Local3 = (Local1 & 0xFFFF) | (CSLE << 16) | (0x8E << 40) |
                ((Local1 & 0xFFFF0000) << 32)
            XVWD (Local0, Local3)
            XVWD (Local0 + 8, Local1 >> 32)
            Local0 += 16
            Local1 += 16
            Increment (Local2)
        }

        CreateWordField (IDTR, Zero, ILIM)
        CreateQWordField (IDTR, 2, IBAS)
        ILIM = SizeOf (IDTA) - One
        IBAS = XADR (IDTA)
        XIDT (IDTR)
    }

    Name (HEXD, "0123456789abcdef")
    Name (REGS, Package () {
        "R15", "R14", "R13", "R12", "R11", "R10", "R9", "R8",
        "RDI", "RSI", "RBP", "RBX", "RDX", "RCX", "RAX",
        "RIP", "CS", "RFLAGS", "RSP", "SS"
    })

    Method (GETR, 2, Serialized)
    {
        CreateQWordField (Arg0, Arg1 * 8, WORD)
        Return (WORD)
    }

    Method (PHEX, 1, NotSerialized)
    {
        Local0 = 64
        While (Local0)
        {
            Local0 -= 4
            Local1 = (Arg0 >> Local0) & 0xF
            PUTC (DerefOf (Index (HEXD, Local1)))
        }
    }

    Method (PNUM, 2, NotSerialized)
    {
        PUTT (Arg0)
        PHEX (Arg1)
    }

    // ACPI checksums are the sum of all bytes modulo 256.
    Method (CHKS, 2, NotSerialized)
    {
        If (Arg1 > (Ones - Arg0)) { Return (Zero) }
        Local0 = Zero
        Local1 = Zero
        While (Local0 < Arg1)
        {
            Local2 = XMEM (Arg0 + Local0, One)
            If (Local2 == Ones) { Return (Zero) }
            Local1 = (Local1 + Local2) & 0xFF
            Increment (Local0)
        }
        Return (Local1 == Zero)
    }

    // Verify an ACPI system description table and return its length.
    Method (SDTL, 3, NotSerialized)
    {
        If (XMEM (Arg0, 4) != Arg1) { Return (Zero) }
        Local0 = XMEM (Arg0 + 4, 4)
        If (Local0 == Ones || Local0 < Arg2) { Return (Zero) }
        If (!CHKS (Arg0, Local0)) { Return (Zero) }
        Return (Local0)
    }

    Method (PTXT, 2, NotSerialized)
    {
        Local0 = Zero
        While (Local0 < Arg1)
        {
            Local1 = XMEM (Arg0 + Local0, One)
            If (Local1 < 0x20 || Local1 > 0x7E) { Local1 = 0x2E }
            PUTC (Local1)
            Increment (Local0)
        }
    }

    Method (PTBL, 1, NotSerialized)
    {
        Local0 = XMEM (Arg0, 4)
        Local1 = XMEM (Arg0 + 4, 4)
        Local2 = 36
        If (Local0 == 0x53434146) { Local2 = 64 } // FACS
        If (Local0 == Ones || Local1 == Ones || Local1 < Local2 ||
            Local1 > (Ones - Arg0) || XMEM (Arg0 + Local2 - One, One) == Ones)
        {
            PNUM ("ACPI unreadable table at 0x", Arg0)
            PUTS ("")
            Return (Zero)
        }

        PUTT ("ACPI table ")
        PTXT (Arg0, 4)
        PNUM (" address=0x", Arg0)
        PNUM (" size=0x", Local1)
        If (Local2 == 64)
        {
            PNUM (" version=0x", XMEM (Arg0 + 32, One))
        }
        Else
        {
            PNUM (" revision=0x", XMEM (Arg0 + 8, One))
            PNUM (" checksum=0x", XMEM (Arg0 + 9, One))
            PUTT (" OEM ID=")
            PTXT (Arg0 + 10, 6)
            PUTT (" OEM table ID=")
            PTXT (Arg0 + 16, 8)
            PNUM (" OEM revision=0x", XMEM (Arg0 + 24, 4))
            PUTT (" creator ID=")
            PTXT (Arg0 + 28, 4)
            PNUM (" creator revision=0x", XMEM (Arg0 + 32, 4))
        }
        PUTS ("")
        Return (Local1)
    }

    // Prefer the 64-bit FADT pointer when the field is present and nonzero.
    Method (FREF, 5, NotSerialized)
    {
        Local0 = Zero
        If (Arg1 >= (Arg3 + 8)) { Local0 = XMEM (Arg0 + Arg3, 8) }
        If (Local0 == Zero && Arg1 >= (Arg2 + 4))
        {
            Local0 = XMEM (Arg0 + Arg2, 4)
        }
        If (Local0 == Zero) { Return (Zero) }
        If (XMEM (Local0, 4) != Arg4)
        {
            PNUM ("ACPI invalid FADT table reference at 0x", Local0)
            PUTS ("")
            Return (Zero)
        }
        Return (PTBL (Local0))
    }

    Method (PLAP, 4, NotSerialized)
    {
        PNUM (Arg0, Arg1)
        PNUM (" ACPI UID=0x", Arg2)
        PNUM (" flags=0x", Arg3)
        PUTS ("")
    }

    Method (MADT, 2, NotSerialized)
    {
        Local0 = 44
        Local1 = XMEM (Arg0 + 36, 4)
        While (Local0 < Arg1)
        {
            Local2 = Arg1 - Local0
            If (Local2 < 2) { Break }
            Local3 = Arg0 + Local0
            Local4 = XMEM (Local3, One)
            Local5 = XMEM (Local3 + One, One)
            If (Local5 < 2 || Local5 > Local2) { Break }
            If (Local4 == Zero)
            {
                If (Local5 < 8) { Break }
                PLAP ("LAPIC ID=0x", XMEM (Local3 + 3, One),
                    XMEM (Local3 + 2, One), XMEM (Local3 + 4, 4))
            }
            ElseIf (Local4 == One)
            {
                If (Local5 < 12) { Break }
                PNUM ("IOAPIC ID=0x", XMEM (Local3 + 2, One))
                PNUM (" address=0x", XMEM (Local3 + 4, 4))
                PNUM (" GSI base=0x", XMEM (Local3 + 8, 4))
                PUTS ("")
            }
            ElseIf (Local4 == 5)
            {
                If (Local5 < 12) { Break }
                Local1 = XMEM (Local3 + 4, 8)
            }
            ElseIf (Local4 == 9)
            {
                If (Local5 < 16) { Break }
                PLAP ("x2APIC ID=0x", XMEM (Local3 + 4, 4),
                    XMEM (Local3 + 12, 4), XMEM (Local3 + 8, 4))
            }
            Local0 += Local5
        }
        If (Local0 != Arg1)
        {
            PUTS ("ACPI MADT has a malformed entry")
            Return (Zero)
        }
        PNUM ("LAPIC address=0x", Local1)
        PUTS ("")
        TRDY = TMRS (Arg0, Arg1, Local1)
        If (!TRDY) { PUTS ("APIC timer setup failed") }
        Return (One)
    }

    Name (PIVC, 0x20)
    Name (LAVC, 0x21)
    Name (KBVC, 0x23)
    Name (MSVC, 0x24)
    Name (MSBA, Zero)
    Name (MSRE, Zero)
    Name (MSFL, Zero)
    Name (MSRD, Zero)
    Name (KCFG, Zero)
    Name (SVEC, 0xFF)
    Name (IMSK, 0x10000)
    Name (IPOL, 0x2000)
    Name (ILVL, 0x8000)
    Name (LAVA, 0xFFFFFF0000000000)
    Name (IOVA, 0xFFFFFF0000001000)
    Name (X2EN, Zero)
    Name (PIBA, Zero)
    Name (PIRE, Zero)
    Name (PIFL, Zero)
    Name (ISFL, Zero)
    Name (KBBA, Zero)
    Name (KBRE, Zero)
    Name (KBFL, Zero)
    Name (KRDY, Zero)
    Name (TWAI, 1000000000)
    Name (TRDY, Zero)
    Name (TICK, Zero)

    Method (XNXE, 0, NotSerialized)
    {
        Return ((XMSR (0xC0000080, Ones) >> 11) & One) // EFER.NXE
    }

    // Map controller pages with the legacy uncacheable PAT selection.
    Method (MMIO, 2, NotSerialized)
    {
        Local0 = WRIT | 0x18
        If (XNXE ()) { Local0 |= NOEX }
        Return (VMAP (Arg0, Arg1, Local0))
    }

    Method (LREG, 2, NotSerialized)
    {
        If (X2EN) { Return (XMSR (0x800 + (Arg0 >> 4), Arg1)) }
        Return (XDWD (LAVA + Arg0, Arg1))
    }

    Method (LSET, 1, NotSerialized)
    {
        If (!XAPC ()) { Return (Zero) }
        Local0 = XMSR (0x1B, Ones)
        X2EN = Local0 & 0x400
        If (!X2EN)
        {
            If ((Local0 & PMSK) != Arg0 || !MMIO (LAVA, Arg0)) { Return (Zero) }
            If (!(Local0 & 0x800)) { XMSR (0x1B, Local0 | 0x800) }
        }

        // Quiesce local sources, then enable the LAPIC with a spurious vector.
        Local1 = (LREG (0x30, Ones) >> 16) & 0xFF
        LREG (0x320, IMSK | LAVC)
        LREG (0x380, Zero)
        LREG (0x350, IMSK)
        LREG (0x360, IMSK)
        LREG (0x370, IMSK | 0xFE)
        If (Local1 >= 4) { LREG (0x340, IMSK) } // Performance counter
        If (Local1 >= 5) { LREG (0x330, IMSK) } // Thermal
        If (Local1 >= 6) { LREG (0x2F0, IMSK) } // CMCI
        LREG (0x80, Zero)
        LREG (0xF0, 0x100 | SVEC)
        Return (One)
    }

    Method (IREG, 3, NotSerialized)
    {
        XDWD (Arg0, Arg1)
        Return (XDWD (Arg0 + 0x10, Arg2))
    }

    // Locate the ISA IRQ override, including its polarity and trigger mode.
    Method (ISOV, 3, NotSerialized)
    {
        ISFL = Zero
        Local0 = 44
        While (Local0 < Arg1)
        {
            Local1 = Arg0 + Local0
            If (XMEM (Local1, One) == 2 && XMEM (Local1 + One, One) >= 10 &&
                XMEM (Local1 + 2, One) == Zero && XMEM (Local1 + 3, One) == Arg2)
            {
                Local2 = XMEM (Local1 + 8, One) | (XMEM (Local1 + 9, One) << 8)
                If ((Local2 & ~0xF) || (Local2 & 3) == 2 || (Local2 & 0xC) == 8)
                {
                    Return (Ones)
                }
                If ((Local2 & 3) == 3) { ISFL |= IPOL }
                If ((Local2 & 0xC) == 0xC) { ISFL |= ILVL }
                Return (XMEM (Local1 + 4, 4))
            }
            Local0 += XMEM (Local1 + One, One)
        }
        Return (Arg2)
    }

    // Mask firmware routes and find the I/O APIC and pins covering the PIT, keyboard, and mouse GSIs.
    Method (ISET, 5, NotSerialized)
    {
        Local0 = 44
        While (Local0 < Arg1)
        {
            Local1 = Arg0 + Local0
            If (XMEM (Local1, One) == One)
            {
                Local2 = IOVA + XMEM (Local1 + 2, One) * PGSZ
                If (!MMIO (Local2, XMEM (Local1 + 4, 4))) { Return (Zero) }
                Local3 = (IREG (Local2, One, Ones) >> 16) & 0xFF
                If (Local3 >= 120) { Return (Zero) }
                Local4 = Zero
                While (Local4 <= Local3)
                {
                    IREG (Local2, 0x10 + 2 * Local4, IMSK)
                    Increment (Local4)
                }
                Local5 = XMEM (Local1 + 8, 4)
                If (Arg2 >= Local5 && Arg2 - Local5 <= Local3)
                {
                    If (PIBA) { Return (Zero) }
                    PIBA = Local2
                    PIRE = 0x10 + 2 * (Arg2 - Local5)
                }
                If (Arg3 >= Local5 && Arg3 - Local5 <= Local3)
                {
                    If (KBBA) { Return (Zero) }
                    KBBA = Local2
                    KBRE = 0x10 + 2 * (Arg3 - Local5)
                }
                If (Arg4 >= Local5 && Arg4 - Local5 <= Local3)
                {
                    If (MSBA) { Return (Zero) }
                    MSBA = Local2
                    MSRE = 0x10 + 2 * (Arg4 - Local5)
                }
            }
            Local0 += XMEM (Local1 + One, One)
        }
        Return (PIBA != Zero)
    }

    Name (KSNM, Buffer () {0x6B, 0x62, 0x64})
    Name (KSND, Zero)
    Name (KSOP, Zero) // One open file description owns raw input
    Name (KSBF, Buffer (512) {})
    Name (KSHD, Zero)
    Name (KSTL, Zero)
    Name (KSEX, Zero)

    // Set 1 byte plus an extended-key flag in bit 8. Pause is ignored.
    Method (KSIR, 1, NotSerialized)
    {
        If (KSKP) { Decrement (KSKP)
            Return (Zero) }
        If (Arg0 == 0xE1) { KSKP = 5
            KSEX = Zero
            Return (Zero) }
        If (Arg0 == 0xE0) { KSEX = One
            Return (Zero) }
        Local0 = (KSTL + 2) & 511
        If (Local0 == KSHD) { KSHD = (KSHD + 2) & 511 }
        XSTB (XADR (KSBF) + KSTL, Arg0)
        XSTB (XADR (KSBF) + KSTL + One, KSEX)
        KSTL = Local0
        KSEX = Zero
        Return (Zero)
    }

    Method (KSRD, 3, NotSerialized)
    {
        If (!Arg2) { Return (Zero) }
        If (Arg2 < 2) { Return (Zero - 22) }
        If (KSHD == KSTL) { Return (Zero - 11) } // EAGAIN
        If (!UCOP (Arg0, Arg1, XADR (KSBF) + KSHD, 2)) { Return (Zero - 14) }
        KSHD = (KSHD + 2) & 511
        Return (2)
    }

    Name (MSNM, Buffer () {0x6D, 0x6F, 0x75, 0x73, 0x65})
    Name (MSND, Zero)
    Name (MSOP, Zero)
    Name (MSBF, Buffer (512) {})
    Name (MSHD, Zero)
    Name (MSTL, Zero)
    Name (MSCT, Zero)
    Name (MSPH, Zero)
    Name (MSDX, Zero)

    // Each record is signed LE16 dx, signed LE16 dy (down positive),
    // a PS/2 button-state byte, and three reserved zero bytes.
    Method (MSPK, 1, NotSerialized)
    {
        If (!MSCT)
        {
            If (!(Arg0 & 8)) { Return (Zero) }
            MSPH = Arg0
            MSCT = One
            Return (Zero)
        }
        If (MSCT == One)
        {
            MSDX = Arg0
            MSCT = 2
            Return (Zero)
        }
        MSCT = Zero
        If (!MSOP) { Return (Zero) }

        Local0 = MSDX
        Local1 = Arg0
        If (MSPH & 0x10) { Local0 -= 256 }
        If (MSPH & 0x20) { Local1 -= 256 }
        If (MSPH & 0x40) { Local0 = Zero }
        If (MSPH & 0x80) { Local1 = Zero }
        Local2 = (MSTL + 8) & 511
        If (Local2 == MSHD) { MSHD = (MSHD + 8) & 511 }
        XSTQ (XADR (MSBF) + MSTL,
            (Local0 & 0xFFFF) | (((Zero - Local1) & 0xFFFF) << 16) | ((MSPH & 7) << 32))
        MSTL = Local2
        Return (Zero)
    }

    Method (MSRR, 3, NotSerialized)
    {
        If (!Arg2) { Return (Zero) }
        If (Arg2 < 8) { Return (Zero - 22) }
        If (MSHD == MSTL) { Return (Zero - 11) }
        If (!UCOP (Arg0, Arg1, XADR (MSBF) + MSHD, 8)) { Return (Zero - 14) }
        MSHD = (MSHD + 8) & 511
        Return (8)
    }

    Name (KBUF, Buffer (128) {})
    Name (KBHD, Zero)
    Name (KBTL, Zero)
    Name (KEND, Zero) // End of input available to readers
    Name (KCAN, Zero) // Edit and echo lines for the interactive init process
    Name (KMOD, Zero)
    Name (KSKP, Zero)
    Name (KRHD, Zero)
    Name (KRTL, Zero)

    // US key maps for translated set 1 make codes through 0x3f.
    Name (KLOW, Buffer (64)
    {
        0x00, 0x00, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x30, 0x2D, 0x3D, 0x08, 0x00,
        0x71, 0x77, 0x65, 0x72, 0x74, 0x79, 0x75, 0x69, 0x6F, 0x70, 0x5B, 0x5D, 0x0A, 0x00, 0x61, 0x73,
        0x64, 0x66, 0x67, 0x68, 0x6A, 0x6B, 0x6C, 0x3B, 0x27, 0x60, 0x00, 0x5C, 0x7A, 0x78, 0x63, 0x76,
        0x62, 0x6E, 0x6D, 0x2C, 0x2E, 0x2F, 0x00, 0x00, 0x00, 0x20, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
    })
    Name (KUPP, Buffer (64)
    {
        0x00, 0x00, 0x21, 0x40, 0x23, 0x24, 0x25, 0x5E, 0x26, 0x2A, 0x28, 0x29, 0x5F, 0x2B, 0x08, 0x00,
        0x51, 0x57, 0x45, 0x52, 0x54, 0x59, 0x55, 0x49, 0x4F, 0x50, 0x7B, 0x7D, 0x0A, 0x00, 0x41, 0x53,
        0x44, 0x46, 0x47, 0x48, 0x4A, 0x4B, 0x4C, 0x3A, 0x22, 0x7E, 0x00, 0x7C, 0x5A, 0x58, 0x43, 0x56,
        0x42, 0x4E, 0x4D, 0x3C, 0x3E, 0x3F, 0x00, 0x00, 0x00, 0x20, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
    })

    // Bounded status waits are used only while programming the controller.
    Method (KBWT, 2, NotSerialized)
    {
        Local0 = 0x10000
        While (Local0)
        {
            If ((KSTA & Arg0) == Arg1) { Return (One) }
            Decrement (Local0)
        }
        Return (Zero)
    }

    Method (KBCM, 1, NotSerialized)
    {
        If (!KBWT (2, Zero)) { Return (Zero) }
        KSTA = Arg0
        Return (One)
    }

    Method (KBDT, 1, NotSerialized)
    {
        If (!KBWT (2, Zero)) { Return (Zero) }
        KDAT = Arg0
        Return (One)
    }

    Method (KBSC, 1, NotSerialized)
    {
        Local0 = 3
        While (Local0)
        {
            If (!KBDT (Arg0)) { Return (Zero) }
            If (!KBWT (One, One)) { Return (Zero) }
            Local1 = KDAT
            If (Local1 == 0xFA) { Return (One) } // ACK
            If (Local1 != 0xFE) { Return (Zero) } // RESEND
            Decrement (Local0)
        }
        Return (Zero)
    }

    Method (KSET, 1, NotSerialized)
    {
        If (!KBBA || (KBBA == PIBA && KBRE == PIRE)) { Return (Zero) }
        If (!KBCM (0xAD)) { Return (Zero) } // Disable first port
        If (!KBCM (0xA7)) { Return (Zero) } // Disable second port

        Local0 = 32
        While (Local0 && (KSTA & One))
        {
            Local1 = KDAT
            Decrement (Local0)
        }
        If (!Local0 || !KBCM (0x20)) { Return (Zero) } // Read config
        If (!KBWT (One, One)) { Return (Zero) }
        Local1 = (KDAT & ~0x53) | 0x20 // IRQs and translation off, second port disabled
        If (!KBCM (0x60)) { Return (Zero) }
        If (!KBDT (Local1)) { Return (Zero) }
        If (!KBCM (0xAE)) { Return (Zero) }
        If (!KBSC (0xF5)) { Return (Zero) } // Disable scanning
        If (!KBSC (0xF0)) { Return (Zero) } // Select scan code set
        If (!KBSC (2)) { Return (Zero) }
        If (!KBSC (0xF4)) { Return (Zero) } // Enable scanning

        IREG (KBBA, KBRE + One, Arg0 << 24)
        IREG (KBBA, KBRE, KBVC | KBFL)
        If (!KBCM (0x60) || !KBWT (2, Zero))
        {
            IREG (KBBA, KBRE, IMSK)
            Return (Zero)
        }
        KCFG = Local1 | 0x41 // Set 1 translation and first-port IRQ enabled
        KDAT = KCFG
        Return (One)
    }

    Method (MSSC, 1, NotSerialized)
    {
        Local0 = 3
        While (Local0)
        {
            If (!KBCM (0xD4) || !KBDT (Arg0)) { Return (Zero) }
            Local1 = 0x10000
            While (Local1)
            {
                Local2 = KSTA
                If ((Local2 & 0x21) == 0x21)
                {
                    Local3 = KDAT
                    If (Local2 & 0xC0) { Return (Zero) }
                    If (Local3 == 0xFA) { Return (One) }
                    If (Local3 != 0xFE) { Return (Zero) }
                    Break
                }
                If (Local2 & One) { KIRQ () }
                Decrement (Local1)
            }
            If (!Local1) { Return (Zero) }
            Decrement (Local0)
        }
        Return (Zero)
    }

    Method (MSST, 1, NotSerialized)
    {
        If (!MSBA || (MSBA == PIBA && MSRE == PIRE) ||
            (MSBA == KBBA && MSRE == KBRE)) { Return (Zero) }
        If (!KBCM (0xA8)) { Return (Zero) } // Enable auxiliary port
        If (MSSC (0xF6) && MSSC (0xF4))
        {
            IREG (MSBA, MSRE + One, Arg0 << 24)
            IREG (MSBA, MSRE, MSVC | MSFL)
            If (KBCM (0x60) && KBDT ((KCFG & ~0x20) | 2)) { Return (One) }
            IREG (MSBA, MSRE, IMSK)
        }
        KBCM (0xA7)
        Return (Zero)
    }

    Method (KERS, 0, NotSerialized)
    {
        PUTC (8)
        SPUT (0x20)
        SPUT (8)
    }

    Method (KIRQ, 0, NotSerialized)
    {
        Local0 = KSTA
        If (!(Local0 & One)) { Return (Zero) }
        Local1 = KDAT
        If (Local0 & 0x20)
        {
            If (Local0 & 0xC0) { MSCT = Zero }
            ElseIf (MSRD) { MSPK (Local1) }
            Return (Zero)
        }
        If (Local0 & 0xC0) { Return (Zero) }

        If (KSOP) { Return (KSIR (Local1)) }

        If (KSKP)
        {
            Decrement (KSKP)
            Return (Zero)
        }
        If (Local1 == 0xE0) { KSKP = One
            Return (Zero) }
        If (Local1 == 0xE1) { KSKP = 5
            Return (Zero) }

        Local2 = Local1 & 0x7F
        If (Local2 == 0x2A || Local2 == 0x36)
        {
            Local3 = One
            If (Local2 == 0x36) { Local3 = 2 }
            If (Local1 & 0x80) { KMOD &= ~Local3 }
            Else { KMOD |= Local3 }
            Return (Zero)
        }
        If (Local1 & 0x80) { Return (Zero) }
        If (Local2 == 0x3A) { KMOD ^= 4
            Return (Zero) }
        If (Local2 >= 64) { Return (Zero) }

        Local3 = XBYT (XADR (KLOW) + Local2)
        Local4 = ((KMOD & 3) != Zero)
        If ((KMOD & 4) && Local3 >= 0x61 && Local3 <= 0x7A)
        {
            Local4 = !Local4
        }
        If (Local4) { Local3 = XBYT (XADR (KUPP) + Local2) }
        If (!Local3) { Return (Zero) }

        If (KCAN && Local3 == 8)
        {
            If (KBTL != KEND)
            {
                KBTL = (KBTL - One) & 127
                KERS ()
            }
            Return (Zero)
        }

        Local4 = (KBTL + One) & 127
        If (Local4 == KBHD) { Return (Zero) }
        // Keep room for Enter even when the editable input fills the ring.
        If (KCAN && Local3 != 0x0A && ((Local4 + One) & 127) == KBHD)
        {
            Return (Zero)
        }
        XSTB (XADR (KBUF) + KBTL, Local3)
        KBTL = Local4
        If (KCAN)
        {
            If (Local3 != 0x0A)
            {
                PUTC (Local3)
                Return (Zero)
            }
            PUTS ("")
        }
        KEND = KBTL
        Return (One)
    }

    // For level-triggered IRQs, finish the PIT assertion before LAPIC EOI.
    Method (PEOI, 0, NotSerialized)
    {
        If (PIFL & ILVL)
        {
            Local0 = 0x10000
            Local1 = Zero
            If (PIFL & IPOL) { Local1 = 0x80 }
            While (Local0)
            {
                PCMD = 0xE2 // Latch channel 0 status only.
                If ((PDAT & 0x80) == Local1) { Break }
                Decrement (Local0)
            }
            If (!Local0) { Return (Zero) }
        }
        LREG (0xB0, Zero)
        Return (One)
    }

    Method (PCAL, 0, NotSerialized)
    {
        // PIT channel 0 mode 2, divisor 11932, roughly 100 Hz.
        // Use a square wave for level routes so deassertion can be observed.
        Local2 = 0x34
        If (PIFL & ILVL) { Local2 = 0x36 }
        PCMD = Local2
        PDAT = 0x9C
        PDAT = 0x2E
        IREG (PIBA, PIRE, PIVC | PIFL)
        If (XWAI (TWAI) != PIVC) { Return (Zero) }

        // Divide LAPIC clock by 16 and measure four PIT periods.
        LREG (0x3E0, 3)
        LREG (0x380, 0xFFFFFFFF)
        Local0 = Zero
        While (Local0 < 4)
        {
            If (!PEOI ()) { Return (Zero) }
            If (XWAI (TWAI) != PIVC) { Return (Zero) }
            Increment (Local0)
        }
        Local1 = LREG (0x390, Ones)
        If (!Local1 || Local1 == 0xFFFFFFFF) { Return (Zero) }
        Return ((0xFFFFFFFF - Local1 + 2) / 4)
    }

    // Count delivered LAPIC ticks and acknowledge any latched IRQ.
    Method (TACK, 1, NotSerialized)
    {
        If (Arg0 == LAVC)
        {
            Increment (TICK)
            SWAK ()
        }
        Local0 = Zero
        If (Arg0 == KBVC || Arg0 == MSVC) { Local0 = KIRQ () }
        If (Arg0) { LREG (0xB0, Zero) }
        If (Local0) { KWAK () }
        If (Arg0 == LAVC || Arg0 == KBVC || Arg0 == MSVC) { PWAK () }
    }

    Method (TMRS, 3, NotSerialized)
    {
        If (!LSET (Arg2)) { Return (Zero) }
        If (XMEM (Arg0 + 40, 4) & One)
        {
            MIMR = 0xFF
            SIMR = 0xFF
        }
        Local0 = ISOV (Arg0, Arg1, Zero)
        PIFL = ISFL
        If (Local0 == Ones) { Return (Zero) }
        Local4 = ISOV (Arg0, Arg1, One)
        KBFL = ISFL
        Local5 = ISOV (Arg0, Arg1, 12)
        MSFL = ISFL
        If (!ISET (Arg0, Arg1, Local0, Local4, Local5)) { Return (Zero) }

        Local1 = LREG (0x20, Ones)
        If (!X2EN) { Local1 >>= 24 }
        If (Local1 >= 0xFF) { Return (Zero) }
        IREG (PIBA, PIRE + One, Local1 << 24)
        Local2 = PCAL ()
        IREG (PIBA, PIRE, IMSK | PIVC | PIFL)
        LREG (0xB0, Zero)
        LREG (0x380, Zero)
        If (!Local2) { Return (Zero) }

        PNUM ("PIT routed through IOAPIC GSI=0x", Local0)
        PUTS ("")
        PNUM ("LAPIC timer calibrated ticks per PIT period=0x", Local2)
        PUTS ("")
        LREG (0x320, 0x20000 | LAVC)
        LREG (0x380, Local2)

        While (TICK < 3)
        {
            Local3 = XWAI (TWAI)
            If (!Local3)
            {
                LREG (0x320, IMSK | LAVC)
                LREG (0x380, Zero)
                Return (Zero)
            }
            TACK (Local3)
        }
        PUTS ("LAPIC periodic timer delivered 3 interrupts")
        KRDY = KSET (Local1)
        If (KRDY)
        {
            PUTS ("PS/2 keyboard IRQ ready")
            MSRD = MSST (Local1)
        }
        If (MSRD) { PUTS ("PS/2 mouse IRQ ready") }
        If (!KRDY) { PUTS ("PS/2 keyboard unavailable") }
        Return (One)
    }

    Method (ACPI, 1, NotSerialized)
    {
        // Signatures are encoded as little-endian integers.
        If (XMEM (Arg0, 8) != 0x2052545020445352 || !CHKS (Arg0, 20))
        {
            PUTS ("ACPI RSDP missing or invalid")
            Return (Zero)
        }

        Local0 = Zero
        Local1 = Zero
        Local2 = 20
        Local3 = XMEM (Arg0 + 15, One)
        If (Local3 >= 2)
        {
            Local4 = XMEM (Arg0 + 20, 4)
            If (Local4 != Ones && Local4 >= 36 && CHKS (Arg0, Local4))
            {
                Local2 = Local4
                Local0 = XMEM (Arg0 + 24, 8)
                Local1 = SDTL (Local0, 0x54445358, 36) // XSDT
            }
        }
        PNUM ("ACPI table RSDP address=0x", Arg0)
        PNUM (" size=0x", Local2)
        PNUM (" revision=0x", Local3)
        PUTT (" OEM ID=")
        PTXT (Arg0 + 9, 6)
        PUTS ("")

        Local2 = 8
        If (Local1 < 36 || ((Local1 - 36) & 7))
        {
            Local0 = XMEM (Arg0 + 16, 4)
            Local1 = SDTL (Local0, 0x54445352, 36) // RSDT
            Local2 = 4
        }
        If (Local1 < 36 || ((Local1 - 36) & (Local2 - One)))
        {
            PUTS ("ACPI root table missing or invalid")
            Return (Zero)
        }

        PTBL (Local0)
        Local3 = 36
        Local6 = Zero
        Local7 = Zero
        While (Local3 < Local1)
        {
            Local4 = XMEM (Local0 + Local3, Local2)
            Local5 = PTBL (Local4)
            If (Local5)
            {
                If (XMEM (Local4, 4) == 0x50434146) // FACP (FADT)
                {
                    If (CHKS (Local4, Local5))
                    {
                        FREF (Local4, Local5, 36, 132, 0x53434146) // FACS
                        FREF (Local4, Local5, 40, 140, 0x54445344) // DSDT
                    }
                }
                ElseIf (Local7 == Zero)
                {
                    Local7 = SDTL (Local4, 0x43495041, 44) // APIC
                    If (Local7) { Local6 = Local4 }
                }
            }
            Local3 += Local2
        }
        If (Local7) { Return (MADT (Local6, Local7)) }
        PUTS ("ACPI MADT missing or invalid")
        Return (Zero)
    }

    Method (BRKP, 1, NotSerialized)
    {
        PUTS ("ASL breakpoint handler")
        Local0 = Zero
        While (Local0 < SizeOf (REGS))
        {
            PUTT (DerefOf (Index (REGS, Local0)))
            PUTT ("=0x")
            PHEX (GETR (Arg0, Local0))
            PUTC (0x0D)
            PUTC (0x0A)
            Increment (Local0)
        }
    }

    Name (PGSZ, 0x1000)
    Name (MIDX, Zero)
    Name (PNXT, Zero)
    Name (PEND, Zero)
    Name (PFRE, Zero)
    Name (PTOT, Zero)
    Name (PUSE, Zero)

    Method (XPLK, 2, NotSerialized) { Return (XVWD (HHDO + Arg0, Arg1)) }

    // Allocate a physical page. Zero indicates exhaustion.
    Method (PALC, 0, NotSerialized)
    {
        If (PFRE)
        {
            Local0 = PFRE
            PFRE = XPLK (Local0, Ones)
            XPLK (Local0, Zero)
        }
        Else
        {
            While (PNXT == PEND)
            {
                Local1 = XMAP (MIDX, Zero)
                If (Local1 == Ones)
                {
                    Return (Zero)
                }
                If (Local1)
                {
                    PNXT = Local1
                    PEND = XMAP (MIDX, One)
                }
                Increment (MIDX)
            }
            Local0 = PNXT
            PNXT += PGSZ
        }
        Increment (PUSE)
        Return (Local0)
    }

    // The caller must own the page and return it exactly once.
    Method (PDEL, 1, NotSerialized)
    {
        XPLK (Arg0, PFRE)
        PFRE = Arg0
        Decrement (PUSE)
    }

    Name (PMSK, 0x000FFFFFFFFFF000)
    Name (PRES, One)
    Name (WRIT, 0x02)
    Name (USER, 0x04)
    Name (LARG, 0x80)
    Name (NOEX, 0x8000000000000000)
    // R/W, U/S, PWT, PCD, global and NX.
    Name (VFLG, 0x800000000000019E) // Includes the leaf PAT bit
    // Bit 9 is software-owned. On leaves it marks VALL pages, on branches our tables.
    Name (VOWN, 0x200)
    Name (UANO, 0x400) // Anonymous user leaf eligible for mprotect

    Method (VPER, 2, NotSerialized)
    {
        Local0 = Arg1 & (WRIT | USER)
        Return (!(Arg0 & LARG) && (Arg0 & Local0) == Local0 &&
            (!(Arg0 & NOEX) || (Arg1 & NOEX)))
    }

    // Arguments are table virtual address, bit shift, virtual page and leaf entry.
    Method (VPTE, 4, NotSerialized)
    {
        Local0 = Arg0 + (((Arg2 >> Arg1) & 0x1FF) * 8)
        Local1 = XVWD (Local0, Ones)
        If (Arg1 == 12)
        {
            If (Local1 & PRES) { Return (Zero) }
            XVWD (Local0, Arg3)
            Return (One)
        }

        If (Local1 & PRES)
        {
            If (!VPER (Local1, Arg3)) { Return (Zero) }
            Return (VPTE (HHDO + (Local1 & PMSK), Arg1 - 9, Arg2, Arg3))
        }

        Local2 = PALC ()
        If (!Local2) { Return (Zero) }
        Local3 = HHDO + Local2
        XCLR (Local3)
        // Publish the new subtree only after the leaf has been installed.
        If (!VPTE (Local3, Arg1 - 9, Arg2, Arg3))
        {
            PDEL (Local2)
            Return (Zero)
        }

        // Allow either privilege and access mode at leaves in new tables.
        XVWD (Local0, Local2 | PRES | WRIT | USER | VOWN)
        Return (One)
    }

    // Map one caller-owned physical page at a canonical virtual page address.
    Method (VMAP, 3, Serialized)
    {
        If ((Arg0 & (PGSZ - One)) || !Arg1 || (Arg1 & ~PMSK) ||
            (Arg2 & ~VFLG) || ((Arg2 & NOEX) && !XNXE ()))
        {
            Return (Zero)
        }
        Local0 = Arg0 >> 47
        If (Local0 != Zero && Local0 != 0x1FFFF) { Return (Zero) }

        Local1 = XCR3 ()
        If (!Local1) { Return (Zero) }
        VINI (HHDO + Local1)
        If (!VPTE (HHDO + Local1, 39, Arg0, Arg1 | Arg2 | PRES))
        {
            Return (Zero)
        }

        XINV (Arg0)
        Return (One)
    }

    Name (VBEG, 0xFFFF800000000000)
    Name (VEND, 0xFFFFFF0000000000)
    // Anonymous kernel pages use the same write-back cache type as the direct map.
    Name (KAFL, 0x8000000000000102)

    // Snapshot inherited PML4 slots so neither allocation nor release
    // traverses bootloader tables or relies on their software bits.
    Name (VRDY, Zero)
    Name (VRS0, Zero)
    Name (VRS1, Zero)
    Name (VRS2, Zero)
    Name (VRS3, Zero)

    Method (VRBT, 2, NotSerialized)
    {
        Local0 = Zero
        Local1 = Zero
        While (Local1 < 64)
        {
            If (XVWD (Arg0 + (Arg1 + Local1) * 8, Ones))
            {
                Local0 |= One << Local1
            }
            Increment (Local1)
        }
        Return (Local0)
    }

    Method (VINI, 1, NotSerialized)
    {
        If (!VRDY)
        {
            VRS0 = VRBT (Arg0, 256)
            VRS1 = VRBT (Arg0, 320)
            VRS2 = VRBT (Arg0, 384)
            VRS3 = VRBT (Arg0, 448)
            VRDY = One
        }
    }

    Method (VRSV, 1, NotSerialized)
    {
        Local0 = (Arg0 >> 39) & 0xFF
        Local1 = One << (Local0 & 63)
        If (Local0 < 64) { Return (VRS0 & Local1) }
        If (Local0 < 128) { Return (VRS1 & Local1) }
        If (Local0 < 192) { Return (VRS2 & Local1) }
        Return (VRS3 & Local1)
    }

    // Report the size of the block covering this address, with PRES if
    // unavailable and VOWN if it is a present anonymous leaf.
    Method (VPRB, 3, NotSerialized)
    {
        If (VRSV (Arg1)) { Return ((One << 39) | PRES) }
        Local0 = Arg0
        Local1 = 39
        While (One)
        {
            Local2 = XVWD (Local0 + (((Arg1 >> Local1) & 0x1FF) * 8), Ones)
            Local3 = One << Local1
            If (!Local2) { Return (Local3) }
            If (Local1 == 12)
            {
                If (Local2 & PRES) { Return (Local3 | PRES | (Local2 & VOWN)) }
                Return (Local3 | PRES)
            }
            If (!(Local2 & PRES) || !VPER (Local2, Arg2))
            {
                Return (Local3 | PRES)
            }
            Local0 = HHDO + (Local2 & PMSK)
            Local1 -= 9
        }
        Return (Zero)
    }

    // Find the highest contiguous hole, skipping entire absent or blocked subtrees.
    Method (VFND, 3, NotSerialized)
    {
        Local0 = VEND
        Local1 = VEND
        While (Local0 > VBEG)
        {
            Local2 = VPRB (Arg0, Local0 - One, Arg2)
            Local3 = Local2 & PMSK
            Local0 = (Local0 - One) & ~(Local3 - One)
            If (Local2 & PRES) { Local1 = Local0 }
            If (Local1 - Local0 >= Arg1) { Return (Local1 - Arg1) }
        }
        Return (Zero)
    }

    // Remove a known anonymous leaf and reclaim any now-empty kernel tables.
    Method (VRMV, 4, NotSerialized)
    {
        Local0 = Arg0 + (((Arg2 >> Arg1) & 0x1FF) * 8)
        Local1 = XVWD (Local0, Ones)
        Local2 = Local1 & PMSK
        If (Arg1 != 12)
        {
            Local3 = HHDO + Local2
            VRMV (Local3, Arg1 - 9, Arg2, Arg3)
            If (!(Local1 & VOWN)) { Return (Zero) }
            Local4 = Local3 + PGSZ
            While (Local3 < Local4)
            {
                If (XVWD (Local3, Ones)) { Return (Zero) }
                Local3 += 8
            }
        }

        XVWD (Local0, Zero)
        XINV (Arg2)
        If (Arg1 != 12 || Arg3) { PDEL (Local2) }
        Return (One)
    }

    // Allocate zeroed anonymous backing for Length bytes and return its virtual base.
    Method (VALL, 2, Serialized)
    {
        If (!Arg0 || Arg0 > (VEND - VBEG) || (Arg1 & ~KAFL) ||
            ((Arg1 & NOEX) && !XNXE ()))
        {
            Return (Zero)
        }
        Local0 = XCR3 ()
        If (!Local0) { Return (Zero) }
        Local0 += HHDO
        VINI (Local0)
        Local1 = (Arg0 + PGSZ - One) & ~(PGSZ - One)
        Local2 = VFND (Local0, Local1, Arg1)
        If (!Local2) { Return (Zero) }

        Local3 = Local2
        Local4 = Local2 + Local1
        While (Local3 < Local4)
        {
            Local5 = PALC ()
            If (!Local5) { Break }
            XCLR (HHDO + Local5)
            If (!VPTE (Local0, 39, Local3, Local5 | Arg1 | PRES | VOWN))
            {
                PDEL (Local5)
                Break
            }
            XINV (Local3)
            Local3 += PGSZ
        }
        If (Local3 == Local4) { Return (Local2) }

        While (Local3 > Local2)
        {
            Local3 -= PGSZ
            VRMV (Local0, 39, Local3, One)
        }
        Return (Zero)
    }

    // As with munmap, the start must be aligned and the length rounds up.
    Method (VUNM, 2, Serialized)
    {
        If (Arg0 < VBEG || Arg0 >= VEND || (Arg0 & (PGSZ - One)) ||
            !Arg1 || Arg1 > (VEND - Arg0))
        {
            Return (Zero)
        }
        Local0 = XCR3 ()
        If (!Local0) { Return (Zero) }
        Local0 += HHDO
        VINI (Local0)
        Local1 = Arg0 + ((Arg1 + PGSZ - One) & ~(PGSZ - One))

        // Validate the full interval before changing any mappings.
        Local2 = Arg0
        While (Local2 < Local1)
        {
            Local3 = VPRB (Local0, Local2, NOEX)
            If ((Local3 & (PRES | VOWN)) != (PRES | VOWN)) { Return (Zero) }
            Local2 += PGSZ
        }
        While (Local1 > Arg0)
        {
            Local1 -= PGSZ
            VRMV (Local0, 39, Local1, One)
        }
        Return (One)
    }

    // Expose only one free frame and verify that a failed allocation returns it.
    Method (VRTX, 0, NotSerialized)
    {
        Local0 = PALC ()
        If (!Local0) { Return (Zero) }
        Local1 = MIDX
        Local2 = PNXT
        Local3 = PFRE
        MIDX = Ones
        PNXT = PEND
        PFRE = Zero
        PDEL (Local0)

        Local4 = VALL (2 * PGSZ, WRIT)
        Local5 = PALC ()
        MIDX = Local1
        PNXT = Local2
        PFRE = Local3
        If (Local5) { PDEL (Local5) }
        Return (!Local4 && Local5 == Local0)
    }

    Method (VRTS, 0, NotSerialized)
    {
        If (VALL (Zero, WRIT) || VALL (PGSZ, USER) || VALL (Ones, WRIT))
        {
            Return (Zero)
        }
        Local0 = VALL (PGSZ + One, WRIT)
        If (!Local0) { Return (Zero) }
        Local1 = VALL (One, WRIT)
        If (!Local1 || (Local1 >= Local0 && Local1 < Local0 + 2 * PGSZ))
        {
            Return (Zero)
        }
        If (!VRTX ()) { Return (Zero) }
        If (XVWD (Local0, Ones) || XVWD (Local0 + PGSZ, Ones)) { Return (Zero) }
        XVWD (Local0, 0x1234)
        XVWD (Local0 + PGSZ, 0x5678)
        If (XVWD (Local0, Ones) != 0x1234 || XVWD (Local0 + PGSZ, Ones) != 0x5678 ||
            VUNM (Local0 + One, One) || XVWD (Local0, Ones) != 0x1234)
        {
            Return (Zero)
        }
        If (!VUNM (Local0, PGSZ + One)) { Return (Zero) }
        If (VUNM (Local0, PGSZ)) { Return (Zero) }

        Local2 = VALL (2 * PGSZ, WRIT)
        If (Local2 != Local0) { Return (Zero) }
        If (XVWD (Local2, Ones) || XVWD (Local2 + PGSZ, Ones)) { Return (Zero) }
        If (!VUNM (Local2, 2 * PGSZ)) { Return (Zero) }
        Return (VUNM (Local1, One))
    }

    Method (VTST, 0, NotSerialized)
    {
        Local0 = PALC ()
        If (!Local0) { Return (Zero) }
        Local1 = 0x0000400000000000
        If (VMAP (Local1 + One, Local0, WRIT) ||
            VMAP (0x0000800000000000, Local0, WRIT) ||
            VMAP (Local1, Local0 + One, WRIT) || VMAP (Local1, Zero, WRIT) ||
            VMAP (HHDO + Local0, Local0, WRIT) || VMAP (Local1, Local0, One))
        {
            Return (Zero)
        }
        If (!VMAP (Local1, Local0, WRIT))
        {
            PDEL (Local0)
            Return (Zero)
        }

        Local2 = Local1 + PGSZ
        Local3 = USER
        If (XNXE ()) { Local3 |= NOEX }
        If (VMAP (Local1, Local0, Local3) || !VMAP (Local2, Local0, Local3))
        {
            Return (Zero)
        }

        // Verify the leaf flags and user access through every ancestor.
        Local4 = HHDO + XCR3 ()
        Local5 = 39
        While (Local5 > 12)
        {
            Local6 = XVWD (Local4 + (((Local2 >> Local5) & 0x1FF) * 8), Ones)
            If ((Local6 & (PRES | USER)) != (PRES | USER)) { Return (Zero) }
            Local4 = HHDO + (Local6 & PMSK)
            Local5 -= 9
        }
        Local6 = XVWD (Local4 + (((Local2 >> 12) & 0x1FF) * 8), Ones)
        If (Local6 != (Local0 | Local3 | PRES)) { Return (Zero) }
        Local6 = XVWD (Local4 + (((Local1 >> 12) & 0x1FF) * 8), Ones)
        If (Local6 != (Local0 | WRIT | PRES)) { Return (Zero) }

        XVWD (Local1, Zero)
        If (XSTQ (Local1, Ones) || XVWD (Local1, Ones) != Ones) { Return (Zero) }
        XVWD (Local1, 0x0123456789ABCDEF)
        If (XPLK (Local0, Ones) != 0x0123456789ABCDEF) { Return (Zero) }
        XPLK (Local0, 0xFEDCBA9876543210)
        Local7 = (XVWD (Local2, Ones) == 0xFEDCBA9876543210)
        Local4 = HHDO + XCR3 ()
        VRMV (Local4, 39, Local2, Zero)
        VRMV (Local4, 39, Local1, One)
        Return (Local7)
    }

    // Indexed by the Limine memory map type.
    Name (MTYP, Package ()
    {
        "Usable", "Reserved", "ACPI Reclaimable", "ACPI NVS",
        "Bad Memory", "Bootloader Reclaimable", "Executable and Modules",
        "Framebuffer", "Reserved Mapped"
    })

    Method (PMAP, 0, NotSerialized)
    {
        PUTS ("Limine memory map")
        Local0 = Zero
        Local1 = XMAP (Local0, 4)
        While (Local1 != Ones)
        {
            Local2 = XMAP (Local0, Zero)
            If (Local2) { PTOT += (XMAP (Local0, One) - Local2) / PGSZ }
            PNUM ("Memory base=0x", XMAP (Local0, 2))
            PNUM (" length=0x", XMAP (Local0, 3))
            PUTT (" type=")
            If (Local1 < SizeOf (MTYP))
            {
                PUTS (DerefOf (Index (MTYP, Local1)))
            }
            Else
            {
                PUTS ("Unknown")
            }
            Increment (Local0)
            Local1 = XMAP (Local0, 4)
        }
    }

    Method (PTST, 0, NotSerialized)
    {
        Local0 = PALC ()
        Local1 = PALC ()
        If (!Local0 || !Local1 || Local0 == Local1 ||
            (Local0 & (PGSZ - One)) || (Local1 & (PGSZ - One)))
        {
            Return (Zero)
        }
        PNUM ("ASL page 1 physical=0x", Local0)
        PUTS ("")
        PNUM ("ASL page 2 physical=0x", Local1)
        PUTS ("")
        PDEL (Local0)
        PDEL (Local1)
        Local2 = PALC ()
        Local3 = PALC ()
        If (Local2 != Local1 || Local3 != Local0) { Return (Zero) }
        PDEL (Local3)
        PDEL (Local2)
        Return (One)
    }

    Name (SQHD, Zero)
    Name (SQTL, Zero)
    Name (TSIZ, 0x5000)
    // Task record: next pointer, saved frame pointer, entry argument.
    Name (TSFR, 8)
    Name (TSAR, 16)
    Name (TSUL, 24) // Physical address of the task's user range list
    Name (TSCR, 32) // Physical address of its private PML4, or zero
    Name (UPID, One) // Boot PID, including the legacy PID 0 init mode
    Name (PNID, 2)
    Name (PRHD, Zero)
    Name (PRTK, 8)  // Live task pointer, or zero for a zombie
    Name (PRID, 16)
    Name (PRPA, 24) // Parent process record
    Name (PRST, 32) // Encoded wait status
    Name (PRWT, 40) // Blocked in wait4
    Name (UPNM, Zero) // Boot module basename
    Name (TSFS, 40) // User FS base
    Name (TSFX, 0x1000) // Page-aligned XSAVE or FXSAVE area
    Name (TSPR, 48) // Process record in the direct map, zero for native tasks
    Name (TSCE, 56) // Close-on-exec bits indexed by descriptor number
    Name (TSFD, 552) // Pointers to shared open file descriptions
    Name (TSCL, 712) // Closed or redirected implicit console descriptors
    Name (TSPH, 736) // User virtual address of the ELF program header table
    Name (TSPN, 744) // Number of ELF program headers
    Name (WSTA, Buffer (4) {})
    CreateDWordField (WSTA, Zero, WVAL)
    Name (WRUS, Buffer (144) {}) // Zeroed Linux x86-64 struct rusage
    Name (FDLM, 19)
    Name (UPTH, Buffer (1024) {})
    Name (DENT, Buffer (280) {}) // Largest aligned linux_dirent64 record
    Name (DOTS, Buffer (3) {0x2E, 0x2E, 0})
    Name (EXZR, Buffer (512) {})
    Name (USTA, Buffer (144) {}) // Linux x86-64 struct stat
    Name (UTSN, Buffer (390) {}) // Linux new_utsname, six 65-byte fields
    Name (UTID, Package () {"ASL kernel", "localhost", "0.1.0", "AMLAOT", "x86_64"})
    Name (USTP, 0x0000008000000000)
    Name (USSZ, 0x10000) // 64 KiB per userspace task
    Name (SYEV, 0x80)
    Name (UFEV, 0x81)

    Method (SYIN, 0, NotSerialized)
    {
        XMSR (0xC0000081, (DSLE << 48) | (CSLE << 32)) // STAR
        XMSR (0xC0000082, SYEA)                    // LSTAR
        XMSR (0xC0000084, 0xFFFFFFFF)                 // FMASK
        XMSR (0xC0000080, XMSR (0xC0000080, Ones) | One)

        // Fill the identity once, leaving the padding and domain name zeroed.
        Local0 = Zero
        While (Local0 < SizeOf (UTID))
        {
            Local1 = DerefOf (Index (UTID, Local0))
            Local2 = Zero
            While (Local2 < SizeOf (Local1))
            {
                XSTB (XADR (UTSN) + Local0 * 65 + Local2, DerefOf (Index (Local1, Local2)))
                Increment (Local2)
            }
            Increment (Local0)
        }
    }

    // Refresh shared kernel entries while the kernel root is active.
    // The process never owns these entries or has ring-3 access to them.
    Method (UKRN, 1, NotSerialized)
    {
        Local0 = HHDO + XCR3 () + 256 * 8
        Local1 = HHDO + Arg0 + 256 * 8
        Local2 = Local0 + 256 * 8
        While (Local0 < Local2)
        {
            XVWD (Local1, XVWD (Local0, Ones) & ~USER)
            Local0 += 8
            Local1 += 8
        }
    }

    // Locate a user leaf even when PROT_NONE blocks access from ring 3.
    Method (UPTE, 2, NotSerialized)
    {
        Local0 = HHDO + XVWD (Arg0 + TSCR, Ones)
        Local1 = 39
        While (One)
        {
            Local2 = Local0 + (((Arg1 >> Local1) & 0x1FF) * 8)
            Local3 = XVWD (Local2, Ones)
            If (!(Local3 & PRES)) { Return (Zero) }
            If (Local1 == 12) { Return (Local2) }
            If (!(Local3 & USER) || (Local3 & LARG)) { Return (Zero) }
            Local0 = HHDO + (Local3 & PMSK)
            Local1 -= 9
        }
        Return (Zero)
    }

    // Translate a validated user address while staying in the kernel root.
    Method (UPHY, 3, NotSerialized)
    {
        Local0 = UPTE (Arg0, Arg1)
        If (!Local0) { Return (Zero) }
        Local1 = XVWD (Local0, Ones)
        Local2 = USER | Arg2
        If ((Local1 & Local2) != Local2) { Return (Zero) }
        Return (HHDO + (Local1 & PMSK) + (Arg1 & (PGSZ - One)))
    }

    // A range record occupies one physical page: next, base, mapped end.
    Method (UMAP, 7, NotSerialized)
    {
        Local0 = PALC ()
        If (!Local0) { Return (Zero) }
        Local1 = HHDO + Local0
        Local2 = Arg1 & ~(PGSZ - One)
        Local3 = (Arg1 + Arg2 + PGSZ - One) & ~(PGSZ - One)
        XVWD (Local1, XVWD (Arg0 + TSUL, Ones))
        XVWD (Local1 + 8, Local2)
        XVWD (Local1 + 16, Local2)
        XVWD (Local1 + 24, Arg3)
        XVWD (Arg0 + TSUL, Local0)

        While (Local2 < Local3)
        {
            Local4 = PALC ()
            If (!Local4) { Return (Zero) }
            Local5 = HHDO + Local4
            XCLR (Local5)
            Local6 = Local2
            If (Local6 < Arg1) { Local6 = Arg1 }
            If (Local6 < Arg1 + Arg5)
            {
                Local7 = Local2 + PGSZ
                If (Local7 > Arg1 + Arg5) { Local7 = Arg1 + Arg5 }
                If (Arg6)
                {
                    XMOV (Local5 + Local6 - Local2, Arg6 + Arg4 + Local6 - Arg1,
                        Local7 - Local6)
                }
                ElseIf (!XCPY (Local5 + Local6 - Local2, Arg4 + Local6 - Arg1,
                    Local7 - Local6))
                {
                    PDEL (Local4)
                    Return (Zero)
                }
            }
            If (!VPTE (HHDO + XVWD (Arg0 + TSCR, Ones), 39, Local2,
                Local4 | Arg3 | USER | PRES | VOWN))
            {
                PDEL (Local4)
                Return (Zero)
            }
            Local2 += PGSZ
            XVWD (Local1 + 16, Local2)
        }
        Return (One)
    }

    // Remove the user range linked from Arg1 (a task slot or previous record).
    Method (UDEL, 2, NotSerialized)
    {
        Local0 = XVWD (Arg1, Ones)
        Local1 = HHDO + Local0
        Local2 = XVWD (Local1 + 8, Ones)
        Local3 = XVWD (Local1 + 16, Ones)
        Local4 = HHDO + XVWD (Arg0 + TSCR, Ones)
        While (Local2 < Local3)
        {
            VRMV (Local4, 39, Local2, One)
            Local2 += PGSZ
        }
        XVWD (Arg1, XVWD (Local1, Ones))
        PDEL (Local0)
    }

    Method (SDEL, 1, NotSerialized)
    {
        Local0 = XVWD (Arg0 + TSCR, Ones)
        Local1 = Arg0 + TSFD
        While (Local1 < Arg0 + TSFD + FDLM * 8)
        {
            FDCL (Local1)
            Local1 += 8
        }
        VREL (VCWD (Arg0))
        While (XVWD (Arg0 + TSUL, Ones)) { UDEL (Arg0, Arg0 + TSUL) }
        If (Local0) { PDEL (Local0) }
        Return (VUNM (Arg0, TSIZ))
    }

    // Read an ELF field from the boot module or an already bounded archive image.
    Method (ELWD, 3, NotSerialized)
    {
        If (!Arg0) { Return (XIMG (Arg1, Arg2)) }
        Local0 = Zero
        Local1 = Zero
        While (Local1 < Arg2)
        {
            Local0 |= XBYT (Arg0 + Arg1 + Local1) << (Local1 * 8)
            Increment (Local1)
        }
        Return (Local0)
    }

    // Validate and load one PT_LOAD header. Return 2 if it covers the entry.
    Method (ELSG, 5, NotSerialized)
    {
        Local0 = ELWD (Arg4, Arg1 + 4, 4)  // p_flags
        Local1 = ELWD (Arg4, Arg1 + 8, 8)  // p_offset
        Local2 = ELWD (Arg4, Arg1 + 16, 8) // p_vaddr
        Local3 = ELWD (Arg4, Arg1 + 32, 8) // p_filesz
        Local4 = ELWD (Arg4, Arg1 + 40, 8) // p_memsz
        Local5 = ELWD (Arg4, Arg1 + 48, 8) // p_align
        Local6 = USTP - USSZ - PGSZ
        If ((Local0 & ~7) || !(Local0 & 4) || (Local0 & 3) == 3 ||
            Local1 > Arg2 || Local3 > Arg2 - Local1 || Local3 > Local4 ||
            Local2 < PGSZ || Local2 >= Local6 || Local4 > Local6 - Local2 ||
            ((Local2 ^ Local1) & (PGSZ - One)))
        {
            Return (Zero)
        }
        If (Local5 > One && ((Local5 & (Local5 - One)) ||
            ((Local2 ^ Local1) & (Local5 - One)))) { Return (Zero) }
        If (!Local4) { Return (One) }

        Local7 = Zero
        If (Local0 & 2) { Local7 |= WRIT }
        If (!(Local0 & One) && XNXE ()) { Local7 |= NOEX }
        If (!UMAP (Arg0, Local2, Local4, Local7, Local1, Local3, Arg4)) { Return (Zero) }
        If ((Local0 & One) && Arg3 >= Local2 && Arg3 - Local2 < Local3)
        {
            Return (2)
        }
        Return (One)
    }

    // Publish the program header table only when a load segment maps it in full.
    Method (ELPH, 3, NotSerialized)
    {
        If (XVWD (Arg0 + TSPH, Ones)) { Return (Zero) }
        Local0 = ELWD (Arg2, 32, 8)
        Local1 = ELWD (Arg2, 56, 2)
        Local2 = ELWD (Arg2, Arg1 + 8, 8) // p_offset
        Local3 = ELWD (Arg2, Arg1 + 32, 8) // p_filesz
        If (Local0 < Local2) { Return (Zero) }
        Local0 -= Local2
        If (Local0 > Local3 || Local1 * 56 > Local3 - Local0) { Return (Zero) }
        XSTQ (Arg0 + TSPH, ELWD (Arg2, Arg1 + 16, 8) + Local0)
        XSTQ (Arg0 + TSPN, Local1)
        Return (Zero)
    }

    Method (ELLD, 2, NotSerialized)
    {
        Local6 = Zero
        If (Arg1)
        {
            Local0 = XVWD (Arg1 + VNSZ, Ones)
            Local6 = XVWD (Arg1 + VNDA, Ones)
        }
        Else { Local0 = XIMG (Zero, Zero) }
        If (Local0 == Ones || Local0 < 64 ||
            (ELWD (Local6, Zero, 8) & 0x00FFFFFFFFFFFFFF) != 0x00010102464C457F ||
            ELWD (Local6, 16, 4) != 0x003E0002 || ELWD (Local6, 20, 4) != One ||
            ELWD (Local6, 52, 4) != 0x00380040)
        {
            Return (Zero)
        }
        Local1 = ELWD (Local6, 24, 8) // e_entry
        Local2 = ELWD (Local6, 32, 8) // e_phoff
        Local3 = ELWD (Local6, 56, 2) // e_phnum
        If (Local2 < 64 || Local2 > Local0 || !Local3 ||
            Local3 == 0xFFFF || Local3 > (Local0 - Local2) / 56)
        {
            Return (Zero)
        }

        Local4 = Zero
        While (Local3)
        {
            Local5 = ELWD (Local6, Local2, 4)
            If (Local5 == One)
            {
                Local5 = ELSG (Arg0, Local2, Local0, Local1, Local6)
                If (!Local5) { Return (Zero) }
                ELPH (Arg0, Local2, Local6)
                If (Local5 == 2) { Local4 = One }
            }
            ElseIf (Local5 == 2 || Local5 == 3 ||
                (Local5 == 0x6474E551 && (ELWD (Local6, Local2 + 4, 4) & One)))
            {
                Return (Zero)
            }
            Local2 += 56
            Decrement (Local3)
        }
        If (!Local4) { Return (Zero) }
        Local7 = WRIT
        If (XNXE ()) { Local7 |= NOEX }
        If (!UMAP (Arg0, USTP - USSZ, USSZ, Local7, Zero, Zero, Zero)) { Return (Zero) }
        Return (Local1)
    }

    // Validate ownership and required permissions before accessing user memory.
    Method (URNG, 4, NotSerialized)
    {
        If (!Arg2) { Return (One) }
        If (Arg1 < PGSZ || Arg1 >= USTP || Arg2 > USTP - Arg1) { Return (Zero) }
        Local0 = Arg1 & ~(PGSZ - One)
        Local1 = Arg1 + Arg2
        While (Local0 < Local1)
        {
            If (!UPHY (Arg0, Local0, Arg3)) { Return (Zero) }
            Local0 += PGSZ
        }
        Return (One)
    }

    // Copy to a validated user buffer using the physical direct map.
    Method (UCOP, 4, NotSerialized)
    {
        If (!URNG (Arg0, Arg1, Arg3, WRIT)) { Return (Zero) }
        While (Arg3)
        {
            Local0 = UPHY (Arg0, Arg1, WRIT)
            If (!Local0) { Return (Zero) }
            Local1 = PGSZ - (Arg1 & (PGSZ - One))
            If (Local1 > Arg3) { Local1 = Arg3 }
            XMOV (Local0, Arg2, Local1)
            Arg1 += Local1
            Arg2 += Local1
            Arg3 -= Local1
        }
        Return (One)
    }

    // Copy a validated userspace buffer into kernel-owned storage.
    Method (UCPY, 4, NotSerialized)
    {
        If (!URNG (Arg0, Arg2, Arg3, Zero)) { Return (Zero) }
        While (Arg3)
        {
            Local0 = UPHY (Arg0, Arg2, Zero)
            If (!Local0) { Return (Zero) }
            Local1 = PGSZ - (Arg2 & (PGSZ - One))
            If (Local1 > Arg3) { Local1 = Arg3 }
            XMOV (Arg1, Local0, Local1)
            Arg1 += Local1
            Arg2 += Local1
            Arg3 -= Local1
        }
        Return (One)
    }

    // Copy the path from userspace and select the starting directory.
    Method (UENT, 3, NotSerialized)
    {
        Return (UPRS (Arg0, Arg1, Arg2, Zero))
    }

    Method (UPAR, 3, NotSerialized)
    {
        Return (UPRS (Arg0, Arg2, Arg1, One))
    }

    Method (UPRS, 4, NotSerialized)
    {
        If (!Arg1 || Arg1 >= USTP) { Return (Zero - 14) } // EFAULT
        Local0 = XADR (UPTH)
        Local1 = Zero
        While (Local1 < SizeOf (UPTH))
        {
            If (Arg1 + Local1 >= USTP) { Return (Zero - 14) }
            Local2 = UPHY (Arg0, Arg1 + Local1, Zero)
            If (!Local2) { Return (Zero - 14) }
            Local3 = XBYT (Local2)
            If (!Local3) { Break }
            XSTB (Local0 + Local1, Local3)
            Increment (Local1)
        }
        If (!Local1) { Return (Zero - 2) } // ENOENT
        If (Local1 == SizeOf (UPTH)) { Return (Zero - 36) } // ENAMETOOLONG
        Local2 = VROT
        If (XBYT (Local0) != 0x2F)
        {
            If ((Arg2 & 0xFFFFFFFF) == 0xFFFFFF9C) { Local2 = VCWD (Arg0) }
            Else
            {
                Local3 = UFDL (Arg0, Arg2 & 0xFFFFFFFF)
                If (!Local3) { Return (Zero - 9) }
                Local2 = XVWD (Local3, Ones)
                If (Local2 == XADR (SKND)) { Return (Zero - 20) }
            }
        }
        If (XVWD (Local2 + VNTY, Ones) != 4) { Return (Zero - 20) }
        If (Arg3) { Return (VPAR (Local2, Local0, Local1)) }
        Return (VWAL (Local2, Local0, Local1))
    }

    Method (VWAL, 3, NotSerialized)
    {
        Local0 = Arg0
        Local1 = Zero
        While (Local1 < Arg2)
        {
            If (XVWD (Local0 + VNTY, Ones) != 4) { Return (Zero - 20) }
            If (XBYT (Arg1 + Local1) == 0x2F)
            {
                Increment (Local1)
                Continue
            }
            Local2 = Local1
            While (Local1 < Arg2)
            {
                If (XBYT (Arg1 + Local1) == 0x2F) { Break }
                Increment (Local1)
            }
            Local3 = Local1 - Local2
            If (Local3 > 255) { Return (Zero - 36) }
            Local2 += Arg1
            // Path lookups run on every open and stat. Keep dot components
            // allocation-free so misses cannot exhaust the early AML arena.
            If (XBYT (Local2) == 0x2E)
            {
                If (Local3 == One) { Continue }
                If (Local3 == 2 && XBYT (Local2 + One) == 0x2E)
                {
                    Local0 = XVWD (Local0 + VNPA, Ones)
                    Continue
                }
            }
            Local0 = VFIN (Local0, Local2, Local3)
            If (!Local0) { Return (Zero - 2) }
        }
        Return (Local0)
    }

    Method (FDCL, 1, NotSerialized)
    {
        Local0 = XVWD (Arg0, Ones)
        If (!Local0) { Return (Zero - 9) }
        XSTQ (Arg0, Zero)
        Local1 = XVWD (Local0 + 16, Ones) - One
        If (Local1) { XSTQ (Local0 + 16, Local1) }
        Else
        {
            If (XVWD (Local0, Ones) == XADR (SKND))
            {
                SKCL (Local0)
                Return (Zero)
            }
            If (Local0 == MSOP) { MSOP = Zero }
            If (Local0 == FBOW)
            {
                VBIX = 9
                VBDT = Zero
                FBOW = Zero
                FBPG = Zero
            }
            If (Local0 == KSOP)
            {
                KSOP = Zero
                KMOD &= 4
                KSKP = Zero
            }
            VREL (XVWD (Local0, Ones))
            PDEL (Local0 - HHDO)
        }
        Return (Zero)
    }

    Method (UFDL, 2, NotSerialized)
    {
        If (Arg1 >= FDLM) { Return (Zero) }
        Return (XVWD (Arg0 + TSFD + Arg1 * 8, Ones))
    }

    Method (SSTD, 2, NotSerialized)
    {
        Return (Arg1 < 3 && !(XVWD (Arg0 + TSCL, Ones) & (One << Arg1)) &&
            !UFDL (Arg0, Arg1))
    }

    Method (SYDP, 3, NotSerialized)
    {
        If (Arg1 >= FDLM || Arg2 >= FDLM) { Return (Zero - 9) }
        Local0 = UFDL (Arg0, Arg1)
        If (Arg1 == Arg2)
        {
            If (Local0 || SSTD (Arg0, Arg1)) { Return (Arg2) }
            Return (Zero - 9)
        }
        If (!Local0)
        {
            If (SSTD (Arg0, Arg1)) { Return (Zero - 38) }
            Return (Zero - 9)
        }

        XSTQ (Local0 + 16, XVWD (Local0 + 16, Ones) + One)
        Local1 = Arg0 + TSFD + Arg2 * 8
        FDCL (Local1)
        XSTQ (Local1, Local0)
        XSTQ (Arg0 + TSCE, XVWD (Arg0 + TSCE, Ones) & ~(One << Arg2))
        If (Arg2 < 3) { XSTQ (Arg0 + TSCL, XVWD (Arg0 + TSCL, Ones) | (One << Arg2)) }
        Return (Arg2)
    }

    Method (SYFC, 4, NotSerialized)
    {
        Local0 = UFDL (Arg0, Arg1)
        If (!Local0)
        {
            If (SSTD (Arg0, Arg1)) { Return (Zero - 38) }
            Return (Zero - 9)
        }
        Local1 = XVWD (Arg0 + TSCE, Ones)
        Local2 = One << Arg1
        If (Arg2 == Zero || Arg2 == 1030) // F_DUPFD / F_DUPFD_CLOEXEC
        {
            If (Arg3 >= FDLM) { Return (Zero - 22) }
            While (Arg3 < FDLM)
            {
                If (!UFDL (Arg0, Arg3) && !SSTD (Arg0, Arg3))
                {
                    SYDP (Arg0, Arg1, Arg3)
                    If (Arg2 == 1030)
                    {
                        XSTQ (Arg0 + TSCE, XVWD (Arg0 + TSCE, Ones) | (One << Arg3))
                    }
                    Return (Arg3)
                }
                Increment (Arg3)
            }
            Return (Zero - 24)
        }
        If (Arg2 == One) { Return ((Local1 & Local2) >> Arg1) } // F_GETFD
        If (Arg2 == 2) // F_SETFD
        {
            Local1 &= ~Local2
            If (Arg3 & One) { Local1 |= Local2 }
            XSTQ (Arg0 + TSCE, Local1)
            Return (Zero)
        }
        Local3 = XVWD (Local0, Ones)
        If (Local3 == XADR (SKND)) { Return (SKFC (Local0, Arg2, Arg3)) }
        If (Arg2 == 3) { Return (XVWD (Local0 + 40, Ones)) } // F_GETFL
        If (Arg2 == 4 && XVWD (Local3 + VNMD, Ones)) // F_SETFL
        {
            XSTQ (Local0 + 40, (XVWD (Local0 + 40, Ones) & 3) | (Arg3 & 0x400))
            Return (Zero)
        }
        Return (Zero - 22)
    }

    Method (SYOP, 5, NotSerialized)
    {
        Local0 = UENT (Arg0, Arg2, Arg1)
        If ((Arg3 & 0x10040) == 0x10040 || (Arg3 & 3) == 3) { Return (Zero - 22) }
        If (Local0 >= Zero - 4095 && (Local0 != Zero - 2 || !(Arg3 & 0x40))) { Return (Local0) }
        If (Local0 != Zero - 2 && (Arg3 & 0xC0) == 0xC0) { Return (Zero - 17) }
        Local1 = 3
        While (Local1 < FDLM && UFDL (Arg0, Local1)) { Increment (Local1) }
        If (Local1 == FDLM) { Return (Zero - 24) }
        Local3 = PALC ()
        If (!Local3) { Return (Zero - 12) }
        Local4 = SYON (Arg0, Local0, Arg1, Arg2, Arg3, Arg4)
        If (Local4 >= Zero - 4095)
        {
            PDEL (Local3)
            Return (Local4)
        }
        Local0 = Local4
        Local3 += HHDO
        Local2 = Arg0 + TSFD + Local1 * 8
        VREF (Local0)
        XSTQ (Local3, Local0)
        XSTQ (Local3 + 8, Zero)
        XSTQ (Local3 + 16, One)
        XSTQ (Local3 + 24, XVWD (Local0 + VNSZ, Ones))
        XSTQ (Local3 + 32, XVWD (Local0 + VNDA, Ones))
        XSTQ (Local3 + 40, Arg3 & 0x403)
        If (!XVWD (Local0 + VNTY, Ones))
        {
            XSTQ (Local3 + 32, Local3 + 48)
            XSTQ (Local3 + 24, MGEN (Local3 + 48))
        }
        If (Local0 == KSND)
        {
            KSHD = Zero
            KSTL = Zero
            KSEX = Zero
            KSKP = Zero
            KSOP = Local3
        }
        If (Local0 == MSND)
        {
            MSHD = Zero
            MSTL = Zero
            MSOP = Local3
        }
        XSTQ (Local2, Local3)
        Local4 = XVWD (Arg0 + TSCE, Ones) & ~(One << Local1)
        If (Arg3 & 0x80000) { Local4 |= One << Local1 }
        XSTQ (Arg0 + TSCE, Local4)
        Return (Local1)
    }

    Method (SYON, 6, NotSerialized)
    {
        Local0 = Arg1
        If (Local0 == Zero - 2)
        {
            Return (VCRE (Arg0, Arg2, Arg3, 0x8000 | (Arg5 & 0x1FF & ~VMSK (Arg0))))
        }
        If (Local0 == KSND)
        {
            If (!KRDY) { Return (Zero - 19) }
            If (KSOP) { Return (Zero - 16) } // EBUSY
        }
        If (Local0 == MSND)
        {
            If (!MSRD) { Return (Zero - 19) }
            If (MSOP) { Return (Zero - 16) }
        }
        Local1 = XVWD (Local0 + VNTY, Ones)
        If (Local1 != 4 && (Arg4 & 0x10000)) { Return (Zero - 20) }
        If (Local1 == 4 && (Arg4 & 0x243)) { Return (Zero - 21) }
        If (((Arg4 & 3) && Local1 != 12 && !EXWR (Local0)) ||
            ((Arg4 & 0x600) && !EXWR (Local0))) { Return (Zero - 30) }
        If (Arg4 & 0x200)
        {
            Local2 = EXTR (Local0)
            If (Local2) { Return (Local2) }
        }
        Return (Local0)
    }

    Method (SYFR, 4, NotSerialized)
    {
        Local0 = UFDL (Arg0, Arg1)
        If (!Local0) { Return (Zero - 9) }
        Local1 = XVWD (Local0, Ones)
        If (Local1 == XADR (SKND)) { Return (SKRW (Arg0, Local0, Arg2, Arg3, Zero)) }
        If ((XVWD (Local0 + 40, Ones) & 3) == One) { Return (Zero - 9) }
        If (Local1 == MSND) { Return (MSRR (Arg0, Arg2, Arg3)) }
        If (Local1 == KSND) { Return (KSRD (Arg0, Arg2, Arg3)) }
        If (XVWD (Local1 + VNTY, Ones) == 4) { Return (Zero - 21) } // EISDIR
        Local2 = XVWD (Local0 + 8, Ones)
        Local3 = XVWD (Local0 + 24, Ones)
        Local5 = XVWD (Local0 + 32, Ones)
        If (XVWD (Local1 + VNMD, Ones))
        {
            Local3 = XVWD (Local1 + VNSZ, Ones)
            Local5 = XVWD (Local1 + VNDA, Ones)
        }
        If (XVWD (Local1 + VNTY, Ones) == 12) { Local3 = FBSZ }
        If (!Arg3 || Local2 >= Local3) { Return (Zero) }
        Local4 = Local3 - Local2
        If (Local4 > Arg3) { Local4 = Arg3 }
        If (Local4 > PGSZ) { Local4 = PGSZ }
        Local5 += Local2
        If (XVWD (Local1 + VNTY, Ones) == 12)
        {
            If (!FBAD || FBPP != 4) { Return (Zero - 19) }
            Local5 = XADR (FBIO)
            XFBL (Local5, FBAD + Local2, Local4)
        }
        If (!UCOP (Arg0, Arg2, Local5, Local4))
        {
            Return (Zero - 14)
        }
        XSTQ (Local0 + 8, Local2 + Local4)
        Return (Local4)
    }

    Method (SYLS, 4, NotSerialized)
    {
        If (SSTD (Arg0, Arg1)) { Return (Zero - 29) } // ESPIPE
        Local0 = UFDL (Arg0, Arg1)
        If (!Local0) { Return (Zero - 9) }
        If (Local0 == KSOP || Local0 == MSOP || XVWD (Local0, Ones) == XADR (SKND)) { Return (Zero - 29) }
        If (XVWD (XVWD (Local0, Ones) + VNTY, Ones) == 4)
        {
            If (Arg3 || (Arg2 >> 63)) { Return (Zero - 22) }
            XSTQ (Local0 + 8, Arg2)
            Return (Arg2)
        }
        Local1 = Arg2
        If (Arg3 == One) { Local1 += XVWD (Local0 + 8, Ones) }
        ElseIf (Arg3 == 2)
        {
            Local2 = XVWD (Local0, Ones)
            If (XVWD (Local2 + VNMD, Ones)) { Local1 += XVWD (Local2 + VNSZ, Ones) }
            Else { Local1 += XVWD (Local0 + 24, Ones) }
        }
        ElseIf (Arg3) { Return (Zero - 22) }
        If (Local1 >> 63) { Return (Zero - 22) }
        XSTQ (Local0 + 8, Local1)
        Return (Local1)
    }

    // The directory cursor is an entry index, including dot entries.
    Method (SYGD, 4, NotSerialized)
    {
        Local0 = UFDL (Arg0, Arg1)
        If (!Local0) { Return (Zero - 9) }
        Local1 = XVWD (Local0, Ones)
        If (XVWD (Local1 + VNTY, Ones) != 4) { Return (Zero - 20) }
        Local2 = Zero
        Local3 = XADR (DENT)
        Local6 = XVWD (Local1 + VNCH, Ones)
        Local7 = 2
        While (Local6 && Local7 < XVWD (Local0 + 8, Ones))
        {
            Local6 = XVWD (Local6 + VNXT, Ones)
            Increment (Local7)
        }
        While (One)
        {
            Local7 = XVWD (Local0 + 8, Ones)
            If (Local7 < 2)
            {
                Local4 = XADR (DOTS)
                Local5 = Local7 + One
                Local7 = Local1
                If (Local5 == 2) { Local7 = XVWD (Local1 + VNPA, Ones) }
                XSTQ (Local3, XVWD (Local7 + VNID, Ones))
                XSTQ (Local3 + 16, 4 << 16)
            }
            Else
            {
                If (!Local6) { Break }
                Local4 = XVWD (Local6 + VNNA, Ones)
                Local5 = XVWD (Local6 + VNNL, Ones)
                XSTQ (Local3, XVWD (Local6 + VNID, Ones))
                Local7 = XVWD (Local6 + VNTY, Ones)
                If (!Local7) { Local7 = 8 }
                XSTQ (Local3 + 16, Local7 << 16)
                Local6 = XVWD (Local6 + VNXT, Ones)
            }
            XSTQ (Local3 + 8, XVWD (Local0 + 8, Ones) + One)
            Local7 = (19 + Local5 + One + 7) & ~7
            If (Local7 > Arg3 - Local2)
            {
                If (!Local2) { Return (Zero - 22) }
                Break
            }
            // For short names the last word overlaps d_type.
            If (Local7 > 24) { XSTQ (Local3 + Local7 - 8, Zero) }
            XSTQ (Local3 + 16, Local7 | XVWD (Local3 + 16, Ones))
            XMOV (Local3 + 19, Local4, Local5)
            XSTB (Local3 + 19 + Local5, Zero)
            If (Arg2 >= USTP || !UCOP (Arg0, Arg2 + Local2, Local3, Local7))
            {
                If (!Local2) { Return (Zero - 14) }
                Break
            }
            Local2 += Local7
            XSTQ (Local0 + 8, XVWD (Local3 + 8, Ones))
        }
        Return (Local2)
    }

    Method (VFEX, 1, NotSerialized)
    {
        Return (XVWD (Arg0 + VNSZ, Ones) >= 64 &&
            ELWD (XVWD (Arg0 + VNDA, Ones), Zero, 4) == 0x464C457F)
    }

    Method (SYAC, 4, NotSerialized)
    {
        If (Arg3 & ~7) { Return (Zero - 22) }
        Local0 = UENT (Arg0, Arg2, Arg1)
        If (Local0 >= Zero - 4095) { Return (Local0) }
        If (((Arg3 & 2) && !EXWR (Local0) && !VMUT (Local0)) || ((Arg3 & One) && XVWD (Local0 + VNTY, Ones) != 4 && !VFEX (Local0)))
        {
            Return (Zero - 13)
        }
        Return (Zero)
    }

    Method (SYFS, 5, NotSerialized)
    {
        If (Arg4 & ~0x1100) { Return (Zero - 22) } // AT_EMPTY_PATH and AT_SYMLINK_NOFOLLOW
        Local0 = Ones
        If (Arg4 & 0x1000)
        {
            If (!Arg2) { Local0 = Zero }
            Else
            {
                If (Arg2 >= USTP) { Return (Zero - 14) }
                Local1 = UPHY (Arg0, Arg2, Zero)
                If (!Local1) { Return (Zero - 14) }
                If (!XBYT (Local1)) { Local0 = Zero }
            }
        }
        Local1 = 0x21B6 // character device, 0666
        Local2 = Zero
        Local3 = 2
        If (Local0 || !SSTD (Arg0, Arg1))
        {
            If (Local0)
            {
                Local0 = UENT (Arg0, Arg2, Arg1)
                If (Local0 >= Zero - 4095) { Return (Local0) }
            }
            Else
            {
                Local0 = UFDL (Arg0, Arg1)
                If (!Local0) { Return (Zero - 9) }
                Local0 = XVWD (Local0, Ones)
            }
            Local1 = 0x416D // directory, 0555
            Local3 = XVWD (Local0 + VNID, Ones)
            If (XVWD (Local0 + VNTY, Ones) != 4)
            {
                Local1 = 0x8124 // regular file, 0444
                If (VFEX (Local0)) { Local1 = 0x816D } // executable ELF, 0555
                If (EXWR (Local0)) { Local1 |= 0x80 }
                Local2 = XVWD (Local0 + VNSZ, Ones)
                If (XVWD (Local0 + VNTY, Ones) == 12)
                {
                    Local1 = 0x21B6 // framebuffer character device, 0666
                    Local2 = FBSZ
                }
                If (Local0 == KSND || Local0 == MSND) { Local1 = 0x2124 } // keyboard, 0444
                If (Local0 == XADR (SKND)) { Local1 = 0xC1FF } // socket, 0777
            }
        }
        If (Local0 && Local0 != XADR (SKND) && XVWD (Local0 + VNMD, Ones))
        {
            Local1 = XVWD (Local0 + VNMD, Ones)
        }
        Local4 = XADR (USTA)
        XSTQ (Local4, Zero) // device
        XSTQ (Local4 + 8, Local3) // inode
        Local3 = One
        If (Local0 && Local0 != XADR (SKND) && !XVWD (Local0 + VNPA, Ones))
        {
            Local3 = Zero
        }
        XSTQ (Local4 + 16, Local3) // link count
        XSTQ (Local4 + 24, Local1) // mode and UID
        XSTQ (Local4 + 48, Local2) // size
        XSTQ (Local4 + 56, PGSZ) // preferred I/O block size
        XSTQ (Local4 + 64, (Local2 + 511) / 512)
        Local3 = 72
        While (Local3 < 120)
        {
            XSTQ (Local4 + Local3, Zero)
            Local3 += 8
        }
        If (Local0 && Local0 != XADR (SKND) && XVWD (Local0 + VNFO, Ones))
        {
            EXSA (Local0, Local4)
        }
        If (!UCOP (Arg0, Arg3, Local4, SizeOf (USTA))) { Return (Zero - 14) }
        Return (Zero)
    }

    Method (SYWR, 4, NotSerialized)
    {
        Arg1 &= 0xFFFFFFFF
        Local0 = UFDL (Arg0, Arg1)
        If (Local0)
        {
            Local1 = XVWD (Local0, Ones)
            If (Local1 == XADR (SKND)) { Return (SKRW (Arg0, Local0, Arg2, Arg3, One)) }
            If (XVWD (Local1 + VNMD, Ones) && !XVWD (Local1 + VNPA, Ones))
            {
                Return (VOWR (Arg0, Local0, Arg2, Arg3))
            }
            If (EXWR (Local1)) { Return (EXIO (Arg0, Local0, Arg2, Arg3)) }
            If (!FBAD || FBPP != 4) { Return (Zero - 19) } // ENODEV
            If (XVWD (Local1 + VNTY, Ones) != 12) { Return (Zero - 9) }
            Local2 = Arg3
            If (Local2 > PGSZ) { Local2 = PGSZ }
            Local3 = XVWD (Local0 + 8, Ones)
            If (Local3 >= FBSZ) { Return (Zero) }
            If (Local2 > FBSZ - Local3) { Local2 = FBSZ - Local3 }
            If (!URNG (Arg0, Arg2, Local2, Zero)) { Return (Zero - 14) }
            If (!UCPY (Arg0, XADR (FBIO), Arg2, Local2)) { Return (Zero - 14) }
            XFBL (FBAD + Local3, XADR (FBIO), Local2)
            XSTQ (Local0 + 8, Local3 + Local2)
            Return (Local2)
        }
        If (!SSTD (Arg0, Arg1) || !Arg1) { Return (Zero - 9) } // EBADF
        Local0 = Arg3
        If (Local0 > PGSZ) { Local0 = PGSZ }
        If (!URNG (Arg0, Arg2, Local0, Zero)) { Return (Zero - 14) } // EFAULT
        Local1 = Zero
        Local2 = Zero
        While (Local1 < Local0)
        {
            If (!Local1 || !((Arg2 + Local1) & (PGSZ - One)))
            {
                Local2 = UPHY (Arg0, Arg2 + Local1, Zero)
                If (!Local2) { Return (Zero - 14) } // EFAULT
            }
            PUTC (XBYT (Local2))
            Increment (Local2)
            Increment (Local1)
        }
        Return (Local1)
    }

    Name (WIOV, Buffer (16) {}) // Linux x86-64 struct iovec

    Method (SYWV, 4, NotSerialized)
    {
        If (Arg3 > 1024) { Return (Zero - 22) } // IOV_MAX
        If (!URNG (Arg0, Arg2, Arg3 * 16, Zero)) { Return (Zero - 14) }
        Local0 = XADR (WIOV)
        Local1 = Zero
        While (Arg3)
        {
            If (!UCPY (Arg0, Local0, Arg2, 16))
            {
                If (Local1) { Return (Local1) }
                Return (Zero - 14)
            }
            Local2 = XVWD (Local0 + 8, Ones)
            If (Local2)
            {
                Local3 = SYWR (Arg0, Arg1, XVWD (Local0, Ones), Local2)
                If (Local3 >= Zero - 4095)
                {
                    If (Local1) { Return (Local1) }
                    Return (Local3)
                }
                Local1 += Local3
                If (Local3 < Local2) { Return (Local1) }
            }
            Arg2 += 16
            Decrement (Arg3)
        }
        If (!Local1) { Return (SYWR (Arg0, Arg1, Zero, Zero)) }
        Return (Local1)
    }

    // Complete a read from the input ring, or return Ones to block.
    Method (SYRD, 2, NotSerialized)
    {
        Local4 = XVWD (Arg1 + 8 * 8, Ones) & 0xFFFFFFFF
        If (Local4 || !SSTD (Arg0, Zero))
        {
            Return (SYFR (Arg0, Local4, XVWD (Arg1 + 9 * 8, Ones),
                XVWD (Arg1 + 12 * 8, Ones)))
        }
        Local0 = XVWD (Arg1 + 12 * 8, Ones)
        If (!Local0) { Return (Zero) }
        If (!KRDY) { Return (Zero - 19) } // ENODEV
        If (Local0 > 127) { Local0 = 127 }
        Local1 = XVWD (Arg1 + 9 * 8, Ones)
        If (!URNG (Arg0, Local1, Local0, WRIT)) { Return (Zero - 14) } // EFAULT
        If (KBHD == KEND) { Return (Ones) }

        Local2 = Zero
        Local3 = Zero
        While (Local2 < Local0 && KBHD != KEND)
        {
            If (!Local2 || !((Local1 + Local2) & (PGSZ - One)))
            {
                Local3 = UPHY (Arg0, Local1 + Local2, WRIT)
                If (!Local3) { Return (Zero - 14) } // EFAULT
            }
            Local5 = XBYT (XADR (KBUF) + KBHD)
            XSTB (Local3, Local5)
            KBHD = (KBHD + One) & 127
            Increment (Local3)
            Increment (Local2)
            If (KCAN && Local5 == 0x0A) { Break }
        }
        Return (Local2)
    }

    Method (KBLK, 1, NotSerialized)
    {
        XVWD (Arg0, Zero)
        If (KRTL) { XVWD (KRTL, Arg0) }
        Else { KRHD = Arg0 }
        KRTL = Arg0
    }

    Method (KWAK, 0, NotSerialized)
    {
        While (KRHD && KBHD != KEND)
        {
            Local0 = KRHD
            KRHD = XVWD (Local0, Ones)
            If (!KRHD) { KRTL = Zero }
            Local1 = XVWD (Local0 + TSFR, Ones)
            XSTQ (Local1 + 14 * 8, SYRD (Local0, Local1))
            SQAP (Local0)
        }
    }

    // Private anonymous mappings used by the static libc allocator.
    Method (SYMM, 2, NotSerialized)
    {
        Local0 = XVWD (Arg1 + 12 * 8, Ones) & 0xFFFFFFFF
        If ((Local0 != Zero && Local0 != One && Local0 != 3) ||
            (XVWD (Arg1 + 5 * 8, Ones) & 0xFFFFFFFF) != 0x22 ||
            (XVWD (Arg1 + 7 * 8, Ones) & 0xFFFFFFFF) != 0xFFFFFFFF ||
            XVWD (Arg1 + 6 * 8, Ones))
        {
            Return (Zero - 22) // EINVAL
        }
        Local0 = XVWD (Arg1 + 9 * 8, Ones)
        If (!Local0) { Return (Zero - 22) }
        Local1 = USTP - USSZ - PGSZ
        If (Local0 > Local1 - PGSZ) { Return (Zero - 12) } // ENOMEM
        Local0 = (Local0 + PGSZ - One) & ~(PGSZ - One)

        // Find a gap below the stack guard. Restart whenever a mapping
        // intersects the candidate, which moves down on each restart.
        While (Local1 >= Local0 + PGSZ)
        {
            Local2 = Local1 - Local0
            Local3 = XVWD (Arg0 + TSUL, Ones)
            While (Local3)
            {
                Local4 = HHDO + Local3
                Local5 = XVWD (Local4 + 8, Ones)
                If (Local5 < Local1 && XVWD (Local4 + 16, Ones) > Local2)
                {
                    Local1 = Local5
                    Break
                }
                Local3 = XVWD (Local4, Ones)
            }
            If (!Local3)
            {
                Local6 = UANO
                If (XNXE ()) { Local6 |= NOEX }
                Local7 = XVWD (Arg0 + TSUL, Ones)
                If (UMAP (Arg0, Local2, Local0, Local6, Zero, Zero, Zero))
                {
                    UPRT (Arg0, Local2, Local0, XVWD (Arg1 + 12 * 8, Ones) & 0xFFFFFFFF)
                    Return (Local2)
                }
                // UMAP may have already linked a partially populated range.
                If (XVWD (Arg0 + TSUL, Ones) != Local7) { UDEL (Arg0, Arg0 + TSUL) }
                Break
            }
        }
        Return (Zero - 12)
    }

    // Only anonymous pages can change permissions. Verify the entire span first.
    Method (UPRT, 4, NotSerialized)
    {
        If ((Arg1 & (PGSZ - One)) || Arg1 < PGSZ || Arg1 >= USTP ||
            Arg2 > USTP - Arg1 || (Arg3 != Zero && Arg3 != One && Arg3 != 3))
        {
            Return (Zero - 22)
        }
        Local0 = Arg1 + Arg2
        Local1 = Arg1
        While (Local1 < Local0)
        {
            Local2 = UPTE (Arg0, Local1)
            If (!Local2 || !(XVWD (Local2, Ones) & UANO)) { Return (Zero - 12) }
            Local1 += PGSZ
        }
        Local3 = Zero
        If (Arg3) { Local3 = USER | (Arg3 & WRIT) }
        While (Arg1 < Local0)
        {
            Local2 = UPTE (Arg0, Arg1)
            XSTQ (Local2, (XVWD (Local2, Ones) & ~(USER | WRIT)) | Local3)
            Arg1 += PGSZ
        }
        Return (Zero)
    }

    Method (SYMU, 3, NotSerialized)
    {
        If ((Arg1 & (PGSZ - One)) || Arg1 < PGSZ || Arg1 >= USTP ||
            !Arg2 || Arg2 > USTP - Arg1) { Return (Zero - 22) }
        Local0 = Arg1 + ((Arg2 + PGSZ - One) & ~(PGSZ - One))
        Local1 = Arg0 + TSUL
        While (XVWD (Local1, Ones))
        {
            Local2 = HHDO + XVWD (Local1, Ones)
            If (XVWD (Local2 + 8, Ones) == Arg1 && XVWD (Local2 + 16, Ones) == Local0)
            {
                UDEL (Arg0, Local1)
                Return (Zero)
            }
            Local1 = Local2
        }
        Return (Zero - 22) // Only a complete mapping can be unmapped.
    }

    Method (VBRD, 1, NotSerialized)
    {
        VBIX = Arg0
        Return (VBDT)
    }

    // Verify that the boot framebuffer is the first page of QEMU Standard VGA.
    // Map two additional scanout pages in its PCI framebuffer aperture.
    Method (FBFP, 0, NotSerialized)
    {
        FBCK = One
        If (FBPP != 4 || FBRD != 16 || FBGR != 8 || FBBL ||
            FBPT != FBWD * 4 || FBAD < HHDO) { Return (Zero) }
        Local0 = Zero
        While (Local0 < 32)
        {
            Local1 = 0x80000000 | (Local0 << 11)
            PCIX = Local1
            If (PCDT == 0x11111234)
            {
                PCIX = Local1 + 4
                If (!(PCDT & 2)) { Return (Zero) }
                PCIX = Local1 + 0x10
                Local2 = PCDT
                If ((Local2 & 7) || (Local2 & ~0xF) != FBAD - HHDO) { Return (Zero) }
                Break
            }
            Increment (Local0)
        }
        If (Local0 == 32 || VBRD (Zero) != 0xB0C5 || !(VBRD (4) & One) ||
            VBRD (One) != FBWD || VBRD (2) != FBHT || VBRD (3) != 32 ||
            VBRD (6) != FBWD || VBRD (8) || VBRD (9)) { Return (Zero) }

        Local3 = FBHT
        While ((Local3 * FBPT) & (PGSZ - One)) { Increment (Local3) }
        Local4 = Local3 * FBPT
        Local5 = VBRD (0xA) << 16
        If (Local3 > 0x7FFF || Local4 * 2 + FBSZ > Local5) { Return (Zero) }

        Local2 = (Local2 & ~0xF) + Local4
        Local5 = Local4 + FBSZ
        Local7 = FBCA ()
        Local6 = Zero
        While (Local6 < Local5)
        {
            If (!VMAP (FBVA + Local6, Local2 + Local6, Local7))
            {
                While (Local6)
                {
                    Local6 -= PGSZ
                    VRMV (HHDO + XCR3 (), 39, FBVA + Local6, Zero)
                }
                Return (Zero)
            }
            Local6 += PGSZ
        }
        FBYT = Local3
        Return (One)
    }

    // Use a firmware-provided write-combining PAT entry when available.
    Method (FBCA, 0, NotSerialized)
    {
        Local0 = XMSR (0x277, Ones)
        Local1 = Zero
        Local2 = 0x18 // Fall back to the legacy uncacheable PAT entry.
        While (Local1 < 8)
        {
            If ((Local0 & 0xFF) == One)
            {
                Local2 = ((Local1 & 3) << 3) | ((Local1 & 4) << 5)
                Break
            }
            Local0 >>= 8
            Increment (Local1)
        }
        If (XNXE ()) { Local2 |= NOEX }
        Return (WRIT | Local2)
    }

    Method (FBPR, 3, NotSerialized)
    {
        If (!FBCK) { FBFP () }
        If (!FBYT) { Return (Zero - 25) } // ENOTTY, use ordinary fbdev writes
        If (FBOW && FBOW != Arg1) { Return (Zero - 16) } // EBUSY
        Local0 = One
        If (FBPG == One) { Local0 = 2 }
        Local1 = FBVA + (Local0 - One) * FBYT * FBPT
        If (!UCPY (Arg0, Local1, Arg2, FBSZ)) { Return (Zero - 14) }

        Local2 = Local0 * FBYT
        VBIX = 9
        VBDT = Local2
        If (VBDT != Local2)
        {
            VBDT = Zero
            FBYT = Zero
            FBPG = Zero
            FBOW = Zero
            Return (Zero - 25)
        }
        FBPG = Local0
        FBOW = Arg1
        Return (Zero)
    }

    Method (SYIO, 4, NotSerialized)
    {
        If (!UFDL (Arg0, Arg1) && !SSTD (Arg0, Arg1))
        {
            Return (Zero - 9) // EBADF
        }
        If (Arg2 == 0x5413)
        {
            If (!URNG (Arg0, Arg3, 8, WRIT)) { Return (Zero - 14) }
            Local0 = 25 | (80 << 16)
            If (FBAD) { Local0 = FBRS | (FBCS << 16) }
            Local1 = Zero
            While (Local1 < 8)
            {
                XSTB (UPHY (Arg0, Arg3 + Local1, WRIT), Local0 & 0xFF)
                Local0 >>= 8
                Increment (Local1)
            }
            Return (Zero)
        }
        If (Arg1 < 3) { Return (Zero - 25) } // ENOTTY
        Local0 = UFDL (Arg0, Arg1)
        If (!Local0 || XVWD (XVWD (Local0, Ones) + VNTY, Ones) != 12)
        {
            Return (Zero - 25) // ENOTTY
        }
        // Private fbdev request. Arg3 points to a complete packed XRGB frame.
        If (Arg2 == 0x46F0) { Return (FBPR (Arg0, Local0, Arg3)) }
        If (Arg2 == 0x4600)
        {
            If (!FBAD || FBPP != 4) { Return (Zero - 19) } // ENODEV
            If (!URNG (Arg0, Arg3, SizeOf (FBVS), WRIT)) { Return (Zero - 14) }
            Local1 = (FBWD & 0xFFFFFFFF) | (FBHT << 32)
            XSTQ (XADR (FBVS), Local1)
            XSTQ (XADR (FBVS) + 8, Local1)
            XSTQ (XADR (FBVS) + 24, 32)
            XSTQ (XADR (FBVS) + 32, FBRD | (8 << 32))
            XSTQ (XADR (FBVS) + 40, FBGR << 32)
            XSTQ (XADR (FBVS) + 48, 8)
            XSTQ (XADR (FBVS) + 56, FBBL | (8 << 32))
            If (!UCOP (Arg0, Arg3, XADR (FBVS), SizeOf (FBVS))) { Return (Zero - 14) }
            Return (Zero)
        }
        If (Arg2 == 0x4602)
        {
            If (!FBAD || FBPP != 4) { Return (Zero - 19) } // ENODEV
            If (!URNG (Arg0, Arg3, SizeOf (FBFS), WRIT)) { Return (Zero - 14) }
            XMOV (XADR (FBFS), XADR (FBNM), SizeOf (FBNM))
            XSTQ (XADR (FBFS) + 24, FBSZ & 0xFFFFFFFF)
            XSTQ (XADR (FBFS) + 32, 2 << 32)
            XSTQ (XADR (FBFS) + 40, Zero)
            XSTQ (XADR (FBFS) + 48, FBPT)
            If (!UCOP (Arg0, Arg3, XADR (FBFS), SizeOf (FBFS))) { Return (Zero - 14) }
            Return (Zero)
        }
        Return (Zero - 25) // ENOTTY
    }

    // SYSCALL frames use the same register order as the timer frame.
    // Allocate a process record separately so zombies hold no task memory.
    Method (PRAL, 3, NotSerialized)
    {
        Local0 = PALC ()
        If (!Local0) { Return (Zero) }
        Local0 += HHDO
        XCLR (Local0)
        XSTQ (Local0, PRHD)
        XSTQ (Local0 + PRTK, Arg0)
        XSTQ (Local0 + PRID, Arg1)
        XSTQ (Local0 + PRPA, Arg2)
        XSTQ (Arg0 + TSPR, Local0)
        PRHD = Local0
        Return (Local0)
    }

    Method (PRDL, 1, NotSerialized)
    {
        Local0 = PRHD
        Local1 = Zero
        While (Local0 != Arg0)
        {
            Local1 = Local0
            Local0 = XVWD (Local0, Ones)
        }
        Local2 = XVWD (Arg0, Ones)
        If (Local1) { XSTQ (Local1, Local2) }
        Else { PRHD = Local2 }
        PDEL (Arg0 - HHDO)
    }

    // Clone private mappings eagerly, preserving range boundaries and permissions.
    Method (UCLN, 2, NotSerialized)
    {
        Local0 = PALC ()
        If (!Local0) { Return (Zero) }
        XCLR (HHDO + Local0)
        XSTQ (Arg1 + TSCR, Local0)
        Local0 = XVWD (Arg0 + TSUL, Ones)
        While (Local0)
        {
            Local1 = HHDO + Local0
            Local2 = XVWD (Local1 + 8, Ones)
            Local3 = XVWD (Local1 + 16, Ones)
            If (!UMAP (Arg1, Local2, Local3 - Local2, XVWD (Local1 + 24, Ones),
                Zero, Zero, Zero)) { Return (Zero) }
            While (Local2 < Local3)
            {
                Local4 = UPTE (Arg0, Local2)
                Local5 = UPTE (Arg1, Local2)
                If (!Local4 || !Local5) { Return (Zero) }
                Local6 = XVWD (Local4, Ones)
                Local7 = XVWD (Local5, Ones)
                XMOV (HHDO + (Local7 & PMSK), HHDO + (Local6 & PMSK), PGSZ)
                XSTQ (Local5, (Local7 & PMSK) | (Local6 & ~PMSK))
                Local2 += PGSZ
            }
            Local0 = XVWD (Local1, Ones)
        }
        Return (One)
    }

    Method (SYFK, 2, NotSerialized)
    {
        If (PNID > 0x7FFFFFFF) { Return (Zero - 11) } // EAGAIN
        Local0 = STAL ()
        If (!Local0) { Return (Zero - 12) }
        Local1 = Local0 + TSIZ - 20 * 8
        If (!UCLN (Arg0, Local0) ||
            !PRAL (Local0, PNID, XVWD (Arg0 + TSPR, Ones)))
        {
            SDEL (Local0)
            Return (Zero - 12)
        }
        XMOV (Local1, Arg1, 20 * 8)
        XMOV (Local0 + TSFX, Arg0 + TSFX, PGSZ)
        XSTQ (Local0 + TSFR, Local1)
        XSTQ (Local1 + 14 * 8, Zero) // Child's syscall result
        XSTQ (Local0 + TSFS, XVWD (Arg0 + TSFS, Ones))
        XSTQ (Local0 + TSCE, XVWD (Arg0 + TSCE, Ones))
        XSTQ (Local0 + TSCL, XVWD (Arg0 + TSCL, Ones))
        XSTQ (Local0 + TSWD, VCWD (Arg0))
        VREF (VCWD (Arg0))
        XSTQ (Local0 + TSUM, XVWD (Arg0 + TSUM, Ones))
        Local2 = TSFD
        While (Local2 < TSFD + FDLM * 8)
        {
            Local3 = XVWD (Arg0 + Local2, Ones)
            If (Local3)
            {
                XSTQ (Local3 + 16, XVWD (Local3 + 16, Ones) + One)
                XSTQ (Local0 + Local2, Local3)
            }
            Local2 += 8
        }
        SQAP (Local0)
        Local4 = PNID
        Increment (PNID)
        Return (Local4)
    }

    // Return Ones when a matching child exists and the caller must block.
    Method (SYWT, 2, NotSerialized)
    {
        Local0 = XVWD (Arg1 + 8 * 8, Ones) & 0xFFFFFFFF
        Local1 = XVWD (Arg1 + 12 * 8, Ones) & 0xFFFFFFFF
        If (Local1 & ~One) { Return (Zero - 22) } // WNOHANG
        Local2 = XVWD (Arg0 + TSPR, Ones)
        Local3 = PRHD
        Local4 = Zero
        While (Local3)
        {
            Local5 = XVWD (Local3 + PRID, Ones)
            // All tasks share the boot process's group.
            If (XVWD (Local3 + PRPA, Ones) == Local2 &&
                (!Local0 || Local0 == 0xFFFFFFFF || Local0 == Local5 ||
                 Local0 == ((Zero - UPID) & 0xFFFFFFFF)))
            {
                Local4 = One
                If (!XVWD (Local3 + PRTK, Ones))
                {
                    Local6 = XVWD (Arg1 + 9 * 8, Ones)
                    Local7 = XVWD (Arg1 + 5 * 8, Ones)
                    If ((Local6 && !URNG (Arg0, Local6, SizeOf (WSTA), WRIT)) ||
                        (Local7 && !URNG (Arg0, Local7, SizeOf (WRUS), WRIT)))
                    {
                        Return (Zero - 14) // Leave the child available for another wait.
                    }
                    If (Local6)
                    {
                        WVAL = XVWD (Local3 + PRST, Ones)
                        If (!UCOP (Arg0, Local6, XADR (WSTA), SizeOf (WSTA)))
                        {
                            Return (Zero - 14)
                        }
                    }
                    If (Local7 && !UCOP (Arg0, Local7, XADR (WRUS), SizeOf (WRUS)))
                    {
                        Return (Zero - 14)
                    }
                    PRDL (Local3)
                    Return (Local5)
                }
            }
            Local3 = XVWD (Local3, Ones)
        }
        If (!Local4) { Return (Zero - 10) } // ECHILD
        If (Local1) { Return (Zero) }
        Return (Ones)
    }

    Method (PREX, 2, NotSerialized)
    {
        Local0 = XVWD (Arg0 + TSPR, Ones)
        Local1 = XVWD (Local0 + PRPA, Ones)
        XSTQ (Local0 + PRTK, Zero)
        XSTQ (Local0 + PRST, Arg1)
        SDEL (Arg0)

        // Orphans continue running and are reaped automatically on exit.
        Local2 = PRHD
        While (Local2)
        {
            Local3 = XVWD (Local2, Ones)
            If (XVWD (Local2 + PRPA, Ones) == Local0)
            {
                XSTQ (Local2 + PRPA, Zero)
                If (!XVWD (Local2 + PRTK, Ones)) { PRDL (Local2) }
            }
            Local2 = Local3
        }
        If (!Local1)
        {
            PRDL (Local0)
        }
        ElseIf (XVWD (Local1 + PRWT, Ones))
        {
            Local2 = XVWD (Local1 + PRTK, Ones)
            Local3 = XVWD (Local2 + TSFR, Ones)
            Local4 = SYWT (Local2, Local3)
            If (Local4 != Ones)
            {
                XSTQ (Local1 + PRWT, Zero)
                XSTQ (Local3 + 14 * 8, Local4)
                SQAP (Local2)
            }
        }
    }

    // Copy a user pointer, including pointers straddling two pages.
    // A user pointer can never equal Ones, which signals a bad address.
    Method (URDQ, 2, NotSerialized)
    {
        If (Arg1 >= USTP - 7) { Return (Ones) }
        Local0 = Zero
        Local1 = Zero
        While (Local1 < 8)
        {
            Local2 = UPHY (Arg0, Arg1 + Local1, Zero)
            If (!Local2) { Return (Ones) }
            Local0 |= XBYT (Local2) << (Local1 * 8)
            Increment (Local1)
        }
        Return (Local0)
    }

    // Supply ELF metadata so static libc can locate and align its TLS block.
    Method (UXAV, 2, NotSerialized)
    {
        XSTQ (Arg1, 6) // AT_PAGESZ
        XSTQ (Arg1 + 8, PGSZ)
        XSTQ (Arg1 + 16, 16) // AT_HWCAP with zero feature bits
        If (XVWD (Arg0 + TSPH, Ones))
        {
            XSTQ (Arg1 + 32, 3) // AT_PHDR
            XSTQ (Arg1 + 40, XVWD (Arg0 + TSPH, Ones))
            XSTQ (Arg1 + 48, 4) // AT_PHENT
            XSTQ (Arg1 + 56, 56)
            XSTQ (Arg1 + 64, 5) // AT_PHNUM
            XSTQ (Arg1 + 72, XVWD (Arg0 + TSPN, Ones))
        }
        // The freshly zeroed stack supplies AT_NULL.
    }

    // Copy argv and envp into the top stack page of the new address space.
    // Reserve 656 bytes for argc, up to 64 pointers, terminators and auxv.
    Method (EXST, 4, NotSerialized)
    {
        Local0 = UPHY (Arg1, USTP - PGSZ, WRIT)
        Local1 = Local0 + 8
        Local2 = Local0 + 656
        Local3 = Arg2
        Local4 = Zero
        While (One)
        {
            If (Local3)
            {
                Local5 = URDQ (Arg0, Local3)
                If (Local5 >= USTP) { Return (Zero - 14) }
                Local3 += 8
                If (Local5)
                {
                    If (Local1 >= Local0 + 8 + (64 + Local4) * 8)
                    {
                        Return (Zero - 7) // E2BIG
                    }
                    XSTQ (Local1, USTP - PGSZ + Local2 - Local0)
                    While (One)
                    {
                        If (Local2 >= Local0 + PGSZ) { Return (Zero - 7) }
                        If (Local5 >= USTP) { Return (Zero - 14) }
                        Local6 = UPHY (Arg0, Local5, Zero)
                        If (!Local6) { Return (Zero - 14) }
                        Local7 = XBYT (Local6)
                        XSTB (Local2, Local7)
                        Increment (Local2)
                        Increment (Local5)
                        If (!Local7) { Break }
                    }
                    Local1 += 8
                    Continue
                }
            }
            If (Local4) { Break }
            XSTQ (Local0, (Local1 - Local0 - 8) / 8)
            Local1 += 8 // argv terminator
            Local3 = Arg3
            Local4 = One
        }
        UXAV (Arg1, Local1 + 8) // skip envp terminator
        Return (Zero)
    }

    Method (SYEX, 4, NotSerialized)
    {
        Local0 = UENT (Arg0, Arg1, 0xFFFFFF9C)
        If (Local0 >= Zero - 4095) { Return (Local0) }
        If (!VFEX (Local0)) { Return (Zero - 13) }

        Local1 = STAL ()
        If (!Local1) { Return (Zero - 12) }
        Local2 = PALC ()
        If (!Local2)
        {
            SDEL (Local1)
            Return (Zero - 12)
        }
        XCLR (HHDO + Local2)
        XSTQ (Local1 + TSCR, Local2)
        Local3 = ELLD (Local1, Local0)
        Local4 = Zero - 8 // ENOEXEC
        If (Local3) { Local4 = EXST (Arg0, Local1, Arg2, Arg3) }
        If (Local4)
        {
            SDEL (Local1)
            Return (Local4)
        }

        // Commit only after the image and arguments have been copied.
        // The temporary task takes ownership of the old address space.
        XSTQ (Local1 + TSCR, XVWD (Arg0 + TSCR, Ones))
        XSTQ (Arg0 + TSCR, Local2)
        Local2 = XVWD (Local1 + TSUL, Ones)
        XSTQ (Local1 + TSUL, XVWD (Arg0 + TSUL, Ones))
        XSTQ (Arg0 + TSUL, Local2)
        SDEL (Local1)

        Local5 = XVWD (Arg0 + TSCE, Ones)
        Local6 = Zero
        While (Local5 && Local6 < FDLM)
        {
            If (Local5 & (One << Local6))
            {
                FDCL (Arg0 + TSFD + Local6 * 8)
            }
            Increment (Local6)
        }
        XSTQ (Arg0 + TSCE, Zero)
        XSTQ (Arg0 + TSFS, Zero)
        XCLR (Arg0 + TSFX)
        XSTQ (Arg0 + TSFX, 0x037F)
        XSTQ (Arg0 + TSFX + 24, 0x1F80)
        XMOV (Arg0 + TSIZ - 20 * 8, XADR (EXZR), 20 * 8)
        SFRM (Arg0, Local3, Zero, USTP - PGSZ)
        Return (Zero)
    }

    Name (SLHD, Zero)
    Name (TSDL, 704) // Wake tick, immediately after the descriptor array
    Name (TMVL, Buffer (16) {})

    // Wake elapsed nanosleeps. The scheduler owns this ordered list.
    Method (SWAK, 0, NotSerialized)
    {
        While (SLHD)
        {
            If (XVWD (SLHD + TSDL, Ones) > TICK) { Break }
            Local0 = SLHD
            SLHD = XVWD (Local0, Ones)
            SQAP (Local0)
        }
    }

    Method (SYNS, 2, NotSerialized)
    {
        If (!UCPY (Arg0, XADR (TMVL), Arg1, 16)) { Return (Zero - 14) }
        Local0 = XVWD (XADR (TMVL), Ones)
        Local1 = XVWD (XADR (TMVL) + 8, Ones)
        If (Local0 > 0x7FFFFFFFFFFFFFFF / 100 || Local1 >= 1000000000)
        {
            Return (Zero - 22)
        }
        If (!(Local0 || Local1)) { Return (Zero) }
        // Round up and allow for the partial tick at the start.
        Local2 = TICK + Local0 * 100 + (Local1 + 9999999) / 10000000 + One
        XSTQ (Arg0 + TSDL, Local2)
        Local3 = Zero
        Local4 = SLHD
        While (Local4)
        {
            If (XVWD (Local4 + TSDL, Ones) > Local2) { Break }
            Local3 = Local4
            Local4 = XVWD (Local4, Ones)
        }
        XVWD (Arg0, Local4)
        If (Local3) { XVWD (Local3, Arg0) }
        Else { SLHD = Arg0 }
        Return (Ones)
    }

    Name (PLHD, Zero) // Tasks waiting in poll
    Name (PLEV, Buffer (8) {}) // Linux x86-64 struct pollfd
    Name (PLMX, 1024)

    // Return the supported event mask for a descriptor.
    Method (PRDY, 2, NotSerialized)
    {
        If (Arg1 >> 31) { Return (Zero) } // Negative descriptors are ignored.
        If (!Arg1 && SSTD (Arg0, Arg1))
        {
            If (!KRDY) { Return (8) } // POLLERR
            If (KBHD != KEND) { Return (0x41) } // POLLIN | POLLRDNORM
            Return (Zero)
        }
        If (SSTD (Arg0, Arg1)) { Return (0x104) } // POLLOUT | POLLWRNORM
        Local0 = UFDL (Arg0, Arg1)
        If (!Local0) { Return (0x20) } // POLLNVAL
        If (XVWD (Local0, Ones) == XADR (SKND)) { Return (SKRD (Local0)) }
        If (Local0 == MSOP)
        {
            If (MSHD != MSTL) { Return (0x41) }
            Return (Zero)
        }
        If (Local0 == KSOP)
        {
            If (KSHD != KSTL) { Return (0x41) }
            Return (Zero)
        }
        Return (0x145) // Regular VFS nodes are always ready, including at EOF.
    }

    Method (PSCN, 3, NotSerialized)
    {
        If (Arg2 > PLMX) { Return (Zero - 22) }
        If (!URNG (Arg0, Arg1, Arg2 * 8, WRIT)) { Return (Zero - 14) }
        Local0 = XADR (PLEV)
        Local1 = Zero
        While (Arg2)
        {
            If (!UCPY (Arg0, Local0, Arg1, 6)) { Return (Zero - 14) }
            Local2 = XVWD (Local0, Ones)
            Local3 = PRDY (Arg0, Local2 & 0xFFFFFFFF)
            Local3 &= ((Local2 >> 32) & 0xFFFF) | 0x38 // ERR, HUP, NVAL
            XSTB (Local0 + 6, Local3 & 0xFF)
            XSTB (Local0 + 7, Local3 >> 8)
            If (!UCOP (Arg0, Arg1 + 6, Local0 + 6, 2)) { Return (Zero - 14) }
            If (Local3) { Increment (Local1) }
            Arg1 += 8
            Decrement (Arg2)
        }
        Return (Local1)
    }

    // Recheck after timer and keyboard interrupts while running in the kernel root.
    Method (PWAK, 0, NotSerialized)
    {
        Local0 = Zero
        Local1 = PLHD
        While (Local1)
        {
            Local2 = XVWD (Local1, Ones)
            Local3 = XVWD (Local1 + TSFR, Ones)
            Local4 = PSCN (Local1, XVWD (Local3 + 8 * 8, Ones),
                XVWD (Local3 + 9 * 8, Ones))
            If (Local4 || TICK >= XVWD (Local1 + TSDL, Ones))
            {
                If (Local0) { XSTQ (Local0, Local2) }
                Else { PLHD = Local2 }
                XSTQ (Local3 + 14 * 8, Local4)
                SQAP (Local1)
            }
            Else { Local0 = Local1 }
            Local1 = Local2
        }
    }

    // A deadline of Ones means an indefinite wait.
    Method (SYPL, 3, NotSerialized)
    {
        Local0 = PSCN (Arg0, XVWD (Arg1 + 8 * 8, Ones),
            XVWD (Arg1 + 9 * 8, Ones))
        If (Local0 || Arg2 <= TICK) { Return (Local0) }
        XSTQ (Arg0 + TSDL, Arg2)
        XSTQ (Arg0, PLHD)
        PLHD = Arg0
        Return (Ones)
    }

    Method (SYPP, 2, NotSerialized)
    {
        If (XVWD (Arg1 + 5 * 8, Ones)) { Return (Zero - 38) } // R10, signal mask
        Local0 = XVWD (Arg1 + 12 * 8, Ones)
        Local1 = Ones
        If (Local0)
        {
            If (!UCPY (Arg0, XADR (TMVL), Local0, 16)) { Return (Zero - 14) }
            Local2 = XVWD (XADR (TMVL), Ones)
            Local3 = XVWD (XADR (TMVL) + 8, Ones)
            If (Local2 > 0x7FFFFFFFFFFFFFFF / 100 || Local3 >= 1000000000)
            {
                Return (Zero - 22)
            }
            Local1 = TICK
            If (Local2 || Local3)
            {
                Local1 += Local2 * 100 + (Local3 + 9999999) / 10000000 + One
            }
        }
        Return (SYPL (Arg0, Arg1, Local1))
    }

    // Socket endpoints share the open-description header used by VFS files.
    Name (SKND, Buffer (72) {})
    Name (SKHD, Zero) // Bound endpoints
    Name (SKAD, Buffer (110) {})
    Name (SKAL, Buffer (4) {})
    Name (SKST, 40)  // 0 unconnected, 1 listening, 2 connected
    Name (SKFL, 48)  // O_NONBLOCK
    Name (SKPR, 56)  // Connected peer, cleared on final close
    Name (SKNX, 64)  // Bound-list link
    Name (SKLN, 72)  // Address length, including AF_UNIX
    Name (SKQH, 80)  // Pending connections, in FIFO order
    Name (SKQT, 88)
    Name (SKQN, 96)
    Name (SKQM, 104)
    Name (SKQL, 112) // Queue link on a pending endpoint
    Name (SKRH, 120) // Receive ring head
    Name (SKRT, 128) // Receive ring tail
    Name (SKNM, 136) // sockaddr_un
    Name (SKRX, 256) // Receive ring data
    Name (SKMS, 2047) // One ring slot remains empty.
    Name (SKWH, Zero) // Tasks waiting for socket I/O
    Name (SKCH, Zero) // A socket state change can unblock a waiter.

    Method (SKFD, 2, NotSerialized)
    {
        Local0 = UFDL (Arg0, Arg1 & 0xFFFFFFFF)
        If (!Local0) { Return (Zero - 9) }
        If (XVWD (Local0, Ones) != XADR (SKND)) { Return (Zero - 88) }
        Return (Local0)
    }

    Method (SKNW, 1, NotSerialized)
    {
        Local0 = PALC ()
        If (!Local0) { Return (Zero) }
        Local0 += HHDO
        XCLR (Local0)
        XSTQ (Local0, XADR (SKND))
        XSTQ (Local0 + 16, One)
        XSTQ (Local0 + SKFL, Arg0 & 0x800)
        Return (Local0)
    }

    // Install a new open description, taking ownership only on success.
    Method (FINS, 3, NotSerialized)
    {
        Local0 = 3
        While (Local0 < FDLM)
        {
            Local1 = Arg0 + TSFD + Local0 * 8
            If (!XVWD (Local1, Ones))
            {
                XSTQ (Local1, Arg1)
                Local2 = XVWD (Arg0 + TSCE, Ones) & ~(One << Local0)
                If (Arg2 & 0x80000) { Local2 |= One << Local0 }
                XSTQ (Arg0 + TSCE, Local2)
                Return (Local0)
            }
            Increment (Local0)
        }
        Return (Zero - 24)
    }

    Method (SKUP, 1, NotSerialized)
    {
        Local0 = XVWD (Arg0 + SKPR, Ones)
        If (Local0)
        {
            XSTQ (Local0 + SKPR, Zero)
            SKCH = One
        }
        PDEL (Arg0 - HHDO)
    }

    Method (SKCL, 1, NotSerialized)
    {
        If (XVWD (Arg0 + SKLN, Ones))
        {
            Local0 = Zero
            Local1 = SKHD
            While (Local1 != Arg0)
            {
                Local0 = Local1
                Local1 = XVWD (Local1 + SKNX, Ones)
            }
            Local2 = XVWD (Arg0 + SKNX, Ones)
            If (Local0) { XSTQ (Local0 + SKNX, Local2) }
            Else { SKHD = Local2 }
        }
        Local0 = XVWD (Arg0 + SKQH, Ones)
        While (Local0)
        {
            Local1 = XVWD (Local0 + SKQL, Ones)
            SKUP (Local0)
            Local0 = Local1
        }
        SKUP (Arg0)
    }

    Name (SKPF, Buffer (8) {})

    Method (SKPA, 3, NotSerialized)
    {
        If (!URNG (Arg0, Arg2, 8, WRIT)) { Return (Zero - 14) }
        Local0 = SKNW (Arg1)
        If (!Local0) { Return (Zero - 12) }
        Local1 = SKNW (Arg1)
        If (!Local1)
        {
            SKUP (Local0)
            Return (Zero - 12)
        }
        Local2 = FINS (Arg0, Local0, Arg1)
        If (Local2 >= Zero - 4095)
        {
            SKUP (Local0)
            SKUP (Local1)
            Return (Local2)
        }
        Local3 = FINS (Arg0, Local1, Arg1)
        If (Local3 >= Zero - 4095)
        {
            FDCL (Arg0 + TSFD + Local2 * 8)
            SKUP (Local1)
            Return (Local3)
        }
        XSTQ (Local0 + SKST, 2)
        XSTQ (Local1 + SKST, 2)
        XSTQ (Local0 + SKPR, Local1)
        XSTQ (Local1 + SKPR, Local0)
        XSTQ (XADR (SKPF), Local2 | (Local3 << 32))
        If (!UCOP (Arg0, Arg2, XADR (SKPF), 8))
        {
            FDCL (Arg0 + TSFD + Local2 * 8)
            FDCL (Arg0 + TSFD + Local3 * 8)
            Return (Zero - 14)
        }
        Return (Zero)
    }

    Method (SKSO, 4, NotSerialized)
    {
        If (Arg1 != One) { Return (Zero - 97) } // AF_UNIX
        If ((Arg2 & ~0x80800) != One) { Return (Zero - 94) } // SOCK_STREAM
        If (Arg3) { Return (Zero - 93) }
        Local0 = SKNW (Arg2)
        If (!Local0) { Return (Zero - 12) }
        Local1 = FINS (Arg0, Local0, Arg2)
        If (Local1 >= Zero - 4095) { SKUP (Local0) }
        Return (Local1)
    }

    Method (SKCP, 3, NotSerialized)
    {
        If (Arg2 < 3 || Arg2 > 110) { Return (Zero - 22) }
        Local0 = XADR (SKAD)
        If (!UCPY (Arg0, Local0, Arg1, Arg2)) { Return (Zero - 14) }
        If (XBYT (Local0) != One || XBYT (Local0 + One)) { Return (Zero - 22) }
        Local1 = XBYT (Local0 + 2)
        If (!Local1) { Return (Arg2) } // Abstract addresses retain embedded zeros.
        If (Local1 != 0x2F) { Return (Zero - 22) }
        Local1 = 3
        While (Local1 < Arg2 && XBYT (Local0 + Local1)) { Increment (Local1) }
        Return (Local1)
    }

    Method (SKFN, 1, NotSerialized)
    {
        Local0 = SKHD
        Local1 = XADR (SKAD)
        While (Local0)
        {
            If (XVWD (Local0 + SKLN, Ones) == Arg0)
            {
                Local2 = Zero
                While (Local2 < Arg0 &&
                    XBYT (Local1 + Local2) == XBYT (Local0 + SKNM + Local2))
                {
                    Increment (Local2)
                }
                If (Local2 == Arg0) { Return (Local0) }
            }
            Local0 = XVWD (Local0 + SKNX, Ones)
        }
        Return (Zero)
    }

    Method (SKBD, 4, NotSerialized)
    {
        Local0 = SKFD (Arg0, Arg1)
        If (Local0 >= Zero - 4095) { Return (Local0) }
        If (XVWD (Local0 + SKLN, Ones) || XVWD (Local0 + SKST, Ones))
        {
            Return (Zero - 22)
        }
        Local1 = SKCP (Arg0, Arg2, Arg3)
        If (Local1 >= Zero - 4095) { Return (Local1) }
        If (SKFN (Local1)) { Return (Zero - 98) }
        XMOV (Local0 + SKNM, XADR (SKAD), Local1)
        XSTQ (Local0 + SKLN, Local1)
        XSTQ (Local0 + SKNX, SKHD)
        SKHD = Local0
        Return (Zero)
    }

    Method (SKLS, 3, NotSerialized)
    {
        Local0 = SKFD (Arg0, Arg1)
        If (Local0 >= Zero - 4095) { Return (Local0) }
        If (!XVWD (Local0 + SKLN, Ones) || XVWD (Local0 + SKST, Ones) == 2)
        {
            Return (Zero - 22)
        }
        Arg2 &= 0xFFFFFFFF
        If (Arg2 > 32) { Arg2 = 32 }
        XSTQ (Local0 + SKQM, Arg2 + One)
        XSTQ (Local0 + SKST, One)
        Return (Zero)
    }

    Method (SKCO, 4, NotSerialized)
    {
        Local0 = SKFD (Arg0, Arg1)
        If (Local0 >= Zero - 4095) { Return (Local0) }
        Local1 = XVWD (Local0 + SKST, Ones)
        If (Local1 == 2) { Return (Zero - 106) }
        If (Local1) { Return (Zero - 22) }
        Local1 = SKCP (Arg0, Arg2, Arg3)
        If (Local1 >= Zero - 4095) { Return (Local1) }
        Local2 = SKFN (Local1)
        If (!Local2)
        {
            If (XBYT (XADR (SKAD) + 2)) { Return (Zero - 2) }
            Return (Zero - 111)
        }
        If (XVWD (Local2 + SKST, Ones) != One) { Return (Zero - 111) }
        Local3 = XVWD (Local2 + SKQN, Ones)
        If (Local3 >= XVWD (Local2 + SKQM, Ones)) { Return (Zero - 11) }
        Local4 = SKNW (Zero)
        If (!Local4) { Return (Zero - 12) }
        XSTQ (Local0 + SKST, 2)
        XSTQ (Local4 + SKST, 2)
        XSTQ (Local0 + SKPR, Local4)
        XSTQ (Local4 + SKPR, Local0)
        Local5 = XVWD (Local2 + SKQT, Ones)
        If (Local5) { XSTQ (Local5 + SKQL, Local4) }
        Else { XSTQ (Local2 + SKQH, Local4) }
        XSTQ (Local2 + SKQT, Local4)
        XSTQ (Local2 + SKQN, Local3 + One)
        SKCH = One
        Return (Zero)
    }

    Method (SKAC, 5, NotSerialized)
    {
        If (Arg4 & ~0x80800) { Return (Zero - 22) }
        Local0 = SKFD (Arg0, Arg1)
        If (Local0 >= Zero - 4095) { Return (Local0) }
        If (XVWD (Local0 + SKST, Ones) != One) { Return (Zero - 22) }
        Local1 = XVWD (Local0 + SKQH, Ones)
        If (!Local1)
        {
            If (XVWD (Local0 + SKFL, Ones)) { Return (Zero - 11) }
            Return (Ones) // Block in the scheduler.
        }
        If (Arg2)
        {
            Local2 = XADR (SKAL)
            If (!UCPY (Arg0, Local2, Arg3, 4) || !URNG (Arg0, Arg3, 4, WRIT))
            {
                Return (Zero - 14)
            }
            Local3 = ELWD (Local2, Zero, 4)
            Local4 = XVWD (Local1 + SKPR, Ones)
            Local5 = 2
            Local6 = XADR (SKAD)
            XSTB (Local6, One)
            XSTB (Local6 + One, Zero)
            If (Local4 && XVWD (Local4 + SKLN, Ones))
            {
                Local5 = XVWD (Local4 + SKLN, Ones)
                Local6 = Local4 + SKNM
            }
            If (Local3 > Local5) { Local3 = Local5 }
            XSTB (Local2, Local5)
            XSTB (Local2 + One, Zero)
            XSTB (Local2 + 2, Zero)
            XSTB (Local2 + 3, Zero)
            If (!UCOP (Arg0, Arg2, Local6, Local3) ||
                !UCOP (Arg0, Arg3, Local2, 4)) { Return (Zero - 14) }
        }
        Local2 = FINS (Arg0, Local1, Arg4)
        If (Local2 >= Zero - 4095) { Return (Local2) }
        Local3 = XVWD (Local1 + SKQL, Ones)
        XSTQ (Local0 + SKQH, Local3)
        If (!Local3) { XSTQ (Local0 + SKQT, Zero) }
        XSTQ (Local0 + SKQN, XVWD (Local0 + SKQN, Ones) - One)
        XSTQ (Local1 + SKQL, Zero)
        XSTQ (Local1 + SKFL, Arg4 & 0x800)
        Return (Local2)
    }

    // Read or write a contiguous segment of the receive ring.
    Method (SKRW, 5, NotSerialized)
    {
        If (XVWD (Arg1 + SKST, Ones) != 2) { Return (Zero - 107) }
        If (!Arg3) { Return (Zero) }
        Local0 = Arg1
        Local1 = XVWD (Arg1 + SKPR, Ones)
        If (Arg4 & One)
        {
            If (!Local1) { Return (Zero - 32) }
            Local0 = Local1
        }
        Local2 = XVWD (Local0 + SKRH, Ones)
        Local3 = XVWD (Local0 + SKRT, Ones)
        Local4 = (Local3 - Local2) & SKMS
        Local5 = Local2
        If (Arg4 & One)
        {
            Local4 = SKMS - Local4
            Local5 = Local3
        }
        If (!Local4)
        {
            If (!Local1) { Return (Zero) } // EOF
            If ((Arg4 & 0x40) || XVWD (Arg1 + SKFL, Ones)) { Return (Zero - 11) }
            Return (Ones)
        }
        If (Local4 > Arg3) { Local4 = Arg3 }
        Local6 = SKMS + One - Local5
        If (Local6 > Local4) { Local6 = Local4 }
        If (Arg4 & One)
        {
            If (!URNG (Arg0, Arg2, Local4, Zero)) { Return (Zero - 14) }
            If (!UCPY (Arg0, Local0 + SKRX + Local5, Arg2, Local6) ||
                !UCPY (Arg0, Local0 + SKRX, Arg2 + Local6, Local4 - Local6))
            {
                Return (Zero - 14)
            }
            XSTQ (Local0 + SKRT, (Local5 + Local4) & SKMS)
        }
        Else
        {
            If (!URNG (Arg0, Arg2, Local4, WRIT)) { Return (Zero - 14) }
            If (!UCOP (Arg0, Arg2, Local0 + SKRX + Local5, Local6) ||
                !UCOP (Arg0, Arg2 + Local6, Local0 + SKRX, Local4 - Local6))
            {
                Return (Zero - 14)
            }
            XSTQ (Local0 + SKRH, (Local5 + Local4) & SKMS)
        }
        SKCH = One
        Return (Local4)
    }

    Method (SKRD, 1, NotSerialized)
    {
        Local0 = XVWD (Arg0 + SKST, Ones)
        If (Local0 == One)
        {
            If (XVWD (Arg0 + SKQH, Ones)) { Return (0x41) }
            Return (Zero)
        }
        If (!Local0) { Return (0x10) }
        Local1 = XVWD (Arg0 + SKPR, Ones)
        If (!Local1) { Return (0x51) } // POLLHUP and readable EOF
        Local2 = Zero
        If (XVWD (Arg0 + SKRH, Ones) != XVWD (Arg0 + SKRT, Ones)) { Local2 = 0x41 }
        If (((XVWD (Local1 + SKRT, Ones) - XVWD (Local1 + SKRH, Ones)) & SKMS) < SKMS)
        {
            Local2 |= 0x104
        }
        Return (Local2)
    }

    Method (SKFC, 3, NotSerialized)
    {
        If (Arg1 == 3) { Return (2 | XVWD (Arg0 + SKFL, Ones)) } // F_GETFL
        If (Arg1 == 4) // F_SETFL
        {
            XSTQ (Arg0 + SKFL, Arg2 & 0x800)
            SKCH = One
            Return (Zero)
        }
        Return (Zero - 22)
    }

    Name (SKMH, Buffer (56) {}) // Linux x86-64 struct msghdr
    Name (SKZE, Buffer (12) {}) // Zero ancillary length and message flags

    Method (SKRV, 5, NotSerialized)
    {
        If (Arg3 > 1024) { Return (Zero - 22) }
        If (!URNG (Arg0, Arg2, Arg3 * 16, Zero)) { Return (Zero - 14) }
        Local0 = XADR (WIOV)
        Local1 = Zero
        While (Arg3)
        {
            If (!UCPY (Arg0, Local0, Arg2, 16))
            {
                If (Local1) { Return (Local1) }
                Return (Zero - 14)
            }
            Local2 = XVWD (Local0 + 8, Ones)
            If (Local2)
            {
                If (Arg4 & 0x100)
                {
                    Local3 = SYFR (Arg0, Arg1, XVWD (Local0, Ones), Local2)
                }
                Else
                {
                    Local3 = SKRW (Arg0, Arg1, XVWD (Local0, Ones), Local2, Arg4)
                }
                If (Local3 >= Zero - 4095)
                {
                    If (Local1) { Return (Local1) }
                    Return (Local3)
                }
                Local1 += Local3
                If (Local3 < Local2) { Return (Local1) }
            }
            Arg2 += 16
            Decrement (Arg3)
        }
        Return (Local1)
    }

    Method (SKRC, 2, NotSerialized)
    {
        Local0 = SKFD (Arg0, XVWD (Arg1 + 8 * 8, Ones))
        If (Local0 >= Zero - 4095) { Return (Local0) }
        Local1 = XVWD (Arg1 + 9 * 8, Ones)
        Local2 = XVWD (Arg1 + 12 * 8, Ones)
        If (XVWD (Arg1 + 14 * 8, Ones) == 45) // recvfrom
        {
            Local3 = XVWD (Arg1 + 5 * 8, Ones) & 0xFFFFFFFF
            If ((Local3 & ~0x40) || XVWD (Arg1 + 7 * 8, Ones)) { Return (Zero - 95) }
            Return (SKRW (Arg0, Local0, Local1, Local2, Local3))
        }

        // recvmsg on a byte stream. This transport carries no ancillary data.
        Local2 &= 0xFFFFFFFF
        If (Local2 & ~0x40000040) { Return (Zero - 95) }
        Local3 = XADR (SKMH)
        If (!URNG (Arg0, Local1, 56, WRIT) || !UCPY (Arg0, Local3, Local1, 56))
        {
            Return (Zero - 14)
        }
        Local4 = SKRV (Arg0, Local0, XVWD (Local3 + 16, Ones), XVWD (Local3 + 24, Ones),
            Local2 & 0x40)
        If (Local4 >= Zero - 4095) { Return (Local4) }
        If (!UCOP (Arg0, Local1 + 8, XADR (SKZE), 4) ||
            !UCOP (Arg0, Local1 + 40, XADR (SKZE), 12)) { Return (Zero - 14) }
        Return (Local4)
    }

    Method (SKIO, 2, NotSerialized)
    {
        Local0 = XVWD (Arg1 + 14 * 8, Ones) // syscall number
        Local1 = XVWD (Arg1 + 8 * 8, Ones)
        Local2 = XVWD (Arg1 + 9 * 8, Ones)
        Local3 = XVWD (Arg1 + 12 * 8, Ones)
        If (Local0 == 43 || Local0 == 288)
        {
            Local4 = Zero
            If (Local0 == 288) { Local4 = XVWD (Arg1 + 5 * 8, Ones) & 0xFFFFFFFF }
            Return (SKAC (Arg0, Local1, Local2, Local3, Local4))
        }
        If (Local0 == 19)
        {
            Return (SKRV (Arg0, Local1 & 0xFFFFFFFF, Local2, Local3 & 0xFFFFFFFF, 0x100))
        }
        If (Local0 == 20)
        {
            Return (SYWV (Arg0, Local1 & 0xFFFFFFFF, Local2, Local3 & 0xFFFFFFFF))
        }
        If (Local0 == 45 || Local0 == 47) { Return (SKRC (Arg0, Arg1)) }
        Return (SKRW (Arg0, UFDL (Arg0, Local1 & 0xFFFFFFFF), Local2, Local3, Local0))
    }

    Method (SKWK, 0, NotSerialized)
    {
        Local0 = Zero
        Local1 = SKWH
        While (Local1)
        {
            Local2 = XVWD (Local1, Ones)
            Local3 = XVWD (Local1 + TSFR, Ones)
            Local4 = SKIO (Local1, Local3)
            If (Local4 != Ones)
            {
                If (Local0) { XSTQ (Local0, Local2) }
                Else { SKWH = Local2 }
                XSTQ (Local3 + 14 * 8, Local4)
                SQAP (Local1)
            }
            Else { Local0 = Local1 }
            Local1 = Local2
        }
    }

    Method (SKNT, 0, NotSerialized)
    {
        If (SKCH)
        {
            While (SKCH)
            {
                SKCH = Zero
                SKWK ()
            }
            PWAK ()
        }
    }

    Method (SKBK, 1, NotSerialized)
    {
        XSTQ (Arg0, SKWH)
        SKWH = Arg0
    }

    Name (RLBV, Buffer (16) {})

    // The descriptor table has a fixed size. Report that limit to libc.
    Method (SYRL, 3, NotSerialized)
    {
        If (Arg1 != 7) { Return (Zero - 22) } // RLIMIT_NOFILE
        Local0 = XADR (RLBV)
        XSTQ (Local0, FDLM)
        XSTQ (Local0 + 8, FDLM)
        If (Arg2 && !UCOP (Arg0, Arg2, Local0, 16)) { Return (Zero - 14) }
        Return (Zero)
    }

    Method (SYSC, 1, NotSerialized)
    {
        Local0 = XVWD (Arg0 + TSFR, Ones)
        Local1 = XVWD (Local0 + 14 * 8, Ones) // RAX
        Local2 = XVWD (Local0 + 8 * 8, Ones)  // RDI
        If (Local1 == 60 || Local1 == 231)
        {
            Local3 = Local2 & 0xFF
            Local6 = XVWD (XVWD (Arg0 + TSPR, Ones) + PRID, Ones)
            PREX (Arg0, Local3 << 8)
            If (Local6 == UPID)
            {
                Local4 = Zero
                While (Local4 < 63)
                {
                    Local5 = XBYT (UPNM + Local4)
                    If (!Local5) { Break }
                    PUTC (Local5)
                    Increment (Local4)
                }
                PNUM (" exited status=0x", Local3)
                PUTS ("")
            }
            Return (Zero)
        }
        Local3 = Zero - 38 // ENOSYS
        If (!Local1)
        {
            Local3 = SYRD (Arg0, Local0)
            If (Local3 == Ones)
            {
                If ((Local2 & 0xFFFFFFFF) || UFDL (Arg0, Zero)) { SKBK (Arg0) }
                Else { KBLK (Arg0) }
                Return (Zero)
            }
        }
        ElseIf (Local1 == One)
        {
            Local3 = SYWR (Arg0, Local2, XVWD (Local0 + 9 * 8, Ones),
                XVWD (Local0 + 12 * 8, Ones))
            If (Local3 == Ones)
            {
                SKBK (Arg0)
                Return (Zero)
            }
        }
        ElseIf (Local1 == 2) // open
        {
            Local3 = SYOP (Arg0, 0xFFFFFF9C, Local2, XVWD (Local0 + 9 * 8, Ones), XVWD (Local0 + 12 * 8, Ones))
        }
        ElseIf (Local1 == 3)
        {
            Local2 &= 0xFFFFFFFF
            Local3 = Zero - 9
            If (Local2 < FDLM)
            {
                If (SSTD (Arg0, Local2))
                {
                    XSTQ (Arg0 + TSCL, XVWD (Arg0 + TSCL, Ones) | (One << Local2))
                    Local3 = Zero
                }
                Else { Local3 = FDCL (Arg0 + TSFD + Local2 * 8) }
            }
        }
        ElseIf (Local1 == 4 || Local1 == 6) // stat or lstat
        {
            Local4 = Zero
            If (Local1 == 6) { Local4 = 0x100 }
            Local3 = SYFS (Arg0, 0xFFFFFF9C, Local2, XVWD (Local0 + 9 * 8, Ones), Local4)
        }
        ElseIf (Local1 == 5) // fstat
        {
            Local3 = SYFS (Arg0, Local2 & 0xFFFFFFFF, Zero, XVWD (Local0 + 9 * 8, Ones), 0x1000)
        }
        ElseIf (Local1 == 7) // poll
        {
            Local4 = XVWD (Local0 + 12 * 8, Ones) & 0xFFFFFFFF
            Local5 = Ones
            If (!(Local4 >> 31))
            {
                Local5 = TICK
                If (Local4) { Local5 += (Local4 + 9) / 10 + One }
            }
            Local3 = SYPL (Arg0, Local0, Local5)
            If (Local3 == Ones) { Return (Zero) }
        }
        ElseIf (Local1 == 8)
        {
            Local3 = SYLS (Arg0, Local2 & 0xFFFFFFFF, XVWD (Local0 + 9 * 8, Ones),
                XVWD (Local0 + 12 * 8, Ones) & 0xFFFFFFFF)
        }
        ElseIf (Local1 == 9)
        {
            Local3 = SYMM (Arg0, Local0)
        }
        ElseIf (Local1 == 10) // mprotect
        {
            Local3 = UPRT (Arg0, Local2, XVWD (Local0 + 9 * 8, Ones),
                XVWD (Local0 + 12 * 8, Ones) & 0xFFFFFFFF)
        }
        ElseIf (Local1 == 11)
        {
            Local3 = SYMU (Arg0, Local2, XVWD (Local0 + 9 * 8, Ones))
        }
        ElseIf (Local1 == 16)
        {
            Local3 = SYIO (Arg0, Local2, XVWD (Local0 + 9 * 8, Ones),
                XVWD (Local0 + 12 * 8, Ones))
        }
        ElseIf (Local1 == 19) // readv on open descriptions
        {
            Local3 = SKRV (Arg0, Local2 & 0xFFFFFFFF, XVWD (Local0 + 9 * 8, Ones),
                XVWD (Local0 + 12 * 8, Ones) & 0xFFFFFFFF, 0x100)
            If (Local3 == Ones)
            {
                SKBK (Arg0)
                Return (Zero)
            }
        }
        ElseIf (Local1 == 20) // writev
        {
            Local3 = SYWV (Arg0, Local2 & 0xFFFFFFFF, XVWD (Local0 + 9 * 8, Ones),
                XVWD (Local0 + 12 * 8, Ones) & 0xFFFFFFFF)
            If (Local3 == Ones)
            {
                SKBK (Arg0)
                Return (Zero)
            }
        }
        ElseIf (Local1 == 21) // access
        {
            Local3 = SYAC (Arg0, 0xFFFFFF9C, Local2, XVWD (Local0 + 9 * 8, Ones) & 0xFFFFFFFF)
        }
        ElseIf (Local1 == 35) // nanosleep
        {
            Local3 = SYNS (Arg0, Local2)
            If (Local3 == Ones)
            {
                XSTQ (Local0 + 14 * 8, Zero)
                Return (Zero)
            }
        }
        ElseIf (Local1 == 228) // clock_gettime(CLOCK_MONOTONIC)
        {
            Local3 = Zero - 22
            If ((Local2 & 0xFFFFFFFF) == One)
            {
                XSTQ (XADR (TMVL), TICK / 100)
                XSTQ (XADR (TMVL) + 8, (TICK % 100) * 10000000)
                Local3 = Zero - 14
                If (UCOP (Arg0, XVWD (Local0 + 9 * 8, Ones), XADR (TMVL), 16))
                {
                    Local3 = Zero
                }
            }
        }
        ElseIf (Local1 == 32) // dup
        {
            Local3 = SYFC (Arg0, Local2 & 0xFFFFFFFF, Zero, Zero)
        }
        ElseIf (Local1 == 33 || Local1 == 292) // dup2, dup3
        {
            Local2 &= 0xFFFFFFFF
            Local4 = XVWD (Local0 + 9 * 8, Ones) & 0xFFFFFFFF
            Local5 = Zero
            If (Local1 == 292) { Local5 = XVWD (Local0 + 12 * 8, Ones) & 0xFFFFFFFF }
            If (Local1 == 292 && (Local2 == Local4 || (Local5 & ~0x80000)))
            {
                Local3 = Zero - 22
            }
            Else
            {
                Local3 = SYDP (Arg0, Local2, Local4)
                If (Local3 < Zero - 4095 && Local5)
                {
                    XSTQ (Arg0 + TSCE, XVWD (Arg0 + TSCE, Ones) | (One << Local4))
                }
            }
        }
        ElseIf (Local1 == 53) // socketpair
        {
            Local4 = XVWD (Local0 + 9 * 8, Ones) & 0xFFFFFFFF
            Local3 = Zero - 97 // EAFNOSUPPORT
            If ((Local2 & 0xFFFFFFFF) == One)
            {
                Local3 = Zero - 94 // ESOCKTNOSUPPORT
                If ((Local4 & ~0x80800) == One)
                {
                    Local3 = Zero - 93 // EPROTONOSUPPORT
                    If (!(XVWD (Local0 + 12 * 8, Ones) & 0xFFFFFFFF))
                    {
                        Local3 = SKPA (Arg0, Local4, XVWD (Local0 + 5 * 8, Ones))
                    }
                }
            }
        }
        ElseIf (Local1 == 41) // socket
        {
            Local3 = SKSO (Arg0, Local2 & 0xFFFFFFFF, XVWD (Local0 + 9 * 8, Ones) & 0xFFFFFFFF,
                XVWD (Local0 + 12 * 8, Ones) & 0xFFFFFFFF)
        }
        ElseIf (Local1 == 42 || Local1 == 49) // connect or bind
        {
            Local4 = XVWD (Local0 + 9 * 8, Ones)
            Local5 = XVWD (Local0 + 12 * 8, Ones) & 0xFFFFFFFF
            If (Local1 == 42) { Local3 = SKCO (Arg0, Local2, Local4, Local5) }
            Else { Local3 = SKBD (Arg0, Local2, Local4, Local5) }
        }
        ElseIf (Local1 == 43 || Local1 == 288) // accept or accept4
        {
            Local3 = SKIO (Arg0, Local0)
            If (Local3 == Ones)
            {
                SKBK (Arg0)
                Return (Zero)
            }
        }
        ElseIf (Local1 == 45 || Local1 == 47) // recvfrom or recvmsg
        {
            Local3 = SKRC (Arg0, Local0)
            If (Local3 == Ones)
            {
                SKBK (Arg0)
                Return (Zero)
            }
        }
        ElseIf (Local1 == 50) // listen
        {
            Local3 = SKLS (Arg0, Local2, XVWD (Local0 + 9 * 8, Ones))
        }
        ElseIf (Local1 == 57 || Local1 == 56) // fork / fork-style clone
        {
            Local3 = Zero - 22
            If (Local1 == 57 || (Local2 == 17 && !XVWD (Local0 + 9 * 8, Ones)))
            {
                Local3 = SYFK (Arg0, Local0)
            }
        }
        ElseIf (Local1 == 59) // execve
        {
            Local3 = SYEX (Arg0, Local2, XVWD (Local0 + 9 * 8, Ones),
                XVWD (Local0 + 12 * 8, Ones))
            If (!Local3) { Return (One) }
        }
        ElseIf (Local1 == 61) // wait4
        {
            Local3 = SYWT (Arg0, Local0)
            If (Local3 == Ones)
            {
                XSTQ (XVWD (Arg0 + TSPR, Ones) + PRWT, One)
                Return (Zero)
            }
        }
        ElseIf (Local1 == 63) // uname
        {
            Local3 = Zero - 14 // EFAULT
            If (UCOP (Arg0, Local2, XADR (UTSN), SizeOf (UTSN))) { Local3 = Zero }
        }
        ElseIf (Local1 == 72) // fcntl
        {
            Local3 = SYFC (Arg0, Local2 & 0xFFFFFFFF, XVWD (Local0 + 9 * 8, Ones) & 0xFFFFFFFF,
                XVWD (Local0 + 12 * 8, Ones))
        }
        ElseIf (Local1 == 74 || Local1 == 75) // fsync, fdatasync
        {
            Local4 = UFDL (Arg0, Local2 & 0xFFFFFFFF)
            Local3 = Zero - 9
            If (Local4)
            {
                Local3 = Zero - 22
                Local5 = XVWD (Local4, Ones)
                If (Local5 != XADR (SKND) && XVWD (Local5 + VNFS, Ones))
                {
                    EXVL = XVWD (Local5 + VNFS, Ones)
                    Local3 = Zero - 5
                    If (EXSY ()) { Local3 = Zero }
                }
            }
        }
        ElseIf (Local1 == 79) // getcwd
        {
            Local3 = VGCD (Arg0, Local2, XVWD (Local0 + 9 * 8, Ones))
        }
        ElseIf (Local1 == 80) // chdir
        {
            Local3 = VCHD (Arg0, Local2)
        }
        ElseIf (Local1 == 83 || Local1 == 258) // mkdir, mkdirat
        {
            Local4 = 0xFFFFFF9C
            Local5 = XVWD (Local0 + 9 * 8, Ones)
            If (Local1 == 258)
            {
                Local4 = Local2
                Local2 = Local5
                Local5 = XVWD (Local0 + 12 * 8, Ones)
            }
            Local3 = VCRE (Arg0, Local4, Local2, 0x4000 | (Local5 & 0x1FF & ~VMSK (Arg0)))
            If (Local3 < Zero - 4095) { Local3 = Zero }
        }
        ElseIf (Local1 == 82) // rename
        {
            Local3 = VREN (Arg0, 0xFFFFFF9C, Local2, 0xFFFFFF9C, XVWD (Local0 + 9 * 8, Ones))
        }
        ElseIf (Local1 == 264) // renameat
        {
            Local3 = VREN (Arg0, Local2, XVWD (Local0 + 9 * 8, Ones),
                XVWD (Local0 + 12 * 8, Ones), XVWD (Local0 + 5 * 8, Ones))
        }
        ElseIf (Local1 == 84 || Local1 == 87) // rmdir, unlink
        {
            Local4 = Zero
            If (Local1 == 84) { Local4 = 0x200 }
            Local3 = VUNL (Arg0, 0xFFFFFF9C, Local2, Local4)
        }
        ElseIf (Local1 == 263) // unlinkat
        {
            Local3 = VUNL (Arg0, Local2, XVWD (Local0 + 9 * 8, Ones),
                XVWD (Local0 + 12 * 8, Ones) & 0xFFFFFFFF)
        }
        ElseIf (Local1 == 95) // umask
        {
            Local3 = VMSK (Arg0)
            XSTQ (Arg0 + TSUM, 0x200 | (Local2 & 0x1FF))
        }
        ElseIf (Local1 == 158)
        {
            Local4 = XVWD (Local0 + 9 * 8, Ones)
            Local3 = Zero - 22
            If (Local2 == 0x1002 && Local4 < USTP) // ARCH_SET_FS
            {
                XSTQ (Arg0 + TSFS, Local4)
                Local3 = Zero
            }
        }
        ElseIf (Local1 == 39 || Local1 == 186) // getpid / gettid
        {
            Local3 = XVWD (XVWD (Arg0 + TSPR, Ones) + PRID, Ones)
        }
        ElseIf (Local1 == 102 || Local1 == 104 || Local1 == 107 || Local1 == 108)
        {
            Local3 = Zero // uid, gid, effective uid and effective gid
        }
        ElseIf (Local1 == 110) // getppid
        {
            Local4 = XVWD (XVWD (Arg0 + TSPR, Ones) + PRPA, Ones)
            Local3 = Zero
            If (Local4) { Local3 = XVWD (Local4 + PRID, Ones) }
        }
        ElseIf (Local1 == 97) // getrlimit
        {
            Local4 = XVWD (Local0 + 9 * 8, Ones)
            Local3 = Zero - 14
            If (Local4) { Local3 = SYRL (Arg0, Local2 & 0xFFFFFFFF, Local4) }
        }
        ElseIf (Local1 == 302) // prlimit64
        {
            Local4 = XVWD (Arg0 + TSPR, Ones)
            Local2 &= 0xFFFFFFFF
            Local3 = Zero - 3 // ESRCH
            If (!Local2 || Local2 == XVWD (Local4 + PRID, Ones))
            {
                Local3 = Zero - One // EPERM for limit changes
                If (!XVWD (Local0 + 12 * 8, Ones))
                {
                    Local3 = SYRL (Arg0, XVWD (Local0 + 9 * 8, Ones) & 0xFFFFFFFF,
                        XVWD (Local0 + 5 * 8, Ones))
                }
            }
        }
        ElseIf (Local1 == 217) // getdents64
        {
            Local3 = SYGD (Arg0, Local2 & 0xFFFFFFFF, XVWD (Local0 + 9 * 8, Ones),
                XVWD (Local0 + 12 * 8, Ones) & 0xFFFFFFFF)
        }
        ElseIf (Local1 == 257)
        {
            Local3 = SYOP (Arg0, Local2, XVWD (Local0 + 9 * 8, Ones),
                XVWD (Local0 + 12 * 8, Ones), XVWD (Local0 + 5 * 8, Ones))
        }
        ElseIf (Local1 == 262)
        {
            Local3 = SYFS (Arg0, Local2 & 0xFFFFFFFF, XVWD (Local0 + 9 * 8, Ones),
                XVWD (Local0 + 12 * 8, Ones), XVWD (Local0 + 5 * 8, Ones))
        }
        ElseIf (Local1 == 269) // faccessat
        {
            Local3 = SYAC (Arg0, Local2, XVWD (Local0 + 9 * 8, Ones),
                XVWD (Local0 + 12 * 8, Ones) & 0xFFFFFFFF)
        }
        ElseIf (Local1 == 271) // ppoll
        {
            Local3 = SYPP (Arg0, Local0)
            If (Local3 == Ones) { Return (Zero) }
        }
        XSTQ (Local0 + 14 * 8, Local3)
        Return (One)
    }

    Method (SQAP, 1, NotSerialized)
    {
        XVWD (Arg0, Zero)
        If (SQTL) { XVWD (SQTL, Arg0) }
        Else { SQHD = Arg0 }
        SQTL = Arg0
    }

    Method (STAL, 0, NotSerialized)
    {
        Local0 = WRIT
        If (XNXE ()) { Local0 |= NOEX }
        Return (VALL (TSIZ, Local0))
    }

    // Build a 15-register interrupt frame plus the five hardware slots.
    Method (SFRM, 4, NotSerialized)
    {
        Local0 = Arg0 + TSIZ
        Local1 = Arg3
        Local2 = UCSL
        Local3 = UDSL
        If (!Arg3)
        {
            Local0 -= 8
            Local1 = Local0
            Local2 = CSLE
            Local3 = DSLE
            XVWD (Local0, TEXA)
        }
        Local0 -= 20 * 8
        XSTQ (Local0 + 8 * 8, Arg2)    // RDI
        XVWD (Local0 + 15 * 8, Arg1)   // RIP
        XVWD (Local0 + 16 * 8, Local2) // CS
        XVWD (Local0 + 17 * 8, 0x202)  // RFLAGS with IF set
        XVWD (Local0 + 18 * 8, Local1) // RSP
        XVWD (Local0 + 19 * 8, Local3) // SS
        XVWD (Arg0 + TSFR, Local0)
        XSTQ (Arg0 + TSAR, Arg2)
    }

    Method (SSPN, 2, NotSerialized)
    {
        If (!Arg0) { Return (Zero) }
        Local0 = STAL ()
        If (!Local0) { Return (Zero) }
        SFRM (Local0, Arg0, Arg1, Zero)
        SQAP (Local0)
        Return (Local0)
    }

    // Copy a bounded boot argument to the freshly zeroed user stack page.
    Method (UARG, 3, NotSerialized)
    {
        Local0 = Zero
        While (Local0 < Arg2)
        {
            Local1 = XBYT (Arg0 + Local0)
            If (!Local1) { Return (Local0) }
            XSTB (Arg1 + Local0, Local1)
            Increment (Local0)
        }
        If (XBYT (Arg0 + Local0)) { Return (Ones) }
        Return (Local0)
    }

    Name (EPTH, Buffer (7) {0x50, 0x41, 0x54, 0x48, 0x3D, 0x2F, 0})

    // Build argc/argv, PATH=/, and a minimal auxiliary vector.
    // The first '|' in the module string separates two optional arguments.
    Method (USTK, 2, NotSerialized)
    {
        Local0 = USTP - 1024
        Local1 = UPHY (Arg0, Local0, WRIT)
        If (!Local1) { Return (Zero) }
        Local2 = One
        XSTQ (Local1 + 8, Local0 + 152)
        If (UARG (UPNM, Local1 + 152, 63) == Ones) { Return (Zero) }
        If (Arg1)
        {
            Local3 = UARG (Arg1, Local1 + 216, 807)
            If (Local3 == Ones) { Return (Zero) }
            If (Local3)
            {
                Local2 = 2
                XSTQ (Local1 + 16, Local0 + 216)
                Local4 = Zero
                While (Local4 < Local3)
                {
                    If (XBYT (Local1 + 216 + Local4) == 0x7C)
                    {
                        XSTB (Local1 + 216 + Local4, Zero)
                        XSTQ (Local1 + 24, Local0 + 217 + Local4)
                        Local2 = 3
                        Break
                    }
                    Increment (Local4)
                }
            }
        }
        XSTQ (Local1, Local2)
        XMOV (Local1 + 144, XADR (EPTH), SizeOf (EPTH))
        XSTQ (Local1 + (Local2 + 2) * 8, Local0 + 144)
        UXAV (Arg0, Local1 + (Local2 + 4) * 8)
        Return (Local0)
    }

    Method (USPN, 2, NotSerialized)
    {
        Local0 = STAL ()
        If (!Local0) { Return (Zero) }
        Local2 = PALC ()
        If (!Local2)
        {
            VUNM (Local0, TSIZ)
            Return (Zero)
        }
        XCLR (HHDO + Local2)
        XVWD (Local0 + TSCR, Local2)
        Local1 = ELLD (Local0, Arg1)
        If (!Local1)
        {
            SDEL (Local0)
            Return (Zero)
        }
        XSTQ (Local0 + TSFX, 0x037F) // x87 control word
        XSTQ (Local0 + TSFX + 24, 0x1F80) // MXCSR
        Local3 = USTK (Local0, Arg0)
        If (!Local3)
        {
            SDEL (Local0)
            Return (Zero)
        }
        If (!PRAL (Local0, UPID, Zero))
        {
            SDEL (Local0)
            Return (Zero)
        }
        SFRM (Local0, Local1, Zero, Local3)
        SQAP (Local0)
        Return (Local0)
    }

    Method (SSTP, 0, NotSerialized)
    {
        SKNT ()
        Local0 = SQHD
        If (!Local0)
        {
            TACK (XWAI (Zero))
            Return (Zero)
        }

        SQHD = XVWD (Local0, Ones)
        If (!SQHD) { SQTL = Zero }
        Local2 = Zero
        Local4 = XVWD (Local0 + TSCR, Ones)
        If (Local4) { Local2 = Local0 + TSIZ }
        XVWD (XADR (TSSA) + 8, Local2)
        While (One)
        {
            Local3 = XVWD (Local0 + TSFR, Ones)
            If (Local2 && (XVWD (Local3 + 15 * 8, Ones) >= USTP ||
                XVWD (Local3 + 18 * 8, Ones) >= USTP))
            {
                Local1 = UFEV
                Break
            }
            If (Local4)
            {
                UKRN (Local4)
                XMSR (0xC0000100, XVWD (Local0 + TSFS, Ones))
            }
            Local1 = XRUN (Local3, Local0 + TSFR, Local2, Local4, Local0 + TSFX)
            If (Local4) { XMSR (0xC0000100, Zero) }
            If (Local1 == PIVC || Local1 == KBVC || Local1 == MSVC)
            {
                TACK (Local1)
                Continue
            }
            If (Local1 == SYEV)
            {
                Local5 = SYSC (Local0)
                SKNT ()
                If (Local5)
                {
                    Local4 = XVWD (Local0 + TSCR, Ones)
                    Continue
                }
                Return (Zero)
            }
            Break
        }

        If (Local1 == LAVC)
        {
            TACK (Local1)
            SQAP (Local0)
        }
        Else
        {
            If (Local4)
            {
                PREX (Local0, 11) // Userspace fault reported as SIGSEGV
                PUTS ("Userspace fault terminated task")
            }
            Else { SDEL (Local0) }
        }
        Return (Local1)
    }

    Method (STST, 0, NotSerialized)
    {
        Local0 = VALL (PGSZ, WRIT)
        If (!Local0) { Return (Zero) }
        Local1 = Local0
        Local2 = Local0 + 32 * 8
        While (Local1 < Local2)
        {
            If (!SSPN (TSTA, Local1)) { Return (Zero) }
            Local1 += 8
        }

        // Every spinning task must be preempted in FIFO order. Retry a
        // round if a pending tick interrupted an entry before it started.
        Local5 = Zero
        While (Local5 < 32)
        {
            Local1 = Local0
            Local5 = Zero
            While (Local1 < Local2)
            {
                If (!SQHD) { Return (Zero) }
                If (XVWD (SQHD + TSAR, Ones) != Local1) { Return (Zero) }
                If (SSTP () != LAVC) { Return (Zero) }
                If (XVWD (Local1, Ones) == One) { Increment (Local5) }
                Local1 += 8
            }
        }
        Local1 = Local0
        While (Local1 < Local2)
        {
            XVWD (Local1, 2)
            Local1 += 8
        }

        // Resumed tasks check their saved register and return through the
        // exit gate. An intervening tick may defer an exit by one round.
        Local3 = HHDO + XCR3 ()
        Local5 = Zero
        While (SQHD)
        {
            Local4 = SQHD
            Local1 = XVWD (Local4 + TSAR, Ones)
            If (!SSTP ())
            {
                If (XVWD (Local1, Ones) != 3 ||
                    (VPRB (Local3, Local4, NOEX) & PRES)) { Return (Zero) }
                Increment (Local5)
            }
        }
        Return (Local5 == 32 && !SQTL && VUNM (Local0, PGSZ))
    }

    Name (SHBF, Buffer (80) {})
    Name (VROT, Zero)
    Name (VNEW, Zero)
    Name (VLIM, Zero)
    Name (VINO, 2) // Reserve inode 2 for the console
    Name (VNXT, 0)
    Name (VNCH, 8)
    Name (VNPA, 16)
    Name (VNNA, 24)
    Name (VNNL, 32)
    Name (VNDA, 40)
    Name (VNSZ, 48)
    Name (VNTY, 56) // 4 directory, 8 archive file, 0 generated file
    Name (VNID, 64)
    Name (VNFS, 72)
    Name (VNFO, 80)
    Name (VNSL, 368)

    // Pack nodes into allocator pages and reuse detached ext4 nodes.
    Method (VNOD, 4, NotSerialized)
    {
        If (VFRN)
        {
            Local0 = VFRN
            VFRN = XVWD (Local0 + VNXT, Ones)
            Local1 = Zero
            While (Local1 < VNSL)
            {
                XSTQ (Local0 + Local1, Zero)
                Local1 += 8
            }
        }
        Else
        {
            If (VNEW + VNSL > VLIM)
            {
                Local0 = PALC ()
                If (!Local0) { Return (Zero) }
                VNEW = HHDO + Local0
                VLIM = VNEW + PGSZ
                XCLR (VNEW)
            }
            Local0 = VNEW
            VNEW += VNSL
        }
        Increment (VINO)
        XSTQ (Local0 + VNID, VINO)
        XSTQ (Local0 + VNTY, Arg3)
        If (Arg2) { XMOV (Local0 + 88, Arg1, Arg2) }
        XSTQ (Local0 + VNNA, Local0 + 88)
        XSTQ (Local0 + VNNL, Arg2)
        If (!Arg0) { Arg0 = Local0 }
        Else
        {
            Local1 = Arg0 + VNCH
            While (XVWD (Local1, Ones)) { Local1 = XVWD (Local1, Ones) + VNXT }
            XSTQ (Local1, Local0)
        }
        XSTQ (Local0 + VNPA, Arg0)
        Return (Local0)
    }

    Method (VFIN, 3, NotSerialized)
    {
        Local0 = XVWD (Arg0 + VNCH, Ones)
        While (Local0)
        {
            If (XVWD (Local0 + VNNL, Ones) == Arg2)
            {
                Local1 = XVWD (Local0 + VNNA, Ones)
                Local2 = Zero
                While (Local2 < Arg2)
                {
                    If (XBYT (Local1 + Local2) != XBYT (Arg1 + Local2)) { Break }
                    Increment (Local2)
                }
                If (Local2 == Arg2) { Return (Local0) }
            }
            Local0 = XVWD (Local0 + VNXT, Ones)
        }
        Return (Zero)
    }

    Name (PRNM, Buffer () {0x70, 0x72, 0x6F, 0x63})
    Name (MINM, Buffer () {0x6D, 0x65, 0x6D, 0x69, 0x6E, 0x66, 0x6F})
    Name (CINM, Buffer () {0x63, 0x70, 0x75, 0x69, 0x6E, 0x66, 0x6F})
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
        Return (MLIN (Local1, MAVL, Local0) - Arg0)
    }

    Method (CGEN, 1, NotSerialized)
    {
        // Fastfetch's Linux backend parses these standard cpuinfo properties.
        Local0 = Arg0
        Local0 = XCPY (Local0, XADR ("processor\t: 0\nvendor_id\t: GenuineIntel\nmodel name\t: QEMU Virtual CPU\n\n"), 76)
        Return (Local0 - Arg0)
    }

    // Archive format: eight-byte magic, then aligned records containing
    // u64 name length, u64 data length, name bytes, data bytes and padding.
    Method (RFNX, 1, NotSerialized)
    {
        Return (Arg0 + ((16 + XVWD (Arg0, Ones) + XVWD (Arg0 + 8, Ones) + 7) & ~7))
    }

    // Install a root file or a file within one archive directory.
    Method (RFND, 2, NotSerialized)
    {
        Local0 = VROT
        Local1 = Zero
        While (Local1 < Arg1 && XBYT (Arg0 + Local1) != 0x2F) { Increment (Local1) }
        If (Local1 < Arg1)
        {
            If (!Local1 || Local1 + One == Arg1) { Return (Zero) }
            Local0 = VFIN (VROT, Arg0, Local1)
            If (!Local0) { Local0 = VNOD (VROT, Arg0, Local1, 4) }
            If (!Local0 || XVWD (Local0 + VNTY, Ones) != 4) { Return (Zero) }
            Arg0 += Local1 + One
            Arg1 -= Local1 + One
        }
        If (VFIN (Local0, Arg0, Arg1)) { Return (Zero) }
        Return (VNOD (Local0, Arg0, Arg1, 8))
    }

    Method (RFIN, 2, NotSerialized)
    {
        If (!Arg0 || Arg1 < 8 || (Arg0 & 7) || (Arg1 & 7) ||
            Arg1 > Ones - Arg0)
        {
            Return (Zero)
        }
        If (XVWD (Arg0, Ones) != 0x31305346524C5341) { Return (Zero) }
        Local0 = Arg0 + 8
        Local1 = Arg0 + Arg1
        While (Local0 < Local1)
        {
            Local2 = Local1 - Local0
            If (Local2 < 16) { Return (Zero) }
            Local3 = XVWD (Local0, Ones)
            If (!Local3 || Local3 > 63 || Local3 > Local2 - 16 ||
                XVWD (Local0 + 8, Ones) > Local2 - 16 - Local3)
            {
                Return (Zero)
            }
            Local0 = RFNX (Local0)
        }
        Local0 = Arg0 + 8
        While (Local0 < Local1)
        {
            Local2 = XVWD (Local0, Ones)
            Local3 = RFND (Local0 + 16, Local2)
            If (!Local3) { Return (Zero) }
            XSTQ (Local3 + VNDA, Local0 + 16 + Local2)
            XSTQ (Local3 + VNSZ, XVWD (Local0 + 8, Ones))
            Local0 = RFNX (Local0)
        }
        Return (One)
    }

    Method (RFLI, 0, NotSerialized)
    {
        Local0 = XVWD (VROT + VNCH, Ones)
        While (Local0)
        {
            Local1 = XVWD (Local0 + VNNA, Ones)
            Local2 = Local1 + XVWD (Local0 + VNNL, Ones)
            While (Local1 < Local2)
            {
                PUTC (XBYT (Local1))
                Increment (Local1)
            }
            PUTS ("")
            Local0 = XVWD (Local0 + VNXT, Ones)
        }
    }

    Name (MSHL, Buffer (128) {})

    Method (RFCT, 2, NotSerialized)
    {
        Local0 = VWAL (VROT, Arg0, Arg1)
        If (Local0 >= Zero - 4095)
        {
            PUTS ("File not found")
            Return (Zero)
        }
        If (XVWD (Local0 + VNTY, Ones) == 4)
        {
            PUTS ("File not found")
            Return (Zero)
        }
        Local1 = XVWD (Local0 + VNDA, Ones)
        Local2 = XVWD (Local0 + VNSZ, Ones)
        If (!XVWD (Local0 + VNTY, Ones))
        {
            Local1 = XADR (MSHL)
            Local2 = MGEN (Local1)
        }
        Local2 += Local1
        Local3 = 0x0A
        While (Local1 < Local2)
        {
            Local3 = XBYT (Local1)
            If (Local3 == 0x0A) { PUTC (0x0D) }
            PUTC (Local3)
            Increment (Local1)
        }
        If (Local3 != 0x0A) { PUTS ("") }
        Return (One)
    }

    Method (SHMT, 3, NotSerialized)
    {
        If (Arg1 != SizeOf (Arg2)) { Return (Zero) }
        Local0 = Zero
        While (Local0 < Arg1)
        {
            If (XBYT (Arg0 + Local0) != DerefOf (Index (Arg2, Local0)))
            {
                Return (Zero)
            }
            Increment (Local0)
        }
        Return (One)
    }

    Method (SHCM, 2, NotSerialized)
    {
        Local0 = Arg0
        Local1 = Arg0 + Arg1
        While (Local0 < Local1)
        {
            If (XBYT (Local0) != 0x20) { Break }
            Increment (Local0)
        }
        While (Local1 > Local0)
        {
            If (XBYT (Local1 - One) != 0x20) { Break }
            Decrement (Local1)
        }
        If (Local0 == Local1) { Return (Zero) }

        Local2 = Local0
        While (Local2 < Local1)
        {
            If (XBYT (Local2) == 0x20) { Break }
            Increment (Local2)
        }
        Local3 = Local2 - Local0
        While (Local2 < Local1)
        {
            If (XBYT (Local2) != 0x20) { Break }
            Increment (Local2)
        }
        If (SHMT (Local0, Local3, "help"))
        {
            If (Local2 == Local1) { PUTS ("help, ls, cat <file>") }
            Else { PUTS ("Usage: help") }
        }
        ElseIf (SHMT (Local0, Local3, "ls"))
        {
            If (Local2 == Local1 || SHMT (Local2, Local1 - Local2, "/")) { RFLI () }
            Else { PUTS ("Usage: ls [/]") }
        }
        ElseIf (SHMT (Local0, Local3, "cat"))
        {
            If (Local2 == Local1) { PUTS ("Usage: cat <file>") }
            Else
            {
                If (XBYT (Local2) == 0x2F) { Increment (Local2) }
                RFCT (Local2, Local1 - Local2)
            }
        }
        Else { PUTS ("Unknown command. Type help.") }
        Return (One)
    }

    Method (SHLL, 0, NotSerialized)
    {
        Local0 = XADR (SHBF)
        Local1 = Zero
        Local2 = Zero
        PUTS ("ASL shell. Type help.")
        PUTT ("asl> ")
        While (One)
        {
            While (KBHD == KBTL) { SSTP () }
            Local3 = XBYT (XADR (KBUF) + KBHD)
            KBHD = (KBHD + One) & 127
            If (Local3 == 0x0A)
            {
                PUTS ("")
                If (Local2) { PUTS ("Input line too long") }
                Else { SHCM (Local0, Local1) }
                Local1 = Zero
                Local2 = Zero
                PUTT ("asl> ")
            }
            ElseIf (Local3 == 8)
            {
                If (Local1 && !Local2)
                {
                    Decrement (Local1)
                    KERS ()
                }
            }
            ElseIf (Local3 >= 0x20 && Local3 <= 0x7E)
            {
                If (Local1 == SizeOf (SHBF)) { Local2 = One }
                Else
                {
                    XSTB (Local0 + Local1, Local3)
                    Increment (Local1)
                    PUTC (Local3)
                }
            }
        }
    }

    Name (XINI, Buffer () { "xorg-probe" })

    Method (KERN, 6, NotSerialized)
    {
        // Boot handoff words in the order supplied by _start.
        HHDO = XVWD (Arg5, Ones)
        IVEC = XVWD (Arg5 + 8, Ones)
        SYEA = XVWD (Arg5 + 16, Ones)
        TEXA = XVWD (Arg5 + 24, Ones)
        TSTA = XVWD (Arg5 + 32, Ones)

        IENA = Zero
        LINE = 0x80
        DATA = One
        IENA = Zero
        LINE = 0x03
        FIFO = 0xC7
        MODE = 0x0B
        FINI ()
        PUTS ("ASL kernel booted")

        SGDT ()
        PUTS ("ASL GDT loaded")
        SIDT ()
        PUTS ("ASL IDT loaded with 256 gates")
        XBRK ()
        PUTS ("ASL resumed after int3")
        PMAP ()
        If (PTST ()) { PUTS ("ASL page allocator ready") }
        Else { PUTS ("ASL page allocator test failed") }
        If (VTST ()) { PUTS ("ASL virtual page mapper ready") }
        Else
        {
            PUTS ("ASL virtual page mapper test failed")
            Return (Zero)
        }
        If (VRTS ()) { PUTS ("ASL virtual range allocator ready") }
        Else { PUTS ("ASL virtual range allocator test failed") }
        ACPI (Arg0)
        If (TRDY)
        {
            While (TICK < 100) { TACK (XWAI (Zero)) }
            PUTS ("LAPIC tick counter reached 100")
            // Uncomment to run the 32-task scheduler test before userspace.
            // If (!STST ())
            // {
            //     PUTS ("Round-robin scheduler test failed")
            //     Return (Zero)
            // }
            // PUTS ("Round-robin scheduler preempted and reaped 32 tasks")
            SYIN ()
            VROT = VNOD (Zero, Zero, Zero, 4)
            If (!VROT) { Return (Zero) }
            If (!RFIN (Arg1, Arg2)) { PUTS ("Invalid initramfs") }
            Local0 = VNOD (VROT, XADR (DEVN), SizeOf (DEVN), 4)
            If (Local0)
            {
                VNOD (Local0, XADR (FBNM), SizeOf (FBNM), 12)
                KSND = VNOD (Local0, XADR (KSNM), SizeOf (KSNM), 2)
                MSND = VNOD (Local0, XADR (MSNM), SizeOf (MSNM), 2)
            }
            Local0 = VNOD (VROT, XADR (PRNM), SizeOf (PRNM), 4)
            If (!Local0 || !VNOD (Local0, XADR (MINM), SizeOf (MINM), Zero))
            {
                Return (Zero)
            }
            Local2 = Zero
            If (FSIN () && !XBYT (Arg3))
            {
                Local2 = VWAL (VROT, XADR (XINI), SizeOf (XINI) - One)
                If (Local2 >= Zero - 4095)
                {
                    PUTS ("Desktop init missing from ext4")
                    Return (Zero)
                }
                Arg3 = XADR (XINI)
            }
            UPNM = Arg3
            Local0 = Arg4
            If (Local0)
            {
                If (SHMT (Local0, 5, "init:"))
                {
                    Local0 += 5
                    UPID = Zero
                    KCAN = One
                }
            }
            If (!USPN (Local0, Local2)) { PUTS ("Userspace module load failed") }
            While (SQHD || KRHD || SLHD || PLHD || SKWH) { SSTP () }
            If (KCAN)
            {
                KCAN = Zero
                KBHD = KBTL
                KEND = KBTL
            }
            If (KRDY)
            {
                SHLL ()
            }
            While (One) { SSTP () }
        }
        Return (Zero)
    }
}
