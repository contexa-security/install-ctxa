#!/bin/sh
set -eu

REPO="contexa-security/contexa-cli"
DEFAULT_CHANNEL_MANIFEST_URL="https://raw.githubusercontent.com/$REPO/snapshot-channel/channel-manifest.json"
DEFAULT_CHANNEL_SIGNATURE_URL="https://raw.githubusercontent.com/$REPO/snapshot-channel/channel-manifest.json.sig"
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
  download_url=$1
  download_target=$2
  download_started=$(date +%s)
  download_attempt=1
  while :; do
    download_now=$(date +%s)
    download_remaining=$((TOTAL_TIMEOUT - download_now + download_started))
    if [ "$download_remaining" -le 0 ]; then
      printf '%s\n' "HTTP download failed [TIMEOUT] after $download_attempt attempt(s) within $TOTAL_TIMEOUT second(s): $download_url. Retry the same installer." >&2
      return 1
    fi
    download_status=0
    download_http=$(curl -sS -L --connect-timeout "$CONNECT_TIMEOUT" --max-time "$download_remaining" -o "$download_target" -w '%{http_code}' "$download_url") || download_status=$?
    case "$download_http" in 2??)
      [ "$download_status" -eq 0 ] && return 0
      ;;
    esac
    download_retryable=0
    case "$download_http" in
      429) download_reason=HTTP_429_RATE_LIMIT; download_retryable=1 ;;
      408) download_reason=HTTP_408_TIMEOUT; download_retryable=1 ;;
      5??) download_reason=HTTP_5XX; download_retryable=1 ;;
      4??) download_reason="HTTP_$download_http" ;;
      *)
        case "$download_status" in
          28) download_reason=TIMEOUT; download_retryable=1 ;;
          7|18|52|55|56) download_reason=CONNECTION_RESET; download_retryable=1 ;;
          *) download_reason="CURL_$download_status" ;;
        esac
        ;;
    esac
    rm -f "$download_target"
    if [ "$download_retryable" -ne 1 ] || [ "$download_attempt" -gt "$RETRIES" ]; then
      case "$download_reason" in
        HTTP_429_RATE_LIMIT) download_guidance='Retry the same installer after the server retry window.' ;;
        TIMEOUT|CONNECTION_RESET|HTTP_408_TIMEOUT|HTTP_5XX) download_guidance='The endpoint was temporarily unavailable. Retry the same installer.' ;;
        *) download_guidance='Check the URL and trust configuration before retrying the same installer.' ;;
      esac
      printf '%s\n' "HTTP download failed [$download_reason] after $download_attempt attempt(s) within $TOTAL_TIMEOUT second(s): $download_url. $download_guidance" >&2
      return 1
    fi
    download_attempt=$((download_attempt + 1))
    sleep 1
  done
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

manifest_string_value() {
  awk -v key="\"$2\"" '
    index($0, key) {
      value = $0
      sub(".*" key "[[:space:]]*:[[:space:]]*\"", "", value)
      sub("\".*$", "", value)
      print value
      exit
    }
  ' "$1"
}

manifest_starter_version() {
  awk '
    index($0, "\"starter\"") { in_starter = 1 }
    in_starter && match($0, /"version": "[^"]+"/) {
      value = substr($0, RSTART, RLENGTH)
      sub(/^"version": "/, "", value); sub(/"$/, "", value)
      print value; exit
    }
  ' "$1"
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{ print tolower($1) }'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{ print tolower($1) }'
  else
    fail "Neither sha256sum nor shasum is available."
  fi
}

reported_version() {
  "$1" --version 2>/dev/null | awk 'NR == 1 { print; exit }'
}

smoke_binary() {
  [ "$(reported_version "$1")" = "$2" ] || return 1
  "$1" --help >/dev/null 2>&1 || return 1
  "$1" >/dev/null 2>&1 || return 1
}

smoke_any_binary() {
  [ -f "$1" ] || return 1
  candidate_version=$(reported_version "$1")
  [ -n "$candidate_version" ] || return 1
  "$1" --help >/dev/null 2>&1 || return 1
  "$1" >/dev/null 2>&1 || return 1
}

transaction_value() {
  transaction_key=$1
  while IFS= read -r transaction_line; do
    case "$transaction_line" in
      "$transaction_key="*) printf '%s' "${transaction_line#*=}"; return 0 ;;
    esac
  done <"$MARKER_PATH"
  return 1
}

clear_installer_transaction() {
  rm -f "$MARKER_PATH" "$MARKER_PATH.writing"
}

