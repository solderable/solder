#!/usr/bin/env bash
set -euo pipefail

arch_die() { printf 'error: %s\n' "$*" >&2; exit 1; }
arch_need() { command -v "$1" >/dev/null 2>&1 || arch_die "required command not found: $1"; }
arch_usage() {
  cat <<'EOF'
Install the Solder CLI and SolderCAD on Arch Linux x86_64.

Usage: install-arch.sh [--version <version>] [--dry-run] [--yes]

  --version <version>  Install this release; otherwise select GitHub Latest.
  --dry-run            Inspect the release and user launchers without installing.
  --yes                Let pacman proceed without its confirmation prompt.

Run as your normal user. Only pacman runs through sudo.
Requires curl, Python 3, pacman, and sudo.
EOF
}

arch_resolve_download() {
  python3 - "$1" "$2" <<'PY'
import json, re, sys

def fail(message):
    raise SystemExit('error: ' + message)
try:
    with open(sys.argv[1], encoding='utf-8') as source:
        release = json.load(source)
except (OSError, ValueError):
    fail('GitHub release metadata is not readable JSON')
if not isinstance(release, dict):
    fail('GitHub returned invalid release metadata')
tag = release.get('tag_name')
if not isinstance(tag, str) or not re.fullmatch(r'v?[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?', tag):
    fail('GitHub returned an invalid release version')
if release.get('draft') is not False or not isinstance(release.get('assets'), list):
    fail('GitHub returned invalid release metadata')
if sys.argv[2] and tag != sys.argv[2]:
    fail('GitHub returned a different release version than requested')
name = 'soldercad-' + tag.removeprefix('v') + '-1-x86_64.pkg.tar.zst'
assets = [item for item in release['assets'] if isinstance(item, dict) and item.get('name') == name]
if len(assets) != 1:
    fail('GitHub release must contain exactly one ' + name + ' asset')
asset = assets[0]
size = asset.get('size')
digest = asset.get('digest')
url = 'https://github.com/solderable/solder/releases/download/' + tag + '/' + name
if type(size) is not int or not 0 < size <= 9007199254740991:
    fail('GitHub release asset has an invalid byte size')
if not isinstance(digest, str) or not re.fullmatch(r'sha256:[0-9a-fA-F]{64}', digest):
    fail('GitHub release asset is missing a valid SHA-256 digest')
if asset.get('browser_download_url') != url:
    fail('GitHub release asset has an unexpected download URL')
print('\t'.join([tag, name, url, str(size), digest[7:].lower()]))
PY
}

