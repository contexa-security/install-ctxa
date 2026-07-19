#!/bin/sh
set -eu

REPO="contexa-security/contexa-cli"
DEFAULT_RELEASE_API="https://api.github.com/repos/$REPO/releases/latest"
DEFAULT_DOWNLOAD_BASE="https://github.com/$REPO/releases/download"

case "${CONTEXA_LANG:-${LANG:-en}}" in
  ko|ko[_-]*) INSTALL_LANG=ko ;;
  *) INSTALL_LANG=en ;;
esac

msg() {
  key=$1
  if [ "$INSTALL_LANG" = ko ]; then
    case "$key" in
      fail_prefix) printf '%s' 'Contexa 설치 프로그램 실패' ;;
      preserved) printf '%s' '가능한 경우 기존 CLI를 보존했습니다. 보고된 원인을 해결한 뒤 같은 명령을 다시 실행하세요.' ;;
      rolled_back) printf '%s' 'Contexa CLI를 다음 버전으로 롤백했습니다: ' ;;
      uninstalled) printf '%s' 'Contexa CLI 바이너리와 설치 프로그램 소유 PATH 항목을 제거했습니다. 프로젝트 파일은 변경하지 않았습니다.' ;;
      already_installed) printf '%s' ' 버전이 이미 설치되어 있어 파일을 교체하지 않았습니다.' ;;
      installed) printf '%s' ' 설치와 검증을 완료했습니다: ' ;;
      primary) printf '%s' '주요 명령:' ;;
      immutable) printf '%s' '동일 버전 재설치: CONTEXA_VERSION=' ;;
      rollback) printf '%s' '롤백: CONTEXA_INSTALL_ACTION=rollback' ;;
      uninstall) printf '%s' '제거: CONTEXA_INSTALL_ACTION=uninstall (프로젝트 reset은 별도)' ;;
      unsupported_action) printf '%s' '지원하지 않는 CONTEXA_INSTALL_ACTION' ;;
    esac
  else
    case "$key" in
      fail_prefix) printf '%s' 'Contexa installer failed' ;;
      preserved) printf '%s' 'The existing CLI was preserved when possible. Fix the reported cause and run the same command again.' ;;
      rolled_back) printf '%s' 'Contexa CLI rolled back to ' ;;
      uninstalled) printf '%s' 'Contexa CLI binary and installer-owned PATH entry were removed. Project files were not changed.' ;;
      already_installed) printf '%s' ' is already installed; no file was replaced.' ;;
      installed) printf '%s' ' installed and verified for ' ;;
      primary) printf '%s' 'Primary commands:' ;;
      immutable) printf '%s' 'Immutable reinstall: CONTEXA_VERSION=' ;;
      rollback) printf '%s' 'Rollback: CONTEXA_INSTALL_ACTION=rollback' ;;
      uninstall) printf '%s' 'Uninstall: CONTEXA_INSTALL_ACTION=uninstall (project reset is separate)' ;;
      unsupported_action) printf '%s' 'Unsupported CONTEXA_INSTALL_ACTION' ;;
    esac
  fi
}

fail() {
  printf '%s\n' "$(msg fail_prefix): $1" >&2
  printf '%s\n' "$(msg preserved)" >&2
  exit 1
}

positive_int() {
  name=$1
  value=$2
  maximum=$3
  case "$value" in ''|*[!0-9]*) fail "$name must be an integer from 1 to $maximum." ;; esac
  [ "$value" -ge 1 ] && [ "$value" -le "$maximum" ] || fail "$name must be an integer from 1 to $maximum."
  printf '%s' "$value"
}

CONNECT_TIMEOUT=$(positive_int CONTEXA_HTTP_CONNECT_TIMEOUT_SEC "${CONTEXA_HTTP_CONNECT_TIMEOUT_SEC:-5}" 60)
TOTAL_TIMEOUT=$(positive_int CONTEXA_HTTP_TOTAL_TIMEOUT_SEC "${CONTEXA_HTTP_TOTAL_TIMEOUT_SEC:-30}" 300)
RETRIES=$(positive_int CONTEXA_HTTP_RETRIES "${CONTEXA_HTTP_RETRIES:-2}" 5)

