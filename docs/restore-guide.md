# Restore guide

[← Back to the README](../README.md)

How to rebuild the system on the new disk, from preparing the installer to the checks after the first reboot.

## 0. What you need

| What | Details |
|---|---|
| **Backup USB stick/disk** | contains the `system-backup-YYYYMMDD-HHMMSS/` folder |
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
├── README.md, docs/
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
   | same user | Claude Code chats are tied to the `/home/<user>/...` path (with another user the files are still restored into your home, but paths inside them won't match) |
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
  git clone https://github.com/GiuliettoJava/EasyDistroHopping.git ~/EasyDistroHopping
  cd ~/EasyDistroHopping
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
| 1 | Repositories | third-party repos and keys for the detected package manager (see [package manager detection](how-it-works.md#package-manager-detection)), then refreshes the package database |
| 2 | **Home** | extracts all your files (long part), then re-applies SSH/Claude from the safety copy, fixes ownership (and SELinux labels where enabled) |
| 3 | **SSH** | fixes permissions (`~/.ssh` 700, keys 600) |
| 4 | Packages | explicitly installed packages; on Arch the AUR helper + AUR packages; packages from local files (`~/Downloads`, `~/Desktop`); pip `--user`, pipx |
| 5 | Flatpak & Snap | installs flatpak/snapd if needed; flatpak apps from Flathub or `.flatpak` bundles; snaps on the same channel (classic when needed) + their data snapshot |
| 6 | **Look & feel** | KDE → KDE: imports and applies the konsave `migrazione` profile; otherwise skipped (settings come from the home) |
| 7 | Network | NetworkManager Wi-Fi and VPN connections with their passwords |
| 8 | System | sysctl, udev, sudoers, `/etc/hosts`, manually installed apps in `/opt`, `/usr/local`, hostname, crontab (cron is installed if missing) |
| 9 | GRUB | GRUB theme into `/boot/grub2` or `/boot/grub` + regenerates `grub.cfg` (skipped with other bootloaders) |
| 10 | Docker | `docker`/`input` groups, enables Docker, restores Docker volumes |

The script **does not stop on individual errors**: it keeps going and prints the list of what failed at the end. The full log is saved to `~/restore-YYYYMMDD-HHMM.log`.

**Details worth knowing**

- The old `/etc` is extracted to a temporary folder and **only the needed pieces** are copied over; existing files on the new system are never overwritten.
- Before extracting the home, the fresh system's `.config` and `.local` are saved to `~/.home-fresh-before-restore.tar.zst`.
- Packages that don't exist in the new system's repositories are skipped and listed in a single line; the rest is installed in bulk (one at a time if the bulk install fails). Kernel packages are skipped.
- apt: official Debian/Ubuntu sources are left to the new install; only third-party sources are copied.
- pip: on distributions that block `pip install --user` (PEP 668, e.g. Debian 12+, Arch), it retries with `--break-system-packages`.
- `sudoers.d` files are validated with `visudo` before being copied; host names from the old `/etc/hosts` are added only if missing (compared by IP and name, so nothing is duplicated); `/opt` folders are restored only if no package recreated them, with their SELinux labels reset where SELinux is enabled.
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

> 🔒 Keep the old disk untouched until you have verified everything in [step 8](#8-checks-after-rebooting).

Backups made by older versions of these scripts (`fedora-backup-*` folders, Fedora only) are still recognized and can be restored.
