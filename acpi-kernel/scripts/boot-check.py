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


def x11_window_visible(capture, desktop=False):
    magic, dimensions, max_value, pixels = capture.read_bytes().split(b"\n", 3)
    width, height = map(int, dimensions.split())
    if magic != b"P6" or max_value != b"255" or len(pixels) != width * height * 3:
        raise RuntimeError("Unexpected QEMU screendump format")

    # Only the one-shot mlibc probe allows console scrolling after mapping.
    origin_x, window_width, window_height = 96, 208, 112
    color = bytes.fromhex("2ba6a2")
    window_row = color * window_width
    rows = []
    for y in range(height):
        start = (y * width + origin_x) * 3
        end = start + len(window_row)
        if pixels[start:end] == window_row:
            if pixels[start - 3:start] == color or pixels[end:end + 3] == color:
                raise RuntimeError("X11 window pixels extend beyond the requested width")
            rows.append(y)
    if desktop:
        return rows == list(range(192, 192 + window_height)) and pixels[60:63] == bytes.fromhex("1c293e")
    return len(rows) == window_height and rows[-1] - rows[0] == window_height - 1


def dwm_bar_visible(capture):
    magic, dimensions, max_value, pixels = capture.read_bytes().split(b"\n", 3)
    width, height = map(int, dimensions.split())
    if magic != b"P6" or max_value != b"255" or len(pixels) != width * height * 3:
        raise RuntimeError("Unexpected QEMU screendump format")
    # The stock dwm bar has a blue selected tag, dark gray background, and antialiased text.
    bar = pixels[:width * min(height, 24) * 3]
    colors = {bar[i:i + 3] for i in range(0, len(bar), 3)}
    if pixels[:3] != bytes.fromhex("005577") or bytes.fromhex("222222") not in colors or len(colors) <= 12:
        return False

    return True


def capture_desktop(stream, capture, serial_path, bash_prompt, dwm_check):
    if bash_prompt in serial_path.read_bytes():
        raise RuntimeError("Bash became interactive before the desktop closed")
    command(stream, "screendump", {"filename": str(capture)})
    if dwm_check:
        return dwm_bar_visible(capture)
    return x11_window_visible(capture, desktop=True)


