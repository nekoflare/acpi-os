# Host side of the TCP guest tests (run-guest-test.sh "// tcp-server").
# Listens on 127.0.0.1, which the guest reaches at 10.0.2.2, and writes
# "<port> <closed port>" to argv[1]. Each connection starts with a command line:
#   echo          echo everything until EOF, then close
#   send N        send N pattern bytes, then close
#   sink          read until EOF, then reply "<bytes> <crc32 hex>" and close
#   rst           close with SO_LINGER 0, which sends a reset
#   wait          read until EOF, then send "bye" and close (half-close)
#   slow N        sleep 2 s, then read N bytes and reply with their crc32
#   idle          read until EOF, without answering
#   sinklog ID    like sink, but keep the reply for "query ID" instead
#   query ID      reply with what sinklog ID saw ("pending" until its EOF)
# Pattern byte i is (i * 7 + (i >> 8)) & 255.
import os, socket, struct, sys, threading, time, zlib


def pattern(n, start=0):
    return bytes(((i * 7) + (i >> 8)) & 255 for i in range(start, start + n))


CHUNK = pattern(1 << 20)


def line(conn):
    data = b""
    while not data.endswith(b"\n"):
        c = conn.recv(1)
        if not c:
            break
        data += c
    return data.decode().split()


def readall(conn, limit=None):
    total, crc = 0, 0
    while limit is None or total < limit:
        d = conn.recv(65536 if limit is None else min(65536, limit - total))
        if not d:
            break
        total += len(d)
        crc = zlib.crc32(d, crc)
    return total, crc


results = {}


def serve(conn):
    try:
        cmd = line(conn)
        if not cmd:
            return
        if cmd[0] == "echo":
            while True:
                d = conn.recv(65536)
                if not d:
                    break
                conn.sendall(d)
        elif cmd[0] == "send":
            n = int(cmd[1])
            sent = 0
            while sent < n:
                k = min(len(CHUNK), n - sent)
                # The pattern restarts every MiB, which is a multiple of 256.
                conn.sendall(CHUNK[:k])
                sent += k
        elif cmd[0] == "sink":
            total, crc = readall(conn)
            conn.sendall(b"%d %08x\n" % (total, crc))
        elif cmd[0] == "rst":
            conn.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
        elif cmd[0] == "wait":
            readall(conn)
            conn.sendall(b"bye\n")
        elif cmd[0] == "slow":
            # A modest receive buffer makes slirp close its window (below the
            # host lo MSS, the host itself would stall on its persist timer).
            conn.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 131072)
            time.sleep(2)
            total, crc = readall(conn, int(cmd[1]))
            conn.sendall(b"%d %08x\n" % (total, crc))
        elif cmd[0] == "idle":
            readall(conn)
        elif cmd[0] == "sinklog":
            results[cmd[1]] = "pending"
            total, crc = readall(conn)
            results[cmd[1]] = "%d %08x" % (total, crc)
        elif cmd[0] == "query":
            conn.sendall(results.get(cmd[1], "none").encode() + b"\n")
    except OSError:
        pass
    finally:
        conn.close()


s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", 0))
s.listen(64)
c = socket.socket()
c.bind(("127.0.0.1", 0))
closed = c.getsockname()[1]
c.close()
open(sys.argv[1] + ".tmp", "w").write("%d %d\n" % (s.getsockname()[1], closed))
os.rename(sys.argv[1] + ".tmp", sys.argv[1])
while True:
    conn, _ = s.accept()
    threading.Thread(target=serve, args=(conn,), daemon=True).start()
