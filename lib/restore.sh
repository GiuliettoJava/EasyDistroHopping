#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"
B="$(cd "${1:-$SCRIPT_DIR/..}" && pwd)" || die "Backup folder not found: ${1:-}"
FAILED=()
info() { echo; echo "${BLU}==>${RST} $*"; }
ok()   { echo "${GRN}[OK]${RST} $*"; }
fail() { echo "${RED}[FAILED]${RST} $*"; FAILED+=("$*"); }
step() { local d="$1"; shift; if "$@"; then ok "$d"; else fail "$d"; fi; }

[[ $EUID -ne 0 ]] || die "Do not run as root: run it as a normal user (it will ask for sudo)."
[[ "$PM" != unknown ]] || die "Unsupported package manager: dnf (Fedora/RHEL), apt (Debian/Ubuntu) or pacman (Arch) is required."

ENV_FILE="$B/meta/system-info.env"
meta() { grep -m1 "^$1=" "$ENV_FILE" 2>/dev/null | cut -d= -f2-; }
HOME_INCLUDED="$(meta home_included)"; HOME_INCLUDED="${HOME_INCLUDED:-1}"
if ((HOME_INCLUDED)); then [[ -f "$B/home.tar.zst" ]] || die "home.tar.zst not found in $B"; fi
OLD_USER="$(meta user)"
OLD_HOSTNAME="$(meta hostname)"
OLD_DE="$(meta de)"
[[ -z "$OLD_DE" && -f "$B/critical/migrazione.knsv" ]] && OLD_DE=kde
OLD_PM="$(meta pm)";         OLD_PM="${OLD_PM:-dnf}"
OLD_OS_ID="$(meta os_id)";   OLD_OS_ID="${OLD_OS_ID:-fedora}"
OLD_OS_VERSION="$(meta os_version)"; OLD_OS_VERSION="${OLD_OS_VERSION:-$(meta fedora)}"
OLD_CODENAME="$(meta os_codename)"
OLD_AUR_HELPER="$(meta aur_helper)"
NEW_OS_ID="$(os_field ID)"
NEW_OS_VERSION="$(os_field VERSION_ID)"
NEW_CODENAME="$(os_field VERSION_CODENAME)"

PKG_EXPLICIT="$B/pkgs/packages-explicit.txt"; [[ -f "$PKG_EXPLICIT" ]] || PKG_EXPLICIT="$B/pkgs/dnf-userinstalled.txt"
PKG_LOCAL="$B/pkgs/packages-local.txt";       [[ -f "$PKG_LOCAL" ]]    || PKG_LOCAL="$B/pkgs/dnf-local-rpms.txt"
PKG_AUR="$B/pkgs/aur-packages.txt"

if ((HOME_INCLUDED)) && [[ "$(id -un)" != "$OLD_USER" || "$HOME" != "/home/$OLD_USER" ]]; then
  echo "${YLW}Current user: $(id -un) — backup user: $OLD_USER${RST}"
  echo "The files will be restored into $HOME, but Claude Code chats and settings that contain"
  echo "/home/$OLD_USER paths will NOT match."
  yes_no "Continue anyway?" || exit 1
fi

SAME_PM=1
if [[ "$PM" != "$OLD_PM" ]]; then
  SAME_PM=0
  echo "${YLW}The backup comes from $OLD_OS_ID ($OLD_PM), this system is $NEW_OS_ID ($PM).${RST}"
  echo "Package names differ between distributions: repositories and system packages will NOT be"
  echo "installed automatically (the lists stay in $B/pkgs). Everything else is restored."
  yes_no "Continue?" || exit 1
elif [[ "$NEW_OS_ID" != "$OLD_OS_ID" || "$NEW_OS_VERSION" != "$OLD_OS_VERSION" ]]; then
  echo "${YLW}Note: backup is from $OLD_OS_ID $OLD_OS_VERSION, current system is $NEW_OS_ID $NEW_OS_VERSION.${RST}"
