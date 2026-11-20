#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
VM="$HERE/vm.sh"
VM_HOME="${VM_HOME:-$HOME/.local/share/easydistrohopping-vms}"

usage() {
  cat <<EOF
Usage: tests/vm/edge-test.sh [DISTRO] [--keep] [--mem MB]

Edge cases in a single VM (default distro: fedora): refused destinations,
disk picker, odd mount paths, corrupted backup, different user, trial backup,
shellcheck.
EOF
  exit 1
}

D=fedora; KEEP=0; MEM=3072
while (($#)); do case "$1" in
  --keep) KEEP=1; shift ;; --mem) MEM="$2"; shift 2 ;; -h|--help) usage ;;
  -*) usage ;; *) D="$1"; shift ;; esac; done

RUN_ID="$(date +%Y%m%d-%H%M%S)"
NAME="edge-$D"; STICK="edge-stick-$RUN_ID"
OUT="$VM_HOME/results/$RUN_ID-edge-$D"
mkdir -p "$OUT"
exec > >(tee "$OUT/test.log") 2>&1

cleanup() {
  "$VM" stop "$NAME" >/dev/null 2>&1 || true
  if ((KEEP == 0)); then
    "$VM" destroy "$NAME" >/dev/null 2>&1 || true
    "$VM" usb-rm "$STICK" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

"$VM" destroy "$NAME" >/dev/null 2>&1 || true
"$VM" usb "$STICK" 16G
"$VM" create "$NAME" "$D"
"$VM" start "$NAME" --mem "$MEM" --usb "$STICK"
"$VM" wait "$NAME"
"$VM" push "$NAME"

"$VM" exec "$NAME" bash -s <<'EOF' | tee "$OUT/results.txt"
set -u
R=~/EasyDistroHopping
res() { printf '%-5s %-28s %s\n' "$1" "$2" "${3:-}"; }
expect() { local name="$1" want="$2" log="$3"; if grep -q -- "$want" "$log"; then res PASS "$name"; else res FAIL "$name" "expected: $want"; tail -n 5 "$log" | sed 's/^/      | /'; fi; }

install_pkgs() {
  if   command -v dnf     >/dev/null; then sudo dnf install -y -q "$@"
  elif command -v apt-get >/dev/null; then sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@"
  elif command -v pacman  >/dev/null; then sudo pacman -Syu --noconfirm --needed "$@"
  fi >/dev/null 2>&1
}
install_pkgs zstd dosfstools
command -v dnf >/dev/null && ! sudo modprobe vfat 2>/dev/null && install_pkgs "kernel-modules-$(uname -r)"
sudo modprobe vfat 2>/dev/null
mkdir -p ~/Documents ~/.ssh
echo edge-marker > ~/Documents/marker.txt
printf 'Host x\n  HostName x.example\n' > ~/.ssh/config; chmod 600 ~/.ssh/config
USB=$(lsblk -dpno NAME,TRAN | awk '$2=="usb"{print $1; exit}')
sudo mkfs.ext4 -q -F -L EDGE "$USB"

loopdisk() {
  local f="/var/tmp/$1.img" mp="/mnt/$1"
  sudo truncate -s "$2" "$f"; sudo mkdir -p "$mp"
  case "$3" in
    vfat) sudo mkfs.vfat -F 32 "$f" >/dev/null; sudo mount -o loop,uid=$(id -u),gid=$(id -g) "$f" "$mp" ;;
    ext4) sudo mkfs.ext4 -q -F "$f"; sudo mount -o loop "$f" "$mp"; sudo chown "$(id -u):$(id -g)" "$mp" ;;
  esac
}

loopdisk fat 3G vfat
printf 'n\n' | bash $R/migrate.sh save /mnt/fat > /tmp/e1.log 2>&1
expect "refuses FAT32" "FAT32" /tmp/e1.log

mkdir -p ~/bk
printf 'n\n' | bash $R/migrate.sh save ~/bk > /tmp/e2.log 2>&1
expect "refuses the home disk" "same disk as your home" /tmp/e2.log
rmdir ~/bk 2>/dev/null

