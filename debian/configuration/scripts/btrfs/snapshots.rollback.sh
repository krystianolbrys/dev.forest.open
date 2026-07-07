#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=btrfs.env
source "${SCRIPT_DIR}/btrfs.env"

BACKUP_ID="${1:-}"

# ===== runtime =====
ROLLBACK_TS="$(date +%F_%H%M%S)"

BACKUP_DIR="${BTRFS_MNT}/${SNAPSHOT_ROOT}/${BACKUP_ID}"
ROOT_CURRENT="${BTRFS_MNT}/${ROOT_SUBVOL}"
ROOT_BROKEN="${BTRFS_MNT}/${ROOT_SUBVOL}.broken.${ROLLBACK_TS}"
ROOT_BACKUP="${BACKUP_DIR}/${ROOT_SUBVOL}"

BOOT_BACKUP_SRC="${BACKUP_DIR}/boot/"
EFI_BACKUP_SRC="${BACKUP_DIR}/efi/"

mounted_by_script=0

cleanup() {
    if [[ "$mounted_by_script" -eq 1 ]]; then
        echo "Unmounting: $BTRFS_MNT"
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

usage() {
    cat >&2 <<EOF
Usage:
  sudo $0 BACKUP_ID

Example:
  sudo $0 2026-07-02_145930

Optional environment overrides:
  BTRFS_DEV=/dev/mapper/vda3_crypt
  BTRFS_MNT=/mnt/btrfs-root
  ROOT_SUBVOL=@rootfs
  SNAPSHOT_ROOT=@snapshots
EOF
    exit 1
}

# ===== main =====
require_root

[[ -n "$BACKUP_ID" ]] || usage
[[ -b "$BTRFS_DEV" ]] || die "Device does not exist or is not block device: $BTRFS_DEV"

mkdir -p "$BTRFS_MNT"

if mountpoint -q "$BTRFS_MNT"; then
    echo "Mountpoint already mounted: $BTRFS_MNT"
else
    echo "Mounting Btrfs top-level: $BTRFS_DEV -> $BTRFS_MNT"
    mount -o subvolid=5 "$BTRFS_DEV" "$BTRFS_MNT"
    mounted_by_script=1
fi

# ===== validation before changes =====
[[ -d "$BACKUP_DIR" ]] || die "Backup directory does not exist: $BACKUP_DIR"
[[ -d "$ROOT_BACKUP" ]] || die "Missing rootfs snapshot in backup: $ROOT_BACKUP"
[[ -d "$ROOT_CURRENT" ]] || die "Current rootfs does not exist: $ROOT_CURRENT"
[[ ! -e "$ROOT_BROKEN" ]] || die "Target broken rootfs already exists: $ROOT_BROKEN"

[[ -d "$BOOT_BACKUP_SRC" ]] || die "Missing /boot backup: $BOOT_BACKUP_SRC"

if [[ -d "$EFI_BACKUP_SRC" ]]; then
    restore_efi=1
else
    restore_efi=0
    echo "WARNING: EFI backup missing: $EFI_BACKUP_SRC — EFI restore will be skipped"
fi

if [[ "$restore_efi" -eq 1 ]]; then
    mountpoint -q "$EFI_DST" || die "$EFI_DST is not a mountpoint; refusing to run rsync --delete on EFI"
fi

echo
echo "Rollback source:"
echo "  $BACKUP_DIR"
echo
echo "Current rootfs will be moved:"
echo "  $ROOT_CURRENT"
echo "  -> $ROOT_BROKEN"
echo
echo "New rootfs will be created from:"
echo "  $ROOT_BACKUP"
echo

# ===== rollback rootfs =====
echo "Moving current rootfs:"
mv "$ROOT_CURRENT" "$ROOT_BROKEN"

echo "Restoring rootfs from snapshot:"
btrfs subvolume snapshot "$ROOT_BACKUP" "$ROOT_CURRENT"

# ===== rollback boot =====
echo "Restoring /boot:"
rsync -aHAXx --numeric-ids --delete "$BOOT_BACKUP_SRC" "$BOOT_DST"

if [[ "$restore_efi" -eq 1 ]]; then
    echo "Restoring /boot/efi:"
    rsync -aHAXx --numeric-ids --delete "$EFI_BACKUP_SRC" "$EFI_DST"
fi

sync

echo
echo "OK: rollback finished."
echo "Old rootfs:"
echo "  $ROOT_BROKEN"
echo
echo "Recommended:"
echo "  sudo reboot"
