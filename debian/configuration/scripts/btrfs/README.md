# Btrfs OS Snapshots

Small set of helper scripts for local OS rollback on Debian with Btrfs.

This setup backs up:

- readonly snapshot of the `@rootfs` subvolume
- copy of `/boot`
- copy of `/boot/efi`, if it is a separate mountpoint
- optional swapfile setup on a dedicated `@swap` subvolume

This is **not** a disk-failure backup.  
It is a local OS rollback mechanism for cases where the disk still works, but the system was broken by updates, configuration changes, experiments, or user error.

## Files

```text
btrfs.env
create.swap.sh
snapshots.create.sh
snapshots.getlist.sh
snapshots.rollback.sh
snapshots.diag.sh
```

## Configuration

Main configuration is stored in:

```bash
btrfs.env
```

Default values:

```bash
BTRFS_DEV=/dev/mapper/vda3_crypt
BTRFS_MNT=/mnt/btrfs-root

ROOT_SUBVOL=@rootfs
SNAPSHOT_ROOT=@snapshots
SWAP_SUBVOL=@swap

BOOT_SRC=/boot/
EFI_SRC=/boot/efi/

BOOT_DST=/boot/
EFI_DST=/boot/efi/

SWAP_MOUNT=/swap
SWAPFILE=/swap/swapfile
SWAP_SIZE=4g
```

You can either edit `btrfs.env` or override values for a single command:

```bash
sudo BTRFS_DEV=/dev/mapper/other_crypt ./snapshots.getlist.sh
```

Example with different temporary mountpoint:

```bash
sudo BTRFS_MNT=/mnt/test-btrfs ./snapshots.diag.sh
```

## Initial setup

Make scripts executable:

```bash
chmod +x *.sh
```

Check shell syntax:

```bash
bash -n create.swap.sh
bash -n snapshots.create.sh
bash -n snapshots.getlist.sh
bash -n snapshots.rollback.sh
bash -n snapshots.diag.sh
```

## Diagnostics

Run diagnostics before first use:

```bash
sudo ./snapshots.diag.sh
```

The diagnostic script prints:

- current configuration
- Btrfs block device info
- active Btrfs and boot mountpoints
- Btrfs filesystem usage
- Btrfs subvolume list
- expected paths
- snapshot list
- swap status
- relevant `/etc/fstab` entries
- kernel command line

## Create a backup

Run:

```bash
sudo ./snapshots.create.sh
```

By default, the backup ID is generated automatically:

```text
YYYY-MM-DD_HHMMSS
```

Example:

```text
2026-07-02_153000
```

The backup will be created under:

```text
/mnt/btrfs-root/@snapshots/2026-07-02_153000
```

Expected backup layout:

```text
@rootfs/
boot/
efi/
```

The `efi/` directory is created only if `/boot/efi` is a separate mountpoint.

## Create a backup with custom ID

Use:

```bash
sudo BACKUP_ID=test-before-upgrade ./snapshots.create.sh
```

Result:

```text
/mnt/btrfs-root/@snapshots/test-before-upgrade
```

Recommended naming examples:

```text
before-upgrade
before-kernel-change
before-nvidia-test
before-network-refactor
2026-07-02_clean-install
```

## List backups

Run:

```bash
sudo ./snapshots.getlist.sh
```

Example output:

```text
BACKUP_ID              ROOTFS   BOOT     EFI      CREATED
---------              ------   ----     ---      -------
2026-07-02_153000      yes      yes      yes      2026-07-02 15:30:00
before-upgrade         yes      yes      yes      2026-07-02 16:10:00
```

Column meaning:

```text
ROOTFS  - root filesystem snapshot exists
BOOT    - /boot backup exists
EFI     - /boot/efi backup exists
CREATED - directory creation/modification time
```

## Rollback system

Rollback restores:

- `@rootfs` from selected snapshot
- `/boot` from selected backup
- `/boot/efi` from selected backup, if available

Run:

```bash
sudo ./snapshots.rollback.sh BACKUP_ID
```

Example:

```bash
sudo ./snapshots.rollback.sh 2026-07-02_153000
```

During rollback, current rootfs is not deleted. It is moved aside:

