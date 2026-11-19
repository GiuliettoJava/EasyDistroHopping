# Linux system backup & restore

A **personal tool** I wrote to swap the SSD of my laptop when copying the partition straight to the new drive wasn't an option. Instead of cloning the disk, it saves everything that matters to an external disk, and after a clean install it rebuilds the system on the new SSD: files, programs, desktop look & feel, SSH keys, Claude Code chats, Wi-Fi.

It's shared as-is in case it's useful to someone else in the same situation. Read the scripts before running them on your machine.

## Where it was used and tested

| | |
|---|---|
| Machine | Lenovo ThinkPad T470 (Intel Core i5-6300U, Intel HD Graphics 520, 16 GB RAM) |
| New SSD | Intel SSDPEKKF256G8L 256 GB NVMe, btrfs |
| System | Fedora 44 KDE Plasma 6 → fresh Fedora 44 KDE Plasma 6 |
| Real migration | November 2026: backup to a USB stick (exFAT), clean install on the new SSD, restore from a TTY. All 10 restore steps completed; the only failure was one locally installed RPM (MongoDB Compass) that conflicted with another package and had to be installed by hand. |

That migration was done with the first, Fedora-only version of the scripts. The current version was then generalized:
- on the same machine, the Fedora/`dnf` code paths were checked;
- the `apt` (Debian 13) and `pacman` (Arch) package functions, including AUR helper bootstrap and AUR installs, were tested in containers.

A full backup → restore cycle on Debian/Ubuntu or Arch, and on desktops other than KDE, **has not been done yet**.

## Credits

