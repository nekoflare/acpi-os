DefinitionBlock ("", "DSDT", 2, "AMLAOT", "OSITEST", 1)
{
    Name (STAT, Zero)
    If ((\_OS == "Microsoft Windows NT") && CondRefOf (\_OSI))
    {
        If (\_OSI ("Windows 2015") == Ones) { STAT = 42 }
        If (\_OSI ("AMLAOT Test") == Ones) { STAT = 7 }
    }

    Method (MAIN, 0, NotSerialized)
    {
        If (LNot (CondRefOf (\_OS, Local0))) { Return (3) }
        If (DerefOf (Local0) != "Microsoft Windows NT") { Return (4) }
        If (\_OSI ("Linux") != Zero) { Return (One) }
        If (\_OSI ("Extended Address Space Descriptor") != Ones) { Return (2) }
        Return (STAT)
    }

    Method (READ, 0, NotSerialized)
    {
        Return (STAT)
    }

    Method (OSNM, 0, NotSerialized)
    {
        Return (\_OS)
    }

    Method (OSWR, 0, NotSerialized)
    {
        \_OS = "AMLAOT Test"
        Return (Zero)
    }

    Method (BAD0, 1, NotSerialized)
    {
        Return (\_OSI (Arg0))
    }
}
