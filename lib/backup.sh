#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/common.sh"

DEST_ROOT="${1:-}"
INCLUDE_TRASH=0
[[ "${2:-}" == "--include-trash" ]] && INCLUDE_TRASH=1

info() { echo "${BLU}==>${RST} $*"; }
ok()   { echo "${GRN}[OK]${RST} $*"; }
warn() { echo "${YLW}[WARNING]${RST} $*"; WARNINGS+=("$*"); }
WARNINGS=()

[[ -n "$DEST_ROOT" ]] || die "Usage: $0 /path/to/destination [--include-trash]"
[[ $EUID -ne 0 ]]     || die "Do not run as root. Run it as a normal user."
[[ -d "$DEST_ROOT" ]] || die "Destination '$DEST_ROOT' does not exist (is the disk mounted?)"
DEST_ROOT="$(realpath "$DEST_ROOT")"

USER_NAME="$(id -un)"
HOME_DIR="$HOME"
STAMP="$(date +%Y%m%d-%H%M)"
B="$DEST_ROOT/system-backup-$STAMP"
DE="$(detect_de)"
command -v zstd >/dev/null || die "zstd is required: install the 'zstd' package and run again."
[[ "$PM" != unknown ]] || die "Unsupported package manager: dnf (Fedora/RHEL), apt (Debian/Ubuntu) or pacman (Arch) is required."
OS_ID="$(os_field ID)"; OS_NAME="$(os_field PRETTY_NAME)"
IS_KDE=0; [[ "$DE" == kde ]] && IS_KDE=1

FSTYPE="$(findmnt -no FSTYPE --target "$DEST_ROOT")"
case "$FSTYPE" in
  vfat|msdos) die "Destination is FAT32: it does not support files >4GB. Format the disk as ext4, btrfs or exFAT." ;;
esac
info "Destination filesystem: $FSTYPE"
info "System: ${OS_NAME:-$OS_ID}  |  package manager: $PM"
info "Desktop environment: $DE$( ((IS_KDE)) || echo ' (KDE-specific steps will be skipped)')"
if [[ "$(findmnt -no SOURCE --target "$DEST_ROOT" | sed 's/\[.*//')" == "$(findmnt -no SOURCE --target "$HOME" | sed 's/\[.*//')" ]]; then
  die "Destination '$DEST_ROOT' is on the same disk as your home! Use the external USB stick/disk (e.g. /run/media/$(id -un)/<DISK>)."
fi

EXCLUDES=(
  "$USER_NAME/.cache"
  "$USER_NAME/.local/share/flatpak"
  "$USER_NAME/.var/app/*/cache"
  "$USER_NAME/.claude.json.tmp.*"
)
((IS_KDE)) && EXCLUDES+=("$USER_NAME/.local/share/baloo")
[[ $INCLUDE_TRASH -eq 1 ]] || EXCLUDES+=("$USER_NAME/.local/share/Trash")
case "$DEST_ROOT/" in
  "$HOME_DIR/"*) for g in "${BACKUP_GLOBS[@]}"; do EXCLUDES+=("$USER_NAME/${DEST_ROOT#"$HOME_DIR/"}/$g"); done ;;
esac

info "Calculating size of the data to back up (may take a minute)..."
DU_EXCL=()
for e in "${EXCLUDES[@]}"; do DU_EXCL+=("--exclude=/home/$e"); done
HOME_BYTES=$(du -sb "${DU_EXCL[@]}" "$HOME_DIR" 2>/dev/null | awk '{print $1}')
NEED=$(( HOME_BYTES + 2*1024*1024*1024 ))
AVAIL=$(df -B1 --output=avail "$DEST_ROOT" | tail -1)
info "Home data: $(numfmt --to=iec "$HOME_BYTES")  |  Free space on destination: $(numfmt --to=iec "$AVAIL")"
(( AVAIL > NEED )) || die "Not enough space on the destination (at least $(numfmt --to=iec $NEED) needed, before compression)."

for p in opera chrome firefox discord spotify code postman gitkraken; do
  if pgrep -x -i "$p" >/dev/null 2>&1; then
    warn "Process '$p' is running: close it for a consistent profile backup."
  fi
