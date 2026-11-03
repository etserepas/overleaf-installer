#!/usr/bin/env bash
#
# One-command installer for a self-hosted Overleaf Community Edition with:
#   - the official overleaf/toolkit (Docker: Overleaf, MongoDB, Redis)
#   - full TeX Live (scheme-full), rebuilt formats and TeX Live fonts visible to XeLaTeX/LuaLaTeX
#   - optional Microsoft core fonts (Times New Roman, Arial, ...) after accepting their EULA
#   - an nginx reverse proxy (existing nginx is reused, otherwise the distro one is installed),
#     on port 80 or on a port of its own with redirects such as /latex from the existing site
#   - a workaround for MongoDB 8 on Linux kernels >= 6.19 (SERVER-121912)
#
# Safe to re-run: every step checks what is already in place and skips it.
#
# Usage:
#   sudo ./install.sh [options]
#   curl -fsSL https://raw.githubusercontent.com/<owner>/<repo>/main/install.sh | sudo bash -s -- [options]
#
# Run ./install.sh --help for the options.

set -Eeuo pipefail

# ---------------------------------------------------------------- defaults ---

TOOLKIT_REPO="https://github.com/overleaf/toolkit.git"
INSTALL_DIR="/opt/overleaf-toolkit"
APP_NAME="LaTeX Editor"
SITE_URL=""                 # default: http://<primary IPv4 of this machine>
ADMIN_EMAIL=""
INTERNAL_PORT=8080          # Overleaf listens on 127.0.0.1:<port> behind nginx
LISTEN_PORT=""              # public port (default: 80, or the port in --site-url)
REDIRECT_PATHS=""           # e.g. "/latex,/overleaf": paths of the port-80 site that redirect to Overleaf
NGINX_MODE="auto"           # auto | no
TEXLIVE_FULL=1
MSFONTS="ask"               # ask | yes | no
ASSUME_YES=0
WAIT_TIMEOUT=600            # seconds to wait for Overleaf to answer HTTP

# ------------------------------------------------------------------ output ---

if [[ -t 1 ]]; then
  C_BOLD=$'\e[1m'; C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'; C_RED=$'\e[31m'; C_RESET=$'\e[0m'
else
  C_BOLD=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_RESET=""
fi

step() { echo; echo "${C_BOLD}==> $*${C_RESET}"; }
info() { echo "    $*"; }
ok()   { echo "    ${C_GREEN}✓${C_RESET} $*"; }
warn() { echo "    ${C_YELLOW}!${C_RESET} $*" >&2; }
die()  { echo "${C_RED}ERROR:${C_RESET} $*" >&2; exit 1; }

trap 'die "command failed at line $LINENO: $BASH_COMMAND"' ERR

usage() {
  cat <<EOF
Install a self-hosted Overleaf Community Edition with full TeX Live.

Usage: sudo $0 [options]

Options:
  --site-url URL             Public URL of the site (default: http://<this machine's IP>)
  --app-name NAME            Name shown in the Overleaf UI (default: "$APP_NAME")
  --admin-email EMAIL        Contact email shown on the register page
  --dir PATH                 Where to put the Overleaf toolkit (default: $INSTALL_DIR)
  --listen-port PORT         Public port of Overleaf (default: 80). Use another port, e.g. 8081,
                             to keep an existing site on port 80
  --redirect-paths LIST      Comma-separated paths of the existing port-80 site that redirect to
                             Overleaf, e.g. /latex,/overleaf (needs --listen-port other than 80)
  --port PORT                Internal port Overleaf listens on behind nginx (default: $INTERNAL_PORT)
  --no-nginx                 Don't use nginx; Overleaf listens directly on the public port
  --no-texlive-full          Keep the image's minimal TeX Live
  --accept-mscorefonts-eula  Install Microsoft core fonts (Times New Roman, Arial, ...)
                             and accept their EULA without asking
  --no-mscorefonts           Don't install Microsoft core fonts
  -y, --yes                  Don't ask for confirmation
  -h, --help                 Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --site-url)                SITE_URL="${2:?}"; shift 2 ;;
    --app-name)                APP_NAME="${2:?}"; shift 2 ;;
    --admin-email)             ADMIN_EMAIL="${2:?}"; shift 2 ;;
    --dir)                     INSTALL_DIR="${2:?}"; shift 2 ;;
    --listen-port)             LISTEN_PORT="${2:?}"; shift 2 ;;
    --redirect-paths)          REDIRECT_PATHS="${2:?}"; shift 2 ;;
    --port)                    INTERNAL_PORT="${2:?}"; shift 2 ;;
    --no-nginx)                NGINX_MODE="no"; shift ;;
    --no-texlive-full)         TEXLIVE_FULL=0; shift ;;
    --accept-mscorefonts-eula) MSFONTS="yes"; shift ;;
    --no-mscorefonts)          MSFONTS="no"; shift ;;
    -y|--yes)                  ASSUME_YES=1; shift ;;
    -h|--help)                 usage; exit 0 ;;
    *) usage >&2; die "unknown option: $1" ;;
  esac
