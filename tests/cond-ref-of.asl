DefinitionBlock ("", "DSDT", 2, "AMLAOT", "CONDREF", 1)
{
    External (MISS, UnknownObj)
    Name (DATA, 41)

    Method (MAIN, 0, NotSerialized)
    {
        Local0 = 9
        If (CondRefOf (MISS, Local0)) { Return (One) }
        If (Local0 != 9) { Return (2) }
        If (CondRefOf (DATA, Local1) != Ones) { Return (3) }
        If (DerefOf (Local1) != 41) { Return (4) }
        DATA = 42
        If (DerefOf (Local1) != 42) { Return (5) }
        If (CondRefOf (MAIN, Local2) != Ones) { Return (6) }
        If (ObjectType (Local2) != 8) { Return (7) }
        If (CondRefOf (MAIN) != Ones) { Return (8) }
        Return (42)
    }
}
