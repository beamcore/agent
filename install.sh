#!/bin/sh
# Beamcore installer — downloads a pre-built release from GitHub.
#
# Usage:
#   curl -fsSL https://beamcore.dev/install.sh | sh
#   curl -fsSL https://raw.githubusercontent.com/beamcore/agent/main/install.sh | sh
#   BEAMCORE_VERSION=v0.2.0 ./install.sh
#
# Environment variables:
#   BEAMCORE_VERSION      - version to install (default: latest)
#   BEAMCORE_INSTALL_DIR  - app directory (default: ~/.beamcore/app)
#   BEAMCORE_BIN_DIR      - launcher directory (default: ~/.local/bin)
#   BEAMCORE_CONFIG_DIR   - config directory (default: ~/.beamcore)
#   BEAMCORE_REPO         - GitHub repo (default: beamcore/agent)
#   BEAMCORE_NO_VERIFY    - skip checksum verification if set to 1
#   BEAMCORE_NO_PATH_HINT - suppress PATH instructions if set to 1
#   BEAMCORE_NO_LAUNCHER  - skip launcher creation if set to 1

set -eu

# ==============================================================================
# Configuration
# ==============================================================================

REPO="${BEAMCORE_REPO:-beamcore/agent}"
INSTALL_DIR="${BEAMCORE_INSTALL_DIR:-$HOME/.beamcore/app}"
BIN_DIR="${BEAMCORE_BIN_DIR:-$HOME/.local/bin}"
CONFIG_DIR="${BEAMCORE_CONFIG_DIR:-$HOME/.beamcore}"
VERSION="${BEAMCORE_VERSION:-latest}"
NO_VERIFY="${BEAMCORE_NO_VERIFY:-0}"
NO_PATH_HINT="${BEAMCORE_NO_PATH_HINT:-0}"
NO_LAUNCHER="${BEAMCORE_NO_LAUNCHER:-0}"

GITHUB_BASE="${BEAMCORE_GITHUB_BASE:-https://github.com/${REPO}}"

MAX_RETRIES=3
RETRY_DELAY=2

# ==============================================================================
# Utilities
# ==============================================================================

die() {
  printf '\033[31merror:\033[0m %s\n' "$1" >&2
  exit 1
}

info() {
  printf '\033[1m==> %s\033[0m\n' "$1"
}

ok() {
  printf '\033[32m✓\033[0m %s\n' "$1"
}

warn() {
  printf '\033[33m⚠\033[0m %s\n' "$1"
}

step() {
  printf '    %s\n' "$1"
}

has_cmd() {
  command -v "$1" >/dev/null 2>&1
}

# Retry a command up to MAX_RETRIES times with exponential backoff.
retry() {
  _retry_n=0
  _retry_delay="$RETRY_DELAY"
  while [ "$_retry_n" -lt "$MAX_RETRIES" ]; do
    if "$@"; then
      return 0
    fi
    _retry_n=$(( _retry_n + 1 ))
    if [ "$_retry_n" -lt "$MAX_RETRIES" ]; then
      warn "Attempt $_retry_n failed, retrying in ${_retry_delay}s..."
      sleep "$_retry_delay"
      _retry_delay=$(( _retry_delay * 2 ))
    fi
  done
  return 1
}

# ==============================================================================
# Cleanup trap
# ==============================================================================

CLEANUP_DIRS=""

cleanup() {
  # Remove any temporary directories we created
  for d in $CLEANUP_DIRS; do
    rm -rf "$d" 2>/dev/null || true
  done
}

trap cleanup EXIT INT TERM

make_tmp_dir() {
  _tmp="${TMPDIR:-/tmp}/beamcore-install.$$"
  mkdir -p "$_tmp"
  CLEANUP_DIRS="$CLEANUP_DIRS $_tmp"
  printf '%s' "$_tmp"
}

# ==============================================================================
# Platform detection
# ==============================================================================

detect_platform() {
  _os="$(uname -s)"
  case "$_os" in
    Linux*)  _os="linux" ;;
    Darwin*) _os="darwin" ;;
    *)       die "Unsupported operating system: $_os (only Linux and macOS are supported)" ;;
  esac

  _arch="$(uname -m)"
  case "$_arch" in
    x86_64|amd64)  _arch="amd64" ;;
    aarch64|arm64) _arch="arm64" ;;
    *)             die "Unsupported architecture: $_arch (only amd64 and arm64 are supported)" ;;
  esac

  PLATFORM="${_os}-${_arch}"
}

# ==============================================================================
# Prerequisites check
# ==============================================================================

check_prerequisites() {
  if has_cmd curl; then
    DOWNLOADER="curl"
  elif has_cmd wget; then
    DOWNLOADER="wget"
  else
    die "Either curl or wget is required. Install one and try again."
  fi

  if has_cmd tar; then
    : # ok
  else
    die "tar is required but not found."
  fi
}

# ==============================================================================
# Version resolution
# ==============================================================================

