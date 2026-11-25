DefinitionBlock ("", "DSDT", 2, "AMLAOT", "INITORDR", 1)
{
    Name (EARL, 5)

    // Module-level code runs this before LATE exists, so reading LATE fails
    // and context creation reports the error.
    Method (PEEK, 0, NotSerialized)
    {
        Return (EARL + LATE)
    }

    If (PEEK ()) {}
    Name (LATE, 7)
}