fi

if graphical_session_running; then
  echo "${YLW}A graphical desktop session is running for this user.${RST}"
  echo "Recommended: log out, press Ctrl+Alt+F3, log in from the TTY and run the script again."
  yes_no "Continue anyway (you must reboot IMMEDIATELY at the end)?" || exit 1
fi

LOG="$HOME/restore-$(date +%Y%m%d-%H%M).log"
exec > >(tee -a "$LOG") 2>&1
echo "Restoring from: $B   —   $(date)"
echo "System: $(os_field PRETTY_NAME)  |  package manager: $PM"

info "Verifying backup integrity (SHA256)"
if ( cd "$B" && sha256sum -c --quiet SHA256SUMS ); then ok "checksums match"
else
  echo "${RED}Some backup files do not match their checksums!${RST}"
  yes_no "Continue anyway?" || exit 1
fi

sudo -v || die "sudo failed"
( while kill -0 $$ 2>/dev/null; do sudo -n true; sleep 50; done ) 2>/dev/null &
SUDO_KEEPALIVE=$!
trap 'kill $SUDO_KEEPALIVE 2>/dev/null' EXIT

if ! command -v zstd >/dev/null; then
  info "Installing zstd (needed to read the backup)"
  pm_install zstd || { pm_refresh && pm_install zstd; } || die "zstd is required: install it and run again"
fi

TMP="$(mktemp -d)"
untar_sys() { zstd -dc "$1" | sudo tar -C "$2" -xpf - "${@:3}"; }
old_files() { sudo find "$OLDETC/$1" -maxdepth 1 -type f -name "$2" 2>/dev/null | sort; }
selinux_on() { command -v selinuxenabled >/dev/null && selinuxenabled; }

info "Preparing system files"
mkdir -p "$TMP/sys"
step "extracting backed-up /etc (to a temporary area)" untar_sys "$B/system/etc.tar.zst" "$TMP/sys"
OLDETC="$TMP/sys/etc"

restore_repos_dnf() {
  if [[ "$NEW_OS_ID" == fedora ]] && [[ -n "$(old_files yum.repos.d 'rpmfusion-*.repo')" ]]; then
    step "RPM Fusion free+nonfree" pm_install \
      "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-${NEW_OS_VERSION}.noarch.rpm" \
      "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-${NEW_OS_VERSION}.noarch.rpm"
  fi
  local f n
  while read -r f; do
    n="$(basename "$f")"; [[ -e "/etc/pki/rpm-gpg/$n" ]] || sudo install -m 644 "$f" "/etc/pki/rpm-gpg/$n"
  done < <(old_files pki/rpm-gpg '*')
  while read -r f; do
    n="$(basename "$f")"
    case "$n" in fedora*|rpmfusion*|redhat*|rocky*|almalinux*|centos*|epel*) continue ;; esac
    [[ -e "/etc/yum.repos.d/$n" ]] && continue
    sudo install -m 644 -o root -g root "$f" "/etc/yum.repos.d/$n" && ok "repo $n" || fail "repo $n"
  done < <(old_files yum.repos.d '*.repo')
  if [[ -n "$OLD_OS_VERSION" && "$NEW_OS_VERSION" != "$OLD_OS_VERSION" ]]; then
    sudo sed -i "s/fedora-$OLD_OS_VERSION-/fedora-$NEW_OS_VERSION-/g" /etc/yum.repos.d/_copr*.repo 2>/dev/null
  fi
}

