#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$HERE/lib"
[[ -f "$LIB/common.sh" ]] || { echo "lib/common.sh not found next to $0"; exit 1; }
source "$LIB/common.sh"

SELECTED_DIR=""
SELECTED_DEV=""
MOUNTED_WITH_SUDO=0

disk_of() { lsblk -lspno NAME,TYPE "$1" 2>/dev/null | awk '$2=="disk"{print $1; exit}'; }
mountpoint_of() { findmnt -no TARGET -S "$1" 2>/dev/null | head -1; }

system_disks() {
  local m src
  for m in / /boot /home "$HOME"; do
    src="$(findmnt -no SOURCE --target "$m" 2>/dev/null | sed 's/\[.*//')"
    [[ -b "$src" ]] && disk_of "$src"
  done | sort -u
}

list_volumes() {
  local sys dev type fs
  sys="$(system_disks)"
  lsblk -lpno NAME,TYPE | while read -r dev type; do
    [[ "$type" == part || "$type" == disk || "$type" == crypt ]] || continue
    fs="$(lsblk -dno FSTYPE "$dev")"
    case "$fs" in ext2|ext3|ext4|btrfs|xfs|f2fs|exfat|vfat|ntfs|ntfs3) ;; *) continue ;; esac
    [[ -n "$sys" ]] && grep -qxF "$(disk_of "$dev")" <<<"$sys" && continue
    echo "$dev"
  done
}

mount_volume() {
  local dev="$1" mp fs opts=()
  mp="$(mountpoint_of "$dev")"
  if [[ -z "$mp" ]]; then
    echo "Mounting $dev ..."
    if udisksctl mount -b "$dev" >/dev/null 2>&1; then
      MOUNTED_WITH_SUDO=0
    else
      echo "${YLW}udisksctl failed, trying with sudo mount...${RST}"
      fs="$(lsblk -dno FSTYPE "$dev")"
      case "$fs" in vfat|exfat|ntfs|ntfs3) opts=(-o "uid=$(id -u),gid=$(id -g)") ;; esac
      mp="/mnt/$(basename "$dev")"
      sudo mkdir -p "$mp" && sudo mount "${opts[@]}" "$dev" "$mp" || die "Cannot mount $dev"
      MOUNTED_WITH_SUDO=1
    fi
    mp="$(mountpoint_of "$dev")"
    [[ -n "$mp" ]] || die "$dev does not seem to be mounted"
  fi
  echo "${GRN}[OK]${RST} $dev mounted at $mp"
  SELECTED_DEV="$dev"
  SELECTED_DIR="$mp"
}

unmount_volume() {
  local dev="$1"
  sync
  if [[ $MOUNTED_WITH_SUDO -eq 1 ]]; then sudo umount "$dev"
  else udisksctl unmount -b "$dev"
  fi && echo "${GRN}[OK]${RST} $dev unmounted: you can unplug it." || echo "${YLW}Could not unmount $dev${RST}"
}

