#!/bin/sh
set -eu
(set -o pipefail) 2>/dev/null && set -o pipefail || true

REPO="contexa-security/contexa-cli"
BIN="contexa"

CYAN='\033[0;36m'
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
DIM='\033[2m'
BOLD='\033[1m'
NC='\033[0m'

info() { printf "  %b%s%b\n" "$DIM" "$1" "$NC"; }
success() { printf "  %b%s%b\n" "$GREEN" "$1" "$NC"; }
warn() { printf "  %b! %s%b\n" "$YELLOW" "$1" "$NC"; }
fail() { printf "  %bError: %s%b\n" "$RED" "$1" "$NC"; exit 1; }

fmt_bytes() {
  bytes=${1:-0}
  case "$bytes" in ''|*[!0-9]*) echo ""; return ;; esac
  if [ "$bytes" -lt 1024 ]; then
    echo "$bytes B"
  elif [ "$bytes" -lt 1048576 ]; then
    awk "BEGIN { printf \"%.1f KB\", $bytes/1024 }"
  elif [ "$bytes" -lt 1073741824 ]; then
    awk "BEGIN { printf \"%.1f MB\", $bytes/1048576 }"
  else
    awk "BEGIN { printf \"%.2f GB\", $bytes/1073741824 }"
  fi
}

print_banner() {
  printf "\n"
  printf "  %b===============================================%b\n" "$CYAN" "$NC"
  printf "  %b Contexa CLI Installer%b\n" "$CYAN$BOLD" "$NC"
  printf "  %b AI-Native Zero Trust Security Platform%b\n" "$YELLOW" "$NC"
  printf "  %b https://ctxa.ai%b\n" "$DIM" "$NC"
  printf "  %b===============================================%b\n\n" "$CYAN" "$NC"
}

check_environment() {
  info "Running environment checks..."

  if command -v java >/dev/null 2>&1; then
    java_major=$(java -version 2>&1 | awk -F '"' '/version/ {print $2; exit}' | awk -F. '{ if ($1 == "1") print $2; else print $1 }')
    if [ -n "$java_major" ] && [ "$java_major" -ge 17 ] 2>/dev/null; then
      success "Java check: JDK 17+ detected."
    else
      warn "Java 17+ was not detected. CLI installation can continue, but Contexa projects require JDK 17+."
    fi
  else
    warn "Java was not found. CLI installation can continue, but Contexa projects require JDK 17+."
  fi

  if command -v docker >/dev/null 2>&1; then
    if docker info >/dev/null 2>&1; then
      success "Docker check: daemon is running."
    else
      warn "Docker daemon is not running. Basic CLI install is OK; local infra commands will need it."
    fi
  else
    warn "Docker CLI was not found. Basic CLI install is OK; local infra commands will need Docker."
  fi
  printf "\n"
}

require_tool() {
  if ! command -v "$1" >/dev/null 2>&1; then
    fail "$1 is required by the installer. Please install it and retry."
  fi
}

resolve_install_dir() {
  if [ -n "${CONTEXA_INSTALL_DIR:-}" ]; then
    printf "%s" "$CONTEXA_INSTALL_DIR"
    return
  fi

  if [ "$(id -u 2>/dev/null || echo 1)" = "0" ]; then
    printf "%s" "/usr/local/bin"
    return
  fi

  if [ -d "/usr/local/bin" ] && [ -w "/usr/local/bin" ]; then
    printf "%s" "/usr/local/bin"
    return
  fi

  if [ -z "${HOME:-}" ]; then
    fail "HOME is empty and CONTEXA_INSTALL_DIR was not provided."
  fi
  printf "%s" "$HOME/.local/bin"
}

print_banner
require_tool curl
require_tool awk
check_environment

VERSION=$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" \
  | awk -F '"' '/"tag_name"/ {print $4; exit}')

if [ -z "$VERSION" ]; then
  fail "could not fetch latest release version from GitHub."
fi

OS=$(uname -s)
ARCH=$(uname -m)

case "$OS" in
  Linux*)
    case "$ARCH" in
      x86_64)  FILE="contexa-linux-x64"; PLATFORM="Linux x64" ;;
      aarch64|arm64) FILE="contexa-linux-arm64"; PLATFORM="Linux ARM64" ;;
      *) fail "unsupported Linux architecture: $ARCH" ;;
    esac ;;
  Darwin*)
    case "$ARCH" in
      arm64) FILE="contexa-macos-arm64"; PLATFORM="macOS ARM64 (Apple Silicon)" ;;
      x86_64)
        fail "Intel Mac prebuilt binary is not available yet. Build from source: https://github.com/${REPO}" ;;
      *) fail "unsupported macOS architecture: $ARCH" ;;
    esac ;;
  MINGW*|MSYS*|CYGWIN*)
    FILE="contexa-win-x64.exe"; BIN="contexa.exe"; PLATFORM="Windows x64" ;;
  *) fail "unsupported OS: $OS" ;;
