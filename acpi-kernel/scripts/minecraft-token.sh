#!/bin/sh
# Hands a Minecraft account token to the desktop VM, where `minecraft-login`
# fetches it (the guest reaches this host's loopback at 10.0.2.2).
#   scripts/minecraft-token.sh [port]    default port 25599
# The token comes from Prism Launcher's accounts.json (the active Microsoft
# account) when there is one, otherwise it is pasted: on minecraft.net, signed
# in, it is the value of the bearer_token cookie. Tokens last about 24 hours.
# The token is checked against the Minecraft profile API, then served once,
# on 127.0.0.1 only, for at most five minutes.
set -eu
port="${1:-25599}"

token=
for accounts in "${XDG_DATA_HOME:-$HOME/.local/share}/PrismLauncher/accounts.json" \
    "$HOME/.var/app/org.prismlauncher.PrismLauncher/data/PrismLauncher/accounts.json"; do
    [ -f "$accounts" ] || continue
    token=$(python3 -I -c '
import json, sys
accounts = json.load(open(sys.argv[1]))["accounts"]
accounts = [a for a in accounts if a.get("type") == "MSA" and a.get("ygg", {}).get("token")]
accounts.sort(key=lambda a: not a.get("active"))
print(accounts[0]["ygg"]["token"] if accounts else "")' "$accounts")
    [ -n "$token" ] && { echo "Using the account from $accounts" >&2; break; }
done
if [ -z "$token" ]; then
    printf 'Paste the Minecraft access token (input is hidden): ' >&2
    # Restore echo even when ^C interrupts the prompt.
    trap 'stty echo 2>/dev/null; echo >&2; exit 130' INT TERM
    stty -echo 2>/dev/null || true
    IFS= read -r token || true
    stty echo 2>/dev/null || true
    trap - INT TERM
    echo >&2
fi
token=$(printf '%s' "$token" | tr -d ' \r\n')
[ -n "$token" ] || { echo "No token." >&2; exit 1; }

profile=$(printf 'header = "Authorization: Bearer %s"\n' "$token" |
    curl -sS --max-time 15 -K - https://api.minecraftservices.com/minecraft/profile)
name=$(printf '%s' "$profile" | sed -n 's/.*"name" *: *"\([^"]*\)".*/\1/p')
[ -n "$name" ] || { echo "Minecraft rejected the token: $profile" >&2; exit 1; }
echo "Token is valid for $name. In the VM run: minecraft-login${1:+ $port}" >&2

# The token travels in the environment, not on a command line.
MINECRAFT_TOKEN=$token exec python3 -I -c '
import http.server, os, sys, time
token = os.environ.pop("MINECRAFT_TOKEN").encode()

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/token":
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header("Content-Length", str(len(token)))
        self.end_headers()
        self.wfile.write(token)
        self.server.served = True
    def log_message(self, *args):
        pass

server = http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), Handler)
server.served = False
deadline = time.monotonic() + 300
try:
    while not server.served and time.monotonic() < deadline:
        server.timeout = deadline - time.monotonic()
        server.handle_request()
except KeyboardInterrupt:
    print(file=sys.stderr)
print("Sent the token to the VM." if server.served else "Nobody asked for the token.", file=sys.stderr)
sys.exit(0 if server.served else 1)' "$port"
