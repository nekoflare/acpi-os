DefinitionBlock ("", "SSDT", 2, "AMLAOT", "RUNTIME", 1)
{
    External (VAL0, IntObj)

    Method (BUMP, 1, NotSerialized)
    {
        Add (VAL0, Arg0, VAL0)
        Return (VAL0)
    }

    Alias (BUMP, INC0)

    Method (DELG, 1, NotSerialized)
    {
        Return (INC0 (Arg0))
    }

    Method (DIV0, 1, NotSerialized)
    {
        Return (Divide (One, Arg0))
    }

    Method (FAIL, 1, NotSerialized)
    {
        Return (DIV0 (Arg0))
    }

    Method (LOOP, 1, NotSerialized)
    {
        While (Arg0) { Noop }
        Return (Zero)
    }

    Method (RECU, 1, NotSerialized)
    {
        If (Arg0) { Return (RECU (Arg0)) }
        Return (Zero)
    }
}