resolve_version() {
  if [ "$VERSION" = "latest" ]; then
    info "Resolving latest version"
    _url="${GITHUB_BASE}/releases/latest"
    _redirect=""

    case "$DOWNLOADER" in
      curl)
        _redirect="$(curl -fsSL -o /dev/null -w '%{url_effective}' "$_url" 2>/dev/null)" || \
          die "Failed to resolve latest version. Check your network or set BEAMCORE_VERSION explicitly."
        ;;
      wget)
        _redirect="$(wget --max-redirect=0 -q -O /dev/null --server-response "$_url" 2>&1 | \
          grep -i 'Location:' | tail -1 | awk '{print $2}' | tr -d '\r')" || \
          die "Failed to resolve latest version. Check your network or set BEAMCORE_VERSION explicitly."
        ;;
    esac

    VERSION="$(echo "$_redirect" | grep -o '[^/]*$')"
    [ -n "$VERSION" ] || die "Could not parse version from redirect: $_redirect"
  fi

  # Ensure version starts with 'v'
  case "$VERSION" in
    v*) ;;
    *)  VERSION="v${VERSION}" ;;
  esac
}

# ==============================================================================
# Download with retry
# ==============================================================================

download() {
  _dl_url="$1"
  _dl_dest="$2"

  case "$DOWNLOADER" in
    curl)
      retry curl -fsSL --connect-timeout 15 --max-time 300 -o "$_dl_dest" "$_dl_url"
      ;;
    wget)
      retry wget -q --connect-timeout=15 --timeout=300 -O "$_dl_dest" "$_dl_url"
      ;;
  esac
}

# ==============================================================================
# Checksum verification
# ==============================================================================

verify_checksum() {
  _tarball="$1"
  _checksums_file="$2"

  if [ "$NO_VERIFY" = "1" ]; then
    warn "Skipping checksum verification (BEAMCORE_NO_VERIFY=1)"
    return 0
  fi

  if [ ! -f "$_checksums_file" ]; then
    warn "No checksums file found — skipping verification"
    return 0
  fi

  _filename="$(basename "$_tarball")"
  _expected="$(grep "$_filename" "$_checksums_file" | awk '{print $1}')"

  if [ -z "$_expected" ]; then
    warn "No checksum entry for $_filename — skipping verification"
    return 0
  fi

  if has_cmd sha256sum; then
    _actual="$(sha256sum "$_tarball" | awk '{print $1}')"
  elif has_cmd shasum; then
    _actual="$(shasum -a 256 "$_tarball" | awk '{print $1}')"
  else
    warn "Neither sha256sum nor shasum available — skipping verification"
    return 0
  fi

  if [ "$_expected" != "$_actual" ]; then
    die "Checksum mismatch for $_filename
  expected: $_expected
  actual:   $_actual
The download may be corrupted. Try again or download manually."
  fi

  ok "Checksum verified"
}

# ==============================================================================
# Verify download is a valid tarball
# ==============================================================================

verify_tarball() {
  _file="$1"
  _size="$(wc -c < "$_file" | tr -d ' ')"

  # Minimum reasonable size: 1MB (a real release should be several MB)
  if [ "$_size" -lt 1048576 ]; then
    # Could be an error page from GitHub (404 HTML is ~1-5KB)
    if head -c 100 "$_file" | grep -qi '<!doctype\|<html\|404'; then
      die "Downloaded file appears to be an HTML error page, not a release tarball.
The requested version ($VERSION) may not exist or there may be a network issue.
Check available releases: ${GITHUB_BASE}/releases"
    fi
  fi

  if ! tar -tzf "$_file" >/dev/null 2>&1; then
    die "Downloaded file is not a valid gzip tarball. The download may be corrupted.
Try again, or download manually from: ${GITHUB_BASE}/releases"
  fi
}

# ==============================================================================
# Install release
# ==============================================================================

install_release() {
  _asset_name="beamcore-${VERSION#v}-${PLATFORM}.tar.gz"
  _asset_url="${GITHUB_BASE}/releases/download/${VERSION}/${_asset_name}"
  _checksums_url="${GITHUB_BASE}/releases/download/${VERSION}/SHA256SUMS"

  info "Downloading Beamcore ${VERSION} (${PLATFORM})"

  _tmp_dir="$(make_tmp_dir)"

  # Download the tarball
  step "Downloading archive..."
  download "$_asset_url" "$_tmp_dir/$_asset_name" || \
    die "Download failed. No release found for ${VERSION} / ${PLATFORM}.
Check available releases: ${GITHUB_BASE}/releases"

  # Download checksums (best effort)
  _checksums_file="$_tmp_dir/SHA256SUMS"
  download "$_checksums_url" "$_checksums_file" 2>/dev/null || true

  # Verify checksum
  verify_checksum "$_tmp_dir/$_asset_name" "$_checksums_file"

  # Verify it's a real tarball
  step "Verifying archive integrity..."
  verify_tarball "$_tmp_dir/$_asset_name"

  info "Installing to ${INSTALL_DIR}"

  # Extract to staging directory
  _staging="$_tmp_dir/staged"
  mkdir -p "$_staging"
  tar -xzf "$_tmp_dir/$_asset_name" -C "$_staging"

  # Verify the extracted release looks valid
  if [ ! -f "$_staging/bin/beamcore" ]; then
    die "Extracted archive does not contain expected release structure (missing bin/beamcore)"
  fi

  # Atomic replacement with rollback
  _parent="$(dirname "$INSTALL_DIR")"
  mkdir -p "$_parent"

  if [ -d "$INSTALL_DIR" ]; then
    _backup="${INSTALL_DIR}.backup.$$"
    mv "$INSTALL_DIR" "$_backup"
    if mv "$_staging" "$INSTALL_DIR"; then
      rm -rf "$_backup"
    else
      # Rollback
      rm -rf "$INSTALL_DIR"
      mv "$_backup" "$INSTALL_DIR"
      die "Failed to install new release — previous installation restored"
    fi
  else
    mv "$_staging" "$INSTALL_DIR"
  fi

  ok "App installed to ${INSTALL_DIR}"
}