restore_repos_apt() {
  local d f n
  for d in apt/keyrings apt/trusted.gpg.d; do
    while read -r f; do
      n="$(basename "$f")"
      [[ -e "/etc/$d/$n" ]] && continue
      sudo install -D -m 644 "$f" "/etc/$d/$n" && ok "key /etc/$d/$n"
    done < <(old_files "$d" '*')
  done
  if [[ -f "$B/system/usr-share-keyrings.tar.zst" ]]; then
    step "keys in /usr/share/keyrings" bash -c "zstd -dc '$B/system/usr-share-keyrings.tar.zst' | sudo tar -C / -xpf - --skip-old-files"
  fi
  local official='(deb|security|ftp[.a-z0-9]*)\.debian\.org|(archive|security|ports)\.ubuntu\.com|mirror\+file:/etc/apt/mirrors/|(debian-archive|ubuntu-archive)-keyring'
  while read -r f; do
    n="$(basename "$f")"
    [[ -e "/etc/apt/sources.list.d/$n" ]] && continue
    sudo grep -qE "$official" "$f" && continue
    if [[ "$OLD_OS_ID" != "$NEW_OS_ID" ]]; then
      fail "apt repo $n not added: it is for $OLD_OS_ID, add the $NEW_OS_ID version by hand"
      continue
    fi
    sudo install -m 644 -o root -g root "$f" "/etc/apt/sources.list.d/$n" && ok "repo $n" || { fail "repo $n"; continue; }
    if [[ -n "$OLD_CODENAME" && -n "$NEW_CODENAME" && "$OLD_CODENAME" != "$NEW_CODENAME" ]]; then
      sudo sed -i "s/\b$OLD_CODENAME\b/$NEW_CODENAME/g" "/etc/apt/sources.list.d/$n" && ok "repo $n: $OLD_CODENAME → $NEW_CODENAME"
    fi
  done < <(old_files apt/sources.list.d '*.list'; old_files apt/sources.list.d '*.sources')
}

restore_repos_pacman() {
  local r
  if sudo grep -q '^\[multilib\]' "$OLDETC/pacman.conf" && ! grep -q '^\[multilib\]' /etc/pacman.conf; then
    printf '\n[multilib]\nInclude = /etc/pacman.d/mirrorlist\n' | sudo tee -a /etc/pacman.conf >/dev/null && ok "pacman: multilib enabled"
  fi
  for r in $(sudo grep -oE '^\[[^]]+\]' "$OLDETC/pacman.conf" | tr -d '[]'); do
    case "$r" in options|core|extra|multilib|community|testing|core-testing|extra-testing|multilib-testing) continue ;; esac
    grep -q "^\[$r\]" /etc/pacman.conf || fail "pacman repo [$r] not added automatically: copy its section from the old /etc/pacman.conf and import its key"
  done
}

info "[1/10] Package repositories ($PM)"
if ((SAME_PM)); then
  case "$PM" in
    dnf)    restore_repos_dnf ;;
    apt)    restore_repos_apt ;;
    pacman) restore_repos_pacman ;;
  esac
  step "refreshing package database" pm_refresh
else
  fail "repositories skipped: the backup uses $OLD_PM, this system uses $PM"
fi

if ((HOME_INCLUDED == 0)); then
  info "[2/10] Home: skipped (trial backup made with --no-home)"
  info "[3/10] SSH permissions: skipped"
else
info "[2/10] Restoring home (all files) — this is the long part"
tar -C "$HOME" -cf - .config .local 2>/dev/null | zstd -q -o "$HOME/.home-fresh-before-restore.tar.zst" 2>/dev/null
if command -v pv >/dev/null; then
  pv "$B/home.tar.zst" | zstd -dc | tar -C "$HOME" -xpf - --xattrs --acls --strip-components=1
else
  zstd -dc "$B/home.tar.zst" | tar -C "$HOME" -xpf - --xattrs --acls --strip-components=1
fi
rc=("${PIPESTATUS[@]}")
if [[ ${rc[*]} =~ ^(0 ?)+$ ]]; then ok "home restored"; else fail "home extraction (exit codes: ${rc[*]})"; fi
step "critical files (SSH, Claude Code, wallet)" bash -c "zstd -dc '$B/critical/critical.tar.zst' | tar -C \"\$HOME\" -xpf - --xattrs --acls --strip-components=1"
step "home ownership" sudo chown -R "$(id -un):$(id -gn)" "$HOME"
selinux_on && step "home SELinux labels" sudo restorecon -RF "$HOME"

