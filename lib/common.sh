RED=$'\e[31m'; GRN=$'\e[32m'; YLW=$'\e[33m'; BLU=$'\e[34m'; RST=$'\e[0m'
die()    { echo "${RED}[ERROR]${RST} $*"; exit 1; }
yes_no() { local a; read -rp "$1 [y/N] " a; [[ "$a" =~ ^[sSyY]$ ]]; }

BACKUP_GLOBS=(system-backup-* fedora-backup-*)

os_field() { ( . /etc/os-release 2>/dev/null; printf '%s\n' "${!1:-}" ); }

detect_de() {
  local d="${XDG_CURRENT_DESKTOP:-${DESKTOP_SESSION:-}}"
  case "${d,,}" in
    *kde*|*plasma*)   echo kde;      return ;;
    *gnome*|*ubuntu*) echo gnome;    return ;;
    *xfce*)           echo xfce;     return ;;
    *cinnamon*)       echo cinnamon; return ;;
    *mate*)           echo mate;     return ;;
    *lxqt*)           echo lxqt;     return ;;
    *budgie*)         echo budgie;   return ;;
  esac
  if   command -v plasmashell      >/dev/null; then echo kde
  elif command -v gnome-shell      >/dev/null; then echo gnome
  elif command -v xfce4-session    >/dev/null; then echo xfce
  elif command -v cinnamon-session >/dev/null; then echo cinnamon
  elif command -v mate-session     >/dev/null; then echo mate
  elif command -v lxqt-session     >/dev/null; then echo lxqt
  elif command -v budgie-desktop   >/dev/null; then echo budgie
  else echo none
  fi
}

graphical_session_running() {
  pgrep -u "$(id -u)" -x 'plasmashell|gnome-shell|xfce4-session|cinnamon|mate-session|lxqt-session|budgie-panel' >/dev/null
}

detect_pm() {
  if   command -v dnf     >/dev/null; then echo dnf
  elif command -v apt-get >/dev/null; then echo apt
  elif command -v pacman  >/dev/null; then echo pacman
  else echo unknown
  fi
}

PM="${PM:-$(detect_pm)}"

pm_list_explicit() {
  case "$PM" in
    dnf)    dnf repoquery --userinstalled --qf '%{name}\n' ;;
    apt)    apt-mark showmanual ;;
    pacman) pacman -Qqe ;;
  esac 2>/dev/null | sort -u
}

pm_list_local() {
  case "$PM" in
    dnf)    dnf repoquery --installed --qf '%{name} %{from_repo}\n' \
              | awk '$2=="@commandline" || $2=="<unknown>" {print $1}' ;;
    apt)    apt list --installed 2>/dev/null | awk -F/ '/\[installed.*local\]/{print $1}' ;;
    pacman) pacman -Qqm ;;
  esac 2>/dev/null | sort -u
}

pm_list_all() {
  case "$PM" in
    dnf)    rpm -qa --qf '%{NAME}\t%{VERSION}-%{RELEASE}\t%{ARCH}\n' ;;
    apt)    dpkg-query -W -f='${Package}\t${Version}\t${Architecture}\n' ;;
    pacman) pacman -Q | tr ' ' '\t' ;;
  esac 2>/dev/null | sort
}

pm_list_available() {
  case "$PM" in
    dnf)    dnf repoquery --available --qf '%{name}\n' ;;
    apt)    apt-cache pkgnames ;;
    pacman) pacman -Slq ;;
  esac 2>/dev/null | sort -u
}

pm_is_installed() {
  case "$PM" in
    dnf)    rpm -q "$1" ;;
    apt)    dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed' ;;
    pacman) pacman -Qq "$1" ;;
  esac >/dev/null 2>&1
}

pm_install() {
  case "$PM" in
    dnf)    sudo dnf install -y "$@" ;;
    apt)    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" ;;
    pacman) sudo pacman -S --needed --noconfirm "$@" ;;
  esac
}

pm_refresh() {
  case "$PM" in
    dnf)    sudo dnf makecache -y ;;
    apt)    sudo apt-get update ;;
    pacman) sudo pacman -Syu --noconfirm ;;
  esac
}

pm_local_ext() {
  case "$PM" in
    dnf)    echo rpm ;;
    apt)    echo deb ;;
    pacman) echo pkg.tar.zst ;;
  esac
}

pm_pip_package() {
  case "$PM" in
    pacman) echo python-pip ;;
    *)      echo python3-pip ;;
  esac
}

AUR_HELPERS=(paru yay pikaur trizen)
AUR_RPC="https://aur.archlinux.org/rpc/v5/info"

detect_aur_helper() {
  local h
  for h in "${AUR_HELPERS[@]}"; do command -v "$h" >/dev/null && { echo "$h"; return 0; }; done
  return 1
}

aur_flags() {
  case "$1" in
    paru)   echo "--needed --noconfirm --skipreview --removemake" ;;
    yay)    echo "--needed --noconfirm --answerdiff None --answerclean None --answeredit None --removemake" ;;
    pikaur) echo "--needed --noconfirm --noedit --nodiff" ;;
    trizen) echo "--needed --noconfirm --noedit" ;;
    *)      echo "--needed --noconfirm" ;;
  esac
}

aur_filter_existing() {
  local names=() n out
  mapfile -t names
  ((${#names[@]})) || return 0
  command -v curl >/dev/null || return 1
  local i args=() found=""
  for ((i = 0; i < ${#names[@]}; i += 100)); do
    args=()
    for n in "${names[@]:i:100}"; do args+=(--data-urlencode "arg[]=$n"); done
    out="$(curl -fsG --globoff --max-time 30 "$AUR_RPC" "${args[@]}")" || return 1
    [[ "$out" == *'"type":"error"'* ]] && return 1
    found+="$(grep -o '"Name":"[^"]*"' <<<"$out" | cut -d'"' -f4)"$'\n'
  done
  sed '/^$/d' <<<"$found" | sort -u
}

is_aur_helper_pkg() { [[ "$1" =~ ^(paru|yay|pikaur|trizen)(-bin|-git)?$ ]]; }

disk_of() { lsblk -lspno NAME "$1" 2>/dev/null | tail -1; }
mount_source() { findmnt -no SOURCE --target "$1" 2>/dev/null | sed 's/\[.*//'; }

same_disk() {
  local a b da db
  a="$(mount_source "$1")"; b="$(mount_source "$2")"
  [[ -n "$a" && "$a" == "$b" ]] && return 0
  [[ -b "$a" && -b "$b" ]] || return 1
  da="$(disk_of "$a")"; db="$(disk_of "$b")"
  [[ -n "$da" && "$da" == "$db" ]]
}
