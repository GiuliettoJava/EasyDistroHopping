RED=$'\e[31m'; GRN=$'\e[32m'; YLW=$'\e[33m'; BLU=$'\e[34m'; RST=$'\e[0m'
die()    { echo "${RED}[ERROR]${RST} $*"; exit 1; }
yes_no() { local a; read -rp "$1 [y/N] " a; [[ "$a" =~ ^[sSyY]$ ]]; }

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
