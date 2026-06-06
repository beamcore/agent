#!/bin/sh
# Beamcore installer — downloads a pre-built release from GitHub.
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/beamcore/agent/main/install.sh | sh
#   ./install.sh
#   BEAMCORE_VERSION=v0.2.0 ./install.sh
#
# Environment variables:
#   BEAMCORE_VERSION      - version to install (default: latest)
#   BEAMCORE_INSTALL_DIR  - app directory (default: ~/.beamcore/app)
#   BEAMCORE_BIN_DIR      - launcher directory (default: ~/.local/bin)
#   BEAMCORE_REPO         - GitHub repo (default: beamcore/agent)
#   BEAMCORE_NO_VERIFY    - skip checksum verification if set to 1
#   BEAMCORE_NO_PATH_HINT - suppress PATH instructions if set to 1

set -eu

REPO="${BEAMCORE_REPO:-beamcore/agent}"
INSTALL_DIR="${BEAMCORE_INSTALL_DIR:-$HOME/.beamcore/app}"
BIN_DIR="${BEAMCORE_BIN_DIR:-$HOME/.local/bin}"
CONFIG_DIR="${BEAMCORE_CONFIG_DIR:-$HOME/.beamcore}"
VERSION="${BEAMCORE_VERSION:-latest}"
NO_VERIFY="${BEAMCORE_NO_VERIFY:-0}"
NO_PATH_HINT="${BEAMCORE_NO_PATH_HINT:-0}"

GITHUB_BASE="${BEAMCORE_GITHUB_BASE:-https://github.com/${REPO}}"

# --- Utilities ---

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

has_cmd() {
  command -v "$1" >/dev/null 2>&1
}

# --- Platform detection ---

detect_platform() {
  local os arch

  os="$(uname -s)"
  case "$os" in
    Linux*)  os="linux" ;;
    Darwin*) os="darwin" ;;
    *)       die "Unsupported operating system: $os (only Linux and macOS are supported)" ;;
  esac

  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64)   arch="amd64" ;;
    aarch64|arm64)   arch="arm64" ;;
    *)               die "Unsupported architecture: $arch (only amd64 and arm64 are supported)" ;;
  esac

  PLATFORM="${os}-${arch}"
}

# --- Version resolution ---

resolve_version() {
  if [ "$VERSION" = "latest" ]; then
    info "Resolving latest version"
    # Use the redirect from /releases/latest to avoid API rate limits
    local url="${GITHUB_BASE}/releases/latest"
    local redirect

    if has_cmd curl; then
      redirect="$(curl -fsSL -o /dev/null -w '%{url_effective}' "$url" 2>/dev/null)" || \
        die "Failed to resolve latest version. Check your network or set BEAMCORE_VERSION explicitly."
    elif has_cmd wget; then
      redirect="$(wget --max-redirect=0 -q -O /dev/null --server-response "$url" 2>&1 | \
        grep -i 'Location:' | tail -1 | awk '{print $2}' | tr -d '\r')" || \
        die "Failed to resolve latest version. Check your network or set BEAMCORE_VERSION explicitly."
    else
      die "Either curl or wget is required"
    fi

    VERSION="$(echo "$redirect" | grep -o '[^/]*$')"
    [ -n "$VERSION" ] || die "Could not parse version from redirect: $redirect"
  fi

  # Ensure version starts with 'v'
  case "$VERSION" in
    v*) ;;
    *)  VERSION="v${VERSION}" ;;
  esac
}

# --- Download ---

download() {
  local url="$1" dest="$2"

  if has_cmd curl; then
    curl -fsSL -o "$dest" "$url"
  elif has_cmd wget; then
    wget -q -O "$dest" "$url"
  else
    die "Either curl or wget is required"
  fi
}

# --- Checksum verification ---

verify_checksum() {
  local tarball="$1" checksums_file="$2"

  if [ "$NO_VERIFY" = "1" ]; then
    warn "Skipping checksum verification (BEAMCORE_NO_VERIFY=1)"
    return 0
  fi

  if [ ! -f "$checksums_file" ]; then
    warn "No checksums file found — skipping verification"
    return 0
  fi

  local filename expected actual
  filename="$(basename "$tarball")"
  expected="$(grep "$filename" "$checksums_file" | awk '{print $1}')"

  if [ -z "$expected" ]; then
    warn "No checksum entry for $filename — skipping verification"
    return 0
  fi

  if has_cmd sha256sum; then
    actual="$(sha256sum "$tarball" | awk '{print $1}')"
  elif has_cmd shasum; then
    actual="$(shasum -a 256 "$tarball" | awk '{print $1}')"
  else
    warn "Neither sha256sum nor shasum available — skipping verification"
    return 0
  fi

  if [ "$expected" != "$actual" ]; then
    die "Checksum mismatch for $filename\n  expected: $expected\n  actual:   $actual"
  fi

  ok "Checksum verified"
}

