DefinitionBlock ("", "DSDT", 2, "AMLTEST", "IASLDM", 0x00000001)
{
    Scope (\_SB)
    {
        Device (DEV0)
        {
            Name (_HID, EisaId ("PNP0C02"))
            Name (_UID, One)

            Method (_STA, 0, NotSerialized)
            {
                Return (0x0F)
            }
        }
    }
}
