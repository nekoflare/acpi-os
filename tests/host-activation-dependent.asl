DefinitionBlock ("", "SSDT", 2, "AMLAOT", "HOSTACTN", 1)
{
    External (PVAL, IntObj)
    Alias (PVAL, CHLD)

    Method (GETC, 0, NotSerialized)
    {
        Return (CHLD)
    }
}
