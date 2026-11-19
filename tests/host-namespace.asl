DefinitionBlock ("", "DSDT", 2, "AMLAOT", "HOSTNS", 1)
{
    Mutex (MTX0, 0)
    Mutex (MTX2, 2)
    Event (EVT0)

    Processor (CPU0, 1, 0x1234, 6)
    {
        Method (STEP, 1, Serialized, 2)
        {
            Return (Arg0 + 1)
        }
    }

    PowerResource (PWR0, 0, 10)
    {
        Method (STEP, 1, Serialized, 1)
        {
            Return (\CPU0.STEP (Arg0) + 2)
        }
    }

    ThermalZone (TZ00)
    {
        Method (STEP, 1, Serialized, 1)
        {
            Return (\PWR0.STEP (Arg0) + 3)
        }

        Method (FAIL, 0, Serialized, 3)
        {
            Return (\PWR0.STEP (0))
        }
    }

    Method (HOST, 0, NotSerialized)
    {
        Sleep (5)
        Stall (11)
        Notify (\TZ00, 0x81)
        Return (Timer)
    }

    Method (EVWT, 1, NotSerialized)
    {
        Return (Wait (EVT0, Arg0))
    }

    Method (MAIN, 0, NotSerialized)
    {
        If (Acquire (MTX2, Zero)) { Return (One) }
        If (Acquire (MTX2, Zero)) { Return (2) }
        If (LNot (Acquire (MTX0, Zero))) { Return (3) }
        Release (MTX2)
        If (LNot (Acquire (MTX0, Zero))) { Return (4) }
        Release (MTX2)
        If (Acquire (MTX0, Zero)) { Return (5) }
        Release (MTX0)

        Signal (EVT0)
        Signal (EVT0)
        If (Wait (EVT0, Zero)) { Return (6) }
        If (Wait (EVT0, Zero)) { Return (7) }
        If (LNot (Wait (EVT0, Zero))) { Return (8) }
        Signal (EVT0)
        Reset (EVT0)
        If (LNot (Wait (EVT0, Zero))) { Return (9) }

        If (ObjectType (\CPU0) != 12) { Return (10) }
        If (ObjectType (\PWR0) != 11) { Return (11) }
        If (ObjectType (\TZ00) != 13) { Return (12) }
        If (LNot (HOST ())) { Return (13) }
        If (LNot (Wait (EVT0, 5))) { Return (14) }

        Return (\TZ00.STEP (36))
    }
}
