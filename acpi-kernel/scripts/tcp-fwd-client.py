# Host side of "// tcp-fwd: <guest port>": connect to the guest server through
# QEMU's hostfwd on 127.0.0.1:argv[1], send "hello from host", expect it back
# in capitals, then send the verdict "ok" or "bad". Retries until the guest
# listens (slirp drops the host connection while nothing does).
import socket, sys, time

deadline = time.time() + 50
while time.time() < deadline:
    try:
        c = socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=5)
        c.sendall(b"hello from host\n")
        data = b""
        while not data.endswith(b"\n"):
            d = c.recv(100)
            if not d:
                break
            data += d
        if not data:
            c.close()
            time.sleep(0.2)
            continue
        c.sendall(b"ok\n" if data == b"HELLO FROM HOST\n" else b"bad\n")
        c.close()
        break
    except OSError:
        time.sleep(0.2)
