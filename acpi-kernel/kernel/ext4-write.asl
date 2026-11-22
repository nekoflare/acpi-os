    // Writable images use 32-byte group descriptors and no journal or checksums.
    // Scratch pages are shared by mounts; syscalls run on the scheduler stack.
    Name (EXGD, Zero)
    Name (EXBM, Zero)
    Name (EXDB, Zero)
    Name (EXIB, Zero)

    Method (EXLE, 4, NotSerialized)
    {
        While (Arg3)
        {
            XSTB (Arg0 + Arg1, Arg2 & 0xFF)
            Increment (Arg1)
            Arg2 >>= 8
            Decrement (Arg3)
        }
    }

    Method (EXBW, 2, NotSerialized)
    {
        If (!XVWD (EXVL + EXRW, Ones)) { Return (Zero) }
        If (Arg0 < XVWD (EXVL + EXBL, Ones))
        {
            Local0 = XVWD (EXVL, Ones) + Arg0 * 8
            XMOV (VDMA, Arg1, PGSZ)
            If (VBRQ (One, Local0, PGSZ))
            {
                Local1 = EXCG (Local0)
                If (Local1) { XMOV (Local1, VDMA, PGSZ) }
                Return (One)
            }
            EXCX (Local0)
        }
        XSTQ (EXVL + EXRW, Zero)
        Return (Zero)
    }

    Method (EXSY, 0, NotSerialized)
    {
        If (!(VFEA & 0x200)) { Return (One) }
        If (VBRQ (4, Zero, Zero)) { Return (One) }
        XSTQ (EXVL + EXRW, Zero)
        Return (Zero)
    }

    Method (EXBT, 1, NotSerialized)
    {
        Return (XBYT (EXBM + Arg0 / 8) & (One << (Arg0 % 8)))
    }

    Method (EXBS, 3, NotSerialized)
    {
        While (Arg1)
        {
            Local0 = EXBM + Arg0 / 8
            Local1 = One << (Arg0 % 8)
            Local2 = XBYT (Local0) & ~Local1
            If (Arg2) { Local2 |= Local1 }
            XSTB (Local0, Local2)
            Increment (Arg0)
            Decrement (Arg1)
        }
    }

    // Update one group's bitmap and free counters. Arg1 selects the inode bitmap.
    // Arg3 is the group-relative index, or Ones to search for a free run.
    Method (EXAG, 6, NotSerialized)
    {
        Local0 = 32 * (Arg0 % 128)
        Local1 = One + Arg0 / 128
        If (!EXRD (Local1, EXGD)) { Return (Zero) }
        Local2 = ELWD (EXGD, Local0 + Arg1 * 4, 4)
        If (!Local2 || !EXRD (Local2, EXBM)) { Return (Zero) }
        Local3 = XVWD (EXVL + EXBG, Ones)
        Local4 = XVWD (EXVL + EXBL, Ones)
        Local5 = One
        If (Arg1)
        {
            Local3 = XVWD (EXVL + EXIG, Ones)
            Local4 = XVWD (EXVL + EXIC, Ones)
            Local5 = 10 // Inode 11 is the first unreserved inode
        }
        Local4 -= Arg0 * Local3
        If (Local4 > Local3) { Local4 = Local3 }
        If (Arg0) { Local5 = Zero }
        Local6 = Arg3
        If (Local6 == Ones)
        {
            // EXSQ asks for a longer free run so the file can grow in place.
            Local7 = Arg2
            If (EXSQ > Local7) { Local7 = EXSQ }
            Local6 = EXSR (Local5, Local4, Local7)
        }
        If (Local6 < Local5 || Local6 >= Local4 ||
            Arg2 > Local4 - Local6) { Return (Zero) }

        Local7 = Zero
        While (Local7 < Arg2)
        {
            // Allocation needs clear bits and freeing needs set ones. Compare
            // LNot results: AML truth is Ones, so "bit != 0" never equals One.
            If (!EXBT (Local6 + Local7) == !Arg4) { Return (Zero) }
            Increment (Local7)
        }
        If (!EXRD (Zero, EXDB)) { Return (Zero) }
        EXBS (Local6, Arg2, Arg4)
        Local5 = Arg2
        If (Arg4) { Local5 = Zero - Arg2 }
        Local7 = Local0 + 12 + Arg1 * 2
        EXLE (EXGD, Local7, ELWD (EXGD, Local7, 2) + Local5, 2)
        Local7 = 1024 + 12 + Arg1 * 4
        EXLE (EXDB, Local7, ELWD (EXDB, Local7, 4) + Local5, 4)
        If (Arg5)
        {
            Local5 = One
            If (!Arg4) { Local5 = Ones }
            EXLE (EXGD, Local0 + 16, ELWD (EXGD, Local0 + 16, 2) + Local5, 2)
        }
        If (!EXBW (Local2, EXBM)) { Return (Zero) }
        If (!EXBW (Local1, EXGD)) { Return (Zero) }
        If (!EXBW (Zero, EXDB)) { Return (Zero) }
        Return (Arg0 * Local3 + Local6 + Arg1)
    }

    // Arg2 is a block number or zero-based inode index, or Ones for any run.
    Method (EXAL, 5, NotSerialized)
    {
        If (!Arg1 || !XVWD (EXVL + EXRW, Ones)) { Return (Zero) }
        Local0 = XVWD (EXVL + EXBG, Ones)
        Local1 = XVWD (EXVL + EXBL, Ones)
        If (Arg0)
        {
            Local0 = XVWD (EXVL + EXIG, Ones)
            Local1 = XVWD (EXVL + EXIC, Ones)
        }
        If (Arg2 == Ones)
        {
            // First look for an EXSW-block run, then settle for an exact fit.
            Local4 = EXSW
            If (Arg0 || Local4 <= Arg1) { Local4 = Zero }
            While (One)
            {
                EXSQ = Local4
                Local2 = Zero
                While (Local2 * Local0 < Local1)
                {
                    Local3 = EXAG (Local2, Arg0, Arg1, Ones, One, Arg4)
                    If (Local3 || !XVWD (EXVL + EXRW, Ones))
                    {
                        EXSQ = Zero
                        Return (Local3)
                    }
                    Increment (Local2)
                }
                If (!Local4) { Break }
                Local4 = Zero
            }
            EXSQ = Zero
            Return (Zero)
        }
        If (Arg2 >= Local1 || Arg1 > Local1 - Arg2) { Return (Zero) }
        If (Arg3)
        {
            Return (EXAG (Arg2 / Local0, Arg0, Arg1, Arg2 % Local0, One, Arg4))
        }

        // An existing extent can span group boundaries.
        Local2 = Arg2
        While (Arg1)
        {
            Local3 = Local0 - Arg2 % Local0
            If (Local3 > Arg1) { Local3 = Arg1 }
            If (!EXAG (Arg2 / Local0, Arg0, Local3, Arg2 % Local0, Zero, Arg4))
            {
                XSTQ (EXVL + EXRW, Zero)
                Return (Zero)
            }
            Arg2 += Local3
            Arg1 -= Local3
        }
        Return (Local2 + Arg0)
    }

    Name (EXSW, Zero) // Preferred free-run length for the next block search
    Name (EXSQ, Zero) // Run length EXAG searches for, set by EXAL

    // Find Arg2 clear bits in [Arg0, Arg1). Whole qwords that are full, or
    // empty without completing the run, are skipped without bit tests.
    Method (EXSR, 3, NotSerialized)
    {
        Local0 = Zero
        While (Arg0 < Arg1)
        {
            If (!(Arg0 & 63) && Arg0 + 64 <= Arg1)
            {
                Local1 = XVWD (EXBM + Arg0 / 8, Ones)
                If (Local1 == Ones)
                {
                    Local0 = Zero
                    Arg0 += 64
                    Continue
                }
                If (!Local1 && Local0 + 64 < Arg2)
                {
                    Local0 += 64
                    Arg0 += 64
                    Continue
                }
            }
            If (EXBT (Arg0)) { Local0 = Zero }
            Else
            {
                Increment (Local0)
                If (Local0 == Arg2) { Return (Arg0 + One - Local0) }
            }
            Increment (Arg0)
        }
        Return (Ones)
    }

    // Return the inline extent count for inodes we can modify.
    Method (EXEC, 1, NotSerialized)
    {
        If (!Arg0 || ELWD (Arg0, 40, 2) != 0xF30A ||
            ELWD (Arg0, 46, 2) || ELWD (Arg0, 42, 2) > 4 ||
            ELWD (Arg0, 104, 4) || ELWD (Arg0, 108, 4)) { Return (Ones) }
        Local0 = ELWD (Arg0, 42, 2)
        Local1 = Zero
        While (Local1 < Local0)
        {
            Local2 = Arg0 + 52 + Local1 * 12
            Local3 = ELWD (Local2, 4, 2)
            Local4 = ELWD (Local2, 8, 4)
            If (!Local3 || Local3 > 0x8000 || ELWD (Local2, 6, 2) ||
                !Local4 || Local4 + Local3 > XVWD (EXVL + EXBL, Ones)) { Return (Ones) }
            Increment (Local1)
        }
        Return (Local0)
    }

    Method (EXHD, 4, NotSerialized)
    {
        // The caller keeps the old extent entries until after the inode write.
        Local0 = Zero
        While (Local0 < 60)
        {
            XSTB (Arg0 + 40 + Local0, Zero)
            Increment (Local0)
        }
        EXLE (Arg0, 4, Arg1, 4)
        EXLE (Arg0, 28, Arg3 * 8, 4)
        EXLE (Arg0, 32, 0x80000, 4)
        EXLE (Arg0, 40, 0xF30A, 2)
        EXLE (Arg0, 44, 4, 2)
        If (Arg3)
        {
            EXLE (Arg0, 42, One, 2)
            EXLE (Arg0, 56, Arg3, 2)
            EXLE (Arg0, 60, Arg2, 4)
        }
    }

    Name (EXOL, Buffer (48) {}) // Snapshot of the four inline extent entries
    Name (EXSN, Zero) // During writeback, the node whose cache EXSZ fills new blocks from
    Name (EXSD, Zero) // During writeback, the dirty bitmap of that cache

    // Fill block Arg0, logical block Arg1 of the file being resized: from
    // the writeback cache when there is one (clearing its dirty bit), or
    // with zeros. A page that is not resident comes from the old block.
    Method (EXZW, 2, NotSerialized)
    {
        If (EXSN)
        {
            If (EXSD)
            {
                Local0 = EXSD + Arg1 / 8
                XSTB (Local0, XBYT (Local0) & ~(One << (Arg1 % 8)))
            }
            Local0 = VCPA (EXSN, Arg1)
            If (Local0) { Return (EXBW (Arg0, Local0)) }
        }
        XCLR (EXDB)
        If (EXSN)
        {
            Local1 = XVWD (EXSN + VNVL, Ones) - Arg1 * PGSZ
            If (Arg1 * PGSZ < XVWD (EXSN + VNVL, Ones))
            {
                // The extent tree is still the old one until EXHD.
                Local0 = EXMP (EXIR (XVWD (EXSN + VNIN, Ones)), Arg1)
                If (!Local0) { Return (Zero) }
                If (Local0 != Ones && !EXRD (Local0, EXDB)) { Return (Zero) }
                If (Local1 < PGSZ) { FTZC (EXDB + Local1, PGSZ - Local1) }
            }
        }
        Return (EXBW (Arg0, EXDB))
    }

    Method (EXFB, 1, NotSerialized)
    {
        Local0 = XADR (EXOL)
        While (Arg0)
        {
            If (!EXAL (Zero, ELWD (Local0, 4, 2), ELWD (Local0, 8, 4), Zero, Zero))
            {
                Return (Zero)
            }
            Local0 += 12
            Decrement (Arg0)
        }
        Return (One)
    }

    // Resize regular files and directory block storage. The common growth path
    // extends an existing contiguous extent; fragmentation falls back to a
    // replacement run. Newly allocated space is zeroed before publication.
    Method (EXSZ, 2, NotSerialized)
    {
        Local0 = EXIR (Arg0)
        Local1 = EXEC (Local0)
        If (Local1 == Ones) { Return (Zero - 95) }
        Local2 = ELWD (Local0, 4, 4)
        Local3 = (Arg1 + PGSZ - One) / PGSZ
        Local4 = (Local2 + PGSZ - One) / PGSZ
        If (Arg1 == Local2) { Return (Zero) }
        If (Local3 == Local4)
        {
            EXLE (Local0, 4, Arg1, 4)
            If (!EXBW (EXIB, EXIN)) { Return (Zero - 5) }
            Return (Zero)
        }
        If (Local1 && Local3 > Local4)
        {
            Local5 = EXAP (Arg0, Arg1, Local1, Local3, Local4)
            If (Local5 != One) { Return (Local5) }
            Local0 = EXIR (Arg0)
            If (!Local0) { Return (Zero - 5) }
        }
        ElseIf (Local1 && Local3) { Return (EXSH (Arg0, Arg1, Local3)) }
        XMOV (XADR (EXOL), Local0 + 52, 48)
        Local5 = Zero
        Local6 = Zero
        If (Local3 && Local1 == One && !ELWD (Local0, 52, 4) &&
            ELWD (Local0, 56, 2) == Local4 && Local3 > Local4)
        {
            Local5 = ELWD (Local0, 60, 4)
            Local6 = EXAL (Zero, Local3 - Local4, Local5 + Local4, One, Zero)
        }
        If (Local3 && !Local6)
        {
            // Leave room to grow in place, so relocation stays rare.
            EXSW = Local3 * 2
            If (EXSW > 0x8000) { EXSW = 0x8000 }
            Local5 = EXAL (Zero, Local3, Ones, One, Zero)
            EXSW = Zero
            If (!Local5)
            {
                If (!XVWD (EXVL + EXRW, Ones)) { Return (Zero - 5) }
                Return (Zero - 28)
            }
        }
        Local7 = Zero
        If (Local6) { Local7 = Local4 }
        While (Local7 < Local3)
        {
            Local0 = Ones
            If (Local7 < Local4 && !Local6 && !EXSN)
            {
                Local0 = EXMP (EXIR (Arg0), Local7)
            }
            If (Local0 == Ones)
            {
                If (!EXZW (Local5 + Local7, Local7)) { Return (Zero - 5) }
            }
            ElseIf (!Local0 || !EXRD (Local0, EXDB) || !EXBW (Local5 + Local7, EXDB))
            {
                Return (Zero - 5)
            }
            Increment (Local7)
        }
        Local0 = EXIR (Arg0)
        If (!Local0) { Return (Zero - 5) }
        EXHD (Local0, Arg1, Local5, Local3)
        If (!EXBW (EXIB, EXIN)) { Return (Zero - 5) }
        If (!Local6)
        {
            If (!EXFB (Local1)) { Return (Zero - 5) }
        }
        Return (Zero)
    }

    // Grow a file by extending its last extent in place, or by adding an
    // inline extent elsewhere, so existing blocks are never copied. Returns
    // One when neither applies and the caller must relocate the file.
    Method (EXAP, 5, NotSerialized)
    {
        Local0 = EXIR (Arg0)
        If (!Local0) { Return (Zero - 5) }
        Local1 = Local0 + 52 + (Arg2 - One) * 12
        Local2 = ELWD (Local1, Zero, 4)
        Local3 = ELWD (Local1, 4, 2)
        Local4 = ELWD (Local1, 8, 4)
        If (Local2 + Local3 != Arg4) { Return (One) }
        Local5 = Arg3 - Arg4
        Local6 = Zero
        Local7 = Zero
        If (Local3 + Local5 <= 0x8000)
        {
            If (EXAL (Zero, Local5, Local4 + Local3, One, Zero)) { Local6 = Local4 + Local3 }
            ElseIf (!XVWD (EXVL + EXRW, Ones)) { Return (Zero - 5) }
        }
        If (!Local6)
        {
            If (Arg2 >= 4 || ELWD (Local0, 44, 2) <= Arg2 || Local5 > 0x8000) { Return (One) }
            EXSW = Arg3
            If (EXSW > 0x8000) { EXSW = 0x8000 }
            Local6 = EXAL (Zero, Local5, Ones, One, Zero)
            EXSW = Zero
            If (!Local6)
            {
                If (!XVWD (EXVL + EXRW, Ones)) { Return (Zero - 5) }
                Return (Zero - 28)
            }
            Local7 = One
        }
        Local2 = Zero
        While (Local2 < Local5)
        {
            If (!EXZW (Local6 + Local2, Arg4 + Local2)) { Return (Zero - 5) }
            Increment (Local2)
        }
        Local0 = EXIR (Arg0)
        If (!Local0) { Return (Zero - 5) }
        If (Local7)
        {
            Local1 = Local0 + 52 + Arg2 * 12
            EXLE (Local1, Zero, Arg4, 4)
            EXLE (Local1, 4, Local5, 2)
            EXLE (Local1, 6, Zero, 2)
            EXLE (Local1, 8, Local6, 4)
            EXLE (Local0, 42, Arg2 + One, 2)
        }
        Else
        {
            Local1 = Local0 + 52 + (Arg2 - One) * 12
            EXLE (Local1, 4, ELWD (Local1, 4, 2) + Local5, 2)
        }
        EXLE (Local0, 4, Arg1, 4)
        EXLE (Local0, 28, ELWD (Local0, 28, 4) + Local5 * 8, 4)
        If (!EXBW (EXIB, EXIN)) { Return (Zero - 5) }
        Return (Zero)
    }

    // Shrink to Arg2 > 0 blocks by trimming extents in place. Blocks are
    // freed only after the inode no longer references them.
    Method (EXSH, 3, NotSerialized)
    {
        Local0 = EXIR (Arg0)
        If (!Local0) { Return (Zero - 5) }
        Local1 = ELWD (Local0, 42, 2)
        XMOV (XADR (EXOL), Local0 + 52, 48)
        Local2 = Zero // Blocks released
        Local3 = Zero // Extents kept
        Local4 = Zero
        While (Local4 < Local1)
        {
            Local5 = Local0 + 52 + Local4 * 12
            Local6 = ELWD (Local5, Zero, 4)
            Local7 = ELWD (Local5, 4, 2)
            If (Local6 >= Arg2) { Local2 += Local7 }
            Else
            {
                If (Local6 + Local7 > Arg2)
                {
                    Local2 += Local6 + Local7 - Arg2
                    EXLE (Local5, 4, Arg2 - Local6, 2)
                }
                Increment (Local3)
            }
            Increment (Local4)
        }
        Local4 = 52 + Local3 * 12
        While (Local4 < 52 + Local1 * 12)
        {
            XSTB (Local0 + Local4, Zero)
            Increment (Local4)
        }
        EXLE (Local0, 42, Local3, 2)
        EXLE (Local0, 4, Arg1, 4)
        EXLE (Local0, 28, ELWD (Local0, 28, 4) - Local2 * 8, 4)
        If (!EXBW (EXIB, EXIN)) { Return (Zero - 5) }
        Local0 = XADR (EXOL)
        While (Local1)
        {
            Local6 = ELWD (Local0, Zero, 4)
            Local7 = ELWD (Local0, 4, 2)
            Local5 = ELWD (Local0, 8, 4)
            If (Local6 >= Arg2)
            {
                If (!EXAL (Zero, Local7, Local5, Zero, Zero)) { Return (Zero - 5) }
            }
            ElseIf (Local6 + Local7 > Arg2)
            {
                If (!EXAL (Zero, Local6 + Local7 - Arg2, Local5 + Arg2 - Local6, Zero, Zero))
                {
                    Return (Zero - 5)
                }
            }
            Local0 += 12
            Decrement (Local1)
        }
        Return (Zero)
    }

    Method (EXDI, 5, NotSerialized)
    {
        EXLE (Arg0, Zero, Arg1, 4)
        EXLE (Arg0, 4, Arg2, 2)
        If (Arg3)
        {
            XSTB (Arg0 + 6, XVWD (Arg3 + VNNL, Ones))
            XSTB (Arg0 + 7, Arg4)
            XMOV (Arg0 + 8, XVWD (Arg3 + VNNA, Ones), XVWD (Arg3 + VNNL, Ones))
        }
    }

    // Directory entries are a sequence of aligned records within each block.
    // Arg3 is zero for removal, One for insertion, Two for replacement.
    Method (EXED, 5, NotSerialized)
    {
        Local0 = EXIR (XVWD (Arg0 + VNFO, Ones))
        If (!Local0 || EXEC (Local0) == Ones) { Return (Zero - 95) }
        Local1 = ELWD (Local0, 4, 4) / PGSZ
        Local2 = Zero
        While (Local2 < Local1)
        {
            Local3 = EXMP (Local0, Local2)
            If (!Local3 || Local3 == Ones || !EXRD (Local3, EXDB)) { Return (Zero - 5) }
            Local4 = EXDB
            While (Local4 < EXDB + PGSZ)
            {
                Local5 = ELWD (Local4, 4, 2)
                Local6 = ELWD (Local4, Zero, 4)
                Local7 = (8 + XBYT (Local4 + 6) + 3) & ~3
                If (Local5 < 8 || (Local5 & 3) || Local4 + Local5 > EXDB + PGSZ ||
                    (Local6 && Local7 > Local5)) { Return (Zero - 5) }
                If (Arg3 == One)
                {
                    If (!Local6) { Local7 = Zero }
                    If (Local5 >= Local7 + ((8 + XVWD (Arg1 + VNNL, Ones) + 3) & ~3))
                    {
                        If (Local7) { EXLE (Local4, 4, Local7, 2) }
                        EXDI (Local4 + Local7, Arg2, Local5 - Local7, Arg1, Arg4)
                        If (!EXBW (Local3, EXDB)) { Return (Zero - 5) }
                        Return (Zero)
                    }
                }
                ElseIf (Local6 && Local6 == XVWD (Arg1 + VNFO, Ones) &&
                    EXEQ (Local4, Arg1))
                {
                    If (Arg3)
                    {
                        EXLE (Local4, Zero, Arg2, 4)
                        XSTB (Local4 + 7, Arg4)
                    }
                    Else { EXRM (Local4, Local5) }
                    If (!EXBW (Local3, EXDB)) { Return (Zero - 5) }
                    Return (Zero)
                }
                Local4 += Local5
            }
            Increment (Local2)
        }
        If (Arg3 != One) { Return (Zero - 2) }
        If (Local1 >= 0x100000 / PGSZ) { Return (Zero - 28) }
        Local3 = EXSZ (XVWD (Arg0 + VNFO, Ones), (Local1 + One) * PGSZ)
        If (Local3) { Return (Local3) }
        Local3 = EXMP (EXIR (XVWD (Arg0 + VNFO, Ones)), Local1)
        If (!Local3 || Local3 == Ones) { Return (Zero - 5) }
        XCLR (EXDB)
        EXDI (EXDB, Arg2, PGSZ, Arg1, Arg4)
        If (!EXBW (Local3, EXDB)) { Return (Zero - 5) }
        Return (Zero)
    }

    Method (EXRM, 2, NotSerialized)
    {
        If (Arg0 == EXDB)
        {
            EXLE (Arg0, Zero, Zero, 4)
            Return (Zero)
        }
        Local0 = EXDB
        While (One)
        {
            Local1 = ELWD (Local0, 4, 2)
            If (Local0 + Local1 == Arg0)
            {
                EXLE (Local0, 4, Local1 + Arg1, 2)
                Return (Zero)
            }
            Local0 += Local1
        }
    }

    Method (EXEQ, 2, NotSerialized)
    {
        Local0 = XVWD (Arg1 + VNNL, Ones)
        If (XBYT (Arg0 + 6) != Local0) { Return (Zero) }
        Local1 = XVWD (Arg1 + VNNA, Ones)
        While (Local0)
        {
            Decrement (Local0)
            If (XBYT (Arg0 + 8 + Local0) != XBYT (Local1 + Local0)) { Return (Zero) }
        }
        Return (One)
    }

    Method (EXLK, 2, NotSerialized)
    {
        Local0 = EXIR (Arg0)
        If (!Local0) { Return (Zero) }
        EXLE (Local0, 26, ELWD (Local0, 26, 2) + Arg1, 2)
        Return (EXBW (EXIB, EXIN))
    }

    Method (EXCR, 2, NotSerialized)
    {
        Local0 = XVWD (Arg0 + VNPA, Ones)
        EXVL = XVWD (Local0 + VNFS, Ones)
        Local1 = Zero
        Local6 = One
        If ((Arg1 & 0xF000) == 0x4000) { Local1 = One Local6 = 2 }
        ElseIf ((Arg1 & 0xF000) == 0xA000) { Local6 = 7 }
        Local2 = EXAL (One, One, Ones, One, Local1)
        If (!Local2)
        {
            If (!XVWD (EXVL + EXRW, Ones)) { Return (Zero - 5) }
            Return (Zero - 28)
        }
        Local3 = Zero
        If (Local1)
        {
            Local3 = EXAL (Zero, One, Ones, One, Zero)
            If (!Local3)
            {
                EXAL (One, One, Local2 - One, Zero, One)
                Return (Zero - 28)
            }
            XCLR (EXDB)
            EXDI (EXDB, Local2, 12, Zero, Zero)
            EXLE (EXDB, 6, 0x2E0201, 3)
            EXDI (EXDB + 12, XVWD (Local0 + VNFO, Ones), PGSZ - 12, Zero, Zero)
            EXLE (EXDB + 12, 6, 0x2E2E0202, 4)
            If (!EXBW (Local3, EXDB)) { Return (Zero - 5) }
        }
        Local4 = EXIR (Local2)
        If (!Local4) { Return (Zero - 5) }
        Local5 = XVWD (EXVL + EXIS, Ones)
        While (Local5)
        {
            Local5 -= 8
            XSTQ (Local4 + Local5, Zero)
        }
        EXLE (Local4, Zero, Arg1, 2)
        EXLE (Local4, 26, One + Local1, 2)
        EXHD (Local4, Local1 * PGSZ, Local3, Local1)
        If (!EXBW (EXIB, EXIN)) { Return (Zero - 5) }
        Local5 = EXED (Local0, Arg0, Local2, One, Local6)
        If (Local5)
        {
            If (XVWD (EXVL + EXRW, Ones)) { EXDL (Local2, Local1) }
            Return (Local5)
        }
        If (Local1)
        {
            If (!EXLK (XVWD (Local0 + VNFO, Ones), One)) { Return (Zero - 5) }
        }
        XSTQ (Arg0 + VNFS, EXVL)
        XSTQ (Arg0 + VNFO, Local2)
        XSTQ (Arg0 + VNMD, Arg1)
        If (Local6 == One) { XSTQ (Arg0 + VNIN, Local2) }
        If (!EXSY ()) { Return (Zero - 5) }
        Return (Zero)
    }

    Method (EXDL, 2, NotSerialized)
    {
        // Fast symlink targets live in i_block and own no data blocks.
        Local2 = EXIR (Arg0)
        If (Local2 && (ELWD (Local2, Zero, 2) & 0xF000) == 0xA000 &&
            ELWD (Local2, 4, 4) <= 60)
        {
            // No EXSZ: i_block is the target, not an extent tree.
        }
        ElseIf (EXSZ (Arg0, Zero)) { Return (Zero) }
        Local0 = EXIR (Arg0)
        If (!Local0) { Return (Zero) }
        Local1 = XVWD (EXVL + EXIS, Ones)
        While (Local1)
        {
            Local1 -= 8
            XSTQ (Local0 + Local1, Zero)
        }
        If (!EXBW (EXIB, EXIN)) { Return (Zero) }
        If (!EXAL (One, One, Arg0 - One, Zero, Arg1)) { Return (Zero) }
        Return (EXSY ())
    }

    Method (EXUL, 2, NotSerialized)
    {
        EXVL = XVWD (Arg0 + VNFS, Ones)
        Local0 = EXED (Arg0, Arg1, Zero, Zero, Zero)
        If (Local0) { Return (Local0) }
        If (XVWD (Arg1 + VNTY, Ones) == 4)
        {
            If (!EXLK (XVWD (Arg0 + VNFO, Ones), Ones)) { Return (Zero - 5) }
        }
        If (!EXSY ()) { Return (Zero - 5) }
        Return (Zero)
    }

    // Change the destination first, then remove the old entry. The scheduler
    // prevents concurrent observation of intermediate directory records.
    Method (EXRN, 4, NotSerialized)
    {
        EXVL = XVWD (Arg0 + VNFS, Ones)
        Local0 = XVWD (Arg1 + VNFO, Ones)
        Local1 = Zero
        If (XVWD (Arg1 + VNTY, Ones) == 4) { Local1 = One }
        Local5 = EXFT (Arg1)
        If (Arg3) { Local2 = EXED (Arg2, Arg3, Local0, 2, Local5) }
        Else
        {
            // The replacement name has been copied into a scratch VFS record.
            Local2 = EXED (Arg2, XADR (EXNM), Local0, One, Local5)
        }
        If (Local2) { Return (Local2) }
        Local2 = EXED (Arg0, Arg1, Zero, Zero, Zero)
        If (Local2) { Return (Local2) }
        If (Local1)
        {
            If (Arg0 != Arg2)
            {
                Local3 = EXMP (EXIR (Local0), Zero)
                If (!Local3 || Local3 == Ones || !EXRD (Local3, EXDB)) { Return (Zero - 5) }
                Local4 = ELWD (EXDB, 4, 2)
                If (!SHMT (EXDB + Local4 + 8, XBYT (EXDB + Local4 + 6), ".."))
                {
                    Return (Zero - 5)
                }
                EXLE (EXDB, Local4, XVWD (Arg2 + VNFO, Ones), 4)
                If (!EXBW (Local3, EXDB)) { Return (Zero - 5) }
                If (!EXLK (XVWD (Arg0 + VNFO, Ones), Ones)) { Return (Zero - 5) }
                If (!Arg3)
                {
                    If (!EXLK (XVWD (Arg2 + VNFO, Ones), One)) { Return (Zero - 5) }
                }
            }
            ElseIf (Arg3)
            {
                If (!EXLK (XVWD (Arg0 + VNFO, Ones), Ones)) { Return (Zero - 5) }
            }
        }
        If (!EXSY ()) { Return (Zero - 5) }
        Return (Zero)
    }

    Name (EXNM, Buffer (40) {})

    // ext4 dirent filetype for a VFS node: 1 file, 2 directory, 7 symlink.
    Method (EXFT, 1, NotSerialized)
    {
        Local0 = XVWD (Arg0 + VNTY, Ones)
        If (Local0 == 4) { Return (2) }
        If (Local0 == 10) { Return (7) }
        Return (One)
    }

    // Publish a symlink's cached target. Fast targets occupy i_block;
    // longer targets use the same extent blocks as regular files.
    Method (EXSV, 1, NotSerialized)
    {
        EXVL = XVWD (Arg0 + VNFS, Ones)
        Local0 = EXIR (XVWD (Arg0 + VNFO, Ones))
        If (!Local0 || (ELWD (Local0, Zero, 2) & 0xF000) != 0xA000) { Return (Zero - 5) }
        Local1 = XVWD (Arg0 + VNSZ, Ones)
        If (Local1 <= 60)
        {
            Local2 = Local0 + 40
            Local3 = Zero
            While (Local3 < 60)
            {
                XSTB (Local2 + Local3, Zero)
                Increment (Local3)
            }
            If (Local1) { XMOV (Local2, XVWD (Arg0 + VNDA, Ones), Local1) }
            EXLE (Local0, 4, Local1, 4)
            EXLE (Local0, 28, Zero, 4)
            If (!EXBW (EXIB, EXIN)) { Return (Zero - 5) }
            If (!EXSY ()) { Return (Zero - 5) }
            Return (Zero)
        }
        Local2 = EXSZ (XVWD (Arg0 + VNFO, Ones), Local1)
        If (Local2) { Return (Local2) }
        Local0 = EXIR (XVWD (Arg0 + VNFO, Ones))
        If (!Local0) { Return (Zero - 5) }
        Local2 = Zero
        While (Local2 < Local1)
        {
            Local3 = EXMP (Local0, Local2 / PGSZ)
            If (!Local3 || Local3 == Ones) { Return (Zero - 5) }
            Local4 = Local1 - Local2
            If (Local4 > PGSZ) { Local4 = PGSZ }
            XCLR (EXDB)
            XMOV (EXDB, XVWD (Arg0 + VNDA, Ones) + Local2, Local4)
            If (!EXBW (Local3, EXDB)) { Return (Zero - 5) }
            Local2 += PGSZ
        }
        If (!EXSY ()) { Return (Zero - 5) }
        Return (Zero)
    }
