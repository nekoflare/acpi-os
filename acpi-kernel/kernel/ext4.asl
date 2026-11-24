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

    // Write-through cache of whole blocks, direct-mapped by disk LBA. Every
    // ext4 write passes through EXBW, which refreshes a cached copy, so the
    // cache always matches the disk. Reads fill it; writes never allocate,
    // which keeps streaming file data from evicting group descriptors,
    // bitmaps, inode tables and the superblock.
    Name (EXCT, Zero) // Tag page: LBA + 1 for each slot, zero when empty
    Name (EXCP, Zero) // Page of per-slot data page addresses
    Name (EXCM, 511) // Slot mask; one tag page holds 512 slots

    Method (EXCI, 0, NotSerialized)
    {
        Local0 = PALC ()
        If (!Local0) { Return (Zero) }
        Local1 = PALC ()
        If (!Local1)
        {
            PDEL (Local0)
            Return (Zero)
        }
        XCLR (Local0 + HHDO)
        XCLR (Local1 + HHDO)
        EXCP = Local1 + HHDO
        EXCT = Local0 + HHDO
        Return (One)
    }

    // Return the cached copy of LBA Arg0, or zero.
    Method (EXCG, 1, NotSerialized)
    {
        If (!EXCT) { Return (Zero) }
        Local0 = ((Arg0 >> 3) & EXCM) * 8
        If (XVWD (EXCT + Local0, Ones) != Arg0 + One) { Return (Zero) }
        Return (XVWD (EXCP + Local0, Ones))
    }

    // Record the page at Arg1 as the contents of LBA Arg0.
    Method (EXCF, 2, NotSerialized)
    {
        If (!EXCT) { Return (Zero) }
        Local0 = ((Arg0 >> 3) & EXCM) * 8
        Local1 = XVWD (EXCP + Local0, Ones)
        If (!Local1)
        {
            Local1 = PALC ()
            If (!Local1) { Return (Zero) }
            Local1 += HHDO
            XSTQ (EXCP + Local0, Local1)
        }
        XMOV (Local1, Arg1, PGSZ)
        XSTQ (EXCT + Local0, Arg0 + One)
        Return (One)
    }

    Method (EXCX, 1, NotSerialized)
    {
        If (!EXCT) { Return (Zero) }
        Local0 = ((Arg0 >> 3) & EXCM) * 8
        If (XVWD (EXCT + Local0, Ones) == Arg0 + One) { XSTQ (EXCT + Local0, Zero) }
        Return (Zero)
    }

    Method (EXRD, 2, NotSerialized)
    {
        If (Arg0 >= XVWD (EXVL + EXBL, Ones)) { Return (Zero) }
        Local0 = XVWD (EXVL, Ones) + Arg0 * 8
        Local1 = EXCG (Local0)
        If (Local1)
        {
            XMOV (Arg1, Local1, PGSZ)
            Return (One)
        }
        If (!VBRQ (Zero, Local0, PGSZ)) { Return (Zero) }
        XMOV (Arg1, VDMA, PGSZ)
        EXCF (Local0, VDMA)
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

    // Populate the existing VFS. File bytes are read on first use; see
    // vfs-cache.asl.
    Method (EXFL, 2, NotSerialized)
    {
        Local0 = EXIR (Arg1)
        If (!Local0 || (ELWD (Local0, Zero, 2) & 0xF000) != 0x8000 ||
            ELWD (Local0, 108, 4)) { Return (Zero) }
        Local1 = ELWD (Local0, 4, 4)
        If (Local1 > VFMX) { Return (Zero) }
        XSTQ (Arg0 + VNIN, Arg1)
        XSTQ (Arg0 + VNVL, Local1)
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
        If (Local0 != One && Local0 != 2 && Local0 != 7) { Return (One) }
        If (SHMT (Arg1 + 8, Arg2, ".") || SHMT (Arg1 + 8, Arg2, "..")) { Return (One) }
        If (!Arg2 || VFIN (Arg0, Arg1 + 8, Arg2)) { Return (Zero) }
        Local1 = 8
        If (Local0 == 2) { Local1 = 4 }
        ElseIf (Local0 == 7) { Local1 = 10 }
        Local2 = VNOD (Arg0, Arg1 + 8, Arg2, Local1)
        If (!Local2) { Return (Zero) }
        If (Local0 == 2) { Return (EXDR (Local2, Arg3, Arg4 + One)) }
        If (Local0 == 7) { Return (EXSL (Local2, Arg3)) }
        Return (EXFL (Local2, Arg3))
    }

    // Populate a symlink node with its target. Targets of up to 60 bytes
    // live in i_block; longer targets use the regular block mapping.
    Method (EXSL, 2, NotSerialized)
    {
        Local0 = EXIR (Arg1)
        If (!Local0 || (ELWD (Local0, Zero, 2) & 0xF000) != 0xA000 ||
            ELWD (Local0, 108, 4)) { Return (Zero) }
        Local1 = ELWD (Local0, 4, 4)
        If (Local1 > 0x100000) { Return (Zero) }
        XSTQ (Arg0 + VNFS, EXVL)
        XSTQ (Arg0 + VNMD, ELWD (Local0, Zero, 2))
        If (ELWD (Local0, 26, 2) == One && !(ELWD (Local0, 32, 4) & 0x30))
        {
            XSTQ (Arg0 + VNFO, Arg1)
        }
        XSTQ (Arg0 + VNSZ, Local1)
        If (!Local1) { Return (One) }
        Local2 = WRIT
        If (XNXE ()) { Local2 |= NOEX }
        Local3 = (Local1 + PGSZ - One) & ~(PGSZ - One)
        Local4 = VALL (Local3, Local2)
        If (!Local4) { Return (Zero) }
        If (Local1 <= 60) { XMOV (Local4, Local0 + 40, Local1) }
        ElseIf (!EXLD (Local0, Local4, Local1))
        {
            VUNM (Local4, Local3)
            Return (Zero)
        }
        XSTQ (Arg0 + VNDA, Local4)
        XSTQ (Arg0 + VNCP, Local3)
        Return (One)
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

    // Move the entries of bootstrap directory Arg1 into disk directory Arg0.
    // Directories on both sides merge; otherwise the bootstrap entry wins and
    // the disk's entry of that name is dropped from the tree.
    Method (EXMG, 3, NotSerialized)
    {
        Local0 = XVWD (Arg1 + VNCH, Ones)
        While (Local0)
        {
            Local1 = XVWD (Local0 + VNXT, Ones)
            Local2 = VFIN (Arg0, XVWD (Local0 + VNNA, Ones), XVWD (Local0 + VNNL, Ones))
            Local3 = Zero
            If (Local2 && Arg2 < 16) // LAnd evaluates both operands
            {
                Local3 = XVWD (Local2 + VNTY, Ones) == 4 && XVWD (Local0 + VNTY, Ones) == 4
            }
            If (Local3) { EXMG (Local2, Local0, Arg2 + One) }
            Else
            {
                If (Local2)
                {
                    VDET (Arg0, Local2)
                    EXFR (Local2)
                }
                VDET (Arg1, Local0)
                Local4 = Arg0 + VNCH
                While (XVWD (Local4, Ones)) { Local4 = XVWD (Local4, Ones) + VNXT }
                XSTQ (Local4, Local0)
                XSTQ (Local0 + VNXT, Zero)
                XSTQ (Local0 + VNPA, Arg0)
            }
            Local0 = Local1
        }
    }

    // Stage a tree before publishing it. Existing synthetic nodes and fstab
    // are kept when mounting over the bootstrap root; a directory on both
    // sides, such as /etc, becomes the disk's with the bootstrap entries in it.
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
        // A name on both sides is allowed only for two directories that no
        // one holds open; check them all before changing anything.
        Local2 = XVWD (Local1 + VNCH, Ones)
        While (Local2)
        {
            Local3 = VFIN (Arg1, XVWD (Local2 + VNNA, Ones), XVWD (Local2 + VNNL, Ones))
            If (Local3)
            {
                If (XVWD (Local2 + VNTY, Ones) != 4 || XVWD (Local3 + VNTY, Ones) != 4 ||
                    XVWD (Local3 + VNRF, Ones))
                {
                    EXFR (Local1)
                    PDEL (Local0)
                    Return (Zero)
                }
            }
            Local2 = XVWD (Local2 + VNXT, Ones)
        }
        // The bootstrap entries of such a directory (/etc/fstab, hosts,
        // resolv.conf) move into the disk's directory.
        Local2 = XVWD (Local1 + VNCH, Ones)
        While (Local2)
        {
            Local3 = VFIN (Arg1, XVWD (Local2 + VNNA, Ones), XVWD (Local2 + VNNL, Ones))
            If (Local3)
            {
                EXMG (Local2, Local3, One)
                VDET (Arg1, Local3)
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
        If (XVWD (Arg0 + VNIN, Ones)) { VCRL (Arg0) }
        Else
        {
            Local1 = XVWD (Arg0 + VNSZ, Ones)
            If (Local1) { VUNM (XVWD (Arg0 + VNDA, Ones), Local1) }
        }
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
        If (XVWD (Arg0 + VNDB, Ones))
        {
            // Delayed writeback: the cache is newer than the disk inode.
            Local1 = XVWD (Arg0 + VNSZ, Ones)
            XSTQ (Arg1 + 48, Local1)
            Local1 = (Local1 + PGSZ - One) / PGSZ * 8
            If (Local1 > ELWD (Local0, 28, 4)) { XSTQ (Arg1 + 64, Local1) }
        }
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

    // Delayed writeback for linked ext4 regular files. write() and
    // ftruncate() only change the in-memory cache (VNDA/VNSZ) and record
    // dirty pages in a VDBS-byte bitmap at VNDB, which covers the VFMX file
    // limit. Dirty nodes are linked through VNDQ from EXDH.
    // Writeback (fsync, sync, or an idle CPU after EXPI) resizes the inode
    // to the cached size in one step, so appends get one contiguous
    // allocation, and writes each dirty page once. No syscall but those
    // waits on the disk.
    Name (EXDH, Zero) // Dirty node list
    Name (EXDT, Zero) // MNOW of the last periodic writeback
    Name (EXPI, 5000000000) // Periodic writeback interval in nanoseconds
    Name (VDBS, 0x10000) // Dirty bitmap bytes: one bit per page up to 2 GiB

    // Mark cache pages [Arg1, Arg2) dirty. Arg1 == Arg2 marks only the size.
    Method (EXDM, 3, NotSerialized)
    {
        Local0 = XVWD (Arg0 + VNDB, Ones)
        If (!Local0)
        {
            Local1 = WRIT
            If (XNXE ()) { Local1 |= NOEX }
            Local0 = VALL (VDBS, Local1)
            If (!Local0) { Return (Zero) }
            XSTQ (Arg0 + VNDB, Local0)
            XSTQ (Arg0 + VNDQ, EXDH)
            EXDH = Arg0
        }
        If (Arg2 > VDBS * 8) { Arg2 = VDBS * 8 }
        While (Arg1 < Arg2)
        {
            Local1 = Local0 + Arg1 / 8
            XSTB (Local1, XBYT (Local1) | (One << (Arg1 % 8)))
            Increment (Arg1)
        }
        Return (One)
    }

    // Drop a node's dirty state without writing it.
    Method (EXDC, 1, NotSerialized)
    {
        Local0 = XVWD (Arg0 + VNDB, Ones)
        If (!Local0) { Return (Zero) }
        If (EXDH == Arg0) { EXDH = XVWD (Arg0 + VNDQ, Ones) }
        Else
        {
            Local1 = EXDH
            // LAnd evaluates both operands: test the link only for a node.
            While (Local1)
            {
                If (XVWD (Local1 + VNDQ, Ones) == Arg0) { Break }
                Local1 = XVWD (Local1 + VNDQ, Ones)
            }
            If (Local1) { XSTQ (Local1 + VNDQ, XVWD (Arg0 + VNDQ, Ones)) }
        }
        XSTQ (Arg0 + VNDQ, Zero)
        XSTQ (Arg0 + VNDB, Zero)
        VUNM (Local0, VDBS)
        Return (Zero)
    }

    // write() to a linked ext4 file: copy into the cache and mark it dirty.
    Method (EXWC, 4, NotSerialized)
    {
        Local0 = XVWD (Arg1, Ones)
        If (!(XVWD (Arg1 + 40, Ones) & 3)) { Return (Zero - 9) }
        If (!Arg3) { Return (Zero) }
        If (!EXDM (Local0, Zero, Zero)) { Return (Zero - 12) }
        Local2 = XVWD (Arg1 + 8, Ones)
        If (XVWD (Arg1 + 40, Ones) & 0x400) { Local2 = XVWD (Local0 + VNSZ, Ones) }
        Local1 = VOWR (Arg0, Arg1, Arg2, Arg3)
        If (Local1 && Local1 < Zero - 4095)
        {
            EXDM (Local0, Local2 / PGSZ, (Local2 + Local1 + PGSZ - One) / PGSZ)
        }
        Return (Local1)
    }

    // Write one dirty node back. Data reaches newly allocated blocks before
    // the inode that publishes them. The caller issues the FLUSH.
    Method (EXWB, 1, NotSerialized)
    {
        Local0 = XVWD (Arg0 + VNDB, Ones)
        If (!Local0) { Return (Zero) }
        Local1 = XVWD (Arg0 + VNFO, Ones)
        If (!Local1 || !XVWD (Arg0 + VNPA, Ones))
        {
            EXDC (Arg0)
            Return (Zero)
        }
        EXVL = XVWD (Arg0 + VNFS, Ones)
        If (!XVWD (EXVL + EXRW, Ones)) { Return (Zero - 5) }
        Local2 = XVWD (Arg0 + VNSZ, Ones)
        Local3 = (Local2 + PGSZ - One) / PGSZ
        Local4 = EXIR (Local1)
        If (!Local4) { Return (Zero - 5) }
        Local5 = ELWD (Local4, 4, 4)
        If (Local5 != Local2)
        {
            // Growth makes the old tail block's bytes past its end visible.
            If (Local2 > Local5 && (Local5 % PGSZ)) { EXDM (Arg0, Local5 / PGSZ, Local5 / PGSZ + One) }
            EXSN = Arg0
            EXSD = Local0
            Local6 = EXSZ (Local1, Local2)
            EXSN = Zero
            EXSD = Zero
            If (Local6) { Return (Local6) }
            Local4 = EXIR (Local1)
            If (!Local4) { Return (Zero - 5) }
        }
        Local6 = Zero
        While (Local6 < Local3)
        {
            If (!(Local6 & 63) && !XVWD (Local0 + Local6 / 8, Ones))
            {
                Local6 += 64
                Continue
            }
            If (XBYT (Local0 + Local6 / 8) & (One << (Local6 % 8)))
            {
                Local7 = EXMP (Local4, Local6)
                If (!Local7 || Local7 == Ones) { Return (Zero - 5) }
                Local5 = VCPA (Arg0, Local6)
                If (!Local5)
                {
                    // Truncated away and not rewritten: zeros, unless part
                    // of the page still comes from the disk.
                    Local5 = EXDB
                    XCLR (EXDB)
                    If (Local6 * PGSZ < XVWD (Arg0 + VNVL, Ones))
                    {
                        If (VPOP (Arg0, Local6, Local4)) { Return (Zero - 5) }
                        Local5 = VCPA (Arg0, Local6)
                    }
                }
                If (!EXBW (Local7, Local5)) { Return (Zero - 5) }
            }
            Increment (Local6)
        }
        // The inode now holds every byte, so later misses may read it.
        XSTQ (Arg0 + VNVL, Local2)
        EXDC (Arg0)
        Return (Zero)
    }

    // Write back every dirty node, then FLUSH once.
    Method (EXWA, 0, NotSerialized)
    {
        Local0 = EXDH
        Local1 = Zero
        While (Local0)
        {
            Local2 = XVWD (Local0 + VNDQ, Ones)
            If (EXWB (Local0)) { Local1 = One }
            Local0 = Local2
        }
        If (EXVL) { EXSY () }
        EXDT = MNOW ()
        Return (Local1)
    }

    // Called by an idle CPU while dirty nodes exist.
    Method (EXPW, 0, NotSerialized)
    {
        If (MNOW () - EXDT < EXPI) { Return (Zero) }
        Return (EXWA ())
    }