done
if ((${#WARNINGS[@]})); then
  read -rp "Some apps are still open. Continue anyway? [y/N] " a
  [[ "$a" =~ ^[sSyY]$ ]] || die "Aborted. Close the apps and run again."
  WARNINGS=()
fi

info "sudo is needed to back up system files (/etc, /boot, /opt, docker)."
sudo -v || die "sudo failed"
( while kill -0 $$ 2>/dev/null; do sudo -n true; sleep 50; done ) 2>/dev/null &
SUDO_KEEPALIVE=$!
trap 'kill $SUDO_KEEPALIVE 2>/dev/null' EXIT

mkdir -p "$B"/{critical,pkgs,system,meta} || die "Cannot create $B"
LOG="$B/backup.log"
exec > >(tee -a "$LOG") 2>&1
info "Backup to: $B"
echo "Started: $(date)"

check_tar() {
  local desc="$1"; shift
  local tar_rc="$1" z_rc="$2"
  if [[ $tar_rc -le 1 && $z_rc -eq 0 ]]; then ok "$desc"
  else warn "$desc: error (tar=$tar_rc zstd=$z_rc)"; fi
}

info "[1/7] Separate archive of critical files (SSH, GnuPG, Claude Code, git$( ((IS_KDE)) && echo ', KWallet, konsave'))"
CRIT_PATHS=(.ssh .claude .claude.json .local/share/claude .local/bin/claude .gnupg
            .gitconfig .config/gh .bashrc .bash_profile
            .local/share/DBeaverData .config/filezilla .putty .mongodb
            .local/share/keyrings)
((IS_KDE)) && CRIT_PATHS+=(.local/share/kwalletd .config/konsave)
CRIT=()
for f in "${CRIT_PATHS[@]}"; do
  [[ -e "$HOME_DIR/$f" || -L "$HOME_DIR/$f" ]] && CRIT+=("$USER_NAME/$f")
done
tar -C /home -cpf - --xattrs --acls "${CRIT[@]}" 2>>"$B/meta/tar-critical-warnings.log" \
  | zstd -T0 -q -3 -o "$B/critical/critical.tar.zst"
check_tar "critical files" "${PIPESTATUS[@]}"
cp -a "$HOME_DIR/.ssh/config" "$B/critical/ssh_config.txt" 2>/dev/null
ls -1 "$HOME_DIR/.claude/projects" > "$B/critical/claude-projects.txt" 2>/dev/null

info "[2/7] Package lists ($PM, flatpak, snap, pip, pipx, VS Code)"
P="$B/pkgs"
pm_list_explicit > "$P/packages-explicit.txt"
pm_list_local    > "$P/packages-local.txt"
pm_list_all      > "$P/packages-all.tsv"
[[ "$PM" == dnf ]] && dnf copr list > "$P/copr.txt" 2>/dev/null
AUR_HELPER=""; AUR_MSG=""
if [[ "$PM" == pacman ]]; then
  AUR_HELPER="$(detect_aur_helper)"
  pacman -Qm 2>/dev/null | tr ' ' '\t' > "$P/foreign-versions.tsv"
  if AUR_LIST="$(aur_filter_existing < "$P/packages-local.txt")"; then
    printf '%s\n' "$AUR_LIST" | sed '/^$/d' > "$P/aur-packages.txt"
    comm -23 "$P/packages-local.txt" "$P/aur-packages.txt" > "$P/foreign-not-in-aur.txt"
    AUR_MSG="; AUR: $(wc -l < "$P/aur-packages.txt") packages, $(wc -l < "$P/foreign-not-in-aur.txt") foreign not in the AUR"
  else
    AUR_MSG="; AUR: could not reach aur.archlinux.org, all $(wc -l < "$P/packages-local.txt") foreign packages will be treated as AUR packages"
  fi
  AUR_MSG+=" (helper: ${AUR_HELPER:-none})"
fi
flatpak list --app --columns=application,installation,origin > "$P/flatpak-apps.tsv" 2>/dev/null
flatpak remotes --columns=name,url,options > "$P/flatpak-remotes.tsv" 2>/dev/null
pip list --user --format=freeze > "$P/pip-user.txt" 2>/dev/null
command -v pipx >/dev/null && pipx list --short > "$P/pipx.txt" 2>/dev/null
command -v code >/dev/null && code --list-extensions > "$P/vscode-extensions.txt" 2>/dev/null
SNAP_COUNT=0
if command -v snap >/dev/null; then
  snap list > "$P/snap-list.txt" 2>/dev/null
  SNAP_COUNT=$(tail -n +2 "$P/snap-list.txt" 2>/dev/null | wc -l)
fi
ok "$PM: $(wc -l < "$P/packages-explicit.txt") explicitly installed, $(wc -l < "$P/packages-local.txt") from local files/AUR; flatpak: $(($(wc -l < "$P/flatpak-apps.tsv"))) apps; snap: $SNAP_COUNT$AUR_MSG"

info "[3/7] System files (full /etc, GRUB theme, /opt, Wi-Fi/VPN, Docker, snap data)"
S="$B/system"
sudo tar -C / -cpf - --xattrs --acls etc 2>>"$B/meta/tar-etc-warnings.log" | zstd -T0 -q -3 -o "$S/etc.tar.zst"
check_tar "/etc" "${PIPESTATUS[@]}"
for g in grub2 grub; do
  if sudo test -d "/boot/$g/themes"; then
    sudo tar -C /boot -cpf - "$g/themes" | zstd -T0 -q -o "$S/grub-themes.tar.zst"
    check_tar "GRUB theme (/boot/$g/themes)" "${PIPESTATUS[@]}"
    break
  fi
done
if [[ "$PM" == apt && -d /usr/share/keyrings ]]; then
  sudo tar -C / -cpf - usr/share/keyrings 2>/dev/null | zstd -T0 -q -o "$S/usr-share-keyrings.tar.zst"
  check_tar "apt keyrings (/usr/share/keyrings)" "${PIPESTATUS[@]}"
fi
sudo tar -C / -cpf - --exclude=opt/containerd opt 2>>"$B/meta/tar-opt-warnings.log" | zstd -T0 -q -3 -o "$S/opt.tar.zst"
check_tar "/opt" "${PIPESTATUS[@]}"
sudo tar -C / -cpf - usr/local 2>/dev/null | zstd -T0 -q -o "$S/usr-local.tar.zst"
check_tar "/usr/local" "${PIPESTATUS[@]}"
if sudo test -d /var/lib/docker/volumes; then
  docker volume ls > "$S/docker-volumes.txt" 2>/dev/null
  sudo tar -C /var/lib/docker -cpf - volumes 2>>"$B/meta/tar-docker-warnings.log" | zstd -T0 -q -3 -o "$S/docker-volumes.tar.zst"
  check_tar "Docker volumes" "${PIPESTATUS[@]}"
fi
if (( SNAP_COUNT > 0 )); then
  SNAP_SET=$(sudo snap save 2>/dev/null | awk 'NR==2{print $1}')
  if [[ -n "$SNAP_SET" ]] && sudo snap export-snapshot "$SNAP_SET" "$S/snap-snapshot.export" >/dev/null 2>&1; then
    sudo chown "$(id -u):$(id -g)" "$S/snap-snapshot.export" 2>/dev/null
    sudo snap forget "$SNAP_SET" >/dev/null 2>&1
    ok "snap data snapshot (set $SNAP_SET)"
  else
    warn "snap data snapshot failed (snap list is saved anyway)"
  fi
fi
crontab -l > "$S/crontab-user.txt" 2>/dev/null || true

info "[4/7] System information"
M="$B/meta"
{
  echo "user=$USER_NAME"; echo "uid=$(id -u)"; echo "groups=$(id -Gn)"
  echo "hostname=$(hostnamectl --static 2>/dev/null || cat /etc/hostname)"
  echo "os_id=$OS_ID"
  echo "os_version=$(os_field VERSION_ID)"
  echo "os_codename=$(os_field VERSION_CODENAME)"
  echo "pm=$PM"
  echo "aur_helper=$AUR_HELPER"
  echo "de=$DE"
  echo "date=$(date -Is)"
} > "$M/system-info.env"
cat /etc/os-release > "$M/os-release.txt"
localectl status > "$M/locale.txt" 2>&1
timedatectl show > "$M/timedate.txt" 2>&1
lsblk -f > "$M/lsblk.txt" 2>&1
cat /etc/fstab > "$M/fstab.txt"
systemctl list-unit-files --state=enabled --no-pager > "$M/systemd-enabled.txt" 2>&1
systemctl --user list-unit-files --state=enabled --no-pager > "$M/systemd-user-enabled.txt" 2>&1
nmcli -t -f NAME,TYPE con show > "$M/nm-connections.txt" 2>&1
lspci > "$M/lspci.txt" 2>&1
ok "info saved"

info "[5/7] Full home archive ($(numfmt --to=iec "$HOME_BYTES")) — this is the long part"
EXCL_ARGS=()
for e in "${EXCLUDES[@]}"; do EXCL_ARGS+=("--exclude=$e"); done
printf '%s\n' "${EXCLUDES[@]}" > "$M/home-excludes.txt"
if command -v pv >/dev/null; then
  tar -C /home -cpf - --xattrs --acls "${EXCL_ARGS[@]}" "$USER_NAME" 2>>"$M/tar-home-warnings.log" \
    | pv -s "$HOME_BYTES" | zstd -T0 -q -3 -o "$B/home.tar.zst"
  check_tar "home" "${PIPESTATUS[0]}" "${PIPESTATUS[2]}"
else
  tar -C /home -cpf - --xattrs --acls "${EXCL_ARGS[@]}" "$USER_NAME" 2>>"$M/tar-home-warnings.log" \
    | zstd -T0 -3 -o "$B/home.tar.zst"
  check_tar "home" "${PIPESTATUS[@]}"
fi
ls -lh "$B/home.tar.zst"

if ((IS_KDE)); then
  info "[6/7] Saving KDE look & feel with konsave"
  if command -v konsave >/dev/null; then
    KTMP="$HOME/.cache/konsave-export-tmp"
    rm -rf "$KTMP"; mkdir -p "$KTMP"
    konsave -s migrazione -f && \
    konsave -e migrazione -d "$KTMP" -n migrazione -f && \
    cp "$KTMP/migrazione.knsv" "$B/critical/" && ok "konsave: profile 'migrazione' exported" \
      || warn "konsave: save/export failed"
    if konsave -l 2>/dev/null | grep -qw plasma6_backup; then
      konsave -e plasma6_backup -d "$KTMP" -n plasma6_backup -f >/dev/null 2>&1 && \
      cp "$KTMP/plasma6_backup.knsv" "$B/critical/" \
        && ok "konsave: profile 'plasma6_backup' exported" || warn "konsave: plasma6_backup export failed"
    fi
    rm -rf "$KTMP"
    ls -lh "$B"/critical/*.knsv 2>/dev/null
  else
    warn "konsave not found! Install it with: python3 -m pip install --user konsave"
  fi
else
  info "[6/7] Desktop look & feel: $DE is not KDE, konsave skipped (settings are in the home archive)"
fi

info "[7/7] Verifying archive integrity"
VERIFY_OK=1
for a in "$B"/home.tar.zst "$B"/critical/critical.tar.zst "$B"/system/*.tar.zst; do
  [[ -f "$a" ]] || continue
  if zstd -dc "$a" 2>/dev/null | tar -tf - >/dev/null 2>&1; then ok "intact: ${a#"$B/"}"
  else warn "CORRUPTED ARCHIVE: $a"; VERIFY_OK=0; fi
done
zstd -dc "$B/critical/critical.tar.zst" | tar -tf - > "$M/critical-list.txt"
for must in "$USER_NAME/.ssh/id_ed25519" "$USER_NAME/.ssh/config" "$USER_NAME/.claude/projects/" "$USER_NAME/.claude.json"; do
  grep -q "^$must" "$M/critical-list.txt" && ok "present: $must" || { warn "MISSING: $must"; VERIFY_OK=0; }
done
if ((IS_KDE)); then
  ls "$B"/critical/migrazione.knsv >/dev/null 2>&1 && ok "present: konsave profile" || { warn "MISSING: konsave profile"; VERIFY_OK=0; }
fi

mkdir -p "$B/lib"
cp "$ROOT_DIR/migrate.sh" "$B/" || warn "migrate.sh not found in $ROOT_DIR"
cp "$ROOT_DIR/README.md" "$B/" 2>/dev/null
cp "$SCRIPT_DIR"/*.sh "$B/lib/" || warn "could not copy lib/ scripts into the backup"
chmod +x "$B"/*.sh "$B"/lib/*.sh 2>/dev/null

info "Computing SHA256 checksums..."
( cd "$B" && find . -type f ! -name SHA256SUMS ! -name backup.log -print0 | xargs -0 sha256sum > SHA256SUMS )
sync

echo
echo "Finished: $(date)"
du -sh "$B"
if ((${#WARNINGS[@]})); then
  echo "${YLW}Warnings:${RST}"; printf '  - %s\n' "${WARNINGS[@]}"
fi
if [[ $VERIFY_OK -eq 1 ]]; then
  echo "${GRN}BACKUP COMPLETED AND VERIFIED:${RST} $B"
else
  echo "${RED}BACKUP HAS ERRORS — check the warnings above and $LOG before formatting!${RST}"
  exit 1
fi
