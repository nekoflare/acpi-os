DefinitionBlock ("", "SSDT", 2, "AMLAOT", "HOSTDYNS", 1)
{
    External (SVAL, IntObj)
    Alias (SVAL, DALS)
    Name (DVAL, 41)
    Method (DINC, 0, Serialized, 2)
    {
        Return (Increment (DVAL))
    }
}
