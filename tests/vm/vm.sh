#!/usr/bin/env bash
set -euo pipefail

VM_HOME="${VM_HOME:-$HOME/.local/share/backupping-vms}"
IMG="$VM_HOME/images"; RUN="$VM_HOME/vms"; USBDIR="$VM_HOME/usb"
KEY="$VM_HOME/id_ed25519"
VM_USER=tester
mkdir -p "$IMG" "$RUN" "$USBDIR"

die() { echo "vm: $*" >&2; exit 1; }

image_url() {
  case "$1" in
    fedora)
      local base=https://download.fedoraproject.org/pub/fedora/linux/releases/44/Cloud/x86_64/images/ f
      f=$(curl -fsSL "$base" | grep -o 'Fedora-Cloud-Base-Generic-[^"<]*\.qcow2' | sort -uV | tail -1)
      [[ -n "$f" ]] || die "cannot resolve the Fedora image"
      echo "$base$f" ;;
    debian) echo https://cloud.debian.org/images/cloud/trixie/latest/debian-13-generic-amd64.qcow2 ;;
    ubuntu) echo https://cloud-images.ubuntu.com/releases/26.04/release/ubuntu-26.04-server-cloudimg-amd64.img ;;
    arch)   echo https://geo.mirror.pkgbuild.com/images/latest/Arch-Linux-x86_64-cloudimg.qcow2 ;;
    *) die "unknown distro '$1' (fedora, debian, ubuntu, arch)" ;;
  esac
}

need() { for c; do command -v "$c" >/dev/null || die "missing '$c' (sudo dnf install qemu-kvm qemu-img)"; done; }

cmd_fetch() {
  local d="$1" out="$IMG/$1.qcow2"
  [[ -f "$out" && "${2:-}" != "--force" ]] && { echo "$out already present"; return; }
  local pb=-sS; [[ -t 2 ]] && pb=--progress-bar
  curl -fL $pb -o "$out.part" "$(image_url "$d")" && mv "$out.part" "$out"
}

ensure_key() { [[ -f "$KEY" ]] || ssh-keygen -q -t ed25519 -N '' -C backupping-vm -f "$KEY"; }

make_seed() {
  local name="$1" dir="$RUN/$1" pub
  pub=$(cat "$KEY.pub")
  cat >"$dir/user-data" <<EOF
#cloud-config
hostname: $name
users:
  - name: $VM_USER
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    shell: /bin/bash
    lock_passwd: false
    plain_text_passwd: tester
    ssh_authorized_keys: ["$pub"]
ssh_pwauth: true
growpart: {mode: auto, devices: ["/"]}
EOF
  printf 'instance-id: %s-%s\nlocal-hostname: %s\n' "$name" "$(date +%s)" "$name" >"$dir/meta-data"
  rm -f "$dir/seed.img"
  mkfs.vfat -n CIDATA -C "$dir/seed.img" 2048 >/dev/null
  mcopy -i "$dir/seed.img" "$dir/user-data" "$dir/meta-data" ::
}