choose_volume() {
  local title="$1" vols v i c mp
  SELECTED_DIR=""; SELECTED_DEV=""
  while true; do
    mapfile -t vols < <(list_volumes)
    echo
    echo "${BLU}==>${RST} $title"
    if ((${#vols[@]})); then
      i=1
      for v in "${vols[@]}"; do
        mp="$(mountpoint_of "$v")"
        printf '  %d) %-22s %7s  %-6s  %-16s %s\n' "$i" "$v" "$(lsblk -dno SIZE "$v" | tr -d ' ')" \
          "$(lsblk -dno FSTYPE "$v")" "$(lsblk -dno LABEL "$v")" "${mp:-(not mounted)}"
        i=$((i+1))
      done
    else
      echo "  ${YLW}No external disk found. Plug one in and choose r.${RST}"
    fi
    echo "  r) rescan"
    echo "  p) enter a path manually"
    echo "  q) quit"
    read -rp "Choice: " c
    case "$c" in
      q) exit 0 ;;
      r|"") continue ;;
      p) read -rp "Path: " SELECTED_DIR
         [[ -d "$SELECTED_DIR" ]] && return 0
         echo "${RED}Not a directory: $SELECTED_DIR${RST}"; SELECTED_DIR="" ;;
      *) if [[ "$c" =~ ^[0-9]+$ && $c -ge 1 && $c -le ${#vols[@]} ]]; then
           mount_volume "${vols[$((c-1))]}"; return 0
         fi
         echo "${RED}Invalid choice${RST}" ;;
    esac
  done
}

is_verified() {
  grep -qE 'BACKUP (COMPLETED AND VERIFIED|COMPLETATO E VERIFICATO)' "$1/backup.log" 2>/dev/null
}

choose_backup() {
  local root="$1" backups b i=1 c tag
  mapfile -t backups < <(find "$root" -maxdepth 2 -type d \( -name 'system-backup-*' -o -name 'fedora-backup-*' \) 2>/dev/null \
                         | while read -r b; do [[ -f "$b/home.tar.zst" ]] && echo "$b"; done | sort -r)
  ((${#backups[@]})) || die "No backup (system-backup-*) found in $root"
  echo
  echo "${BLU}==>${RST} Backups found in $root"
  for b in "${backups[@]}"; do
    if is_verified "$b"; then tag="${GRN}[verified]${RST}"; else tag="${YLW}[not verified!]${RST}"; fi
    echo "  $i) ${b#"$root/"}  $tag"
    i=$((i+1))
  done
  read -rp "Which backup do you want to restore? [1] " c
  c="${c:-1}"
  [[ "$c" =~ ^[0-9]+$ && $c -ge 1 && $c -le ${#backups[@]} ]] || die "Invalid choice"
  SELECTED_DIR="${backups[$((c-1))]}"
}

do_save() {
  local dest="${1:-}" rc
  [[ -f "$LIB/backup.sh" ]]  || die "backup.sh not found in $LIB"
  [[ -f "$LIB/restore.sh" ]] || die "restore.sh not found in $LIB"
  if [[ -z "$dest" ]]; then
    choose_volume "Where should the backup be saved?"
    dest="$SELECTED_DIR"
  fi
  [[ -d "$dest" ]] || die "Destination not found: $dest"
  if [[ ! -w "$dest" ]]; then
    echo "${YLW}$dest is not writable by $(id -un): creating $dest/backups owned by you.${RST}"
    sudo install -d -o "$(id -u)" -g "$(id -g)" "$dest/backups" || die "Cannot create $dest/backups"
    dest="$dest/backups"
  fi
  echo
  echo "${GRN}BACKUP${RST} of this system to: $dest"
  local extra=()
  yes_no "Include the Trash too?" && extra=(--include-trash)
  bash "$LIB/backup.sh" "$dest" "${extra[@]}"
  rc=$?
  if [[ -n "$SELECTED_DEV" ]] && yes_no "Unmount $SELECTED_DEV now?"; then unmount_volume "$SELECTED_DEV"; fi
  exit $rc
}

do_restore() {
  local dir="${1:-}" script
  if [[ -z "$dir" && -f "$HERE/home.tar.zst" ]]; then
    dir="$HERE"
  elif [[ -z "$dir" ]]; then
    choose_volume "Which disk contains the backup?"
    choose_backup "$SELECTED_DIR"
    dir="$SELECTED_DIR"
  fi
  dir="$(cd "$dir" 2>/dev/null && pwd)" || die "Backup folder not found"
  [[ -f "$dir/home.tar.zst" ]] || die "$dir is not a backup folder (home.tar.zst missing)"
  if   [[ -f "$LIB/restore.sh" ]];     then script="$LIB/restore.sh"
  elif [[ -f "$dir/lib/restore.sh" ]]; then script="$dir/lib/restore.sh"
  elif [[ -f "$dir/restore.sh" ]];     then script="$dir/restore.sh"
  else die "restore.sh missing"; fi
  echo
  echo "${GRN}RESTORE${RST} from: $dir"
  is_verified "$dir" || echo "${YLW}Warning: backup.log does not say the backup was verified.${RST}"
  yes_no "Confirm? Files in the current home will be overwritten." || exit 0
  exec bash "$script" "$dir"
}

do_mount() {
  choose_volume "Which disk do you want to mount?"
  echo "Mounted at: $SELECTED_DIR"
}

case "${1:-}" in
  save|backup)   shift; do_save "$@" ;;
  restore)       shift; do_restore "$@" ;;
  mount)         do_mount ;;
  "")
    echo "=========================================="
    echo "  migrate — Linux system migration"
    echo "=========================================="
    echo "System: $(os_field PRETTY_NAME)  |  package manager: $PM"
    echo "Desktop environment: $(detect_de)"
    [[ -f "$HERE/home.tar.zst" ]] && echo "${YLW}Running from inside a backup:${RST} $HERE"
    echo "  1) SAVE    — back up this system to an external disk"
    echo "  2) RESTORE — restore this system from a backup"
    echo "  3) MOUNT   — just mount an external disk"
    echo "  q) quit"
    read -rp "Choice: " c
    case "$c" in
      1) do_save ;;
      2) do_restore ;;
      3) do_mount ;;
      *) exit 0 ;;
    esac ;;
  *) die "Usage: bash $0 [save [DEST] | restore [BACKUP_DIR] | mount]" ;;
esac
