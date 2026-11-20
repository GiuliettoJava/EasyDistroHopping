# EasyDistroHopping

Back up a Linux system to an external disk and rebuild it on a fresh install — the same distro, or another one of the same family (Debian ↔ Ubuntu, Fedora ↔ RHEL clones, Arch ↔ Arch-based): files, packages, desktop look & feel, SSH keys, Wi-Fi. Works with `dnf`, `apt` and `pacman` (+ AUR).

A **personal tool** I wrote to swap the SSD of my laptop when copying the partition straight to the new drive wasn't an option. Instead of cloning the disk, it saves everything that matters to an external disk, and after a clean install it rebuilds the system on the new SSD: files, programs, desktop look & feel, SSH keys, Claude Code chats, Wi-Fi.

It's shared as-is in case it's useful to someone else in the same situation. Read the scripts before running them on your machine.

## Which hops work

Everything in your home (files, dotfiles, app settings, SSH/GPG keys) moves to any distribution. What changes is how much of the *system* can be rebuilt, and that depends on the package manager:

| Hop | Example | Home & settings | System config ¹ | Repositories | System packages | Flatpak · Snap · pip |
|---|---|:---:|:---:|:---:|:---:|:---:|
| **Same distro** | Fedora → Fedora | ✅ | ✅ | ✅ | ✅ | ✅ |
| **Same family** (same package manager) | Debian → Ubuntu · Arch → EndeavourOS · Fedora → AlmaLinux | ✅ | ✅ | 🟡 ² | 🟡 ³ | ✅ |
| **Different family** | Arch → Fedora · Ubuntu → Arch | ✅ | ✅ | ❌ skipped | ❌ skipped ⁴ | ✅ |

¹ hostname, `/etc/hosts`, sysctl, udev rules, sudoers, network connections (Wi-Fi/VPN), `/opt`, `/usr/local`, crontab, Docker volumes, GRUB theme.
² `apt`: third-party repositories are reported instead of copied (their URLs are distro-specific), official ones come from the new system. `dnf`: RPM Fusion and COPR are only set up on Fedora. `pacman`: `[multilib]` is enabled, the AUR works everywhere.
³ installed when a package with the same name exists on the new distribution; the others are listed at the end of the restore.
⁴ names differ between families: the lists stay in the backup (`pkgs/`) to reinstall by hand.

The KDE look & feel (konsave) is applied whenever both systems run KDE Plasma, whatever the distribution.


## Quick start

On the **old PC**, close your browsers and apps, plug in an external disk and run, as your normal user (not with sudo):

```bash
git clone https://github.com/GiuliettoJava/EasyDistroHopping.git
cd EasyDistroHopping
bash migrate.sh save
```

Pick the disk from the list: it is mounted automatically, everything is archived and verified, and the scripts and docs are copied onto the disk too. Check that `backup.log` ends with **"BACKUP COMPLETED AND VERIFIED"** before wiping anything.

On the **new PC**, install the distribution with **the same username and password**, update it, log out, switch to a text console (**Ctrl + Alt + F3**) and run from the backup folder on the disk:

```bash
bash migrate.sh restore
```

Then reboot. The full step-by-step procedure is in the [restore guide](docs/restore-guide.md).

**Requirements**: `bash`, `sudo`, `tar`, `zstd`, and `udisks2` for automatic mounting. `pv` is optional (progress bars).

## Documentation

| | |
|---|---|
| [Usage and backup](docs/usage.md) | commands, disk picker, what gets backed up |
| [Restore guide](docs/restore-guide.md) | from the installer USB stick to the checks after reboot, troubleshooting, what is not restored |
| [How it works](docs/how-it-works.md) | package manager and AUR handling, desktop detection |
| [Try your own distro hop first](docs/try-a-distro-hop.md) | test a migration in a VM with a trial backup, without your files |
| [Testing](docs/testing.md) | the real migration, the VM test harness and its results |

## Tested on

A real Fedora 44 KDE → Fedora 44 KDE migration on a ThinkPad T470, plus full backup → restore cycles in VMs: Fedora → Fedora, Debian → Debian, Arch → Arch and Debian → Ubuntu. Desktops other than KDE and real migrations on Debian/Ubuntu or Arch hardware are not tested yet. Details in [Testing](docs/testing.md).

## Credits

The KDE look & feel is saved and restored with **[konsave](https://github.com/Prayag2/konsave)** by **Prayag Jain** ([@Prayag2](https://github.com/Prayag2)), GPL-3.0. Thanks for a tool that turns a whole Plasma setup into one portable file: it's what made moving the desktop exactly as it was possible. konsave is installed with pip and called by these scripts; none of its code is included here.

## License

Copyright (C) 2026 GiuliettoJava. Released under the **[GNU General Public License v3.0](LICENSE)** (GPL-3.0): anyone can use, study, share and modify it, also commercially. If you distribute it or a modified version, it must stay under the GPL-3.0 and include its source code. It comes **without any warranty**: you're moving your whole system, so check the backup before wiping the old disk.

Tools the scripts install and call at runtime keep their own licenses (e.g. konsave is GPL-3.0).
