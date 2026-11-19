DefinitionBlock ("", "DSDT", 2, "AMLAOT", "MIDTEST", 1)
{
    Name (TEXT, "abcdef")
    Name (DATA, Buffer () {0x10, 0x00, 0x30, 0x40})
    Name (DEST, Package () {""})

    Method (BAD0, 1, NotSerialized)
    {
        Return (Mid (Arg0, Zero, One))
    }

    Method (MAIN, 0, NotSerialized)
    {
        If (Mid (TEXT, 2, Ones, Local0) != "cdef") { Return (One) }
        If (Local0 != "cdef") { Return (2) }
        If (Mid (TEXT, Ones, Ones) != "") { Return (3) }
        If (Mid (TEXT, Zero, Zero) != "") { Return (4) }

        Local1 = Mid (DATA, One, 2, Local2)
        If (SizeOf (Local1) != 2 || SizeOf (Local2) != 2) { Return (5) }
        If (DerefOf (Index (Local2, Zero)) != Zero) { Return (6) }
        If (DerefOf (Index (Local2, One)) != 0x30) { Return (7) }
        Store (0xFE, Index (Local2, One))
        If (DerefOf (Index (DATA, 2)) != 0x30) { Return (8) }

        Local3 = Mid (DATA, 4, Ones)
        If (ObjectType (Local3) != 3 || SizeOf (Local3) != Zero) { Return (9) }
        Mid (TEXT, Zero, 2, Index (DEST, Zero))
        If (DerefOf (Index (DEST, Zero)) != "ab") { Return (10) }
        Return (42)
    }
}
