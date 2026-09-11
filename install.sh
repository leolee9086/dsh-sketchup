#!/usr/bin/env bash
# macOS: install into an existing DSH + Node/pnpm setup. This does not bootstrap DSH.
set -euo pipefail
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PLUGINS=${SKETCHUP_PLUGINS_DIR:-"$HOME/Library/Application Support/SketchUp 2024/SketchUp/Plugins"}
DSH_COMMAND=dsh
DSH_ROOT=${DSH_HOME:-"$HOME/.dsh"}
PROFILE=web
PACKAGE=''
SKIP_HOST=0
SKIP_RUBY=0
DRY_RUN=0
usage() {
  printf '%s\n' 'Usage: bash install.sh [--source-root DIR] [--plugins-dir DIR] [--dsh-command PATH]' \
    '  [--dsh-home DIR] [--profile NAME] [--package-path DIR_OR_TGZ]' \
    '  [--skip-host] [--skip-ruby] [--dry-run]' \
    'Requires existing DSH and pnpm for Host installation; macOS SketchUp Ruby installation only.'
}
while (($#)); do
  case "$1" in
    --source-root|--plugins-dir|--dsh-command|--dsh-home|--profile|--package-path)
      if (($# < 2)) || [[ -z "$2" ]]; then printf 'Missing value for %s\n' "$1" >&2; exit 2; fi
      case "$1" in
        --source-root) ROOT=$2;; --plugins-dir) PLUGINS=$2;; --dsh-command) DSH_COMMAND=$2;;
        --dsh-home) DSH_ROOT=$2;; --profile) PROFILE=$2;; --package-path) PACKAGE=$2;;
      esac
      shift 2;;
    --skip-host) SKIP_HOST=1; shift;; --skip-ruby) SKIP_RUBY=1; shift;;
    --dry-run) DRY_RUN=1; shift;; --help|-h) usage; exit 0;;
    *) printf 'Unknown option: %s\n' "$1" >&2; usage >&2; exit 2;;
  esac
