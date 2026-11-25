#!/usr/bin/env python3
# Find which file a guest crash happened in. The kernel prints the code bytes
# at the faulting RIP ("  code=<hex>", kernel.asl UXCR); search every regular
# file under the given roots for them and print each match as file and file
# offset, which `addr2line`/`objdump --start-address` take directly.
#   scripts/find-crash-code.py <hex bytes> [root...]
# Default root: ../target/alpine-firefox/root
import os, sys

code = bytes.fromhex(sys.argv[1])
roots = sys.argv[2:] or [os.path.join(os.path.dirname(__file__), "../../target/alpine-firefox/root")]
for root in roots:
    for top, _, names in os.walk(root):
        for name in names:
            path = os.path.join(top, name)
            if os.path.islink(path) or not os.path.isfile(path):
                continue
            with open(path, "rb") as f:
                if f.read(4) != b"\x7fELF":
                    continue
                data = f.read()
            at = data.find(code)
            while at >= 0:
                print("%s offset=%#x" % (path, at + 4))
                at = data.find(code, at + 1)
