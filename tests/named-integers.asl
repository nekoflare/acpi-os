DefinitionBlock ("", "SSDT", 2, "AMLAOT", "AOTNAMES", 1)
{
    Method (READ, 0, NotSerialized)
    {
        Return (\CNTR)
    }

    Name (CNTR, 41)

    Method (BUMP, 0, NotSerialized)
    {
        Store (Add (CNTR, One), \CNTR)
        Return (CNTR)
    }

    Method (OBSV, 0, NotSerialized)
    {
        Return (Add (CNTR, BUMP ()))
    }
}
