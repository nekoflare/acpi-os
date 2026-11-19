"""Pack flat files into the ASL kernel's boot archive."""

from pathlib import Path
import re
import struct
import sys


def pack(output, files):
    image = bytearray(b"ASLRFS01")
    for path in sorted(files, key=lambda path: path.name):
        name = path.name.encode("ascii")
        if not re.fullmatch(rb"[A-Za-z0-9_][A-Za-z0-9_.-]{0,62}", name):
            raise ValueError(f"Invalid initramfs filename: {path.name}")
        data = path.read_bytes()
        image.extend(struct.pack("<QQ", len(name), len(data)))
        image.extend(name)
        image.extend(data)
        image.extend(bytes(-len(image) % 8))
    output.write_bytes(image)


if __name__ == "__main__":
    pack(Path(sys.argv[1]), map(Path, sys.argv[2:]))
