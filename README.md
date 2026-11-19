# Fedora KDE backup & restore

Bash scripts to move an entire Fedora KDE system (files, programs, KDE look & feel, SSH, Claude Code chats, Wi-Fi) from an old install to a fresh **Fedora 44 KDE** install.

| Script | What it does |
|---|---|
| `saveRestore.sh` | single entry point with a menu: **save** (backup) or **restore** |
| `backup.sh` | creates `fedora-backup-YYYYMMDD-HHMM/` on an external disk |
| `restore.sh` | restores everything on the new system |

### Usage

Put the three scripts in the same folder (e.g. on the backup USB stick), then:

```bash
bash saveRestore.sh                 # interactive menu
bash saveRestore.sh save [DEST]     # backup
bash saveRestore.sh restore [DIR]   # restore
```

- `save`: if `DEST` is omitted and the script is on an external disk (`/run/media/...`), the backup goes there; otherwise you are asked to pick one of the mounted external disks.
- `restore`: if `DIR` is omitted, it uses the backup folder the script is in, or the most recent `fedora-backup-*` folder next to it.

You can also call the scripts directly:

```bash
bash backup.sh /run/media/$USER/<DISK> [--include-trash]
bash /run/media/$USER/<DISK>/fedora-backup-XXXX/restore.sh
```

### Making the backup (old PC)

- Run it from a terminal as your **normal user, not with sudo**: it asks for the sudo password once at the start and keeps it alive until the end.
- **Close** browsers (Opera, Chrome, Firefox), Discord, Spotify, VS Code, Postman and GitKraken first, so their profiles are saved in a consistent state. The script warns you if any of them is still running.
- The destination must **not** be FAT32 (no files >4 GB; use ext4, btrfs or exFAT) and must **not** be on the same disk as your home (that's the disk you're about to wipe).
- It checks there is enough free space (home size + 2 GB margin, before compression).

**What gets backed up**

| Part | Content |
|---|---|
| `critical/critical.tar.zst` | a separate, redundant copy of SSH, GnuPG, Claude Code, KWallet, git/gh config, konsave, shell rc files, DBeaver, FileZilla, PuTTY, MongoDB — still safe even if the big archive has problems |
| `critical/*.knsv` | konsave profile `migrazione` (current KDE look & feel) and, if present, the older `plasma6_backup` profile |
| `home.tar.zst` | the whole home, with permissions, xattrs and ACLs |
| `pkgs/` | user-installed dnf packages, RPMs installed from local files, COPR repos, flatpak apps and remotes, pip `--user`, pipx, VS Code extensions |
| `system/` | full `/etc` (includes Wi-Fi/VPN connections with passwords, repos, sysctl, GRUB config, sudoers), GRUB themes, `/opt` (except containerd), `/usr/local`, Docker volumes, user crontab |
| `meta/` | user/uid/groups, hostname, Fedora version, locale, disks, fstab, enabled systemd units, network connections, hardware |

Excluded from the home archive, because they are regenerated or reinstalled: `~/.cache`, the Baloo search index, user flatpak installations (`~/.local/share/flatpak`), flatpak app caches, and the Trash (unless `--include-trash` or `y` in the menu). If the destination is inside the home, previous backups are excluded too.

At the end every archive is test-extracted, the presence of the essentials (SSH key and config, Claude Code projects, konsave profile) is checked, the scripts and this README are copied into the backup folder (so the disk alone is enough on the new PC) and a `SHA256SUMS` file is written.

> Notes: a tar exit code of 1 ("file changed while reading") is treated as acceptable. konsave exports to a temporary folder on the local disk first, because on exFAT its icon symlinks would be expanded into tens of GB.

The rest of this document is the **restore guide**.

---

## 0. What you need

| What | Details |
|---|---|
| **Backup USB stick/disk** | contains the `fedora-backup-YYYYMMDD-HHMM/` folder |
| **Another USB stick** for the installer | ≥ 4 GB, it will be wiped. **Do not use the backup one!** |
| Fedora 44 KDE ISO | `Fedora-KDE-Desktop-Live-44-1.7.x86_64.iso` |
| Internet connection | wired is easier: Wi-Fi is only restored later |

