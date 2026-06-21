#!/bin/sh
set -eu

KONS_HOME=${KONS_HOME:-${PREFIX:-"$HOME/.kons"}}
PREFIX=${PREFIX:-"$KONS_HOME"}
KONS_REPO=${KONS_REPO:-"https://github.com/scheme-packages/kons"}
KONS_REF=${KONS_REF:-"main"}
KONS_TARBALL_URL=${KONS_TARBALL_URL:-"$KONS_REPO/archive/$KONS_REF.tar.gz"}
KONS_SOURCE=${KONS_SOURCE:-""}
KONS_DEFAULT_SCHEME=${KONS_DEFAULT_SCHEME:-""}
NON_INTERACTIVE=0
DRY_RUN=0
KEEP_TMP=${KONS_KEEP_TMP:-0}

say() {
  printf '%s\n' "$*"
}

say_err() {
  printf '%s\n' "$*" >&2
}

die() {
  say_err "install.sh: error: $*"
  exit 1
}

usage() {
  cat <<'USAGE'
Usage: install.sh [options]

Options:
  --kons-home DIR        Install root (default: $KONS_HOME, $PREFIX, or ~/.kons)
  --prefix DIR           Compatibility alias for --kons-home
  --repo URL             GitHub-style source repo URL
  --ref REF              Git ref used for tarball or git clone
  --tarball-url URL      Source tarball URL
  --source DIR           Use an existing local checkout/source tree
  --scheme NAME          Default project runner: capy, gauche, guile, or chibi
  --non-interactive      Fail instead of prompting for choices
  --dry-run              Print actions without changing the filesystem
  --keep-tmp             Keep temporary source checkout
  -h, --help             Show this help

The installer verifies the selected Scheme runner is available and can offer to
install Gauche, Guile, or Chibi via your system package manager (apt, pacman,
dnf, brew, pkg, etc.). The installed `kons` launcher can run through CapyScheme,
Gauche, Guile, or Chibi.
USAGE
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1
}

require_cmd() {
  if ! need_cmd "$1"; then
    die "required command not found: $1"
  fi
}

run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    say "+ $*"
  else
    "$@"
  fi
}

prompt() {
  if [ "$NON_INTERACTIVE" -eq 1 ] || [ ! -r /dev/tty ]; then
    return 1
  fi
  printf '%s' "$1" >&2
  IFS= read -r answer </dev/tty
  printf '%s' "$answer"
  return 0
}

validate_scheme() {
  case "$1" in
    capy|gauche|gosh|guile|chibi|chibi-scheme) ;;
    *) die "invalid --scheme: $1 (expected capy, gauche, guile, or chibi)" ;;
  esac
}

canonical_scheme() {
  case "$1" in
    gosh) say "gauche" ;;
    chibi-scheme) say "chibi" ;;
    *) say "$1" ;;
  esac
}

scheme_command() {
  case "$1" in
    capy) say "capy" ;;
    gauche) say "gosh" ;;
    guile) say "guile" ;;
    chibi) say "chibi-scheme" ;;
    *) die "invalid scheme: $1" ;;
  esac
}

require_scheme_runner() {
  scheme=$1
  command=$(scheme_command "$scheme")
  require_cmd "$command"
}

detect_os() {
  uname_cmd=uname
  if ! need_cmd uname; then
    if [ -x /usr/bin/uname ]; then uname_cmd=/usr/bin/uname
    elif [ -x /bin/uname ]; then uname_cmd=/bin/uname
    else say unknown; return 0
    fi
  fi
  uname_s=$($uname_cmd -s 2>/dev/null || say unknown)
  case "$uname_s" in
    Darwin) say macos ;;
    FreeBSD) say freebsd ;;
    OpenBSD) say openbsd ;;
    NetBSD) say netbsd ;;
    Linux) say linux ;;
    *) say unknown ;;
  esac
}