done

# Prompts read from the terminal, so they also work with `curl ... | sudo bash`.
ask_yes_no() {
  local prompt="$1" answer
  if [[ ! -r /dev/tty ]]; then return 1; fi
  read -r -p "    $prompt [y/N] " answer </dev/tty || return 1
  [[ "$answer" =~ ^[YyΝν] ]]
}

# --------------------------------------------------------------- preflight ---

preflight() {
  step "Checking this machine"

  [[ $EUID -eq 0 ]] || die "run as root: sudo $0 $*"

  [[ -r /etc/os-release ]] || die "cannot detect the OS (/etc/os-release missing)"
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID:-} ${ID_LIKE:-}" in
    *ubuntu*|*debian*) ok "OS: ${PRETTY_NAME:-$ID}" ;;
    *) die "only Ubuntu/Debian are supported (found: ${PRETTY_NAME:-unknown})" ;;
  esac

  local arch; arch="$(uname -m)"
  [[ "$arch" == "x86_64" ]] || die "Overleaf's official images are x86_64 only (found: $arch)"
  ok "Architecture: $arch"

  local mem_gb; mem_gb=$(( $(awk '/MemTotal/ {print $2}' /proc/meminfo) / 1024 / 1024 ))
  if (( mem_gb < 4 )); then warn "only ${mem_gb} GB RAM; 4 GB or more is recommended"; else ok "RAM: ${mem_gb} GB"; fi

  local parent free_gb need_gb=10
  (( TEXLIVE_FULL )) && need_gb=25
  parent="$(dirname "$INSTALL_DIR")"; mkdir -p "$parent"
  free_gb=$(( $(df -Pk "$parent" | awk 'NR==2 {print $4}') / 1024 / 1024 ))
  if (( free_gb < need_gb )); then
    warn "only ${free_gb} GB free on $(df -P "$parent" | awk 'NR==2 {print $6}'); about ${need_gb} GB is needed"
  else
    ok "Free disk: ${free_gb} GB"
  fi

  [[ -z "$LISTEN_PORT" || "$LISTEN_PORT" =~ ^[0-9]+$ ]] || die "--listen-port must be a number"
  [[ "$INTERNAL_PORT" =~ ^[0-9]+$ ]] || die "--port must be a number"
  if [[ -z "$SITE_URL" ]]; then
    local ip
    ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "src") print $(i + 1)}')"
    [[ -n "$ip" ]] || ip="$(hostname -I | awk '{print $1}')"
    [[ -n "$ip" ]] || die "cannot detect this machine's IP; pass --site-url"
    SITE_URL="http://$ip"
    if [[ -n "$LISTEN_PORT" && "$LISTEN_PORT" != 80 ]]; then SITE_URL+=":$LISTEN_PORT"; fi
  fi
  SITE_URL="${SITE_URL%/}"
  [[ "$SITE_URL" =~ ^https?://[^/]+$ ]] || die "--site-url must look like http://host or https://host (no path)"
  # Without --listen-port, use the port written in --site-url (e.g. http://host:8081).
  if [[ -z "$LISTEN_PORT" ]]; then
    if [[ "${SITE_URL#*://}" =~ :([0-9]+)$ ]]; then LISTEN_PORT="${BASH_REMATCH[1]}"; else LISTEN_PORT=80; fi
  fi
  if [[ "$NGINX_MODE" != "no" && "$LISTEN_PORT" == "$INTERNAL_PORT" ]]; then
    die "--listen-port and --port must differ (nginx listens on one, Overleaf on the other)"
  fi

  if [[ -n "$REDIRECT_PATHS" ]]; then
    [[ "$NGINX_MODE" == "no" ]] && die "--redirect-paths needs nginx (drop --no-nginx)"
    [[ "$LISTEN_PORT" == 80 ]] && die "--redirect-paths needs --listen-port other than 80 (Overleaf would own port 80 itself)"
    local p
    for p in ${REDIRECT_PATHS//,/ }; do
      [[ "$p" =~ ^/[A-Za-z0-9._~-]+(/[A-Za-z0-9._~-]+)*$ ]] || die "invalid redirect path: $p (use e.g. /latex)"
    done
  fi

  if [[ "$MSFONTS" == "ask" ]]; then
    echo
    info "Microsoft core fonts (Times New Roman, Arial, Courier New, ...) are needed by many"
    info "university templates. Installing them means accepting Microsoft's EULA:"
    info "https://corefonts.sourceforge.net/eula.htm"
    if ask_yes_no "Install them and accept the EULA?"; then MSFONTS="yes"; else MSFONTS="no"; fi
  fi

  echo
  info "Site URL:        $SITE_URL"
  info "Toolkit dir:     $INSTALL_DIR"
  info "Reverse proxy:   $([[ $NGINX_MODE == no ]] && echo "none (Overleaf on port $LISTEN_PORT)" || echo "nginx :$LISTEN_PORT -> 127.0.0.1:$INTERNAL_PORT")"
  [[ -n "$REDIRECT_PATHS" ]] && info "Redirects:       ${REDIRECT_PATHS//,/, } on port 80 -> $SITE_URL/"
  info "Full TeX Live:   $([[ $TEXLIVE_FULL == 1 ]] && echo yes || echo no)"
  info "MS core fonts:   $MSFONTS"
  if (( ! ASSUME_YES )) && [[ -r /dev/tty ]]; then
    ask_yes_no "Continue?" || die "cancelled"
  fi
}

# ------------------------------------------------------------ dependencies ---

apt_has() { [[ -n "$(apt-cache policy "$1" 2>/dev/null | awk '/Candidate:/ && $2 != "(none)" {print $2}')" ]]; }

install_dependencies() {
  step "Installing Docker, Docker Compose and git"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq

  local pkgs=(ca-certificates curl git)
  command -v docker >/dev/null || pkgs+=(docker.io)
  if ! docker compose version >/dev/null 2>&1; then
    if apt_has docker-compose-v2; then pkgs+=(docker-compose-v2)
    elif apt_has docker-compose-plugin; then pkgs+=(docker-compose-plugin)
    else die "no Docker Compose v2 package found; install Docker from https://docs.docker.com/engine/install/ and re-run"
    fi
  fi
  apt-get install -y -qq "${pkgs[@]}" >/dev/null
  systemctl enable --now docker >/dev/null 2>&1 || true

  docker info >/dev/null 2>&1 || die "Docker is installed but not running"
  ok "$(docker --version)"
  ok "$(docker compose version)"

  if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]] && ! id -nG "$SUDO_USER" | grep -qw docker; then
    usermod -aG docker "$SUDO_USER"
    ok "added $SUDO_USER to the docker group (takes effect at next login)"
  fi
}

