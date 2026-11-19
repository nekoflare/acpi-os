DefinitionBlock ("", "DSDT", 2, "AMLAOT", "MTHREG", 1)
{
    Name (SREF, Zero)

    Method (SAVE, 0, Serialized)
    {
        OperationRegion (TEMP, SystemMemory, 0x2000, One)
        Field (TEMP, ByteAcc, NoLock, Preserve) { ITEM, 8 }
        CopyObject (RefOf (ITEM), SREF)
        Return (Zero)
    }

    Method (READ, 0, NotSerialized)
    {
        Return (DerefOf (SREF))
    }

    Method (WORK, 2, Serialized)
    {
        OperationRegion (MEM0, SystemMemory, Arg0, 4)
        Field (MEM0, ByteAcc, NoLock, Preserve)
        {
            RAW0, 8, BSEL, 8, ISEL, 8, IDAT, 8
        }
        Field (MEM0, ByteAcc, NoLock, Preserve)
        {
            , 4, HIGH, 4
        }
        BankField (MEM0, BSEL, 7, ByteAcc, NoLock, Preserve)
        {
            Offset (3), BNK0, 8
        }
        IndexField (ISEL, IDAT, ByteAcc, NoLock, Preserve)
        {
            Offset (2), IDX0, 8
        }

        If (LNot (CondRefOf (MEM0, Local0))) { Return (One) }
        If (ObjectType (Local0) != 10) { Return (2) }
        RAW0 = 0x04
        HIGH = Arg1
        BNK0 = 0xA1
        If (BNK0 != 0xA1 || BSEL != 7) { Return (3) }
        IDX0 = 0xB2
        If (IDX0 != 0xB2 || ISEL != 2) { Return (4) }
        Return (RAW0)
    }

    Method (MAIN, 0, NotSerialized)
    {
        If (WORK (0x2000, 2) != 0x24) { Return (5) }
        If (WORK (0x2100, 4) != 0x44) { Return (6) }
        Return (42)
    }
}
