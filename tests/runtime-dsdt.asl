DefinitionBlock ("", "DSDT", 1, "AMLAOT", "RUNTIME", 1)
{
    External (BUMP, MethodObj)
    Name (BASE, 41)
    Alias (BASE, VAL0)

    Method (MAIN, 0, NotSerialized)
    {
        Return (Add (Multiply (BUMP (One), 100), VAL0))
    }
}