# ----------------------------------------------------------------- toolkit ---

# Set KEY=VALUE in a shell-style config file, replacing an existing line or appending.
set_conf() {
  local file="$1" key="$2" value="$3" escaped
  if grep -qE "^${key}=" "$file"; then
    escaped="${value//\\/\\\\}"; escaped="${escaped//&/\\&}"; escaped="${escaped//|/\\|}"
    sed -i -E "s|^${key}=.*|${key}=${escaped}|" "$file"
  else
    printf '%s=%s\n' "$key" "$value" >>"$file"
  fi
}

unset_conf() { sed -i -E "/^${2}=/d" "$1"; }

toolkit() { (cd "$INSTALL_DIR" && "$@" </dev/null); }

setup_toolkit() {
  step "Setting up the Overleaf toolkit in $INSTALL_DIR"

  if [[ -d "$INSTALL_DIR/.git" ]]; then
    ok "toolkit already present ($(git -C "$INSTALL_DIR" log -1 --format='%h, %cs'))"
  else
    git clone -q "$TOOLKIT_REPO" "$INSTALL_DIR"
    ok "cloned $TOOLKIT_REPO"
  fi
  if [[ ! -f "$INSTALL_DIR/config/overleaf.rc" ]]; then
    toolkit bin/init >/dev/null
    ok "created config/ from the toolkit defaults"
  fi

  (( TEXLIVE_FULL )) && save_unsaved_texlive

  local rc="$INSTALL_DIR/config/overleaf.rc" env="$INSTALL_DIR/config/variables.env"
  if [[ "$NGINX_MODE" == "no" ]]; then
    set_conf "$rc" OVERLEAF_LISTEN_IP 0.0.0.0
    set_conf "$rc" OVERLEAF_PORT "$LISTEN_PORT"
    unset_conf "$env" OVERLEAF_BEHIND_PROXY
  else
    set_conf "$rc" OVERLEAF_LISTEN_IP 127.0.0.1
    set_conf "$rc" OVERLEAF_PORT "$INTERNAL_PORT"
    set_conf "$env" OVERLEAF_BEHIND_PROXY true
  fi
  set_conf "$env" OVERLEAF_APP_NAME "\"$APP_NAME\""
  set_conf "$env" OVERLEAF_SITE_URL "$SITE_URL"
  [[ -n "$ADMIN_EMAIL" ]] && set_conf "$env" OVERLEAF_ADMIN_EMAIL "$ADMIN_EMAIL"
  # Overleaf turns secure cookies on whenever this variable exists, whatever its value.
  # Over plain HTTP the browser then drops the session cookie ("Session error"), so only
  # set it for HTTPS.
  if [[ "$SITE_URL" == https://* ]]; then
    set_conf "$env" OVERLEAF_SECURE_COOKIE true
  else
    unset_conf "$env" OVERLEAF_SECURE_COOKIE
  fi
  ok "configured site URL, app name and listen address"

  apply_mongo_kernel_workaround

  # Let the invoking user run bin/* via the docker group. data/ is left alone:
  # the containers own their files there (e.g. MongoDB runs as uid 999).
  if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
    chown "$SUDO_USER": "$INSTALL_DIR"
    find "$INSTALL_DIR" -mindepth 1 -maxdepth 1 ! -name data -exec chown -R "$SUDO_USER": {} +
  fi
}

# MongoDB 8.x refuses to start on kernels >= 6.19 because its bundled TCMalloc
# conflicts with the kernel's rseq changes (https://jira.mongodb.org/browse/SERVER-121912).
# Re-enabling glibc's rseq registration makes it start; harmless on older kernels.
apply_mongo_kernel_workaround() {
  local kver kmaj kmin mongo_major override
  kver="$(uname -r)"
  kmaj="${kver%%.*}"; kmin="${kver#*.}"; kmin="${kmin%%[!0-9]*}"
  mongo_major="$(grep -E '^MONGO_VERSION=' "$INSTALL_DIR/config/overleaf.rc" | cut -d= -f2 | cut -d. -f1)"
  override="$INSTALL_DIR/config/docker-compose.override.yml"

  if (( kmaj < 6 || (kmaj == 6 && kmin < 19) )) || (( ${mongo_major:-0} < 8 )); then
    return 0
  fi
  if [[ -f "$override" ]]; then
    if grep -q GLIBC_TUNABLES "$override"; then
      ok "MongoDB kernel workaround already in place"
    else
      warn "kernel $kver needs GLIBC_TUNABLES=glibc.pthread.rseq=1 on the mongo service,"
      warn "but $override already exists; add it there by hand"
    fi
    return 0
  fi
  cat >"$override" <<'YAML'
# Added by install.sh: MongoDB 8.x refuses to start on Linux kernel >= 6.19
# (https://jira.mongodb.org/browse/SERVER-121912). Re-enabling glibc rseq lets
# its TCMalloc work. Can be removed once the kernel is 7.0.14+/7.1+ and mongo 8.0.30+.
services:
    mongo:
        environment:
            GLIBC_TUNABLES: glibc.pthread.rseq=1
YAML
  ok "kernel $kver: applied the MongoDB 8 rseq workaround"
}

wait_for_overleaf() {
  local port url deadline code=""
  port="$(grep -E '^OVERLEAF_PORT=' "$INSTALL_DIR/config/overleaf.rc" | cut -d= -f2)"
  url="http://127.0.0.1:${port:-80}/login"
  deadline=$(( SECONDS + WAIT_TIMEOUT ))
  while (( SECONDS < deadline )); do
    code="$(curl -s -o /dev/null -w '%{http_code}' "$url" || true)"
    [[ "$code" == "200" ]] && { ok "Overleaf answers on $url"; return 0; }
    sleep 5
  done
  die "Overleaf did not answer on $url within ${WAIT_TIMEOUT}s (last HTTP code: ${code:-none}). See: cd $INSTALL_DIR && bin/logs"
}

start_overleaf() {
  step "Starting Overleaf (the first run downloads several GB of images)"
  toolkit bin/up -d 2>&1 | grep -E 'Started|Running|Healthy|Recreated|Error|error' | sed 's/^/    /' || true
  wait_for_overleaf
}

# ----------------------------------------------------------------- TeX Live ---

in_overleaf() { docker exec -e DEBIAN_FRONTEND=noninteractive sharelatex bash -c "$1"; }

base_version() { sed -E 's/-with-texlive-full$//' "$INSTALL_DIR/config/version"; }

install_texlive_full() {
  local base target current
  base="$(base_version)"
  target="${base}-with-texlive-full"
  current="$(cat "$INSTALL_DIR/config/version")"

  if [[ "$current" == "$target" ]] && docker image inspect "sharelatex/sharelatex:$target" >/dev/null 2>&1 \
     && in_overleaf 'kpsewhich mathspec.sty >/dev/null' \
     && { [[ "$MSFONTS" != "yes" ]] || in_overleaf 'fc-list 2>/dev/null | grep -q "Times New Roman"'; }; then
    step "Full TeX Live"
    ok "already installed in sharelatex/sharelatex:$target"
    return 0
  fi

  if in_overleaf 'kpsewhich mathspec.sty >/dev/null 2>&1'; then
    step "Completing full TeX Live (already installed; rebuilding formats and fonts, a few minutes)"
  else
    step "Installing full TeX Live in the Overleaf container (about 8 GB, often 30-60 minutes)"
  fi

  # A TeX Live release can only install from its own year's repository. If CTAN has
  # moved on to a newer year, switch to that year's frozen archive.
  local tl_year selfupdate
  tl_year="$(in_overleaf 'tlmgr --version' | sed -nE 's/.*texlive\/([0-9]{4}).*/\1/p' | head -1)"
  if ! selfupdate="$(in_overleaf 'tlmgr update --self 2>&1')"; then
    if grep -qi 'older than remote repository' <<<"$selfupdate" && [[ -n "$tl_year" ]]; then
      warn "TeX Live $tl_year is no longer current; using its frozen archive"
      in_overleaf "tlmgr option repository https://ftp.math.utah.edu/pub/tex/historic/systems/texlive/$tl_year/tlnet-final" >/dev/null
      in_overleaf 'tlmgr update --self' >/dev/null
    else
      echo "$selfupdate" >&2; die "tlmgr update --self failed"
    fi
  fi
  ok "tlmgr is up to date (TeX Live ${tl_year:-?})"

  info "downloading and installing packages; progress: docker exec sharelatex tail -f /tmp/tlmgr-full.log"
  # The format build at the end of `tlmgr install` can fail on a tlmgr/fmtutil option
  # mismatch even though every package installed, so formats are rebuilt separately below.
  if ! in_overleaf 'tlmgr install scheme-full >/tmp/tlmgr-full.log 2>&1'; then
    in_overleaf 'grep -q "fmtutil" /tmp/tlmgr-full.log' \
      || { in_overleaf 'tail -20 /tmp/tlmgr-full.log' >&2; die "tlmgr install scheme-full failed"; }
    warn "tlmgr's own format build failed; rebuilding formats separately"
  fi
  ok "scheme-full packages installed"

  in_overleaf 'mktexlsr >/dev/null 2>&1; fmtutil-sys --all >/tmp/fmtutil.log 2>&1' \
    || { in_overleaf 'grep -E "ERROR|failed" /tmp/fmtutil.log | tail -20' >&2; die "fmtutil-sys --all failed"; }
  in_overleaf 'updmap-sys >/dev/null 2>&1; tlmgr path add >/dev/null 2>&1 || true'
  ok "formats and font maps rebuilt"

  # XeLaTeX/LuaLaTeX find fonts through fontconfig, which doesn't know TeX Live's fonts.
  in_overleaf 'apt-get update -qq && apt-get install -y -qq fontconfig >/dev/null
    conf="$(kpsewhich -var-value TEXMFSYSVAR)/fonts/conf/texlive-fontconfig.conf"
    cp "$conf" /etc/fonts/conf.d/09-texlive.conf && fc-cache -f >/dev/null'
  ok "TeX Live fonts registered with fontconfig"

  if [[ "$MSFONTS" == "yes" ]]; then
    in_overleaf 'echo "ttf-mscorefonts-installer msttcorefonts/accepted-mscorefonts-eula select true" | debconf-set-selections
      apt-get install -y -qq ttf-mscorefonts-installer >/tmp/msfonts.log 2>&1 && fc-cache -f >/dev/null' \
      || { in_overleaf 'tail -20 /tmp/msfonts.log' >&2; die "installing Microsoft core fonts failed"; }
    ok "Microsoft core fonts installed"
  fi

  verify_texlive
  commit_texlive_image "$target"

  toolkit bin/up -d >/dev/null 2>&1
  wait_for_overleaf
  docker image prune -f >/dev/null 2>&1 || true
}

# Saves the running sharelatex container as image <target> and points config/version at it.
commit_texlive_image() {
  local target="$1"
  # The commit writes the container's changes again as a compressed layer and, with the
  # containerd image store, unpacks it once more, so it needs about twice their size.
  local changed_gb free_gb docker_root
  changed_gb=$(( $(docker ps -s --filter name='^sharelatex$' --format '{{.Size}}' |
    awk '{v = $1 + 0; if ($1 ~ /GB/) v *= 1024; else if ($1 ~ /kB/) v /= 1024; else if ($1 !~ /MB/) v = 0; print int(v)}') / 1024 + 1 ))
  docker_root="$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || echo /var/lib/docker)"
  free_gb=$(( $(df -Pk "$docker_root" | awk 'NR==2 {print $4}') / 1024 / 1024 ))
  if (( free_gb < 2 * changed_gb + 2 )); then
    die "saving the image needs about $(( 2 * changed_gb + 2 )) GB free on $(df -P "$docker_root" | awk 'NR==2 {print $6}'), but only ${free_gb} GB is.
       Free some space or grow the disk, then re-run this script: what is installed so far is kept."
  fi

  info "saving the container as sharelatex/sharelatex:$target"
  docker commit -m "full TeX Live (install.sh)" sharelatex "sharelatex/sharelatex:$target" >/dev/null
  echo "$target" >"$INSTALL_DIR/config/version"
  ok "config/version -> $target"
}

# An earlier run may have installed TeX Live and then stopped before saving it (e.g. on a
# full disk). Changing the configuration recreates the container, which would throw that
# work away, so save it first.
save_unsaved_texlive() {
  local version
  version="$(cat "$INSTALL_DIR/config/version" 2>/dev/null || true)"
  [[ -n "$version" && "$version" != *-with-texlive-full ]] || return 0
  docker ps --format '{{.Names}}' 2>/dev/null | grep -qx sharelatex || return 0
  in_overleaf 'kpsewhich mathspec.sty >/dev/null 2>&1' || return 0
  info "saving the full TeX Live installed by an earlier run before changing the configuration"
  commit_texlive_image "${version}-with-texlive-full"
}

verify_texlive() {
  local font="TeX Gyre Termes"
  [[ "$MSFONTS" == "yes" ]] && font="Times New Roman"
  docker exec -i sharelatex bash -c 'rm -rf /tmp/tltest && mkdir /tmp/tltest && cat >/tmp/tltest/t.tex' <<EOF
\\documentclass{report}
\\usepackage{mathspec}
\\usepackage{xgreek}
\\setmainfont{$font}
\\usepackage[Sonny]{fncychap}
\\usepackage{biblatex}
\\usepackage{multirow}
\\begin{document}
\\chapter{Test}
Hello, Καλημέρα, \$E = mc^2\$.
\\end{document}
EOF
  if in_overleaf 'cd /tmp/tltest && latexmk -xelatex -interaction=nonstopmode -halt-on-error t.tex >/dev/null 2>&1'; then
    ok "test document compiled with XeLaTeX ($font, Greek, mathspec, biblatex)"
    in_overleaf 'rm -rf /tmp/tltest'
  else
    in_overleaf 'grep -A3 "^!" /tmp/tltest/t.log | head -20' >&2 || true
    die "test compile failed"
  fi
}

# ------------------------------------------------------------------- nginx ---

find_nginx() {
  local bin
  for bin in "$(command -v nginx 2>/dev/null || true)" /usr/sbin/nginx /usr/local/nginx/sbin/nginx; do
    [[ -n "$bin" && -x "$bin" ]] && { echo "$bin"; return 0; }
  done
  return 1
}

nginx_main_conf() { "$1" -t 2>&1 | sed -nE 's/.*configuration file (\S+) (syntax|test).*/\1/p' | head -1; }

# Copies a config file into <confdir>/overleaf-backups/ and prints the copy's path. Backups must
# not sit next to the original: nginx would load a copy left in sites-enabled/ as another site.
backup_file() {
  local dir="$2/overleaf-backups" base copy n=1
  mkdir -p "$dir"
  base="$dir/$(basename "$1").$(date +%Y%m%d-%H%M%S)"
  copy="$base"
  while [[ -e "$copy" ]]; do n=$(( n + 1 )); copy="$base-$n"; done
  cp "$1" "$copy"
  echo "$copy"
}

reload_nginx() {
  local bin="$1"
  if systemctl is-active --quiet nginx 2>/dev/null; then systemctl reload nginx
  elif "$bin" -s reload 2>/dev/null; then :
  else systemctl enable --now nginx >/dev/null 2>&1 || "$bin"
  fi
}

write_proxy_server() {
  local host="${SITE_URL#*://}" ipv6=""
  # Listen on IPv6 too, unless the machine has it disabled (nginx would fail to bind).
  [[ -e /proc/net/if_inet6 ]] && ipv6="listen [::]:${LISTEN_PORT};"
  cat <<EOF
# Overleaf Community Edition (written by install.sh)
map \$http_upgrade \$overleaf_connection_upgrade {
    default upgrade;
    ''      close;
}

server {
    listen ${LISTEN_PORT};
    ${ipv6}
    server_name ${host%%:*};

    client_max_body_size 50M;

    location / {
        proxy_pass http://127.0.0.1:${INTERNAL_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$overleaf_connection_upgrade;
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 3m;
        proxy_send_timeout 3m;
    }
}
EOF
}

setup_nginx() {
  [[ "$NGINX_MODE" == "no" ]] && return 0
  step "Configuring the nginx reverse proxy"

  local bin conf confdir target include_added=0 backup=""
  if ! bin="$(find_nginx)"; then
    info "nginx not found; installing the distribution package"
    apt-get install -y -qq nginx >/dev/null
    bin="$(find_nginx)" || die "nginx installation failed"
  fi
  conf="$(nginx_main_conf "$bin")"
  [[ -n "$conf" && -f "$conf" ]] || die "cannot find nginx's configuration (nginx -t output unexpected)"
  confdir="$(dirname "$conf")"
  ok "using $bin ($conf)"

  local layout=main
  if [[ -d "$confdir/sites-enabled" ]]; then
    layout=sites; target="$confdir/sites-available/overleaf"
  elif "$bin" -T 2>/dev/null | grep -qE '^\s*include\s+\S*conf\.d/\*\.conf'; then
    layout=confd; target="$confdir/conf.d/overleaf.conf"; mkdir -p "$confdir/conf.d"
  else
    target="$confdir/overleaf.conf"
  fi

  # A file written by an earlier run is ours to rewrite (e.g. for a new --listen-port);
  # a proxy someone set up by hand is left alone.
  if [[ ! -f "$target" ]] &&
     "$bin" -T 2>/dev/null | grep -qE "proxy_pass\s+http://(127\.0\.0\.1|localhost):${INTERNAL_PORT}\b"; then
    ok "nginx already proxies to 127.0.0.1:${INTERNAL_PORT}; leaving that configuration as is"
  else
    # On port 80 an Overleaf site named after this machine's IP would take over the site
    # that already answers there. Only the stock nginx welcome page may be replaced.
    local site80
    if [[ "$LISTEN_PORT" == 80 && ! -f "$target" ]] && site80="$(find_port80_listen "$bin")"; then
      site80="${site80%:*}"
      if ! [[ "$site80" == "$confdir"/sites-enabled/default || "$site80" == "$confdir"/conf.d/default.conf ]] ||
         grep -qE '^\s*proxy_pass' "$site80"; then
        die "another site already answers on port 80 ($site80). Keep it with, for example:
       --listen-port 8081 --redirect-paths /latex,/overleaf"
      fi
    fi

    local previous=""
    [[ -f "$target" ]] && { previous="$(mktemp)"; cp "$target" "$previous"; }
    write_proxy_server >"$target"
    if [[ "$layout" == sites ]]; then
      ln -sf "$target" "$confdir/sites-enabled/overleaf"
    elif [[ "$layout" == main ]] && ! grep -qF "include $target;" "$conf"; then
      # Custom builds without sites-enabled/conf.d: add an include inside the http block.
      backup="$(backup_file "$conf" "$confdir")"
      sed -i -E "0,/^\s*http\s*\{/s||&\n    include $target;|" "$conf"
      include_added=1
    fi

    if ! "$bin" -t >/dev/null 2>&1; then
      "$bin" -t >&2 || true
      if [[ -n "$previous" ]]; then cp "$previous" "$target"; else rm -f "$target" "$confdir/sites-enabled/overleaf"; fi
      (( include_added )) && cp "$backup" "$conf"
      die "nginx rejected the new configuration; changes were rolled back"
    fi
    reload_nginx "$bin"
    ok "nginx: port ${LISTEN_PORT} (${SITE_URL#*://}) -> 127.0.0.1:${INTERNAL_PORT} ($target)"
    [[ -n "$backup" ]] && info "previous nginx.conf saved as $backup"
  fi

  [[ -n "$REDIRECT_PATHS" ]] && setup_redirects "$bin" "$confdir"

  if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q '^Status: active'; then
    warn "ufw is active; to allow browsers in, run: sudo ufw allow ${LISTEN_PORT}/tcp"
  fi
  return 0
}

write_redirects() {
  local p
  echo "# Redirects to Overleaf (written by install.sh), included in the site on port 80"
  for p in ${REDIRECT_PATHS//,/ }; do
    printf 'location = %s { return 302 %s/; }\n' "$p" "$SITE_URL"
    printf 'location ^~ %s/ { return 302 %s/; }\n' "$p" "$SITE_URL"
  done
}

# Prints "file:line" of the listen directive of the site that answers on port 80:
# its default_server if there is one, otherwise the first server listening on 80.
find_port80_listen() {
  local bin="$1" pattern f n
  for pattern in '(^|[{;])\s*listen\s+((0\.0\.0\.0|\*):)?80\s[^;]*default_server' '(^|[{;])\s*listen\s+((0\.0\.0\.0|\*):)?80(\s[^;]*)?;'; do
    while read -r f; do
      [[ -f "$f" ]] || continue
      n="$(grep -nE "$pattern" "$f" | head -1 | cut -d: -f1)"
      [[ -n "$n" ]] && { echo "$f:$n"; return 0; }
    done < <("$bin" -T 2>/dev/null | sed -nE 's/^# configuration file (.*):$/\1/p')
  done
  return 1
}

setup_redirects() {
  local bin="$1" confdir="$2" snippet="$2/overleaf-redirects.conf" loc file="" line indent backup="" previous=""
  [[ -f "$snippet" ]] && { previous="$(mktemp)"; cp "$snippet" "$previous"; }
  write_redirects >"$snippet"

  if ! "$bin" -T 2>/dev/null | grep -qF "include $snippet;"; then
    if ! loc="$(find_port80_listen "$bin")"; then
      rm -f "$snippet"
      die "no nginx site has 'listen 80', so there is nowhere to add ${REDIRECT_PATHS}"
    fi
    file="${loc%:*}"; line="${loc##*:}"
    backup="$(backup_file "$file" "$confdir")"
    indent="$(sed -n "${line}s/^\([[:space:]]*\).*/\1/p" "$file")"
    # Right after the listen directive, so it lands inside the server block even when
    # the whole block is on one line.
    sed -i -E "${line}s|(listen\s+[^;]*80[^;]*;)|\1\n${indent}include $snippet;|" "$file"
  fi

  if ! "$bin" -t >/dev/null 2>&1; then
    "$bin" -t >&2 || true
    if [[ -n "$previous" ]]; then cp "$previous" "$snippet"; else rm -f "$snippet"; fi
    [[ -n "$backup" ]] && cp "$backup" "$file"
    die "nginx rejected the redirects; changes were rolled back"
  fi
  reload_nginx "$bin"
  ok "redirects on port 80: ${REDIRECT_PATHS//,/, } -> $SITE_URL/ ($snippet)"
  [[ -n "$backup" ]] && info "included from $file (previous version saved as $backup)"
  return 0
}

# ------------------------------------------------------------------ finish ---

summary() {
  step "Done"
  echo
  echo "    Open:            ${C_BOLD}${SITE_URL}/launchpad${C_RESET}  (create the first admin account)"
  echo "    Then log in at:  ${SITE_URL}/login"
  echo "    Add users at:    ${SITE_URL}/admin/register"
  if [[ -n "$REDIRECT_PATHS" ]]; then
    local host="${SITE_URL#*://}" p
    for p in ${REDIRECT_PATHS//,/ }; do
      echo "    Also via:        ${SITE_URL%%://*}://${host%%:*}$p"
    done
  fi
  echo
  echo "    Toolkit:         cd $INSTALL_DIR"
  echo "                     bin/up -d | bin/stop | bin/logs | bin/doctor"
  echo "    Data:            $INSTALL_DIR/data   (back this up)"
  echo
  echo "    Overleaf runs in the browser with XeLaTeX/LuaLaTeX/pdfLaTeX; choose the compiler"
  echo "    per project in Menu -> Settings -> Compiler."
}

main() {
  preflight "$@"
  install_dependencies
  setup_toolkit
  start_overleaf
  (( TEXLIVE_FULL )) && install_texlive_full
  setup_nginx
  summary
}

main "$@"
