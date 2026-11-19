DefinitionBlock ("", "DSDT", 2, "AMLAOT", "CONCAT", 1)
{
    Name (LHS0, "ab")
    Name (RHS0, "cd")
    Name (INT0, 0x12)
    Name (DATA, Buffer () {0x00, 0xAF})
    Name (DEST, Package () {""})

    Method (MAIN, 0, NotSerialized)
    {
        If (Concatenate (LHS0, RHS0, Local0) != "abcd") { Return (One) }
        If (Local0 != "abcd") { Return (2) }
        If (Concatenate (LHS0, 0xAB) != "abab") { Return (3) }
        If (Concatenate (LHS0, DATA) != "ab0x00,0xAF") { Return (4) }

        Local1 = Concatenate (DATA, LHS0)
        If (Local1 != Buffer () {0x00, 0xAF, 0x61, 0x62, 0x00}) { Return (5) }
        Local2 = ToBuffer (Ones)
        Local2 = SizeOf (Local2)
        Local3 = Concatenate (INT0, "0x34")
        If (SizeOf (Local3) != (Local2 + Local2)) { Return (6) }
        If (DerefOf (Index (Local3, Zero)) != 0x12) { Return (7) }
        If (DerefOf (Index (Local3, Local2)) != 0x34) { Return (8) }

        Local4 = Mid (DATA, 2, One)
        Local5 = Concatenate (Local4, Local4)
        If (SizeOf (Local5) != Zero) { Return (9) }
        Concatenate (LHS0, RHS0, Index (DEST, Zero))
        If (DerefOf (Index (DEST, Zero)) != "abcd") { Return (10) }
        Return (42)
    }
}
