    // Demand-paged cache for ext4 regular files. A node with VNIN set owns
    // a window of kernel virtual space at VNDA, VNCP bytes long, in which
    // only pages that something touched are mapped. Code that dereferences
    // VNDA first calls VENS for the bytes it needs; pages are read from the
    // inode on first use. Bytes at or past VNVL are zero without a disk read:
    // they were never written, were truncated away, or the inode is gone.
    // Clean pages are dropped under memory pressure, least recently used
    // node first. Dirty pages (see EXDM) and unlinked files stay resident.
    Name (VNIN, 400) // Inode backing a demand-paged node, or zero
    Name (VNVL, 408) // Bytes the inode holds valid data for
    Name (VNLQ, 416) // Next (less recently used) node with a window
    Name (VNLP, 424) // Previous (more recently used) node with a window

    Name (VFMX, 0x7FFFFFFF) // ext4 without large_file caps i_size here

    // Windows are carved out of 256 GiB above the LAPIC and framebuffer
    // mappings, in 2 MiB chunks so a window owns whole page tables.
    Name (VWBS, 0xFFFFFF4000000000)
    Name (VWCH, 131072)
    Name (VWCS, 0x200000)
    Name (VWBM, Zero) // Chunk allocation bitmap
    Name (VWHT, Zero) // Next-fit search start

    Name (VLRH, Zero) // Most recently used node with a window
    Name (VLRT, Zero) // Least recently used node with a window
    Name (VCPC, Zero) // Mapped cache pages
    Name (VCMX, Zero) // Cache size, in pages, that triggers eviction
    Name (VCLO, Zero) // Free pages below which eviction starts
    Name (VEPN, Zero) // Node whose pages [VEPL, VEPH) VENS is populating
    Name (VEPL, Zero)
    Name (VEPH, Zero)

    // Reserve Arg0 contiguous chunks. Returns the window base, or zero.
    Method (VWNA, 1, NotSerialized)
    {
        If (!VWBM)
        {
            Local0 = WRIT
            If (XNXE ()) { Local0 |= NOEX }
            VWBM = VALL (VWCH / 8, Local0)
            If (!VWBM) { Return (Zero) }
        }
        Local0 = VWHT
        Local1 = Zero
        Local2 = Zero
        While (Local1 < VWCH + Arg0)
        {
            If (Local0 >= VWCH)
            {
                Local0 = Zero
                Local2 = Zero
            }
            If (!(Local0 & 63) && XLDQ (VWBM + Local0 / 8) == Ones)
            {
                Local0 += 64
                Local1 += 64
                Local2 = Zero
                Continue
            }
            If (XBYT (VWBM + Local0 / 8) & (One << (Local0 % 8))) { Local2 = Zero }
            Else
            {
                Increment (Local2)
                If (Local2 == Arg0)
                {
                    Local3 = Local0 + One - Arg0
                    VWBT (Local3, Arg0, One)
                    VWHT = Local0 + One
                    Return (VWBS + Local3 * VWCS)
                }
            }
            Increment (Local0)
            Increment (Local1)
        }
        Return (Zero)
    }

    Method (VWBT, 3, NotSerialized)
    {
        While (Arg1)
        {
            Local0 = VWBM + Arg0 / 8
            Local1 = One << (Arg0 % 8)
            If (Arg2) { XSTB (Local0, XBYT (Local0) | Local1) }
            Else { XSTB (Local0, XBYT (Local0) & ~Local1) }
            Increment (Arg0)
            Decrement (Arg1)
        }
    }

    // Address of the page-directory entry covering window address Arg0.
    // Arg1 creates missing upper tables; otherwise a missing one gives zero.
    Method (VCPE, 2, NotSerialized)
    {
        Local0 = HHDO + XCR3 ()
        Local1 = 39
        While (Local1 > 21)
        {
            Local2 = Local0 + ((Arg0 >> Local1) & 0x1FF) * 8
            Local3 = XLDQ (Local2)
            If (!(Local3 & PRES))
            {
                If (!Arg1) { Return (Zero) }
                Local4 = PALC ()
                If (!Local4) { Return (Zero) }
                XCLR (HHDO + Local4)
                Local3 = Local4 | PRES | WRIT | USER | VOWN
                XSTQ (Local2, Local3)
                If (Local1 == 39) { Increment (KPGE) }
            }
            Local0 = HHDO + (Local3 & PMSK)
            Local1 -= 9
        }
        Return (Local0 + ((Arg0 >> 21) & 0x1FF) * 8)
    }

    // Address of the leaf entry for window address Arg0, or zero when its
    // page table does not exist.
    Method (VCPT, 1, NotSerialized)
    {
        Local0 = VCPE (Arg0, Zero)
        If (!Local0) { Return (Zero) }
        Local1 = XLDQ (Local0)
        If (!(Local1 & PRES)) { Return (Zero) }
        Return (HHDO + (Local1 & PMSK) + ((Arg0 >> 12) & 0x1FF) * 8)
    }

    // Kernel address of cache page Arg1, or zero when it is not resident.
    // The local TLB entry is dropped first: another CPU may have evicted
    // and refilled the page since this one last touched it.
    Method (VCPA, 2, NotSerialized)
    {
        Local0 = XLDQ (Arg0 + VNDA)
        If (!XLDQ (Arg0 + VNIN)) { Return (Local0 + Arg1 * PGSZ) }
        If (!Local0) { Return (Zero) }
        Local0 += Arg1 * PGSZ
        Local1 = VCPT (Local0)
        If (!Local1) { Return (Zero) }
        If (!(XLDQ (Local1) & PRES)) { Return (Zero) }
        XINV (Local0)
        Return (Local0)
    }

    // LRU list maintenance. A node is listed exactly while it has a window.
    Method (VLUN, 1, NotSerialized)
    {
        Local0 = XLDQ (Arg0 + VNLP)
        Local1 = XLDQ (Arg0 + VNLQ)
        If (Local0) { XSTQ (Local0 + VNLQ, Local1) }
        ElseIf (VLRH == Arg0) { VLRH = Local1 }
        Else { Return (Zero) }
        If (Local1) { XSTQ (Local1 + VNLP, Local0) }
        Else { VLRT = Local0 }
        XSTQ (Arg0 + VNLP, Zero)
        XSTQ (Arg0 + VNLQ, Zero)
        Return (Zero)
    }

    Method (VLTO, 1, NotSerialized)
    {
        If (VLRH == Arg0) { Return (Zero) }
        VLUN (Arg0)
        XSTQ (Arg0 + VNLQ, VLRH)
        If (VLRH) { XSTQ (VLRH + VNLP, Arg0) }
        VLRH = Arg0
        If (!VLRT) { VLRT = Arg0 }
        Return (Zero)
    }

    // Unmap one resident leaf at Arg1 (its entry address) for address Arg0.
    Method (VCDL, 2, NotSerialized)
    {
        Local0 = XLDQ (Arg1) & PMSK
        XSTQ (Arg1, Zero)
        XINV (Arg0)
        PDEL (Local0)
        Decrement (VCPC)
    }

    // Unmap every resident page, dirty or not, and give the window back.
    Method (VCRL, 1, NotSerialized)
    {
        If (!XLDQ (Arg0 + VNIN)) { Return (Zero) }
        Local0 = XLDQ (Arg0 + VNDA)
        If (!Local0) { Return (Zero) }
        Local1 = XLDQ (Arg0 + VNCP) / VWCS
        Local2 = Zero
        While (Local2 < Local1)
        {
            Local3 = Local0 + Local2 * VWCS
            Local4 = VCPE (Local3, Zero)
            If (Local4)
            {
                Local5 = XLDQ (Local4)
                If (Local5 & PRES)
                {
                    Local6 = HHDO + (Local5 & PMSK)
                    Local7 = Zero
                    While (Local7 < 512)
                    {
                        If (XLDQ (Local6 + Local7 * 8) & PRES)
                        {
                            VCDL (Local3 + Local7 * PGSZ, Local6 + Local7 * 8)
                        }
                        Increment (Local7)
                    }
                    XSTQ (Local4, Zero)
                    PDEL (Local5 & PMSK)
                }
            }
            Increment (Local2)
        }
        VWBT ((Local0 - VWBS) / VWCS, Local1, Zero)
        VLUN (Arg0)
        XSTQ (Arg0 + VNDA, Zero)
        XSTQ (Arg0 + VNCP, Zero)
        Return (Zero)
    }

    // Whether page Arg1 of Arg0 must stay resident.
    Method (VCKP, 2, NotSerialized)
    {
        If (Arg0 == VEPN && Arg1 >= VEPL && Arg1 < VEPH) { Return (One) }
        Local0 = XLDQ (Arg0 + VNDB)
        If (!Local0) { Return (Zero) }
        Return ((XBYT (Local0 + Arg1 / 8) >> (Arg1 % 8)) & One)
    }

    // Drop the clean pages of Arg0. Unlinked files have no disk copy.
    Method (VCEV, 1, NotSerialized)
    {
        If (!XLDQ (Arg0 + VNIN) || !XLDQ (Arg0 + VNPA)) { Return (Zero) }
        Local0 = XLDQ (Arg0 + VNDA)
        If (!Local0) { Return (Zero) }
        Local1 = XLDQ (Arg0 + VNCP) / VWCS
        Local2 = Zero
        Local7 = Zero // Pages kept
        While (Local2 < Local1)
        {
            Local3 = Local0 + Local2 * VWCS
            Local4 = VCPT (Local3)
            If (Local4)
            {
                Local5 = Zero
                While (Local5 < 512)
                {
                    Local6 = Local4 + Local5 * 8
                    If (XLDQ (Local6) & PRES)
                    {
                        If (VCKP (Arg0, Local2 * 512 + Local5)) { Increment (Local7) }
                        Else { VCDL (Local3 + Local5 * PGSZ, Local6) }
                    }
                    Increment (Local5)
                }
            }
            Increment (Local2)
        }
        If (!Local7 && !XLDQ (Arg0 + VNDB) && Arg0 != VEPN) { VCRL (Arg0) }
        Return (Zero)
    }

    Method (VCLW, 0, NotSerialized)
    {
        Return (VCPC >= VCMX || PTOT - PUSE < VCLO)
    }

    // Make room before mapping another page, oldest windows first, and
    // the node being filled last.
    Method (VCRC, 0, NotSerialized)
    {
        If (!VCMX)
        {
            VCMX = PTOT / 4
            VCLO = PTOT / 16
            If (VCLO < 2048) { VCLO = 2048 }
        }
        If (!VCLW ()) { Return (Zero) }
        Local0 = VLRT
        While (Local0 && VCLW ())
        {
            Local1 = XLDQ (Local0 + VNLP)
            If (Local0 != VEPN) { VCEV (Local0) }
            Local0 = Local1
        }
        If (VEPN && VCLW ()) { VCEV (VEPN) }
        Return (Zero)
    }

    // Make the window of Arg0 cover Arg1 bytes. Growth moves whole page
    // tables to a larger window, so resident pages are never copied.
    Method (VCGR, 2, NotSerialized)
    {
        Local0 = XLDQ (Arg0 + VNCP)
        Local1 = XLDQ (Arg0 + VNDA)
        If (Local1 && Arg1 <= Local0) { Return (One) }
        If (Arg1 > VFMX) { Return (Zero) }
        Local2 = XLDQ (Arg0 + VNSZ)
        If (Local2 > Arg1) { Arg1 = Local2 }
        Local2 = VWCS
        If (Local0) { Local2 = Local0 * 2 }
        While (Local2 < Arg1) { Local2 *= 2 }
        If (Local2 > VFMX + One) { Local2 = VFMX + One }
        Local3 = VWNA (Local2 / VWCS)
        If (!Local3) { Return (Zero) }
        // Create the new directories first so the move cannot fail halfway.
        Local4 = Zero
        While (Local4 < Local2 / VWCS)
        {
            If (!VCPE (Local3 + Local4 * VWCS, One))
            {
                VWBT ((Local3 - VWBS) / VWCS, Local2 / VWCS, Zero)
                Return (Zero)
            }
            Increment (Local4)
        }
        If (Local1)
        {
            Local4 = Zero
            While (Local4 < Local0 / VWCS)
            {
                Local5 = VCPE (Local1 + Local4 * VWCS, Zero)
                If (Local5)
                {
                    Local6 = XLDQ (Local5)
                    If (Local6 & PRES)
                    {
                        XSTQ (VCPE (Local3 + Local4 * VWCS, Zero), Local6)
                        XSTQ (Local5, Zero)
                        Local5 = HHDO + (Local6 & PMSK)
                        Local7 = Zero
                        While (Local7 < 512)
                        {
                            If (XLDQ (Local5 + Local7 * 8) & PRES)
                            {
                                XINV (Local1 + Local4 * VWCS + Local7 * PGSZ)
                            }
                            Increment (Local7)
                        }
                    }
                }
                Increment (Local4)
            }
            VWBT ((Local1 - VWBS) / VWCS, Local0 / VWCS, Zero)
        }
        XSTQ (Arg0 + VNDA, Local3)
        XSTQ (Arg0 + VNCP, Local2)
        VLTO (Arg0)
        Return (One)
    }

    // Map page Arg1 of Arg0 if it is absent. Arg2 is the cached inode
    // (from EXIR) to read through, or zero to leave the page zeroed.
    // Returns zero or a negative errno.
    Method (VPOP, 3, NotSerialized)
    {
        Local0 = XLDQ (Arg0 + VNDA) + Arg1 * PGSZ
        Local1 = VCPE (Local0, One)
        If (!Local1) { Return (Zero - 12) }
        Local2 = XLDQ (Local1)
        If (!(Local2 & PRES))
        {
            Local3 = PALC ()
            If (!Local3) { Return (Zero - 12) }
            XCLR (HHDO + Local3)
            Local2 = Local3 | PRES | WRIT | USER | VOWN
            XSTQ (Local1, Local2)
        }
        Local1 = HHDO + (Local2 & PMSK) + ((Local0 >> 12) & 0x1FF) * 8
        If (XLDQ (Local1) & PRES) { Return (Zero) }
        VCRC ()
        Local3 = PALC ()
        If (!Local3) { Return (Zero - 12) }
        Local4 = HHDO + Local3
        XCLR (Local4)
        Local5 = XLDQ (Arg0 + VNVL)
        If (Arg2 && Arg1 * PGSZ < Local5)
        {
            Local6 = EXMP (Arg2, Arg1)
            If (!Local6 || (Local6 != Ones && !EXRD (Local6, Local4)))
            {
                PDEL (Local3)
                Return (Zero - 5)
            }
            Local5 -= Arg1 * PGSZ
            If (Local5 < PGSZ) { FTZC (Local4 + Local5, PGSZ - Local5) }
        }
        Local2 = Local3 | PRES | WRIT | VOWN
        If (XNXE ()) { Local2 |= NOEX }
        XSTQ (Local1, Local2)
        XINV (Local0)
        Increment (VCPC)
        Return (Zero)
    }

    // Make bytes [Arg1, Arg1 + Arg2) of Arg0 resident. Arg3 skips the read
    // for pages the range covers whole, which the caller will overwrite.
    // Returns zero or a negative errno.
    Method (VENS, 4, NotSerialized)
    {
        If (!XLDQ (Arg0 + VNIN) || !Arg2) { Return (Zero) }
        Local0 = Arg1 + Arg2
        If (!VCGR (Arg0, Local0)) { Return (Zero - 12) }
        VLTO (Arg0)
        Local1 = Arg1 / PGSZ
        Local2 = (Local0 + PGSZ - One) / PGSZ
        VEPN = Arg0
        VEPL = Local1
        VEPH = Local2
        Local3 = Zero // Cached inode, fetched on the first read
        Local4 = XLDQ (Arg0 + VNVL)
        Local5 = EXVL
        EXVL = XLDQ (Arg0 + VNFS)
        Local6 = Zero
        While (Local1 < Local2)
        {
            Local7 = XLDQ (Arg0 + VNDA) + Local1 * PGSZ
            Local7 = VCPT (Local7)
            If (Local7) { Local7 = XLDQ (Local7) & PRES }
            If (Local7) { XINV (XLDQ (Arg0 + VNDA) + Local1 * PGSZ) }
            Else
            {
                Local7 = Zero
                If (Local1 * PGSZ < Local4)
                {
                    Local7 = One
                    If (Arg3 && Local1 * PGSZ >= Arg1)
                    {
                        If ((Local1 + One) * PGSZ <= Local0) { Local7 = Zero }
                    }
                }
                If (Local7 && !Local3)
                {
                    Local3 = EXIR (XLDQ (Arg0 + VNIN))
                    If (!Local3)
                    {
                        Local6 = Zero - 5
                        Break
                    }
                }
                If (!Local7) { Local6 = VPOP (Arg0, Local1, Zero) }
                Else { Local6 = VPOP (Arg0, Local1, Local3) }
                If (Local6) { Break }
            }
            Increment (Local1)
        }
        EXVL = Local5
        VEPN = Zero
        Return (Local6)
    }

    // Zero the cache from byte Arg1 on, for truncation from Arg2 bytes.
    // Whole pages past Arg1 are unmapped; the disk copy of them stops
    // counting, so they read back as zeros.
    Method (VCZR, 3, NotSerialized)
    {
        If (Arg1 % PGSZ)
        {
            Local0 = VENS (Arg0, Arg1, One, Zero)
            If (Local0) { Return (Local0) }
            Local1 = VCPA (Arg0, Arg1 / PGSZ)
            FTZC (Local1 + Arg1 % PGSZ, PGSZ - Arg1 % PGSZ)
        }
        Local2 = (Arg1 + PGSZ - One) / PGSZ
        Local3 = (Arg2 + PGSZ - One) / PGSZ
        Local4 = XLDQ (Arg0 + VNDA)
        If (Local4)
        {
            While (Local2 < Local3)
            {
                Local5 = Local4 + Local2 * PGSZ
                Local6 = VCPT (Local5)
                If (Local6)
                {
                    If (XLDQ (Local6) & PRES) { VCDL (Local5, Local6) }
                }
                Increment (Local2)
            }
        }
        If (Arg1 < XLDQ (Arg0 + VNVL)) { XSTQ (Arg0 + VNVL, Arg1) }
        Return (Zero)
    }

    // An unlinked file keeps its data only in the cache, so load it all
    // before the inode is freed.
    Method (VCMZ, 1, NotSerialized)
    {
        If (!XLDQ (Arg0 + VNIN) || !XLDQ (Arg0 + VNRF)) { Return (Zero) }
        Return (VENS (Arg0, Zero, XLDQ (Arg0 + VNSZ), Zero))
    }
