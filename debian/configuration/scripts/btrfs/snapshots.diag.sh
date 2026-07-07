#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=btrfs.env
source "${SCRIPT_DIR}/btrfs.env"

mounted_by_script=0

cleanup() {
    if [[ "$mounted_by_script" -eq 1 ]]; then
        echo
        echo "Unmounting temporary Btrfs mount: $BTRFS_MNT"
        umount "$BTRFS_MNT" || true
    fi
}
trap cleanup EXIT

die() {
    echo "ERROR: $*" >&2
    exit 1
}

section() {
    echo
    echo "===== $* ====="
}

require_root() {
    [[ "${EUID}" -eq 0 ]] || die "Run as root"
}

require_root

section "Configuration"
cat <<EOF
BTRFS_DEV       = $BTRFS_DEV
BTRFS_MNT       = $BTRFS_MNT
ROOT_SUBVOL     = $ROOT_SUBVOL
SNAPSHOT_ROOT   = $SNAPSHOT_ROOT
SWAP_SUBVOL     = $SWAP_SUBVOL
SWAP_MOUNT      = $SWAP_MOUNT
SWAPFILE        = $SWAPFILE
SWAP_SIZE       = $SWAP_SIZE
BOOT_SRC        = $BOOT_SRC
EFI_SRC         = $EFI_SRC
BOOT_DST        = $BOOT_DST
EFI_DST         = $EFI_DST
EOF

section "Block device"
if [[ -b "$BTRFS_DEV" ]]; then
    lsblk -f "$BTRFS_DEV"
else
    die "Device does not exist or is not a block device: $BTRFS_DEV"
fi

section "Current Btrfs and boot mounts"
findmnt -t btrfs || true
echo
findmnt "$BTRFS_MNT" || true
findmnt /boot || true
findmnt /boot/efi || true
findmnt "$SWAP_MOUNT" || true

section "Mounting Btrfs top-level"
mkdir -p "$BTRFS_MNT"

if mountpoint -q "$BTRFS_MNT"; then
    echo "Already mounted: $BTRFS_MNT"
else
    mount -o subvolid=5 "$BTRFS_DEV" "$BTRFS_MNT"
    mounted_by_script=1
    echo "Mounted: $BTRFS_DEV -> $BTRFS_MNT"
fi

section "Btrfs filesystem usage"
btrfs filesystem usage "$BTRFS_MNT" || true

section "Btrfs subvolumes"
btrfs subvolume list "$BTRFS_MNT" || true

section "Expected paths"
for path in \
    "$BTRFS_MNT/$ROOT_SUBVOL" \
    "$BTRFS_MNT/$SNAPSHOT_ROOT" \
    "$BTRFS_MNT/$SWAP_SUBVOL" \
    "$SWAP_MOUNT" \
    "$SWAPFILE" \
    "/boot" \
    "/boot/efi"
do
    if [[ -e "$path" ]]; then
        echo "OK      $path"
    else
        echo "MISSING $path"
    fi
done

section "Snapshot backup list"
SNAPSHOT_DIR="$BTRFS_MNT/$SNAPSHOT_ROOT"

if [[ -d "$SNAPSHOT_DIR" ]]; then
    printf "%-22s %-8s %-8s %-8s %-20s\n" "BACKUP_ID" "ROOTFS" "BOOT" "EFI" "CREATED"
    printf "%-22s %-8s %-8s %-8s %-20s\n" "---------" "------" "----" "---" "-------"

    find "$SNAPSHOT_DIR" -mindepth 1 -maxdepth 1 -type d | sort | while read -r backup_dir; do
        backup_id="$(basename "$backup_dir")"

        has_rootfs="no"
        has_boot="no"
        has_efi="no"

        [[ -d "$backup_dir/$ROOT_SUBVOL" ]] && has_rootfs="yes"
        [[ -d "$backup_dir/boot" ]] && has_boot="yes"
        [[ -d "$backup_dir/efi" ]] && has_efi="yes"

        created="$(stat -c '%y' "$backup_dir" | cut -d'.' -f1)"

        printf "%-22s %-8s %-8s %-8s %-20s\n" \
            "$backup_id" "$has_rootfs" "$has_boot" "$has_efi" "$created"
    done
else
    echo "Snapshot directory does not exist: $SNAPSHOT_DIR"
fi

section "Swap status"
swapon --show || true

section "fstab entries"
grep -E 'btrfs|swap|/boot|efi' /etc/fstab || true

section "Kernel command line"
cat /proc/cmdline || true

section "Done"
echo "Diagnostic check finished."
