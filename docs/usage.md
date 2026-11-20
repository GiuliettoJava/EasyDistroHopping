# Usage and backup

[← Back to the README](../README.md)

## Usage

Keep `migrate.sh` and `lib/` together (a clone of this repo, or the copy inside a backup folder), then:

```bash
bash migrate.sh                         # interactive menu
bash migrate.sh save [DEST]             # backup
bash migrate.sh save DEST --no-home     # trial backup without your files (see try-a-distro-hop.md)
bash migrate.sh restore [BACKUP_DIR]    # restore
bash migrate.sh mount                   # only pick and mount a disk
```

Without arguments, `save` and `restore` show the **disk picker**:

```
==> Where should the backup be saved?
  1) /dev/sdb1              931.5G  exfat   BACKUP           (not mounted)
  2) /dev/sdc1               57.3G  ext4    USBSTICK         /run/media/user/USBSTICK
  r) rescan
  p) enter a path manually
  q) quit
```

- Only partitions with a usable filesystem (ext4, btrfs, xfs, f2fs, exFAT, FAT, NTFS, unlocked LUKS) are listed; the disk(s) holding `/`, `/boot` and `/home` are hidden.
- If the chosen disk is not mounted, it is mounted with `udisksctl mount` (falling back to `sudo mount` under `/mnt`).
- **save**: if the disk root is not writable by your user (e.g. a fresh ext4 disk), a `backups/` folder owned by you is created on it. At the end it offers to unmount the disk.
- **restore**: lists the `system-backup-*` folders found on the disk (newest first), marking whether each one finished as *verified*. If `migrate.sh` is run from inside a backup folder, that backup is used directly.

The restore always uses `lib/restore.sh` next to `migrate.sh`, falling back to the copy inside the backup.

To mount a disk by hand instead:

```bash
lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINTS
udisksctl mount -b /dev/sdX1          # mounted at /run/media/$USER/<LABEL>
udisksctl unmount -b /dev/sdX1
```

---

## Making the backup (old PC)

- Run it from a terminal as your **normal user, not with sudo**: it asks for the sudo password once at the start and keeps it alive until the end.
- **Close** browsers (Opera, Chrome, Firefox), Discord, Spotify, VS Code, Postman and GitKraken first, so their profiles are saved in a consistent state. The script warns you if any of them is still running.
- The destination must **not** be FAT32 (no files >4 GB; use ext4, btrfs or exFAT) and must **not** be on the same disk as your home (that's the disk you're about to wipe).
- It checks there is enough free space (home size + 2 GB margin, before compression).

**What gets backed up**

| Part | Content |
|---|---|
| `critical/critical.tar.zst` | a separate, redundant copy of SSH, GnuPG, Claude Code, GNOME Keyring, git/gh config, shell rc files, DBeaver, FileZilla, PuTTY, MongoDB, plus KWallet and konsave config on KDE — still safe even if the big archive has problems |
| `critical/*.knsv` | **KDE only**: konsave profile `migrazione` (current KDE look & feel) and, if present, the older `plasma6_backup` profile |
| `home.tar.zst` | the whole home, with permissions, xattrs and ACLs |
| `pkgs/` | `packages-explicit.txt`, `packages-local.txt`, `packages-all.tsv` (with versions), COPR repos (dnf), flatpak apps and remotes, snap list, pip `--user`, pipx, VS Code extensions |
| `system/` | full `/etc` (includes Wi-Fi/VPN connections with passwords, repos, sysctl, GRUB config, sudoers), GRUB themes (`/boot/grub2` or `/boot/grub`), `/usr/share/keyrings` (apt), `/opt` (except containerd), `/usr/local`, Docker volumes, snap data snapshot (`snap save` + `snap export-snapshot`), user crontab |
| `meta/` | user/uid/groups, hostname, distribution + version + codename, package manager, desktop, locale, disks, fstab, enabled systemd units, network connections, hardware |

Excluded from the home archive, because they are regenerated or reinstalled: `~/.cache`, the Baloo search index (KDE), user flatpak installations (`~/.local/share/flatpak`), flatpak app caches, and the Trash (unless you answer `y` to the Trash question). If the destination is inside the home, previous backups are excluded too.

At the end every archive is test-extracted, the presence of the essentials (SSH key and config, Claude Code projects, konsave profile on KDE) is checked, the scripts, the README and `docs/` are copied into the backup folder (so the disk alone is enough on the new PC) and a `SHA256SUMS` file is written.

> Notes: a tar exit code of 1 ("file changed while reading") is treated as acceptable. konsave exports to a temporary folder on the local disk first, because on exFAT its icon symlinks would be expanded into tens of GB.

Next: [restore guide](restore-guide.md).
