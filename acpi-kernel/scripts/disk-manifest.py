# Decides which staged files pack-xorg-disk.sh must write to the desktop ext4
# volume, from the manifest of the previous pack:
#   disk-manifest.py <staged tree> <old manifest> <new manifest> <changed> <removed> [all]
# Manifest lines are "<sha256>\t<size>\t<mtime ns>\t<path>". A file whose size
# and mtime match its old entry keeps its hash unread; one whose hash matches
# (a restaged but identical artifact) is unchanged too. <changed> lists the
# files to write, <removed> those the old pack wrote that are no longer staged.
# "all" lists every staged file as changed (a full restage).
import hashlib, os, sys

tree, old_path, new_path, changed_path, removed_path = sys.argv[1:6]
everything = sys.argv[6:] == ["all"]

old = {}
if os.path.exists(old_path):
    with open(old_path, encoding="utf-8", errors="surrogateescape") as f:
        for line in f:
            digest, size, mtime, path = line.rstrip("\n").split("\t", 3)
            old[path] = (digest, int(size), int(mtime))


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while chunk := f.read(1 << 20):
            h.update(chunk)
    return h.hexdigest()


new, changed = {}, []
for root, dirs, files in os.walk(tree):
    dirs.sort()
    for name in sorted(files):
        full = os.path.join(root, name)
        if os.path.islink(full):
            continue  # symbolic links are refreshed separately
        path = os.path.relpath(full, tree)
        st = os.stat(full)
        prior = old.get(path)
        if prior and prior[1] == st.st_size and prior[2] == st.st_mtime_ns:
            digest = prior[0]
        else:
            digest = sha256(full)
        new[path] = (digest, st.st_size, st.st_mtime_ns)
        if everything or not prior or prior[0] != digest:
            changed.append(path)

with open(new_path, "w", encoding="utf-8", errors="surrogateescape") as f:
    for path, (digest, size, mtime) in new.items():
        f.write(f"{digest}\t{size}\t{mtime}\t{path}\n")
with open(changed_path, "w", encoding="utf-8", errors="surrogateescape") as f:
    f.writelines(path + "\n" for path in changed)
with open(removed_path, "w", encoding="utf-8", errors="surrogateescape") as f:
    f.writelines(path + "\n" for path in sorted(set(old) - set(new)))
print(f"disk-manifest: {len(changed)} of {len(new)} files changed, "
      f"{len(old.keys() - new.keys())} removed", file=sys.stderr)
