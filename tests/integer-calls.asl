#ifdef WIDTH32
DefinitionBlock ("", "DSDT", 1, "AMLAOT", "INTCALLS", 1)
#else
DefinitionBlock ("", "DSDT", 2, "AMLAOT", "INTCALLS", 1)
#endif
{
    Name (COUN, Zero)

    // Integer-returning, may fall through.
    Method (MAYB, 1, NotSerialized)
    {
        COUN++
        If (Arg0) { Return (Arg0 + 1) }
    }

    // Needs MAYB's value; fails with AML_NO_RETURN when MAYB falls through.
    Method (NEED, 1, NotSerialized)
    {
        Return (MAYB (Arg0) * 2)
    }

    // A statement call must not swallow NEED's AML_NO_RETURN failure.
    Method (STMT, 1, NotSerialized)
    {
        NEED (Arg0)
        Return (77)
    }

    // A statement call to a fall-through method succeeds.
    Method (IGNR, 0, NotSerialized)
    {
        MAYB (Zero)
        Return (COUN)
    }

    // Six scalar arguments: more than fit in registers with tagged values.
    Method (SIXA, 6, NotSerialized)
    {
        Return ((((((Arg0 * 2) + Arg1) * 2 + Arg2) * 2 + Arg3) * 2 + Arg4) * 2 + Arg5)
    }

    Method (CSIX, 0, NotSerialized)
    {
        Return (SIXA (1, 0, 1, 1, 0, 1))
    }

    // Mixed: Arg0 receives a string, Arg1 stays scalar.
    Method (MIXD, 2, NotSerialized)
    {
        Return (SizeOf (Arg0) + Arg1)
    }

    Method (CMIX, 0, NotSerialized)
    {
        Return (MIXD ("abcd", 10) + MIXD (Buffer (3) {}, 1))
    }

    Method (SERI, 1, Serialized, 3)
    {
        Return (Arg0 + 5)
    }

    Method (CSER, 0, NotSerialized)
    {
        Return (SERI (37))
    }

    // Recurses until the depth limit fails the call.
    Method (DEEP, 1, NotSerialized)
    {
        Return (DEEP (Arg0 + 1))
    }

    // Always returns, so callers need no missing-value check.
    Method (ALWS, 1, NotSerialized)
    {
        If (Arg0) { Return (1) } Else { Return (2) }
    }

    Method (CALW, 0, NotSerialized)
    {
        Return (ALWS (Zero) * 10 + ALWS (One))
    }

    // Wraps around at the table's integer width.
    Method (WRAP, 1, NotSerialized)
    {
        Return (Arg0 + 1)
    }

    Method (CWRP, 0, NotSerialized)
    {
        Return (WRAP (Ones))
    }
}
