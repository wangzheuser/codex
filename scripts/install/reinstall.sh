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

package_json_version() {
  path="$1"
  [ -f "$path" ] || return 1
  sed -n 's/^[[:space:]]*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$path" | head -n 1
}

cargo_workspace_version() {
  path="$1"
  [ -f "$path" ] || return 1
  awk '
    /^[[:space:]]*\[workspace\.package\][[:space:]]*$/ { in_workspace_package = 1; next }
    in_workspace_package && /^[[:space:]]*\[/ { exit }
    in_workspace_package && /^[[:space:]]*version[[:space:]]*=/ {
      sub(/^[^"]*"/, "")
      sub(/".*/, "")
      print
      exit
    }
  ' "$path"
}

codex_binary_version() {
  path="$1"
  [ -f "$path" ] || return 1
  "$path" --version 2>/dev/null \
    | sed -n 's/.*codex-cli[[:space:]][[:space:]]*\([0-9][0-9A-Za-z.+-]*\).*/\1/p' \
    | head -n 1
}

dev_version_from_version() {
  version="$1"
  [ -n "$version" ] || return 1

  base_version="$(printf '%s\n' "$version" \
    | sed -n 's/.*codex-cli[[:space:]][[:space:]]*\([0-9][0-9A-Za-z.+-]*\).*/\1/p' \
    | head -n 1)"
  if [ -z "$base_version" ]; then
    base_version="$version"
  fi

  base_version="$(printf '%s\n' "$base_version" | sed 's/-dev$//')"
  if [ -z "$base_version" ] || [ "$base_version" = "0.0.0" ]; then
    return 1
  fi

  printf '%s-dev\n' "$base_version"
}

resolve_codex_dev_version() {
  if [ -n "${CODEX_DEV_VERSION:-}" ]; then
    explicit_version="$(printf '%s\n' "$CODEX_DEV_VERSION" \
      | sed -n 's/.*codex-cli[[:space:]][[:space:]]*\([0-9][0-9A-Za-z.+-]*\).*/\1/p' \
      | head -n 1)"
    if [ -n "$explicit_version" ]; then
      printf '%s\n' "$explicit_version"
    else
      printf '%s\n' "$CODEX_DEV_VERSION"
    fi
    return 0
  fi

  if [ -n "${CODEX_DEV_BASE_VERSION:-}" ]; then
    if dev_version="$(dev_version_from_version "$CODEX_DEV_BASE_VERSION")"; then
      printf '%s\n' "$dev_version"
      return 0
    fi
  fi

  candidate="$(cargo_workspace_version "$codex_rs_dir/Cargo.toml" || true)"
  if dev_version="$(dev_version_from_version "$candidate")"; then
    printf '%s\n' "$dev_version"
    return 0
  fi

  candidate="$(package_json_version "$repo_root/codex-cli/package.json" || true)"
  if dev_version="$(dev_version_from_version "$candidate")"; then
    printf '%s\n' "$dev_version"
    return 0
  fi

  if command -v npm >/dev/null 2>&1; then
    npm_root="$(npm root -g 2>/dev/null || true)"
    if [ -n "$npm_root" ]; then
      candidate="$(package_json_version "$npm_root/@openai/codex/package.json" || true)"
      if dev_version="$(dev_version_from_version "$candidate")"; then
        printf '%s\n' "$dev_version"
        return 0
      fi
    fi
  fi

  if command -v codex >/dev/null 2>&1; then
    candidate="$(codex --version 2>/dev/null | head -n 1 || true)"
    if dev_version="$(dev_version_from_version "$candidate")"; then
      printf '%s\n' "$dev_version"
      return 0
    fi
  fi

  for candidate_path in \
    "$HOME/Applications/Codex.app/Contents/Resources/app/bin/codex" \
    "/Applications/Codex.app/Contents/Resources/app/bin/codex"
  do
    candidate="$(codex_binary_version "$candidate_path" || true)"
    if dev_version="$(dev_version_from_version "$candidate")"; then
      printf '%s\n' "$dev_version"
      return 0
    fi
  done

  printf '0.0.0-dev\n'
}

quote_sh() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

write_shim() {
  path="$1"
  extra_arg="$2"
  binary_literal="$(quote_sh "$installed_bin")"
  dev_home_literal="$(quote_sh "$dev_home")"
  extra=""
  if [ -n "$extra_arg" ]; then
    extra=" $(quote_sh "$extra_arg")"
  fi

  cat >"$path" <<EOF
#!/bin/sh
if [ "\$#" -eq 1 ] && { [ "\$1" = "--version" ] || [ "\$1" = "-V" ]; }; then
  echo "codex-cli $dev_version"
  exit 0
fi
export CODEX_HOME=$dev_home_literal
export CODEX_SQLITE_HOME=$dev_home_literal
exec $binary_literal$extra "\$@"
EOF
  chmod 0755 "$path"
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
  CODEX_REINSTALL_PROFILE   Build profile to use.
  CODEX_DEV_VERSION         Exact dev version shown by codex-dev --version.
  CODEX_DEV_BASE_VERSION    Base version used to derive <base>-dev.
  CODEX_DEV_HOME            Dev Codex home. Defaults to ~/.codex-dev.
  CODEX_DEV_INSTALL_ROOT    Dev install root. Defaults to ~/.local/share/codex-dev.
  CODEX_DEV_SHIM_DIR        Shim directory. Defaults to ~/.local/bin.
  CODEX_DEV_SEED_HOME       Source home for initial config copy. Defaults to ~/.codex.
  CARGO_BUILD_JOBS          Optional Cargo parallelism override.
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

if [ "$(uname -s)" != "Darwin" ]; then
  fail "reinstall.sh only supports macOS. Use reinstall.ps1 on Windows."
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

if [ -z "${HOME:-}" ]; then
  fail "HOME is not set."
fi

dev_home="${CODEX_DEV_HOME:-$HOME/.codex-dev}"
install_root="${CODEX_DEV_INSTALL_ROOT:-$HOME/.local/share/codex-dev}"
shim_dir="${CODEX_DEV_SHIM_DIR:-$HOME/.local/bin}"
source_home="${CODEX_DEV_SEED_HOME:-$HOME/.codex}"
install_bin_dir="$install_root/bin"
installed_bin="$install_bin_dir/codex"
source_bin="$codex_rs_dir/target/$build_output_dir/codex"
dev_version="$(resolve_codex_dev_version)"

assert_sqlx_migrations_use_lf

step "Resolved codex-dev version: codex-cli $dev_version"
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

mkdir -p "$dev_home" "$install_bin_dir" "$shim_dir"

timestamp=$(date +%Y%m%d%H%M%S)
if [ -f "$installed_bin" ]; then
  backup_bin="$installed_bin.backup.$timestamp"
  if [ -e "$backup_bin" ]; then
    fail "Backup path already exists: $backup_bin"
  fi

  step "Backing up existing codex-dev binary to $backup_bin"
  cp "$installed_bin" "$backup_bin"
fi

step "Installing codex-dev binary at $installed_bin"
install -m 0755 "$source_bin" "$installed_bin"

for file_name in config.toml auth.json AGENTS.md; do
  source_path="$source_home/$file_name"
  destination_path="$dev_home/$file_name"
  if [ -f "$source_path" ] && [ ! -e "$destination_path" ]; then
    cp "$source_path" "$destination_path"
  fi
done

step "Writing codex-dev and cx-dev shims to $shim_dir"
write_shim "$shim_dir/codex-dev" ""
write_shim "$shim_dir/cx-dev" "--dangerously-bypass-approvals-and-sandbox"

step "Verifying installed codex-dev version"
"$shim_dir/codex-dev" --version
step "Verifying installed cx-dev version"
"$shim_dir/cx-dev" --version