free_port() {
  local p=2222
  while ss -Htln "sport = :$p" | grep -q . || grep -qx "$p" "$RUN"/*/port 2>/dev/null; do ((p++)); done
  echo "$p"
}

cmd_create() {
  local name="$1" distro="$2" size="${3:-30G}" dir="$RUN/$1"
  need qemu-img
  [[ -d "$dir" ]] && die "'$name' already exists (vm.sh destroy $name)"
  [[ -f "$IMG/$distro.qcow2" ]] || cmd_fetch "$distro"
  ensure_key; mkdir -p "$dir"
  qemu-img create -q -f qcow2 -F qcow2 -b "$IMG/$distro.qcow2" "$dir/disk.qcow2" "$size"
  echo "$distro" >"$dir/distro"; free_port >"$dir/port"
  make_seed "$name"
  echo "created $name ($distro, ssh port $(cat "$dir/port"))"
}

running() { [[ -f "$RUN/$1/pid" ]] && kill -0 "$(cat "$RUN/$1/pid")" 2>/dev/null; }

cmd_start() {
  local name="$1"; shift
  local dir="$RUN/$name" mem=4096 cpus=2 gui=0 usb=""
  [[ -d "$dir" ]] || die "no VM '$name'"
  running "$name" && { echo "$name already running"; return; }
  while (($#)); do case "$1" in
    --mem) mem="$2"; shift 2 ;; --cpus) cpus="$2"; shift 2 ;;
    --gui) gui=1; shift ;; --usb) usb="$2"; shift 2 ;;
    *) die "unknown option $1" ;; esac; done
  need qemu-system-x86_64
  local args=(-name "$name" -machine q35,accel=kvm -cpu host -smp "$cpus" -m "$mem"
    -drive "file=$dir/disk.qcow2,if=virtio,discard=unmap"
    -drive "file=$dir/seed.img,if=virtio,format=raw,readonly=on"
    -netdev "user,id=n0,hostfwd=tcp:127.0.0.1:$(cat "$dir/port")-:22" -device virtio-net-pci,netdev=n0
    -device virtio-rng-pci -pidfile "$dir/pid" -serial "file:$dir/console.log" -daemonize)
  if [[ -n "$usb" ]]; then
    [[ -f "$USBDIR/$usb.qcow2" ]] || die "no USB disk '$usb' (vm.sh usb $usb)"
    args+=(-device qemu-xhci,id=xhci -drive "file=$USBDIR/$usb.qcow2,if=none,id=usbstick"
           -device usb-storage,bus=xhci.0,drive=usbstick,removable=on)
  fi
  if ((gui)); then args+=(-vga virtio -display gtk); else args+=(-display none -vga none); fi
  qemu-system-x86_64 "${args[@]}"
  echo "started $name (ssh: tests/vm/vm.sh ssh $name)"
}

ssh_opts() {
  echo -i "$KEY" -p "$(cat "$RUN/$1/port")" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
       -o LogLevel=ERROR -o ConnectTimeout=5
}

cmd_ssh() {
  local name="$1"; shift
  # shellcheck disable=SC2046
  ssh $(ssh_opts "$name") -t "$VM_USER@127.0.0.1" "$@"
}

cmd_exec() {
  local name="$1"; shift
  # shellcheck disable=SC2046
  ssh $(ssh_opts "$name") "$VM_USER@127.0.0.1" "$@"
}

cmd_wait() {
  local name="$1" t="${2:-300}" i
  for ((i = 0; i < t; i += 3)); do
    if cmd_exec "$name" 'cloud-init status --wait >/dev/null 2>&1 || test -f /var/lib/cloud/instance/boot-finished' 2>/dev/null; then
      echo "$name ready"; return 0; fi
    running "$name" || die "$name is not running (see $RUN/$name/console.log)"
    sleep 3
  done
  die "timeout waiting for $name"
}

cmd_push() {
  local name="$1" src="${2:-$(cd "$(dirname "$0")/../.." && pwd)}" dst="${3:-backupping}"
  tar -C "$src" --exclude=.git --exclude='system-backup-*' --exclude='fedora-backup-*' -cf - . \
    | cmd_exec "$name" "rm -rf ~/$dst && mkdir -p ~/$dst && tar -C ~/$dst -xf -"
  echo "pushed $src -> $name:~/$dst"
}

cmd_pull() {
  local name="$1" remote="$2" local_dir="${3:-.}"
  mkdir -p "$local_dir"
  cmd_exec "$name" "tar -C \"\$(dirname $remote)\" -cf - \"\$(basename $remote)\"" | tar -C "$local_dir" -xf -
}

cmd_stop() {
  local name="$1" i
  running "$name" || { echo "$name not running"; return; }
  cmd_exec "$name" 'sudo systemctl poweroff' 2>/dev/null || true
  for ((i = 0; i < 60; i++)); do running "$name" || { echo "stopped $name"; return; }; sleep 1; done
  kill "$(cat "$RUN/$name/pid")"; echo "killed $name"
}

cmd_destroy() {
  local name="$1"
  running "$name" && kill "$(cat "$RUN/$name/pid")" && sleep 1
  rm -rf "${RUN:?}/$name"; echo "destroyed $name"
}

cmd_usb() {
  local name="$1" size="${2:-32G}" f="$USBDIR/$1.qcow2"
  need qemu-img
  [[ -f "$f" ]] && die "USB disk '$name' exists (vm.sh usb-rm $name)"
  qemu-img create -q -f qcow2 "$f" "$size"; echo "created USB disk $name ($size, unformatted)"
}

cmd_list() {
  local d n
  printf '%-14s %-8s %-6s %s\n' NAME DISTRO PORT STATE
  for d in "$RUN"/*/; do
    [[ -d "$d" ]] || continue; n=$(basename "$d")
    printf '%-14s %-8s %-6s %s\n' "$n" "$(cat "$d/distro")" "$(cat "$d/port")" "$(running "$n" && echo running || echo stopped)"
  done
  echo; echo "USB disks:"; ls -1 "$USBDIR" 2>/dev/null | sed 's/\.qcow2$//;s/^/  /'
  echo; echo "Base images:"; ls -1sh "$IMG" 2>/dev/null | tail -n+2 | sed 's/^/  /'
}

usage() {
  cat <<EOF
Usage: tests/vm/vm.sh COMMAND ...

  fetch DISTRO [--force]         download a cloud image (fedora, debian, ubuntu, arch)
  create NAME DISTRO [SIZE]      new VM backed by the image (default 30G)
  start NAME [--gui] [--mem MB] [--cpus N] [--usb DISK]
  wait NAME [SECONDS]            wait for ssh + cloud-init
  ssh NAME [CMD...]              interactive shell (user $VM_USER, password $VM_USER)
  exec NAME CMD...               run a command, no tty
  push NAME [SRC] [DEST]         copy the repo into ~/backupping in the VM
  pull NAME REMOTE_PATH [DIR]    copy a file/dir out of the VM
  stop NAME | destroy NAME
  usb NAME [SIZE] | usb-rm NAME  virtual USB stick, attach with start --usb NAME
  list

Data lives in $VM_HOME
EOF
}

c="${1:-}"; shift || true
case "$c" in
  fetch|create|start|wait|ssh|exec|push|pull|stop|destroy|usb|list)
    [[ "$c" == list || $# -ge 1 ]] || { usage; exit 1; }
    "cmd_$c" "$@" ;;
  usb-rm) rm -f "$USBDIR/${1:?}.qcow2"; echo "removed USB disk $1" ;;
  *) usage; [[ -z "$c" || "$c" == -h || "$c" == --help ]] ;;
esac
