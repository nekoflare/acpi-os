#!/bin/sh
set -eu

output=$1
kernel=$2
limine=$3
config=$4
shift 4

# 32 GiB image: 1 MiB GPT, 64 MiB ESP, ext4 to 1 MiB before the end (the
# backup GPT lives there). Images are sparse, so unused space costs nothing.
disk_mib=32768
apps_mib=$((disk_mib - 66))

exec 9>"$output.lock"
flock -n 9 || { echo "The desktop disk is in use: $output" >&2; exit 1; }

work=$(mktemp -d "$(cd "$(dirname "$output")" && pwd)/.xorg-disk.XXXXXX")
trap 'rm -rf "$work"' EXIT
mkdir "$work/apps"

# Each argument is name=source, a bare source file, or name->target for a
# symbolic link. Directories keep the symbolic links inside them.
for spec do
    case "$spec" in
        *'->'*)
            name=${spec%%->*}
            mkdir -p "$work/apps/$(dirname "$name")"
            ln -sfn -- "${spec#*->}" "$work/apps/$name"
            continue
            ;;
        *=*) name=${spec%%=*}; source=${spec#*=} ;;
        *) name=${spec##*/}; source=$spec ;;
    esac
    # Reflink copies (btrfs, XFS) are nearly free; cp falls back to a real
    # copy elsewhere. -p keeps the mtimes the manifest compares.
    if [ -d "$source" ]; then
        mkdir -p "$work/apps/$name"
        cp -a --reflink=auto -- "$source/." "$work/apps/$name/"
    else
        mkdir -p "$work/apps/$(dirname "$name")"
        cp -p --reflink=auto -- "$source" "$work/apps/$name"
    fi
done

# busybox applets dispatch on argv[0]. Link every applet that does not
# already have a real binary in the image.
if [ -f "$work/apps/bin/busybox" ]; then
    "$work/apps/bin/busybox" --list | while IFS= read -r applet; do
        if [ ! -e "$work/apps/bin/$applet" ] && [ ! -L "$work/apps/bin/$applet" ]; then
            ln -s /bin/busybox "$work/apps/bin/$applet"
        fi
    done
fi

# Compare the staged tree with the manifest of the last pack (written beside
# the image). XORG_RESTAGE=1 rewrites every file.
manifest="$output.manifest"
[ -f "$output" ] || rm -f "$manifest"
# Without a manifest (or on a restage) also run the one-time migrations below.
full=${XORG_RESTAGE:+1}
[ -f "$manifest" ] || full=1
python3 -I "$(dirname "$0")/disk-manifest.py" "$work/apps" "$manifest" "$work/manifest" \
    "$work/changed" "$work/removed" ${XORG_RESTAGE:+all}

# Preserve the existing ext4 volume when refreshing the boot image.
# qemu-img refuses to copy the disk while a running VM holds its write lock.
if [ -f "$output" ]; then
    qemu-img convert -f raw -O raw "$output" "$work/old-disk.img"
    old_size=$(stat -c %s "$work/old-disk.img")
    case "$old_size" in
        $((194 * 1024 * 1024))) old_apps_size=128 ;;
        $((322 * 1024 * 1024))) old_apps_size=256 ;;
        $((disk_mib * 1024 * 1024))) old_apps_size=$apps_mib ;;
        *) echo "Unexpected Xorg disk image size: $old_size" >&2; exit 1 ;;
    esac
    dd if="$work/old-disk.img" of="$work/apps.img" bs=1M skip=65 count="$old_apps_size" conv=sparse status=none
    rm -f "$work/old-disk.img"
    [ "$(blkid -p -s LABEL -o value "$work/apps.img")" = acpi-apps ]
    e2fsck -fn "$work/apps.img"
    truncate -s "${apps_mib}M" "$work/apps.img"
    resize2fs "$work/apps.img"

    ensure_directory()
    {
        [ "$1" != . ] || return 0
        entry=$(debugfs -R "stat \"/$1\"" "$work/apps.img" 2>/dev/null)
        case "$entry" in
            *"Type: directory"*) return 0 ;;
            '') ;;
            *) echo "Packaged directory conflicts with /$1" >&2; return 1 ;;
        esac
        ensure_directory "$(dirname "$1")"
        debugfs -w -R "mkdir \"/$1\"" "$work/apps.img"
        entry=$(debugfs -R "stat \"/$1\"" "$work/apps.img" 2>/dev/null)
        case "$entry" in *"Type: directory"*) ;; *) return 1 ;; esac
    }

    (
        cd "$work/apps"
        # Write only what changed since the last pack: create the missing
        # parent directories, remove former files (older copies, applet
        # links, files no longer packaged), then write; one debugfs session
        # each. debugfs mkdir on an existing directory leaks an inode whose
        # block stays free in the bitmap (a later write then shares it), so
        # one stat batch finds the directories that are really missing.
        sed 's|/[^/]*$||; t; d' "$work/changed" | sort -u | while IFS= read -r dir; do
            while [ "$dir" != . ]; do printf '%s\n' "$dir"; dir=$(dirname "$dir"); done
        done | sort -u > "$work/dirs"
        awk '{ printf "stat \"/%s\"\n", $0 }' "$work/dirs" > "$work/stat.cmds"
        : > "$work/mkdir.cmds"
        if [ -s "$work/stat.cmds" ]; then
            stdbuf -o0 -e0 debugfs -f "$work/stat.cmds" "$work/apps.img" 2>&1 | awk '
                /^debugfs: stat "/ { finish(); path = substr($0, 16, length($0) - 16); next }
                path != "" && /Type: directory/ { state = "dir" }
                path != "" && /Type: / && !/Type: directory/ { state = "other" }
                path != "" && /File not found by ext2_lookup/ { state = "missing" }
                function finish() {
                    if (path == "") return
                    if (state == "missing") printf "mkdir \"%s\"\n", path
                    else if (state != "dir") { print "Packaged directory conflicts with /" path > "/dev/stderr"; bad = 1 }
                    path = ""; state = ""
                }
                END { finish(); exit bad }' > "$work/mkdir.cmds"
        fi
        cat "$work/removed" "$work/changed" | awk '{ printf "rm \"/%s\"\n", $0 }' > "$work/rm.cmds"
        awk '{ printf "write \"%s\" \"/%s\"\n", $0, $0 }' "$work/changed" > "$work/write.cmds"
        for step in mkdir rm write; do
            [ -s "$work/$step.cmds" ] || continue
            debugfs -w -f "$work/$step.cmds" "$work/apps.img" >/dev/null 2>"$work/$step.err"
            # Anything else, such as rm meeting a directory, is a conflict
            # between a packaged file and the volume.
            if grep -v -e '^debugfs [0-9]' -e '^rm: File not found by ext2_lookup' \
                "$work/$step.err"; then
                echo "debugfs $step failed" >&2
                exit 1
            fi
        done

        if [ -n "$full" ]; then
            # Remove the prior picom config location from the ext4 image. A disk
            # /etc is fine now: the kernel merges it with the bootstrap /etc.
            entry=$(debugfs -R 'stat /etc/picom.conf' "$work/apps.img" 2>/dev/null)
            case "$entry" in
                *"Type: regular"*) debugfs -w -R 'rm /etc/picom.conf' "$work/apps.img" ;;
            esac

            # Java class path directories (loaded as dir/*) must hold only the
            # current jars: drop files the staged tree no longer has, such as
            # the previous Minecraft or LWJGL version's.
            for dir in opt/lwjgl opt/minecraft/libraries; do
                [ -d "$dir" ] || continue
                debugfs -R "ls -p \"/$dir\"" "$work/apps.img" 2>/dev/null |
                    awk -F/ '$6 != "" && $6 != "." && $6 != ".." { print $6 }' |
                    while IFS= read -r file; do
                        [ -e "$dir/$file" ] || debugfs -w -R "rm \"/$dir/$file\"" "$work/apps.img"
                    done
            done

            # Retire the old root-level copies after their /bin replacements
            # are in place. Leave unrelated files at those paths alone.
            printf '\177ELF' > "$work/elf-magic"
            for spec do
                case "$spec" in
                    bin/*=*) legacy=${spec%%=*}; legacy=${legacy#bin/} ;;
                    *) continue ;;
                esac
                case "$legacy" in */*) continue ;; esac
                entry=$(debugfs -R "stat \"/$legacy\"" "$work/apps.img" 2>/dev/null)
                case "$entry" in *"Type: regular"*) ;; *) continue ;; esac
                : > "$work/current"
                debugfs -R "dump \"/$legacy\" \"$work/current\"" "$work/apps.img"
                if head -c 4 "$work/current" | cmp -s "$work/elf-magic" -; then
                    debugfs -w -R "rm \"/$legacy\"" "$work/apps.img"
                    entry=$(debugfs -R "stat \"/$legacy\"" "$work/apps.img" 2>/dev/null)
                    [ -z "$entry" ]
                fi
            done

            # Bash is now installed under its normal command name.
            entry=$(debugfs -R 'stat /bin/bash.elf' "$work/apps.img" 2>/dev/null)
            case "$entry" in
                *"Type: regular"*)
                    : > "$work/current"
                    debugfs -R "dump /bin/bash.elf \"$work/current\"" "$work/apps.img"
                    if head -c 4 "$work/current" | cmp -s "$work/elf-magic" -; then
                        debugfs -w -R 'rm /bin/bash.elf' "$work/apps.img"
                        entry=$(debugfs -R 'stat /bin/bash.elf' "$work/apps.img" 2>/dev/null)
                        [ -z "$entry" ]
                    fi
                    ;;
            esac
        fi

        # Refresh symlinks (busybox applets) in one debugfs batch. rm
        # tolerates missing names so stale links are replaced cleanly.
        find . -type l -print | sed 's|^\./||; s|/[^/]*$||; t; d' | sort -u |
            while IFS= read -r dir; do ensure_directory "$dir"; done
        {
            find . -type l -print | while IFS= read -r path; do
                name=${path#./}
                printf 'rm "/%s"\n' "$name"
                printf 'symlink "/%s" "%s"\n' "$name" "$(readlink "$path")"
            done
        } > "$work/links.cmds"
        if [ -s "$work/links.cmds" ]; then
            debugfs -w -f "$work/links.cmds" "$work/apps.img" 2>&1 |
                grep -v 'rm: File not found' || true
        fi
    )
    e2fsck -fn "$work/apps.img"
