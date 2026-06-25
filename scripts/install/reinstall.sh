#!/bin/sh

set -eu

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

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
codex_rs_dir="$repo_root/codex-rs"

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

codex_package_root="$npm_root/@openai/codex"
platform_package_root="$codex_package_root/node_modules/@openai/$platform_package"
installed_bin="$platform_package_root/vendor/$target_triple/bin/codex"
source_bin="$codex_rs_dir/target/release/codex"

if [ ! -d "$codex_package_root" ]; then
  fail "Global @openai/codex package not found at: $codex_package_root. Install it with: npm install -g @openai/codex"
fi

if [ ! -d "$platform_package_root" ]; then
  fail "Platform package not found at: $platform_package_root. Reinstall Codex with: npm install -g @openai/codex"
fi

if [ ! -f "$installed_bin" ]; then
  fail "Installed Codex binary not found at: $installed_bin"
fi

step "Building codex-cli release binary"
(
  cd "$codex_rs_dir"
  CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-1}" cargo build --locked -p codex-cli --release
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
