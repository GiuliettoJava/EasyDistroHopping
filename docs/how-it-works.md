# How it works

[← Back to the README](../README.md)

## Overview

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
├── docs/           ← documentation
└── README.md
```

**Requirements**: `bash`, `sudo`, `tar`, `zstd` (installed automatically on restore if missing), `udisks2` for automatic mounting (otherwise `sudo mount` is used). `pv` is optional (progress bars).

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