write_installer_transaction() {
  transaction_state=$1
  case "$transaction_state" in
    DOWNLOADED|VERIFIED|OLD_MOVED|NEW_MOVED|SMOKE_PASSED) ;;
    *) fail "Unsupported installer transaction state: $transaction_state" ;;
  esac
  case "$INSTALL_PATH$BACKUP_PATH$NEW_BINARY$EXPECTED_VERSION" in
    *'
'*) fail "Installer transaction values must not contain newlines." ;;
  esac
  {
    printf '%s\n' 'SCHEMA_VERSION=1'
    printf 'STATE=%s\n' "$transaction_state"
    printf 'FINAL_PATH=%s\n' "$INSTALL_PATH"
    printf 'BACKUP_PATH=%s\n' "$BACKUP_PATH"
    printf 'NEW_PATH=%s\n' "$NEW_BINARY"
    printf 'EXPECTED_VERSION=%s\n' "$EXPECTED_VERSION"
    printf 'HAD_ORIGINAL=%s\n' "$HAD_ORIGINAL"
  } >"$MARKER_PATH.writing"
  mv "$MARKER_PATH.writing" "$MARKER_PATH"
}

recover_installer_transaction() {
  [ -f "$MARKER_PATH" ] || { rm -f "$MARKER_PATH.writing"; return 0; }
  transaction_schema=$(transaction_value SCHEMA_VERSION || true)
  transaction_state=$(transaction_value STATE || true)
  transaction_final=$(transaction_value FINAL_PATH || true)
  transaction_backup=$(transaction_value BACKUP_PATH || true)
  transaction_new=$(transaction_value NEW_PATH || true)
  transaction_version=$(transaction_value EXPECTED_VERSION || true)
  transaction_new_dir=${transaction_new%/*}
  transaction_new_name=${transaction_new##*/}
  case "$transaction_state" in
    DOWNLOADED|VERIFIED|OLD_MOVED|NEW_MOVED|SMOKE_PASSED) ;;
    *) fail "Installer transaction marker has an unsupported state and was retained: $MARKER_PATH" ;;
  esac
  case "$transaction_new_name" in .contexa.new.*) ;; *) fail "Installer transaction marker has an invalid new-binary name and was retained: $MARKER_PATH" ;; esac
  [ "$transaction_schema" = 1 ] &&
    [ "$transaction_final" = "$INSTALL_PATH" ] &&
    [ "$transaction_backup" = "$BACKUP_PATH" ] &&
    [ "$transaction_new_dir" = "$INSTALL_DIR" ] &&
    [ -n "$transaction_version" ] ||
    fail "Installer transaction marker violates the exact path contract and was retained: $MARKER_PATH"

  if smoke_any_binary "$INSTALL_PATH"; then
    [ -f "$transaction_new" ] && rm -f "$transaction_new"
    clear_installer_transaction
    return 0
  fi

  case "$transaction_state" in
    VERIFIED|OLD_MOVED)
      if smoke_binary "$transaction_new" "$transaction_version"; then
        if [ -e "$INSTALL_PATH" ]; then mv "$INSTALL_PATH" "$INSTALL_PATH.failed.$$"; fi
        mv "$transaction_new" "$INSTALL_PATH"
        chmod 755 "$INSTALL_PATH"
        smoke_binary "$INSTALL_PATH" "$transaction_version" || fail "Recovered new binary failed smoke verification; transaction was retained."
        clear_installer_transaction
        return 0
      fi
      ;;
  esac

  if smoke_any_binary "$BACKUP_PATH"; then
    if [ -e "$INSTALL_PATH" ]; then mv "$INSTALL_PATH" "$INSTALL_PATH.failed.$$"; fi
    mv "$BACKUP_PATH" "$INSTALL_PATH"
    [ -f "$transaction_new" ] && rm -f "$transaction_new"
    clear_installer_transaction
    return 0
  fi
  fail "Installer recovery found no verified healthy old or new binary. The marker and files were retained: $MARKER_PATH"
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
mkdir -p "$INSTALL_DIR" || fail "Could not create install directory: $INSTALL_DIR."
INSTALL_DIR=$(cd "$INSTALL_DIR" && pwd -P)
INSTALL_PATH="$INSTALL_DIR/contexa"
BACKUP_PATH="$INSTALL_PATH.previous"
MARKER_PATH="$INSTALL_PATH.install-transaction"
ACTION="${CONTEXA_INSTALL_ACTION:-install}"

recover_installer_transaction
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
[ -w "$INSTALL_DIR" ] || fail "Install directory is not writable: $INSTALL_DIR."

