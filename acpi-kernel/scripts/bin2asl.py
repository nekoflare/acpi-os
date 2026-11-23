#!/usr/bin/env python3
"""Write a binary file as an ASL Name holding a Buffer: bin2asl.py NAME IN OUT."""
import sys


def main():
    name, source, target = sys.argv[1:4]
    data = open(source, "rb").read()
    lines = [f"    // Generated from {source.split('/')[-1]} by scripts/bin2asl.py.",
             f"    Name ({name}, Buffer ({len(data)}) {{"]
    for offset in range(0, len(data), 16):
        chunk = ", ".join(f"0x{byte:02X}" for byte in data[offset:offset + 16])
        comma = "," if offset + 16 < len(data) else ""
        lines.append(f"        {chunk}{comma}")
    lines.append("    })")
    with open(target, "w") as out:
        out.write("\n".join(lines) + "\n")


if __name__ == "__main__":
    main()
