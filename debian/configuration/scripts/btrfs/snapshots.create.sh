#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

die() {
    echo "ERROR: $*" >&2
    exit 1
}

usage() {
    echo "Usage: $0 [tag]" >&2
    echo "Example: $0 my.tag" >&2
}

require_root() {
    [[ "${EUID}" -eq 0 ]] || die "Run as root"
}

# shellcheck source=btrfs.env
source "${SCRIPT_DIR}/btrfs.env"

# ===== parameters =====
[[ $# -le 1 ]] || {
    usage
    die "Too many arguments"
}

TAG="${1:-}"

if [[ -n "$TAG" ]]; then
    [[ "$TAG" =~ ^[A-Za-z0-9._-]+$ ]] || die "Invalid tag: use only A-Z a-z 0-9 . _ -"
    BACKUP_ID="${BACKUP_ID:-$(date +%F_%H%M%S)_${TAG}}"
else
    BACKUP_ID="${BACKUP_ID:-$(date +%F_%H%M%S)}"
fi

# ===== paths =====
BACKUP_DIR="${BTRFS_MNT}/${SNAPSHOT_ROOT}/${BACKUP_ID}"
ROOT_SRC="${BTRFS_MNT}/${ROOT_SUBVOL}"
ROOT_DST="${BACKUP_DIR}/${ROOT_SUBVOL}"

BOOT_BACKUP_DST="${BACKUP_DIR}/boot"
EFI_BACKUP_DST="${BACKUP_DIR}/efi"

mounted_by_script=0

cleanup() {
    if [[ "$mounted_by_script" -eq 1 ]]; then
        umount "$BTRFS_MNT" || true
    fi
}

trap cleanup EXIT

# ===== main =====
require_root

[[ -b "$BTRFS_DEV" ]] || die "Device does not exist or is not block device: $BTRFS_DEV"

mkdir -p "$BTRFS_MNT"

if mountpoint -q "$BTRFS_MNT"; then
    echo "Mountpoint already mounted: $BTRFS_MNT"
else
    echo "Mounting Btrfs top-level: $BTRFS_DEV -> $BTRFS_MNT"
    mount -o subvolid=5 "$BTRFS_DEV" "$BTRFS_MNT"
    mounted_by_script=1
fi

[[ -d "$ROOT_SRC" ]] || die "Missing root subvolume/path: $ROOT_SRC"

mkdir -p "${BTRFS_MNT}/${SNAPSHOT_ROOT}"

[[ ! -e "$BACKUP_DIR" ]] || die "Backup already exists: $BACKUP_DIR"

mkdir "$BACKUP_DIR"

echo "Creating readonly rootfs snapshot:"
echo "  $ROOT_SRC -> $ROOT_DST"
btrfs subvolume snapshot -r "$ROOT_SRC" "$ROOT_DST"

echo "Copying /boot:"
mkdir -p "$BOOT_BACKUP_DST"
rsync -aHAXx --numeric-ids "$BOOT_SRC" "$BOOT_BACKUP_DST/"

if mountpoint -q /boot/efi; then
    echo "Copying /boot/efi:"
    mkdir -p "$EFI_BACKUP_DST"
    rsync -aHAXx --numeric-ids "$EFI_SRC" "$EFI_BACKUP_DST/"
else
    echo "WARNING: /boot/efi is not a mountpoint, skipping separate EFI copy"
fi

sync

echo
echo "OK: backup created:"
echo "  $BACKUP_DIR"