info "[3/10] SSH permissions"
if [[ -d "$HOME/.ssh" ]]; then
  chmod 700 "$HOME/.ssh"
  find "$HOME/.ssh" -type f -exec chmod 600 {} +
  find "$HOME/.ssh" -type f -name '*.pub' -exec chmod 644 {} +
  ok "~/.ssh fixed (700, keys 600)"; ls -la "$HOME/.ssh"
else fail "~/.ssh not found"; fi
fi

AUR_HELPER=""
bootstrap_aur_helper() {
  AUR_HELPER="$(detect_aur_helper)" && return 0
  local want="yay" d rc
  [[ "$OLD_AUR_HELPER" == paru ]] && want="paru"
  info "Installing the AUR helper $want (from ${want}-bin in the AUR)"
  pm_install base-devel git || return 1
  d="$(mktemp -d)"
  git clone --depth 1 "https://aur.archlinux.org/${want}-bin.git" "$d/${want}-bin" \
    && ( cd "$d/${want}-bin" && makepkg -si --noconfirm --needed )
  rc=$?; rm -rf "$d"
  ((rc == 0)) && AUR_HELPER="$(detect_aur_helper)"
}

aur_install() {
  local flags p
  read -ra flags <<<"$(aur_flags "$AUR_HELPER")"
  "$AUR_HELPER" -S "${flags[@]}" "$@"
}

