#!/usr/bin/env bash
set -euo pipefail

REPO="solderable/solder"
INSTALL_DIR="${HOME}/.local/bin"
CONFIG_ROOT="${XDG_CONFIG_HOME:-${HOME}/.config}"
APP_CONFIG_DIR="${CONFIG_ROOT}/solderslack"
VERSION=""
DOWNLOAD_SOURCE="auto"
DRY_RUN=0

usage() {
  cat <<'EOF'
Install Solder for macOS.

Usage:
  install.sh [--version <version>] [--install-dir <dir>] [--download-source <auto|github>] [--dry-run]

Options:
  --version <version>  Install a specific release tag/version. Defaults to latest.
  --install-dir <dir>  Install the solder command into this directory.
                       Defaults to ~/.local/bin. SolderCAD.app is installed to ~/Applications.
  --download-source   Prefer the release's UploadThing CDN (auto, default), or use github.
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

resolve_release_download() {
  # JavaScript for Automation is built into macOS; do not require jq or Python
  # just to install Solder. Parse JSON as data, never source release-note text.
  /usr/bin/osascript -l JavaScript - "$1" "$VERSION" "$ARCH" "$DOWNLOAD_SOURCE" <<'JXA'
ObjC.import('Foundation');
function run(argv) {
  function fail(message) { throw new Error(message); }
  function record(value) { return value !== null && typeof value === 'object' && !Array.isArray(value); }
  function positiveInteger(value) { return typeof value === 'number' && isFinite(value) && Math.floor(value) === value && value > 0 && value <= 9007199254740991; }
  function version(value) { return typeof value === 'string' && !/[\r\n]/.test(value) && /^v?[0-9]+\.[0-9]+(?:\.[0-9]+)?(?:-[0-9A-Za-z.-]+)?$/.test(value); }
  function digest(value) { return typeof value === 'string' && !/[\r\n]/.test(value) && /^sha256:[0-9a-f]{64}$/i.test(value); }
  var text = $.NSString.stringWithContentsOfFileEncodingError(argv[0], $.NSUTF8StringEncoding, null);
  if (!text) fail('Could not read GitHub release metadata.');
  var release;
  try { release = JSON.parse(ObjC.unwrap(text)); }
  catch (_) { fail('GitHub release metadata is invalid JSON.'); }
  if (!record(release) || !version(release.tag_name) || release.draft !== false || !Array.isArray(release.assets)) {
    fail('GitHub returned invalid release metadata.');
  }
  var tag = release.tag_name;
  if (argv[1] && tag !== argv[1]) fail('GitHub returned a different release version than requested.');
  var name = 'solder-' + tag + '-macos-' + argv[2] + '.zip';
  var assets = release.assets.filter(function (asset) { return record(asset) && asset.name === name; });
  if (assets.length !== 1) fail('GitHub release must contain exactly one ' + name + ' asset.');
  var asset = assets[0];
  var url = 'https://github.com/solderable/solder/releases/download/' + tag + '/' + name;
  if (!positiveInteger(asset.size) || !digest(asset.digest) || asset.browser_download_url !== url) {
    fail('GitHub release asset is missing a valid size, SHA-256 digest, or download URL.');
  }
  var source = 'github';
  if (argv[3] !== 'github' && release.body !== null && release.body !== undefined) {
    if (typeof release.body !== 'string') fail('GitHub release body is invalid.');
    var marker = '<!-- solder-release-platform-details';
    var start = release.body.indexOf(marker);
    if (start >= 0) {
      var prefix = marker + ' ';
      var end = release.body.indexOf(' -->', start + prefix.length);
      if (release.body.slice(start, start + prefix.length) !== prefix || end < 0 || release.body.indexOf(marker, start + marker.length) >= 0) {
        fail('Release download metadata is malformed. Use --download-source github to select GitHub explicitly.');
      }
      var details;
      try { details = JSON.parse(release.body.slice(start + prefix.length, end)); }
      catch (_) { fail('Release download metadata is invalid JSON. Use --download-source github to select GitHub explicitly.'); }
      if (!record(details)) fail('Release download metadata must be an object.');
      if (Object.prototype.hasOwnProperty.call(details, 'macos')) {
        var detail = details.macos;
        var mirror = record(detail) ? detail.asset : null;
        if (!record(mirror) || mirror.name !== name || mirror.size !== asset.size || !digest(mirror.digest) || mirror.digest.toLowerCase() !== asset.digest.toLowerCase()) {
          fail('Release download metadata does not match the GitHub asset. Use --download-source github to select GitHub explicitly.');
        }
        if (Object.prototype.hasOwnProperty.call(mirror, 'downloadUrl')) {
          var candidate = mirror.downloadUrl;
          if (typeof candidate !== 'string' || /[^\x21-\x7e]/.test(candidate) || !/^https:\/\/(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.ufs\.sh|utfs\.io)\/f\/[A-Za-z0-9_-]+$/.test(candidate)) {
            fail('Release download URL must be a public UploadThing URL without credentials or query parameters.');
          }
          url = candidate;
          source = 'uploadthing';
        }
      }
    }
  }
  return [tag, name, url, asset.size, asset.digest.slice(7).toLowerCase(), source].join('\t');
}
JXA
}

copy_app_bundle() {
  local source_app destination_app
  source_app="$1"
  destination_app="$2"

  rm -rf "$destination_app"
  ditto "$source_app" "$destination_app"
}

config_dir_writable() {
  local probe
  mkdir -p "$CONFIG_ROOT" 2>/dev/null || return 1
  mkdir -p -m 700 "$APP_CONFIG_DIR" 2>/dev/null || return 1
  probe="${APP_CONFIG_DIR}/.install-write-probe.$$"
  touch "$probe" 2>/dev/null || return 1
  rm -f "$probe"
}

print_config_dir_fix() {
  cat >&2 <<EOF

warning: ${CONFIG_ROOT} is not writable by your user (often caused by a past
"sudo" install of another tool). solder is installed and will run, but it
cannot save your /auth sign-in until you fix the ownership:

  sudo chown "\$(id -un)" "${CONFIG_ROOT}" && mkdir -p "${APP_CONFIG_DIR}"

EOF
}

# solder saves its sign-in key under ~/.config/solderslack. A root-owned
# ~/.config (left behind by past sudo installs of other tools) makes that
# save fail after an otherwise-successful /auth, so repair ownership now.
ensure_config_dir() {
  if config_dir_writable; then
    return 0
  fi

  case "$CONFIG_ROOT" in
    "${HOME}"/*) ;;
    *)
      print_config_dir_fix
      return 0
      ;;
  esac

  printf '\n%s is not writable by your user (often caused by a past "sudo" install).\n' "$CONFIG_ROOT" >&2
  printf 'Fixing ownership so solder can save your sign-in — sudo may ask for your password.\n' >&2

  if ! sudo -n true 2>/dev/null; then
    if [[ ! -r /dev/tty ]] || ! sudo -p "Password for %p: " true; then
      print_config_dir_fix
      return 0
    fi
  fi

  sudo mkdir -p "$CONFIG_ROOT" 2>/dev/null || true
  sudo chown "$(id -u):$(id -g)" "$CONFIG_ROOT" 2>/dev/null || true
  sudo chmod u+rwx "$CONFIG_ROOT" 2>/dev/null || true
  if [[ -e "$APP_CONFIG_DIR" ]]; then
    sudo chown -R "$(id -u):$(id -g)" "$APP_CONFIG_DIR" 2>/dev/null || true
    sudo chmod -R u+rwX "$APP_CONFIG_DIR" 2>/dev/null || true
  fi

  if config_dir_writable; then
    printf 'Fixed: %s is now writable.\n' "$APP_CONFIG_DIR" >&2
  else
    print_config_dir_fix
  fi
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
    --download-source)
      [[ $# -ge 2 ]] || die "--download-source requires a value"
      DOWNLOAD_SOURCE="$2"
      shift 2
      ;;
    --download-source=*)
      DOWNLOAD_SOURCE="${1#*=}"
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

[[ "$DOWNLOAD_SOURCE" == "auto" || "$DOWNLOAD_SOURCE" == "github" ]] || die "--download-source must be auto or github"
[[ -z "$VERSION" || "$VERSION" =~ ^v?[0-9]+\.[0-9]+(\.[0-9]+)?(-[0-9A-Za-z.-]+)?$ ]] || die "--version must be a release version"

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
need_command shasum

TMP_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

RELEASE_API_URL="https://api.github.com/repos/${REPO}/releases/latest"
if [[ -n "$VERSION" ]]; then
  RELEASE_API_URL="https://api.github.com/repos/${REPO}/releases/tags/${VERSION}"
fi
printf 'Reading GitHub release metadata...\n' >&2
curl -fsSL --proto '=https' --tlsv1.2 --connect-timeout 15 --max-time 60 --max-filesize 1048576 \
  -H 'Accept: application/vnd.github+json' -H 'User-Agent: solder-installer' \
  -o "$TMP_DIR/release.json" "$RELEASE_API_URL" || die "failed to read GitHub release metadata"
DOWNLOAD_DETAILS="$(resolve_release_download "$TMP_DIR/release.json")" || die "release download metadata could not be verified"
IFS=$'\t' read -r VERSION ASSET_NAME DOWNLOAD_URL EXPECTED_SIZE EXPECTED_SHA256 RESOLVED_SOURCE <<< "$DOWNLOAD_DETAILS"

CLI_DEST="${INSTALL_DIR}/solder"
OLD_SIDECAR_APP_DEST="${INSTALL_DIR}/SolderCAD.app"
APPLICATIONS_APP_DEST="${HOME}/Applications/SolderCAD.app"

if [[ "$DRY_RUN" -eq 1 ]]; then
  cat <<EOF
Solder macOS installer dry run

Repository:        ${REPO}
Version:           ${VERSION}
Architecture:      ${ARCH}
Download URL:      ${DOWNLOAD_URL}
Download source:   ${RESOLVED_SOURCE}
Archive bytes:     ${EXPECTED_SIZE}
SHA-256:           ${EXPECTED_SHA256}
CLI destination:   ${CLI_DEST}
App destination:   ${APPLICATIONS_APP_DEST}
Old sidecar app:   ${OLD_SIDECAR_APP_DEST}
Config directory:  ${APP_CONFIG_DIR}
EOF
  exit 0
fi

ARCHIVE_PATH="${TMP_DIR}/${ASSET_NAME}"
EXTRACT_DIR="${TMP_DIR}/extract"
mkdir -p "$EXTRACT_DIR"

printf 'Downloading %s\n' "$DOWNLOAD_URL"
curl -fL --proto '=https' --tlsv1.2 -o "$ARCHIVE_PATH" "$DOWNLOAD_URL" || die "${RESOLVED_SOURCE} download failed; no other source was tried. To use GitHub explicitly, rerun with --download-source github"

printf 'Verifying archive size and SHA-256...\n'
ACTUAL_SIZE="$(stat -f%z "$ARCHIVE_PATH")"
[[ "$ACTUAL_SIZE" == "$EXPECTED_SIZE" ]] || die "downloaded archive size does not match the GitHub release asset"
ACTUAL_SHA256="$(shasum -a 256 "$ARCHIVE_PATH")"
ACTUAL_SHA256="${ACTUAL_SHA256%% *}"
[[ "$ACTUAL_SHA256" == "$EXPECTED_SHA256" ]] || die "downloaded archive SHA-256 does not match the GitHub release asset"

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

if [[ -e "$OLD_SIDECAR_APP_DEST" || -L "$OLD_SIDECAR_APP_DEST" ]]; then
  printf 'Removing old sidecar SolderCAD.app from %s\n' "$OLD_SIDECAR_APP_DEST"
  rm -rf "$OLD_SIDECAR_APP_DEST"
fi

printf 'Installing SolderCAD.app to %s\n' "$APPLICATIONS_APP_DEST"
mkdir -p "${HOME}/Applications"
copy_app_bundle "${PAYLOAD_ROOT}/SolderCAD.app" "$APPLICATIONS_APP_DEST"

ensure_config_dir

cat <<EOF

Solder ${VERSION} installed.

CLI:       ${CLI_DEST}
SolderCAD: ${APPLICATIONS_APP_DEST}
EOF

if [[ ":${PATH}:" != *":${INSTALL_DIR}:"* ]]; then
  cat <<EOF

Add ${INSTALL_DIR} to your PATH before running solder:
  export PATH="${INSTALL_DIR}:\$PATH"
EOF
fi