# ==============================================================================
# Launcher
# ==============================================================================

create_launcher() {
  if [ "$NO_LAUNCHER" = "1" ]; then
    return 0
  fi

  _launcher="${BIN_DIR}/beamcore"
  mkdir -p "$BIN_DIR"

  _launcher_tmp="${_launcher}.tmp.$$"
  cat > "$_launcher_tmp" << 'LAUNCHER_EOF'
#!/bin/sh
set -eu

BEAMCORE_APP="${BEAMCORE_INSTALL_DIR:-$HOME/.beamcore/app}"
AGENT_BIN="$BEAMCORE_APP/bin/beamcore"

if [ ! -x "$AGENT_BIN" ]; then
  printf '\033[31merror:\033[0m Beamcore is not installed at %s\n' "$BEAMCORE_APP" >&2
  printf 'Run the installer again or set BEAMCORE_INSTALL_DIR\n' >&2
  exit 1
fi

# Pick up Erlang cookie if present
COOKIE_FILE="$HOME/.erlang.cookie"
if [ -f "$COOKIE_FILE" ]; then
  RELEASE_COOKIE="$(cat "$COOKIE_FILE")"
  export RELEASE_COOKIE
fi

if [ "$#" -eq 0 ]; then
  exec "$AGENT_BIN" eval "Application.ensure_all_started(:beamcore); Beamcore.Agent.chat()"
fi

exec "$AGENT_BIN" "$@"
LAUNCHER_EOF

  chmod +x "$_launcher_tmp"
  mv "$_launcher_tmp" "$_launcher"
  ok "Launcher installed to ${_launcher}"
}

# ==============================================================================
# Config directory
# ==============================================================================

ensure_config() {
  if [ ! -d "$CONFIG_DIR" ]; then
    mkdir -p "$CONFIG_DIR"
    ok "Created config directory: ${CONFIG_DIR}"
  fi
}

# ==============================================================================
# PATH instructions
# ==============================================================================

print_path_instructions() {
  if [ "$NO_PATH_HINT" = "1" ]; then
    return
  fi

  echo ""
  case ":$PATH:" in
    *":${BIN_DIR}:"*)
      ok "${BIN_DIR} is already in your PATH"
      echo "  Run: beamcore"
      ;;
    *)
      warn "${BIN_DIR} is not in your PATH"
      echo ""
      echo "  Add it now (this session only):"
      echo "    export PATH=\"${BIN_DIR}:\$PATH\""
      echo ""
      echo "  Make it permanent:"

      _rc_file="$HOME/.profile"
      case "${SHELL:-}" in
        *zsh*)  _rc_file="$HOME/.zshrc" ;;
        *bash*) _rc_file="$HOME/.bashrc" ;;
      esac

      echo "    echo 'export PATH=\"${BIN_DIR}:\$PATH\"' >> $_rc_file"
      echo ""
      echo "  Or run directly:"
      echo "    ${BIN_DIR}/beamcore"
      ;;
  esac
}

# ==============================================================================
# Pre-flight checks
# ==============================================================================

preflight() {
  # Check we can write to the parent of INSTALL_DIR
  _parent="$(dirname "$INSTALL_DIR")"
  if [ -e "$_parent" ] && [ ! -w "$_parent" ]; then
    die "Cannot write to $_parent — check permissions or set BEAMCORE_INSTALL_DIR"
  fi

  # Check we can write to BIN_DIR (if it exists)
  if [ -e "$BIN_DIR" ] && [ ! -w "$BIN_DIR" ]; then
    die "Cannot write to $BIN_DIR — check permissions or set BEAMCORE_BIN_DIR"
  fi
}

# ==============================================================================
# Main
# ==============================================================================

main() {
  echo ""
  echo "  ┌────────────────────────────────┐"
  echo "  │     Beamcore Agent Installer    │"
  echo "  └────────────────────────────────┘"
  echo ""

  check_prerequisites
  detect_platform
  preflight
  resolve_version
  install_release
  create_launcher
  ensure_config
  print_path_instructions

  echo ""
  ok "Beamcore ${VERSION} installed successfully"
  echo ""
}

main "$@"