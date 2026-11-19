#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RED=$'\e[31m'; GRN=$'\e[32m'; YLW=$'\e[33m'; RST=$'\e[0m'
die() { echo "${RED}[ERROR]${RST} $*"; exit 1; }

pick_dest() {
  local disks=() d i=1 c
  for d in /run/media/"$(id -un)"/*/; do [[ -d "$d" ]] && disks+=("${d%/}"); done
  ((${#disks[@]})) || die "No external disk mounted in /run/media/$(id -un). Plug in the USB stick and open it in Dolphin, then try again." >&2
  echo "Available external disks:" >&2
  for d in "${disks[@]}"; do
    echo "  $i) $d  ($(df -h --output=avail "$d" | tail -1 | tr -d ' ') free, $(findmnt -no FSTYPE --target "$d"))" >&2
    i=$((i+1))
  done
  read -rp "Which disk should the backup be saved to? [1] " c
  c="${c:-1}"
  [[ "$c" =~ ^[0-9]+$ && $c -ge 1 && $c -le ${#disks[@]} ]] || die "Invalid choice" >&2
  echo "${disks[$((c-1))]}"
}

do_save() {
  local dest="${1:-}"
  if [[ -z "$dest" ]]; then
    if [[ "$HERE" == /run/media/* ]]; then dest="$HERE"; else dest="$(pick_dest)" || exit 1; fi
  fi
  [[ -f "$HERE/backup.sh" ]]  || die "backup.sh not found in $HERE"
  [[ -f "$HERE/restore.sh" ]] || die "restore.sh not found in $HERE"
  echo "${GRN}BACKUP${RST} of this system to: $dest"
  read -rp "Include the Trash too (~10GB)? [y/N] " t
  local extra=(); [[ "$t" =~ ^[sSyY]$ ]] && extra=(--include-trash)
  exec bash "$HERE/backup.sh" "$dest" "${extra[@]}"
}

find_backup() {
  [[ -f "$HERE/home.tar.zst" ]] && { echo "$HERE"; return; }
  ls -1d "$HERE"/fedora-backup-*/ 2>/dev/null | sort | tail -1 | sed 's:/$::'
}

do_restore() {
  local dir="${1:-$(find_backup)}"
  [[ -n "$dir" && -f "$dir/home.tar.zst" ]] || die "No backup found (searched in $HERE). Pass the path: bash $0 restore /path/fedora-backup-XXXX"
  [[ -f "$dir/restore.sh" ]] || cp "$HERE/restore.sh" "$dir/" 2>/dev/null || die "restore.sh missing"
  echo "${GRN}RESTORE${RST} from: $dir"
  read -rp "Confirm? Files in the current home will be overwritten. [y/N] " a
  [[ "$a" =~ ^[sSyY]$ ]] || exit 0
  exec bash "$dir/restore.sh"
}

case "${1:-}" in
  save|backup)   shift; do_save "$@" ;;
  restore)       shift; do_restore "$@" ;;
  "")
    echo "=========================================="
    echo "  saveRestore — Fedora KDE migration"
    echo "=========================================="
    b="$(find_backup)"
    [[ -n "$b" ]] && echo "${YLW}Backup found:${RST} $b"
    echo "  1) SAVE    — back up this system (old PC)"
    echo "  2) RESTORE — from backup (fresh new system)"
    echo "  q) quit"
    read -rp "Choice: " c
    case "$c" in
      1) do_save ;;
      2) do_restore ;;
      *) exit 0 ;;
    esac ;;
  *) die "Usage: bash $0 [save [DEST] | restore [DIR]]" ;;
esac