The backup folder must contain:

```
fedora-backup-XXXX/
├── home.tar.zst          ← the whole home
├── critical/             ← SSH, Claude Code, wallet + konsave profile (migrazione.knsv)
├── pkgs/                 ← dnf, flatpak, pip package lists
├── system/               ← /etc, GRUB theme, /opt, Docker volumes
├── meta/                 ← info about the old system
├── restore.sh            ← the restore script
├── saveRestore.sh        ← launcher menu
├── SHA256SUMS            ← checksums to verify integrity
└── backup.log
```

> ⚠️ First of all, open `backup.log` and check that it ends with **"BACKUP COMPLETED AND VERIFIED"**.
> If it doesn't, **do not wipe the old SSD**.

---

## 1. Prepare the installer USB stick (from the old PC)

```bash
cd ~/Downloads
curl -LO https://download.fedoraproject.org/pub/fedora/linux/releases/44/KDE/x86_64/iso/Fedora-KDE-Desktop-Live-44-1.7.x86_64.iso
echo "c8295961d4c41adbf785a31a17c21a971d3b7415fda72dcad0c11c49577bf03a  Fedora-KDE-Desktop-Live-44-1.7.x86_64.iso" | sha256sum -c
```

It must print `OK`. Then write it to the **second** USB stick with balenaEtcher or Fedora Media Writer.

---

## 2. Install Fedora

1. Power off, remove the old SSD (**keep it aside, do not format it**), install the new one.
2. Boot from the installer USB stick and install Fedora.
3. During installation, **very important**:
   - username: **the same as on the old system** (exactly)
   - password: **the same as on the old system**

   | Why | |
   |---|---|
   | same user | Claude Code chats are tied to the `/home/<user>/...` path |
   | same password | KWallet (saved browser and Wi-Fi passwords) is unlocked at login |

4. Reboot, log in for the first time and connect to the internet.

---

## 3. Update the system

The ISO may be a few months old, so it's best to update before restoring:

```bash
sudo dnf upgrade --refresh -y
sudo reboot
```

---

## 4. Switch to a text console (TTY)

The restore must run **without Plasma running**, otherwise KDE overwrites the freshly restored settings when you log out.

1. **Log out** (do not shut down).
2. At the login screen press **Ctrl + Alt + F3**.
3. Log in with your username and password.

---

## 5. Mount the backup disk

Plug in the backup disk, then:

```bash
lsblk -o NAME,SIZE,FSTYPE,LABEL
```

Find the row with your disk's `LABEL` (e.g. `sdb1`) and mount it:

```bash
udisksctl mount -b /dev/sdb1
```

It will be mounted at `/run/media/$USER/<DISK>`.

---

## 6. Run the restore

```bash
bash /run/media/$USER/<DISK>/fedora-backup-*/saveRestore.sh
```

- Choose **2) RESTORE**
- Confirm with **y**
- Enter your **sudo** password when asked (only once)

> Always use `bash ...`, not `./...`: an exFAT disk does not keep the executable permission.

Alternative without the menu:

```bash
bash /run/media/$USER/<DISK>/fedora-backup-*/restore.sh
```

### What the script does, in order

| # | Step | Details |
|---|---|---|
| — | Checksum verification | if something doesn't match it asks whether to continue |
| 1 | Repositories | RPM Fusion, Chrome, VS Code, Docker, Opera, MongoDB, COPR |
| 2 | **Home** | extracts all your files (long part), then re-applies SSH/Claude from the safety copy |
| 3 | **SSH** | fixes permissions (`~/.ssh` 700, keys 600) |
| 4 | Packages | user-installed dnf packages, manual RPMs (DBeaver, Compass, Etcher, GitKraken) from `~/Downloads`, pip/pipx |
| 5 | Flatpak | apps from Flathub, plus apps installed from `.flatpak` bundle files |
| 6 | **Konsave** | imports and applies the `migrazione` profile |
| 7 | Network | Wi-Fi and VPN connections with their passwords |
| 8 | System | sysctl, udev, sudoers, `/etc/hosts`, manually installed apps in `/opt` (e.g. Postman), hostname |
| 9 | GRUB | GRUB theme + regenerates `grub.cfg` |
| 10 | Docker | `docker`/`input` groups, enables Docker, restores Docker volumes |

