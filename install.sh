#!/bin/sh
# pipefail makes a pipeline fail when any stage fails (not just the last one),
# so a failed curl or grep upstream of `sed` is no longer silently swallowed.
set -e
(set -o pipefail) 2>/dev/null && set -o pipefail || true

REPO="contexa-security/contexa-cli"
INSTALL_DIR="/usr/local/bin"
BIN="contexa"

CYAN='\033[0;36m'; GREEN='\033[0;32m'; RED='\033[0;31m'
YELLOW='\033[1;33m'; DIM='\033[2m'; BOLD='\033[1m'; NC='\033[0m'

# Box drawing characters
H='─'; V='│'; TL='╭'; TR='╮'; BL='╰'; BR='╯'

# Banner. Linux/macOS terminals default to UTF-8 so the box-drawing glyphs
# below render cleanly out of the box. The Windows installer (install.ps1)
# uses the same shape but additionally pins the console output encoding
# because PowerShell 5.x on Korean Windows defaults to cp949.
printf "\n"
printf "${CYAN}${BOLD}"
printf "  ░█████╗░░█████╗░███╗░░██╗████████╗███████╗██╗░░██╗░█████╗░\n"
printf "  ██╔══██╗██╔══██╗████╗░██║╚══██╔══╝██╔════╝╚██╗██╔╝██╔══██╗\n"
printf "  ██║░░╚═╝██║░░██║██╔██╗██║░░░██║░░░█████╗░░░╚███╔╝░███████║\n"
printf "  ██║░░██╗██║░░██║██║╚████║░░░██║░░░██╔══╝░░░██╔██╗░██╔══██║\n"
printf "  ╚█████╔╝╚█████╔╝██║░╚███║░░░██║░░░███████╗██╔╝░██╗██║░░██║\n"
printf "  ░╚════╝░░╚════╝░╚═╝░░╚══╝░░░╚═╝░░░╚══════╝╚═╝░░╚═╝╚═╝░░╚═╝\n"
printf "${NC}"
printf "  ${BOLD}AI-Native Zero Trust Security Platform${NC}  ${YELLOW}https://ctxa.ai${NC}\n"
printf "\n"

# Pre-flight check for installer
printf "  ${DIM}Running pre-flight environment checks...${NC}\n"
CHECK_PASS=true

# Check Java 17+
if command -v java >/dev/null 2>&1; then
  JAVA_VER=$(java -version 2>&1 | awk -F '"' '/version/ {print $2}' | cut -d. -f1)
  if [ -z "$JAVA_VER" ]; then
    JAVA_VER=$(java -version 2>&1 | awk '/version/ {print $3}' | tr -d '"' | cut -d. -f1)
  fi
  if [ "${JAVA_VER}" = "1" ]; then
    JAVA_VER=$(java -version 2>&1 | awk -F '"' '/version/ {print $2}' | cut -d. -f2)
  fi

  if [ -z "$JAVA_VER" ] || [ "$JAVA_VER" -lt 17 ] 2>/dev/null; then
    printf "  ${YELLOW}! Java 17+ was not detected (detected: %s)${NC}\n" "${JAVA_VER:-unknown}"
    CHECK_PASS=false
  fi
else
  printf "  ${YELLOW}! Java is not installed on this machine.${NC}\n"
  CHECK_PASS=false
fi

# Check Docker
if command -v docker >/dev/null 2>&1; then
  if ! docker info >/dev/null 2>&1; then
    printf "  ${YELLOW}! Docker daemon is not running.${NC}\n"
    CHECK_PASS=false
  fi
else
  printf "  ${YELLOW}! Docker CLI is not installed.${NC}\n"
  CHECK_PASS=false
fi

