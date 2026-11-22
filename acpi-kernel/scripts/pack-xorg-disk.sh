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

for spec do
    case "$spec" in
        *=*) name=${spec%%=*}; source=${spec#*=} ;;
        *) name=${spec##*/}; source=$spec ;;
    esac
    if [ -d "$source" ]; then
        find "$source" -type f -print | while IFS= read -r file; do
            relative=${file#"$source"/}
            mkdir -p "$work/apps/$name/$(dirname "$relative")"
            cp -p -- "$file" "$work/apps/$name/$relative"
        done
    else
        mkdir -p "$work/apps/$(dirname "$name")"
        cp -p -- "$source" "$work/apps/$name"
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
        find . -type f -print | while IFS= read -r path; do
            name=${path#./}
            ensure_directory "$(dirname "$name")"
            entry=$(debugfs -R "stat \"/$name\"" "$work/apps.img" 2>/dev/null)
            case "$entry" in
                *"Type: regular"*)
                    : > "$work/current"
                    debugfs -R "dump \"/$name\" \"$work/current\"" "$work/apps.img"
                    if cmp -s "$name" "$work/current"; then
                        continue
                    fi
                    debugfs -w -R "rm \"/$name\"" "$work/apps.img"
                    ;;
                *"Type: symlink"*)
                    # A real binary replaces a former applet link.
                    debugfs -w -R "rm \"/$name\"" "$work/apps.img"
                    ;;
                '') ;;
                *) echo "Packaged file conflicts with /$name" >&2; exit 1 ;;
            esac
            debugfs -w -R "write \"$name\" \"/$name\"" "$work/apps.img"
            : > "$work/current"
            debugfs -R "dump \"/$name\" \"$work/current\"" "$work/apps.img"
            cmp "$name" "$work/current"
        done

        # Remove the prior picom config location from the ext4 image. The
        # bootstrap initramfs owns /etc/fstab, so a disk-root /etc directory
        # collides when ext4 is mounted over the bootstrap root.
        entry=$(debugfs -R 'stat /etc/picom.conf' "$work/apps.img" 2>/dev/null)
        case "$entry" in
            *"Type: regular"*) debugfs -w -R 'rm /etc/picom.conf' "$work/apps.img" ;;
        esac
        entry=$(debugfs -R 'stat /etc' "$work/apps.img" 2>/dev/null)
        case "$entry" in
            *"Type: directory"*)
                contents=$(debugfs -R 'ls -l /etc' "$work/apps.img" 2>/dev/null |
                    awk '$NF != "." && $NF != ".." { print $NF }')
                if [ -n "$contents" ]; then
                    echo "Cannot retire /etc from the desktop ext4 image; it still contains: $contents" >&2
                    exit 1
                fi
                debugfs -w -R 'rmdir /etc' "$work/apps.img"
                ;;
        esac

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

        # Refresh symlinks (busybox applets) in one debugfs batch. rm
        # tolerates missing names so stale links are replaced cleanly.
        {
            find . -type l -print | while IFS= read -r path; do
                name=${path#./}
                ensure_directory "$(dirname "$name")"
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
