DefinitionBlock ("", "DSDT", 2, "AMLAOT", "AOTNS", 1)
{
    Scope (\_SB)
    {
        Device (LFT0)
        {
            Name (_ADR, Zero)
            Name (STAT, 10)

            Method (RUN0, 1, NotSerialized)
            {
                Store (STEP (Arg0), STAT)
                Return (^STAT)
            }

            Device (INNR)
            {
                Name (_ADR, Zero)

                Method (RUN0, 0, NotSerialized)
                {
                    Increment (STAT)
                    Store (^^STEP (One), ^^STAT)
                    Store (\STEP (), \STAT)
                    Return (Add (STAT, \STAT))
                }
            }
        }

        Device (RGT0)
        {
            Name (_ADR, One)
            Name (STAT, 20)

            Method (RUN0, 1, NotSerialized)
            {
                Store (^STEP (Arg0, 2), ^STAT)
                Return (Add (STAT, ^^LFT0.STAT))
            }

            Method (STEP, 2, NotSerialized)
            {
                Return (Add (STAT, Multiply (Arg0, Arg1)))
            }
        }
    }

    Scope (\_SB.LFT0)
    {
        Method (STEP, 1, NotSerialized)
        {
            Return (Add (STAT, Arg0))
        }
    }

    Scope (\)
    {
        Name (STAT, 100)

        Method (STEP, 0, NotSerialized)
        {
            Return (Add (\STAT, 5))
        }
    }

    Method (MAIN, 0, NotSerialized)
    {
        Store (\_SB.LFT0.RUN0 (5), Local0)
        Store (^_SB.RGT0.RUN0 (3), Local1)
        Store (\_SB.LFT0.INNR.RUN0 (), Local2)
        Return (Add (Multiply (Local0, 1000000), Add (Multiply (Local1, 1000), Local2)))
    }
}