require_tool() {
  command -v "$1" >/dev/null 2>&1 || fail "$1 is required. Install it and retry."
}

download() {
  curl -fsSL --connect-timeout "$CONNECT_TIMEOUT" --max-time "$TOTAL_TIMEOUT" \
    --retry "$RETRIES" --retry-max-time "$TOTAL_TIMEOUT" --retry-delay 1 \
    --retry-connrefused "$1" -o "$2"
}

resolve_install_dir() {
  if [ -n "${CONTEXA_INSTALL_DIR:-}" ]; then
    printf '%s' "$CONTEXA_INSTALL_DIR"
  elif [ -d /usr/local/bin ] && [ -w /usr/local/bin ]; then
    printf '%s' /usr/local/bin
  else
    [ -n "${HOME:-}" ] || fail "HOME is empty. Set CONTEXA_INSTALL_DIR and retry."
    printf '%s' "$HOME/.local/bin"
  fi
}

version_ge() {
  awk -v actual="$1" -v minimum="$2" 'BEGIN {
    split(actual, a, "."); split(minimum, m, ".");
    for (i = 1; i <= 3; i++) {
      av = a[i] + 0; mv = m[i] + 0;
      if (av > mv) exit 0;
      if (av < mv) exit 1;
    }
    exit 0;
  }'
}

detect_platform() {
  OS=$(uname -s)
  ARCH=$(uname -m)
  case "$OS:$ARCH" in
    Linux:x86_64)
      FILE=contexa-linux-x64
      PLATFORM="Linux x64"
      EXPECTED_CODE_SIGNATURE=unsigned-snapshot
      ldd --version 2>&1 | grep -qi musl && fail "Linux musl is not supported. The existing CLI was not changed."
      require_tool getconf
      GLIBC_VERSION=$(getconf GNU_LIBC_VERSION 2>/dev/null | awk '{print $2}')
      [ -n "$GLIBC_VERSION" ] || fail "Could not determine glibc version."
      version_ge "$GLIBC_VERSION" 2.28 || fail "glibc 2.28 or newer is required; found $GLIBC_VERSION."
      ;;
    Darwin:arm64)
      FILE=contexa-macos-arm64
      PLATFORM="macOS ARM64"
      EXPECTED_CODE_SIGNATURE=adhoc-snapshot
      MACOS_VERSION=$(sw_vers -productVersion)
      version_ge "$MACOS_VERSION" 11 || fail "macOS 11 or newer is required; found $MACOS_VERSION."
      ;;
    Linux:aarch64|Linux:arm64)
      fail "Linux ARM64 is not supported and no asset is published. The existing CLI was not changed."
      ;;
    Darwin:x86_64)
      fail "Intel Mac is not supported and no asset is published. The existing CLI was not changed."
      ;;
    MINGW*:*|MSYS*:*|CYGWIN*:*)
      fail "Use install.ps1 on Windows."
      ;;
    *) fail "Unsupported platform: $OS $ARCH. The existing CLI was not changed." ;;
  esac
}

write_public_key() {
  if [ -n "${CONTEXA_TRUSTED_PUBLIC_KEY_PATH:-}" ]; then
    case "$DOWNLOAD_BASE" in
      http://127.0.0.1:*|http://localhost:*|http://\[::1\]:*) ;;
      *) fail "A test public key override is allowed only with a loopback release server." ;;
    esac
    [ -f "$CONTEXA_TRUSTED_PUBLIC_KEY_PATH" ] || fail "The configured test public key does not exist."
    cp "$CONTEXA_TRUSTED_PUBLIC_KEY_PATH" "$1"
    return
  fi
  cat >"$1" <<'KEY'
