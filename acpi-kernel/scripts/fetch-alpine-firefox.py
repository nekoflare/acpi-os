#!/usr/bin/env python3
"""Fetch Alpine's firefox-esr and its dependency closure for the probe (P2).

Downloads the current stable Alpine APKINDEX for main and community, resolves
the packages named on the command line (default: firefox-esr) transitively
through their D: dependencies and the P: provides of other packages, checks
every .apk against the index checksum (SHA-1 of the control segment) and the
datahash in its .PKGINFO (SHA-256 of the data segment), and unpacks the data
into ../target/alpine-firefox/root, with absolute symbolic links made
relative so the tree works under /opt/alpine (P3).

musl is skipped when Alpine's version matches ours (sources/musl.version),
because musl-runtime already provides /lib/ld-musl-x86_64.so.1. If Alpine's
is different it is unpacked too, so P3 ships Alpine's ld-musl under
/opt/alpine.

Environment: ALPINE_MIRROR (default https://dl-cdn.alpinelinux.org/alpine),
ALPINE_BRANCH (default: read from latest-stable, e.g. v3.22).
Usage: scripts/fetch-alpine-firefox.py [package...]
"""
import base64
import hashlib
import io
import os
import re
import shutil
import sys
import tarfile
import urllib.request
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
KERNEL = os.path.dirname(HERE)
OUT = os.path.join(os.path.dirname(KERNEL), "target", "alpine-firefox")
MIRROR = os.environ.get("ALPINE_MIRROR", "https://dl-cdn.alpinelinux.org/alpine").rstrip("/")
ARCH = "x86_64"
REPOS = ("main", "community")


def fetch(url):
    req = urllib.request.Request(url, headers={"User-Agent": "fetch-alpine-firefox"})
    with urllib.request.urlopen(req, timeout=120) as r:
        return r.read()


def gzip_members(data):
    """Split a concatenation of gzip streams into the raw bytes of each."""
    out, pos = [], 0
    while pos < len(data):
        d = zlib.decompressobj(31)
        d.decompress(data[pos:])
        if not d.eof:
            raise ValueError("truncated gzip member")
        end = len(data) - len(d.unused_data)
        out.append(data[pos:end])
        pos = end
    return out


def tar_of(member):
    return tarfile.open(fileobj=io.BytesIO(zlib.decompress(member, 31)), mode="r:")


def parse_index(blob, repo):
    """Return the packages of an APKINDEX.tar.gz as dicts of field -> value."""
    text = None
    for m in gzip_members(blob):
        with tar_of(m) as t:
            for ti in t:
                if ti.name == "APKINDEX":
                    text = t.extractfile(ti).read().decode()
    if text is None:
        raise ValueError(f"{repo}: no APKINDEX in index archive")
    pkgs = []
    for block in text.split("\n\n"):
        fields = {}
        for line in block.splitlines():
            if len(line) > 2 and line[1] == ":":
                fields[line[0]] = line[2:]
        if "P" in fields:
            fields["repo"] = repo
            pkgs.append(fields)
    return pkgs


def dep_name(dep):
    """'so:libfoo.so.1>=2' -> 'so:libfoo.so.1'; '/bin/sh' -> 'cmd:sh'."""
    name = re.split(r"[<>=~]", dep, maxsplit=1)[0]
    if name.startswith("/"):
        name = "cmd:" + name.rsplit("/", 1)[1]
    return name


def resolve(pkgs, roots, skip):
    byname, provides = {}, {}
    for p in pkgs:
        byname.setdefault(p["P"], p)  # main comes first, so it wins
        for prov in p.get("p", "").split():
            name = prov.split("=", 1)[0]
            provides.setdefault(name, []).append(p)

    def provider(name):
        if name in byname:
            return byname[name]
        cands = provides.get(name)
        if not cands:
            return None
        # Highest provider_priority (k:) wins, then the package named like it.
        return max(cands, key=lambda p: int(p.get("k", "0")))

    chosen, missing, queue = {}, [], list(roots)
    while queue:
        dep = queue.pop()
        if dep.startswith("!"):
            continue
        name = dep_name(dep)
        p = provider(name)
        if p is None:
            missing.append(name)
            continue
        if p["P"] in chosen or p["P"] in skip:
            continue
        chosen[p["P"]] = p
        queue.extend(p.get("D", "").split())
    return chosen, sorted(set(missing))


def check_apk(data, want):
    """Return (members, control index) if data matches the index checksum
    (SHA-1 of the control segment) and its own datahash (SHA-256 of the data
    segment); raise ValueError otherwise."""
    try:
        members = gzip_members(data)
        # Signature, control, data; the control segment holds .PKGINFO.
        ctl = next(i for i, m in enumerate(members)
                   if any(ti.name == ".PKGINFO" for ti in tar_of(m)))
        with tar_of(members[ctl]) as t:
            info = t.extractfile(".PKGINFO").read().decode()
    except (zlib.error, tarfile.TarError, StopIteration, UnicodeDecodeError) as e:
        raise ValueError(f"malformed package ({e})")
    if hashlib.sha1(members[ctl]).digest() != want:
        raise ValueError("checksum does not match APKINDEX")
    datahash = re.search(r"^datahash = (\w+)$", info, re.M)
    if len(members) <= ctl + 1 or (
            datahash and hashlib.sha256(members[ctl + 1]).hexdigest() != datahash.group(1)):
        raise ValueError("data segment does not match datahash")
    return members, ctl