install_aur_packages() {
  local pkgs=("$@") p
  ((${#pkgs[@]})) || return 0
  if ! bootstrap_aur_helper; then
    fail "AUR packages not installed (could not set up an AUR helper): ${pkgs[*]}"
    return
  fi
  ok "AUR helper: $AUR_HELPER"
  if aur_install "${pkgs[@]}"; then
    ok "AUR packages (${#pkgs[@]})"
  else
    echo "Bulk AUR install failed, trying package by package..."
    for p in "${pkgs[@]}"; do pm_is_installed "$p" || aur_install "$p" || fail "AUR: $p"; done
  fi
}

install_from_list() {
  local pkgs missing p
  pkgs="$(grep -vxF -f <(cat "$PKG_LOCAL" 2>/dev/null) "$PKG_EXPLICIT" \
          | grep -vE '^(gpg-pubkey|rpmfusion-(free|nonfree)-release|kernel(-core|-modules.*|-devel)?|linux-(image|headers|modules)-[0-9].*)$')"
  [[ -n "$pkgs" ]] || { ok "no packages to install"; return; }
  if [[ "$PM" != dnf ]]; then
    local avail; avail="$(pm_list_available)"
    missing="$(comm -23 <(sort -u <<<"$pkgs") <(cat <<<"$avail"))"
    pkgs="$(comm -12 <(sort -u <<<"$pkgs") <(cat <<<"$avail"))"
    [[ -n "$missing" ]] && fail "not available in the repositories ($(wc -l <<<"$missing")): $(tr '\n' ' ' <<<"$missing")"
  fi
  if [[ "$PM" == dnf ]]; then
    sudo dnf install -y --skip-unavailable --skip-broken $pkgs
  else
    pm_install $pkgs
  fi && { ok "$PM packages ($(wc -w <<<"$pkgs"))"; return; }
  echo "Bulk install failed, trying package by package..."
  for p in $pkgs; do pm_is_installed "$p" || pm_install "$p" >/dev/null 2>&1 || fail "$PM: $p"; done
}

install_local_packages() {
  local ext p f aur=() in_aur
  ext="$(pm_local_ext)"
  while read -r p; do
    [[ -z "$p" || "$p" == rpmfusion-* ]] && continue
    [[ "$PM" == pacman ]] && { [[ "$p" == *-debug ]] || is_aur_helper_pkg "$p"; } && continue
    pm_is_installed "$p" && { ok "$p already installed"; continue; }
    f=$(ls -t "$HOME"/Downloads/"$p"[-_]*."$ext" "$HOME"/Desktop/"$p"[-_]*."$ext" 2>/dev/null | head -1)
    if [[ "$PM" == pacman ]]; then
      in_aur=1
      [[ -f "$PKG_AUR" ]] && ! grep -qxF "$p" "$PKG_AUR" && in_aur=0
      if ((in_aur)); then aur+=("$p")
      elif [[ -n "$f" ]]; then step "local package $p" sudo pacman -U --needed --noconfirm "$f"
      else fail "foreign package $p: not in the AUR and no .$ext file in ~/Downloads or ~/Desktop"; fi
    elif [[ -n "$f" ]]; then
      step "local package $p" pm_install "$f"
    else
      fail "local package $p: .$ext file not found in ~/Downloads or ~/Desktop (download it from the vendor's site)"
    fi
  done < <(cat "$PKG_LOCAL" 2>/dev/null)
  [[ "$PM" == pacman ]] && install_aur_packages "${aur[@]}"
}

info "[4/10] Installing system packages ($PM)"
if ((SAME_PM)); then
  install_from_list
  info "Packages installed from local files$( [[ "$PM" == pacman ]] && echo ' / AUR')"
  install_local_packages
else
  fail "system packages skipped: the backup uses $OLD_PM (lists in $B/pkgs)"
fi

info "pip --user / pipx"
if [[ -s "$B/pkgs/pip-user.txt" ]]; then
  python3 -m pip --version >/dev/null 2>&1 || step "installing pip" pm_install "$(pm_pip_package)"
  pip_user_install() {
    python3 -m pip install --user -q -r "$1" 2>/dev/null \
      || python3 -m pip install --user -q --break-system-packages -r "$1"
  }
  step "pip --user (konsave & co.)" pip_user_install "$B/pkgs/pip-user.txt"
fi
if [[ -s "$B/pkgs/pipx.txt" ]]; then
  command -v pipx >/dev/null || step "installing pipx" pm_install pipx
  command -v pipx >/dev/null && step "pipx reinstall-all" pipx reinstall-all
fi

info "[5/10] Flatpak and Snap"
if [[ -n "$(tail -n +1 "$B/pkgs/flatpak-apps.tsv" 2>/dev/null | grep -v '^Application ID')" ]]; then
  command -v flatpak >/dev/null || step "installing flatpak" pm_install flatpak
  step "flathub (system)" sudo flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
  step "flathub (user)"   flatpak remote-add --user --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
  while IFS=$'\t' read -r app inst origin; do
    [[ -z "$app" || "$app" == "Application ID" ]] && continue
    scope="--system"; [[ "$inst" == "user" ]] && scope="--user"
    pre=""; [[ "$scope" == "--system" ]] && pre="sudo"
    if [[ "$origin" == "flathub" ]]; then
      $pre flatpak install $scope -y --noninteractive flathub "$app" && ok "flatpak $app" || fail "flatpak $app"
    else
      bundle=$(find "$HOME/Downloads" "$HOME/Desktop" -maxdepth 2 -name '*.flatpak' 2>/dev/null \
               | grep -i "$(echo "$app" | awk -F. '{print $NF}')" | head -1)
      [[ -z "$bundle" ]] && bundle=$(find "$HOME/Downloads" "$HOME/Desktop" -maxdepth 2 -name '*.flatpak' 2>/dev/null | head -1)
      if [[ -n "$bundle" ]]; then
        $pre flatpak install $scope -y --noninteractive "$bundle" && ok "flatpak $app (from $bundle)" || fail "flatpak $app from bundle"
      else fail "flatpak $app: .flatpak bundle not found"; fi
    fi
  done < "$B/pkgs/flatpak-apps.tsv"
else
  ok "no flatpak apps in the backup"
fi

SNAPLIST="$B/pkgs/snap-list.txt"
if [[ -s "$SNAPLIST" ]]; then
  if ! command -v snap >/dev/null; then
    if [[ "$PM" == pacman ]]; then
      bootstrap_aur_helper && step "installing snapd (AUR)" aur_install snapd \
        || fail "snapd not installed: it is in the AUR and no AUR helper is available"
    else
      step "installing snapd" pm_install snapd
    fi
  fi
  if command -v snap >/dev/null; then
    [[ -e /snap ]] || sudo ln -s /var/lib/snapd/snap /snap
    step "enabling snapd" sudo systemctl enable --now snapd.socket
    [[ "$PM" == pacman ]] && sudo systemctl enable --now snapd.apparmor.service >/dev/null 2>&1
    sudo snap wait system seed.loaded >/dev/null 2>&1
    while read -r name _ver _rev tracking _pub notes; do
      [[ -z "$name" || "$name" == bare ]] && continue
      [[ ",${notes:-}," =~ ,(base|core|snapd), ]] && continue
      snap list "$name" >/dev/null 2>&1 && { ok "snap $name already installed"; continue; }
      if [[ "$tracking" == "-" ]]; then fail "snap $name: installed from a local file, reinstall it manually"; continue; fi
      args=(--channel="$tracking"); [[ ",${notes:-}," == *,classic,* ]] && args+=(--classic)
      sudo snap install "$name" "${args[@]}" && ok "snap $name" || fail "snap $name"
    done < <(tail -n +2 "$SNAPLIST")
    if [[ -f "$B/system/snap-snapshot.export" ]]; then
      SNAP_ID=$(sudo snap import-snapshot "$B/system/snap-snapshot.export" 2>/dev/null | grep -oE '#[0-9]+' | head -1 | tr -d '#')
      if [[ -n "$SNAP_ID" ]]; then step "restoring snap data (snapshot #$SNAP_ID)" sudo snap restore "$SNAP_ID"
      else fail "snap snapshot import"; fi
    fi
  fi
fi

NEW_DE="$(detect_de)"
info "[6/10] Desktop look & feel (backup: ${OLD_DE:-unknown}, this system: $NEW_DE)"
if [[ "$OLD_DE" != kde ]]; then
  ok "backup is not from KDE: konsave skipped (desktop settings come from the home archive)"
elif [[ "$NEW_DE" != kde ]]; then
  fail "konsave skipped: the backup is from KDE but this system runs $NEW_DE (install KDE Plasma, then: konsave -i $B/critical/migrazione.knsv -f && konsave -a migrazione)"
else
  export PATH="$HOME/.local/bin:$PATH"
  if command -v konsave >/dev/null; then
    step "konsave import 'migrazione'" konsave -i "$B/critical/migrazione.knsv" -f
    step "konsave apply 'migrazione'"  konsave -a migrazione
    [[ -f "$B/critical/plasma6_backup.knsv" ]] && konsave -i "$B/critical/plasma6_backup.knsv" -f >/dev/null 2>&1
    konsave -l
  else
    fail "konsave not installed: python3 -m pip install --user konsave && konsave -i $B/critical/migrazione.knsv -f && konsave -a migrazione"
  fi
fi

info "[7/10] Wi-Fi / VPN connections (with passwords)"
NM_CONNS="$(old_files NetworkManager/system-connections '*')"
if [[ -z "$NM_CONNS" ]]; then
  ok "no NetworkManager connections in the backup"
elif ! command -v nmcli >/dev/null; then
  fail "NetworkManager is not installed: connections not restored (they are in the backed-up /etc)"
else
  while read -r c; do
    n="$(basename "$c")"
    [[ -e "/etc/NetworkManager/system-connections/$n" ]] && continue
    sudo install -m 600 -o root -g root "$c" "/etc/NetworkManager/system-connections/$n" && ok "network: $n" || fail "network: $n"
  done <<<"$NM_CONNS"
  selinux_on && sudo restorecon -R /etc/NetworkManager/system-connections
  step "reloading NetworkManager" sudo nmcli connection reload
fi

info "[8/10] System configuration (sysctl, sudoers, udev, /opt)"
while read -r f; do
  [[ -n "$f" ]] || continue; n="$(basename "$f")"
  [[ -e "/etc/sysctl.d/$n" ]] && continue
  sudo install -m 644 "$f" "/etc/sysctl.d/$n" && ok "sysctl: $n" || fail "sysctl: $n"
done < <(old_files sysctl.d '*.conf')
sudo sysctl --system >/dev/null 2>&1
while read -r f; do
  [[ -n "$f" ]] || continue; n="$(basename "$f")"
  [[ -e "/etc/udev/rules.d/$n" ]] || { sudo install -m 644 "$f" "/etc/udev/rules.d/$n" && ok "udev: $n"; }
done < <(old_files udev/rules.d '*.rules')
while read -r f; do
  [[ -n "$f" ]] || continue; n="$(basename "$f")"
  [[ -e "/etc/sudoers.d/$n" ]] && continue
  if sudo visudo -cf "$f" >/dev/null; then sudo install -m 440 "$f" "/etc/sudoers.d/$n" && ok "sudoers.d: $n"
  else fail "sudoers.d: $n is invalid, skipped"; fi
done < <(old_files sudoers.d '*')
hosts_has() {
  awk -v ip="$1" -v n="$2" '{sub(/#.*/, "")} $1 == ip {for (i = 2; i <= NF; i++) if ($i == n) f = 1} END {exit !f}' /etc/hosts
}
while read -r ip names; do
  [[ -n "$ip" && -n "$names" ]] || continue
  add=""
  for n in $names; do hosts_has "$ip" "$n" || add+=" $n"; done
  [[ -n "$add" ]] && echo "$ip$add" | sudo tee -a /etc/hosts >/dev/null && ok "hosts: $ip$add"
done < <(sudo sed -e 's/#.*//' "$OLDETC/hosts" 2>/dev/null)
mkdir -p "$TMP/opt"; zstd -dc "$B/system/opt.tar.zst" | sudo tar -C "$TMP/opt" -xpf -
for d in "$TMP"/opt/opt/*; do
  [[ -d "$d" ]] || continue; n="$(basename "$d")"
  if [[ ! -e "/opt/$n" ]]; then
    sudo cp -a "$d" "/opt/$n" && ok "/opt/$n" || fail "/opt/$n"
    selinux_on && sudo restorecon -R "/opt/$n"
  fi
done
step "/usr/local" bash -c "zstd -dc '$B/system/usr-local.tar.zst' | sudo tar -C / -xpf - --skip-old-files"
CUR_HOSTNAME="$(hostnamectl --static 2>/dev/null || cat /etc/hostname)"
[[ -z "$OLD_HOSTNAME" || "$CUR_HOSTNAME" == "$OLD_HOSTNAME" ]] || step "hostname $OLD_HOSTNAME" sudo hostnamectl set-hostname "$OLD_HOSTNAME"
if [[ -s "$B/system/crontab-user.txt" ]]; then
  if ! command -v crontab >/dev/null; then
    case "$PM" in apt) cron_pkg=cron ;; *) cron_pkg=cronie ;; esac
    step "installing cron ($cron_pkg)" pm_install "$cron_pkg"
    for s in crond cronie cron; do
      systemctl list-unit-files "$s.service" --no-legend 2>/dev/null | grep -q . && sudo systemctl enable --now "$s.service" >/dev/null 2>&1
    done
  fi
  if command -v crontab >/dev/null; then step "crontab" crontab "$B/system/crontab-user.txt"
  else fail "crontab not restored: install cron, then run: crontab $B/system/crontab-user.txt"; fi
fi

info "[9/10] GRUB theme"
GRUB_DIR=""; for d in /boot/grub2 /boot/grub; do [[ -d "$d" ]] && { GRUB_DIR="$d"; break; }; done
MKCONFIG="$(command -v grub2-mkconfig || command -v grub-mkconfig)"
if [[ ! -f "$B/system/grub-themes.tar.zst" ]]; then
  ok "no GRUB theme in the backup"
elif [[ -z "$GRUB_DIR" || -z "$MKCONFIG" || ! -f /etc/default/grub ]]; then
  fail "GRUB theme skipped: GRUB not found on this system (systemd-boot or another bootloader?)"
else
  mkdir -p "$TMP/grub"; zstd -dc "$B/system/grub-themes.tar.zst" | sudo tar -C "$TMP/grub" -xpf -
  SRC="$(sudo find "$TMP/grub" -maxdepth 2 -type d -name themes | head -1)"
  step "copying themes to $GRUB_DIR/themes" sudo bash -c "mkdir -p '$GRUB_DIR/themes' && cp -a '$SRC'/. '$GRUB_DIR/themes/'"
  selinux_on && sudo restorecon -R "$GRUB_DIR/themes"
  THEME_LINE="$(sudo grep -E '^GRUB_THEME=' "$OLDETC/default/grub" | sed -E "s#/boot/grub2?/themes/#$GRUB_DIR/themes/#")"
  if [[ -n "$THEME_LINE" ]]; then
    sudo cp /etc/default/grub /etc/default/grub.pre-restore
    sudo sed -i '/^GRUB_THEME=/d; s/^GRUB_TERMINAL_OUTPUT=/#GRUB_TERMINAL_OUTPUT=/' /etc/default/grub
    echo "$THEME_LINE" | sudo tee -a /etc/default/grub >/dev/null
    step "regenerating $GRUB_DIR/grub.cfg" sudo "$MKCONFIG" -o "$GRUB_DIR/grub.cfg"
  fi
fi

info "[10/10] Docker and user groups"
for g in docker input; do
  if getent group "$g" >/dev/null; then
    id -nG | grep -qw "$g" || step "adding user to group $g" sudo usermod -aG "$g" "$(id -un)"
  fi
done
if command -v docker >/dev/null; then
  step "enabling docker" sudo systemctl enable docker
  if [[ -f "$B/system/docker-volumes.tar.zst" ]]; then
    sudo systemctl stop docker docker.socket 2>/dev/null
    sudo mkdir -p /var/lib/docker
    step "restoring Docker volumes" bash -c "zstd -dc '$B/system/docker-volumes.tar.zst' | sudo tar -C /var/lib/docker -xpf -"
    step "starting docker" sudo systemctl start docker
  fi
elif [[ -f "$B/system/docker-volumes.tar.zst" ]]; then
  fail "Docker is not installed: volumes not restored (install Docker, then extract system/docker-volumes.tar.zst into /var/lib/docker)"
fi
while read -r unit state _; do
  [[ "$state" == "enabled" && "$unit" == *.service ]] || continue
  if systemctl list-unit-files "$unit" --no-legend 2>/dev/null | grep -q disabled; then
    sudo systemctl enable "$unit" >/dev/null 2>&1 && ok "enabled $unit"
  fi
done < "$B/meta/systemd-enabled.txt"

sudo rm -rf "$TMP"

echo
echo "=================================================================="
if ((${#FAILED[@]})); then
  echo "${YLW}Restore finished with ${#FAILED[@]} problems:${RST}"
  printf '  - %s\n' "${FAILED[@]}"
else
  echo "${GRN}RESTORE COMPLETED WITHOUT ERRORS${RST}"
fi
echo "Log: $LOG"
echo
echo "Now REBOOT:  sudo reboot"
[[ "$NEW_DE" == kde ]] && echo "After rebooting: KWallet will use the old system's password."
[[ -d "$HOME/.claude/projects" ]] && echo "Claude Code chats are in ~/.claude/projects (claude --resume)."
echo "=================================================================="
