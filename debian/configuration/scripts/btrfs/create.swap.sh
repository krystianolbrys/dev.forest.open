#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=btrfs.env
source "${SCRIPT_DIR}/btrfs.env"

usage() {
  cat <<EOF
Usage: $0 [-d device] [-m btrfs_root_mount] [-s swap_size]

Options:
  -d  Btrfs device, default: ${BTRFS_DEV}
  -m  Temporary mountpoint for Btrfs top-level, default: ${BTRFS_MNT}
  -s  Swap size, default: ${SWAP_SIZE}

Example:
  sudo $0 -d /dev/mapper/vda3_crypt -m /mnt/btrfs-root -s 8g
EOF
}

while getopts ":d:m:s:h" opt; do
  case "$opt" in
    d) BTRFS_DEV="$OPTARG" ;;
    m) BTRFS_MNT="$OPTARG" ;;
    s) SWAP_SIZE="$OPTARG" ;;
    h) usage; exit 0 ;;
    *) usage; exit 1 ;;
  esac
done

die() {
  echo "ERROR: $*" >&2
  exit 1
}

cleanup() {
  if mountpoint -q "$BTRFS_MNT"; then
    umount "$BTRFS_MNT" || true
  fi
}
trap cleanup EXIT

[[ $EUID -eq 0 ]] || die "Run as root"
[[ -b "$BTRFS_DEV" ]] || die "Device does not exist or is not block device: $BTRFS_DEV"

mkdir -p "$BTRFS_MNT"
mkdir -p "$SWAP_MOUNT"

echo "[1/7] Mounting Btrfs top-level subvolid=5..."
if ! mountpoint -q "$BTRFS_MNT"; then
  mount -o subvolid=5 "$BTRFS_DEV" "$BTRFS_MNT"
fi

echo "[2/7] Creating swap subvolume if missing..."
if ! btrfs subvolume show "$BTRFS_MNT/$SWAP_SUBVOL" >/dev/null 2>&1; then
  btrfs subvolume create "$BTRFS_MNT/$SWAP_SUBVOL"
else
  echo "Subvolume already exists: $SWAP_SUBVOL"
fi

echo "[3/7] Adding /swap mount to /etc/fstab if missing..."
FSTAB_SWAP_MOUNT="$BTRFS_DEV $SWAP_MOUNT btrfs defaults,subvol=$SWAP_SUBVOL,noatime 0 0"

if ! grep -qE "[[:space:]]${SWAP_MOUNT}[[:space:]]+btrfs[[:space:]]" /etc/fstab; then
  echo "$FSTAB_SWAP_MOUNT" >> /etc/fstab
else
  echo "fstab already contains mount entry for $SWAP_MOUNT"
fi

echo "[4/7] Reloading systemd..."
systemctl daemon-reload

echo "[5/7] Mounting /swap..."
mount "$SWAP_MOUNT"

echo "[6/7] Creating Btrfs swapfile if missing..."
if [[ ! -e "$SWAPFILE" ]]; then
  btrfs filesystem mkswapfile --size "$SWAP_SIZE" "$SWAPFILE"
else
  echo "Swapfile already exists: $SWAPFILE"
fi

echo "[7/7] Adding swapfile to /etc/fstab if missing..."
if ! grep -qE "^${SWAPFILE//\//\\/}[[:space:]]+none[[:space:]]+swap[[:space:]]" /etc/fstab; then
  echo "$SWAPFILE none swap defaults 0 0" >> /etc/fstab
else
  echo "fstab already contains swap entry for $SWAPFILE"
fi

swapon "$SWAPFILE" || true

echo
echo "Done."
echo "Verify:"
echo "  findmnt $SWAP_MOUNT"
echo "  swapon --show"
echo "  btrfs subvolume list $BTRFS_MNT"