detect_pkg_manager() {
  os=$(detect_os)

  if [ "$os" = macos ]; then
    if need_cmd brew; then say brew; return 0; fi
    if need_cmd port; then say macports; return 0; fi
    say none
    return 0
  fi

  if [ "$os" = freebsd ]; then
    if need_cmd pkg; then say pkg; return 0; fi
    say none
    return 0
  fi

  if [ "$os" = openbsd ]; then
    if need_cmd pkg_add; then say pkg_add; return 0; fi
    say none
    return 0
  fi

  if [ "$os" = netbsd ]; then
    if need_cmd pkgin; then say pkgin; return 0; fi
    if need_cmd pkg_add; then say pkg_add; return 0; fi
    say none
    return 0
  fi

  if [ "$os" = linux ] && [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    case "${ID:-}:${ID_LIKE:-}" in
      *alpine*) if need_cmd apk; then say apk; return 0; fi ;;
      *arch*|*manjaro*|*endeavouros*) if need_cmd pacman; then say pacman; return 0; fi ;;
      *fedora*|*rhel*|*centos*|*rocky*|*alma*|*nobara*) if need_cmd dnf; then say dnf; return 0; fi
        if need_cmd yum; then say yum; return 0; fi ;;
      *opensuse*|*suse*) if need_cmd zypper; then say zypper; return 0; fi ;;
      *void*) if need_cmd xbps-install; then say xbps; return 0; fi ;;
      *nixos*) if need_cmd nix-env; then say nix; return 0; fi ;;
      *debian*|*ubuntu*|*linuxmint*|*pop*|*elementary*) if need_cmd apt-get; then say apt; return 0; fi ;;
    esac
  fi

  if need_cmd apt-get; then say apt; return 0; fi
  if need_cmd dnf; then say dnf; return 0; fi
  if need_cmd yum; then say yum; return 0; fi
  if need_cmd pacman; then say pacman; return 0; fi
  if need_cmd zypper; then say zypper; return 0; fi
  if need_cmd apk; then say apk; return 0; fi
  if need_cmd xbps-install; then say xbps; return 0; fi
  if need_cmd brew; then say brew; return 0; fi
  if need_cmd pkg; then say pkg; return 0; fi
  if need_cmd pkgin; then say pkgin; return 0; fi
  if need_cmd pkg_add; then say pkg_add; return 0; fi
  say none
}

scheme_pkg_name() {
  scheme=$1
  pkg_mgr=$2

  case "$scheme:$pkg_mgr" in
    gauche:apt) say gauche ;;
    guile:apt) say guile-3.0 ;;
    chibi:apt) say chibi-scheme ;;

    gauche:pacman) say gauche ;;
    guile:pacman) say guile ;;
    chibi:pacman) say chibi ;;

    gauche:dnf|gauche:yum) say gauche ;;
    guile:dnf|guile:yum) say guile ;;
    chibi:dnf|chibi:yum) say chibi-scheme ;;

    gauche:apk) say gauche ;;
    guile:apk) say guile ;;
    chibi:apk) say chibi ;;

    gauche:zypper) say gauche ;;
    guile:zypper) say guile ;;
    chibi:zypper) say chibi-scheme ;;

    gauche:xbps) say gauche ;;
    guile:xbps) say guile ;;
    chibi:xbps) say chibi-scheme ;;

    gauche:brew|gauche:macports) say gauche ;;
    guile:brew|guile:macports) say guile ;;
    chibi:brew|chibi:macports) say chibi-scheme ;;

    gauche:pkg) say gauche ;;
    guile:pkg) say guile3 ;;
    chibi:pkg) say chibi-scheme ;;

    gauche:pkgin|gauche:pkg_add) say gauche ;;
    guile:pkgin|guile:pkg_add) say guile ;;
    chibi:pkgin|chibi:pkg_add) say chibi-scheme ;;

    gauche:nix) say gauche ;;
    guile:nix) say guile ;;
    chibi:nix) say chibi ;;

    *) die "no package mapping for scheme=$scheme on pkg_mgr=$pkg_mgr" ;;
  esac
}

scheme_install_command() {
  scheme=$1
  pkg_mgr=$2
  pkg=$(scheme_pkg_name "$scheme" "$pkg_mgr")

  case "$pkg_mgr" in
    apt) say "apt-get install -y $pkg" ;;
    pacman) say "pacman -S --needed --noconfirm $pkg" ;;
    dnf|yum) say "$pkg_mgr install -y $pkg" ;;
    apk) say "apk add $pkg" ;;
    zypper) say "zypper --non-interactive install $pkg" ;;
    xbps) say "xbps-install -Sy $pkg" ;;
    brew) say "brew install $pkg" ;;
    macports) say "port install $pkg" ;;
    pkg) say "pkg install -y $pkg" ;;
    pkgin) say "pkgin -y install $pkg" ;;
    pkg_add) say "pkg_add $pkg" ;;
    nix) say "nix-env -iA nixpkgs.$pkg" ;;
    *) return 1 ;;
  esac
}

run_privileged() {
  pkg_mgr=$1
  shift

  case "$pkg_mgr" in
    brew|macports|nix)
      run "$@"
      ;;
    *)
      if [ "$(id -u)" -eq 0 ]; then
        run "$@"
      elif need_cmd sudo; then
        run sudo "$@"
      else
        run "$@"
      fi
      ;;
  esac
}

