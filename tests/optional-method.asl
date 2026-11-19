DefinitionBlock ("", "DSDT", 2, "AMLAOT", "OPTMTH", 1)
{
    External (MDBG, MethodObj)
    Name (SIDE, Zero)

    Method (CALL, 1, NotSerialized)
    {
        If (Arg0)
        {
            Return (\MDBG (Increment (SIDE)))
        }
        Return (42)
    }

    Method (SEEN, 0, NotSerialized)
    {
        Return (SIDE)
    }

    Method (MAIN, 0, NotSerialized)
    {
        If (CondRefOf (\MDBG))
        {
            Return (\MDBG (42))
        }

        If (LNot (CondRefOf (\MDBG)))
        {
            Return (42)
        }
        Else
        {
            Return (\MDBG (Zero))
        }
    }
}