if [ "$CHECK_PASS" = false ]; then
  printf "\n  ${BOLD}Some dependencies are missing.${NC} However, you can still install Contexa CLI\n"
  printf "  to configure your Spring project using Standalone/Skip mode.\n"
  printf "  ${CYAN}Would you like to proceed with the CLI installation anyway? (y/n): ${NC}"
  if [ -t 0 ]; then
    read -r CONTINUE_INSTALL < /dev/tty
  else
    printf "\n  ${DIM}Non-interactive shell detected. Proceeding with installation automatically...${NC}\n"
    CONTINUE_INSTALL="y"
  fi

  if [ "$CONTINUE_INSTALL" != "y" ] && [ "$CONTINUE_INSTALL" != "Y" ]; then
    printf "\n  ${RED}Installation aborted by user.${NC}\n"
    printf "  - To install JDK 17:  https://adoptium.net\n"
    printf "  - To install Docker:  https://docs.docker.com/engine/install/\n\n"
    exit 0
  fi
else
  printf "  ${GREEN}Pre-flight environment checks passed.${NC}\n\n"
fi

# Fetch latest version
VERSION=$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" \
  | grep '"tag_name"' | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/')

if [ -z "$VERSION" ]; then
  printf "  ${RED}Error: Could not fetch latest version${NC}\n"
  exit 1
fi

# Detect OS / ARCH
OS=$(uname -s); ARCH=$(uname -m)

case "$OS" in
  Linux*)
    case "$ARCH" in
      x86_64)  FILE="contexa-linux-x64"; PLATFORM="Linux x64" ;;
      aarch64) FILE="contexa-linux-arm64"; PLATFORM="Linux ARM64" ;;
      *) printf "  ${RED}Unsupported: $ARCH${NC}\n"; exit 1 ;;
    esac ;;
  Darwin*)
    case "$ARCH" in
      x86_64)
        # No prebuilt Intel Mac binary is published yet. Refuse early instead of
        # attempting a download that returns 404 (release matrix ships ARM64 only).
        printf "  ${RED}Intel Mac is not yet supported as a prebuilt binary.${NC}\n"
        printf "  ${YELLOW}Build from source instead:${NC}\n"
        printf "    git clone https://github.com/${REPO}\n"
        printf "    cd contexa-cli && npm install && node src/index.js init\n"
        exit 1 ;;
      arm64)  FILE="contexa-macos-arm64"; PLATFORM="macOS ARM64 (Apple Silicon)" ;;
      *) printf "  ${RED}Unsupported: $ARCH${NC}\n"; exit 1 ;;
    esac ;;
  MINGW*|MSYS*|CYGWIN*)
    FILE="contexa-win-x64.exe"; BIN="contexa.exe"
    INSTALL_DIR="$HOME/.local/bin"; PLATFORM="Windows x64" ;;
  *) printf "  ${RED}Unsupported OS: $OS${NC}\n"; exit 1 ;;
esac

URL="https://github.com/${REPO}/releases/download/${VERSION}/${FILE}"
SHA_URL="${URL}.sha256"

# Info box
printf "  ${TL}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${TR}\n"
printf "  ${V}  Version  : ${YELLOW}%-39s${NC}${V}\n" "${VERSION}"
printf "  ${V}  Platform : %-39s${V}\n" "${PLATFORM}"
printf "  ${V}  Target   : ${DIM}%-39s${NC}${V}\n" "${INSTALL_DIR}/${BIN}"
printf "  ${BL}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${BR}\n"
printf "\n"

mkdir -p "$INSTALL_DIR"

# Download to a temporary path; verify SHA-256 before promoting it.
TMP_BIN=$(mktemp 2>/dev/null || mktemp -t contexa)
trap 'rm -f "$TMP_BIN" "$TMP_BIN.sha256"' EXIT

# Convert raw bytes into a human-readable size string. Operators want to know
# whether they are about to wait on a 1 MB or a 100 MB download; the previous
# "Downloading ..." dot animation hid that completely.
fmt_bytes() {
  local b=$1
  if [ -z "$b" ] || [ "$b" -le 0 ] 2>/dev/null; then echo ""; return; fi
  if   [ "$b" -lt 1024 ];       then echo "$b B"
  elif [ "$b" -lt 1048576 ];    then awk "BEGIN { printf \"%.1f KB\", $b/1024 }"
  elif [ "$b" -lt 1073741824 ]; then awk "BEGIN { printf \"%.1f MB\", $b/1048576 }"
  else                               awk "BEGIN { printf \"%.2f GB\", $b/1073741824 }"
  fi
}