esac

INSTALL_DIR=$(resolve_install_dir)
INSTALL_PATH="${INSTALL_DIR}/${BIN}"
URL="https://github.com/${REPO}/releases/download/${VERSION}/${FILE}"
SHA_URL="${URL}.sha256"

printf "  Version  : %s\n" "$VERSION"
printf "  Platform : %s\n" "$PLATFORM"
printf "  Target   : %s\n\n" "$INSTALL_PATH"

if ! mkdir -p "$INSTALL_DIR"; then
  fail "could not create install directory: $INSTALL_DIR"
fi
if [ ! -w "$INSTALL_DIR" ]; then
  fail "install directory is not writable: $INSTALL_DIR. Set CONTEXA_INSTALL_DIR to a writable directory."
fi

TMP_BIN=$(mktemp 2>/dev/null || mktemp -t contexa)
TMP_SHA="${TMP_BIN}.sha256"
trap 'rm -f "$TMP_BIN" "$TMP_SHA"' EXIT HUP INT TERM

EXPECTED_SIZE=$(curl -fsSLI "$URL" 2>/dev/null \
  | awk 'BEGIN{IGNORECASE=1} /^content-length:/ { gsub("\r", "", $2); print $2; exit }' || true)
EXPECTED_HUMAN=$(fmt_bytes "$EXPECTED_SIZE")

if [ -n "$EXPECTED_HUMAN" ]; then
  info "Downloading $EXPECTED_HUMAN..."
else
  info "Downloading..."
fi

curl -fsSL "$URL" -o "$TMP_BIN"
ACTUAL_SIZE=$(wc -c <"$TMP_BIN" 2>/dev/null | tr -d ' ')
ACTUAL_HUMAN=$(fmt_bytes "$ACTUAL_SIZE")
if [ -n "$ACTUAL_HUMAN" ]; then
  success "Downloaded $ACTUAL_HUMAN."
else
  success "Downloaded successfully."
fi

info "Verifying checksum..."
if ! curl -fsSL "$SHA_URL" -o "$TMP_SHA"; then
  fail "checksum file not found at $SHA_URL. Refusing to install an unverified binary."
fi

EXPECTED_SHA=$(awk '{print tolower($1); exit}' "$TMP_SHA")
if [ -z "$EXPECTED_SHA" ]; then
  fail "checksum file is empty."
fi

if command -v sha256sum >/dev/null 2>&1; then
  ACTUAL_SHA=$(sha256sum "$TMP_BIN" | awk '{print tolower($1)}')
elif command -v shasum >/dev/null 2>&1; then
  ACTUAL_SHA=$(shasum -a 256 "$TMP_BIN" | awk '{print tolower($1)}')
else
  fail "neither sha256sum nor shasum was found; cannot verify download."
fi

if [ "$EXPECTED_SHA" != "$ACTUAL_SHA" ]; then
  printf "  %bexpected: %s%b\n" "$RED" "$EXPECTED_SHA" "$NC"
  printf "  %bactual  : %s%b\n" "$RED" "$ACTUAL_SHA" "$NC"
  fail "checksum mismatch. Refusing to install a tampered binary."
fi
success "Checksum verified."

EXPECTED_CLI_VERSION=${VERSION#v}
REPORTED_CLI_VERSION=$("$TMP_BIN" --version 2>/dev/null || true)
if [ "$REPORTED_CLI_VERSION" != "$EXPECTED_CLI_VERSION" ]; then
  fail "release tag/binary version mismatch. Tag=$VERSION, binary=${REPORTED_CLI_VERSION:-unavailable}"
fi
success "Version contract verified: $REPORTED_CLI_VERSION"

mv "$TMP_BIN" "$INSTALL_PATH"
chmod +x "$INSTALL_PATH"

if ! "$INSTALL_PATH" --help >/dev/null 2>&1; then
  fail "installed binary did not run successfully: $INSTALL_PATH --help"
fi
success "Binary smoke check passed."

case ":$PATH:" in
  *":$INSTALL_DIR:"*) ;;
  *)
    warn "$INSTALL_DIR is not on PATH. Add it to your shell profile to run 'contexa' from any directory."
    printf "  export PATH=\"%s:\$PATH\"\n" "$INSTALL_DIR"
    ;;
esac

printf "\n"
success "Contexa $VERSION installed!"
printf "\n  Get started:\n"
printf "    cd your-spring-project\n"
printf "    contexa init\n"
printf "    contexa reset\n"
printf "    contexa init --simulate\n"
printf "    contexa reset --simulate\n\n"
