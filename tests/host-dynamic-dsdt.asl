DefinitionBlock ("", "DSDT", 2, "AMLAOT", "HOSTDYNA", 1)
{
    External (DVAL, IntObj)
    External (DALS, IntObj)
    Name (SVAL, 87)
    External (DINC, MethodObj)
    Name (REFS, Zero)
    Name (MREF, Zero)
    Name (HNDL, Zero)
    OperationRegion (TBLE, SystemMemory, 0x3000, 0x1000)

    Method (LDTB, 0, NotSerialized)
    {
        HNDL = LoadTable ("SSDT", "AMLAOT", "HOSTDYNS", "", "", Zero)
        Return (HNDL)
    }

    Method (LDOP, 0, NotSerialized)
    {
        Load (TBLE, HNDL)
        Return (HNDL)
    }

    Method (ULDT, 0, NotSerialized)
    {
        Unload (HNDL)
        Return (Zero)
    }

    Method (MAIN, 0, NotSerialized)
    {
        Return (DINC ())
    }

    Method (SAVE, 0, NotSerialized)
    {
        CopyObject (RefOf (DVAL), REFS)
        Return (Zero)
    }

    Method (SAVA, 0, NotSerialized)
    {
        CopyObject (RefOf (DALS), REFS)
        Return (DALS)
    }

    Method (READ, 0, NotSerialized)
    {
        Return (DerefOf (REFS))
    }

    Method (PRES, 0, NotSerialized)
    {
        If (CondRefOf (DINC, Local0))
        {
            CopyObject (Local0, MREF)
            If (LNot (CondRefOf (DALS, Local1)))
            {
                Return (Zero)
            }
            Return (DerefOf (Local1))
        }
        Return (Zero)
    }

    Method (MTYP, 0, NotSerialized)
    {
        Return (ObjectType (MREF))
    }
}