-----BEGIN PUBLIC KEY-----
MIIBojANBgkqhkiG9w0BAQEFAAOCAY8AMIIBigKCAYEAosHQvVy9S+AGAvskLk13
njD9SoRHMURAbU2RQWZgQt2t0vN3Ib7aVMIwStGdJhaDIuPHTg0WrwM6ogPDDqfF
mHHm8XkviBHnkgFQWvovLHtRudSgU6g+5ReaT0G0HsWFC3aGVJhOEwo5EqJJxZgj
Ic533CJTyn6ZbV8C0PGPP3kZQb1C/zPCaVtQg02v3Vm1C+sivBfCFRRJlcXhfc5h
vbtB40DcRFkJfkBbdHBwdAnRfuH8OnIeL9dWEFyNgR7ZIREnjqNahtZbUM9gBS1p
1Zw3ffTls2QSyMvQobqwNOdfP2/LN0K8uiJJ8K7nh524wGANdTlmKY2cAAkUbZsO
2FK7sLCcVDXShQptXFj31DEzdQCb9hAnarXK5C6qBFxloDGzV8b+xlALFQBIO8xw
XlxR8jZq+CiVJmWHUr78A0fubstaBUSgpU1ZzdUl0plI6MczU/udM7miH/O1ih7t
0ox745ahU/7eXEYOLNRAJs2gidol7m+apyY/qV7DIMhzAgMBAAE=
-----END PUBLIC KEY-----
KEY
}

manifest_asset_hash() {
  awk -v file="$FILE" '
    index($0, "\"file\": \"" file "\"") { in_asset = 1 }
    in_asset && match($0, /"sha256": "[0-9a-fA-F]+"/) {
      value = substr($0, RSTART, RLENGTH)
      sub(/^"sha256": "/, "", value); sub(/"$/, "", value)
      print tolower(value); exit
    }
  ' "$MANIFEST_FILE"
}

manifest_asset_code_signature() {
  awk -v file="$FILE" '
    index($0, "\"file\": \"" file "\"") { in_asset = 1 }
    in_asset && match($0, /"codeSignature": "[^"]+"/) {
      value = substr($0, RSTART, RLENGTH)
      sub(/^"codeSignature": "/, "", value); sub(/"$/, "", value)
      print value; exit
    }
  ' "$MANIFEST_FILE"
}

reported_version() {
  "$1" --version 2>/dev/null | awk 'NR == 1 { print; exit }'
}

smoke_binary() {
  [ "$(reported_version "$1")" = "$2" ] || return 1
  "$1" --help >/dev/null 2>&1 || return 1
  "$1" >/dev/null 2>&1 || return 1
}

profile_path() {
  if [ -n "${CONTEXA_SHELL_PROFILE:-}" ]; then printf '%s' "$CONTEXA_SHELL_PROFILE"; else printf '%s' "$HOME/.profile"; fi
}

ensure_path() {
  case ":$PATH:" in *":$INSTALL_DIR:"*) ;; *) PATH="$INSTALL_DIR:$PATH"; export PATH ;; esac
  hash -r 2>/dev/null || true
  resolved=$(command -v contexa 2>/dev/null || true)
  [ "$resolved" = "$INSTALL_PATH" ] || fail "PATH conflict: first contexa command is ${resolved:-missing}, expected $INSTALL_PATH."
  if [ "${CONTEXA_SKIP_PATH_UPDATE:-0}" != 1 ]; then
    PROFILE=$(profile_path)
    if ! grep -Fq '# >>> contexa-cli installer >>>' "$PROFILE" 2>/dev/null; then
      {
        printf '\n%s\n' '# >>> contexa-cli installer >>>'
        printf 'export PATH="%s:$PATH"\n' "$INSTALL_DIR"
        printf '%s\n' '# <<< contexa-cli installer <<<'
      } >>"$PROFILE"
    fi
  fi
  if command -v which >/dev/null 2>&1; then
    which -a contexa 2>/dev/null | awk -v final="$INSTALL_PATH" '$0 != final { print "Warning: another contexa command remains and was not deleted: " $0 > "/dev/stderr" }'
  fi
}

remove_profile_block() {
  [ "${CONTEXA_SKIP_PATH_UPDATE:-0}" = 1 ] && return 0
  PROFILE=$(profile_path)
  [ -f "$PROFILE" ] || return 0
  temporary="$PROFILE.contexa-remove.$$"
  awk '
    $0 == "# >>> contexa-cli installer >>>" { skip = 1; next }
    $0 == "# <<< contexa-cli installer <<<" { skip = 0; next }
    !skip { print }
  ' "$PROFILE" >"$temporary"
  mv "$temporary" "$PROFILE"
}

INSTALL_DIR=$(resolve_install_dir)
INSTALL_PATH="$INSTALL_DIR/contexa"
BACKUP_PATH="$INSTALL_PATH.previous"
ACTION="${CONTEXA_INSTALL_ACTION:-install}"

