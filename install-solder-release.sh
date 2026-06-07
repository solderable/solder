#!/usr/bin/env bash
set -euo pipefail

install_dir="${SOLDERSLACK_INSTALL_DIR:-${HOME:-}/.local/bin}"
install_name="${SOLDERSLACK_INSTALL_NAME:-solder}"
kicad_install_dir="${SOLDER_KICAD_INSTALL_DIR:-${HOME:-}/Applications}"
kicad_app_name="${SOLDER_KICAD_APP_NAME:-SolderCAD.app}"
release_repo="${SOLDER_RELEASE_REPO:-solderable/solder}"
release_api_url="${SOLDER_RELEASE_API_URL:-https://api.github.com/repos/$release_repo/releases/latest}"
release_download_base_url="${SOLDER_RELEASE_DOWNLOAD_BASE_URL:-https://github.com/$release_repo/releases/download}"

install_kicad() {
  if [ "$(uname -s)" != "Darwin" ]; then
    echo "SOLDER_INSTALL_KICAD is currently supported on macOS only" >&2
    exit 1
  fi

  if [ -z "$kicad_install_dir" ] || { [ "$kicad_install_dir" = "/Applications" ] && [ -z "${HOME:-}" ]; }; then
    echo "SOLDER_KICAD_INSTALL_DIR or HOME must be set" >&2
    exit 1
  fi

  if [ -z "$kicad_app_name" ] || [ "$kicad_app_name" = "." ] || [ "$kicad_app_name" = ".." ] || [[ "$kicad_app_name" == */* ]]; then
    echo "SOLDER_KICAD_APP_NAME must be a plain app bundle name" >&2
    exit 1
  fi

  kicad_target="$kicad_install_dir/$kicad_app_name"
  kicad_stage="$kicad_install_dir/.$kicad_app_name.tmp-$$"

  cleanup_kicad() {
    rm -rf "$kicad_stage"
  }

  if [ ! -x "$package_root/$kicad_app_name/Contents/MacOS/kicad" ] || [ ! -x "$package_root/$kicad_app_name/Contents/MacOS/kicad-cli" ]; then
    echo "SolderCAD artifact did not contain a runnable KiCad app bundle" >&2
    exit 1
  fi

  mkdir -p "$kicad_install_dir"
  rm -rf "$kicad_stage"
  cp -R "$package_root/$kicad_app_name" "$kicad_stage"
  rm -rf "$kicad_target"
  mv "$kicad_stage" "$kicad_target"
  cleanup_kicad

  echo "SolderCAD installed to $kicad_target"
}

if [ -z "$install_dir" ] || [ "$install_dir" = "/.local/bin" ]; then
  echo "SOLDERSLACK_INSTALL_DIR or HOME must be set" >&2
  exit 1
fi

if [ -z "$install_name" ] || [ "$install_name" = "." ] || [ "$install_name" = ".." ] || [[ "$install_name" == */* ]]; then
  echo "SOLDERSLACK_INSTALL_NAME must be a plain filename" >&2
  exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "curl is required to install solder" >&2
  exit 1
fi

if [ "$(uname -s)" != "Darwin" ]; then
  echo "The hosted solder release installer currently supports macOS only" >&2
  exit 1
fi

if ! command -v ditto >/dev/null 2>&1; then
  echo "ditto is required to extract the solder release" >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1 && [ -z "${SOLDER_RELEASE_TAG:-}" ]; then
  echo "python3 is required to resolve solder release metadata" >&2
  echo "Install python3, or set SOLDER_RELEASE_TAG" >&2
  exit 1
fi

arch="$(uname -m)"
case "$arch" in
  arm64) release_arch="arm64" ;;
  x86_64) release_arch="x64" ;;
  *)
    echo "Unsupported macOS architecture for solder: $arch" >&2
    exit 1
    ;;
esac

release_tag="${SOLDER_RELEASE_TAG:-}"
release_json=""

if [ -z "$release_tag" ]; then
  release_json="$(curl -fsSL "$release_api_url")"
fi

if [ -z "$release_tag" ]; then
  release_tag="$(printf '%s' "$release_json" | python3 -c 'import json, sys; print(json.load(sys.stdin)["tag_name"])')"
fi

if [ -z "$release_tag" ]; then
  echo "Could not resolve latest solder release tag" >&2
  exit 1
fi

package_name="solder-$release_tag-macos-$release_arch"
package_url="${SOLDER_RELEASE_ARTIFACT_URL:-$release_download_base_url/$release_tag/$package_name.zip}"

mkdir -p "$install_dir"
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/solder-release.XXXXXX")"
package_zip="$tmp_dir/$package_name.zip"
extract_dir="$tmp_dir/extract"
tmp="$(mktemp "${TMPDIR:-/tmp}/solder.XXXXXX")"
target="$install_dir/$install_name"
cleanup() {
  rm -rf "$tmp_dir"
  rm -f "$tmp"
}
trap cleanup EXIT

echo "Downloading solder $release_tag for macOS $release_arch"
curl -fsSL "$package_url" -o "$package_zip"
mkdir -p "$extract_dir"
ditto -x -k "$package_zip" "$extract_dir"

package_root="$extract_dir/$package_name"
if [ ! -d "$package_root" ]; then
  package_root="$(find "$extract_dir" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
fi

if [ -z "$package_root" ] || [ ! -x "$package_root/solder" ]; then
  echo "Solder release artifact did not contain an executable solder binary" >&2
  exit 1
fi

cp "$package_root/solder" "$tmp"
chmod 0755 "$tmp"
if command -v codesign >/dev/null 2>&1; then
  codesign --force --sign - "$tmp" >/dev/null 2>&1 || true
fi
mv "$tmp" "$target"

echo "solder installed to $target"
case ":${PATH:-}:" in
  *":$install_dir:"*) ;;
  *) echo "Add $install_dir to PATH, then run: $install_name --version" ;;
esac

if [ "${SOLDER_INSTALL_KICAD:-1}" = "1" ]; then
  install_kicad
fi

cleanup
trap - EXIT
