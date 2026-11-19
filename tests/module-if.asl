DefinitionBlock ("", "DSDT", 2, "AMLAOT", "MODIF", 1)
{
    Name (MODE, 2)
    Name (VALU, Zero)
    Method (FLAG, 0, NotSerialized)
    {
        Return (One)
    }
    If (FLAG ())
    {
        If (MODE == 2)
        {
            VALU = 42
        }
        Else
        {
            VALU = 10
        }
    }
    Else
    {
        VALU = 20
    }
    Method (MAIN, 0, NotSerialized)
    {
        Return (VALU)
    }
}
