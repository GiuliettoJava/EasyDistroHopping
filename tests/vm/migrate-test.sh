#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
VM="$HERE/vm.sh"
VM_HOME="${VM_HOME:-$HOME/.local/share/backupping-vms}"

usage() {
  cat <<EOF
Usage: tests/vm/migrate-test.sh SRC_DISTRO DST_DISTRO [options]

Full migration in VMs: SRC is provisioned with test data, backed up with
migrate.sh to a virtual USB stick, then DST is restored from it and checked.

  --fs ext4|exfat|btrfs   filesystem of the USB stick (default ext4)
  --keep                  leave both VMs (stopped) for inspection
  --mem MB                RAM per VM (default 3072)

Distros: fedora, debian, ubuntu, arch
EOF
  exit 1
}

(($# >= 2)) || usage
SRC_D="$1"; DST_D="$2"; shift 2
FS=ext4; KEEP=0; MEM=3072
while (($#)); do case "$1" in
  --fs) FS="$2"; shift 2 ;; --keep) KEEP=1; shift ;; --mem) MEM="$2"; shift 2 ;;
  *) usage ;; esac; done

RUN_ID="$(date +%Y%m%d-%H%M%S)"
SRC="src-$SRC_D"; DST="dst-$DST_D"; STICK="stick-$RUN_ID"
OUT="$VM_HOME/results/$RUN_ID-$SRC_D-to-$DST_D"
mkdir -p "$OUT"
exec > >(tee "$OUT/test.log") 2>&1

step() { echo; echo "######## $*"; }
on() { "$VM" exec "$@"; }

cleanup() {
  "$VM" stop "$SRC" >/dev/null 2>&1 || true
  "$VM" stop "$DST" >/dev/null 2>&1 || true
  if ((KEEP == 0)); then
    "$VM" destroy "$SRC" >/dev/null 2>&1 || true
    "$VM" destroy "$DST" >/dev/null 2>&1 || true
    "$VM" usb-rm "$STICK" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

PREP_PKGS='
install_pkgs() {
  if   command -v dnf     >/dev/null; then sudo dnf install -y -q "$@"
  elif command -v apt-get >/dev/null; then sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@"
  elif command -v pacman  >/dev/null; then sudo pacman -Syu --noconfirm --needed "$@"
  fi
}
fs_module() {
  sudo modprobe "$1" 2>/dev/null && return
  command -v dnf >/dev/null && sudo dnf install -y -q "kernel-modules-$(uname -r)" && sudo modprobe "$1"
}
usb_dev() { lsblk -dpno NAME,TRAN | awk '"'"'$2=="usb"{print $1; exit}'"'"'; }
'

pm_of() { case "$1" in fedora) echo dnf ;; debian|ubuntu) echo apt ;; arch) echo pacman ;; esac; }
TOKEN="token-$RUN_ID-$RANDOM"

for v in "$SRC" "$DST"; do "$VM" destroy "$v" >/dev/null 2>&1 || true; done

step "Create USB stick and source VM ($SRC_D)"
"$VM" usb "$STICK" 24G
"$VM" create "$SRC" "$SRC_D"
"$VM" start "$SRC" --mem "$MEM" --usb "$STICK"
"$VM" wait "$SRC"
"$VM" push "$SRC"

step "Provision source with test data"
cron_pkg=""; case "$SRC_D" in debian|ubuntu) cron_pkg=cron ;; fedora) cron_pkg=cronie ;; arch) cron_pkg=cronie ;; esac
mkfs_pkg=""; case "$FS" in exfat) mkfs_pkg=exfatprogs ;; btrfs) mkfs_pkg=btrfs-progs ;; esac
on "$SRC" bash -s <<EOF
set -e
$PREP_PKGS
fs_module $FS
install_pkgs zstd htop tree $mkfs_pkg $cron_pkg
mkdir -p ~/Documents ~/.ssh ~/.config/testapp ~/.local/share/Trash/files
echo "$TOKEN" > ~/Documents/marker.txt
echo "trash" > ~/.local/share/Trash/files/old.txt
printf 'Host example\n  HostName example.org\n' > ~/.ssh/config; chmod 600 ~/.ssh/config
echo "setting=$TOKEN" > ~/.config/testapp/app.conf
echo "alias migrated='echo $TOKEN'" >> ~/.bashrc
(crontab -l 2>/dev/null; echo "17 3 * * * echo $TOKEN >/dev/null") | crontab - || true
echo "vm.swappiness = 17" | sudo tee /etc/sysctl.d/99-migrate-test.conf >/dev/null
echo "10.17.17.17 migrate-test.local" | sudo tee -a /etc/hosts >/dev/null
sudo mkdir -p /opt/testapp && echo "$TOKEN" | sudo tee /opt/testapp/VERSION >/dev/null
echo "$TOKEN" | sudo tee /usr/local/bin/migrate-test >/dev/null
dev=\$(usb_dev); [ -n "\$dev" ] || { echo "USB stick not found"; exit 1; }
case "$FS" in
  ext4)  sudo mkfs.ext4 -q -F -L MIGRATE "\$dev" ;;
  exfat) sudo mkfs.exfat -L MIGRATE "\$dev" >/dev/null ;;
  btrfs) sudo mkfs.btrfs -q -f -L MIGRATE "\$dev" ;;
