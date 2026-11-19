DefinitionBlock ("", "SSDT", 2, "AMLAOT", "HOSTACTS", 1)
{
    External (KEEP, MutexObj)
    External (NEST, IntObj)
    Name (PVAL, 42)
    Mutex (TEMP, 2)

    Method (INIT, 0, NotSerialized)
    {
        If (Acquire (KEEP, Zero)) { Return (Zero) }
        If (Acquire (TEMP, Zero)) { Return (Zero) }
        If (NEST)
        {
            Return (LoadTable ("SSDT", "AMLAOT", "HOSTACTN", "", "", Zero))
        }
        Return (Timer)
    }

    OperationRegion (REG0, SystemMemory, INIT (), One)
}
