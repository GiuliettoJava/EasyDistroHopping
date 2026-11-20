# Testing

[← Back to the README](../README.md)

## Where it was used and tested

**Real migration** — November 2026, with the first, Fedora-only version of the scripts:

| | |
|---|---|
| Machine | Lenovo ThinkPad T470 (Intel Core i5-6300U, Intel HD Graphics 520, 16 GB RAM) |
| New SSD | Intel SSDPEKKF256G8L 256 GB NVMe, btrfs |
| Hop | Fedora 44 KDE Plasma 6 → fresh Fedora 44 KDE Plasma 6 |
| How | backup to a USB stick (exFAT), clean install on the new SSD, restore from a TTY |
| Result | ✅ all 10 restore steps completed; the only failure was one locally installed RPM (MongoDB Compass) that conflicted with another package and had to be installed by hand |

**Virtual machines** — full backup → restore cycles of the current version, run on the same machine with [`tests/vm/`](#testing-in-virtual-machines):

| from ↓ · to → | Fedora 44 | Debian 13 | Ubuntu 26.04 | Arch |
|---|:---:|:---:|:---:|:---:|
| **Fedora 44** | ✅ | 🟡 | · | · |
| **Debian 13** | · | ✅ | 🟡 | · |
| **Ubuntu 26.04** | · | 🟡 | · | · |
| **Arch** | 🟡 | · | · | ✅ |

✅ restored with no errors, all checks passed · 🟡 all checks passed, with expected reports (packages that don't exist on the other distribution, parts the VM image lacks) · `·` not tested yet. Details in [Test results](#test-results).

The `apt` and `pacman` package functions, including the AUR helper bootstrap and AUR installs, were also tested in containers.

**Not tested yet**: desktops other than KDE (GNOME, Xfce, …) and a real migration on Debian/Ubuntu or Arch hardware.

## Testing in virtual machines

`tests/vm/` holds a small QEMU/KVM harness that runs a whole migration between two throw‑away VMs, so changes can be tried on other distributions without touching a real disk. It uses the official cloud images (configured with cloud‑init), a virtual **USB stick** that is moved from the old VM to the new one, and ssh. libvirt is not needed.

```bash
sudo dnf install qemu-kvm qemu-img        # Debian/Ubuntu: qemu-system-x86 qemu-utils · Arch: qemu-base
                                          # also needed: mtools, dosfstools, curl, openssh

tests/vm/migrate-test.sh fedora fedora            # same distro
tests/vm/migrate-test.sh debian ubuntu --fs exfat # apt → apt, exFAT stick
tests/vm/migrate-test.sh arch fedora --keep       # different package manager, keep the VMs
tests/vm/migrate-test.sh fedora fedora --twice    # restore twice on the same VM
tests/vm/edge-test.sh fedora                      # edge cases in a single VM
```

`migrate-test.sh` creates the source VM, fills it with test data (home files, dotfiles, crontab, `/etc/sysctl.d`, `/etc/hosts`, `/opt`, `/usr/local`, a few packages), runs `migrate.sh save` onto the stick, then restores into a fresh VM with `migrate.sh restore` and checks that everything arrived. With `--twice` it runs the restore again on the same VM and checks again, to make sure that a second restore doesn't duplicate anything. `--mem MB` sets the RAM of each VM (default 3072).

`edge-test.sh` covers refused destinations, the disk picker, a mount path with a space and an apostrophe, a corrupted backup, a restore as a different user, a trial backup and shellcheck (see [Edge cases](#edge-cases)).

Logs and the check list are saved in `~/.local/share/easydistrohopping-vms/results/`.

For manual tests, `tests/vm/vm.sh` handles single VMs:

```bash
tests/vm/vm.sh create box arch          # distros: fedora, debian, ubuntu, arch
tests/vm/vm.sh usb stick                # empty 32G virtual USB stick
tests/vm/vm.sh start box --usb stick    # add --gui for a window, --mem 6144 for a desktop
tests/vm/vm.sh wait box && tests/vm/vm.sh push box
tests/vm/vm.sh ssh box                  # user/password: tester/tester
tests/vm/vm.sh list | stop box | destroy box
```

To test a desktop environment, install it inside the VM (e.g. `sudo dnf group install kde-desktop`) and start it with `--gui`.

### Test results

Run on the machine above (Fedora 44 host, QEMU/KVM) in November 2026, with `tests/vm/migrate-test.sh`. Each run: provision the old VM → `migrate.sh save` to a virtual USB stick → `migrate.sh restore` in a fresh VM → checks on the new VM.

**Checks** (17): home file, `~/.config` dotfile, `.bashrc`, Trash excluded, `~/.ssh/config` permissions, exactly one crontab entry, `/etc/sysctl.d`, `/etc/hosts`, no duplicate `/etc/hosts` entries, `/opt`, `/usr/local`, hostname, owner of every home file, `docs/` copied into the backup, SELinux labels (only where SELinux is enabled), and two packages (only when the package manager is the same). The first round (marked *round 1*) used the first 14 of these.

| | Hop | Kind | USB stick | Backup | Restore | Checks | Notes |
|:---:|---|---|---|---|---|:---:|---|
| ✅ | Fedora 44 → Fedora 44, restore run twice | same distro | ext4 | verified | no errors (both times) | 17/17 ×2 | nothing duplicated by the second restore |
| ✅ | Debian 13 → Debian 13 *(round 1)* | same distro | ext4 | verified | no errors | 14/14 | |
| ✅ | Arch → Arch *(round 1)* | same distro | ext4 | verified | no errors | 14/14 | |
| 🟡 | Debian 13 → Ubuntu 26.04 *(round 1)* | same family | btrfs | verified | 1 report | 14/14 | `grub-cloud-amd64` and `linux-image-amd64` not in the Ubuntu repos: expected, they are Debian-only |
| 🟡 | Debian 13 → Ubuntu 26.04, trial (`--no-home`) *(round 1)* | same family | — | verified, 756 KB | stopped at step 4/10 | — | home and SSH steps skipped as expected; same two Debian-only packages reported |
| 🟡 | Ubuntu 26.04 → Debian 13, restore run twice | same family | btrfs | verified | 2 reports (both times) | 16/16 ×2 | 5 Ubuntu-only packages reported (`ubuntu-server`, `linux-virtual`, …); `grub-pc` fails to configure on the UEFI cloud image: both expected |
| 🟡 | Arch → Fedora 44 | different family | exFAT | verified | 2 reports | 15/15 | repos and packages skipped (expected); cron installed by the restore, SELinux labels correct. The first attempt of this round timed out before the Arch VM answered on ssh (test environment), the second one passed |
| 🟡 | Fedora 44 → Debian 13 | different family | exFAT | verified | 4 reports | 14/14 | repos and packages skipped (expected); NetworkManager and GRUB are not on the Debian cloud image (expected in the VM); cron was installed by the restore and the crontab restored |

### Edge cases

`tests/vm/edge-test.sh [DISTRO]` runs in a single VM (default Fedora) and checks what `migrate.sh` does outside the normal path. Results on Fedora 44, November 2026:

| | Case | Result |
|:---:|---|---|
| ✅ | backup to a FAT32 disk | refused with the FAT32 message |
| ✅ | backup to a folder on the home disk | refused ("same disk as your home") |
| ✅ | backup to a 1 GB disk | refused ("Not enough space") |
| ✅ | backup to another partition of the disk that holds the home | refused ("same disk as your home"); tested with a two-partition loop device |
| ✅ | disk picker | lists the USB stick, hides the system disk; also lists the 2 MB cloud-init seed disk (harmless, VM only) |
| ✅ | save through the picker | `udisksctl` refused (no polkit session over ssh), `sudo mount` fallback used, root-owned ext4 → `backups/` created, backup verified, disk unmounted at the end |
| ✅ | restore through the picker | disk mounted, backup found in `backups/`, restore completed |
| ✅ | corrupted backup (one byte appended to a file) | checksum mismatch detected; answering `n` stops before any change |
| ✅ | mount point with a space and an apostrophe (`/mnt/it's a disk`) | backup and restore with no failed step, home restored |
| ✅ | exit code of a successful backup | 0 |
| ✅ | two backups in a row | each one in its own folder |
| ✅ | trial backup (`save ~/trial --no-home`) | 4.2 MB, no `home.tar.zst`, no critical archive, `home_included=0` |
| ✅ | restore as a different user (`other` instead of `tester`) | warns and asks; on "yes" the files land in `/home/other`, all owned by `other` |
| ℹ️ | shellcheck (`-S warning`) | 6 warnings, none real: colour variables and `BACKUP_GLOBS` "unused" (they are used by the files that `source` `common.sh`), a `~` inside a message string, commas in QEMU arguments |

### Bugs found and fixed

Second round (these tests, November 2026):

1. **A successful backup exited with code 1**: the last line of `lib/backup.sh` was `((NO_HOME)) && echo ...`, which returns 1 when `--no-home` is not used. The message said "VERIFIED", but anything that checks the exit code saw a failure.
2. **`/opt` got the wrong SELinux label** on Fedora/RHEL (`user_tmp_t` instead of `usr_t`), because it is extracted into `/tmp` and copied with `cp -a`. A systemd service running something from `/opt` could be denied. `restorecon` now runs on every restored `/opt` folder and on the GRUB themes.
3. **Duplicate `/etc/hosts` entries**: old lines were compared character by character, so default lines that differ only in spacing or aliases (`127.0.0.1 localhost`, `::1 ip6-localhost`, …) were appended again. Now each IP–name pair is checked, and only the missing names are added.
4. **Crontab not restored when cron was missing** (changing family, minimal installs), with just "crontab" in the summary. The restore now installs `cronie`/`cron`, enables the service, and if that fails says how to restore it by hand.
5. **Restore as a different user didn't work**: after the warning the home was extracted into `/home/<old user>`, where the new user can't write. Archives are now extracted into the current `$HOME`.
6. **The "same disk as your home" check compared partitions, not disks**: a backup to another partition of the same SSD was accepted, and it would be lost when that disk is wiped. Whole disks are compared now (`same_disk` in `lib/common.sh`).
7. **Two backups started in the same minute shared a folder**: folders are now named `system-backup-YYYYMMDD-HHMMSS`.

First round:
- the backup was always marked **"HAS ERRORS"** on any machine that didn't have `~/.ssh/id_ed25519`, `~/.claude/projects` and `~/.claude.json`: now only the critical files that exist (`~/.ssh/id_*`, `~/.ssh/config`, `~/.gnupg`, Claude Code data) are required;
- Debian → Ubuntu: Debian's official source (written with `mirror+file:` URIs in cloud images) was copied to Ubuntu and broke `apt-get update`. Official sources are now recognized in more forms, and when the distribution changes third-party apt repositories are reported instead of copied (their URLs are distro-specific, e.g. Docker);
- the closing hint about Claude Code chats is only shown if `~/.claude/projects` exists.

### Test environment notes

Problems in the test environment itself (not in the scripts), worth knowing if you build your own:
- Debian's `genericcloud` image has no USB drivers: the `generic` image is used instead;
- a user in the `sudo`/`wheel` group *and* with a `NOPASSWD` rule still gets asked for a password by `sudo -v`: the test user only has the `NOPASSWD` rule;
- cloud images ship without `cron`, and Fedora's without the exFAT kernel module (`kernel-modules`): the tests install them on the source VM only, on a cross-family destination it is the restore that installs cron;
- on Arch, `pacman -Syu` upgrades the kernel and removes the running kernel's modules: load the filesystem module **before** it. The harness now checks `/proc/filesystems` first, because `modprobe` fails even for a module that is already loaded.
