DefinitionBlock ("", "DSDT", 2, "AMLAOT", "MTHNAME", 1)
{
    Method (WORK, 1, NotSerialized)
    {
        Name (BUF0, Buffer (Arg0) {})
        If (SizeOf (BUF0) != Arg0) { Return (One) }
        If (DerefOf (Index (BUF0, Zero)) != Zero) { Return (2) }

        Local0 = 41
        Store (Increment (Local0), Debug)
        Store (Local0, Index (BUF0, Zero))
        If (CondRefOf (BUF0, Local1))
        {
            Return (DerefOf (Index (DerefOf (Local1), Zero)))
        }
        Return (3)
    }

    Method (MAIN, 0, NotSerialized)
    {
        If (WORK (One) != 42) { Return (4) }
        Return (WORK (2))
    }
}
