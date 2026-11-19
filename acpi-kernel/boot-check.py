"""Boot QEMU and exercise the guest's PS/2 keyboard over QMP."""

import json
import os
import re
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time


def wait_for(process, deadline, ready, description):
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError(f"QEMU exited while waiting for {description}")
        if ready():
            return
        time.sleep(0.025)
    raise RuntimeError(f"Timed out waiting for {description}")


def reply(stream):
    while line := stream.readline():
        response = json.loads(line)
        if "event" not in response:
            return response
    raise RuntimeError("QMP disconnected")


def command(stream, name, arguments=None):
    request = {"execute": name}
    if arguments is not None:
        request["arguments"] = arguments
    stream.write(json.dumps(request).encode() + b"\n")
    response = reply(stream)
    if "error" in response or response.get("return"):
        raise RuntimeError(f"QMP command {name} failed: {response}")


def send_keys(stream, keys):
    for key in keys:
        command(stream, "human-monitor-command", {"command-line": f"sendkey {key} 50"})
        time.sleep(0.08)


def boot(serial_path, qemu_log, qemu_command):
    bash_check = os.getenv("BASH_CHECK") == "1"
    with tempfile.TemporaryDirectory(prefix="amlaot-") as temp:
        monitor = Path(temp) / "qmp"
        with serial_path.open("wb") as serial, qemu_log.open("wb") as errors:
            process = subprocess.Popen(
                [*qemu_command, "-display", "none", "-qmp", f"unix:{monitor},server=on,wait=off"],
                stdout=serial,
                stderr=errors,
            )
            try:
                deadline = time.monotonic() + (25 if bash_check else 12)
                wait_for(process, deadline, monitor.exists, "QMP")
                if bash_check:
                    wait_for(
                        process, deadline,
                        lambda: serial_path.read_bytes().endswith((b"$ ", b"# ")),
                        "the interactive Bash prompt",
                    )
                    bash_prompt = b"root@localhost:~# "
                    wait_for(
                        process, deadline,
                        lambda: b"root@localhost:" in serial_path.read_bytes(),
                        "the root@localhost Bash prompt",
                    )
                else:
                    wait_for(
                        process, deadline,
                        lambda: b"What is your name?" in serial_path.read_bytes(),
                        "the userspace prompt",
                    )
                    # Let read block before injecting any keyboard events.
                    time.sleep(0.1)
                    if b"hello.elf exited" in serial_path.read_bytes():
                        raise RuntimeError("Userspace exited before keyboard input")
                with socket.socket(socket.AF_UNIX) as client:
                    client.settimeout(2)
                    client.connect(str(monitor))
                    with client.makefile("rwb", buffering=0) as stream:
                        reply(stream)
                        command(stream, "qmp_capabilities")
                        before = Path(temp) / "before.ppm"
                        command(stream, "screendump", {"filename": str(before)})
                        if bash_check:
                            send_keys(stream, ("e", "c", "h", "x", "backspace", "o",
                                               "spc", "shift-4", "shift-4", "ret"))
                            wait_for(
                                process, deadline,
                                lambda: re.search(rb"\r?\n0\r?\nroot@localhost:", serial_path.read_bytes()) is not None,
                                "Bash reporting PID 0",
                            )
                            send_keys(stream, (*"test", "spc", "minus", "f", "spc", "slash",
                                               *"boot", "minus", *"test", "dot", *"sh", "spc",
                                               "shift-7", "shift-7", "spc", *"echo", "spc",
                                               *"found", "ret"))
                            wait_for(
                                process, deadline,
                                lambda: b"\nfound\n" + bash_prompt in serial_path.read_bytes().replace(b"\r\n", b"\n"),
                                "Bash test -f finding the initramfs file",
                            )
                            send_keys(stream, (*"source", "spc", "slash", *"boot",
                                               "minus", *"test", "dot", *"sh", "ret"))
                            wait_for(
                                process, deadline,
                                lambda: b"Bash sourced the read-only initramfs\n" + bash_prompt in serial_path.read_bytes().replace(b"\r\n", b"\n"),
                                "Bash sourcing the initramfs script",
                            )
                            send_keys(stream, (*"ls", "spc", "slash", "ret"))
                            wait_for(
                                process, deadline,
                                lambda: b"boot-test.sh\nfastfetch\nls\nreadme.txt\nwelcome.txt\nproc\n" + bash_prompt in serial_path.read_bytes().replace(b"\r\n", b"\n"),
                                "Bash running the standalone ls executable",
                            )
                            send_keys(stream, ("slash", *"ls", "spc", "minus", "a", "spc", "slash", "ret"))
                            wait_for(
                                process, deadline,
                                lambda: b".\n..\nboot-test.sh\nfastfetch\nls\nreadme.txt\nwelcome.txt\nproc\n" + bash_prompt in serial_path.read_bytes().replace(b"\r\n", b"\n"),
                                "ls -a showing dot entries",
                            )
                            send_keys(stream, (*"ls", "spc", "slash", *"proc", "ret"))
                            wait_for(
                                process, deadline,
                                lambda: b"meminfo\n" + bash_prompt in serial_path.read_bytes().replace(b"\r\n", b"\n"),
                                "ls enumerating /proc",
                            )
                            send_keys(stream, (*"fastfetch", "ret"))
                            wait_for(
                                process, deadline,
                                lambda: (b"fastfetch " in (output := serial_path.read_bytes())
                                         and b"ASL kernel 0.1.0" in output
                                         and re.search(rb"(?:\x1b\[[0-9;]*m)*root(?:\x1b\[[0-9;]*m)*@(?:\x1b\[[0-9;]*m)*localhost", output)
                                         and re.search(rb"CPU[^\n]*: (?:\x1b\[[0-9;]*m)*[A-Za-z0-9]", output)
                                         and re.search(rb"Memory[^\n]*[0-9] (?:KiB|MiB|GiB) / [1-9]", output)
                                         and output.endswith(bash_prompt)),
                                "Fastfetch reporting the ASL kernel identity, CPU model, and memory",
                            )
                            send_keys(stream, (*"echo", "spc", "shift-4", "shift-slash", "ret"))
                            wait_for(
                                process, deadline,
                                lambda: len(re.findall(rb"\r?\n0\r?\nroot@localhost:", serial_path.read_bytes())) == 2,
                                "Fastfetch exiting successfully",
                            )
                            send_keys(stream, (*"exit", "spc", "0", "ret"))
                        else:
                            send_keys(stream, ("shift-a", "x", "backspace", "d", "a", "ret"))
                        wait_for(
                            process, deadline,
                            lambda: b"asl> " in serial_path.read_bytes(),
                            "the ASL shell prompt",
                        )
                        send_keys(stream, ("l", "x", "backspace", "s", "spc", "slash", "ret"))
                        wait_for(
                            process, deadline,
                            lambda: b"welcome.txt\r\nproc\r\nasl> " in serial_path.read_bytes(),
                            "the initramfs listing",
                        )
                        after = serial_path.with_suffix(".ppm").resolve()
                        command(stream, "screendump", {"filename": str(after)})
                        if before.read_bytes() == after.read_bytes():
                            raise RuntimeError("Framebuffer did not change after keyboard input")
                        send_keys(stream, (*"cat", "spc", "slash", *"welcome", "dot", *"txt", "ret"))
                        send_keys(stream, (*"cat", "spc", *"missing", "ret"))
                        wait_for(
                            process, deadline,
                            lambda: b"File not found\r\nasl> " in serial_path.read_bytes(),
                            "the missing-file response and next prompt",
                        )
                        output = serial_path.read_bytes()
                        if os.getenv("MLIBC_CHECK") == "1":
                            if b"mlibc C program verified fork, TLS, allocation, and console I/O\n" not in output:
                                raise RuntimeError("The mlibc C program did not report success")
                        for expected in (
                            b"readme.txt\r\nwelcome.txt\r\nproc\r\nasl> ",
                            b"Welcome to the ASL kernel shell.\r\nasl> ",
                        ):
                            if expected not in output:
                                raise RuntimeError(f"Missing shell output: {expected!r}")
            finally:
                if process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(timeout=2)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait()


if __name__ == "__main__":
    try:
        boot(Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3:])
    except (OSError, RuntimeError) as error:
        sys.exit(str(error))
