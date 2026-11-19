DefinitionBlock ("", "SSDT", 2, "AMLAOT", "OPTDEF", 1)
{
    Method (MDBG, 1, NotSerialized)
    {
        Return (Arg0 + One)
    }
}