scheme_install_hint() {
  scheme=$1
  pkg_mgr=$(detect_pkg_manager)
  os=$(detect_os)

  if [ "$pkg_mgr" != none ]; then
    if cmd=$(scheme_install_command "$scheme" "$pkg_mgr"); then
      say "  $cmd"
      return 0
    fi
  fi

  say "  Install a $scheme runner for $os manually, then re-run install.sh."
  case "$scheme" in
    gauche) say "  Gauche provides the 'gosh' command." ;;
    guile) say "  Guile provides the 'guile' command." ;;
    chibi) say "  Chibi provides the 'chibi-scheme' command." ;;
  esac
}

install_scheme_runner() {
  scheme=$1
  pkg_mgr=$(detect_pkg_manager)

  if [ "$pkg_mgr" = none ]; then
    say_err "No supported package manager found on $(detect_os)."
    scheme_install_hint "$scheme" >&2
    return 1
  fi

  if ! install_cmd=$(scheme_install_command "$scheme" "$pkg_mgr"); then
    say_err "Cannot map $scheme to a package on $pkg_mgr."
    scheme_install_hint "$scheme" >&2
    return 1
  fi

  say "Installing $scheme via $pkg_mgr:"
  say "  $install_cmd"

  # shellcheck disable=SC2086
  case "$pkg_mgr" in
    apt)
      run_privileged "$pkg_mgr" sh -c "export DEBIAN_FRONTEND=noninteractive; apt-get update && apt-get install -y $(scheme_pkg_name "$scheme" "$pkg_mgr")" ;;
    pacman)
      run_privileged "$pkg_mgr" pacman -S --needed --noconfirm "$(scheme_pkg_name "$scheme" "$pkg_mgr")" ;;
    dnf|yum)
      run_privileged "$pkg_mgr" "$pkg_mgr" install -y "$(scheme_pkg_name "$scheme" "$pkg_mgr")" ;;
    apk)
      run_privileged "$pkg_mgr" apk add "$(scheme_pkg_name "$scheme" "$pkg_mgr")" ;;
    zypper)
      run_privileged "$pkg_mgr" zypper --non-interactive install "$(scheme_pkg_name "$scheme" "$pkg_mgr")" ;;
    xbps)
      run_privileged "$pkg_mgr" xbps-install -Sy "$(scheme_pkg_name "$scheme" "$pkg_mgr")" ;;
    brew)
      run_privileged "$pkg_mgr" brew install "$(scheme_pkg_name "$scheme" "$pkg_mgr")" ;;
    macports)
      run_privileged "$pkg_mgr" port install "$(scheme_pkg_name "$scheme" "$pkg_mgr")" ;;
    pkg)
      run_privileged "$pkg_mgr" pkg install -y "$(scheme_pkg_name "$scheme" "$pkg_mgr")" ;;
    pkgin)
      run_privileged "$pkg_mgr" pkgin -y install "$(scheme_pkg_name "$scheme" "$pkg_mgr")" ;;
    pkg_add)
      run_privileged "$pkg_mgr" pkg_add "$(scheme_pkg_name "$scheme" "$pkg_mgr")" ;;
    nix)
      run_privileged "$pkg_mgr" nix-env -iA "nixpkgs.$(scheme_pkg_name "$scheme" "$pkg_mgr")" ;;
    *)
      return 1 ;;
  esac
}

ensure_scheme_runner() {
  scheme=$1
  command=$(scheme_command "$scheme")

  if need_cmd "$command"; then
    return 0
  fi

  say_err "Scheme runner not found: $command ($scheme)"

  if [ "$NON_INTERACTIVE" -eq 1 ] || [ ! -r /dev/tty ]; then
    say_err "Install it manually:"
    scheme_install_hint "$scheme" >&2
    die "required command not found: $command"
  fi

  pkg_mgr=$(detect_pkg_manager)
  if [ "$pkg_mgr" = none ]; then
    say_err "No supported package manager found on $(detect_os)."
    scheme_install_hint "$scheme" >&2
    die "required command not found: $command"
  fi

  if ! answer=$(prompt "Install $scheme now using $pkg_mgr? [Y/n]: "); then
    die "required command not found: $command"
  fi

  case "$answer" in
    n|N|no|No|NO) die "required command not found: $command" ;;
  esac

  install_scheme_runner "$scheme" || die "failed to install $scheme"
  require_scheme_runner "$scheme"
}

