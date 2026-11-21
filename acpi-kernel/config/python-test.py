import os
import platform
import sys
from pathlib import Path

print(f"Python interpreter works: {platform.python_version()}")
print(f"Interactive inspect mode: {sys.flags.inspect}")
print(f"PYTHONINSPECT: {'set' if os.getenv('PYTHONINSPECT') else 'unset'}")
print(f"Arguments: {sys.argv!r}")

numbers = [2, 3, 5]
print(f"2 + 3 + 5 = {sum(numbers)}")
print(f"Current directory: {Path.cwd()}")