def click_dwm_tag(stream, capture):
    def send(event_type, **data):
        command(stream, "input-send-event", {"events": [{"type": event_type, "data": data}]})
        time.sleep(0.06)

    _, dimensions, _, _ = capture.read_bytes().split(b"\n", 3)
    width, height = map(int, dimensions.split())
    for axis, delta in (("x", 29 - width // 2), ("y", 6 - height // 2)):
        while delta:
            step = max(-100, min(100, delta))
            send("rel", axis=axis, value=step)
            delta -= step
    send("btn", down=True, button="left")
    send("btn", down=False, button="left")


def dwm_tag_changed(stream, capture):
    command(stream, "screendump", {"filename": str(capture)})
    pixels = capture.read_bytes().split(b"\n", 3)[3]
    return pixels[:3] == bytes.fromhex("222222") and bytes.fromhex("005577") in pixels[18 * 3:60 * 3]


def boot(serial_path, qemu_log, qemu_command):
    bash_check = os.getenv("BASH_CHECK") == "1"
    dwm_check = os.getenv("DWM_CHECK") == "1"
    mlibc_check = os.getenv("MLIBC_CHECK") == "1"
    with tempfile.TemporaryDirectory(prefix="amlaot-") as temp:
        monitor = Path(temp) / "qmp"
        with serial_path.open("wb") as serial, qemu_log.open("wb") as errors:
            process = subprocess.Popen(
                [*qemu_command, "-display", "none", "-qmp", f"unix:{monitor},server=on,wait=off"],
                stdout=serial,
                stderr=errors,
            )
            try:
                deadline = time.monotonic() + (40 if bash_check else 12)
                wait_for(process, deadline, monitor.exists, "QMP")
                bash_prompt = b"root@localhost:~# "
                if not bash_check:
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
                        if bash_check:
                            wait_for(
                                process, deadline,
                                lambda: capture_desktop(stream, before, serial_path, bash_prompt, dwm_check),
                                "the dwm bar" if dwm_check else "the X11 desktop at its unscrolled position",
                            )
                        else:
                            command(stream, "screendump", {"filename": str(before)})
                            if mlibc_check and not x11_window_visible(before):
                                raise RuntimeError("QEMU display is missing the mapped X11 window")
                        if bash_check or mlibc_check:
                            serial_path.with_suffix(".x11.ppm").write_bytes(before.read_bytes())
                        if dwm_check:
                            click_dwm_tag(stream, before)
                            wait_for(process, deadline, lambda: dwm_tag_changed(stream, before),
                                     "a PS/2 mouse click selecting another dwm tag")
                        if bash_check:
                            send_keys(stream, ("esc",))
                            wait_for(
                                process, deadline,
                                lambda: serial_path.read_bytes().endswith(bash_prompt),
                                "Bash after closing the X11 desktop with Escape",
                            )
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
                            root_listing = (
                                rb"bin\nboot-test\.sh\ndoom\.wad\n"
                                + (rb"dwm-fonts\.conf\ndwm-start\.sh\nfonts\n" if dwm_check else b"")
                                + rb"readme\.txt\nwelcome\.txt\n"
                                + (b"" if dwm_check else rb"x11-start\.sh\n")
                                + rb"dev\nproc\nsys\n"
                                + re.escape(bash_prompt)
                            )
                            send_keys(stream, (*"ls", "spc", "slash", "ret"))
                            wait_for(
                                process, deadline,
                                lambda: re.search(root_listing, serial_path.read_bytes().replace(b"\r\n", b"\n")),
                                "Bash running the standalone ls executable",
                            )
                            send_keys(stream, ("slash", *"bin", "slash", *"ls", "spc", "minus", "a", "spc", "slash", "ret"))
                            wait_for(
                                process, deadline,
                                lambda: re.search(rb"\.\n\.\.\n" + root_listing, serial_path.read_bytes().replace(b"\r\n", b"\n")),
                                "ls -a showing dot entries",
                            )
                            send_keys(stream, (*"ls", "spc", "slash", *"proc", "ret"))
                            wait_for(
                                process, deadline,
                                lambda: b"meminfo\n" + bash_prompt in serial_path.read_bytes().replace(b"\r\n", b"\n"),
                                "ls enumerating /proc",
                            )
                            send_keys(stream, (*"ls", "spc", "slash", *"dev", "ret"))
                            wait_for(
                                process, deadline,
                                lambda: b"fb0\nkbd\nmouse\n" + bash_prompt in serial_path.read_bytes().replace(b"\r\n", b"\n"),
                                "Bash listing the framebuffer and input devices",
                            )
                            send_keys(stream, (*"fbtest", "ret"))
                            wait_for(
                                process, deadline,
                                lambda: b"HSV color space displayed (" in serial_path.read_bytes()
                                        and serial_path.read_bytes().endswith(bash_prompt),
                                "userspace fbdev ioctl and pixel-write test",
                            )
                            send_keys(stream, (*"fastfetch", "ret"))
                            wait_for(
                                process, deadline,
                                lambda: (b"fastfetch " in (output := serial_path.read_bytes())
                                         and b"ASL kernel 0.1.0" in output
                                         and re.search(rb"(?:\x1b\[[0-9;]*m)*root(?:\x1b\[[0-9;]*m)*@(?:\x1b\[[0-9;]*m)*localhost", output)
                                         and re.search(rb"Shell[^\n]*: (?:\x1b\[[0-9;]*m)*bash\b", output)
                                         and re.search(rb"CPU[^\n]*: (?:\x1b\[[0-9;]*m)*[A-Za-z0-9]", output)
                                         and re.search(rb"Memory[^\n]*[0-9] (?:KiB|MiB|GiB) / [1-9]", output)
                                         and output.endswith(bash_prompt)),
                                "Fastfetch reporting the ASL kernel identity, shell, CPU model, and memory",
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
                        listing = b"welcome.txt\r\n"
                        if bash_check and not dwm_check:
                            listing += b"x11-start.sh\r\n"
                        listing += b"dev\r\nproc\r\nsys\r\nasl> "
                        wait_for(
                            process, deadline,
                            lambda: listing in serial_path.read_bytes(),
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
                        if mlibc_check:
                            if b"mlibc C program verified fork, TLS, allocation, and console I/O\n" not in output:
                                raise RuntimeError("The mlibc C program did not report success")
                            if b"X11 setup, geometry, and framebuffer window verified in both byte orders\n" not in output:
                                raise RuntimeError("The guest X11 protocol check did not report success")
                        for expected in (
                            listing,
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