```text
@rootfs -> @rootfs.broken.YYYY-MM-DD_HHMMSS
```

Then a new writable `@rootfs` is created from the selected readonly snapshot.

After successful rollback:

```bash
sudo reboot
```

## Rollback safety checks

The rollback script refuses to continue if:

- selected backup directory does not exist
- rootfs snapshot is missing
- current `@rootfs` is missing
- generated `@rootfs.broken.*` target already exists
- `/boot` backup is missing
- EFI backup exists but `/boot/efi` is not a mountpoint

This is intentional.

The script uses `rsync --delete` for `/boot` and `/boot/efi`, so it must not run against a wrong destination.

## Swap setup

Create Btrfs swap subvolume and swapfile:

```bash
sudo ./create.swap.sh
```

Default swap size is defined in `btrfs.env`:

```bash
SWAP_SIZE=4g
```

Override size for one run:

```bash
sudo ./create.swap.sh -s 8g
```

The script creates:

```text
@swap
/swap
/swap/swapfile
```

It also adds required entries to `/etc/fstab`.

Verify swap:

```bash
findmnt /swap
swapon --show
```

## Important notes

### This is not a full backup

These snapshots are stored on the same disk.

If the disk dies, these backups are gone too.

This setup protects against OS breakage, not hardware failure.

### `/boot` is copied with rsync

Btrfs snapshots cover only `@rootfs`.

Because `/boot` and `/boot/efi` are usually outside `@rootfs`, they are copied separately with:

```bash
rsync -aHAXx --numeric-ids
```

The `-x` option prevents crossing filesystem boundaries.

### EFI restore is guarded

Rollback restores EFI only if the backup contains `efi/`.

Additionally, if EFI restore is enabled, `/boot/efi` must be a mountpoint.

This avoids accidentally running `rsync --delete` into a normal directory.

### Use root

All scripts should be run as root:

```bash
sudo ./script-name.sh
```

## Typical workflow

Before risky changes:

```bash
sudo BACKUP_ID=before-upgrade ./snapshots.create.sh
```

Do system changes:

```bash
sudo apt update
sudo apt full-upgrade
```

If the system still works, list backups:

```bash
sudo ./snapshots.getlist.sh
```

If the system is broken but still boots enough to run shell:

```bash
sudo ./snapshots.rollback.sh before-upgrade
sudo reboot
```

## Useful manual checks

Show Btrfs mounts:

```bash
findmnt -t btrfs
```

Show subvolumes:

```bash
sudo btrfs subvolume list /mnt/btrfs-root
```

Show filesystem usage:

```bash
sudo btrfs filesystem usage /mnt/btrfs-root
```

Show swap:

```bash
swapon --show
```

Show fstab:

```bash
grep -E 'btrfs|swap|/boot|efi' /etc/fstab
```

## Cleanup old broken rootfs manually

After successful rollback and verification, old broken rootfs can be removed manually.

Example:

```bash
sudo mount -o subvolid=5 /dev/mapper/vda3_crypt /mnt/btrfs-root
sudo btrfs subvolume delete /mnt/btrfs-root/@rootfs.broken.2026-07-02_160000
```

Do not delete it before confirming the restored system works.

## Cleanup old backups manually

List backups:

```bash
sudo ./snapshots.getlist.sh
```

Delete selected backup:

```bash
sudo mount -o subvolid=5 /dev/mapper/vda3_crypt /mnt/btrfs-root
sudo btrfs subvolume delete /mnt/btrfs-root/@snapshots/BACKUP_ID/@rootfs
sudo rm -rf /mnt/btrfs-root/@snapshots/BACKUP_ID
```

Example:

```bash
sudo btrfs subvolume delete /mnt/btrfs-root/@snapshots/2026-07-02_153000/@rootfs
sudo rm -rf /mnt/btrfs-root/@snapshots/2026-07-02_153000
```

Be careful. This permanently removes the selected local backup.

## Minimal command list

```bash
chmod +x *.sh

sudo ./snapshots.diag.sh
sudo ./snapshots.create.sh
sudo ./snapshots.getlist.sh
sudo ./snapshots.rollback.sh BACKUP_ID

sudo ./create.swap.sh -s 8g
```