choose_default_scheme() {
  if [ -n "$KONS_DEFAULT_SCHEME" ]; then
    validate_scheme "$KONS_DEFAULT_SCHEME"
    canonical_scheme "$KONS_DEFAULT_SCHEME"
    return 0
  fi

  available=""
  if need_cmd capy; then available="$available capy"; fi
  if need_cmd gosh; then available="$available gauche"; fi
  if need_cmd guile; then available="$available guile"; fi
  if need_cmd chibi-scheme; then available="$available chibi"; fi

  case "$available" in
    *" capy"*) say "capy"; return 0 ;;
    *" gauche"*) say "gauche"; return 0 ;;
    *" guile"*) say "guile"; return 0 ;;
    *" chibi"*) say "chibi"; return 0 ;;
  esac

  if answer=$(prompt "Default project runner [gauche/guile/chibi] (default: guile): "); then
    if [ -z "$answer" ]; then answer=guile; fi
    validate_scheme "$answer"
    canonical_scheme "$answer"
    return 0
  fi

  say "guile"
}

make_tmp_dir() {
  if [ "$DRY_RUN" -eq 1 ]; then
    say "${TMPDIR:-/tmp}/kons-install.dry-run"
    return 0
  fi
  if need_cmd mktemp; then
    mktemp -d "${TMPDIR:-/tmp}/kons-install.XXXXXX"
  else
    tmp=${TMPDIR:-/tmp}/kons-install.$$
    rm -rf "$tmp"
    mkdir -p "$tmp"
    say "$tmp"
  fi
}

cleanup() {
  if [ "$KEEP_TMP" = "1" ] || [ "$DRY_RUN" -eq 1 ]; then
    return 0
  fi
  if [ -n "${TMP_ROOT:-}" ] && [ -d "$TMP_ROOT" ]; then
    rm -rf "$TMP_ROOT"
  fi
}

download_source() {
  dest=$1
  run mkdir -p "$dest"

  if [ -n "$KONS_SOURCE" ]; then
    say "Using local source: $KONS_SOURCE"
    if [ "$DRY_RUN" -eq 1 ]; then
      say "+ copy $KONS_SOURCE/. $dest"
    else
      cp -R "$KONS_SOURCE/." "$dest"
    fi
    return 0
  fi

  if need_cmd git; then
    say "Cloning $KONS_REPO#$KONS_REF"
    if [ "$DRY_RUN" -eq 1 ]; then
      say "+ git clone --depth 1 --branch $KONS_REF $KONS_REPO $dest"
      say "+ git -C $dest submodule update --init --recursive vendor/scm-args vendor/conduit"
    else
      git clone --depth 1 --branch "$KONS_REF" "$KONS_REPO" "$dest"
      git -C "$dest" submodule update --init --recursive vendor/scm-args vendor/conduit
    fi
    return 0
  fi

  if need_cmd curl; then
    require_cmd tar
    say "Downloading $KONS_TARBALL_URL"
    if [ "$DRY_RUN" -eq 1 ]; then
      say "+ curl -fsSL $KONS_TARBALL_URL | tar -xz -C $dest --strip-components=1"
    else
      curl -fsSL "$KONS_TARBALL_URL" | tar -xz -C "$dest" --strip-components=1
    fi
    return 0
  fi

  die "need curl+tar, git, or --source DIR to fetch kons"
}

ensure_vendor_dependency() {
  source_dir=$1

  if [ -d "$source_dir/vendor/scm-args/src/args" ] && [ -d "$source_dir/vendor/conduit/src/conduit" ]; then
    return 0
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    say "+ git -C $source_dir submodule update --init --recursive vendor/scm-args vendor/conduit"
    return 0
  fi

  require_cmd git
  [ -d "$source_dir/.git" ] || die "vendored dependencies are missing and $source_dir is not a git checkout"
  git -C "$source_dir" submodule update --init --recursive vendor/scm-args vendor/conduit
  [ -d "$source_dir/vendor/scm-args/src/args" ] || die "vendor/scm-args did not provide src/args"
  [ -d "$source_dir/vendor/conduit/src/conduit" ] || die "vendor/conduit did not provide src/conduit"
}

write_env_files() {
  scheme=$1
  bin_dir=$KONS_HOME/bin
  env_sh=$KONS_HOME/env
  env_fish=$KONS_HOME/env.fish

  run mkdir -p "$KONS_HOME" "$bin_dir"

  if [ "$DRY_RUN" -eq 1 ]; then
    say "+ write $env_sh"
    say "+ write $env_fish"
    return 0
  fi

  cat >"$env_sh" <<EOF
# kons environment (POSIX sh)
# Source this from your shell rc file:
#   . "$KONS_HOME/env"

case ":\$PATH:" in
  *":$bin_dir:"*) ;;
  *) PATH="$bin_dir:\$PATH" ;;
esac
export PATH