esac
fs_module $FS
sudo mkdir -p /mnt/usb
opts=""; [ "$FS" = exfat ] && opts="-o uid=\$(id -u),gid=\$(id -g)"
sudo mount \$opts "\$dev" /mnt/usb
echo "USB \$dev ($FS) mounted on /mnt/usb"
EOF

step "Backup on source"
set +e
on "$SRC" 'printf "n\n" | bash ~/backupping/migrate.sh save /mnt/usb'
BACKUP_RC=$?
set -e
on "$SRC" 'sync; d=$(ls -d /mnt/usb/system-backup-* /mnt/usb/backups/system-backup-* 2>/dev/null | tail -1); cp "$d/backup.log" /tmp/backup.log 2>/dev/null; ls -la "$d"; sudo umount /mnt/usb' || true
"$VM" pull "$SRC" /tmp/backup.log "$OUT" || true
"$VM" stop "$SRC"
((BACKUP_RC == 0)) || { echo "BACKUP FAILED (rc=$BACKUP_RC)"; exit 1; }

step "Create destination VM ($DST_D) and restore"
"$VM" create "$DST" "$DST_D"
"$VM" start "$DST" --mem "$MEM" --usb "$STICK"
"$VM" wait "$DST"
set +e
on "$DST" bash -s <<EOF
$PREP_PKGS
[ "$FS" = exfat ] && install_pkgs exfatprogs >/dev/null
[ "$FS" = btrfs ] && install_pkgs btrfs-progs >/dev/null
fs_module $FS
sudo mkdir -p /mnt/usb
opts=""; [ "$FS" = exfat ] && opts="-o uid=\$(id -u),gid=\$(id -g)"
sudo mount \$opts "\$(usb_dev)" /mnt/usb || exit 1
d=\$(ls -d /mnt/usb/system-backup-* /mnt/usb/backups/system-backup-* 2>/dev/null | tail -1)
echo "Backup: \$d"
yes y | bash "\$d/migrate.sh" restore "\$d"
EOF
RESTORE_RC=$?
set -e
on "$DST" 'cat ~/restore-*.log' >"$OUT/restore.log" 2>/dev/null || true

step "Checks on destination"
CHECKS=$(on "$DST" bash -s <<EOF
c() { if eval "\$2" >/dev/null 2>&1; then echo "PASS  \$1"; else echo "FAIL  \$1"; fi; }
c "home file"            'grep -qx "$TOKEN" ~/Documents/marker.txt'
c "dotfile in .config"   'grep -q "$TOKEN" ~/.config/testapp/app.conf'
c "bashrc"               'grep -q "$TOKEN" ~/.bashrc'
c "trash excluded"       '[ ! -e ~/.local/share/Trash/files/old.txt ]'
c "ssh config perms"     '[ "\$(stat -c %a ~/.ssh/config)" = 600 ]'
c "crontab"              'crontab -l | grep -q "$TOKEN"'
c "sysctl.d"             '[ -f /etc/sysctl.d/99-migrate-test.conf ]'
c "hosts"                'grep -q migrate-test.local /etc/hosts'
c "/opt"                 'grep -qx "$TOKEN" /opt/testapp/VERSION'
c "/usr/local"           'grep -qx "$TOKEN" /usr/local/bin/migrate-test'
c "hostname"             '[ "\$(hostnamectl --static 2>/dev/null || hostname)" = "$SRC" ]'
c "owner of home"        '[ -z "\$(find ~ -xdev ! -user \$(id -un) -print -quit)" ]'
if [ "$(pm_of "$SRC_D")" = "$(pm_of "$DST_D")" ]; then
  c "package htop"       'command -v htop'
  c "package tree"       'command -v tree'
fi
EOF
) || true
echo "$CHECKS" | tee "$OUT/checks.txt"
grep -A50 'Restore finished with' "$OUT/restore.log" | sed -n '1,30p' || true

FAILS=$(grep -c '^FAIL' <<<"$CHECKS" || true)
echo
echo "Backup rc=$BACKUP_RC  restore rc=$RESTORE_RC  failed checks=$FAILS"
echo "Logs: $OUT"
((RESTORE_RC == 0 && FAILS == 0))
