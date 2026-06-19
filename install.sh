#!/usr/bin/env bash
set -euo pipefail

REPO="solderable/solder"
INSTALL_DIR="${HOME}/.local/bin"
VERSION=""
DRY_RUN=0

usage() {
  cat <<'EOF'
Install Solder for macOS.

Usage:
  install.sh [--version <version>] [--install-dir <dir>] [--dry-run]

Options:
  --version <version>  Install a specific release tag/version. Defaults to latest.
  --install-dir <dir>  Install solder and a copy of SolderCAD.app into this directory.
                       Defaults to ~/.local/bin.
  --dry-run            Print the actions that would be taken without installing.
  -h, --help           Show this help.
EOF
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

need_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

resolve_latest_version() {
  local latest_url effective_url tag
  latest_url="https://github.com/${REPO}/releases/latest"

  if ! effective_url="$(curl -fsSLI -o /dev/null -w '%{url_effective}' "$latest_url")"; then
    die "failed to resolve latest release from ${latest_url}"
  fi

  tag="${effective_url##*/}"
  if [[ -z "$tag" || "$tag" == "latest" || "$tag" == "releases" ]]; then
    die "could not determine latest release tag from ${effective_url}"
  fi

  printf '%s\n' "$tag"
}

copy_app_bundle() {
  local source_app destination_app
  source_app="$1"
  destination_app="$2"

  rm -rf "$destination_app"
  ditto "$source_app" "$destination_app"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      [[ $# -ge 2 ]] || die "--version requires a value"
      VERSION="$2"
      shift 2
      ;;
    --version=*)
      VERSION="${1#*=}"
      shift
      ;;
    --install-dir)
      [[ $# -ge 2 ]] || die "--install-dir requires a value"
      INSTALL_DIR="$2"
      shift 2
      ;;
    --install-dir=*)
      INSTALL_DIR="${1#*=}"
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

[[ "$(uname -s)" == "Darwin" ]] || die "install.sh supports macOS only"

case "$(uname -m)" in
  arm64)
    ARCH="arm64"
    ;;
  x86_64|amd64)
    ARCH="x64"
    ;;
  *)
    die "unsupported macOS architecture: $(uname -m)"
    ;;
esac

need_command curl
need_command unzip
need_command mktemp
need_command install
need_command ditto

if [[ -z "$VERSION" ]]; then
  VERSION="$(resolve_latest_version)"
fi

ASSET_NAME="solder-${VERSION}-macos-${ARCH}.zip"
DOWNLOAD_URL="https://github.com/${REPO}/releases/download/${VERSION}/${ASSET_NAME}"
CLI_DEST="${INSTALL_DIR}/solder"
SIDECAR_APP_DEST="${INSTALL_DIR}/SolderCAD.app"
APPLICATIONS_APP_DEST="${HOME}/Applications/SolderCAD.app"

if [[ "$DRY_RUN" -eq 1 ]]; then
  cat <<EOF
Solder macOS installer dry run

Repository:        ${REPO}
Version:           ${VERSION}
Architecture:      ${ARCH}
Download URL:      ${DOWNLOAD_URL}
CLI destination:   ${CLI_DEST}
App destination:   ${SIDECAR_APP_DEST}
Applications copy: ${APPLICATIONS_APP_DEST}
EOF
  exit 0
fi

TMP_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

ARCHIVE_PATH="${TMP_DIR}/${ASSET_NAME}"
EXTRACT_DIR="${TMP_DIR}/extract"
mkdir -p "$EXTRACT_DIR"

printf 'Downloading %s\n' "$DOWNLOAD_URL"
curl -fL --proto '=https' --tlsv1.2 -o "$ARCHIVE_PATH" "$DOWNLOAD_URL"

printf 'Extracting %s\n' "$ASSET_NAME"
unzip -q "$ARCHIVE_PATH" -d "$EXTRACT_DIR"

PAYLOAD_ROOT=""
PAYLOAD_ROOT_COUNT=0
while IFS= read -r candidate_root; do
  PAYLOAD_ROOT="$candidate_root"
  PAYLOAD_ROOT_COUNT=$((PAYLOAD_ROOT_COUNT + 1))
done < <(find "$EXTRACT_DIR" -mindepth 1 -maxdepth 1 -type d \
  ! -name '__MACOSX' \
  ! -name '.*' \
  -print)

[[ "$PAYLOAD_ROOT_COUNT" -eq 1 ]] || die "expected archive to contain exactly one top-level folder"

[[ -f "${PAYLOAD_ROOT}/solder" ]] || die "archive missing solder binary"
[[ -f "${PAYLOAD_ROOT}/INSTALL.txt" ]] || die "archive missing INSTALL.txt"
[[ -d "${PAYLOAD_ROOT}/SolderCAD.app" ]] || die "archive missing SolderCAD.app"

printf 'Installing solder to %s\n' "$CLI_DEST"
mkdir -p "$INSTALL_DIR"
install -m 0755 "${PAYLOAD_ROOT}/solder" "$CLI_DEST"

printf 'Installing SolderCAD.app to %s\n' "$SIDECAR_APP_DEST"
copy_app_bundle "${PAYLOAD_ROOT}/SolderCAD.app" "$SIDECAR_APP_DEST"

printf 'Installing SolderCAD.app to %s\n' "$APPLICATIONS_APP_DEST"
if mkdir -p "${HOME}/Applications" && copy_app_bundle "${PAYLOAD_ROOT}/SolderCAD.app" "$APPLICATIONS_APP_DEST"; then
  :
else
  printf 'warning: could not install SolderCAD.app to %s\n' "$APPLICATIONS_APP_DEST" >&2
fi

cat <<EOF

Solder ${VERSION} installed.

CLI:       ${CLI_DEST}
SolderCAD: ${SIDECAR_APP_DEST}
EOF

if [[ ":${PATH}:" != *":${INSTALL_DIR}:"* ]]; then
  cat <<EOF

Add ${INSTALL_DIR} to your PATH before running solder:
  export PATH="${INSTALL_DIR}:\$PATH"
EOF
fi
