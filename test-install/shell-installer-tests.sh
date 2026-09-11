#!/usr/bin/env bash
set -euo pipefail
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TEST=$(mktemp -d "${TMPDIR:-/tmp}/shell installer.XXXXXXXX")
mkdir -p "$TEST/source/ruby/dsh_sketchup_bridge" "$TEST/source/lib" "$TEST/bin" "$TEST/home/profiles/test"
cp "$ROOT/ruby/dsh_sketchup_bridge.rb" "$TEST/source/ruby/"
cp "$ROOT/ruby/dsh_sketchup_bridge/"{main,setup}.rb "$TEST/source/ruby/dsh_sketchup_bridge/"
printf '{"name":"@leolee9086/dsh-sketchup"}\n' > "$TEST/source/package.json"
printf 'built\n' > "$TEST/source/lib/index.js"
printf 'original\n' > "$TEST/home/profiles/test/cordis.patch.yml"
printf 'release package\n' > "$TEST/source/leolee9086-dsh-sketchup-0.1.0-alpha.1.tgz"
cat > "$TEST/bin/mock dsh" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$INSTALL_TEST_LOG"
printf '%s\n' "$DSH_HOME" >> "$INSTALL_TEST_LOG"
exit "${INSTALL_TEST_EXIT:-0}"
MOCK
cat > "$TEST/bin/npm" <<'MOCK'
#!/usr/bin/env bash
[[ "$1" = pack && "$2" = --ignore-scripts && "$3" = --pack-destination ]] || exit 91
printf 'packed source\n' > "$4/source.tgz"
MOCK
cat > "$TEST/bin/pnpm" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$INSTALL_BUILD_LOG"
if [[ "$1" = run ]]; then printf 'built source\n' > lib/index.js; fi
MOCK
chmod +x "$TEST/bin/"*
export PATH="$TEST/bin:$PATH"
export INSTALL_TEST_LOG="$TEST/cli.log"
export INSTALL_BUILD_LOG="$TEST/build.log"
run() { bash "$ROOT/install.sh" --source-root "$TEST/source" --plugins-dir "$TEST/plugins space" --dsh-home "$TEST/home" --dsh-command "$TEST/bin/mock dsh" --profile test "$@"; }
before=$(find "$TEST" -type f | sort)
run --dry-run
[[ $(find "$TEST" -type f | sort) = "$before" && ! -f "$INSTALL_TEST_LOG" ]]
run
[[ -f "$TEST/plugins space/dsh_sketchup_bridge/setup.rb" ]]
mapfile -t args < "$INSTALL_TEST_LOG"
[[ "${args[0]}|${args[1]}|${args[2]}|${args[3]}|${args[4]}" = 'plugin|--profile|test|add|--save-exact' ]]
[[ "${args[5]}" = "$TEST/home/packages/dsh-sketchup/"* && -f "${args[5]}" && "${args[6]}" = "$TEST/home" ]]
printf 'sentinel\n' > "$TEST/plugins space/dsh_sketchup_bridge/preserve"
run --skip-host
run --skip-host
[[ $(find "$TEST/plugins space" -type f -name preserve | wc -l) = 1 ]]
[[ $(find "$TEST/plugins space" -type d -name 'dsh_sketchup_bridge.bak-*' | wc -l) = 2 ]]
export INSTALL_TEST_EXIT=31
if run; then echo 'native failure accepted' >&2; exit 1; else [[ $? = 31 ]]; fi
export INSTALL_TEST_EXIT=0
rm "$TEST/source/leolee9086-dsh-sketchup-0.1.0-alpha.1.tgz" "$TEST/source/lib/index.js"
run --skip-ruby
mapfile -t args < "$INSTALL_TEST_LOG"
[[ -f "${args[5]}" ]]
[[ $(cat "${args[5]}") = 'packed source' ]]
grep -q '^install --frozen-lockfile --ignore-scripts$' "$INSTALL_BUILD_LOG"
printf '{"name":"@leolee9086/dsh-sketchup","scripts":{"prepare":"exit 99"}}\n' > "$TEST/source/package.json"
if run --skip-ruby; then echo 'prepare manifest accepted' >&2; exit 1; else [[ $? = 1 ]]; fi
printf 'PASS: Bash source/release, durable cache, backups, dry-run and native errors. Artifacts: %s\n' "$TEST"
