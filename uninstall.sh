#!/bin/sh
set -u

installer_file="$(mktemp)" || exit 1
trap 'rm -f "$installer_file"' EXIT HUP INT TERM

if ! curl -fsSL --connect-timeout 5 --max-time 30 \
  https://install.ctxa.ai/install.sh -o "$installer_file"; then
  exit 1
fi

CONTEXA_INSTALL_ACTION=uninstall sh "$installer_file"
