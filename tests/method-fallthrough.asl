DefinitionBlock ("", "DSDT", 2, "AMLAOT", "FALLTHRU", 1)
{
    Name (STOR, Zero)
    Method (SETV, 1, NotSerialized)
    {
        STOR = Arg0
        If (Arg0 == One)
        {
            Return (20)
        }
    }

    Method (MAIN, 0, NotSerialized)
    {
        SETV (42)
        Return (STOR)
    }

    Method (NEED, 1, NotSerialized)
    {
        Return (SETV (Arg0))
    }
}