else
    # The guest driver expects 4 KiB blocks and this explicit feature set.
    truncate -s "${apps_mib}M" "$work/apps.img"
    mkfs.ext4 -q -F -b 4096 -I 256 -O none,filetype,extent -L acpi-apps \
        -d "$work/apps" "$work/apps.img"
fi

truncate -s "${disk_mib}M" "$work/disk.img"
sfdisk --quiet "$work/disk.img" <<PARTITIONS
label: gpt
start=2048, size=131072, type=U, name="EFI System"
start=133120, size=$((apps_mib * 2048)), type=L, name="acpi-apps"
PARTITIONS

truncate -s 64M "$work/esp.img"
mkfs.fat -F 32 -n ACPIBOOT "$work/esp.img"
mmd -i "$work/esp.img" ::/EFI ::/EFI/BOOT ::/boot ::/boot/limine
mcopy -i "$work/esp.img" "$limine" ::/EFI/BOOT/BOOTX64.EFI
mcopy -i "$work/esp.img" "$config" ::/boot/limine/limine.conf
mcopy -i "$work/esp.img" "$kernel" ::/boot/kernel.elf

dd if="$work/esp.img" of="$work/disk.img" bs=1M seek=1 conv=notrunc status=none
dd if="$work/apps.img" of="$work/disk.img" bs=1M seek=65 conv=notrunc,sparse status=none
mv -- "$work/disk.img" "$output"
mv -- "$work/manifest" "$manifest"