loopdisk small 1G ext4
printf 'n\n' | bash $R/migrate.sh save /mnt/small > /tmp/e3.log 2>&1
expect "refuses a full disk" "Not enough space" /tmp/e3.log

sudo truncate -s 6G /var/tmp/two.img
printf 'label: gpt\n,3G\n,\n' | sudo sfdisk -q /var/tmp/two.img
LOOP=$(sudo losetup -fP --show /var/tmp/two.img)
sudo mkfs.ext4 -q -F "${LOOP}p1"; sudo mkfs.ext4 -q -F "${LOOP}p2"
sudo mkdir -p /mnt/p1 /mnt/p2
sudo mount "${LOOP}p1" /mnt/p1; sudo mount "${LOOP}p2" /mnt/p2
sudo install -d -o "$(id -u)" -g "$(id -g)" /mnt/p1/fakehome /mnt/p2/dest
HOME=/mnt/p1/fakehome bash $R/lib/backup.sh /mnt/p2/dest > /tmp/e3b.log 2>&1 </dev/null
expect "refuses another partition of the home disk" "same disk as your home" /tmp/e3b.log
sudo umount /mnt/p1 /mnt/p2; sudo losetup -d "$LOOP"; sudo rm -f /var/tmp/two.img

printf 'q\n' | bash $R/migrate.sh mount > /tmp/e4-list.log 2>&1
sed -n '/==>/,/q) quit/p' /tmp/e4-list.log | sed 's/^/      | /'
IDX=$(grep -E "^ +[0-9]+\) $USB " /tmp/e4-list.log | grep -oE '[0-9]+' | head -1)
grep -qE "^ +[0-9]+\) /dev/vda" /tmp/e4-list.log && res FAIL "picker hides system disk" || res PASS "picker hides system disk"
if [[ -z "$IDX" ]]; then
  res FAIL "picker lists the USB stick"
else
  res PASS "picker lists the USB stick" "choice $IDX"
  printf '%s\nn\ny\n' "$IDX" | bash $R/migrate.sh save > /tmp/e4.log 2>&1; rc=$?
  expect "picker: backup verified" "BACKUP COMPLETED AND VERIFIED" /tmp/e4.log
  expect "picker: backups/ created" "creating .*/backups owned by you" /tmp/e4.log
  findmnt -S "$USB" >/dev/null && res FAIL "picker: unmounted at the end" || res PASS "picker: unmounted at the end"
  grep -E 'udisksctl failed|mounted at' /tmp/e4.log | sed 's/^/      | /'

  printf '%s\n\ny\n' "$IDX" | bash $R/migrate.sh restore > /tmp/e5.log 2>&1
  expect "picker: restore runs" "Restore finished with\|RESTORE COMPLETED WITHOUT ERRORS" /tmp/e5.log
  grep -A20 'Restore finished with' /tmp/e5.log | grep '^  - ' | sed 's/^/      | /'
fi

MP="$(findmnt -no TARGET -S "$USB" | head -1)"
[[ -n "$MP" ]] && sudo umount "$USB"
ODD="/mnt/it's a disk"
sudo mkdir -p "$ODD" && sudo mount "$USB" "$ODD"
B=$(ls -d "$ODD"/backups/system-backup-* | tail -1)

cp -a "$B" "$ODD/backups/corrupt" 2>/dev/null || sudo cp -a "$B" "$ODD/backups/corrupt"
sudo chown -R "$(id -u):$(id -g)" "$ODD/backups/corrupt"
echo tampered >> "$ODD/backups/corrupt/pkgs/packages-explicit.txt"
printf 'y\nn\n' | bash $R/migrate.sh restore "$ODD/backups/corrupt" > /tmp/e6.log 2>&1; rc=$?
expect "corrupt backup detected" "do not match their checksums" /tmp/e6.log
if ((rc != 0)) && ! grep -q '\[1/10\]' /tmp/e6.log; then res PASS "corrupt backup: stops on n"; else res FAIL "corrupt backup: stops on n" "rc=$rc"; fi
rm -rf "$ODD/backups/corrupt"