case "$ACTION" in
  rollback)
    [ -f "$BACKUP_PATH" ] || fail "No previous Contexa binary exists at $BACKUP_PATH."
    rollback_temp="$INSTALL_PATH.rollback.$$"
    [ -f "$INSTALL_PATH" ] && mv "$INSTALL_PATH" "$rollback_temp"
    if mv "$BACKUP_PATH" "$INSTALL_PATH" && "$INSTALL_PATH" --help >/dev/null 2>&1; then
      [ -f "$rollback_temp" ] && mv "$rollback_temp" "$BACKUP_PATH"
      chmod 755 "$INSTALL_PATH"; ensure_path
      printf '%s\n' "$(msg rolled_back)$(reported_version "$INSTALL_PATH")."
      exit 0
    fi
    [ -f "$INSTALL_PATH" ] && rm -f "$INSTALL_PATH"
    [ -f "$rollback_temp" ] && mv "$rollback_temp" "$INSTALL_PATH"
    fail "Rollback smoke verification failed; the pre-rollback binary was restored."
    ;;
  uninstall)
    rm -f "$INSTALL_PATH" "$BACKUP_PATH"
    remove_profile_block
    printf '%s\n' "$(msg uninstalled)"
    exit 0
    ;;
  install) ;;
  *) fail "$(msg unsupported_action): $ACTION" ;;
esac

require_tool curl
require_tool awk
require_tool openssl
detect_platform
mkdir -p "$INSTALL_DIR" || fail "Could not create install directory: $INSTALL_DIR."
[ -w "$INSTALL_DIR" ] || fail "Install directory is not writable: $INSTALL_DIR."

STATE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/contexa-installer.XXXXXX")
MANIFEST_FILE="$STATE_DIR/release-manifest.json"
SIGNATURE_TEXT="$STATE_DIR/release-manifest.json.sig"
SIGNATURE_BINARY="$STATE_DIR/release-manifest.sig.bin"
PUBLIC_KEY="$STATE_DIR/release-signing-public.pem"
SIDECAR_FILE="$STATE_DIR/asset.sha256"
METADATA_FILE="$STATE_DIR/release.json"
NEW_BINARY=$(mktemp "$INSTALL_DIR/.contexa.new.XXXXXX")
cleanup() { rm -rf "$STATE_DIR"; rm -f "$NEW_BINARY"; }
trap cleanup EXIT HUP INT TERM

if [ -n "${CONTEXA_VERSION:-}" ]; then
  VERSION=$CONTEXA_VERSION
else
  RELEASE_API="${CONTEXA_RELEASE_API_URL:-$DEFAULT_RELEASE_API}"
  download "$RELEASE_API" "$METADATA_FILE" || fail "Could not fetch release metadata within the configured timeout."
  VERSION=$(awk -F '"' '/"tag_name"/ { print $4; exit }' "$METADATA_FILE")
