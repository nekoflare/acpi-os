# Host side of the HTTP guest tests (run-guest-test.sh "// http-server").
# Serves plain HTTP and HTTPS on 127.0.0.1, which the guest reaches at
# 10.0.2.2, and writes "<http port> <https port>" to argv[1]. The HTTPS server
# uses the certificate argv[2] and key argv[3]. Paths:
#   /hello        "hello from the host\n"
#   /big          1 MiB of pattern bytes; byte i is (i * 7 + (i >> 8)) & 255
#   /gzip         a text page, gzip-encoded when the client accepts it
#   POST /echo    replies "<bytes> <crc32 hex>" of the request body
#   /page         an HTML page whose script dump()s "page loaded over <scheme>"
import gzip, http.server, os, ssl, sys, threading, zlib


def pattern(n):
    return bytes(((i * 7) + (i >> 8)) & 255 for i in range(n))


BIG = pattern(1 << 20)
PAGE = (b"<!DOCTYPE html><title>ACPI OS</title><p>hello from the host</p>"
        b"<script>dump('page loaded over ' + location.protocol + '\\n')</script>\n")
TEXT = b"".join(b"line %d of the compressible page\n" % i for i in range(2000))


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def reply(self, body, headers=(), kind="application/octet-stream"):
        self.send_response(200)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(body)))
        for name, value in headers:
            self.send_header(name, value)
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/hello":
            self.reply(b"hello from the host\n")
        elif self.path == "/page":
            self.reply(PAGE, kind="text/html; charset=utf-8")
        elif self.path == "/big":
            self.reply(BIG)
        elif self.path == "/gzip":
            if "gzip" in self.headers.get("Accept-Encoding", ""):
                self.reply(gzip.compress(TEXT), [("Content-Encoding", "gzip")])
            else:
                self.reply(TEXT)
        else:
            self.send_error(404)

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        if self.path != "/echo":
            self.send_error(404)
            return
        self.reply(b"%d %08x\n" % (len(body), zlib.crc32(body)))

    def log_message(self, format, *args):
        sys.stderr.write("http-test-server: " + format % args + "\n")


class Server(http.server.ThreadingHTTPServer):
    def handle_error(self, request, client_address):
        # Clients that drop the connection (curl refusing the certificate).
        if not isinstance(sys.exc_info()[1], (ConnectionError, ssl.SSLError)):
            super().handle_error(request, client_address)


plain = Server(("127.0.0.1", 0), Handler)
secure = Server(("127.0.0.1", 0), Handler)
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain(sys.argv[2], sys.argv[3])
secure.socket = context.wrap_socket(secure.socket, server_side=True)
for server in (plain, secure):
    threading.Thread(target=server.serve_forever, daemon=True).start()
with open(sys.argv[1] + ".tmp", "w") as f:
    f.write("%d %d\n" % (plain.server_address[1], secure.server_address[1]))
os.rename(sys.argv[1] + ".tmp", sys.argv[1])
threading.Event().wait()
