#!/bin/sh
set -eu

output=$1
kernel=$2
limine=$3
config=$4
shift 4

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
    mkdir -p "$work/apps/$(dirname "$name")"
    cp -p -- "$source" "$work/apps/$name"
done

# Preserve the existing ext4 volume when refreshing the boot image.
# qemu-img refuses to copy the disk while a running VM holds its write lock.
if [ -f "$output" ]; then
    qemu-img convert -f raw -O raw "$output" "$work/disk.img"
    [ "$(stat -c %s "$work/disk.img")" -eq $((194 * 1024 * 1024)) ]
    dd if="$work/disk.img" of="$work/apps.img" bs=1M skip=65 count=128 status=none
    [ "$(blkid -p -s LABEL -o value "$work/apps.img")" = acpi-apps ]
    e2fsck -fn "$work/apps.img"

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
        for spec do
            case "$spec" in
                *=*) name=${spec%%=*} ;;
                *) name=${spec##*/} ;;
            esac
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
                '') ;;
                *) echo "Packaged file conflicts with /$name" >&2; exit 1 ;;
            esac
            debugfs -w -R "write \"$name\" \"/$name\"" "$work/apps.img"
            : > "$work/current"
            debugfs -R "dump \"/$name\" \"$work/current\"" "$work/apps.img"
            cmp "$name" "$work/current"
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
    )
    e2fsck -fn "$work/apps.img"
else
    # The guest driver expects 4 KiB blocks and this explicit feature set.
    truncate -s 128M "$work/apps.img"
    mkfs.ext4 -q -F -b 4096 -I 256 -O none,filetype,extent -L acpi-apps \
        -d "$work/apps" "$work/apps.img"

    truncate -s 194M "$work/disk.img"
    sfdisk --quiet "$work/disk.img" <<'PARTITIONS'
label: gpt
start=2048, size=131072, type=U, name="EFI System"
start=133120, size=262144, type=L, name="acpi-apps"
PARTITIONS
fi

truncate -s 64M "$work/esp.img"
mkfs.fat -F 32 -n ACPIBOOT "$work/esp.img"
mmd -i "$work/esp.img" ::/EFI ::/EFI/BOOT ::/boot ::/boot/limine
mcopy -i "$work/esp.img" "$limine" ::/EFI/BOOT/BOOTX64.EFI
mcopy -i "$work/esp.img" "$config" ::/boot/limine/limine.conf
mcopy -i "$work/esp.img" "$kernel" ::/boot/kernel.elf

dd if="$work/esp.img" of="$work/disk.img" bs=1M seek=1 conv=notrunc status=none
dd if="$work/apps.img" of="$work/disk.img" bs=1M seek=65 conv=notrunc status=none
mv -- "$work/disk.img" "$output"
