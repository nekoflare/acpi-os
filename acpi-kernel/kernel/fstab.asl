    // Tokenize a bounded fstab line. Return the next token boundary.
    Method (FSWS, 2, NotSerialized)
    {
        While (Arg0 < Arg1 && (XBYT (Arg0) == 0x20 || XBYT (Arg0) == 9))
        {
            Increment (Arg0)
        }
        Return (Arg0)
    }

    Method (FSTK, 2, NotSerialized)
    {
        While (Arg0 < Arg1 && XBYT (Arg0) != 0x20 &&
            XBYT (Arg0) != 9 && XBYT (Arg0) != 0x23 && XBYT (Arg0) != 13)
        {
            Increment (Arg0)
        }
        Return (Arg0)
    }

    Name (FSMP, Zero) // GPT entries already mounted

    Method (FSLN, 2, NotSerialized)
    {
        Arg0 = FSWS (Arg0, Arg1)
        If (Arg0 == Arg1 || XBYT (Arg0) == 0x23 || XBYT (Arg0) == 13) { Return (One) }
        Local0 = FSTK (Arg0, Arg1)
        If (Local0 - Arg0 != 9 || !SHMT (Arg0, 8, "/dev/vda")) { Return (Zero) }
        Local1 = XBYT (Arg0 + 8) - 0x30
        If (!Local1 || Local1 > 9) { Return (Zero) }

        Local2 = FSWS (Local0, Arg1)
        Local3 = FSTK (Local2, Arg1)
        If (Local2 == Local3 || XBYT (Local2) != 0x2F) { Return (Zero) }
        Local4 = VWAL (VROT, Local2, Local3 - Local2)
        If (Local4 >= Zero - 4095) { Return (Zero) } // LOr evaluates both operands
        If (XVWD (Local4 + VNTY, Ones) != 4) { Return (Zero) }

        Local6 = Local2
        Local7 = Local3
        Local2 = FSWS (Local3, Arg1)
        Local3 = FSTK (Local2, Arg1)
        If (!SHMT (Local2, Local3 - Local2, "ext4")) { Return (Zero) }
        Local2 = FSWS (Local3, Arg1)
        Local3 = FSTK (Local2, Arg1)
        If (SHMT (Local2, Local3 - Local2, "noauto")) { Return (One) }
        Local5 = SHMT (Local2, Local3 - Local2, "rw") ||
            SHMT (Local2, Local3 - Local2, "defaults")
        If (!Local5 && !SHMT (Local2, Local3 - Local2, "ro")) { Return (Zero) }
        If (FSMP & (One << Local1)) { Return (Zero) }
        If (!EXMT (Local1, Local4, Local5)) { Return (Zero) }
        FSMP |= One << Local1
        PCMR (Local1, Local6, Local7, Local4)
        PNUM ("fstab: mounted ext4 GPT partition ", Local1)
        PUTS ("")
        Return (One)
    }

    Name (FSPT, Buffer () { "/etc/fstab" })

    Method (FSIN, 0, NotSerialized)
    {
        Local0 = VWAL (VROT, XADR (FSPT), 10)
        If (Local0 >= Zero - 4095) { Return (Zero) }
        If (!VBIN ())
        {
            PUTS ("fstab: virtio-blk unavailable")
            Return (Zero)
        }
        EXIN = PALC ()
        EXIX = PALC ()
        If (!EXIN || !EXIX) { Return (Zero) }
        EXGD = PALC ()
        EXBM = PALC ()
        EXDB = PALC ()
        If (!EXGD || !EXBM || !EXDB) { Return (Zero) }
        EXCI ()
        EXGD += HHDO
        EXBM += HHDO
        EXDB += HHDO
        EXIN += HHDO
        EXIX += HHDO
        Local1 = XVWD (Local0 + VNDA, Ones)
        Local2 = Local1 + XVWD (Local0 + VNSZ, Ones)
        While (Local1 < Local2)
        {
            Local3 = Local1
            While (Local3 < Local2 && XBYT (Local3) != 10) { Increment (Local3) }
            If (!FSLN (Local1, Local3)) { PUTS ("fstab: mount entry failed") }
            Local1 = Local3 + One
        }
        Return (One)
    }
