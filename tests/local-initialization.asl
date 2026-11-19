DefinitionBlock ("", "DSDT", 2, "AMLAOT", "LOCINIT", 1)
{
    Method (PICK, 1, NotSerialized)
    {
        If (Arg0 == One)
        {
            Local0 = 41
        }
        Return (Local0 + One)
    }

    Method (BUMP, 1, NotSerialized)
    {
        If (Arg0 == One)
        {
            Local0 = 41
        }
        Increment (Local0)
        Return (Local0)
    }

    Method (MAIN, 0, NotSerialized)
    {
        Return (PICK (One))
    }
}
