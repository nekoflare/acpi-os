"""Pack files into the ASL kernel's boot archive."""

from pathlib import Path
import re
import struct
import sys


def pack(output, files):
    image = bytearray(b"ASLRFS01")
    entries = []
    for spec in files:
        name, separator, source = spec.partition("=")
        path = Path(source if separator else name)
        entries.append((name if separator else path.name, path))
    for name, path in sorted(entries, key=lambda entry: entry[0]):
        name = name.encode("ascii")
        component = rb"[A-Za-z0-9_][A-Za-z0-9_.-]*"
        if len(name) > 63 or not re.fullmatch(component + rb"(?:/" + component + rb")?", name):
            raise ValueError(f"Invalid initramfs filename: {name!r}")
        data = path.read_bytes()
        image.extend(struct.pack("<QQ", len(name), len(data)))
        image.extend(name)
        image.extend(data)
        image.extend(bytes(-len(image) % 8))
    output.write_bytes(image)


if __name__ == "__main__":
    pack(Path(sys.argv[1]), sys.argv[2:])
