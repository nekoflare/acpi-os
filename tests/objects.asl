DefinitionBlock ("", "DSDT", 2, "AMLAOT", "OBJECTS", 1)
{
    Name (GBUF, Buffer (3) {0xAB, 0xC0})
    CreateByteField (GBUF, One, GFLD)
    Name (GSTR, "abcd")
    Name (GPKG, Package (3) {7, "hi", Buffer (2) {8}})
    Name (GPTH, Package (1) {GBUF})
    Name (GREF, Zero)

    Method (SBUF, 1, NotSerialized)
    {
        Return (Buffer (Arg0) {0xAA, 0x01})
    }

    Method (SPKG, 1, NotSerialized)
    {
        Return (Package (Arg0) {9, "hi"})
    }

    Method (SETV, 1, NotSerialized)
    {
        Store (0x11, Arg0)
        Return (Zero)
    }

    Method (REFS, 0, NotSerialized)
    {
        Local0 = 7
        SETV (RefOf (Local0))
        Return (Local0)
    }

    Method (SAVE, 0, NotSerialized)
    {
        Local0 = Buffer (2) {0xA1, 0xB2}
        CopyObject (Index (Local0, One), GREF)
        Return (Zero)
    }

    Method (BUMP, 0, NotSerialized)
    {
        Return (Increment (GREF))
    }

    Method (FLDS, 0, NotSerialized)
    {
        Local0 = Buffer (2) {0xF0, 0x0F}
        CreateField (Local0, 4, 8, XFLD)
        If (ToInteger (XFLD) != 0xFF) { Return (Zero) }
        Store (0x5A, XFLD)
        Return (ToInteger (Local0))
    }

    Method (EDIT, 0, NotSerialized)
    {
        Local0 = Index (GPKG, Zero)
        Store (0x20, Local0)
        If (DerefOf (Index (GPKG, Zero)) != 0x20) { Return (Zero) }
        Store (0x21, Index (GPKG, Zero))
        Return (DerefOf (Local0))
    }

    Method (CSTR, 0, NotSerialized)
    {
        Store ("xy", GSTR)
        Return (GSTR)
    }

    Method (CVRT, 0, NotSerialized)
    {
        Local2 = "ab"
        Local0 = ToBuffer (Local2)
        If (SizeOf (Local0) != 3) { Return (Zero) }
        If (ToString (Local0, Ones) != "ab") { Return (Zero) }
        Local2 = "0x2A"
        Local1 = ToInteger (Local2)
        If (Local1 != 42) { Return (Zero) }
        If (ToHexString (Local1) != Local2) { Return (Zero) }
        If (ToDecimalString (Local1) != "42") { Return (Zero) }
        Local2 = "a"
        If (LNot (LLess (Local2, "aa"))) { Return (Zero) }
        Local1 = Buffer (2) {1, 2}
        Local2 = Buffer (2) {1, 2}
        If (Local1 != Local2) { Return (Zero) }
        Return (SizeOf (Local1))
    }

    Method (INVD, 0, NotSerialized)
    {
        Return (DerefOf (Index (GBUF, 9)))
    }

    Method (MAIN, 0, NotSerialized)
    {
#ifdef STRING_RESULT
        Return (CSTR ())
#else
        Local0 = SBUF (4)
        If (ObjectType (Local0) != 3) { Return (Zero) }
        If (SizeOf (Local0) != 4) { Return (Zero) }
        If (ToInteger (Local0) != 0x01AA) { Return (Zero) }
        Local0 = SPKG (3)
        If (ObjectType (Local0) != 4) { Return (Zero) }
        If (SizeOf (Local0) != 3) { Return (Zero) }
        If (DerefOf (Index (Local0, One)) != "hi") { Return (Zero) }
        If (ObjectType (GBUF) != 3) { Return (Zero) }
        If (ObjectType (GPKG) != 4) { Return (Zero) }
        If (ObjectType (GFLD) != 14) { Return (Zero) }
        If (REFS () != 0x11) { Return (Zero) }
        If (DerefOf (Index (GPTH, Zero)) != "GBUF") { Return (Zero) }
        If (ObjectType (GREF) == One)
        {
            SAVE ()
            If (BUMP () != 0xB3) { Return (Zero) }
        }
        If (FLDS () != 0x05A0) { Return (Zero) }
        If (EDIT () != 0x21) { Return (Zero) }
        If (CVRT () != 2) { Return (Zero) }
        Store (0x31, GFLD)
        Return (DerefOf (Index (GBUF, One)))
#endif
    }
}
