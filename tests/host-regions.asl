DefinitionBlock ("", "DSDT", 2, "AMLAOT", "HOSTREG", 1)
{
    OperationRegion (MEM0, SystemMemory, 0x2000, 0x10)
    Field (MEM0, WordAcc, NoLock, Preserve)
    {
        RAW0, 16,
        Offset (2),
        RAW1, 16
    }
    Field (MEM0, WordAcc, NoLock, Preserve)
    {
        , 4,
        SPAN, 16
    }
    Field (MEM0, ByteAcc, NoLock, WriteAsOnes)
    {
        Offset (4),
        ONE0, 4
    }
    Field (MEM0, ByteAcc, NoLock, WriteAsZeros)
    {
        Offset (5),
        , 4,
        ZRO0, 4
    }
    Field (MEM0, ByteAcc, NoLock, Preserve)
    {
        Offset (4),
        RAW2, 8,
        RAW3, 8,
        BSEL, 8,
        ISEL, 8,
        DATA, 8
    }
    BankField (MEM0, BSEL, 7, ByteAcc, NoLock, Preserve)
    {
        Offset (9),
        BNK0, 8
    }
    IndexField (ISEL, DATA, ByteAcc, NoLock, Preserve)
    {
        Offset (3),
        IDX0, 8
    }

    Field (MEM0, ByteAcc, Lock, Preserve)
    {
        Offset (10),
        LCK0, 8
    }

    Method (LKIO, 0, NotSerialized)
    {
        LCK0 = 0x66
        Return (LCK0)
    }

    Method (MAIN, 0, NotSerialized)
    {
        RAW0 = 0x1234
        RAW1 = 0x5678
        SPAN = 0xABCD
        If (SPAN != 0xABCD) { Return (One) }
        If (RAW0 != 0xBCD4) { Return (2) }
        If (RAW1 != 0x567A) { Return (3) }
        ONE0 = 6
        ZRO0 = 0xB
        If (RAW2 != 0xF6) { Return (4) }
        If (RAW3 != 0xB0) { Return (5) }
        BNK0 = 0x88
        If (BNK0 != 0x88) { Return (6) }
        If (BSEL != 7) { Return (7) }
        IDX0 = 0x99
        If (IDX0 != 0x99) { Return (8) }
        If (ISEL != 3) { Return (9) }
        Return (42)
    }
}
