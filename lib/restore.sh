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
[[ -f "$B/home.tar.zst" ]] || die "home.tar.zst not found in $B"
source "$B/meta/system-info.env"
OLD_DE="${de:-}"
[[ -z "$OLD_DE" && -f "$B/critical/migrazione.knsv" ]] && OLD_DE=kde
OLD_USER="$user"
if [[ "$(id -un)" != "$OLD_USER" || "$HOME" != "/home/$OLD_USER" ]]; then
  echo "${YLW}Current user: $(id -un) — backup user: $OLD_USER${RST}"
  echo "With a different user, Claude Code chats and many paths will NOT match."
  read -rp "Continue anyway? [y/N] " a; [[ "$a" =~ ^[sSyY]$ ]] || exit 1
fi
NEW_FEDORA="$(rpm -E %fedora)"
[[ "$NEW_FEDORA" == "$fedora" ]] || echo "${YLW}Note: backup is from Fedora $fedora, current system is Fedora $NEW_FEDORA.${RST}"

if graphical_session_running; then
  echo "${YLW}A graphical desktop session is running for this user.${RST}"
  echo "Recommended: log out, press Ctrl+Alt+F3, log in from the TTY and run the script again."
  read -rp "Continue anyway (you must reboot IMMEDIATELY at the end)? [y/N] " a
  [[ "$a" =~ ^[sSyY]$ ]] || exit 1
fi

LOG="$HOME/restore-$(date +%Y%m%d-%H%M).log"
exec > >(tee -a "$LOG") 2>&1
echo "Restoring from: $B   —   $(date)"

info "Verifying backup integrity (SHA256)"
if ( cd "$B" && sha256sum -c --quiet SHA256SUMS ); then ok "checksums match"
else
  echo "${RED}Some backup files do not match their checksums!${RST}"
  read -rp "Continue anyway? [y/N] " a; [[ "$a" =~ ^[sSyY]$ ]] || exit 1
fi

sudo -v || die "sudo failed"
( while kill -0 $$ 2>/dev/null; do sudo -n true; sleep 50; done ) 2>/dev/null &
SUDO_KEEPALIVE=$!
trap 'kill $SUDO_KEEPALIVE 2>/dev/null' EXIT

TMP="$(mktemp -d)"
untar_sys() { zstd -dc "$1" | sudo tar -C "$2" -xpf - "${@:3}"; }

info "Preparing system files"
mkdir -p "$TMP/sys"
step "extracting backed-up /etc (to a temporary area)" untar_sys "$B/system/etc.tar.zst" "$TMP/sys"
OLDETC="$TMP/sys/etc"

info "[1/10] Repositories (RPM Fusion, Chrome, VS Code, Docker, Opera, MongoDB, COPR)"
step "RPM Fusion free+nonfree" sudo dnf install -y \
  "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-${NEW_FEDORA}.noarch.rpm" \
  "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-${NEW_FEDORA}.noarch.rpm"