STATE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/contexa-installer.XXXXXX")
MANIFEST_FILE="$STATE_DIR/release-manifest.json"
SIGNATURE_TEXT="$STATE_DIR/release-manifest.json.sig"
SIGNATURE_BINARY="$STATE_DIR/release-manifest.sig.bin"
CHANNEL_MANIFEST_FILE="$STATE_DIR/channel-manifest.json"
CHANNEL_SIGNATURE_TEXT="$STATE_DIR/channel-manifest.json.sig"
CHANNEL_SIGNATURE_BINARY="$STATE_DIR/channel-manifest.sig.bin"
PUBLIC_KEY="$STATE_DIR/release-signing-public.pem"
SIDECAR_FILE="$STATE_DIR/asset.sha256"
NEW_BINARY=$(mktemp "$INSTALL_DIR/.contexa.new.XXXXXX")
REPLACEMENT_STARTED=0
cleanup() {
  rm -rf "$STATE_DIR"
  if [ -f "$MARKER_PATH" ]; then
    if [ "$REPLACEMENT_STARTED" = 0 ] || smoke_any_binary "$INSTALL_PATH"; then
      clear_installer_transaction
    fi
  fi
  [ -f "$MARKER_PATH" ] || rm -f "$NEW_BINARY"
}
trap cleanup EXIT HUP INT TERM

DOWNLOAD_BASE="${CONTEXA_RELEASE_DOWNLOAD_BASE:-$DEFAULT_DOWNLOAD_BASE}"
write_public_key "$PUBLIC_KEY"
if [ -n "${CONTEXA_VERSION:-}" ]; then
  VERSION=$CONTEXA_VERSION
  RESOLVED_CHANNEL=
  CHANNEL_STARTER_VERSION=
  CHANNEL_RELEASE_MANIFEST_SHA=
else
  CHANNEL_MANIFEST_URL="${CONTEXA_CHANNEL_MANIFEST_URL:-$DEFAULT_CHANNEL_MANIFEST_URL}"
  CHANNEL_SIGNATURE_URL="${CONTEXA_CHANNEL_SIGNATURE_URL:-$DEFAULT_CHANNEL_SIGNATURE_URL}"
  download "$CHANNEL_MANIFEST_URL" "$CHANNEL_MANIFEST_FILE" || fail "Could not download the snapshot channel manifest."
  download "$CHANNEL_SIGNATURE_URL" "$CHANNEL_SIGNATURE_TEXT" || fail "Could not download the snapshot channel signature."
  openssl base64 -d -A -in "$CHANNEL_SIGNATURE_TEXT" -out "$CHANNEL_SIGNATURE_BINARY" >/dev/null 2>&1 || fail "Channel manifest signature is not valid base64."
  openssl dgst -sha256 -verify "$PUBLIC_KEY" -signature "$CHANNEL_SIGNATURE_BINARY" "$CHANNEL_MANIFEST_FILE" >/dev/null 2>&1 || fail "Channel manifest signature verification failed. The existing CLI was not changed."
  grep -Fq '"schemaVersion": 1' "$CHANNEL_MANIFEST_FILE" || fail "Signed channel manifest schema is unsupported."
  RESOLVED_CHANNEL=$(manifest_string_value "$CHANNEL_MANIFEST_FILE" channel)
  VERSION=$(manifest_string_value "$CHANNEL_MANIFEST_FILE" releaseTag)
  CHANNEL_CLI_VERSION=$(manifest_string_value "$CHANNEL_MANIFEST_FILE" cliVersion)
  CHANNEL_STARTER_VERSION=$(manifest_string_value "$CHANNEL_MANIFEST_FILE" starterVersion)
  CHANNEL_RELEASE_MANIFEST_SHA=$(manifest_string_value "$CHANNEL_MANIFEST_FILE" releaseManifestSha256)
  [ "$RESOLVED_CHANNEL" = snapshot ] || fail "Signed channel manifest is not the snapshot channel."
  [ "$CHANNEL_CLI_VERSION" = "${VERSION#v}" ] || fail "Signed channel manifest tag and CLI version do not match."
  case "$CHANNEL_STARTER_VERSION" in *-SNAPSHOT) ;; *) fail "Signed snapshot channel requires a SNAPSHOT starter version." ;; esac
  printf '%s\n' "$CHANNEL_RELEASE_MANIFEST_SHA" | grep -Eq '^[0-9a-f]{64}$' || fail "Signed channel manifest release digest is invalid."