def get_apk(p, branch):
    cache = os.path.join(OUT, "apk", branch)
    os.makedirs(cache, exist_ok=True)
    fname = f"{p['P']}-{p['V']}.apk"
    path = os.path.join(cache, fname)
    want = p["C"]
    if not want.startswith("Q1"):
        raise ValueError(f"{fname}: unknown checksum format {want}")
    want = base64.b64decode(want[2:])
    if os.path.exists(path):
        with open(path, "rb") as f:
            try:
                return check_apk(f.read(), want)
            except ValueError:
                pass  # stale or corrupt cache entry: download again
    data = fetch(f"{MIRROR}/{branch}/{p['repo']}/{ARCH}/{fname}")
    try:
        result = check_apk(data, want)
    except ValueError as e:
        raise SystemExit(f"{fname}: {e}")
    with open(path + ".part", "wb") as f:
        f.write(data)
    os.replace(path + ".part", path)
    return result


def unpack(members, ctl, root):
    with tar_of(members[ctl + 1]) as t:
        # 'tar' filter: no paths or link chains outside root, no setuid bits.
        t.extractall(root, filter="tar")


def human(n):
    for unit in ("B", "KiB", "MiB", "GiB"):
        if n < 1024 or unit == "GiB":
            return f"{n:.1f} {unit}" if unit != "B" else f"{n} B"
        n /= 1024


def main():
    roots = sys.argv[1:] or ["firefox-esr"]
    branch = os.environ.get("ALPINE_BRANCH")
    if not branch:
        y = fetch(f"{MIRROR}/latest-stable/releases/{ARCH}/latest-releases.yaml").decode()
        branch = re.search(r"^\s*branch:\s*(\S+)", y, re.M).group(1)
    os.makedirs(OUT, exist_ok=True)

    pkgs = []
    for repo in REPOS:
        blob = fetch(f"{MIRROR}/{branch}/{repo}/{ARCH}/APKINDEX.tar.gz")
        with open(os.path.join(OUT, f"APKINDEX-{branch}-{repo}.tar.gz"), "wb") as f:
            f.write(blob)
        pkgs += parse_index(blob, repo)

    with open(os.path.join(KERNEL, "sources", "musl.version")) as f:
        ours = f.read().strip()
    musl = next(p for p in pkgs if p["P"] == "musl")
    theirs = musl["V"].split("-r", 1)[0]
    skip = {"musl"} if theirs == ours else set()

    chosen, missing = resolve(pkgs, roots, skip)
    if missing:
        print("unresolved dependencies: " + " ".join(missing), file=sys.stderr)
        return 1

    root = os.path.join(OUT, "root")
    shutil.rmtree(root, ignore_errors=True)
    os.makedirs(root)
    download = 0
    for name in sorted(chosen):
        p = chosen[name]
        members, ctl = get_apk(p, branch)
        download += sum(len(m) for m in members)
        unpack(members, ctl, root)

    # The tree is shipped under /opt/alpine, so absolute links such as
    # bin/sh -> /bin/busybox must stay inside it: make them relative.
    for dirpath, dirs, files in os.walk(root):
        for fn in dirs + files:
            fp = os.path.join(dirpath, fn)
            target = os.readlink(fp) if os.path.islink(fp) else ""
            if target.startswith("/"):
                os.unlink(fp)
                os.symlink(os.path.relpath(root + target, dirpath), fp)

    with open(os.path.join(OUT, "manifest.txt"), "w") as f:
        f.write(f"# Alpine {branch}, roots: {' '.join(roots)}\n")
        f.write(f"# musl: alpine {theirs}, ours {ours}, "
                f"{'skipped' if skip else 'shipped'}\n")
        for name in sorted(chosen):
            p = chosen[name]
            f.write(f"{name} {p['V']} {p['repo']}\n")

    size = 0
    for dirpath, _, files in os.walk(root):
        for fn in files:
            fp = os.path.join(dirpath, fn)
            if not os.path.islink(fp):
                size += os.path.getsize(fp)
    ff = next((chosen[r]["V"] for r in roots if r in chosen), "?")
    print(f"Alpine {branch}: {roots[0]} {ff}")
    print(f"musl: alpine {theirs}, ours {ours} -> "
          f"{'skipped' if skip else 'shipping Alpine ld-musl under /opt/alpine'}")
    print(f"{len(chosen)} packages, {human(download)} downloaded, "
          f"{human(size)} unpacked in {root}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
