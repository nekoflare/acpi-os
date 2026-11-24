    // TCP (NETPLAN phase T). A TCP socket is an AF_INET open description
    // (net-sock.asl) whose page also holds the TCB from TBST on. Every
    // socket that is neither CLOSED nor LISTEN is on the TPHD list, which the
    // network timer walks. Sequence numbers are 32-bit and compared modulo
    // 2^32 (TPLT). Data waits in two rings of TPRZ bytes per connection:
    // the send ring holds everything from SND.UNA on (sent or not), the
    // receive ring what the application has not read yet.
    //
    // A socket the application has closed becomes an orphan (TBFL bit 3)
    // and lives until the connection is closed; then it, like an unaccepted
    // child that was reset, goes on the TPZH list and is freed on the next
    // timer tick, when no TCP code can still be using it.
    Name (TPHD, Zero)       // TCBs that need timers
    Name (TPZH, Zero)       // Sockets to free on the next tick
    Name (TPLC, Zero)       // Socket the last segment matched
    Name (TPFP, Zero)       // Some TCB wants an ACK at the end of this batch
    Name (TPRZ, 0x40000)    // Ring size, a power of two
    Name (TPRK, 0x3FFFF)
    Name (TPWX, 7)          // Window scale we offer (RFC 7323), as Linux does
    Name (TPTW, 5000000000) // TIME_WAIT, shortened from Linux's 60 s
    Name (TPF2, 60000000000) // FIN_WAIT_2 of an orphan (tcp_fin_timeout)
    Name (TPDL, 40000000)   // Delayed ACK
    Name (TPRB, Buffer (8) {})
    // /proc/net/snmp counters
    Name (TQAO, Zero) // ActiveOpens
    Name (TQPO, Zero) // PassiveOpens
    Name (TQAF, Zero) // AttemptFails
    Name (TQER, Zero) // EstabResets
    Name (TQIS, Zero) // InSegs
    Name (TQOS, Zero) // OutSegs
    Name (TQRT, Zero) // RetransSegs
    Name (TQIE, Zero) // InErrs
    Name (TQOR, Zero) // OutRsts
    // The segment being processed, parsed by TPIN.
    Name (TRSA, Zero) // source address
    Name (TRDS, Zero) // destination address
    Name (TRSP, Zero) // source port
    Name (TRDP, Zero) // destination port
    Name (TRSQ, Zero) // sequence number
    Name (TRAK, Zero) // acknowledgment number
    Name (TRFL, Zero) // flags: FIN 1, SYN 2, RST 4, PSH 8, ACK 16
    Name (TRWN, Zero) // window field
    Name (TRDA, Zero) // data
    Name (TRDL, Zero) // data length
    Name (TROM, Zero) // MSS option, zero if absent
    Name (TROW, Zero) // window scale option, Ones if absent
    // Bytes a blocked stream send or MSG_WAITALL receive has already moved,
    // kept in the task record across retries (SKWK).
    Name (TSNP, 840)
    // TCB fields in the socket page.
    Name (TBST, 232) // 0 CLOSED, 1 LISTEN, 2 SYN_SENT, 3 SYN_RCVD, 4 ESTABLISHED,
                     // 5 FIN_WAIT_1, 6 FIN_WAIT_2, 7 CLOSE_WAIT, 8 CLOSING,
                     // 9 LAST_ACK, 10 TIME_WAIT
    Name (TBSU, 240) // SND.UNA
    Name (TBSN, 248) // SND.NXT
    Name (TBSX, 256) // Highest SND.NXT so far
    Name (TBSW, 264) // SND.WND in bytes
    Name (TBW1, 272) // SND.WL1
    Name (TBW2, 280) // SND.WL2
    Name (TBIS, 288) // ISS
    Name (TBRN, 296) // RCV.NXT
    Name (TBRE, 304) // Right edge of the window last advertised
    Name (TBMS, 312) // Send MSS
    Name (TBSB, 320) // Send ring
    Name (TBSO, 328) // Its offset of the byte at SND.UNA
    Name (TBSL, 336) // Bytes in it
    Name (TBRB, 344) // Receive ring
    Name (TBRO, 352) // Its offset of the next byte to read
    Name (TBRL, 360) // Bytes in it
    Name (TBFL, 368) // 1 FIN queued, 2 FIN sent, 4 FIN acked, 8 orphan,
                     // 16 output running, 32 output again, 64 ACK at batch end,
                     // 128 connected (reported to the application),
                     // 256 persist timer, 512 window scaling, 1024 send even a
                     // small segment (persist), 4096 fast recovery,
                     // 8192 on TPHD, 16384 to be freed
    Name (TBRT, 376) // RTO in ns
    Name (TBSR, 384) // SRTT in ns, zero before the first sample
    Name (TBRV, 392) // RTTVAR
    Name (TBTS, 400) // Sequence number being timed
    Name (TBTT, 408) // MNOW when it was sent, zero if none
    Name (TBRD, 416) // Retransmission or persist deadline
    Name (TBRC, 424) // Consecutive timeouts (or persist probes)
    Name (TBAD, 432) // Delayed ACK deadline
    Name (TBAB, 440) // Bytes received and not acknowledged yet
    Name (TBKD, 448) // Keepalive, FIN_WAIT_2 or TIME_WAIT deadline
    Name (TBCW, 456) // cwnd
    Name (TBTH, 464) // ssthresh
    Name (TBDA, 472) // Duplicate ACKs in a row
    Name (TBRF, 480) // Recovery point of fast recovery
    Name (TBLN, 488) // TPHD link
    Name (TBPA, 496) // Listener of a child not accepted yet
    Name (TBAH, 504) // Listener: accept queue
    Name (TBAT, 512)
    Name (TBAN, 520) // Listener: children not accepted yet
    Name (TBBL, 528) // Listener: backlog
    Name (TBAL, 536) // Child: accept queue link
    Name (TBSS, 544) // Peer's window scale
    Name (TBWS, 552) // Our window scale
    Name (TBFS, 560) // Sequence number of our FIN
    Name (TBKP, 568) // Keepalive probes without an answer
    Name (TBDN, 576) // Debug (TCP_DBGDROP): drop every Nth outgoing segment, and
                     // every Mth incoming one for M in the bits from 16 on
    Name (TBDC, 584) // Debug drop counter
    Name (TBSC, 592) // TCP_SYNCNT, zero for 6
    Name (TBUT, 600) // TCP_USER_TIMEOUT in ms, zero for none
    Name (TBRS, 608) // MNOW of the first retransmission of SND.UNA
    Name (TBSE, 616) // Soft error from ICMP or ARP, reported on timeout
    Name (TBMW, 624) // Largest window the peer offered
    Name (TBRM, 632) // MSS we receive with, for ACK decisions
    Name (TBZN, 640) // TPZH link
    Name (TBDS, 648) // Debug drops done
    Name (TBDI, 656) // Debug incoming drop counter
    Name (TBPC, 664) // Persist probes sent
    Name (TBOQ, 672) // Out-of-order ranges held in the receive ring
    Name (TBOR, 680) // TPON ranges of 16 bytes: start and end sequence numbers
    Name (TPON, 8)

    // Sequence number Arg0 before Arg1, and their distance.
    Method (TPLT, 2, NotSerialized)
    {
        Return (((Arg0 - Arg1) & 0xFFFFFFFF) >= 0x80000000)
    }

    Method (TPSD, 2, NotSerialized)
    {
        Return ((Arg0 - Arg1) & 0xFFFFFFFF)
    }

    // 32 random bits for an initial sequence number.
    Method (TPRN, 0, NotSerialized)
    {
        Local0 = Zero
        // AML && does not short-circuit: test for RDRAND first.
        If (XCPD (One, 2) & 0x40000000) { Local0 = XRNG (XADR (TPRB)) }
        If (Local0) { Return (XLDQ (XADR (TPRB)) & 0xFFFFFFFF) }
        Return (((XTSC () * 0x9E3779B97F4A7C15) >> 32) & 0xFFFFFFFF)
    }

    // MSS of the route to Arg0: lo's MTU of 65536 or eth0's 1500, less the
    // IPv4 and TCP headers.
    Method (TPMR, 1, NotSerialized)
    {
        If (NLOC (Arg0)) { Return (65495) }
        Return (1460)
    }

    // MSS socket Arg0 offers: the route's, or TCP_MAXSEG if smaller.
    Method (TPMA, 1, NotSerialized)
    {
        Local0 = TPMR (XLDQ (Arg0 + INRA))
        Local1 = XLDQ (Arg0 + INMS)
        If (Local1 && Local1 < Local0) { Local0 = Local1 }
        Return (Local0)
    }

    Method (TPFS, 2, NotSerialized) // set TBFL bits
    {
        XSTQ (Arg0 + TBFL, XLDQ (Arg0 + TBFL) | Arg1)
    }

    Method (TPFC, 2, NotSerialized) // clear TBFL bits
    {
        XSTQ (Arg0 + TBFL, XLDQ (Arg0 + TBFL) & ~Arg1)
    }

    // Allocate the rings of socket Arg0. Zero if out of memory.
    Method (TPAL, 1, NotSerialized)
    {
        If (!XLDQ (Arg0 + TBSB))
        {
            Local0 = VALL (TPRZ, WRIT)
            If (!Local0) { Return (Zero) }
            XSTQ (Arg0 + TBSB, Local0)
        }
        If (!XLDQ (Arg0 + TBRB))
        {
            Local0 = VALL (TPRZ, WRIT)
            If (!Local0) { Return (Zero) }
            XSTQ (Arg0 + TBRB, Local0)
        }
        Return (One)
    }

    // Reset the connection state of Arg0 for a new connection with initial
    // sequence number Arg1.
    Method (TPNW, 2, NotSerialized)
    {
        XSTQ (Arg0 + TBIS, Arg1)
        XSTQ (Arg0 + TBSU, Arg1)
        Local0 = (Arg1 + One) & 0xFFFFFFFF
        XSTQ (Arg0 + TBSN, Local0)
        XSTQ (Arg0 + TBSX, Local0)
        XSTQ (Arg0 + TBSW, Zero)
        XSTQ (Arg0 + TBSO, Zero)
        XSTQ (Arg0 + TBSL, Zero)
        XSTQ (Arg0 + TBRO, Zero)
        XSTQ (Arg0 + TBRL, Zero)
        XSTQ (Arg0 + TBOQ, Zero)
        XSTQ (Arg0 + TBFL, XLDQ (Arg0 + TBFL) & 8192)
        XSTQ (Arg0 + TBRT, 1000000000) // RFC 6298 initial RTO
        XSTQ (Arg0 + TBSR, Zero)
        XSTQ (Arg0 + TBRV, Zero)
        XSTQ (Arg0 + TBTS, Arg1)
        XSTQ (Arg0 + TBTT, MNOW ())
        XSTQ (Arg0 + TBRD, Zero)
        XSTQ (Arg0 + TBRC, Zero)
        XSTQ (Arg0 + TBAD, Zero)
        XSTQ (Arg0 + TBAB, Zero)
        XSTQ (Arg0 + TBKD, Zero)
        XSTQ (Arg0 + TBDA, Zero)
        XSTQ (Arg0 + TBKP, Zero)
        XSTQ (Arg0 + TBRS, Zero)
        XSTQ (Arg0 + TBSE, Zero)
        XSTQ (Arg0 + TBSS, Zero)
        XSTQ (Arg0 + TBWS, TPWX)
        XSTQ (Arg0 + TBMS, TPMA (Arg0))
        XSTQ (Arg0 + TBRM, TPMR (XLDQ (Arg0 + INRA)))
        XSTQ (Arg0 + TBTH, 0x7FFFFFFF)
        XSTQ (Arg0 + TBCW, XLDQ (Arg0 + TBMS) * 10)
        XSTQ (Arg0 + INSH, Zero)
        XSTQ (Arg0 + INER, Zero)
    }

    // Put Arg0 on the timer list.
    Method (TPLN, 1, NotSerialized)
    {
        If (XLDQ (Arg0 + TBFL) & 8192) { Return () }
        TPFS (Arg0, 8192)
        XSTQ (Arg0 + TBLN, TPHD)
        TPHD = Arg0
    }

    Method (TPUL, 1, NotSerialized)
    {
        If (!(XLDQ (Arg0 + TBFL) & 8192)) { Return () }
        TPFC (Arg0, 8192)
        Local0 = Zero
        Local1 = TPHD
        While (Local1 && Local1 != Arg0)
        {
            Local0 = Local1
            Local1 = XLDQ (Local1 + TBLN)
        }
        If (!Local1) { Return () }
        Local2 = XLDQ (Arg0 + TBLN)
        If (Local0) { XSTQ (Local0 + TBLN, Local2) }
        Else { TPHD = Local2 }
    }

    // Free socket Arg0 on the next tick: it is off every list by then.
    Method (TPZQ, 1, NotSerialized)
    {
        If (XLDQ (Arg0 + TBFL) & 16384) { Return () }
        TPUL (Arg0)
        INUB (Arg0)
        If (TPLC == Arg0) { TPLC = Zero }
        TPFS (Arg0, 16384)
        XSTQ (Arg0 + TBZN, TPZH)
        TPZH = Arg0
        NTIM (MNOW () + One)
    }

    Method (TPRA, 0, NotSerialized)
    {
        While (TPZH)
        {
            Local0 = TPZH
            TPZH = XLDQ (Local0 + TBZN)
            TPFR (Local0)
        }
    }

    // Release the rings and page of socket Arg0.
    Method (TPFR, 1, NotSerialized)
    {
        If (XLDQ (Arg0 + TBSB)) { VUNM (XLDQ (Arg0 + TBSB), TPRZ) }
        If (XLDQ (Arg0 + TBRB)) { VUNM (XLDQ (Arg0 + TBRB), TPRZ) }
        PDEL (Arg0 - HHDO)
    }

    // Copy Arg3 bytes from ring Arg0 at offset Arg1 to Arg2, or with Arg4
    // set from Arg2 into the ring.
    Method (TPRG, 5, NotSerialized)
    {
        Local0 = TPRZ - Arg1
        If (Local0 > Arg3) { Local0 = Arg3 }
        If (Arg4)
        {
            XMOV (Arg0 + Arg1, Arg2, Local0)
            If (Arg3 > Local0) { XMOV (Arg0, Arg2 + Local0, Arg3 - Local0) }
        }
        Else
        {
            XMOV (Arg2, Arg0 + Arg1, Local0)
            If (Arg3 > Local0) { XMOV (Arg2 + Local0, Arg0, Arg3 - Local0) }
        }
    }

    // Move Arg5 bytes between ring Arg1 at offset Arg2 and the Arg3 user
    // iovecs in INIV, skipping their first Arg4 bytes: into the ring, or
    // with Arg6 set out of it. Returns the bytes moved, or Ones on a fault.
    Method (TPIV, 7, NotSerialized)
    {
        Local0 = XADR (INIV)
        Local7 = Zero
        While (Arg3 && Local7 < Arg5)
        {
            Local1 = XLDQ (Local0 + 8)
            Local2 = XLDQ (Local0)
            Local0 += 16
            Decrement (Arg3)
            If (Arg4 >= Local1)
            {
                Arg4 -= Local1
                Continue
            }
            Local2 += Arg4
            Local1 -= Arg4
            Arg4 = Zero
            If (Local1 > Arg5 - Local7) { Local1 = Arg5 - Local7 }
            While (Local1)
            {
                Local3 = TPRZ - Arg2
                If (Local3 > Local1) { Local3 = Local1 }
                If (Arg6)
                {
                    If (!UCOP (Arg0, Local2, Arg1 + Arg2, Local3)) { Return (Ones) }
                }
                ElseIf (!UCPY (Arg0, Arg1 + Arg2, Local2, Local3)) { Return (Ones) }
                Arg2 = (Arg2 + Local3) & TPRK
                Local2 += Local3
                Local1 -= Local3
                Local7 += Local3
            }
        }
        Return (Local7)
    }

    // Window to advertise on socket Arg0, as the 16-bit field (scaled), and
    // record its right edge. Like RFC 1122's receiver SWS avoidance, the edge
    // only moves by at least an MSS or half the ring, and never back.
    Method (TPWN, 1, NotSerialized)
    {
        Local1 = XLDQ (Arg0 + TBWS)
        Local0 = TPRZ - XLDQ (Arg0 + TBRL)
        Local2 = 0xFFFF << Local1
        If (Local0 > Local2) { Local0 = Local2 }
        Local0 &= ~((One << Local1) - One)
        Local3 = XLDQ (Arg0 + TBRN)
        Local4 = TPSD (XLDQ (Arg0 + TBRE), Local3)
        If (Local4 >= 0x80000000) { Local4 = Zero }
        Local5 = XLDQ (Arg0 + TBRM)
        If (Local5 > TPRZ / 2) { Local5 = TPRZ / 2 }
        If (Local0 > Local4)
        {
            If (Local0 - Local4 >= Local5) { Local4 = Local0 }
        }
        XSTQ (Arg0 + TBRE, (Local3 + Local4) & 0xFFFFFFFF)
        Return (Local4 >> Local1)
    }

    // Send a segment on socket Arg0 with sequence number Arg1, carrying
    // Arg3 bytes from send ring offset Arg2, with flags Arg4. A SYN carries
    // the MSS option and, when offered, window scaling. Zero if no buffer.
    Method (TPSG, 5, NotSerialized)
    {
        Local7 = XLDQ (Arg0 + INRA)
        Local6 = 20
        Local5 = Zero
        If (Arg4 & 2)
        {
            Local6 = 24
            If (XLDQ (Arg0 + TBWS) || (XLDQ (Arg0 + TBFL) & 512))
            {
                Local6 = 28
                Local5 = One
            }
        }
        Local0 = NOBF (Local7, Local6 + Arg3)
        If (!Local0) { Return (Zero) }
        Local1 = Local0 + 34
        NB16 (Local1, XLDQ (Arg0 + INLP))
        NB16 (Local1 + 2, XLDQ (Arg0 + INRP))
        NB32 (Local1 + 4, Arg1)
        Local2 = Zero
        If (Arg4 & 0x10) { Local2 = XLDQ (Arg0 + TBRN) }
        NB32 (Local1 + 8, Local2)
        NB16 (Local1 + 12, ((Local6 / 4) << 12) | Arg4)
        If (Arg4 & 2)
        {
            // The window in a SYN is never scaled.
            Local2 = TPRZ - XLDQ (Arg0 + TBRL)
            If (Local2 > 0xFFFF) { Local2 = 0xFFFF }
            XSTQ (Arg0 + TBRE, (XLDQ (Arg0 + TBRN) + Local2) & 0xFFFFFFFF)
        }
        Else { Local2 = TPWN (Arg0) }
        NB16 (Local1 + 14, Local2)
        NB32 (Local1 + 16, Zero)
        If (Arg4 & 2)
        {
            NB32 (Local1 + 20, 0x02040000 | TPMA (Arg0))
            If (Local5) { NB32 (Local1 + 24, 0x01030300 | XLDQ (Arg0 + TBWS)) }
        }
        If (Arg3)
        {
            TPRG (XLDQ (Arg0 + TBSB), (XLDQ (Arg0 + TBSO) + Arg2) & TPRK, Local1 + Local6, Arg3, Zero)
        }
        Local2 = Local6 + Arg3
        Local3 = XLDQ (Arg0 + INLA)
        NB16 (Local1 + 16, NCSM (Local1, Local2, NPSH (Local3, Local7, 6, Local2)))
        If (Arg4 & 0x10)
        {
            XSTQ (Arg0 + TBAD, Zero)
            XSTQ (Arg0 + TBAB, Zero)
            TPFC (Arg0, 64)
        }
        Increment (TQOS)
        If (Arg4 & 4) { Increment (TQOR) }
        Local4 = XLDQ (Arg0 + TBDN) & 0xFFFF
        If (Local4)
        {
            Local5 = XLDQ (Arg0 + TBDC) + One
            If (Local5 >= Local4)
            {
                XSTQ (Arg0 + TBDC, Zero)
                XSTQ (Arg0 + TBDS, XLDQ (Arg0 + TBDS) + One)
                NOAB (Local0, Local7)
                Return (One)
            }
            XSTQ (Arg0 + TBDC, Local5)
        }
        NIPO (Local7, 6, Local0, Local2, Local3)
        Return (One)
    }

    // Send an ACK now.
    Method (TPAN, 1, NotSerialized)
    {
        TPSG (Arg0, XLDQ (Arg0 + TBSN), Zero, Zero, 0x10)
    }

    // ACK at the end of this batch of frames.
    Method (TPQA, 1, NotSerialized)
    {
        TPFS (Arg0, 64)
        TPFP = One
    }

    Method (TPFL, 0, NotSerialized)
    {
        TPFP = Zero
        Local0 = TPHD
        While (Local0)
        {
            Local1 = XLDQ (Local0 + TBLN)
            If (XLDQ (Local0 + TBFL) & 64) { TPAN (Local0) }
            Local0 = Local1
        }
    }

    // Reply to the segment in TR* that matched no connection with a reset,
    // unless it is one (RFC 793).
    Method (TPXR, 0, NotSerialized)
    {
        If (TRFL & 4) { Return () }
        If (TRFL & 0x10)
        {
            Local0 = TRAK
            Local1 = Zero
            Local2 = 4
        }
        Else
        {
            Local0 = Zero
            Local1 = (TRSQ + TRDL + (TRFL & One) + ((TRFL >> 1) & One)) & 0xFFFFFFFF
            Local2 = 0x14
        }
        Local3 = NOBF (TRSA, 20)
        If (!Local3) { Return () }
        Local4 = Local3 + 34
        NB16 (Local4, TRDP)
        NB16 (Local4 + 2, TRSP)
        NB32 (Local4 + 4, Local0)
        NB32 (Local4 + 8, Local1)
        NB16 (Local4 + 12, 0x5000 | Local2)
        NB32 (Local4 + 14, Zero)
        NB16 (Local4 + 18, Zero)
        NB16 (Local4 + 16, NCSM (Local4, 20, NPSH (TRDS, TRSA, 6, 20)))
        Increment (TQOS)
        Increment (TQOR)
        NIPO (TRSA, 6, Local3, 20, TRDS)
    }

    // Arm the retransmission timer while anything is unacknowledged, or the
    // persist timer while data waits for a closed window; stop it otherwise.
    Method (TPAR, 1, NotSerialized)
    {
        Local0 = XLDQ (Arg0 + TBST)
        If (!Local0 || Local0 == One || Local0 == 10) { Return () }
        Local1 = MNOW ()
        If (XLDQ (Arg0 + TBSX) != XLDQ (Arg0 + TBSU))
        {
            If (XLDQ (Arg0 + TBFL) & 256)
            {
                TPFC (Arg0, 256)
                XSTQ (Arg0 + TBRD, Zero)
            }
            If (!XLDQ (Arg0 + TBRD)) { XSTQ (Arg0 + TBRD, Local1 + XLDQ (Arg0 + TBRT)) }
        }
        ElseIf (XLDQ (Arg0 + TBSL))
        {
            If (!(XLDQ (Arg0 + TBFL) & 256))
            {
                TPFS (Arg0, 256)
                XSTQ (Arg0 + TBRC, Zero)
                XSTQ (Arg0 + TBRD, Local1 + XLDQ (Arg0 + TBRT))
            }
        }
        Else
        {
            TPFC (Arg0, 256)
            XSTQ (Arg0 + TBRD, Zero)
        }
        If (XLDQ (Arg0 + TBRD)) { NTIM (XLDQ (Arg0 + TBRD)) }
    }

    // Send whatever the windows allow. Reentry (an ACK delivered on lo while
    // this runs) only asks the running call to look again.
    Method (TPOU, 1, NotSerialized)
    {
        Local0 = XLDQ (Arg0 + TBST)
        If (Local0 != 4 && Local0 != 5 && Local0 != 7 && Local0 != 8 && Local0 != 9) { Return () }
        If (XLDQ (Arg0 + TBFL) & 16)
        {
            TPFS (Arg0, 32)
            Return ()
        }
        TPFS (Arg0, 16)
        Local1 = 1000
        While (Local1)
        {
            TPFC (Arg0, 32)
            If (!TPO1 (Arg0))
            {
                If (!(XLDQ (Arg0 + TBFL) & 32)) { Break }
            }
            Decrement (Local1)
        }
        TPFC (Arg0, 48)
        TPAR (Arg0)
    }

    // Send one segment if anything may go: Nagle's algorithm (unless
    // TCP_NODELAY) and sender SWS avoidance hold back small ones. Returns
    // One if a segment went out.
    Method (TPO1, 1, NotSerialized)
    {
        Local0 = XLDQ (Arg0 + TBSU)
        Local1 = TPSD (XLDQ (Arg0 + TBSN), Local0) // in flight, and offset of SND.NXT's byte
        Local2 = XLDQ (Arg0 + TBSL)
        Local3 = XLDQ (Arg0 + TBFL)
        If (Local1 > Local2) { Return (Zero) } // FIN sent
        Local4 = Local2 - Local1 // unsent
        Local5 = XLDQ (Arg0 + TBSW)
        Local6 = XLDQ (Arg0 + TBCW)
        // Limited transmit (RFC 3042): each of the first two duplicate ACKs
        // lets one more segment out, so a small window still collects the
        // three that start fast retransmit.
        Local7 = XLDQ (Arg0 + TBDA)
        If (!(Local3 & 4096) && Local7 < 3) { Local6 += Local7 * XLDQ (Arg0 + TBMS) }
        If (Local6 < Local5) { Local5 = Local6 }
        If (Local5 > Local1) { Local5 -= Local1 }
        Else { Local5 = Zero }
        If (Local5 > Local4) { Local5 = Local4 }
        Local6 = XLDQ (Arg0 + TBMS)
        If (Local5 > Local6) { Local5 = Local6 }
        Local7 = Zero
        If ((Local3 & One) && Local5 == Local4) { Local7 = One } // FIN goes with the last data
        If (!Local5 && !Local7) { Return (Zero) }
        If (Local5 < Local6 && !Local7 && !(Local3 & 1024))
        {
            If (Local5 < Local4)
            {
                // Window-limited: wait for half the largest window offered,
                // unless nothing is in flight, when no ACK will open it.
                If (Local5 < XLDQ (Arg0 + TBMW) / 2 && Local1) { Return (Zero) }
            }
            ElseIf (Local1 && !(XLDQ (Arg0 + INOB) & 0x200000000)) { Return (Zero) } // Nagle
        }
        Local3 = 0x10
        If (Local5 && Local5 == Local4) { Local3 |= 8 } // PSH
        If (Local7) { Local3 |= One }
        // Advance the send state first: on lo the segment is delivered, and
        // answered, before TPSG returns.
        Local0 = XLDQ (Arg0 + TBSN)
        Local2 = XLDQ (Arg0 + TBSX)
        Local4 = XLDQ (Arg0 + TBFL)
        Local6 = (Local0 + Local5 + Local7) & 0xFFFFFFFF
        If (TPLT (Local0, Local2)) { Increment (TQRT) }
        ElseIf (!XLDQ (Arg0 + TBTT))
        {
            XSTQ (Arg0 + TBTS, Local0)
            XSTQ (Arg0 + TBTT, MNOW ())
        }
        If (Local7)
        {
            TPFS (Arg0, 2)
            XSTQ (Arg0 + TBFS, (Local6 - One) & 0xFFFFFFFF)
        }
        XSTQ (Arg0 + TBSN, Local6)
        If (TPLT (Local2, Local6)) { XSTQ (Arg0 + TBSX, Local6) }
        If (!TPSG (Arg0, Local0, Local1, Local5, Local3))
        {
            // No buffer, so nothing was delivered: undo.
            XSTQ (Arg0 + TBSN, Local0)
            XSTQ (Arg0 + TBSX, Local2)
            XSTQ (Arg0 + TBFL, (XLDQ (Arg0 + TBFL) & ~2) | (Local4 & 2))
            Return (Zero)
        }
        Return (One)
    }

    // Resend the oldest unacknowledged segment (fast retransmit).
    Method (TPR1, 1, NotSerialized)
    {
        Local0 = XLDQ (Arg0 + TBSL)
        If (Local0 > XLDQ (Arg0 + TBMS)) { Local0 = XLDQ (Arg0 + TBMS) }
        Local1 = 0x18
        If (!Local0)
        {
            If (!(XLDQ (Arg0 + TBFL) & 2)) { Return () }
            Local1 = 0x11
        }
        XSTQ (Arg0 + TBTT, Zero)
        If (TPSG (Arg0, XLDQ (Arg0 + TBSU), Zero, Local0, Local1)) { Increment (TQRT) }
    }

    // Take RTT sample Arg1 (ns), RFC 6298 with a 200 ms floor like Linux.
    Method (TPRR, 2, NotSerialized)
    {
        Local0 = XLDQ (Arg0 + TBSR)
        If (!Local0)
        {
            Local0 = Arg1
            Local1 = Arg1 / 2
        }
        Else
        {
            If (Local0 > Arg1) { Local2 = Local0 - Arg1 }
            Else { Local2 = Arg1 - Local0 }
            Local1 = (XLDQ (Arg0 + TBRV) * 3 + Local2) / 4
            Local0 = (Local0 * 7 + Arg1) / 8
        }
        If (!Local0) { Local0 = One }
        XSTQ (Arg0 + TBSR, Local0)
        XSTQ (Arg0 + TBRV, Local1)
        TPRO (Arg0)
    }

    // RTO from SRTT and RTTVAR, which also undoes any backoff.
    Method (TPRO, 1, NotSerialized)
    {
        Local0 = XLDQ (Arg0 + TBSR)
        If (!Local0) { Return () }
        Local2 = XLDQ (Arg0 + TBRV) * 4
        If (Local2 < 10000000) { Local2 = 10000000 } // clock granularity
        Local2 += Local0
        If (Local2 < 200000000) { Local2 = 200000000 }
        If (Local2 > 120000000000) { Local2 = 120000000000 }
        XSTQ (Arg0 + TBRT, Local2)
    }

    // Keepalive deadline after activity on Arg0.
    Method (TPKS, 1, NotSerialized)
    {
        XSTQ (Arg0 + TBKP, Zero)
        If (XLDQ (Arg0 + TBST) != 4 && XLDQ (Arg0 + TBST) != 7) { Return () }
        If (!(XLDQ (Arg0 + INOB) & 0x200)) // SO_KEEPALIVE
        {
            XSTQ (Arg0 + TBKD, Zero)
            Return ()
        }
        Local0 = XLDQ (Arg0 + INKI)
        If (!Local0) { Local0 = 7200 }
        Local0 = MNOW () + Local0 * 1000000000
        XSTQ (Arg0 + TBKD, Local0)
        NTIM (Local0)
    }

    // Enter ESTABLISHED: the peer's window comes from the segment in TR*,
    // scaled by Arg1 bits.
    Method (TPES, 2, NotSerialized)
    {
        XSTQ (Arg0 + TBST, 4)
        Local0 = TRWN << Arg1
        XSTQ (Arg0 + TBSW, Local0)
        XSTQ (Arg0 + TBMW, Local0)
        XSTQ (Arg0 + TBW1, TRSQ)
        XSTQ (Arg0 + TBW2, TRAK)
        If (XLDQ (Arg0 + TBTT) && !XLDQ (Arg0 + TBRC)) { TPRR (Arg0, MNOW () - XLDQ (Arg0 + TBTT)) }
        XSTQ (Arg0 + TBTT, Zero)
        XSTQ (Arg0 + TBRC, Zero)
        XSTQ (Arg0 + TBRD, Zero)
        XSTQ (Arg0 + TBCW, XLDQ (Arg0 + TBMS) * 10)
        TPKS (Arg0)
        SKCH = One
    }

    // Take the peer's initial sequence number and options from the SYN in TR*.
    Method (TPSE, 1, NotSerialized)
    {
        Local0 = (TRSQ + One) & 0xFFFFFFFF
        XSTQ (Arg0 + TBRN, Local0)
        XSTQ (Arg0 + TBRE, Local0)
        Local1 = TROM
        If (!Local1) { Local1 = 536 }
        Local2 = TPMA (Arg0)
        If (Local1 > Local2) { Local1 = Local2 }
        If (Local1 < 64) { Local1 = 64 }
        XSTQ (Arg0 + TBMS, Local1)
        XSTQ (Arg0 + TBCW, Local1 * 10)
        If (TROW != Ones && (XLDQ (Arg0 + TBWS) || (XLDQ (Arg0 + TBFL) & 512)))
        {
            TPFS (Arg0, 512)
            XSTQ (Arg0 + TBSS, TROW)
        }
        Else
        {
            TPFC (Arg0, 512)
            XSTQ (Arg0 + TBSS, Zero)
            XSTQ (Arg0 + TBWS, Zero)
        }
    }

    // Close Arg0 with error Arg1 (zero for none): both directions shut,
    // timers stopped, waiters woken. Orphans and children nobody accepted
    // are freed.
    Method (TPDR, 2, NotSerialized)
    {
        Local0 = XLDQ (Arg0 + TBST)
        If (Local0 == 2 || Local0 == 3) { Increment (TQAF) }
        ElseIf ((Local0 == 4 || Local0 == 7) && Arg1) { Increment (TQER) }
        XSTQ (Arg0 + TBST, Zero)
        If (Arg1) { XSTQ (Arg0 + INER, Arg1) }
        XSTQ (Arg0 + INSH, 3)
        XSTQ (Arg0 + TBRD, Zero)
        XSTQ (Arg0 + TBAD, Zero)
        XSTQ (Arg0 + TBKD, Zero)
        TPFC (Arg0, 64)
        TPUL (Arg0)
        SKCH = One
        Local1 = XLDQ (Arg0 + TBPA)
        If (Local1)
        {
            TPAU (Local1, Arg0)
            TPZQ (Arg0)
            Return ()
        }
        If (XLDQ (Arg0 + TBFL) & 8) { TPZQ (Arg0) }
    }

    // Detach child Arg1 from listener Arg0 and its accept queue.
    Method (TPAU, 2, NotSerialized)
    {
        XSTQ (Arg1 + TBPA, Zero)
        XSTQ (Arg0 + TBAN, XLDQ (Arg0 + TBAN) - One)
        Local0 = Zero
        Local1 = XLDQ (Arg0 + TBAH)
        While (Local1 && Local1 != Arg1)
        {
            Local0 = Local1
            Local1 = XLDQ (Local1 + TBAL)
        }
        If (!Local1) { Return () }
        Local2 = XLDQ (Arg1 + TBAL)
        If (Local0) { XSTQ (Local0 + TBAL, Local2) }
        Else { XSTQ (Arg0 + TBAH, Local2) }
        If (XLDQ (Arg0 + TBAT) == Arg1) { XSTQ (Arg0 + TBAT, Local0) }
        XSTQ (Arg1 + TBAL, Zero)
    }

    Method (TPTI, 1, NotSerialized) // enter TIME_WAIT
    {
        XSTQ (Arg0 + TBST, 10)
        XSTQ (Arg0 + TBRD, Zero)
        TPFC (Arg0, 256)
        Local0 = MNOW () + TPTW
        XSTQ (Arg0 + TBKD, Local0)
        NTIM (Local0)
        SKCH = One
    }

    // The connection of socket Arg0, at address Arg1 port Arg2, with peer Arg3
    // port Arg4; or the listener for that address and port (a specific
    // address before the wildcard). Zero if none.
    Method (TPLK, 5, NotSerialized)
    {
        Local0 = TPLC
        If (Local0)
        {
            If (XLDQ (Local0 + INLP) == Arg2 && XLDQ (Local0 + INRP) == Arg4 &&
                XLDQ (Local0 + INRA) == Arg3 && XLDQ (Local0 + INLA) == Arg1 &&
                XLDQ (Local0 + TBST) > One && XLDQ (Local0 + INPT) == 6)
            {
                Return (Local0)
            }
        }
        Local1 = Zero
        Local0 = INHD
        While (Local0)
        {
            If (XLDQ (Local0 + INPT) == 6 && XLDQ (Local0 + INLP) == Arg2 && Local0 != Arg0)
            {
                Local2 = XLDQ (Local0 + TBST)
                Local3 = XLDQ (Local0 + INLA)
                If (Local2 > One)
                {
                    If (XLDQ (Local0 + INRP) == Arg4 && XLDQ (Local0 + INRA) == Arg3 && Local3 == Arg1)
                    {
                        TPLC = Local0
                        Return (Local0)
                    }
                }
                ElseIf (Local2 == One)
                {
                    If (Local3 == Arg1) { Local1 = Local0 }
                    ElseIf (!Local3 && !Local1) { Local1 = Local0 }
                }
            }
            Local0 = XLDQ (Local0 + INNX)
        }
        Return (Local1)
    }

    // Parse the Arg1 bytes of options at Arg0 into TROM and TROW.
    Method (TPOP, 2, NotSerialized)
    {
        Local0 = Zero
        While (Local0 < Arg1)
        {
            Local1 = XBYT (Arg0 + Local0)
            If (!Local1) { Break }
            If (Local1 == One)
            {
                Increment (Local0)
                Continue
            }
            If (Local0 + One >= Arg1) { Break }
            Local2 = XBYT (Arg0 + Local0 + One)
            If (Local2 < 2 || Local0 + Local2 > Arg1) { Break }
            If (Local1 == 2 && Local2 == 4) { TROM = NL16 (Arg0 + Local0 + 2) }
            ElseIf (Local1 == 3 && Local2 == 3)
            {
                TROW = XBYT (Arg0 + Local0 + 2)
                If (TROW > 14) { TROW = 14 }
            }
            Local0 += Local2
        }
    }

    // TCP in IPv4 header Arg0 (Arg1 bytes, Arg2 in total) from Arg3 to Arg4.
    Method (TPIN, 5, NotSerialized)
    {
        Local0 = Arg0 + Arg1
        Local1 = Arg2 - Arg1
        If (Local1 < 20) { Return () }
        Local2 = (XBYT (Local0 + 12) >> 4) * 4
        If (Local2 < 20 || Local2 > Local1) { Return () }
        If (XCSM (Local0, Local1, NPSH (Arg3, Arg4, 6, Local1)) != 0xFFFF)
        {
            Increment (TQIE)
            Return ()
        }
        If (!NLOC (Arg4)) { Return () }
        Increment (TQIS)
        TRSA = Arg3
        TRDS = Arg4
        TRSP = NL16 (Local0)
        TRDP = NL16 (Local0 + 2)
        TRSQ = NL32 (Local0 + 4)
        TRAK = NL32 (Local0 + 8)
        TRFL = XBYT (Local0 + 13) & 0x3F
        TRWN = NL16 (Local0 + 14)
        TRDA = Local0 + Local2
        TRDL = Local1 - Local2
        TROM = Zero
        TROW = Ones
        If (Local2 > 20) { TPOP (Local0 + 20, Local2 - 20) }
        Local3 = TPLK (Zero, Arg4, TRDP, Arg3, TRSP)
        If (!Local3)
        {
            TPXR ()
            Return ()
        }
        Local4 = XLDQ (Local3 + TBDN) >> 16
        If (Local4)
        {
            Local5 = XLDQ (Local3 + TBDI) + One
            XSTQ (Local3 + TBDI, Local5)
            If (Local5 >= Local4)
            {
                XSTQ (Local3 + TBDI, Zero)
                XSTQ (Local3 + TBDS, XLDQ (Local3 + TBDS) + One)
                Return ()
            }
        }
        Local4 = XLDQ (Local3 + TBST)
        If (Local4 == One) { TPLI (Local3) }
        ElseIf (Local4 == 2) { TPSS (Local3) }
        Else { TPSI (Local3) }
    }

    // A segment for listener Arg0: a SYN makes a child in SYN_RCVD.
    Method (TPLI, 1, NotSerialized)
    {
        If (TRFL & 4) { Return () }
        If (TRFL & 0x10)
        {
            TPXR ()
            Return ()
        }
        If (!(TRFL & 2)) { Return () }
        If (XLDQ (Arg0 + TBAN) > XLDQ (Arg0 + TBBL)) { Return () } // The client retries.
        Local0 = PALC ()
        If (!Local0) { Return () }
        Local0 += HHDO
        XCLR (Local0)
        XSTQ (Local0, XADR (INND))
        XSTQ (Local0 + INTY, One)
        XSTQ (Local0 + INPT, 6)
        // Options are inherited, as on Linux.
        Local1 = INOB
        While (Local1 <= INMS)
        {
            XSTQ (Local0 + Local1, XLDQ (Arg0 + Local1))
            Local1 += 8
        }
        XSTQ (Local0 + INSH, Zero)
        XSTQ (Local0 + TBDN, XLDQ (Arg0 + TBDN))
        XSTQ (Local0 + TBSC, XLDQ (Arg0 + TBSC))
        XSTQ (Local0 + TBUT, XLDQ (Arg0 + TBUT))
        XSTQ (Local0 + INLA, TRDS)
        XSTQ (Local0 + INLP, TRDP)
        XSTQ (Local0 + INRA, TRSA)
        XSTQ (Local0 + INRP, TRSP)
        If (!TPAL (Local0))
        {
            TPFR (Local0)
            Return ()
        }
        XSTQ (Local0 + INNX, INHD)
        INHD = Local0
        XSTQ (Local0 + TBPA, Arg0)
        XSTQ (Arg0 + TBAN, XLDQ (Arg0 + TBAN) + One)
        TPNW (Local0, TPRN ())
        TPSE (Local0)
        XSTQ (Local0 + TBSW, TRWN)
        XSTQ (Local0 + TBST, 3)
        TPLN (Local0)
        TPSG (Local0, XLDQ (Local0 + TBIS), Zero, Zero, 0x12)
        TPAR (Local0)
    }

    // A segment for Arg0 in SYN_SENT.
    Method (TPSS, 1, NotSerialized)
    {
        Local0 = TRFL & 0x10
        If (Local0)
        {
            If (TRAK != XLDQ (Arg0 + TBSX))
            {
                TPXR ()
                Return ()
            }
        }
        If (TRFL & 4)
        {
            If (Local0) { TPDR (Arg0, Zero - 111) } // ECONNREFUSED
            Return ()
        }
        If (!(TRFL & 2)) { Return () }
        TPSE (Arg0)
        If (Local0)
        {
            XSTQ (Arg0 + TBSU, TRAK)
            TPES (Arg0, Zero)
            TPAN (Arg0)
            TPOU (Arg0)
            Return ()
        }
        // Simultaneous open.
        XSTQ (Arg0 + TBST, 3)
        XSTQ (Arg0 + TBTT, Zero)
        TPSG (Arg0, XLDQ (Arg0 + TBIS), Zero, Zero, 0x12)
    }

    // A segment for Arg0 in SYN_RCVD or a synchronized state (RFC 793
    // "SEGMENT ARRIVES", with RFC 5961's challenge ACKs).
    Method (TPSI, 1, NotSerialized)
    {
        Local0 = XLDQ (Arg0 + TBST)
        Local1 = XLDQ (Arg0 + TBRN)
        Local2 = TRDL + (TRFL & One) + ((TRFL >> 1) & One)
        Local3 = TPSD (XLDQ (Arg0 + TBRE), Local1)
        If (Local3 >= 0x80000000) { Local3 = Zero }
        Local4 = TPSD (TRSQ, Local1)
        Local5 = Zero
        If (!Local4) { Local5 = One }
        ElseIf (Local4 < Local3) { Local5 = One }
        ElseIf (Local2 && Local4 >= 0x80000000)
        {
            If (TPLT (Local1, (TRSQ + Local2) & 0xFFFFFFFF)) { Local5 = One }
        }
        If (!Local5)
        {
            If (TRFL & 4) { Return () }
            If (Local0 == 3)
            {
                If (TRFL & 2) { TPSG (Arg0, XLDQ (Arg0 + TBIS), Zero, Zero, 0x12) }
                Return ()
            }
            If (Local0 == 10 && (TRFL & One)) { TPTI (Arg0) }
            TPAN (Arg0)
            Return ()
        }
        If (TRFL & 4)
        {
            If (Local4) { TPAN (Arg0) } // challenge ACK
            ElseIf (Local0 == 3 || Local0 >= 8) { TPDR (Arg0, Zero) }
            Else { TPDR (Arg0, Zero - 104) } // ECONNRESET
            Return ()
        }
        If (TRFL & 2)
        {
            TPAN (Arg0)
            Return ()
        }
        If (!(TRFL & 0x10)) { Return () }
        XSTQ (Arg0 + TBKP, Zero)
        If (Local0 == 3)
        {
            Local6 = XLDQ (Arg0 + TBSU)
            If (!TPLT (Local6, TRAK) || TPLT (XLDQ (Arg0 + TBSX), TRAK))
            {
                TPXR ()
                Return ()
            }
            XSTQ (Arg0 + TBSU, TRAK)
            Local6 = Zero
            If (XLDQ (Arg0 + TBFL) & 512) { Local6 = XLDQ (Arg0 + TBSS) }
            TPES (Arg0, Local6)
            TPAQ (Arg0)
        }
        ElseIf (!TPAK (Arg0)) { Return () }
        Local0 = XLDQ (Arg0 + TBST)
        If (!Local0) { Return () }
        If (TRDL)
        {
            If (Local0 == 4 || Local0 == 5 || Local0 == 6)
            {
                If (XLDQ (Arg0 + TBFL) & 8)
                {
                    // Data for a socket the application closed: reset, as on Linux.
                    TPSG (Arg0, XLDQ (Arg0 + TBSN), Zero, Zero, 0x14)
                    TPDR (Arg0, Zero)
                    Return ()
                }
                TPDT (Arg0)
            }
            Else { TRFL &= ~One }
        }
        If (TRFL & One)
        {
            If (((TRSQ + TRDL) & 0xFFFFFFFF) == XLDQ (Arg0 + TBRN))
            {
                XSTQ (Arg0 + TBRN, (XLDQ (Arg0 + TBRN) + One) & 0xFFFFFFFF)
                XSTQ (Arg0 + INSH, XLDQ (Arg0 + INSH) | One)
                SKCH = One
                If (Local0 == 4) { XSTQ (Arg0 + TBST, 7) }
                ElseIf (Local0 == 5)
                {
                    If (XLDQ (Arg0 + TBFL) & 4) { TPTI (Arg0) }
                    Else { XSTQ (Arg0 + TBST, 8) }
                }
                ElseIf (Local0 == 6) { TPTI (Arg0) }
                TPAN (Arg0)
            }
        }
        TPOU (Arg0)
    }

    // Child Arg0 is established: queue it for accept.
    Method (TPAQ, 1, NotSerialized)
    {
        Increment (TQPO)
        Local0 = XLDQ (Arg0 + TBPA)
        If (!Local0) { Return () }
        Local1 = XLDQ (Local0 + TBAT)
        If (Local1) { XSTQ (Local1 + TBAL, Arg0) }
        Else { XSTQ (Local0 + TBAH, Arg0) }
        XSTQ (Local0 + TBAT, Arg0)
        XSTQ (Arg0 + TBAL, Zero)
        SKCH = One
    }

    // The ACK of the segment in TR* for a synchronized Arg0. Returns zero if
    // the segment must not be processed further.
    Method (TPAK, 1, NotSerialized)
    {
        Local0 = XLDQ (Arg0 + TBSU)
        Local1 = XLDQ (Arg0 + TBSX)
        If (TPLT (Local1, TRAK))
        {
            TPAN (Arg0)
            Return (Zero)
        }
        If (TPLT (TRAK, Local0)) { Return (One) } // old: neither data nor window
        Local2 = TPSD (TRAK, Local0)
        Local3 = TRWN << XLDQ (Arg0 + TBSS)
        If (Local2) { TPNA (Arg0, Local2) }
        ElseIf (!TRDL && !(TRFL & 3) && Local0 != Local1)
        {
            // RFC 5681 also wants an unchanged window, but slirp's moves
            // with almost every ACK and would never trigger fast retransmit.
            TPDU (Arg0)
        }
        If (TPLT (XLDQ (Arg0 + TBW1), TRSQ) ||
            (XLDQ (Arg0 + TBW1) == TRSQ && !TPLT (TRAK, XLDQ (Arg0 + TBW2))))
        {
            Local4 = XLDQ (Arg0 + TBSW)
            XSTQ (Arg0 + TBSW, Local3)
            XSTQ (Arg0 + TBW1, TRSQ)
            XSTQ (Arg0 + TBW2, TRAK)
            If (Local3 > XLDQ (Arg0 + TBMW)) { XSTQ (Arg0 + TBMW, Local3) }
            If (Local3 > Local4 && (XLDQ (Arg0 + TBFL) & 256))
            {
                // The window opened: stop probing.
                TPFC (Arg0, 256)
                XSTQ (Arg0 + TBRD, Zero)
                XSTQ (Arg0 + TBRC, Zero)
            }
        }
        // Our FIN acknowledged?
        Local5 = XLDQ (Arg0 + TBFL)
        If ((Local5 & 2) && !(Local5 & 4))
        {
            If (!TPLT (TRAK, (XLDQ (Arg0 + TBFS) + One) & 0xFFFFFFFF))
            {
                TPFS (Arg0, 4)
                Local6 = XLDQ (Arg0 + TBST)
                If (Local6 == 5)
                {
                    XSTQ (Arg0 + TBST, 6)
                    If (Local5 & 8)
                    {
                        Local7 = MNOW () + TPF2
                        XSTQ (Arg0 + TBKD, Local7)
                        NTIM (Local7)
                    }
                    SKCH = One
                }
                ElseIf (Local6 == 8) { TPTI (Arg0) }
                ElseIf (Local6 == 9)
                {
                    TPDR (Arg0, Zero)
                    Return (Zero)
                }
            }
        }
        Return (One)
    }

    // Arg1 new bytes of sequence space acknowledged by TRAK.
    Method (TPNA, 2, NotSerialized)
    {
        Local0 = Arg1
        Local1 = XLDQ (Arg0 + TBSL)
        If (Local0 > Local1) { Local0 = Local1 } // the FIN's sequence number
        XSTQ (Arg0 + TBSO, (XLDQ (Arg0 + TBSO) + Local0) & TPRK)
        XSTQ (Arg0 + TBSL, Local1 - Local0)
        XSTQ (Arg0 + TBSU, TRAK)
        If (TPLT (XLDQ (Arg0 + TBSN), TRAK)) { XSTQ (Arg0 + TBSN, TRAK) }
        If (XLDQ (Arg0 + TBTT))
        {
            If (TPLT (XLDQ (Arg0 + TBTS), TRAK))
            {
                TPRR (Arg0, MNOW () - XLDQ (Arg0 + TBTT))
                XSTQ (Arg0 + TBTT, Zero)
            }
        }
        // New data acknowledged: forget the backoff, as Linux does.
        If (XLDQ (Arg0 + TBRC)) { TPRO (Arg0) }
        XSTQ (Arg0 + TBRC, Zero)
        XSTQ (Arg0 + TBRS, Zero)
        XSTQ (Arg0 + TBSE, Zero)
        XSTQ (Arg0 + TBRD, Zero)
        Local2 = XLDQ (Arg0 + TBMS)
        Local3 = XLDQ (Arg0 + TBCW)
        If (XLDQ (Arg0 + TBFL) & 4096)
        {
            If (!TPLT (TRAK, XLDQ (Arg0 + TBRF)))
            {
                // NewReno: a full ACK ends fast recovery.
                Local3 = XLDQ (Arg0 + TBTH)
                TPFC (Arg0, 4096)
            }
            Else
            {
                // A partial ACK: resend the next hole, deflate the window.
                TPR1 (Arg0)
                If (Local3 > Arg1) { Local3 -= Arg1 }
                Local3 += Local2
            }
        }
        ElseIf (Local3 < XLDQ (Arg0 + TBTH))
        {
            If (Arg1 < Local2) { Local3 += Arg1 }
            Else { Local3 += Local2 }
        }
        Else
        {
            Local4 = Local2 * Local2 / Local3
            If (!Local4) { Local4 = One }
            Local3 += Local4
        }
        If (Local3 > 0x40000000) { Local3 = 0x40000000 }
        XSTQ (Arg0 + TBCW, Local3)
        XSTQ (Arg0 + TBDA, Zero)
        SKCH = One
    }

    // A duplicate ACK: the third starts fast retransmit (RFC 6582).
    Method (TPDU, 1, NotSerialized)
    {
        Local0 = XLDQ (Arg0 + TBDA) + One
        XSTQ (Arg0 + TBDA, Local0)
        Local1 = XLDQ (Arg0 + TBMS)
        If (XLDQ (Arg0 + TBFL) & 4096)
        {
            XSTQ (Arg0 + TBCW, XLDQ (Arg0 + TBCW) + Local1)
            Return ()
        }
        If (Local0 != 3) { Return () }
        Local2 = TPSD (XLDQ (Arg0 + TBSX), XLDQ (Arg0 + TBSU)) / 2
        If (Local2 < Local1 * 2) { Local2 = Local1 * 2 }
        XSTQ (Arg0 + TBTH, Local2)
        XSTQ (Arg0 + TBCW, Local2 + Local1 * 3)
        XSTQ (Arg0 + TBRF, XLDQ (Arg0 + TBSX))
        TPFS (Arg0, 4096)
        TPR1 (Arg0)
    }

    // Data of the segment in TR* for Arg0. What fits goes into the receive
    // ring at the place its sequence number gives it, so data that arrives
    // ahead of a hole waits there (up to TPON ranges) and needs no
    // retransmission once the hole is filled.
    Method (TPDT, 1, NotSerialized)
    {
        Local0 = XLDQ (Arg0 + TBRN)
        Local1 = TPSD (TRSQ, Local0)
        If (Local1 >= 0x80000000)
        {
            Local1 = TPSD (Local0, TRSQ)
            If (Local1 >= TRDL)
            {
                TRFL &= ~One
                TPAN (Arg0)
                Return ()
            }
            TRDA += Local1
            TRDL -= Local1
            TRSQ = Local0
            Local1 = Zero
        }
        Local2 = TPRZ - XLDQ (Arg0 + TBRL) // free space from RCV.NXT on
        If (Local1 >= Local2)
        {
            TRFL &= ~One
            TPAN (Arg0)
            Return ()
        }
        Local3 = TRDL
        If (Local1 + Local3 > Local2)
        {
            Local3 = Local2 - Local1
            TRFL &= ~One
        }
        Local4 = XLDQ (Arg0 + TBRL)
        TPRG (XLDQ (Arg0 + TBRB), (XLDQ (Arg0 + TBRO) + Local4 + Local1) & TPRK, TRDA, Local3, One)
        If (Local1)
        {
            // Ahead of a hole: remember the range, and ACK at once so the
            // duplicate ACKs start the peer's fast retransmit.
            TRFL &= ~One
            TPOI (Arg0, TRSQ, (TRSQ + Local3) & 0xFFFFFFFF)
            TPAN (Arg0)
            Return ()
        }
        Local5 = (Local0 + Local3) & 0xFFFFFFFF
        Local6 = Local3
        If (XLDQ (Arg0 + TBOQ))
        {
            Local7 = TPOM (Arg0, Local5)
            If (Local7 != Local5)
            {
                // A hole filled: everything held behind it is readable now.
                Local6 += TPSD (Local7, Local5)
                Local5 = Local7
                TRFL &= ~One
                TPQA (Arg0)
            }
        }
        XSTQ (Arg0 + TBRL, Local4 + Local6)
        XSTQ (Arg0 + TBRN, Local5)
        If (Local6) { SKCH = One }
        If (Local3 < TRDL) { TPAN (Arg0) }
        TRDL = Local3
        Local7 = XLDQ (Arg0 + TBAB) + Local3
        XSTQ (Arg0 + TBAB, Local7)
        If (Local3 < Local2 && Local7 <= XLDQ (Arg0 + TBRM) && !(TRFL & One))
        {
            If (!XLDQ (Arg0 + TBAD))
            {
                Local6 = MNOW () + TPDL
                XSTQ (Arg0 + TBAD, Local6)
                NTIM (Local6)
            }
        }
        Else { TPQA (Arg0) }
    }

    // Record out-of-order data from Arg1 to Arg2 on Arg0, merging ranges
    // that overlap or touch. Without a free slot the data is forgotten.
    Method (TPOI, 3, NotSerialized)
    {
        Local0 = Zero
        Local1 = XLDQ (Arg0 + TBOQ)
        While (Local0 < Local1)
        {
            Local2 = Arg0 + TBOR + Local0 * 16
            Local3 = XLDQ (Local2)
            Local4 = XLDQ (Local2 + 8)
            If (!TPLT (Local4, Arg1) && !TPLT (Arg2, Local3))
            {
                // Overlapping or adjacent: take this range out and widen.
                If (TPLT (Local3, Arg1)) { Arg1 = Local3 }
                If (TPLT (Arg2, Local4)) { Arg2 = Local4 }
                Decrement (Local1)
                XSTQ (Local2, XLDQ (Arg0 + TBOR + Local1 * 16))
                XSTQ (Local2 + 8, XLDQ (Arg0 + TBOR + Local1 * 16 + 8))
                Continue
            }
            Increment (Local0)
        }
        If (Local1 < TPON)
        {
            XSTQ (Arg0 + TBOR + Local1 * 16, Arg1)
            XSTQ (Arg0 + TBOR + Local1 * 16 + 8, Arg2)
            Increment (Local1)
        }
        XSTQ (Arg0 + TBOQ, Local1)
    }

    // The new RCV.NXT once ranges that start at or before Arg1 join it;
    // those ranges are dropped.
    Method (TPOM, 2, NotSerialized)
    {
        Local5 = One
        While (Local5)
        {
            Local5 = Zero
            Local0 = Zero
            Local1 = XLDQ (Arg0 + TBOQ)
            While (Local0 < Local1)
            {
                Local2 = Arg0 + TBOR + Local0 * 16
                If (!TPLT (Arg1, XLDQ (Local2)))
                {
                    If (TPLT (Arg1, XLDQ (Local2 + 8)))
                    {
                        Arg1 = XLDQ (Local2 + 8)
                        Local5 = One
                    }
                    Decrement (Local1)
                    XSTQ (Local2, XLDQ (Arg0 + TBOR + Local1 * 16))
                    XSTQ (Local2 + 8, XLDQ (Arg0 + TBOR + Local1 * 16 + 8))
                    XSTQ (Arg0 + TBOQ, Local1)
                    Continue
                }
                Increment (Local0)
            }
        }
        Return (Arg1)
    }

    // After the application read from Arg0: send a window update once the
    // window has at least doubled by an MSS or more (like Linux's
    // tcp_cleanup_rbuf), or the delayed ACK if everything has been read.
    Method (TPWU, 1, NotSerialized)
    {
        Local0 = XLDQ (Arg0 + TBST)
        If (Local0 != 4 && Local0 != 5 && Local0 != 6) { Return () }
        Local1 = TPSD (XLDQ (Arg0 + TBRE), XLDQ (Arg0 + TBRN))
        If (Local1 >= 0x80000000) { Local1 = Zero }
        Local2 = TPRZ - XLDQ (Arg0 + TBRL)
        Local3 = 0xFFFF << XLDQ (Arg0 + TBWS)
        If (Local2 > Local3) { Local2 = Local3 }
        Local4 = XLDQ (Arg0 + TBRM)
        If (Local4 > TPRZ / 2) { Local4 = TPRZ / 2 }
        If (Local2 >= Local1 * 2 && Local2 - Local1 >= Local4)
        {
            TPAN (Arg0)
            Return ()
        }
        If (XLDQ (Arg0 + TBAB) && !XLDQ (Arg0 + TBRL)) { TPAN (Arg0) }
    }

    // Network timer at MNOW Arg0: free reaped sockets, then run every TCB's
    // expired timers and rearm the rest.
    Method (TPTK, 1, NotSerialized)
    {
        TPRA ()
        Local0 = TPHD
        While (Local0)
        {
            Local1 = XLDQ (Local0 + TBLN)
            TPT1 (Local0, Arg0)
            Local0 = Local1
        }
    }

    Method (TPT1, 2, NotSerialized)
    {
        Local0 = XLDQ (Arg0 + TBRD)
        If (Local0 && Arg1 >= Local0)
        {
            XSTQ (Arg0 + TBRD, Zero)
            If (XLDQ (Arg0 + TBFL) & 256) { TPPP (Arg0, Arg1) }
            Else { TPTO (Arg0, Arg1) }
        }
        Local0 = XLDQ (Arg0 + TBAD)
        If (Local0 && Arg1 >= Local0)
        {
            XSTQ (Arg0 + TBAD, Zero)
            If (XLDQ (Arg0 + TBST) >= 4) { TPAN (Arg0) }
        }
        Local0 = XLDQ (Arg0 + TBKD)
        If (Local0 && Arg1 >= Local0)
        {
            XSTQ (Arg0 + TBKD, Zero)
            Local1 = XLDQ (Arg0 + TBST)
            If (Local1 == 10 || Local1 == 6) { TPDR (Arg0, Zero) }
            ElseIf (Local1 == 4 || Local1 == 7) { TPKA (Arg0) }
        }
        If (!XLDQ (Arg0 + TBST)) { Return () }
        If (XLDQ (Arg0 + TBRD)) { NTIM (XLDQ (Arg0 + TBRD)) }
        If (XLDQ (Arg0 + TBAD)) { NTIM (XLDQ (Arg0 + TBAD)) }
        If (XLDQ (Arg0 + TBKD)) { NTIM (XLDQ (Arg0 + TBKD)) }
    }

    // Retransmission timeout on Arg0 at MNOW Arg1: back off, collapse the
    // congestion window and go back to SND.UNA. Gives up with ETIMEDOUT (or a
    // soft error seen meanwhile) after TCP_SYNCNT (6) SYN or 15 other tries,
    // or once TCP_USER_TIMEOUT has passed.
    Method (TPTO, 2, NotSerialized)
    {
        Local0 = XLDQ (Arg0 + TBRC) + One
        Local1 = XLDQ (Arg0 + TBST)
        Local2 = 15
        If (Local1 == 2 || Local1 == 3)
        {
            Local2 = XLDQ (Arg0 + TBSC)
            If (!Local2)
            {
                Local2 = 6
                If (Local1 == 3) { Local2 = 5 }
            }
        }
        If (Local0 == One) { XSTQ (Arg0 + TBRS, Arg1) }
        Local3 = Zero
        If (Local0 > Local2) { Local3 = One }
        Local4 = XLDQ (Arg0 + TBUT)
        If (Local4)
        {
            Local3 = Zero
            If (Arg1 - XLDQ (Arg0 + TBRS) >= Local4 * 1000000) { Local3 = One }
        }
        If (Local3)
        {
            Local5 = XLDQ (Arg0 + TBSE)
            If (!Local5) { Local5 = Zero - 110 } // ETIMEDOUT
            TPDR (Arg0, Local5)
            Return ()
        }
        XSTQ (Arg0 + TBRC, Local0)
        Local5 = XLDQ (Arg0 + TBRT) * 2
        If (Local5 > 120000000000) { Local5 = 120000000000 }
        XSTQ (Arg0 + TBRT, Local5)
        XSTQ (Arg0 + TBTT, Zero)
        Local6 = XLDQ (Arg0 + TBMS)
        Local7 = TPSD (XLDQ (Arg0 + TBSX), XLDQ (Arg0 + TBSU)) / 2
        If (Local7 < Local6 * 2) { Local7 = Local6 * 2 }
        XSTQ (Arg0 + TBTH, Local7)
        XSTQ (Arg0 + TBCW, Local6)
        XSTQ (Arg0 + TBDA, Zero)
        TPFC (Arg0, 4096)
        If (Local1 == 2)
        {
            If (TPSG (Arg0, XLDQ (Arg0 + TBIS), Zero, Zero, 2)) { Increment (TQRT) }
        }
        ElseIf (Local1 == 3)
        {
            If (TPSG (Arg0, XLDQ (Arg0 + TBIS), Zero, Zero, 0x12)) { Increment (TQRT) }
        }
        Else
        {
            XSTQ (Arg0 + TBSN, XLDQ (Arg0 + TBSU))
            TPOU (Arg0)
        }
        TPAR (Arg0)
    }

    // Persist timer: probe the closed window with an old sequence number,
    // which the peer must answer with its current window.
    Method (TPPP, 2, NotSerialized)
    {
        Local0 = XLDQ (Arg0 + TBRC) + One
        XSTQ (Arg0 + TBRC, Local0)
        XSTQ (Arg0 + TBPC, XLDQ (Arg0 + TBPC) + One)
        // A small open window is used now, overriding sender SWS avoidance
        // (RFC 1122 4.2.3.4); a closed one is probed.
        If (XLDQ (Arg0 + TBSW))
        {
            TPFS (Arg0, 1024)
            Local2 = TPO1 (Arg0)
            TPFC (Arg0, 1024)
            If (Local2)
            {
                TPAR (Arg0)
                Return ()
            }
        }
        TPSG (Arg0, (XLDQ (Arg0 + TBSU) - One) & 0xFFFFFFFF, Zero, Zero, 0x10)
        If (Local0 > 10) { Local0 = 10 }
        Local1 = XLDQ (Arg0 + TBRT) << (Local0 - One)
        If (Local1 > 60000000000) { Local1 = 60000000000 }
        XSTQ (Arg0 + TBRD, Arg1 + Local1)
    }

    // Keepalive: probe like the persist timer, every TCP_KEEPINTVL, and
    // give up after TCP_KEEPCNT unanswered probes.
    Method (TPKA, 1, NotSerialized)
    {
        Local0 = XLDQ (Arg0 + INKC)
        If (!Local0) { Local0 = 9 }
        If (XLDQ (Arg0 + TBKP) >= Local0)
        {
            TPDR (Arg0, Zero - 110)
            Return ()
        }
        XSTQ (Arg0 + TBKP, XLDQ (Arg0 + TBKP) + One)
        TPSG (Arg0, (XLDQ (Arg0 + TBSU) - One) & 0xFFFFFFFF, Zero, Zero, 0x10)
        Local1 = XLDQ (Arg0 + INKV)
        If (!Local1) { Local1 = 75 }
        Local1 = MNOW () + Local1 * 1000000000
        XSTQ (Arg0 + TBKD, Local1)
    }

    // ICMP or ARP trouble on the way to Arg0 for TCP. A hard error (Arg2
    // set) ends connections still in SYN_SENT; otherwise, and for
    // established ones, it is kept to report if they time out. Arg1 is the
    // errno; Arg3 and Arg4 the quoted ports (zero for all connections).
    Method (TPHU, 5, NotSerialized)
    {
        Local0 = INHD
        While (Local0)
        {
            Local1 = XLDQ (Local0 + INNX)
            If (XLDQ (Local0 + INPT) == 6 && XLDQ (Local0 + TBST) > One &&
                XLDQ (Local0 + INRA) == Arg0)
            {
                Local2 = One
                If (Arg3)
                {
                    If (XLDQ (Local0 + INLP) != Arg3 || XLDQ (Local0 + INRP) != Arg4) { Local2 = Zero }
                }
                If (Local2)
                {
                    If (Arg2 && XLDQ (Local0 + TBST) == 2) { TPDR (Local0, Arg1) }
                    Else { XSTQ (Local0 + TBSE, Arg1) }
                }
            }
            Local0 = Local1
        }
    }

    // ICMP destination unreachable code Arg2 for the TCP segment quoted at
    // Arg0 (Arg1 bytes): like Linux, codes 2-4 and 9, 10 and 13 are hard
    // errors; others are soft.
    Method (TPIC, 3, NotSerialized)
    {
        Local0 = (XBYT (Arg0) & 0xF) * 4
        If (Local0 < 20 || Arg1 < Local0 + 4) { Return () }
        If (Arg2 == 2) { Local1 = Zero - 92 } // ENOPROTOOPT
        ElseIf (Arg2 == 3) { Local1 = Zero - 111 } // ECONNREFUSED
        ElseIf (Arg2 == 4) { Local1 = Zero - 90 } // EMSGSIZE
        ElseIf (Arg2 == 6 || Arg2 == 9 || Arg2 == Zero) { Local1 = Zero - 101 } // ENETUNREACH
        ElseIf (Arg2 == 7) { Local1 = Zero - 112 } // EHOSTDOWN
        Else { Local1 = Zero - 113 } // EHOSTUNREACH
        Local2 = One
        If (Arg2 != 2 && Arg2 != 3 && Arg2 != 4 && Arg2 != 9 && Arg2 != 10 && Arg2 != 13) { Local2 = Zero }
        Local3 = Arg0 + Local0
        TPHU (NL32 (Arg0 + 16), Local1, Local2, NL16 (Local3), NL16 (Local3 + 2))
    }

    // connect(Arg1, port Arg2) on TCP socket Arg0, for blocking unless Arg3.
    // Returns zero, a negative errno, or Ones to wait (TPCW).
    Method (TPCN, 4, NotSerialized)
    {
        Local0 = XLDQ (Arg0 + TBST)
        If (Local0 == One) { Return (Zero - 106) } // EISCONN, as on Linux
        If (Local0 == 2 || Local0 == 3)
        {
            If (Arg3) { Return (Zero - 114) } // EALREADY
            Return (Ones)
        }
        If (Local0)
        {
            If (XLDQ (Arg0 + TBFL) & 128) { Return (Zero - 106) }
            TPFS (Arg0, 128)
            Return (Zero)
        }
        // A connection attempt that failed reports its error once.
        Local1 = XLDQ (Arg0 + INER)
        If (Local1 && XLDQ (Arg0 + TBSB))
        {
            XSTQ (Arg0 + INER, Zero)
            Return (Local1)
        }
        If (XLDQ (Arg0 + TBFL) & 128) { Return (Zero - 106) } // closed after connecting
        If (!Arg2) { Return (Zero - 111) } // port 0
        Local1 = INRT (Arg0, Arg1)
        If (Local1) { Return (Local1) }
        If (!XLDQ (Arg0 + INLP))
        {
            Local1 = INBN (Arg0, Zero, Zero)
            If (Local1) { Return (Local1) }
        }
        If (!XLDQ (Arg0 + INLA)) { XSTQ (Arg0 + INLA, NSRC (Arg1)) }
        Local1 = TPLK (Arg0, XLDQ (Arg0 + INLA), XLDQ (Arg0 + INLP), Arg1, Arg2)
        If (Local1)
        {
            // AML && does not short-circuit.
            If (XLDQ (Local1 + TBST) > One) { Return (Zero - 99) } // EADDRNOTAVAIL: that connection exists
        }
        If (!TPAL (Arg0)) { Return (Zero - 105) } // ENOBUFS
        XSTQ (Arg0 + INRA, Arg1)
        XSTQ (Arg0 + INRP, Arg2)
        TPNW (Arg0, TPRN ())
        XSTQ (Arg0 + TBST, 2)
        TPLN (Arg0)
        Increment (TQAO)
        TPSG (Arg0, XLDQ (Arg0 + TBIS), Zero, Zero, 2)
        TPAR (Arg0)
        If (Arg3) { Return (Zero - 115) } // EINPROGRESS
        Return (TPCW (Arg0))
    }

    // Completion of a blocking connect on Arg0.
    Method (TPCW, 1, NotSerialized)
    {
        Local0 = XLDQ (Arg0 + TBST)
        If (Local0 == 2 || Local0 == 3) { Return (Ones) }
        If (Local0)
        {
            TPFS (Arg0, 128)
            Return (Zero)
        }
        Local1 = XLDQ (Arg0 + INER)
        XSTQ (Arg0 + INER, Zero)
        If (Local1) { Return (Local1) }
        Return (Zero - 103) // ECONNABORTED
    }

    // listen(Arg0, backlog Arg1). Another listener on the same port and an
    // overlapping address conflicts unless both set SO_REUSEPORT.
    Method (TPLS, 2, NotSerialized)
    {
        If (XLDQ (Arg0 + INTY) != One) { Return (Zero - 95) } // EOPNOTSUPP
        Local0 = XLDQ (Arg0 + TBST)
        If (Local0 > One) { Return (Zero - 22) }
        Local1 = Arg1 & 0xFFFFFFFF
        If (Local1 >= 0x80000000 || Local1 > 4096) { Local1 = 4096 } // somaxconn
        XSTQ (Arg0 + TBBL, Local1)
        If (Local0 == One) { Return (Zero) }
        If (!XLDQ (Arg0 + INLP))
        {
            Local2 = INBN (Arg0, Zero, Zero)
            If (Local2) { Return (Local2) }
        }
        Local2 = INHD
        Local3 = XLDQ (Arg0 + INLA)
        Local4 = XLDQ (Arg0 + INLP)
        While (Local2)
        {
            If (Local2 != Arg0 && XLDQ (Local2 + INPT) == 6 && XLDQ (Local2 + INLP) == Local4 &&
                XLDQ (Local2 + TBST) == One)
            {
                Local5 = XLDQ (Local2 + INLA)
                If (!Local5 || !Local3 || Local5 == Local3)
                {
                    If (!(XLDQ (Local2 + INOB) & XLDQ (Arg0 + INOB) & 0x8000)) { Return (Zero - 98) }
                }
            }
            Local2 = XLDQ (Local2 + INNX)
        }
        XSTQ (Arg0 + TBST, One)
        XSTQ (Arg0 + TBAN, Zero)
        XSTQ (Arg0 + INSH, Zero)
        Return (Zero)
    }

    // accept4 on listener Arg1 for task Arg0: address to Arg2 (length at
    // Arg3), descriptor flags Arg4. Ones to block.
    Method (TPAC, 5, NotSerialized)
    {
        If (Arg4 & ~0x80800) { Return (Zero - 22) }
        If (XLDQ (Arg1 + TBST) != One) { Return (Zero - 22) }
        Local0 = XLDQ (Arg1 + TBAH)
        If (!Local0)
        {
            If (XLDQ (Arg1 + SKFL)) { Return (Zero - 11) }
            Return (Ones)
        }
        If (Arg2)
        {
            If (!UCPY (Arg0, XADR (INAL), Arg3, 4) || !URNG (Arg0, Arg3, 4, WRIT)) { Return (Zero - 14) }
            Local1 = ELWD (XADR (INAL), Zero, 4)
            If (Local1 >> 31) { Return (Zero - 22) }
            INSA (XLDQ (Local0 + INRA), XLDQ (Local0 + INRP))
            If (Local1 > 16) { Local1 = 16 }
            If (Local1 && !UCOP (Arg0, Arg2, XADR (INAD), Local1)) { Return (Zero - 14) }
            XSTQ (XADR (INAL), 16)
            If (!UCOP (Arg0, Arg3, XADR (INAL), 4)) { Return (Zero - 14) }
        }
        XSTQ (Local0 + 16, One)
        XSTQ (Local0 + SKFL, Arg4 & 0x800)
        Local1 = FINS (Arg0, Local0, Arg4)
        If (Local1 >= Zero - 4095)
        {
            XSTQ (Local0 + 16, Zero)
            Return (Local1)
        }
        TPAU (Arg1, Local0)
        TPFS (Local0, 128)
        Return (Local1)
    }

    // Stop listening on Arg0: reset every child nobody accepted.
    Method (TPLX, 1, NotSerialized)
    {
        XSTQ (Arg0 + TBST, Zero)
        Local0 = TPHD
        While (Local0)
        {
            Local1 = XLDQ (Local0 + TBLN)
            If (XLDQ (Local0 + TBPA) == Arg0)
            {
                TPSG (Local0, XLDQ (Local0 + TBSN), Zero, Zero, 0x14)
                TPDR (Local0, Zero)
            }
            Local0 = Local1
        }
        SKCH = One
    }

    // Queue our FIN: shutdown(SHUT_WR) or close.
    Method (TPFN, 1, NotSerialized)
    {
        Local0 = XLDQ (Arg0 + TBST)
        If (Local0 == 4 || Local0 == 3) { XSTQ (Arg0 + TBST, 5) }
        ElseIf (Local0 == 7) { XSTQ (Arg0 + TBST, 9) }
        Else { Return () }
        TPFS (Arg0, One)
        TPOU (Arg0)
    }

    // shutdown(Arg0, Arg1) on a TCP socket.
    Method (TPSH, 2, NotSerialized)
    {
        Local0 = XLDQ (Arg0 + TBST)
        Local1 = Arg1 + One
        If (Local0 == One)
        {
            If (!(Local1 & One)) { Return (Zero - 107) }
            TPLX (Arg0)
            Return (Zero)
        }
        If (Local0 == 2)
        {
            TPDR (Arg0, Zero)
            XSTQ (Arg0 + INSH, Zero)
            Return (Zero)
        }
        XSTQ (Arg0 + INSH, XLDQ (Arg0 + INSH) | Local1)
        SKCH = One
        If (!Local0) { Return (Zero - 107) } // ENOTCONN
        If (Local1 & 2) { TPFN (Arg0) }
        Return (Zero)
    }

    // Final close of TCP socket Arg0. A connection lives on as an orphan
    // that finishes sending and closes; unread data or SO_LINGER with a zero
    // timeout resets it instead, as on Linux.
    Method (TPCL, 1, NotSerialized)
    {
        Local0 = XLDQ (Arg0 + TBST)
        If (Local0 == One) { TPLX (Arg0) }
        If (Local0 == 2) { TPDR (Arg0, Zero) }
        Local0 = XLDQ (Arg0 + TBST)
        If (!Local0)
        {
            TPUL (Arg0)
            INUB (Arg0)
            If (TPLC == Arg0) { TPLC = Zero }
            TPFR (Arg0)
            Return ()
        }
        TPFS (Arg0, 8)
        XSTQ (Arg0 + INSH, 3)
        If (XLDQ (Arg0 + TBRL) || (XLDQ (Arg0 + INLG) & 0xFFFFFFFF00000001) == One)
        {
            If (Local0 != 10) { TPSG (Arg0, XLDQ (Arg0 + TBSN), Zero, Zero, 0x14) }
            TPDR (Arg0, Zero)
            Return ()
        }
        If (Local0 == 6)
        {
            Local1 = MNOW () + TPF2
            XSTQ (Arg0 + TBKD, Local1)
            NTIM (Local1)
        }
        TPFN (Arg0)
    }

    // send on TCP socket Arg1 for task Arg0: the Arg2 iovecs in INIV with
    // flags Arg3. A blocking send returns once everything is in the send
    // ring, waiting (Ones) as often as needed.
    Method (TPSN, 4, NotSerialized)
    {
        Local0 = TPS2 (Arg0, Arg1, Arg2, Arg3)
        If (Local0 != Ones) { XSTQ (Arg0 + TSNP, Zero) }
        Return (Local0)
    }

    Method (TPS2, 4, NotSerialized)
    {
        If (Arg3 & One) { Return (Zero - 95) } // MSG_OOB
        Local7 = XLDQ (Arg0 + TSNP)
        Local0 = XLDQ (Arg1 + INER)
        If (Local0)
        {
            If (Local7) { Return (Local7) }
            XSTQ (Arg1 + INER, Zero)
            Return (Local0)
        }
        Local1 = XLDQ (Arg1 + TBST)
        If (Local1 == 2 || Local1 == 3)
        {
            If ((Arg3 & 0x40) || XLDQ (Arg1 + SKFL)) { Return (Zero - 11) }
            Return (Ones)
        }
        If ((Local1 != 4 && Local1 != 7) || (XLDQ (Arg1 + INSH) & 2))
        {
            If (Local7) { Return (Local7) }
            If (!(Arg3 & 0x4000)) { SGQI (Arg0, 13, Zero, SGSN (Arg0)) } // SIGPIPE
            Return (Zero - 32) // EPIPE
        }
        Local2 = INVS (Arg2)
        If (Local2 >= Zero - 4095) { Return (Local2) }
        Local3 = Local2 - Local7
        Local4 = TPRZ - XLDQ (Arg1 + TBSL)
        If (Local3 < Local4) { Local4 = Local3 }
        If (Local4)
        {
            Local5 = TPIV (Arg0, XLDQ (Arg1 + TBSB),
                (XLDQ (Arg1 + TBSO) + XLDQ (Arg1 + TBSL)) & TPRK, Arg2, Local7, Local4, Zero)
            If (Local5 == Ones)
            {
                If (Local7) { Return (Local7) }
                Return (Zero - 14)
            }
            XSTQ (Arg1 + TBSL, XLDQ (Arg1 + TBSL) + Local4)
            Local7 += Local4
            TPOU (Arg1)
        }
        If (Local7 < Local2)
        {
            If ((Arg3 & 0x40) || XLDQ (Arg1 + SKFL))
            {
                If (Local7) { Return (Local7) }
                Return (Zero - 11)
            }
            XSTQ (Arg0 + TSNP, Local7)
            Return (Ones)
        }
        Return (Local7)
    }

    // recv on TCP socket Arg1 for task Arg0 into the Arg2 iovecs in INIV
    // with flags Arg3 (MSG_PEEK, MSG_TRUNC discards, MSG_WAITALL,
    // MSG_DONTWAIT). A nonzero Arg4 asks for the source address, whose
    // length at Arg5 becomes zero, as on Linux.
    Method (TPRV, 6, NotSerialized)
    {
        Local0 = TPR2 (Arg0, Arg1, Arg2, Arg3)
        If (Local0 != Ones) { XSTQ (Arg0 + TSNP, Zero) }
        If (Local0 < Zero - 4095 && Arg4)
        {
            XSTQ (XADR (INAL), Zero)
            If (!UCOP (Arg0, Arg5, XADR (INAL), 4)) { Return (Zero - 14) }
        }
        Return (Local0)
    }

    Method (TPR2, 4, NotSerialized)
    {
        If (Arg3 & One) { Return (Zero - 22) } // MSG_OOB: no urgent data
        Local1 = XLDQ (Arg1 + TBST)
        If (Local1 == One) { Return (Zero - 107) }
        Local7 = XLDQ (Arg0 + TSNP)
        Local2 = INVS (Arg2)
        If (Local2 >= Zero - 4095) { Return (Local2) }
        Local3 = XLDQ (Arg1 + TBRL)
        If (Local3)
        {
            Local4 = Local2 - Local7
            If (Local4 > Local3) { Local4 = Local3 }
            If (!(Arg3 & 0x20))
            {
                Local5 = TPIV (Arg0, XLDQ (Arg1 + TBRB), XLDQ (Arg1 + TBRO), Arg2, Local7, Local4, One)
                If (Local5 == Ones)
                {
                    If (Local7) { Return (Local7) }
                    Return (Zero - 14)
                }
            }
            If (!(Arg3 & 2))
            {
                XSTQ (Arg1 + TBRO, (XLDQ (Arg1 + TBRO) + Local4) & TPRK)
                XSTQ (Arg1 + TBRL, Local3 - Local4)
                TPWU (Arg1)
            }
            Local7 += Local4
            If (Local7 >= Local2 || !(Arg3 & 0x100) || (Arg3 & 0x42) || XLDQ (Arg1 + SKFL)) { Return (Local7) }
        }
        If (!Local2) { Return (Zero) }
        Local0 = XLDQ (Arg1 + INER)
        If (Local0)
        {
            If (Local7) { Return (Local7) }
            XSTQ (Arg1 + INER, Zero)
            Return (Local0)
        }
        If (XLDQ (Arg1 + INSH) & One) { Return (Local7) }
        If (!Local1) { Return (Zero - 107) } // never connected
        If ((Arg3 & 0x40) || XLDQ (Arg1 + SKFL))
        {
            If (Local7) { Return (Local7) }
            Return (Zero - 11)
        }
        XSTQ (Arg0 + TSNP, Local7)
        Return (Ones)
    }

    // Poll events of TCP socket Arg0, as Linux's tcp_poll.
    Method (TPPL, 1, NotSerialized)
    {
        Local0 = XLDQ (Arg0 + TBST)
        If (Local0 == One)
        {
            If (XLDQ (Arg0 + TBAH)) { Return (0x41) }
            Return (Zero)
        }
        Local1 = Zero
        Local2 = XLDQ (Arg0 + INSH)
        If (Local2 == 3 || !Local0) { Local1 |= 0x10 } // POLLHUP
        If (Local2 & One) { Local1 |= 0x2041 } // POLLIN | POLLRDNORM | POLLRDHUP
        If (Local0 != 2 && Local0 != 3)
        {
            If (XLDQ (Arg0 + TBRL)) { Local1 |= 0x41 }
            If (Local2 & 2) { Local1 |= 0x104 }
            Else
            {
                // Writable while free space is at least half what is queued.
                Local3 = XLDQ (Arg0 + TBSL)
                If ((TPRZ - Local3) * 2 >= Local3) { Local1 |= 0x104 }
            }
        }
        If (XLDQ (Arg0 + INER)) { Local1 |= 8 }
        Return (Local1)
    }

    // /proc/net/snmp: the Tcp lines, with Linux's columns.
    Method (TPSM, 1, NotSerialized)
    {
        Local0 = PCAT (Arg0, "Tcp: RtoAlgorithm RtoMin RtoMax MaxConn ActiveOpens PassiveOpens AttemptFails EstabResets CurrEstab InSegs OutSegs RetransSegs InErrs OutRsts InCsumErrors")
        XSTB (Local0, 10)
        Local0 = PCAT (Local0 + One, "Tcp: 1 200 120000 -1 ")
        Local1 = Zero
        Local2 = INHD
        While (Local2)
        {
            If (XLDQ (Local2 + INPT) == 6)
            {
                Local3 = XLDQ (Local2 + TBST)
                If (Local3 == 4 || Local3 == 7) { Increment (Local1) }
            }
            Local2 = XLDQ (Local2 + INNX)
        }
        Local0 = TPSV (Local0, TQAO)
        Local0 = TPSV (Local0, TQPO)
        Local0 = TPSV (Local0, TQAF)
        Local0 = TPSV (Local0, TQER)
        Local0 = TPSV (Local0, Local1)
        Local0 = TPSV (Local0, TQIS)
        Local0 = TPSV (Local0, TQOS)
        Local0 = TPSV (Local0, TQRT)
        Local0 = TPSV (Local0, TQIE)
        Local0 = TPSV (Local0, TQOR)
        Local0 = CDEC (Local0, TQIE)
        XSTB (Local0, 10)
        Return (Local0 + One - Arg0)
    }

    Method (TPSV, 2, NotSerialized)
    {
        Local0 = CDEC (Arg0, Arg1)
        XSTB (Local0, 0x20)
        Return (Local0 + One)
    }

    // /proc/net/tcp: every bound TCP socket (at most 24), in Linux's format.
    Name (TPST, Buffer (11) {7, 0x0A, 2, 3, 1, 4, 5, 8, 0x0B, 9, 6})
    Method (TPNT, 1, NotSerialized)
    {
        Local0 = PCAT (Arg0, "  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode")
        XSTB (Local0, 10)
        Local0 += One
        Local1 = Zero
        Local2 = INHD
        While (Local2 && Local1 < 24)
        {
            If (XLDQ (Local2 + INPT) == 6)
            {
                Local0 = NPRJ (Local0, Local1, 4)
                Local0 = PCAT (Local0, ": ")
                Local0 = NHXU (Local0, NBSW (XLDQ (Local2 + INLA)), 8)
                XSTB (Local0, 0x3A)
                Local0 = NHXU (Local0 + One, XLDQ (Local2 + INLP), 4)
                XSTB (Local0, 0x20)
                Local0 = NHXU (Local0 + One, NBSW (XLDQ (Local2 + INRA)), 8)
                XSTB (Local0, 0x3A)
                Local0 = NHXU (Local0 + One, XLDQ (Local2 + INRP), 4)
                XSTB (Local0, 0x20)
                Local0 = NHXU (Local0 + One, DerefOf (Index (TPST, XLDQ (Local2 + TBST))), 2)
                XSTB (Local0, 0x20)
                Local0 = NHXU (Local0 + One, XLDQ (Local2 + TBSL), 8)
                XSTB (Local0, 0x3A)
                Local0 = NHXU (Local0 + One, XLDQ (Local2 + TBRL), 8)
                Local0 = PCAT (Local0, " 00:00000000 00000000     0        0 0 1 0000000000000000 ")
                Local0 = CDEC (Local0, XLDQ (Local2 + TBRT) / 10000000)
                Local0 = PCAT (Local0, " 0 0 10 -1")
                XSTB (Local0, 10)
                Local0 += One
                Increment (Local1)
            }
            Local2 = XLDQ (Local2 + INNX)
        }
        Return (Local0 - Arg0)
    }