done
[[ $SKIP_HOST != 1 || $SKIP_RUBY != 1 ]] || { echo 'Choose at least one component.' >&2; exit 2; }
[[ "$PROFILE" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ && ! "$PROFILE" =~ ^[Dd][Ee][Ss][Kk][Tt][Oo][Pp]$ ]] || { echo 'Invalid profile name.' >&2; exit 2; }
# Normalize source/package paths before dsh changes the package-manager directory.
ROOT=$(CDPATH= cd -- "$ROOT" && pwd)
[[ "$PLUGINS" = /* ]] || PLUGINS="$PWD/$PLUGINS"
[[ "$DSH_ROOT" = /* ]] || DSH_ROOT="$PWD/$DSH_ROOT"
if (( ! SKIP_RUBY )); then
  for name in dsh_sketchup_bridge.rb dsh_sketchup_bridge/main.rb dsh_sketchup_bridge/setup.rb; do
    [[ -f "$ROOT/ruby/$name" ]] || { printf 'Missing Ruby source: %s\n' "$name" >&2; exit 1; }
  done
fi
NEEDS_BUILD=0
NEEDS_PACK=0
if (( ! SKIP_HOST )); then
  if [[ -z "$PACKAGE" ]]; then
    PACKAGE="$ROOT/leolee9086-dsh-sketchup-0.1.0-alpha.1.tgz"
    [[ -f "$PACKAGE" ]] || PACKAGE="$ROOT"
  fi
  [[ "$PACKAGE" = /* ]] || PACKAGE="$PWD/$PACKAGE"
  [[ -e "$PACKAGE" ]] || { printf 'Host package not found: %s\n' "$PACKAGE" >&2; exit 1; }
  if [[ -d "$PACKAGE" ]]; then NEEDS_PACK=1; fi
  if [[ -d "$PACKAGE" && ! -f "$PACKAGE/lib/index.js" ]]; then NEEDS_BUILD=1; fi
  printf 'Host: %q plugin --profile %q add --save-exact %q\nDSH_HOME: %s\n' "$DSH_COMMAND" "$PROFILE" "$PACKAGE" "$DSH_ROOT"
  echo 'Host package will be copied into the persistent DSH_HOME/packages/dsh-sketchup cache before registration.'
  if (( NEEDS_PACK )); then echo 'Package source: npm pack --ignore-scripts (no source-directory link)'; fi
  if (( NEEDS_BUILD )); then echo 'Source build required: pnpm install --frozen-lockfile --ignore-scripts; pnpm run build'; fi
fi
if (( ! SKIP_RUBY )); then printf 'Ruby destination: %s (existing components receive unique backups)\n' "$PLUGINS"; fi
if (( DRY_RUN )); then echo 'Dry run: no commands executed, downloads, directories, or files written.'; exit 0; fi
# Cleanup touches only unique staging paths created by this invocation.
STAGE=''
PACK_STAGE=''
CACHE_STAGE=''
cleanup() {
  [[ -z "$STAGE" ]] || rm -rf -- "$STAGE"
  [[ -z "$PACK_STAGE" ]] || rm -rf -- "$PACK_STAGE"
  [[ -z "$CACHE_STAGE" ]] || rm -f -- "$CACHE_STAGE"
  return 0
}
trap cleanup EXIT
file_hash() {
  if command -v shasum >/dev/null; then shasum -a 256 "$1" | cut -d ' ' -f 1
  elif command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d ' ' -f 1
  else echo 'A SHA256 utility (shasum or sha256sum) is required.' >&2; return 127; fi
}
# mktemp atomically reserves a new backup path; never delete an older backup.
backup_file() {
  if [[ -e "$1" || -L "$1" ]]; then
    local backup
    backup=$(mktemp -d "$1.bak-XXXXXXXX")
    cp -pR "$1" "$backup/original"
    printf 'Backup: %s/original\n' "$backup"
  fi
}
if (( ! SKIP_HOST )); then
  command -v "$DSH_COMMAND" >/dev/null || { echo 'DSH CLI not found; supply --dsh-command. macOS bootstrap is not included.' >&2; exit 127; }
  if (( NEEDS_PACK )); then
    command -v npm >/dev/null || { echo 'Package directories need npm pack; use a release tarball or install npm.' >&2; exit 127; }
    # npm 10 may execute prepare despite --ignore-scripts. Refuse that implicit
    # lifecycle hook; this suite builds explicitly before packing.
    node -e 'const m = JSON.parse(require("node:fs").readFileSync(process.argv[1], "utf8")); if (m.scripts && m.scripts.prepare) { console.error("Source package has a prepare script; use a prebuilt release tarball instead."); process.exit(1); }' "$PACKAGE/package.json"
  fi
  if (( NEEDS_BUILD )); then
    command -v pnpm >/dev/null || { echo 'Source build needs pnpm.' >&2; exit 127; }
    (cd -- "$PACKAGE" && pnpm install --frozen-lockfile --ignore-scripts && pnpm run build)
    [[ -f "$PACKAGE/lib/index.js" ]] || { echo 'Source build produced no lib/index.js.' >&2; exit 1; }
  fi
  if (( NEEDS_PACK )); then
    PACK_STAGE=$(mktemp -d "${TMPDIR:-/tmp}/dsh-sketchup-pack-XXXXXXXX")
    (cd -- "$PACKAGE" && npm pack --ignore-scripts --pack-destination "$PACK_STAGE")
    archives=("$PACK_STAGE"/*.tgz)
    [[ ${#archives[@]} = 1 && -f "${archives[0]}" ]] || { echo 'npm pack must produce exactly one Host tarball.' >&2; exit 1; }
    PACKAGE=${archives[0]}
  fi
  hash=$(file_hash "$PACKAGE")
  cache_dir="$DSH_ROOT/packages/dsh-sketchup"
  cached_package="$cache_dir/$hash.tgz"
  if [[ -e "$cached_package" ]]; then
    [[ $(file_hash "$cached_package") = "$hash" ]] || { echo 'Cached Host package checksum mismatch.' >&2; exit 1; }
  else
    mkdir -p "$cache_dir"
    CACHE_STAGE=$(mktemp "$cache_dir/.copy-XXXXXXXX")
    cp "$PACKAGE" "$CACHE_STAGE"
    [[ $(file_hash "$CACHE_STAGE") = "$hash" ]] || { echo 'Host package changed while copying.' >&2; exit 1; }
    # Hard-link publishes the verified copy atomically and refuses overwrite.
    ln "$CACHE_STAGE" "$cached_package"
    rm -f -- "$CACHE_STAGE"
    CACHE_STAGE=''
  fi
  PACKAGE=$cached_package
  printf 'Registering durable package: %s\n' "$PACKAGE"
  for name in package.json pnpm-lock.yaml pnpm-workspace.yaml cordis.yml cordis.yaml cordis.patch.yml; do
    backup_file "$DSH_ROOT/profiles/$PROFILE/$name"
  done
  DSH_HOME="$DSH_ROOT" "$DSH_COMMAND" plugin --profile "$PROFILE" add --save-exact "$PACKAGE"
fi
if (( ! SKIP_RUBY )); then
  mkdir -p "$PLUGINS"
  STAGE=$(mktemp -d "$PLUGINS/.dsh-sketchup-stage-XXXXXXXX")
  cp -p "$ROOT/ruby/dsh_sketchup_bridge.rb" "$STAGE/"
  cp -pR "$ROOT/ruby/dsh_sketchup_bridge" "$STAGE/"
  for name in dsh_sketchup_bridge dsh_sketchup_bridge.rb; do
    target="$PLUGINS/$name"
    backup=''
    if [[ -e "$target" || -L "$target" ]]; then
      backup=$(mktemp -d "$target.bak-XXXXXXXX")
      mv "$target" "$backup/original"
      printf 'Backup: %s/original\n' "$backup"
    fi
    if mv "$STAGE/$name" "$target"; then :; else
      code=$?
      if [[ -n "$backup" && ! -e "$target" ]]; then cp -pR "$backup/original" "$target"; fi
      exit "$code"
    fi
  done
fi
echo 'Installation complete. Restart the affected DSH profile and SketchUp to load the bridge.'