printf 'n\n' | bash $R/migrate.sh save "$ODD" > /tmp/e7a.log 2>&1; rc=$?
expect "odd path: backup" "BACKUP COMPLETED AND VERIFIED" /tmp/e7a.log
((rc == 0)) && res PASS "successful backup exits 0" || res FAIL "successful backup exits 0" "rc=$rc"
n_before=$(ls -d "$ODD"/backups/system-backup-* | wc -l)
printf 'n\n' | bash $R/migrate.sh save "$ODD" > /tmp/e7c.log 2>&1
n_after=$(ls -d "$ODD"/backups/system-backup-* | wc -l)
((n_after == n_before + 1)) && res PASS "back-to-back backups: own folders" || res FAIL "back-to-back backups: own folders" "$n_before -> $n_after"
B=$(ls -d "$ODD"/backups/system-backup-* | tail -1)
echo "odd-path-marker" > ~/Documents/marker.txt
yes y | bash "$B/migrate.sh" restore "$B" > /tmp/e7b.log 2>&1
grep -q '^\[FAILED\]' /tmp/e7b.log && { res FAIL "odd path: restore steps"; grep '^\[FAILED\]' /tmp/e7b.log | sed 's/^/      | /'; } || res PASS "odd path: restore steps"
grep -qx edge-marker ~/Documents/marker.txt && res PASS "odd path: home restored" || res FAIL "odd path: home restored"

bash $R/migrate.sh save ~/trial --no-home > /tmp/e8.log 2>&1 </dev/null
T=$(ls -d ~/trial/system-backup-* 2>/dev/null | tail -1)
if [[ -n "$T" && ! -e "$T/home.tar.zst" && ! -e "$T/critical/critical.tar.zst" ]] && grep -q 'home_included=0' "$T/meta/system-info.env"; then
  res PASS "trial backup has no home" "$(du -sh "$T" | cut -f1)"
else res FAIL "trial backup has no home"; tail -n 5 /tmp/e8.log | sed 's/^/      | /'; fi

sudo useradd -m -s /bin/bash other
echo 'other ALL=(ALL) NOPASSWD:ALL' | sudo tee /etc/sudoers.d/other >/dev/null
sudo -iu other bash -c "yes y | bash \"$B/migrate.sh\" restore \"$B\"" > /tmp/e9.log 2>&1
expect "other user: warned" "Current user: other" /tmp/e9.log
if sudo grep -qx edge-marker /home/other/Documents/marker.txt && [ -z "$(sudo find /home/other ! -user other -print -quit)" ]; then res PASS "other user: files in own home"
else res FAIL "other user: files in own home" "$(grep -m1 -E 'home extraction|home restored' /tmp/e9.log)"; fi
grep -E '^\[FAILED\]' /tmp/e9.log | sed 's/^/      | /'

if command -v dnf >/dev/null; then install_pkgs ShellCheck; elif command -v apt-get >/dev/null; then install_pkgs shellcheck; else install_pkgs shellcheck; fi
if command -v shellcheck >/dev/null; then
  shellcheck -S warning -x -e SC1091 $R/migrate.sh $R/lib/*.sh $R/tests/vm/*.sh > /tmp/sc.log 2>&1
  n=$(grep -c '^In ' /tmp/sc.log)
  res INFO "shellcheck warnings" "$n"
else res INFO "shellcheck" "not available"; fi

for f in /tmp/e*.log /tmp/sc.log; do sudo cp "$f" ~/ 2>/dev/null; done
EOF
"$VM" exec "$NAME" 'tar -C ~ -cf - e1.log e2.log e3.log e3b.log e4-list.log e4.log e5.log e6.log e7a.log e7b.log e7c.log e8.log e9.log sc.log 2>/dev/null' | tar -C "$OUT" -xf - || true
echo
echo "Results: $OUT/results.txt"
! grep -q '^FAIL' "$OUT/results.txt"