fi
case "$VERSION" in v[0-9A-Za-z][0-9A-Za-z._-]*) ;; *) fail "Invalid or empty release tag: $VERSION" ;; esac
EXPECTED_VERSION=${VERSION#v}
DOWNLOAD_BASE="${CONTEXA_RELEASE_DOWNLOAD_BASE:-$DEFAULT_DOWNLOAD_BASE}"
RELEASE_BASE="${DOWNLOAD_BASE%/}/$VERSION"

download "$RELEASE_BASE/release-manifest.json" "$MANIFEST_FILE" || fail "Could not download release-manifest.json."
download "$RELEASE_BASE/release-manifest.json.sig" "$SIGNATURE_TEXT" || fail "Could not download release manifest signature."
write_public_key "$PUBLIC_KEY"
openssl base64 -d -A -in "$SIGNATURE_TEXT" -out "$SIGNATURE_BINARY" >/dev/null 2>&1 || fail "Release manifest signature is not valid base64."
openssl dgst -sha256 -verify "$PUBLIC_KEY" -signature "$SIGNATURE_BINARY" "$MANIFEST_FILE" >/dev/null 2>&1 || fail "Release manifest signature verification failed. The existing CLI was not changed."

grep -Fq "\"releaseTag\": \"$VERSION\"" "$MANIFEST_FILE" || fail "Signed manifest release tag mismatch."
grep -Fq "\"cliVersion\": \"$EXPECTED_VERSION\"" "$MANIFEST_FILE" || fail "Signed manifest CLI version mismatch."
grep -Fq '"required": true' "$MANIFEST_FILE" || fail "Signed manifest trust contract is missing."
grep -Fq '"algorithm": "RSA-3072-SHA256"' "$MANIFEST_FILE" || fail "Signed manifest trust algorithm is unsupported."
grep -Fq "\"file\": \"$FILE\"" "$MANIFEST_FILE" || fail "Signed manifest does not register $PLATFORM."
MANIFEST_SHA=$(manifest_asset_hash)
[ -n "$MANIFEST_SHA" ] || fail "Signed manifest does not bind a digest for $FILE."
MANIFEST_CODE_SIGNATURE=$(manifest_asset_code_signature)
[ "$MANIFEST_CODE_SIGNATURE" = "$EXPECTED_CODE_SIGNATURE" ] || fail "Unsupported code-signature contract for $PLATFORM: ${MANIFEST_CODE_SIGNATURE:-missing}."

if [ -f "$INSTALL_PATH" ] && [ "$(reported_version "$INSTALL_PATH")" = "$EXPECTED_VERSION" ]; then
  smoke_binary "$INSTALL_PATH" "$EXPECTED_VERSION" || fail "The installed same-version binary failed smoke verification."
  ensure_path
  printf '%s\n' "Contexa $VERSION$(msg already_installed)"
  exit 0
fi

download "$RELEASE_BASE/$FILE" "$NEW_BINARY" || fail "Binary download failed within the configured timeout."
download "$RELEASE_BASE/$FILE.sha256" "$SIDECAR_FILE" || fail "Checksum download failed."
SIDECAR_SHA=$(awk '{ print tolower($1); exit }' "$SIDECAR_FILE")
if command -v sha256sum >/dev/null 2>&1; then
  ACTUAL_SHA=$(sha256sum "$NEW_BINARY" | awk '{ print tolower($1) }')
elif command -v shasum >/dev/null 2>&1; then
  ACTUAL_SHA=$(shasum -a 256 "$NEW_BINARY" | awk '{ print tolower($1) }')
else
  fail "Neither sha256sum nor shasum is available."
fi
[ "$SIDECAR_SHA" = "$MANIFEST_SHA" ] && [ "$ACTUAL_SHA" = "$MANIFEST_SHA" ] || fail "Binary digest does not match the signed release manifest."

chmod 755 "$NEW_BINARY"
smoke_binary "$NEW_BINARY" "$EXPECTED_VERSION" || fail "Downloaded binary version, help, or first-run verification failed."
if [ "$OS" = Darwin ]; then
  codesign --verify "$NEW_BINARY" >/dev/null 2>&1 || fail "macOS code-signature contract verification failed."
fi

OLD_MOVED=0
rm -f "$BACKUP_PATH"
if [ -f "$INSTALL_PATH" ]; then mv "$INSTALL_PATH" "$BACKUP_PATH"; OLD_MOVED=1; fi
if ! mv "$NEW_BINARY" "$INSTALL_PATH"; then
  [ "$OLD_MOVED" = 1 ] && mv "$BACKUP_PATH" "$INSTALL_PATH"
  fail "Atomic binary replacement failed; the previous CLI was restored."
fi
chmod 755 "$INSTALL_PATH"
if ! smoke_binary "$INSTALL_PATH" "$EXPECTED_VERSION"; then
  rm -f "$INSTALL_PATH"
  [ "$OLD_MOVED" = 1 ] && mv "$BACKUP_PATH" "$INSTALL_PATH"
  fail "Final smoke verification failed; the previous CLI was restored."
fi

ensure_path
printf '%s\n' "Contexa $VERSION$(msg installed)$PLATFORM."
printf '%s\n' "$(msg primary)" "  contexa init" "  contexa reset" "  contexa init --simulate" "  contexa reset --simulate"
printf '%s\n' "$(msg immutable)$VERSION"
printf '%s\n' "$(msg rollback)"
printf '%s\n' "$(msg uninstall)"