# The installer owns no files in the user's home. Only recognized legacy
# launchers that shadow the system package may be backed up and replaced.
arch_user_launchers() {
  python3 - "$1" "$2" "$3" "$4" <<'PY'
import hashlib, json, os, pathlib, secrets, shlex, stat, sys

phase, home_value, path_value, plan_file = sys.argv[1:]
home = pathlib.Path(home_value).resolve(strict=True)
bin_dir = home / '.local' / 'bin'
uid = os.getuid()

def fail(message):
    raise SystemExit('error: ' + message)

def identity(path):
    entry = path.lstat()
    value = {'dev': entry.st_dev, 'ino': entry.st_ino, 'mode': entry.st_mode,
             'uid': entry.st_uid, 'size': entry.st_size, 'mtime_ns': entry.st_mtime_ns}
    if stat.S_ISLNK(entry.st_mode):
        value['target'] = os.readlink(path)
    elif stat.S_ISREG(entry.st_mode):
        if entry.st_size > 65536:
            fail(str(path) + ' is not a recognized old Solder launcher; leave it intact and use /usr/bin/' + path.name)
        value['sha256'] = hashlib.sha256(path.read_bytes()).hexdigest()
    return value

def is_legacy(path, name):
    try:
        target = path.resolve(strict=True)
        target.relative_to(home)
        info = target.stat()
        if not stat.S_ISREG(info.st_mode) or info.st_uid != uid or info.st_size > 65536:
            return False
        text = target.read_text(encoding='utf-8')
    except (OSError, ValueError, UnicodeError, RuntimeError):
        return False
    # Match a small shell shim, not an arbitrary program mentioning a filename.
    lines = [line.strip() for line in text.splitlines() if line.strip() and not line.lstrip().startswith('#')]
    if len(lines) != 1:
        return False
    try:
        args = shlex.split(lines[0])
    except ValueError:
        return False
    if not text.startswith('#!') or not args or args[0] != 'exec' or args[-1] != '$@':
        return False
    if name == 'solder':
        if len(args) != 4:
            return False
        def home_path(value):
            for prefix in ('${HOME}/', '$HOME/'):
                if value.startswith(prefix):
                    return str(home / value[len(prefix):])
            return value
        return (home_path(args[1]) in ('bun', str(home / '.bun/bin/bun'))
                and home_path(args[2]) == str(home / '.local/bin/solder-main.js'))
    return len(args) == 3 and args[1] in ('/opt/soldercad/bin/kicad', '/usr/bin/soldercad')

def shadows_system(name):
    for entry in path_value.split(os.pathsep):
        directory = pathlib.Path(entry or os.curdir).resolve()
        if directory == pathlib.Path('/usr/bin').resolve():
            return False
        if directory == bin_dir.resolve():
            return True
        candidate = directory / name
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return False
    return False

def plan():
    actions = []
    for name in ('solder', 'soldercad'):
        path = bin_dir / name
        if not os.path.lexists(path) or not shadows_system(name):
            continue
        if path.is_symlink() and os.readlink(path) in ('/usr/bin/' + name, '/opt/soldercad/bin/' + name):
            continue
        if not path.is_file() or not os.access(path, os.X_OK):
            continue
        if bin_dir.is_symlink() or (home / '.local').is_symlink():
            fail(str(bin_dir) + ' uses a symbolic-link directory; inspect it before replacing launchers')
        for parent in (home, home / '.local', bin_dir):
            info = parent.stat()
            if info.st_uid != uid or info.st_mode & 0o022:
                fail(str(parent) + ' is not a private user-owned launcher directory; inspect its ownership and permissions')
        current = identity(path)
        if current['uid'] != uid:
            fail(str(path) + ' is owned by another user; inspect it before installing')
        if not is_legacy(path, name):
            fail(str(path) + ' shadows /usr/bin/' + name + ' and is not a recognized old Solder launcher. It was left unchanged. Move or rename it yourself, then retry.')
        actions.append({'name': name, 'identity': current})
    directory = None
    if actions:
        info = bin_dir.stat()
        directory = {'dev': info.st_dev, 'ino': info.st_ino}
    return {'directory': directory, 'actions': actions}

if phase == 'plan':
    prepared = plan()
    pathlib.Path(plan_file).write_text(json.dumps(prepared), encoding='utf-8')
    for action in prepared['actions']:
        print('Old user launcher will be backed up: ' + str(bin_dir / action['name']))
elif phase == 'apply':
    prepared = json.loads(pathlib.Path(plan_file).read_text(encoding='utf-8'))
    if plan() != prepared:
        fail('User launchers changed during installation; no launcher was replaced. Inspect them and retry.')
    if prepared['actions']:
        directory_fd = os.open(bin_dir, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            info = os.fstat(directory_fd)
            if {'dev': info.st_dev, 'ino': info.st_ino} != prepared['directory']:
                fail('User launcher directory changed during installation; no launcher was replaced')
            for action in prepared['actions']:
                name = action['name']
                path = bin_dir / name
                if identity(path) != action['identity']:
                    fail(str(path) + ' changed during installation; it was not replaced')
                backup_name = '.solder-launcher-backup-' + secrets.token_hex(12)
                os.mkdir(backup_name, mode=0o700, dir_fd=directory_fd)
                backup_fd = os.open(backup_name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=directory_fd)
                try:
                    os.rename(name, name, src_dir_fd=directory_fd, dst_dir_fd=backup_fd)
                    # Recheck after the move: a concurrent replacement must not
                    # be mistaken for the launcher the user saw before install.
                    moved = os.stat(name, dir_fd=backup_fd, follow_symlinks=False)
                    expected = action['identity']
                    if (moved.st_dev, moved.st_ino, moved.st_mode, moved.st_uid, moved.st_size, moved.st_mtime_ns) != tuple(expected[key] for key in ('dev', 'ino', 'mode', 'uid', 'size', 'mtime_ns')):
                        fail('User launcher changed while being moved; preserved it in ' + str(bin_dir / backup_name))
                    os.symlink('/usr/bin/' + name, name, dir_fd=directory_fd)
                except BaseException:
                    try:
                        os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
                    except FileNotFoundError:
                        os.rename(name, name, src_dir_fd=backup_fd, dst_dir_fd=directory_fd)
                    raise
                finally:
                    os.close(backup_fd)
                print('Preserved old launcher at ' + str(bin_dir / backup_name / name))
                print('User launcher now selects /usr/bin/' + name)
        finally:
            os.close(directory_fd)
else:
    fail('Unknown launcher operation')
PY
}

arch_install_release() (
  set -euo pipefail
  local requested="$1" dry_run="$2" assume_yes="$3" user_home="$4" user_path="$5"
  local api details tag name url size digest actual archive
  local -a headers
  # This function already has a subshell scope. Keep the cleanup path alive
  # while Bash unwinds locals before running the EXIT trap.
  scratch="$(mktemp -d)"
  trap 'rm -rf "$scratch"' EXIT
  arch_user_launchers plan "$user_home" "$user_path" "$scratch/launchers.json"
  api='https://api.github.com/repos/solderable/solder/releases/latest'
  if [[ -n "$requested" ]]; then api="https://api.github.com/repos/solderable/solder/releases/tags/$requested"; fi
  printf 'Reading GitHub release metadata...\n'
  headers=(-H 'Accept: application/vnd.github+json' -H 'User-Agent: solder-arch-installer')
  if [[ -n "${GH_TOKEN:-}" ]]; then
    (umask 077; printf 'Authorization: Bearer %s\n' "$GH_TOKEN" > "$scratch/api-authorization")
    headers+=(-H "@$scratch/api-authorization")
  fi
  # Never forward API credentials through a metadata redirect.
  curl -fsSL --max-redirs 0 --proto '=https' --tlsv1.2 --connect-timeout 15 --max-time 60 --max-filesize 1048576 \
    "${headers[@]}" \
    -o "$scratch/release.json" "$api" || arch_die 'failed to read GitHub release metadata'
  details="$(arch_resolve_download "$scratch/release.json" "$requested")" || exit 1
  IFS=$'\t' read -r tag name url size digest <<< "$details"
  printf 'Solder %s for Arch Linux x86_64\nPackage: %s\nBytes: %s\nSHA-256: %s\n' "$tag" "$name" "$size" "$digest"
  if [[ "$dry_run" == 1 ]]; then
    printf 'Dry run: no package downloaded, installed, or user launchers changed.\n'
    exit 0
  fi
  archive="$scratch/$name"
  curl -fL --proto '=https' --proto-redir '=https' --tlsv1.2 --connect-timeout 15 --max-time 1800 --max-filesize "$size" \
    -o "$archive" "$url" || arch_die 'package download failed; nothing was installed'
  actual="$(wc -c < "$archive")"
  actual="${actual//[[:space:]]/}"
  [[ "$actual" == "$size" ]] || arch_die 'downloaded package size does not match the GitHub asset; nothing was installed'
  actual="$(sha256sum "$archive")"
  [[ "${actual%% *}" == "$digest" ]] || arch_die 'downloaded package SHA-256 does not match the GitHub asset; nothing was installed'
  printf 'Package size and SHA-256 verified.\n'
  if [[ "$assume_yes" == 1 ]]; then
    sudo pacman -U --noconfirm -- "$archive"
  elif [[ -t 0 ]]; then
    sudo pacman -U -- "$archive"
  elif [[ -r /dev/tty ]]; then
    # The normal user opens their terminal; sudo elevates only pacman.
    # shellcheck disable=SC2024
    sudo pacman -U -- "$archive" < /dev/tty
  else
    arch_die 'pacman confirmation needs a terminal; rerun with --yes for noninteractive installation'
  fi
  [[ "$(pacman -Q soldercad)" == "soldercad ${tag#v}-1" ]] || arch_die 'pacman did not report the requested installed Solder version; user launchers were not changed'
  arch_user_launchers apply "$user_home" "$user_path" "$scratch/launchers.json"
  if [[ -n "${SOLDER_BINARY_PATH:-}" && ! "$SOLDER_BINARY_PATH" -ef /opt/soldercad/bin/solder ]]; then
    printf 'warning: SOLDER_BINARY_PATH still overrides the installed CLI. To launch this package: env -u SOLDER_BINARY_PATH /usr/bin/soldercad\n' >&2
  fi
  printf 'Installed Solder %s. Run /usr/bin/solder or /usr/bin/soldercad as your normal user.\n' "$tag"
  printf 'If your shell cached an older command, run hash -r or open a new terminal.\n'
)

arch_main() {
  local version='' dry_run=0 assume_yes=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --version) [[ $# -gt 1 && -n "$2" ]] || arch_die '--version requires a value'; version="$2"; shift 2 ;;
      --version=*) version="${1#*=}"; [[ -n "$version" ]] || arch_die '--version requires a value'; shift ;;
      --dry-run) dry_run=1; shift ;;
      --yes) assume_yes=1; shift ;;
      -h|--help) arch_usage; return ;;
      *) arch_die "unknown argument: $1" ;;
    esac
  done
  [[ -z "$version" || "$version" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]] || arch_die '--version must be a release version'
  [[ "$(uname -s)" == Linux && "$(uname -m)" == x86_64 && -f /etc/arch-release ]] || arch_die 'this installer requires Arch Linux x86_64'
  [[ "$(id -u)" != 0 ]] || arch_die 'run this installer as your normal user; only pacman uses sudo'
  for command in curl python3 sha256sum pacman sudo; do arch_need "$command"; done
  arch_install_release "$version" "$dry_run" "$assume_yes" "$HOME" "$PATH"
}

if [[ "${BASH_SOURCE[0]:-$0}" == "$0" ]]; then arch_main "$@"; fi