# --- Install ---

install_release() {
  local asset_name asset_url checksums_url checksums_file

  asset_name="beamcore-${VERSION#v}-${PLATFORM}.tar.gz"
  asset_url="${GITHUB_BASE}/releases/download/${VERSION}/${asset_name}"
  checksums_url="${GITHUB_BASE}/releases/download/${VERSION}/SHA256SUMS"

  info "Downloading Beamcore ${VERSION} (${PLATFORM})"

  # Use script-level variable so the EXIT trap can access it
  BEAMCORE_TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/beamcore-install.XXXXXX")"
  trap 'rm -rf "$BEAMCORE_TMP_DIR"' EXIT
  local tmp_dir="$BEAMCORE_TMP_DIR"

  download "$asset_url" "$tmp_dir/$asset_name" || \
    die "Download failed. No release found for ${VERSION} / ${PLATFORM}.\nCheck available releases: ${GITHUB_BASE}/releases"

  # Attempt checksum verification
  checksums_file="$tmp_dir/SHA256SUMS"
  download "$checksums_url" "$checksums_file" 2>/dev/null || true
  verify_checksum "$tmp_dir/$asset_name" "$checksums_file"

  info "Installing to ${INSTALL_DIR}"

  # Extract to staging directory, verify, then move into place
  local staging="$tmp_dir/staged"
  mkdir -p "$staging"
  tar -xzf "$tmp_dir/$asset_name" -C "$staging"

  # Verify the extracted release looks valid
  if [ ! -f "$staging/bin/agent" ]; then
    die "Extracted archive does not contain expected release structure (missing bin/agent)"
  fi

  # Atomic-ish replacement: backup old, move new, remove backup
  if [ -d "$INSTALL_DIR" ]; then
    local backup="${INSTALL_DIR}.backup.$$"
    mv "$INSTALL_DIR" "$backup"
    if mv "$staging" "$INSTALL_DIR"; then
      rm -rf "$backup"
    else
      # Rollback
      mv "$backup" "$INSTALL_DIR"
      die "Failed to install new release — previous installation restored"
    fi
  else
    mkdir -p "$(dirname "$INSTALL_DIR")"
    mv "$staging" "$INSTALL_DIR"
  fi

  ok "App installed to ${INSTALL_DIR}"
}

# --- Launcher ---

create_launcher() {
  local launcher="${BIN_DIR}/beamcore"

  mkdir -p "$BIN_DIR"
  cat > "$launcher" << 'LAUNCHER_EOF'
#!/bin/sh
set -eu

BEAMCORE_APP="${BEAMCORE_INSTALL_DIR:-$HOME/.beamcore/app}"
AGENT_BIN="$BEAMCORE_APP/bin/agent"

if [ ! -x "$AGENT_BIN" ]; then
  printf '\033[31merror:\033[0m Beamcore is not installed at %s\n' "$BEAMCORE_APP" >&2
  printf 'Run the installer again or set BEAMCORE_INSTALL_DIR\n' >&2
  exit 1
fi

if [ "$#" -eq 0 ]; then
  exec "$AGENT_BIN" eval "Application.ensure_all_started(:agent); Beamcore.Agent.chat()"
fi

exec "$AGENT_BIN" "$@"
LAUNCHER_EOF

  chmod +x "$launcher"
  ok "Launcher installed to ${launcher}"
}

# --- Config directory ---

ensure_config() {
  if [ ! -d "$CONFIG_DIR" ]; then
    mkdir -p "$CONFIG_DIR"
    ok "Created config directory: ${CONFIG_DIR}"
  fi
}

# --- PATH instructions ---

print_path_instructions() {
  if [ "$NO_PATH_HINT" = "1" ]; then
    return
  fi

  echo ""
  case ":$PATH:" in
    *":${BIN_DIR}:"*)
      ok "${BIN_DIR} is in PATH"
      echo "  Run: beamcore"
      ;;
    *)
      warn "${BIN_DIR} is not in your PATH"
      echo ""
      echo "  Add it now:"
      echo "    export PATH=\"${BIN_DIR}:\$PATH\""
      echo ""
      echo "  Make it permanent (add to your shell rc file):"
      local rc_file="$HOME/.profile"
      case "${SHELL:-}" in
        *zsh*)  rc_file="$HOME/.zshrc" ;;
        *bash*) rc_file="$HOME/.bashrc" ;;
      esac
      echo "    echo 'export PATH=\"${BIN_DIR}:\$PATH\"' >> ${rc_file}"
      echo ""
      echo "  Or run directly:"
      echo "    ${BIN_DIR}/beamcore"
      ;;
  esac
}

# --- Main ---

main() {
  echo ""
  echo "  Beamcore Installer"
  echo ""

  detect_platform
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
