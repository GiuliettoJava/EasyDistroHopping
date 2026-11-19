#!/usr/bin/env bash
set -uo pipefail

DEST_ROOT="${1:-}"
INCLUDE_TRASH=0
[[ "${2:-}" == "--include-trash" ]] && INCLUDE_TRASH=1

RED=$'\e[31m'; GRN=$'\e[32m'; YLW=$'\e[33m'; BLU=$'\e[34m'; RST=$'\e[0m'
die()  { echo "${RED}[ERROR]${RST} $*"; exit 1; }
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
B="$DEST_ROOT/fedora-backup-$STAMP"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

FSTYPE="$(findmnt -no FSTYPE --target "$DEST_ROOT")"
case "$FSTYPE" in
  vfat|msdos) die "Destination is FAT32: it does not support files >4GB. Format the disk as ext4, btrfs or exFAT." ;;
esac
info "Destination filesystem: $FSTYPE"
if [[ "$(findmnt -no SOURCE --target "$DEST_ROOT" | sed 's/\[.*//')" == "$(findmnt -no SOURCE --target "$HOME" | sed 's/\[.*//')" ]]; then
  die "Destination '$DEST_ROOT' is on the same disk as your home! Use the external USB stick/disk (e.g. /run/media/$(id -un)/<DISK>)."
fi

EXCLUDES=(
  "$USER_NAME/.cache"
  "$USER_NAME/.local/share/baloo"
  "$USER_NAME/.local/share/flatpak"
  "$USER_NAME/.var/app/*/cache"
  "$USER_NAME/.claude.json.tmp.*"
)
[[ $INCLUDE_TRASH -eq 1 ]] || EXCLUDES+=("$USER_NAME/.local/share/Trash")
case "$DEST_ROOT/" in
  "$HOME_DIR/"*) EXCLUDES+=("$USER_NAME/${DEST_ROOT#"$HOME_DIR/"}/fedora-backup-*") ;;
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

info "[1/7] Separate archive of critical files (SSH, Claude Code, wallet, git)"
CRIT=()
for f in .ssh .claude .claude.json .local/share/claude .local/bin/claude .gnupg \
         .local/share/kwalletd .gitconfig .config/gh .config/konsave .bashrc .bash_profile \
         .local/share/DBeaverData .config/filezilla .putty .mongodb; do
  [[ -e "$HOME_DIR/$f" || -L "$HOME_DIR/$f" ]] && CRIT+=("$USER_NAME/$f")
done
tar -C /home -cpf - --xattrs --acls "${CRIT[@]}" 2>>"$B/meta/tar-critical-warnings.log" \
  | zstd -T0 -q -3 -o "$B/critical/critical.tar.zst"
check_tar "critical files" "${PIPESTATUS[@]}"
cp -a "$HOME_DIR/.ssh/config" "$B/critical/ssh_config.txt" 2>/dev/null
ls -1 "$HOME_DIR/.claude/projects" > "$B/critical/claude-projects.txt" 2>/dev/null

info "[2/7] Package lists (dnf, flatpak, pip, pipx, VS Code)"
P="$B/pkgs"
dnf repoquery --userinstalled --qf '%{name}\n' 2>/dev/null | sort -u > "$P/dnf-userinstalled.txt"
dnf repoquery --installed --qf '%{name} %{from_repo}\n' 2>/dev/null \
  | awk '$2=="@commandline" || $2=="<unknown>" {print $1}' | sort -u > "$P/dnf-local-rpms.txt"
rpm -qa --qf '%{NAME}\t%{VERSION}-%{RELEASE}\t%{ARCH}\n' | sort > "$P/rpm-all-installed.tsv"
dnf copr list > "$P/copr.txt" 2>/dev/null
flatpak list --app --columns=application,installation,origin > "$P/flatpak-apps.tsv" 2>/dev/null
flatpak remotes --columns=name,url,options > "$P/flatpak-remotes.tsv" 2>/dev/null
pip list --user --format=freeze > "$P/pip-user.txt" 2>/dev/null
command -v pipx >/dev/null && pipx list --short > "$P/pipx.txt" 2>/dev/null
command -v code >/dev/null && code --list-extensions > "$P/vscode-extensions.txt" 2>/dev/null
ok "dnf: $(wc -l < "$P/dnf-userinstalled.txt") user packages, $(wc -l < "$P/dnf-local-rpms.txt") local rpms; flatpak: $(($(wc -l < "$P/flatpak-apps.tsv"))) apps"

info "[3/7] System files (full /etc, GRUB theme, /opt, Wi-Fi/VPN)"
S="$B/system"
sudo tar -C / -cpf - --xattrs --acls etc 2>>"$B/meta/tar-etc-warnings.log" | zstd -T0 -q -3 -o "$S/etc.tar.zst"
check_tar "/etc" "${PIPESTATUS[@]}"
if sudo test -d /boot/grub2/themes; then
  sudo tar -C /boot/grub2 -cpf - themes | zstd -T0 -q -o "$S/grub-themes.tar.zst"
  check_tar "GRUB theme" "${PIPESTATUS[@]}"
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
crontab -l > "$S/crontab-user.txt" 2>/dev/null || true

info "[4/7] System information"
M="$B/meta"
{
  echo "user=$USER_NAME"; echo "uid=$(id -u)"; echo "groups=$(id -Gn)"
  echo "hostname=$(hostnamectl hostname)"
  echo "fedora=$(rpm -E %fedora)"
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
  warn "konsave not found!"
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
ls "$B"/critical/migrazione.knsv >/dev/null 2>&1 && ok "present: konsave profile" || { warn "MISSING: konsave profile"; VERIFY_OK=0; }

cp "$SCRIPT_DIR/restore.sh" "$B/" 2>/dev/null || warn "restore.sh not found next to backup.sh"
cp "$SCRIPT_DIR/backup.sh"  "$B/"
cp "$SCRIPT_DIR/saveRestore.sh" "$B/" 2>/dev/null
cp "$SCRIPT_DIR/README.md" "$B/" 2>/dev/null
chmod +x "$B"/*.sh 2>/dev/null

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
