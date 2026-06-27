#!/bin/sh

set -eu

build_profile="${CODEX_REINSTALL_PROFILE:-dev-small}"

step() {
  printf '==> %s\n' "$1"
}

fail() {
  printf 'ERROR: %s\n' "$1" >&2
  exit 1
}

require_command() {
  command_name="$1"
  if ! command -v "$command_name" >/dev/null 2>&1; then
    fail "Missing required command: $command_name"
  fi
}

assert_sqlx_migrations_use_lf() {
  bad_files=""
  for relative_dir in \
    state/migrations \
    state/logs_migrations \
    state/goals_migrations \
    state/memory_migrations
  do
    dir="$codex_rs_dir/$relative_dir"
    [ -d "$dir" ] || continue
    for file in "$dir"/*.sql; do
      [ -f "$file" ] || continue
      if LC_ALL=C grep "$(printf '\r')" "$file" >/dev/null; then
        bad_files="${bad_files}${file}
"
      fi
    done
  done

  if [ -n "$bad_files" ]; then
    printf 'ERROR: SQLx migration files must use LF line endings before building Codex.\n' >&2
    printf 'CRLF changes migration checksums and can make local SQLite DBs fail to open after reinstall.\n' >&2
    printf 'Normalize these files and rerun the script:\n%s' "$bad_files" >&2
    exit 1
  fi
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --profile)
        if [ "$#" -lt 2 ]; then
          fail "--profile requires a value"
        fi
        build_profile="$2"
        shift
        ;;
      --release)
        build_profile="release"
        ;;
      --help|-h)
        cat <<EOF
Usage: reinstall.sh [--profile PROFILE] [--release]

Defaults:
  PROFILE defaults to dev-small for faster local rebuilds.

Environment:
  CODEX_REINSTALL_PROFILE  Build profile to use.
  CARGO_BUILD_JOBS         Optional Cargo parallelism override.
EOF
        exit 0
        ;;
      *)
        fail "Unknown argument: $1"
        ;;
    esac
    shift
  done
}

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
codex_rs_dir="$repo_root/codex-rs"

parse_args "$@"

if [ ! -d "$codex_rs_dir" ]; then
  fail "Could not find codex-rs workspace at: $codex_rs_dir"
fi

require_command cargo
require_command npm

if [ "$(uname -s)" != "Darwin" ]; then
  fail "reinstall.sh only supports macOS. Use reinstall.ps1 on Windows."
fi

case "$(uname -m)" in
  arm64)
    platform_package="codex-darwin-arm64"
    target_triple="aarch64-apple-darwin"
    ;;
  x86_64)
    platform_package="codex-darwin-x64"
    target_triple="x86_64-apple-darwin"
    ;;
  *)
    fail "Unsupported macOS architecture: $(uname -m)"
    ;;
esac

npm_root=$(npm root -g 2>/dev/null) || fail "Failed to resolve npm global root. Is npm installed correctly?"
if [ -z "$npm_root" ]; then
  fail "npm global root is empty."
fi

case "$build_profile" in
  release)
    build_output_dir="release"
    ;;
  dev)
    build_output_dir="debug"
    ;;
  *)
    build_output_dir="$build_profile"
    ;;
esac

codex_package_root="$npm_root/@openai/codex"
platform_package_root="$codex_package_root/node_modules/@openai/$platform_package"
installed_bin="$platform_package_root/vendor/$target_triple/bin/codex"
source_bin="$codex_rs_dir/target/$build_output_dir/codex"

if [ ! -d "$codex_package_root" ]; then
  fail "Global @openai/codex package not found at: $codex_package_root. Install it with: npm install -g @openai/codex"
fi

if [ ! -d "$platform_package_root" ]; then
  fail "Platform package not found at: $platform_package_root. Reinstall Codex with: npm install -g @openai/codex"
fi

if [ ! -f "$installed_bin" ]; then
  fail "Installed Codex binary not found at: $installed_bin"
fi

assert_sqlx_migrations_use_lf

step "Building codex-cli with Cargo profile: $build_profile"
(
  cd "$codex_rs_dir"
  case "$build_profile" in
    release)
      cargo build --locked -p codex-cli --release
      ;;
    dev)
      cargo build --locked -p codex-cli
      ;;
    *)
      cargo build --locked -p codex-cli --profile "$build_profile"
      ;;
  esac
)

if [ ! -f "$source_bin" ]; then
  fail "Build did not produce expected binary: $source_bin"
fi

timestamp=$(date +%Y%m%d%H%M%S)
backup_bin="$installed_bin.backup.$timestamp"

if [ -e "$backup_bin" ]; then
  fail "Backup path already exists: $backup_bin"
fi

step "Backing up installed binary to $backup_bin"
cp "$installed_bin" "$backup_bin"

step "Replacing installed binary at $installed_bin"
install -m 0755 "$source_bin" "$installed_bin"

step "Verifying installed Codex version"
codex --version