The script **does not stop on individual errors**: it keeps going and prints the list of what failed at the end. The full log is saved to `~/restore-YYYYMMDD-HHMM.log`.

**Details worth knowing**

- If your current user differs from the backup's user, or Plasma is running, it asks before continuing.
- The old `/etc` is extracted to a temporary folder and **only the needed pieces** are copied over; existing files on the new system are never overwritten.
- Before extracting the home, the fresh system's `.config` and `.local` are saved to `~/.home-fresh-before-restore.tar.zst`.
- Third-party repos and their GPG keys are copied from the old `/etc`; if the Fedora version changed, COPR repo version numbers are updated.
- dnf packages are installed in bulk, skipping ones that no longer exist; if that fails, it retries one package at a time. Kernel packages and `gpg-pubkey` are skipped.
- RPMs that were installed from local files are looked up in the restored `~/Downloads` and `~/Desktop`; flatpaks not from Flathub are looked up as `.flatpak` bundles in the same places.
- `sudoers.d` files are validated with `visudo` before being copied; custom `/etc/hosts` lines are appended; `/opt` folders are restored only if no package recreated them.
- VPN connections may need their NetworkManager plugin (openvpn, wireguard...), which is installed only if it was in the dnf package list.
- The original GRUB config is saved as `/etc/default/grub.pre-restore` before the theme line is applied.
- System services that were enabled on the old system and are disabled here get enabled.

---

## 7. Reboot

When the script finishes:

```bash
sudo reboot
```

---

## 8. Checks after rebooting

| What | How to check |
|---|---|
| KDE look & feel | theme, panels, icons and wallpaper should be the same as before |
| GRUB theme | visible at boot |
| SSH | `ssh -T git@github.com` or `ssh <your-server>` |
| Claude Code | `cd ~/path/to/project && claude --resume` → your old chats should show up |
| Wi-Fi | saved networks connect automatically |
| Browsers | Opera/Chrome with passwords and sessions (depends on KWallet) |
| Docker | `docker volume ls` → your volumes should be listed (without `sudo`) |
| Flatpak | your apps are in the menu |

---

## 9. If something goes wrong

**Where to look**
- Restore log: `~/restore-YYYYMMDD-HHMM.log`
- The list of failed steps is at the end of the log

**The KDE look & feel was not applied**
```bash
python3 -m pip install --user konsave
konsave -i /run/media/$USER/<DISK>/fedora-backup-*/critical/migrazione.knsv -f
konsave -a migrazione
```
Then log out and back in.

**SSH or Claude chats missing**: restore manually from the safety archive
```bash
zstd -dc /run/media/$USER/<DISK>/fedora-backup-*/critical/critical.tar.zst | tar -C /home -xpf -
chmod 700 ~/.ssh && chmod 600 ~/.ssh/* && chmod 644 ~/.ssh/*.pub
```

**Recover a single file from the home**
```bash
zstd -dc /run/media/$USER/<DISK>/fedora-backup-*/home.tar.zst | tar -C /tmp -xpf - "$USER/Desktop/FILENAME"
```

**Look at a system config from the old PC**
```bash
mkdir -p ~/old-etc
zstd -dc /run/media/$USER/<DISK>/fedora-backup-*/system/etc.tar.zst | sudo tar -C ~/old-etc -xpf -
```

**A manual RPM did not install**: download it again from the official site and install it with `sudo dnf install ./file.rpm`.

**Docker says "permission denied"**: you need a new login for the `docker` group to take effect (a reboot is enough).

---

## 10. What is NOT restored

| What | Notes |
|---|---|
| Trash | excluded, unless you chose to include it |
| Cache (`~/.cache`) | rebuilt automatically |
| Docker images / build cache | pull them again with `docker pull` / `docker compose build` |
| Other partitions/disks | only your home and the system files listed above are backed up |

> 🔒 Keep the old SSD untouched until you have verified everything in step 8.
