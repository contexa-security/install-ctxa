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
      x86_64) FILE="contexa-macos-x64"; PLATFORM="macOS x64" ;;
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

# Download with cycling dot animation
curl -fsSL "$URL" -o "$TMP_BIN" &
CURL_PID=$!
while kill -0 $CURL_PID 2>/dev/null; do
  printf "\r  ${DIM}Downloading .  ${NC}" ; sleep 0.3
  kill -0 $CURL_PID 2>/dev/null || break
  printf "\r  ${DIM}Downloading .. ${NC}" ; sleep 0.3
  kill -0 $CURL_PID 2>/dev/null || break
  printf "\r  ${DIM}Downloading ...${NC}" ; sleep 0.3
done
wait $CURL_PID

printf "\r  ${GREEN}Downloaded successfully.${NC}            \n"

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