KONS_HOME="$KONS_HOME"
KONS_SCHEME="$scheme"
SCHEME="$scheme"
export KONS_HOME KONS_SCHEME SCHEME
EOF

  cat >"$env_fish" <<EOF
# kons environment (fish)
# Source this from fish config:
#   source "$KONS_HOME/env.fish"

if type -q fish_add_path
  fish_add_path -g "$bin_dir"
else
  if not contains "$bin_dir" \$PATH
    set -gx PATH "$bin_dir" \$PATH
  end
end

set -gx KONS_HOME "$KONS_HOME"
set -gx KONS_SCHEME "$scheme"
set -gx SCHEME "$scheme"
EOF
}

install_kons() {
  source_dir=$1
  scheme=$2
  bin_dir=$KONS_HOME/bin
  launcher=$source_dir/bin/kons

  if [ "$DRY_RUN" -eq 0 ]; then
    require_scheme_runner "$scheme"
    [ -x "$launcher" ] || die "launcher not found: $launcher"
  fi

  say "Installing kons into $KONS_HOME"
  if [ "$DRY_RUN" -eq 1 ]; then
    say "+ mkdir -p $KONS_HOME $bin_dir"
    say "+ KONS_SCHEME=$scheme KONS_HOME=$KONS_HOME KONS_VENDORDIR=$source_dir/vendor $launcher --scheme $scheme install --path $source_dir --root $KONS_HOME --directory $bin_dir --name kons"
  else
    run mkdir -p "$KONS_HOME" "$bin_dir"
    KONS_SCHEME="$scheme" KONS_HOME="$KONS_HOME" KONS_VENDORDIR="$source_dir/vendor" \
      "$launcher" --scheme "$scheme" install \
      --path "$source_dir" --root "$KONS_HOME" \
      --directory "$bin_dir" --name kons
  fi
  write_env_files "$scheme"
}

post_install_message() {
  cat <<EOF

kons installed to:
  $KONS_HOME/bin/kons

Environment snippets:
  $KONS_HOME/env
  $KONS_HOME/env.fish

Enable kons in new shells:
  bash: echo '. "$KONS_HOME/env"' >> ~/.bashrc
  zsh:  echo '. "$KONS_HOME/env"' >> ~/.zshrc
  fish: echo 'source "$KONS_HOME/env.fish"' >> ~/.config/fish/config.fish

Try:
  $KONS_HOME/bin/kons --help
  $KONS_HOME/bin/kons doctor
  $KONS_HOME/bin/kons new hello
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --prefix)
      [ "$#" -ge 2 ] || die "--prefix requires a value"
      KONS_HOME=$2
      PREFIX=$2
      shift 2 ;;
    --kons-home)
      [ "$#" -ge 2 ] || die "--kons-home requires a value"
      KONS_HOME=$2
      PREFIX=$2
      shift 2 ;;
    --repo)
      [ "$#" -ge 2 ] || die "--repo requires a value"
      KONS_REPO=$2
      KONS_TARBALL_URL="$KONS_REPO/archive/$KONS_REF.tar.gz"
      shift 2 ;;
    --ref)
      [ "$#" -ge 2 ] || die "--ref requires a value"
      KONS_REF=$2
      KONS_TARBALL_URL="$KONS_REPO/archive/$KONS_REF.tar.gz"
      shift 2 ;;
    --tarball-url)
      [ "$#" -ge 2 ] || die "--tarball-url requires a value"
      KONS_TARBALL_URL=$2
      shift 2 ;;
    --source)
      [ "$#" -ge 2 ] || die "--source requires a value"
      KONS_SOURCE=$2
      shift 2 ;;
    --scheme)
      [ "$#" -ge 2 ] || die "--scheme requires a value"
      KONS_DEFAULT_SCHEME=$2
      shift 2 ;;
    --non-interactive)
      NON_INTERACTIVE=1
      shift ;;
    --dry-run)
      DRY_RUN=1
      shift ;;
    --keep-tmp)
      KEEP_TMP=1
      shift ;;
    -h|--help)
      usage
      exit 0 ;;
    *)
      die "unknown argument: $1" ;;
  esac
done

scheme=$(choose_default_scheme)

if [ "$DRY_RUN" -eq 0 ]; then
  ensure_scheme_runner "$scheme"
fi

TMP_ROOT=$(make_tmp_dir)
trap cleanup EXIT HUP INT TERM
SOURCE_ROOT=$TMP_ROOT/src

download_source "$SOURCE_ROOT"
ensure_vendor_dependency "$SOURCE_ROOT"
install_kons "$SOURCE_ROOT" "$scheme"
post_install_message
