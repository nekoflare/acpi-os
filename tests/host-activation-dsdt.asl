DefinitionBlock ("", "DSDT", 2, "AMLAOT", "HOSTACTD", 1)
{
    Mutex (KEEP, 2)
    Mutex (LOWM, 0)
    Name (NEST, Zero)

    Method (PROB, 0, NotSerialized)
    {
        If (Acquire (LOWM, Zero)) { Return (One) }
        Release (LOWM)
        If (Acquire (KEEP, Zero)) { Return (2) }
        If (LNot (Acquire (LOWM, Zero))) { Return (3) }
        Release (KEEP)
        Return (Zero)
    }

    Method (NSET, 0, NotSerialized)
    {
        NEST = One
        Return (Zero)
    }
}
