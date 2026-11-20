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
| **Fedora 44** | ✅ | · | · | · |
| **Debian 13** | · | ✅ | 🟡 | · |
| **Arch** | ⏳ | · | · | ✅ |

✅ restored with no errors, all checks passed · 🟡 all checks passed, with expected reports · ⏳ to be run again · `·` not tested yet. Details in [Test results](#test-results).

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
```

`migrate-test.sh` creates the source VM, fills it with test data (home files, dotfiles, crontab, `/etc/sysctl.d`, `/etc/hosts`, `/opt`, `/usr/local`, a few packages), runs `migrate.sh save` onto the stick, then restores into a fresh VM with `migrate.sh restore` and checks that everything arrived. Logs and the check list are saved in `~/.local/share/easydistrohopping-vms/results/`.

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

Run on the machine above (Fedora 44 host, QEMU/KVM) in November 2026, with `tests/vm/migrate-test.sh`. Each run: provision the old VM → `migrate.sh save` to a virtual USB stick → `migrate.sh restore` in a fresh VM → 14 checks (home file, `~/.config` dotfile, `.bashrc`, Trash excluded, `~/.ssh/config` permissions, crontab, `/etc/sysctl.d`, `/etc/hosts`, `/opt`, `/usr/local`, hostname, owner of every home file, two packages).

| | Hop | Kind | USB stick | Backup | Restore | Checks | Notes |
|:---:|---|---|---|---|---|:---:|---|
| ✅ | Fedora 44 → Fedora 44 | same distro | ext4 | verified | no errors | 14/14 | |
| ✅ | Debian 13 → Debian 13 | same distro | ext4 | verified | no errors | 14/14 | |
| ✅ | Arch → Arch | same distro | ext4 | verified | no errors | 14/14 | |
| 🟡 | Debian 13 → Ubuntu 26.04 | same family | btrfs | verified | 1 report | 14/14 | `grub-cloud-amd64` and `linux-image-amd64` not in the Ubuntu repos: expected, they are Debian-only |
| 🟡 | Debian 13 → Ubuntu 26.04, trial (`--no-home`) | same family | — | verified, 756 KB | stopped at step 4/10 | — | home and SSH steps skipped as expected; same two Debian-only packages reported |
| ⏳ | Arch → Fedora 44 | different family | exFAT | — | — | — | not completed: the test VM couldn't load the exFAT module after `pacman -Syu` upgraded its kernel (test-harness problem, fixed; to be run again) |

Bugs found by these runs and fixed in the scripts:
- the backup was always marked **"HAS ERRORS"** on any machine that didn't have `~/.ssh/id_ed25519`, `~/.claude/projects` and `~/.claude.json`: now only the critical files that exist (`~/.ssh/id_*`, `~/.ssh/config`, `~/.gnupg`, Claude Code data) are required;
- Debian → Ubuntu: Debian's official source (written with `mirror+file:` URIs in cloud images) was copied to Ubuntu and broke `apt-get update`. Official sources are now recognized in more forms, and when the distribution changes third-party apt repositories are reported instead of copied (their URLs are distro-specific, e.g. Docker);
- the closing hint about Claude Code chats is only shown if `~/.claude/projects` exists.

Problems in the test environment itself (not in the scripts), worth knowing if you build your own:
- Debian's `genericcloud` image has no USB drivers: the `generic` image is used instead;
- a user in the `sudo`/`wheel` group *and* with a `NOPASSWD` rule still gets asked for a password by `sudo -v`: the test user only has the `NOPASSWD` rule;
- cloud images ship without `cron`, and Fedora's without the exFAT kernel module (`kernel-modules`): the tests install them;
- on Arch, load the filesystem module **before** `pacman -Syu`: after a kernel upgrade, modules can't be loaded until reboot.