The KDE look & feel is saved and restored with **[konsave](https://github.com/Prayag2/konsave)** by **Prayag Jain** ([@Prayag2](https://github.com/Prayag2)), GPL-3.0. Thanks for a tool that turns a whole Plasma setup into one portable file: it's what made moving the desktop exactly as it was possible. konsave is installed with pip and called by these scripts; none of its code is included here.

## License

Copyright (C) 2026 GiuliettoJava. Released under the **[GNU General Public License v3.0](LICENSE)** (GPL-3.0): anyone can use, study, share and modify it, also commercially. If you distribute it or a modified version, it must stay under the GPL-3.0 and include its source code. It comes **without any warranty**: you're moving your whole system, so check the backup before wiping the old disk.

Tools the scripts install and call at runtime keep their own licenses (e.g. konsave is GPL-3.0).

---

## Features

- **Distributions**: Fedora / RHEL-based (`dnf`), Debian / Ubuntu-based (`apt`), Arch-based (`pacman`, with AUR support). The package manager is detected automatically.
- **Desktops**: any. KDE Plasma gets extra handling (konsave, KWallet), skipped automatically on other desktops.

**`migrate.sh` is the only script you need to launch**: it lets you pick the external disk, mounts it, and then runs the backup or the restore.

```
.
├── migrate.sh        ← entry point: menu, disk picker, mount
├── lib/
│   ├── backup.sh     ← does the backup   (called by migrate.sh)
│   ├── restore.sh    ← does the restore  (called by migrate.sh)
│   └── common.sh     ← shared helpers: prompts, distro / package manager / desktop detection
└── README.md
```

**Requirements**: `bash`, `sudo`, `tar`, `zstd` (installed automatically on restore if missing), `udisks2` for automatic mounting (otherwise `sudo mount` is used). `pv` is optional (progress bars).

---

## Package manager detection

`lib/common.sh` picks the first one available: `dnf` → `apt` → `pacman`. The distribution, its version/codename and the package manager are saved in the backup (`meta/system-info.env`).

| | dnf (Fedora/RHEL) | apt (Debian/Ubuntu) | pacman (Arch) |
|---|---|---|---|
| Explicitly installed packages | `dnf repoquery --userinstalled` | `apt-mark showmanual` | `pacman -Qqe` |
| Packages from local files | RPMs installed from a file | `.deb` not available in any repo | foreign packages (AUR / local) `pacman -Qqm` |
| Repositories restored | third-party `.repo` files + GPG keys, RPM Fusion (Fedora), COPR version fix | `sources.list.d` entries + keys (`/etc/apt/keyrings`, `trusted.gpg.d`, `/usr/share/keyrings`), codename updated (e.g. `bookworm` → `trixie`) | `[multilib]` enabled; other custom repos reported for manual setup |
| Local packages reinstalled from | `~/Downloads`, `~/Desktop` (`*.rpm`) | `~/Downloads`, `~/Desktop` (`*.deb`) | the **AUR** (see below), or `~/Downloads`, `~/Desktop` (`*.pkg.tar.zst`) for packages that are not in the AUR |
| snapd | from the repos | from the repos | from the AUR (with the AUR helper) |

### AUR (Arch-based systems)

**Backup**
- Records which AUR helper you use (`paru`, `yay`, `pikaur` or `trizen`) in `meta/system-info.env`.
- Saves all foreign packages with versions (`pkgs/foreign-versions.tsv`) and asks the [AUR RPC API](https://aur.archlinux.org/rpc) which of them really exist in the AUR:
  - `pkgs/aur-packages.txt`: packages to reinstall from the AUR;
  - `pkgs/foreign-not-in-aur.txt`: packages installed from a local file or a removed AUR package.
  Only package names are sent. If the AUR can't be reached, every foreign package is treated as an AUR package.
- Helper configs (`~/.config/paru`, `~/.config/yay`) are in the home archive; build caches (`~/.cache/yay`, `~/.cache/paru`) are excluded.

**Restore**
- If no AUR helper is installed, it installs `base-devel` and `git` and builds the same helper you used (`paru-bin`, otherwise `yay-bin`) from the AUR.
- AUR packages are installed non-interactively (no diff/edit prompts, make dependencies removed), in bulk and then one at a time if the bulk install fails.
- The helper itself and `*-debug` packages are skipped (the helper is reinstalled separately, debug packages are rebuilt automatically).
- Packages not in the AUR are installed from a `*.pkg.tar.zst` file in `~/Downloads` / `~/Desktop` if there is one, otherwise reported.
- PGP keys some AUR packages need for source verification are already available, because `~/.gnupg` is restored before packages are installed.

> AUR packages are built from user-submitted PKGBUILDs. The restore installs them without showing the PKGBUILD, trusting the choices you made on the old system; review them afterwards with your helper if you want.

**Different distribution on the new system?** If the backup was made with a different package manager (e.g. Fedora → Arch), the restore asks for confirmation and then **skips repositories and system packages** (names differ between distributions; the lists stay in `pkgs/` for reference). Home, settings, Flatpak, Snap, pip, network, system configs, Docker volumes etc. are still restored.

## Desktop environment detection

The desktop is detected from `XDG_CURRENT_DESKTOP` / `DESKTOP_SESSION`, or (e.g. from a TTY) from the installed session binaries: KDE, GNOME, Xfce, Cinnamon, MATE, LXQt, Budgie.

| | KDE | Other desktops |
|---|---|---|
| KWallet data in the critical archive | ✔ | skipped (GNOME Keyring `~/.local/share/keyrings` is always included) |
| Baloo search index excluded from the home | ✔ | not needed |
| konsave profile export + check | ✔ | skipped |
| konsave import/apply on restore | ✔ only if the backup **and** the new system are KDE | skipped |

On every desktop the settings themselves are restored with the home archive (`~/.config`, `~/.local/share`, ...).

---

## Usage

Keep `migrate.sh` and `lib/` together (a clone of this repo, or the copy inside a backup folder), then:

```bash
bash migrate.sh                         # interactive menu
bash migrate.sh save [DEST]             # backup
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

At the end every archive is test-extracted, the presence of the essentials (SSH key and config, Claude Code projects, konsave profile on KDE) is checked, the scripts and this README are copied into the backup folder (so the disk alone is enough on the new PC) and a `SHA256SUMS` file is written.

> Notes: a tar exit code of 1 ("file changed while reading") is treated as acceptable. konsave exports to a temporary folder on the local disk first, because on exFAT its icon symlinks would be expanded into tens of GB.

The rest of this document is the **restore guide**.

---

## 0. What you need

| What | Details |
|---|---|
| **Backup USB stick/disk** | contains the `system-backup-YYYYMMDD-HHMM/` folder |
| **Another USB stick** for the installer | ≥ 4 GB, it will be wiped. **Do not use the backup one!** |
| Installer ISO | of the distribution you want (to keep the KDE look & feel, pick a KDE edition again) |
| Internet connection | wired is easier: Wi-Fi is only restored later |

The backup folder must contain:

```
system-backup-XXXX/
├── home.tar.zst          ← the whole home
├── critical/             ← SSH, Claude Code, wallets (+ konsave profile on KDE)
├── pkgs/                 ← package lists (system, flatpak, snap, pip...)
├── system/               ← /etc, GRUB theme, /opt, Docker volumes, snap data
├── meta/                 ← info about the old system (distro, package manager, desktop...)
├── migrate.sh            ← launcher menu
├── lib/                  ← backup.sh, restore.sh, common.sh
├── README.md
├── SHA256SUMS            ← checksums to verify integrity
└── backup.log
```

> ⚠️ First of all, open `backup.log` and check that it ends with **"BACKUP COMPLETED AND VERIFIED"**.
> If it doesn't, **do not wipe the old disk**.

---

## 1. Prepare the installer USB stick (from the old PC)

Download the ISO of your distribution and **verify its checksum** against the one published on the official site, e.g. for Fedora 44 KDE:

```bash
cd ~/Downloads
curl -LO https://download.fedoraproject.org/pub/fedora/linux/releases/44/KDE/x86_64/iso/Fedora-KDE-Desktop-Live-44-1.7.x86_64.iso
echo "c8295961d4c41adbf785a31a17c21a971d3b7415fda72dcad0c11c49577bf03a  Fedora-KDE-Desktop-Live-44-1.7.x86_64.iso" | sha256sum -c
```

It must print `OK`. Then write it to the **second** USB stick with balenaEtcher, Fedora Media Writer, Ventoy or `dd`.

---

## 2. Install the new system

1. Power off, remove the old disk (**keep it aside, do not format it**), install the new one.
2. Boot from the installer USB stick and install the system.
3. During installation, **very important**:
   - username: **the same as on the old system** (exactly)
   - password: **the same as on the old system**

   | Why | |
   |---|---|
   | same user | Claude Code chats are tied to the `/home/<user>/...` path |
   | same password | KWallet / GNOME Keyring (saved browser and Wi-Fi passwords) is unlocked at login |

4. Make sure your user can use `sudo` (on Debian, if you set a root password during install: `su -c "usermod -aG sudo $USER"` and log in again).
5. Reboot, log in for the first time and connect to the internet.

---

## 3. Update the system

The ISO may be a few months old, so it's best to update before restoring:

```bash
sudo dnf upgrade --refresh -y                         # Fedora / RHEL
sudo apt update && sudo apt full-upgrade -y           # Debian / Ubuntu
sudo pacman -Syu                                      # Arch
sudo reboot
```

---

## 4. Switch to a text console (TTY)

The restore must run **without a desktop session running**, otherwise the desktop overwrites the freshly restored settings when you log out.

1. **Log out** (do not shut down).
2. At the login screen press **Ctrl + Alt + F3**.
3. Log in with your username and password.

---

## 5. Get the scripts

You need `migrate.sh` and the `lib/` folder. Either:

- **from this repository** (needs internet and `git`):
  ```bash
  git clone https://github.com/<you>/<repo>.git ~/backup-scripts
  cd ~/backup-scripts
  ```
- **or from the backup disk itself**, which already contains a copy. Mount it first:
  ```bash
  lsblk -o NAME,SIZE,FSTYPE,LABEL     # find your disk, e.g. sdb1
  udisksctl mount -b /dev/sdb1         # mounted at /run/media/$USER/<LABEL>
  cd /run/media/$USER/<LABEL>/system-backup-*/
  ```
  (No `udisksctl`? `sudo mkdir -p /mnt/backup && sudo mount /dev/sdb1 /mnt/backup`.)

---

## 6. Run the restore

```bash
bash migrate.sh
```

- Choose **2) RESTORE**
- Pick the backup disk (it is mounted automatically) and the backup folder
- Confirm with **y**
- Enter your **sudo** password when asked (only once)

> Always use `bash ...`, not `./...`: an exFAT disk does not keep the executable permission.

Alternative without the menu:

```bash
bash lib/restore.sh /run/media/$USER/<LABEL>/system-backup-XXXX
```

### What the script does, in order

| # | Step | Details |
|---|---|---|
| — | Checks | checksums, same user, same package manager, no desktop session running (asks before continuing) |
| 1 | Repositories | third-party repos and keys for the detected package manager (see the table above), then refreshes the package database |
| 2 | **Home** | extracts all your files (long part), then re-applies SSH/Claude from the safety copy, fixes ownership (and SELinux labels where enabled) |
| 3 | **SSH** | fixes permissions (`~/.ssh` 700, keys 600) |
| 4 | Packages | explicitly installed packages; on Arch the AUR helper + AUR packages; packages from local files (`~/Downloads`, `~/Desktop`); pip `--user`, pipx |
| 5 | Flatpak & Snap | installs flatpak/snapd if needed; flatpak apps from Flathub or `.flatpak` bundles; snaps on the same channel (classic when needed) + their data snapshot |
| 6 | **Look & feel** | KDE → KDE: imports and applies the konsave `migrazione` profile; otherwise skipped (settings come from the home) |
| 7 | Network | NetworkManager Wi-Fi and VPN connections with their passwords |
| 8 | System | sysctl, udev, sudoers, `/etc/hosts`, manually installed apps in `/opt`, `/usr/local`, hostname, crontab |
| 9 | GRUB | GRUB theme into `/boot/grub2` or `/boot/grub` + regenerates `grub.cfg` (skipped with other bootloaders) |
| 10 | Docker | `docker`/`input` groups, enables Docker, restores Docker volumes |

The script **does not stop on individual errors**: it keeps going and prints the list of what failed at the end. The full log is saved to `~/restore-YYYYMMDD-HHMM.log`.

**Details worth knowing**

- The old `/etc` is extracted to a temporary folder and **only the needed pieces** are copied over; existing files on the new system are never overwritten.
- Before extracting the home, the fresh system's `.config` and `.local` are saved to `~/.home-fresh-before-restore.tar.zst`.
- Packages that don't exist in the new system's repositories are skipped and listed in a single line; the rest is installed in bulk (one at a time if the bulk install fails). Kernel packages are skipped.
- apt: official Debian/Ubuntu sources are left to the new install; only third-party sources are copied.
- pip: on distributions that block `pip install --user` (PEP 668, e.g. Debian 12+, Arch), it retries with `--break-system-packages`.
- `sudoers.d` files are validated with `visudo` before being copied; custom `/etc/hosts` lines are appended; `/opt` folders are restored only if no package recreated them.
- Snap: creates the `/snap` symlink (needed by classic snaps), enables `snapd.socket`, installs each snap from its old tracking channel (base/core snaps are pulled in automatically), then imports and restores the data snapshot.
- VPN connections may need their NetworkManager plugin (openvpn, wireguard...), which is installed only if it was in the package list.
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
| Look & feel | theme, panels, icons and wallpaper should be the same as before |
| GRUB theme | visible at boot |
| SSH | `ssh -T git@github.com` or `ssh <your-server>` |
| Claude Code | `cd ~/path/to/project && claude --resume` → your old chats should show up |
| Wi-Fi | saved networks connect automatically |
| Browsers | passwords and sessions (depends on KWallet / GNOME Keyring) |
| Docker | `docker volume ls` → your volumes should be listed (without `sudo`) |
| Flatpak / Snap | your apps are in the menu; `flatpak list`, `snap list` |

---

## 9. If something goes wrong

**Where to look**
- Restore log: `~/restore-YYYYMMDD-HHMM.log`
- The list of failed steps is at the end of the log

**The KDE look & feel was not applied** (KDE only)
```bash
python3 -m pip install --user konsave        # add --break-system-packages if pip refuses
konsave -i /run/media/$USER/<DISK>/system-backup-*/critical/migrazione.knsv -f
konsave -a migrazione
```
Then log out and back in.

**SSH or Claude chats missing**: restore manually from the safety archive
```bash
zstd -dc /run/media/$USER/<DISK>/system-backup-*/critical/critical.tar.zst | tar -C /home -xpf -
chmod 700 ~/.ssh && chmod 600 ~/.ssh/* && chmod 644 ~/.ssh/*.pub
```

**Recover a single file from the home**
```bash
zstd -dc /run/media/$USER/<DISK>/system-backup-*/home.tar.zst | tar -C /tmp -xpf - "$USER/Desktop/FILENAME"
```

**Look at a system config from the old PC**
```bash
mkdir -p ~/old-etc
zstd -dc /run/media/$USER/<DISK>/system-backup-*/system/etc.tar.zst | sudo tar -C ~/old-etc -xpf -
```

**A package from a local file did not install**: download it again from the official site and install it (`sudo dnf install ./file.rpm`, `sudo apt install ./file.deb`, `sudo pacman -U file.pkg.tar.zst`).

**Moved to a different distribution**: your old package list is in `pkgs/packages-explicit.txt`; install the equivalents by hand.

**Docker says "permission denied"**: you need a new login for the `docker` group to take effect (a reboot is enough).

---

## 10. What is NOT restored

| What | Notes |
|---|---|
| Trash | excluded, unless you chose to include it |
| Cache (`~/.cache`) | rebuilt automatically |
| System packages when changing distribution | names differ: see `pkgs/` |
| Custom pacman repos other than `[multilib]` | reported; add them and their keys by hand |
| Foreign packages that are neither in the AUR nor in `~/Downloads` | reported; see `pkgs/foreign-not-in-aur.txt` |
| Snaps installed from a local `.snap` file | reinstall them manually |
| Docker images / build cache | pull them again with `docker pull` / `docker compose build` |
| Other partitions/disks | only your home and the system files listed above are backed up |

> 🔒 Keep the old disk untouched until you have verified everything in step 8.

Backups made by older versions of these scripts (`fedora-backup-*` folders, Fedora only) are still recognized and can be restored.