# Resolve expected size with a HEAD request so we can show "Downloading 83.6 MB..."
# up front. Failures here are non-fatal - we just fall back to a size-less line.
EXPECTED_SIZE=$(curl -fsSLI "$URL" 2>/dev/null \
  | awk 'BEGIN{IGNORECASE=1} /^content-length:/ { gsub("\r","",$2); print $2; exit }')
EXPECTED_HUMAN=$(fmt_bytes "$EXPECTED_SIZE")

if [ -n "$EXPECTED_HUMAN" ]; then
  printf "  ${DIM}Downloading %s...${NC}\n" "$EXPECTED_HUMAN"
else
  printf "  ${DIM}Downloading...${NC}\n"
fi

curl -fsSL "$URL" -o "$TMP_BIN"

ACTUAL_SIZE=$(wc -c <"$TMP_BIN" 2>/dev/null | tr -d ' ')
ACTUAL_HUMAN=$(fmt_bytes "$ACTUAL_SIZE")
if [ -n "$ACTUAL_HUMAN" ]; then
  printf "  ${GREEN}Downloaded %s.${NC}\n" "$ACTUAL_HUMAN"
else
  printf "  ${GREEN}Downloaded successfully.${NC}\n"
fi

# Verify SHA-256 checksum. Releases must publish a "<file>.sha256" sibling
# containing the hex digest (optionally followed by the filename).
# Failure aborts installation; binary is never marked executable or moved.
printf "  ${DIM}Verifying checksum...${NC}\n"
if ! curl -fsSL "$SHA_URL" -o "$TMP_BIN.sha256"; then
  printf "  ${RED}Error: checksum file not found at $SHA_URL${NC}\n"
  printf "  ${RED}Refusing to install an unverified binary.${NC}\n"
  exit 1
fi

EXPECTED_SHA=$(awk '{print $1}' "$TMP_BIN.sha256")
if [ -z "$EXPECTED_SHA" ]; then
  printf "  ${RED}Error: empty checksum file.${NC}\n"
  exit 1
fi

if command -v sha256sum >/dev/null 2>&1; then
  ACTUAL_SHA=$(sha256sum "$TMP_BIN" | awk '{print $1}')
elif command -v shasum >/dev/null 2>&1; then
  ACTUAL_SHA=$(shasum -a 256 "$TMP_BIN" | awk '{print $1}')
else
  printf "  ${RED}Error: neither sha256sum nor shasum found - cannot verify download.${NC}\n"
  exit 1
fi

if [ "$EXPECTED_SHA" != "$ACTUAL_SHA" ]; then
  printf "  ${RED}Error: checksum mismatch.${NC}\n"
  printf "  ${RED}  expected: $EXPECTED_SHA${NC}\n"
  printf "  ${RED}  actual  : $ACTUAL_SHA${NC}\n"
  printf "  ${RED}Refusing to install a tampered binary.${NC}\n"
  exit 1
fi

printf "  ${GREEN}Checksum verified.${NC}\n\n"

# Promote the verified binary to its final location.
mv "$TMP_BIN" "${INSTALL_DIR}/${BIN}"
chmod +x "${INSTALL_DIR}/${BIN}"

# Success box
printf "  ${TL}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${TR}\n"
printf "  ${V}  ${GREEN}${BOLD}Contexa ${VERSION} installed!${NC}                        ${V}\n"
printf "  ${V}                                                  ${V}\n"
printf "  ${V}  Get started:                                    ${V}\n"
printf "  ${V}    ${CYAN}cd${NC} your-spring-project                       ${V}\n"
printf "  ${V}    ${CYAN}contexa init${NC}                                 ${V}\n"
printf "  ${BL}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${BR}\n"
printf "\n"