fi
case "$VERSION" in v[0-9A-Za-z][0-9A-Za-z._-]*) ;; *) fail "Invalid or empty release tag: $VERSION" ;; esac
EXPECTED_VERSION=${VERSION#v}
RELEASE_BASE="${DOWNLOAD_BASE%/}/$VERSION"

download "$RELEASE_BASE/release-manifest.json" "$MANIFEST_FILE" || fail "Could not download release-manifest.json."
download "$RELEASE_BASE/release-manifest.json.sig" "$SIGNATURE_TEXT" || fail "Could not download release manifest signature."
openssl base64 -d -A -in "$SIGNATURE_TEXT" -out "$SIGNATURE_BINARY" >/dev/null 2>&1 || fail "Release manifest signature is not valid base64."
openssl dgst -sha256 -verify "$PUBLIC_KEY" -signature "$SIGNATURE_BINARY" "$MANIFEST_FILE" >/dev/null 2>&1 || fail "Release manifest signature verification failed. The existing CLI was not changed."

grep -Fq "\"releaseTag\": \"$VERSION\"" "$MANIFEST_FILE" || fail "Signed manifest release tag mismatch."
grep -Fq "\"cliVersion\": \"$EXPECTED_VERSION\"" "$MANIFEST_FILE" || fail "Signed manifest CLI version mismatch."
if [ -n "$RESOLVED_CHANNEL" ]; then
  [ "$(manifest_string_value "$MANIFEST_FILE" channel)" = "$RESOLVED_CHANNEL" ] || fail "Signed release manifest channel mismatch."
  [ "$(manifest_starter_version "$MANIFEST_FILE")" = "$CHANNEL_STARTER_VERSION" ] || fail "Signed release manifest starter version mismatch."
  [ "$(sha256_file "$MANIFEST_FILE")" = "$CHANNEL_RELEASE_MANIFEST_SHA" ] || fail "Signed release manifest digest does not match the signed channel."
fi
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
HAD_ORIGINAL=0
[ -f "$INSTALL_PATH" ] && HAD_ORIGINAL=1
write_installer_transaction DOWNLOADED
download "$RELEASE_BASE/$FILE.sha256" "$SIDECAR_FILE" || fail "Checksum download failed."
SIDECAR_SHA=$(awk '{ print tolower($1); exit }' "$SIDECAR_FILE")
ACTUAL_SHA=$(sha256_file "$NEW_BINARY")
[ "$SIDECAR_SHA" = "$MANIFEST_SHA" ] && [ "$ACTUAL_SHA" = "$MANIFEST_SHA" ] || fail "Binary digest does not match the signed release manifest."

chmod 755 "$NEW_BINARY"
smoke_binary "$NEW_BINARY" "$EXPECTED_VERSION" || fail "Downloaded binary version, help, or first-run verification failed."
if [ "$OS" = Darwin ]; then
  codesign --verify "$NEW_BINARY" >/dev/null 2>&1 || fail "macOS code-signature contract verification failed."
fi
write_installer_transaction VERIFIED

OLD_MOVED=0
REPLACEMENT_STARTED=1
rm -f "$BACKUP_PATH"
if [ -f "$INSTALL_PATH" ]; then mv "$INSTALL_PATH" "$BACKUP_PATH"; OLD_MOVED=1; fi
write_installer_transaction OLD_MOVED
if ! mv "$NEW_BINARY" "$INSTALL_PATH"; then
  [ "$OLD_MOVED" = 1 ] && mv "$BACKUP_PATH" "$INSTALL_PATH"
  clear_installer_transaction
  fail "Atomic binary replacement failed; the previous CLI was restored."
fi
write_installer_transaction NEW_MOVED
chmod 755 "$INSTALL_PATH"
if ! smoke_binary "$INSTALL_PATH" "$EXPECTED_VERSION"; then
  rm -f "$INSTALL_PATH"
  [ "$OLD_MOVED" = 1 ] && mv "$BACKUP_PATH" "$INSTALL_PATH"
  clear_installer_transaction
  fail "Final smoke verification failed; the previous CLI was restored."
fi
write_installer_transaction SMOKE_PASSED

ensure_path
clear_installer_transaction
printf '%s\n' "Contexa $VERSION$(msg installed)$PLATFORM."
printf '%s\n' "$(msg primary)" "  contexa init" "  contexa reset" "  contexa init --simulate" "  contexa reset --simulate"
printf '%s\n' "$(msg immutable)$VERSION"
printf '%s\n' "$(msg rollback)"
printf '%s\n' "$(msg uninstall)"