sudo cp -n "$OLDETC"/pki/rpm-gpg/* /etc/pki/rpm-gpg/ 2>/dev/null
for r in "$OLDETC"/yum.repos.d/*.repo; do
  n="$(basename "$r")"
  case "$n" in fedora*|rpmfusion*) continue ;; esac
  if [[ ! -e "/etc/yum.repos.d/$n" ]]; then
    sudo install -m 644 -o root -g root "$r" "/etc/yum.repos.d/$n" && ok "repo $n" || fail "repo $n"
  fi
done
if [[ "$NEW_FEDORA" != "$fedora" ]]; then
  sudo sed -i "s/fedora-$fedora-/fedora-$NEW_FEDORA-/g" /etc/yum.repos.d/_copr*.repo 2>/dev/null
fi
step "refreshing dnf cache" sudo dnf makecache -y

info "[2/10] Restoring home (all files) — this is the long part"
tar -C "$HOME" -cf - .config .local 2>/dev/null | zstd -q -o "$HOME/.home-fresh-before-restore.tar.zst" 2>/dev/null
if command -v pv >/dev/null; then
  pv "$B/home.tar.zst" | zstd -dc | tar -C "/home" -xpf - --xattrs --acls
else
  zstd -dc "$B/home.tar.zst" | tar -C "/home" -xpf - --xattrs --acls
fi
rc=("${PIPESTATUS[@]}")
if [[ ${rc[*]} =~ ^(0 ?)+$ ]]; then ok "home restored"; else fail "home extraction (exit codes: ${rc[*]})"; fi
step "critical files (SSH, Claude Code, wallet)" bash -c "zstd -dc '$B/critical/critical.tar.zst' | tar -C /home -xpf - --xattrs --acls"
step "home ownership" sudo chown -R "$(id -un):$(id -gn)" "$HOME"
step "home SELinux labels" sudo restorecon -RF "$HOME"

info "[3/10] SSH permissions"
if [[ -d "$HOME/.ssh" ]]; then
  chmod 700 "$HOME/.ssh"
  find "$HOME/.ssh" -type f -exec chmod 600 {} +
  find "$HOME/.ssh" -type f -name '*.pub' -exec chmod 644 {} +
  ok "~/.ssh fixed (700, keys 600)"; ls -la "$HOME/.ssh"
else fail "~/.ssh not found"; fi

info "[4/10] Installing dnf packages"
LOCAL_RPMS="$B/pkgs/dnf-local-rpms.txt"
PKGS=$(grep -vxF -f "$LOCAL_RPMS" "$B/pkgs/dnf-userinstalled.txt" \
       | grep -vE '^(rpmfusion-(free|nonfree)-release|kernel(-core|-modules.*|-devel)?|gpg-pubkey)$')
if sudo dnf install -y --skip-unavailable --skip-broken $PKGS; then
  ok "dnf packages ($(echo "$PKGS" | wc -w))"
else
  echo "Bulk install failed, trying package by package..."
  for p in $PKGS; do rpm -q "$p" >/dev/null 2>&1 || sudo dnf install -y "$p" >/dev/null 2>&1 || fail "dnf: $p"; done
fi
info "Local RPMs"
declare -A RPM_GLOB=( [dbeaver-ce]="dbeaver-ce*.rpm" [mongodb-compass]="mongodb-compass*.rpm" \
                      [balena-etcher]="balena-etcher*.rpm" [gitkraken]="gitkraken*.rpm" )
while read -r p; do
  [[ -z "$p" || "$p" == rpmfusion-* ]] && continue
  rpm -q "$p" >/dev/null 2>&1 && { ok "$p already installed"; continue; }
  g="${RPM_GLOB[$p]:-$p*.rpm}"
  f=$(ls -t "$HOME"/Downloads/$g "$HOME"/Desktop/$g 2>/dev/null | head -1)
  if [[ -n "$f" ]]; then step "local rpm $p" sudo dnf install -y "$f"
  else fail "local rpm $p: .rpm file not found (download it from the vendor's site)"; fi
done < "$LOCAL_RPMS"
info "pip --user / pipx"
step "pip --user (konsave & co.)" python3 -m pip install --user -q -r "$B/pkgs/pip-user.txt"
if [[ -s "$B/pkgs/pipx.txt" ]] && command -v pipx >/dev/null; then
  step "pipx reinstall-all" pipx reinstall-all
fi

info "[5/10] Flatpak and Snap"
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

SNAPLIST="$B/pkgs/snap-list.txt"
if [[ -s "$SNAPLIST" ]]; then
  rpm -q snapd >/dev/null 2>&1 || step "installing snapd" sudo dnf install -y snapd
  [[ -e /snap ]] || sudo ln -s /var/lib/snapd/snap /snap
  step "enabling snapd" sudo systemctl enable --now snapd.socket
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
if ls "$OLDETC"/NetworkManager/system-connections/*.nmconnection >/dev/null 2>&1; then
  for c in "$OLDETC"/NetworkManager/system-connections/*.nmconnection; do
    n="$(basename "$c")"
    [[ -e "/etc/NetworkManager/system-connections/$n" ]] && continue
    sudo install -m 600 -o root -g root "$c" "/etc/NetworkManager/system-connections/$n" && ok "network: $n" || fail "network: $n"
  done
  sudo restorecon -R /etc/NetworkManager/system-connections
  step "reloading NetworkManager" sudo nmcli connection reload
fi

info "[8/10] System configuration (sysctl, sudoers, udev, /opt)"
for f in "$OLDETC"/sysctl.d/*.conf; do
  [[ -e "$f" ]] || continue
  n="$(basename "$f")"; [[ -e "/etc/sysctl.d/$n" ]] && continue
  sudo install -m 644 "$f" "/etc/sysctl.d/$n" && ok "sysctl: $n" || fail "sysctl: $n"
done
sudo sysctl --system >/dev/null 2>&1
for f in "$OLDETC"/udev/rules.d/*.rules; do
  [[ -e "$f" ]] || continue; n="$(basename "$f")"
  [[ -e "/etc/udev/rules.d/$n" ]] || { sudo install -m 644 "$f" "/etc/udev/rules.d/$n" && ok "udev: $n"; }
done
for f in "$OLDETC"/sudoers.d/*; do
  [[ -f "$f" ]] || continue; n="$(basename "$f")"
  [[ -e "/etc/sudoers.d/$n" ]] && continue
  if sudo visudo -cf "$f" >/dev/null; then sudo install -m 440 "$f" "/etc/sudoers.d/$n" && ok "sudoers.d: $n"
  else fail "sudoers.d: $n is invalid, skipped"; fi
done
grep -vE '^\s*(#|$)' "$OLDETC/hosts" | while read -r line; do
  grep -qF "$line" /etc/hosts || { echo "$line" | sudo tee -a /etc/hosts >/dev/null && ok "hosts: $line"; }
done
mkdir -p "$TMP/opt"; zstd -dc "$B/system/opt.tar.zst" | sudo tar -C "$TMP/opt" -xpf -
for d in "$TMP"/opt/opt/*; do
  [[ -d "$d" ]] || continue; n="$(basename "$d")"
  if [[ ! -e "/opt/$n" ]]; then sudo cp -a "$d" "/opt/$n" && ok "/opt/$n" || fail "/opt/$n"; fi
done
step "/usr/local" bash -c "zstd -dc '$B/system/usr-local.tar.zst' | sudo tar -C / -xpf - --skip-old-files"
[[ "$(hostnamectl hostname)" == "$hostname" ]] || step "hostname $hostname" sudo hostnamectl hostname "$hostname"
[[ -s "$B/system/crontab-user.txt" ]] && step "crontab" crontab "$B/system/crontab-user.txt"

info "[9/10] GRUB theme"
if [[ -f "$B/system/grub-themes.tar.zst" ]]; then
  step "copying themes to /boot/grub2/themes" bash -c "zstd -dc '$B/system/grub-themes.tar.zst' | sudo tar -C /boot/grub2 -xpf -"
  THEME_LINE=$(grep -E '^GRUB_THEME=' "$OLDETC/default/grub")
  if [[ -n "$THEME_LINE" ]]; then
    sudo cp /etc/default/grub /etc/default/grub.pre-restore
    sudo sed -i '/^GRUB_THEME=/d; s/^GRUB_TERMINAL_OUTPUT=/#GRUB_TERMINAL_OUTPUT=/' /etc/default/grub
    echo "$THEME_LINE" | sudo tee -a /etc/default/grub >/dev/null
    step "grub2-mkconfig" sudo grub2-mkconfig -o /boot/grub2/grub.cfg
  fi
fi

info "[10/10] Docker and user groups"
for g in docker input; do
  if getent group "$g" >/dev/null; then
    id -nG | grep -qw "$g" || step "adding user to group $g" sudo usermod -aG "$g" "$(id -un)"
  fi
done
if rpm -q docker-ce >/dev/null 2>&1; then
  step "enabling docker" sudo systemctl enable docker
  if [[ -f "$B/system/docker-volumes.tar.zst" ]]; then
    sudo systemctl stop docker docker.socket 2>/dev/null
    sudo mkdir -p /var/lib/docker
    step "restoring Docker volumes" bash -c "zstd -dc '$B/system/docker-volumes.tar.zst' | sudo tar -C /var/lib/docker -xpf -"
    step "starting docker" sudo systemctl start docker
  fi
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
echo "Claude Code chats are in ~/.claude/projects (claude --resume)."
echo "=================================================================="
