#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=btrfs.env
source "${SCRIPT_DIR}/btrfs.env"

mounted_by_script=0

cleanup() {
    if [[ "$mounted_by_script" -eq 1 ]]; then
        umount "$BTRFS_MNT" || true
    fi
}
trap cleanup EXIT

die() {
    echo "ERROR: $*" >&2
    exit 1
}

require_root() {
    [[ "${EUID}" -eq 0 ]] || die "Run as root"
}

require_root

[[ -b "$BTRFS_DEV" ]] || die "Device does not exist or is not block device: $BTRFS_DEV"

mkdir -p "$BTRFS_MNT"

if mountpoint -q "$BTRFS_MNT"; then
    :
else
    mount -o subvolid=5 "$BTRFS_DEV" "$BTRFS_MNT"
    mounted_by_script=1
fi

SNAPSHOT_DIR="${BTRFS_MNT}/${SNAPSHOT_ROOT}"

[[ -d "$SNAPSHOT_DIR" ]] || die "Snapshot directory does not exist: $SNAPSHOT_DIR"

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
