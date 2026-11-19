DefinitionBlock ("", "SSDT", 2, "AMLAOT", "AOTDEMO", 0x00000001)
{
    Method (STEP, 1, NotSerialized)
    {
        If (And (Arg0, One))
        {
            Return (Multiply (Arg0, 3))
        }

        Return (ShiftRight (Arg0, One))
    }

    // TEST(0) = 0, TEST(4) = 13, TEST(8) = 54.
    Method (TEST, 1, NotSerialized)
    {
        Store (Zero, Local0)
        Store (Zero, Local1)

        While (LLess (Local0, Arg0))
        {
            Add (Local1, STEP (Local0), Local1)
            Increment (Local0)
        }

        Return (Local1)
    }

    Scope (\_SB)
    {
        Device (DEMO)
        {
            Name (_ADR, Zero)
            Name (TOTL, Zero)

            Method (BUMP, 1, NotSerialized)
            {
                Divide (Arg0, 3, Local0, Local1)
                If (LGreater (Local0, One))
                {
                    ShiftLeft (Add (Local1, Local0), One, Local2)
                }
                Else
                {
                    Xor (Local1, Local0, Local2)
                }

                Add (TOTL, Local2, TOTL)
                Return (TOTL)
            }

            Device (CHLD)
            {
                Name (_ADR, Zero)

                Method (STEP, 1, NotSerialized)
                {
                    Return (^^BUMP (\STEP (Arg0)))
                }
            }

            Method (RUN0, 1, NotSerialized)
            {
                Store (Zero, TOTL)
                Store (Zero, Local0)
                While (LLess (Local0, Arg0))
                {
                    Increment (Local0)
                    If (LEqual (Local0, 2))
                    {
                        Continue
                    }
                    If (LGreater (Local0, 5))
                    {
                        Break
                    }
                    ^CHLD.STEP (Local0)
                }

                Return (TOTL)
            }
        }
    }

    // MAIN() = TEST(8) + RUN0(8) = 54 + 13.
    Method (MAIN, 0, NotSerialized)
    {
        Return (Add (TEST (8), \_SB.DEMO.RUN0 (8)))
    }
}
