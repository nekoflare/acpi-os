    // Transitional PCI virtio-net: queue 0 receives, queue 1 transmits.
    // Only VIRTIO_NET_F_MAC is negotiated, so every buffer starts with the
    // 10-byte virtio_net_hdr and checksums are computed in software.
    Name (NBAR, Zero) // I/O BAR0 base; zero while no device is ready
    Name (NRXQ, Zero) // RX ring virtual address
    Name (NRXS, Zero) // RX queue size
    Name (NTXQ, Zero) // TX ring virtual address
    Name (NTXS, Zero) // TX queue size
    Name (NMAC, Zero) // Station address, first octet in the low byte
    Name (NIVC, 0x27) // MSI-X vector for RX completions
    Name (NMXA, 0xFFFFFF0000200000) // MSI-X table mapping
    Name (NRBN, 64)   // RX buffers posted, one page each
    Name (NTBN, 32)   // TX buffers, one page each, used in ring order
    Name (NRAV, Zero) // Next RX available index (free running, 16 bits)
    Name (NRLU, Zero) // Last RX used index harvested
    Name (NTAV, Zero) // Next TX available index
    Name (NFRM, Zero) // Frames received
    Name (NIPA, 0x0A00020F) // 10.0.2.15
    Name (NGWA, 0x0A000202) // 10.0.2.2

    Method (NVIO, 3, NotSerialized)
    {
        Return (XPIO (NBAR + Arg0, Arg1, Arg2))
    }

    Method (PHXB, 1, NotSerialized)
    {
        PUTC (DerefOf (Index (HEXD, (Arg0 >> 4) & 0xF)))
        PUTC (DerefOf (Index (HEXD, Arg0 & 0xF)))
    }

    Method (NVIN, 0, NotSerialized)
    {
        Local0 = PCFD (0x10001AF4)
        If (!Local0) { Return (Zero) }
        Local1 = VIOB (Local0)
        If (!Local1) { Return (NVFL ("no I/O BAR")) }
        NBAR = Local1
        NVIO (18, One, Zero) // reset
        NVIO (18, One, 3)    // ACKNOWLEDGE | DRIVER
        Local2 = NVIO (Zero, 4, Ones)
        If (!(Local2 & 0x20)) { Return (NVFL ("no MAC feature")) }
        NVIO (4, 4, 0x20)    // VIRTIO_NET_F_MAC
        // RX completions raise MSI-X entry 0; TX buffers are reclaimed on
        // demand and configuration changes are ignored, so neither has a
        // vector. With MSI-X on, the legacy header grows to 24 bytes.
        If (!PMSX (Local0, NIVC, NMXA)) { Return (NVFL ("MSI-X unavailable")) }
        NVIO (20, 2, 0xFFFF)
        NRXQ = VQST (NBAR, Zero)
        NRXS = VQSZ
        If (!NRXQ) { Return (NVFL ("RX queue setup failed")) }
        NVIO (22, 2, Zero)
        If (NVIO (22, 2, Ones)) { Return (NVFL ("RX vector rejected")) }
        NTXQ = VQST (NBAR, One)
        NTXS = VQSZ
        If (!NTXQ) { Return (NVFL ("TX queue setup failed")) }
        NVIO (22, 2, 0xFFFF)
        NMAC = Zero
        Local3 = Zero
        While (Local3 < 6)
        {
            NMAC |= NVIO (24 + Local3, One, Ones) << (Local3 * 8)
            Increment (Local3)
        }
        If (!NBUF ()) { Return (NVFL ("buffer allocation failed")) }
        NVIO (18, One, 7)    // DRIVER_OK
        NVIO (16, 2, Zero)   // RX buffers are available
        PUTT ("virtio-net MAC=")
        PMAC (NMAC)
        PNUM (" rxq=0x", NRXS)
        PNUM (" txq=0x", NTXS)
        PNUM (" MSI-X vector=0x", NIVC)
        PUTS ("")
        If (!NARI ()) { Return (NVFL ("ARP cache allocation failed")) }
        NTST ()
        Return (One)
    }

    // Report a probe failure and leave the device reset.
    Method (NVFL, 1, NotSerialized)
    {
        PUTT ("virtio-net: ")
        PUTS (Arg0)
        If (NBAR) { NVIO (18, One, 0x80) } // FAILED
        NBAR = Zero
        Return (Zero)
    }

    // Point descriptor i of the ring at Arg0 at a fresh page with device
    // flags Arg2, for i below Arg1.
    Method (NDSC, 3, NotSerialized)
    {
        Local0 = Zero
        While (Local0 < Arg1)
        {
            Local1 = PALC ()
            If (!Local1) { Return (Zero) }
            XCLR (Local1 + HHDO)
            XSTQ (Arg0 + Local0 * 16, Local1)
            XSTQ (Arg0 + Local0 * 16 + 8, (Arg2 << 32) | PGSZ)
            Increment (Local0)
        }
        Return (One)
    }

    // Publish 16-bit ring index Arg1 at Arg0 + 2 with one aligned store, so
    // the device never sees a torn value.
    Method (NIDX, 2, NotSerialized)
    {
        XSTQ (Arg0, (XLDQ (Arg0) & ~0xFFFF0000) | ((Arg1 & 0xFFFF) << 16))
    }

    Method (NBUF, 0, NotSerialized)
    {
        If (NRBN > NRXS) { NRBN = NRXS }
        If (NTBN > NTXS) { NTBN = NTXS }
        If (!NDSC (NRXQ, NRBN, 2) || !NDSC (NTXQ, NTBN, Zero)) { Return (Zero) }
        // Every RX buffer starts out available; descriptor i is buffer i.
        Local0 = NRXQ + NRXS * 16
        NRAV = Zero
        While (NRAV < NRBN)
        {
            XSTB (Local0 + 4 + NRAV * 2, NRAV)
            XSTB (Local0 + 5 + NRAV * 2, NRAV >> 8)
            Increment (NRAV)
        }
        NIDX (Local0, NRAV)
        NRLU = Zero
        NTAV = Zero
        Return (One)
    }

    // Harvest received frames, pass each to NRXF and repost its buffer.
    Method (NRXP, 0, NotSerialized)
    {
        If (!NBAR) { Return (Zero) }
        Local0 = NRXQ + VQUO (NRXS)
        Local1 = (XLDQ (Local0) >> 16) & 0xFFFF
        If (Local1 == NRLU) { Return (Zero) }
        Local2 = NRXQ + NRXS * 16
        Local5 = Zero
        While (Local1 != NRLU)
        {
            Local3 = XLDQ (Local0 + 4 + (NRLU % NRXS) * 8)
            Local4 = Local3 & 0xFFFFFFFF
            Local3 >>= 32
            If (Local4 < NRBN && Local3 > 24 && Local3 <= PGSZ)
            {
                Increment (NFRM)
                NRXB += Local3 - 10
                NETH (XLDQ (NRXQ + Local4 * 16) + HHDO + 10, Local3 - 10)
            }
            Local6 = Local2 + 4 + (NRAV % NRXS) * 2
            XSTB (Local6, Local4)
            XSTB (Local6 + One, Local4 >> 8)
            NRAV = (NRAV + One) & 0xFFFF
            NRLU = (NRLU + One) & 0xFFFF
            Increment (Local5)
        }
        NIDX (Local2, NRAV)
        NVIO (16, 2, Zero)
        If (TPFP) { TPFL () }
        Return (Local5)
    }

    // Return the frame area of the next TX buffer, or zero if every buffer
    // is still owned by the device. Fill it, then call NTXP with its length.
    Method (NTXA, 0, NotSerialized)
    {
        If (!NBAR) { Return (Zero) }
        Local0 = NTXQ + VQUO (NTXS)
        Local1 = 100000
        // QEMU completes transmissions in order, so the oldest buffer is
        // free once the used index has caught up to within NTBN.
        While (((NTAV - (XLDQ (Local0) >> 16)) & 0xFFFF) >= NTBN)
        {
            Decrement (Local1)
            If (!Local1) { Return (Zero) }
        }
        Local2 = XLDQ (NTXQ + (NTAV % NTBN) * 16) + HHDO
        XSTQ (Local2, Zero)
        XSTB (Local2 + 8, Zero)
        XSTB (Local2 + 9, Zero)
        Return (Local2 + 10)
    }

    Method (NTXP, 1, NotSerialized)
    {
        Local0 = NTAV % NTBN
        XSTQ (NTXQ + Local0 * 16 + 8, Arg0 + 10)
        Local1 = NTXQ + NTXS * 16
        Local2 = Local1 + 4 + (NTAV % NTXS) * 2
        XSTB (Local2, Local0)
        XSTB (Local2 + One, Local0 >> 8)
        NTAV = (NTAV + One) & 0xFFFF
        Increment (NTXF)
        NTXB += Arg0
        NIDX (Local1, NTAV)
        NVIO (16, 2, One)
    }

    // Big-endian and station-address stores for building headers.
    Method (NB16, 2, NotSerialized)
    {
        XSTB (Arg0, Arg1 >> 8)
        XSTB (Arg0 + One, Arg1)
    }

    Method (NB32, 2, NotSerialized)
    {
        NB16 (Arg0, Arg1 >> 16)
        NB16 (Arg0 + 2, Arg1)
    }

    Method (NSMC, 2, NotSerialized)
    {
        Local0 = Zero
        While (Local0 < 6)
        {
            XSTB (Arg0 + Local0, Arg1 >> (Local0 * 8))
            Increment (Local0)
        }
    }

    // Big-endian loads and a station-address load (first octet low).
    Method (NL16, 1, NotSerialized)
    {
        Return ((XBYT (Arg0) << 8) | XBYT (Arg0 + One))
    }

    Method (NL32, 1, NotSerialized)
    {
        Return ((NL16 (Arg0) << 16) | NL16 (Arg0 + 2))
    }

    Method (NLMC, 1, NotSerialized)
    {
        Return (XLDQ (Arg0) & 0xFFFFFFFFFFFF)
    }

    // Print a station address.
    Method (PMAC, 1, NotSerialized)
    {
        Local0 = Zero
        While (Local0 < 6)
        {
            If (Local0) { PUTC (0x3A) }
            PHXB (Arg0 >> (Local0 * 8))
            Increment (Local0)
        }
    }

    // Earliest network timer deadline (MNOW), zero when nothing is armed.
    // The BSP tick only compares it; frames arrive through NIVC.
    Name (NATT, Zero)
    Method (NTIM, 1, NotSerialized)
    {
        If (!NATT || Arg0 < NATT) { NATT = Arg0 }
    }

    Method (NTIK, 0, NotSerialized)
    {
        If (!NATT) { Return () }
        Local0 = MNOW ()
        If (Local0 < NATT) { Return () }
        NATT = Zero
        NATK (Local0)
        NRQX (Local0)
        TPTK (Local0)
    }

