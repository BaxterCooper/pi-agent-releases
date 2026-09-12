#!/bin/bash
set -euo pipefail
export LC_ALL=C

# Generated source: BaxterCooper/pi-agent apps/desktop/bootstrap/install.sh. The
# desktop release workflow publishes this file to BaxterCooper/pi-agent-releases.
API_ROOT='https://api.github.com/repos/BaxterCooper/pi-agent-releases'
# Assets are published under exactly this prefix plus the tag.
DOWNLOAD_PREFIX='https://github.com/BaxterCooper/pi-agent-releases/releases/download'
MAX_DOWNLOAD_BYTES=536870912

# Trust anchor. The release workflow rewrites the table below when it mirrors
# this file to BaxterCooper/pi-agent-releases, so the copy a user runs carries
# the SHA-256 of every asset of every release it can install. The published
# `.sha256` sidecar travels with the installer and is only a secondary
# consistency check; it cannot attest to the installer it accompanies.
# BEGIN PINNED
# v0.3.3 OMP.Agent.app.tar.gz 097b1ce49e65a6f212ce822129548f1f6d46c66de04a2e59f1589d03ec5c32e3
# v0.3.3 OMP.Agent.app.tar.gz.sig d146856b5a152e07edfcda6bc99ce11bf6a14f989827d5977bdde127e6790dca
# v0.3.3 OMP.Agent_0.3.3_aarch64.dmg 435b92c485f6e42582999169ade34ea3b7ad32ac3d9051f16b3f7029dc7a0740
# v0.3.3 OMP.Agent_0.3.3_aarch64.dmg.sha256 324a27f088849c142f2b057ce9059ca42d3d6f8759d1196ea3e7ce7038ad2806
# v0.3.3 OMP.Agent_0.3.3_x64-setup.exe 8fe8777c4d3d8b1ab61c31074820123c0732fe9a1a3d49eed8af5bd466544a35
# v0.3.3 OMP.Agent_0.3.3_x64-setup.exe.sha256 e2babee57883a3b2767ecaccb2fcbb97cbc9f9ac2f11961c6a04bb0d6f9d05cb
# v0.3.3 OMP.Agent_0.3.3_x64-setup.exe.sig 894b036783a59d851e022ad49f27c8ddbbb580eb962e969151aaa931f256fd94
# END PINNED
BUNDLE_ID='dev.baxter.pi-agent'
# Bundle names installed by earlier bootstraps under the same bundle identifier.
LEGACY_APP_NAMES=('Pi Agent.app')
# The app bundles no Bun and no OMP: it runs the bundled engine with the user's
# Bun against their global `@oh-my-pi/pi-coding-agent`, and fails to launch
# without both (`src-tauri/src/omp_install.rs`). The bootstrap provisions them.
# OMP_RANGE mirrors the `@oh-my-pi/pi-coding-agent` dependency in
# `packages/engine/package.json`; the two must stay equal.
OMP_PACKAGE='@oh-my-pi/pi-coding-agent'
OMP_RANGE='^18.1.17'
BUN_INSTALLER_URL='https://bun.sh/install'
BUN_BIN=''
ACTION='install'
CHANNEL='stable'
ALLOW_DOWNGRADE=0
TEMP_ROOT=''
MOUNT_ROOT=''
ATTACH_PLIST=''
INSTALLER_PATH=''
SIDECAR_PATH=''
DMG_PATH=''
SOURCE_APP=''
APP_DIR=''
TARGET_APP=''
STAGE_DIR=''
BACKUP_DIR=''
BACKUP_APP=''
RELEASE_VERSION=''
RELEASE_INSTALLER_NAME=''
RELEASE_INSTALLER_SIZE=''
RELEASE_INSTALLER_URL=''
RELEASE_SIDECAR_URL=''
TARGET_MOVED_TO_BACKUP=0
TARGET_INSTALLED=0
MOUNT_POINTS=()
APP_CANDIDATES=()

fail() {
  printf 'OMP Agent bootstrap: %s\n' "$*" >&2
  exit 1
}

usage() {
  printf '%s\n' \
    'Usage: install.sh [--allow-downgrade] [install [stable|latest|VERSION] | uninstall | status]' \
    '' \
    'Install is the default action. VERSION must be an exact semantic version such as 1.2.3.' \
    '--allow-downgrade replaces a newer installed bundle with an older release.'
}

cleanup() {
  local status=$?
  local index
  local backup_preserved=0
  trap - EXIT INT TERM

  if [ "${#MOUNT_POINTS[@]}" -gt 0 ]; then
    index=$((${#MOUNT_POINTS[@]} - 1))
    while [ "$index" -ge 0 ]; do
      if [ -n "$MOUNT_ROOT" ] && validate_mount_point "${MOUNT_POINTS[$index]}"; then
        /usr/bin/hdiutil detach "${MOUNT_POINTS[$index]}" -force >/dev/null 2>&1 || true
      fi
      index=$((index - 1))
    done
  fi

  if [ "$TARGET_MOVED_TO_BACKUP" -eq 1 ]; then
    if [ ! -e "$TARGET_APP" ] && [ ! -L "$TARGET_APP" ] \
      && [ -n "$BACKUP_APP" ] && { [ -e "$BACKUP_APP" ] || [ -L "$BACKUP_APP" ]; }; then
      if /bin/mv "$BACKUP_APP" "$TARGET_APP" >/dev/null 2>&1; then
        TARGET_MOVED_TO_BACKUP=0
      else
        backup_preserved=1
      fi
    else
      backup_preserved=1
    fi
  fi

  if [ -n "$STAGE_DIR" ] && [ -e "$STAGE_DIR" ]; then
    /bin/rm -rf "$STAGE_DIR" >/dev/null 2>&1 || true
  fi
  if [ -n "$BACKUP_DIR" ] && [ -e "$BACKUP_DIR" ]; then
    if [ "$TARGET_MOVED_TO_BACKUP" -eq 0 ]; then
      /bin/rm -rf "$BACKUP_DIR" >/dev/null 2>&1 || true
    else
      backup_preserved=1
    fi
  fi
  if [ "$backup_preserved" -eq 1 ] && [ -n "$BACKUP_DIR" ]; then
    printf 'OMP Agent bootstrap: previous app backup preserved at %s; restore it manually after resolving the failure.\n' "$BACKUP_DIR" >&2
  fi
  if [ -n "$TEMP_ROOT" ] && [ -e "$TEMP_ROOT" ]; then
    /bin/rm -rf "$TEMP_ROOT" >/dev/null 2>&1 || true
  fi

  exit "$status"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

assert_user_context() {
  if [ "${EUID:-1}" -eq 0 ] || [ -n "${SUDO_UID:-}" ] || [ -n "${SUDO_USER:-}" ] || [ -n "${SUDO_COMMAND:-}" ]; then
    fail 'Do not run this bootstrap as root or through sudo; it installs only for the invoking user.'
  fi
  if [ -z "${HOME:-}" ] || [ "${HOME#/}" = "$HOME" ] || [ "$HOME" = '/' ]; then
    fail 'HOME must be an absolute non-root user directory.'
  fi
  case "$HOME" in
    *$'\r'*|*$'\n'*) fail 'HOME contained control characters.' ;;
  esac
  APP_DIR="$HOME/Applications"
  TARGET_APP="$APP_DIR/OMP Agent.app"
}

assert_supported_macos_arm64() {
  local operating_system
  local machine_architecture
  local translated='0'

  if ! operating_system=$(/usr/bin/uname -s 2>/dev/null); then
    fail 'Could not determine the operating system.'
  fi
  if [ "$operating_system" != 'Darwin' ]; then
    fail 'This bootstrap supports macOS Apple Silicon only.'
  fi
  if ! machine_architecture=$(/usr/bin/uname -m 2>/dev/null); then
    fail 'Could not determine the machine architecture.'
  fi
  if [ "$machine_architecture" = 'x86_64' ]; then
    if translated=$(/usr/sbin/sysctl -in sysctl.proc_translated 2>/dev/null); then
      :
    else
      translated='0'
    fi
  fi
  if [ "$machine_architecture" != 'arm64' ] \
    && { [ "$machine_architecture" != 'x86_64' ] || [ "$translated" != '1' ]; }; then
    fail 'This bootstrap supports macOS ARM64 only; Intel macOS is unsupported.'
  fi
}

parse_args() {
  local positional=()
  local argument

  for argument in "$@"; do
    case "$argument" in
      --allow-downgrade)
        ALLOW_DOWNGRADE=1
        ;;
      -*)
        usage >&2
        fail "Unknown option '$argument'."
        ;;
      *)
        positional[${#positional[@]}]=$argument
        ;;
    esac
  done
  set -- ${positional+"${positional[@]}"}
  case "$#" in
    0)
      ACTION='install'
      CHANNEL='stable'
      ;;
    1)
      ACTION=$1
      case "$ACTION" in
        install)
          CHANNEL='stable'
          ;;
        uninstall|status)
          ;;
        *)
          usage >&2
          fail "Unknown action '$ACTION'."
          ;;
      esac
      ;;
    2)
      ACTION=$1
      if [ "$ACTION" != 'install' ]; then
        usage >&2
        fail 'Only install accepts a channel or exact version.'
      fi
      CHANNEL=$2
      ;;
    *)
      usage >&2
      fail 'Too many arguments.'
      ;;
  esac
}

SEMVER_RE='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-(0|[1-9][0-9]*|[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*)(\.(0|[1-9][0-9]*|[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*))*)?(\+[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$'

is_semver() {
  [ "$#" -eq 1 ] && [[ "$1" =~ $SEMVER_RE ]]
}

# Compare two semantic versions. Prints -1, 0 or 1 when the left version is
# lower than, equal to or higher than the right one. Build metadata is ignored
# and a prerelease sorts below the release that carries the same core version.
semver_compare() {
  local left=${1%%+*}
  local right=${2%%+*}
  local left_core=${left%%-*}
  local right_core=${right%%-*}
  local left_pre=''
  local right_pre=''
  local l1 l2 l3 r1 r2 r3
  local left_field right_field
  local index=1

  case "$left" in *-*) left_pre=${left#*-} ;; esac
  case "$right" in *-*) right_pre=${right#*-} ;; esac
  IFS='.' read -r l1 l2 l3 <<< "$left_core"
  IFS='.' read -r r1 r2 r3 <<< "$right_core"
  for index in "$l1:$r1" "$l2:$r2" "$l3:$r3"; do
    left_field=${index%%:*}
    right_field=${index#*:}
    if [ "$left_field" -lt "$right_field" ]; then
      printf '%s\n' '-1'
      return 0
    fi
    if [ "$left_field" -gt "$right_field" ]; then
      printf '%s\n' '1'
      return 0
    fi
  done
  if [ -z "$left_pre" ] && [ -z "$right_pre" ]; then
    printf '%s\n' '0'
    return 0
  fi
  if [ -z "$left_pre" ]; then
    printf '%s\n' '1'
    return 0
  fi
  if [ -z "$right_pre" ]; then
    printf '%s\n' '-1'
    return 0
  fi
  prerelease_compare "$left_pre" "$right_pre"
}

# SemVer 11.4: prerelease identifiers compare field by field; numeric fields
# compare numerically, alphanumeric fields in ASCII order, a numeric field sorts
# below an alphanumeric one, and a longer identifier list wins a shared prefix.
prerelease_compare() {
  local left_rest=$1
  local right_rest=$2
  local left_field right_field left_numeric right_numeric left_value right_value

  while [ -n "$left_rest" ] || [ -n "$right_rest" ]; do
    if [ -z "$left_rest" ]; then
      printf '%s\n' '-1'
      return 0
    fi
    if [ -z "$right_rest" ]; then
      printf '%s\n' '1'
      return 0
    fi
    left_field=${left_rest%%.*}
    right_field=${right_rest%%.*}
    case "$left_rest" in *.*) left_rest=${left_rest#*.} ;; *) left_rest='' ;; esac
    case "$right_rest" in *.*) right_rest=${right_rest#*.} ;; *) right_rest='' ;; esac
    if [ "$left_field" = "$right_field" ]; then
      continue
    fi
    left_numeric=1
    right_numeric=1
    case "$left_field" in ''|*[!0-9]*) left_numeric=0 ;; esac
    case "$right_field" in ''|*[!0-9]*) right_numeric=0 ;; esac
    if [ "$left_numeric" -eq 1 ] && [ "$right_numeric" -eq 1 ]; then
      left_value=$(normalize_decimal "$left_field")
      right_value=$(normalize_decimal "$right_field")
      if [ "$left_value" -eq "$right_value" ]; then
        continue
      fi
      if [ "$left_value" -lt "$right_value" ]; then
        printf '%s\n' '-1'
      else
        printf '%s\n' '1'
      fi
      return 0
    fi
    if [ "$left_numeric" -eq 1 ]; then
      printf '%s\n' '-1'
      return 0
    fi
    if [ "$right_numeric" -eq 1 ]; then
      printf '%s\n' '1'
      return 0
    fi
    if [ "$left_field" \< "$right_field" ]; then
      printf '%s\n' '-1'
    else
      printf '%s\n' '1'
    fi
    return 0
  done
  printf '%s\n' '0'
}

# The launcher's own search order (`omp_install.rs:67-78`): `$BUN_INSTALL/bin`
# first, because a GUI launch inherits a PATH that often predates the install.
find_bun() {
  local candidate

  for candidate in ${BUN_INSTALL:+"$BUN_INSTALL/bin/bun"} "$HOME/.bun/bin/bun" '/opt/homebrew/bin/bun' '/usr/local/bin/bun'; do
    if [ -x "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  if candidate=$(command -v bun 2>/dev/null) && [ -x "$candidate" ]; then
    printf '%s\n' "$candidate"
    return 0
  fi
  return 1
}

# The global root the launcher links the engine against
# (`omp_install.rs:117-130`), read straight from the installed manifest.
installed_omp_version() {
  local root
  local manifest
  local version

  for root in ${BUN_INSTALL:+"$BUN_INSTALL"} "$HOME/.bun" "${BUN_BIN%/bin/bun}"; do
    manifest="$root/install/global/node_modules/$OMP_PACKAGE/package.json"
    [ -f "$manifest" ] || continue
    version=$(/usr/bin/awk -F'"' '/"version"[[:space:]]*:/ { print $4; exit }' "$manifest")
    if is_semver "$version"; then
      printf '%s\n' "$version"
      return 0
    fi
  done
  return 1
}

# `^MAJOR.MINOR.PATCH`: at or above the pin and below the next major.
omp_version_satisfies() {
  local version=$1
  local minimum=${OMP_RANGE#^}

  [ "${version%%.*}" = "${minimum%%.*}" ] || return 1
  [ "$(semver_compare "$version" "$minimum")" != '-1' ]
}

# Idempotent: an existing Bun and an in-range OMP are left exactly as they are.
install_launch_prerequisites() {
  local version=''

  if ! BUN_BIN=$(find_bun); then
    printf 'OMP Agent bootstrap: installing Bun, which the app launcher requires.\n'
    if ! /usr/bin/curl -fsSL --proto '=https' --tlsv1.2 "$BUN_INSTALLER_URL" | /bin/bash; then
      fail "Could not install Bun from $BUN_INSTALLER_URL; install Bun and re-run."
    fi
    if ! BUN_BIN=$(find_bun); then
      fail 'Bun is still not installed; install Bun and re-run.'
    fi
  fi
  if version=$(installed_omp_version) && omp_version_satisfies "$version"; then
    return 0
  fi
  printf 'OMP Agent bootstrap: installing %s@%s, which the app launcher requires.\n' "$OMP_PACKAGE" "$OMP_RANGE"
  if ! "$BUN_BIN" add -g "$OMP_PACKAGE@$OMP_RANGE"; then
    fail "Could not install $OMP_PACKAGE@$OMP_RANGE; run 'bun add -g $OMP_PACKAGE@$OMP_RANGE' and re-run."
  fi
  if ! version=$(installed_omp_version) || ! omp_version_satisfies "$version"; then
    fail "$OMP_PACKAGE@$OMP_RANGE is not installed under the Bun global root; the app cannot start without it."
  fi
}

# An install that replaces a newer bundle silently loses features and state
# formats. Refuse it unless the caller asked for the downgrade explicitly.
assert_not_downgrade() {
  local installed

  if ! installed=$(bundle_version "$TARGET_APP" 2>/dev/null); then
    return 0
  fi
  if ! is_semver "$installed"; then
    printf 'OMP Agent bootstrap: installed version %s is not a semantic version; skipping the downgrade check.\n' \
      "$installed" >&2
    return 0
  fi
  if [ "$(semver_compare "$RELEASE_VERSION" "$installed")" -ge 0 ]; then
    return 0
  fi
  if [ "$ALLOW_DOWNGRADE" -eq 1 ]; then
    printf 'Downgrading OMP Agent from version %s to %s as requested.\n' "$installed" "$RELEASE_VERSION"
    return 0
  fi
  fail "Release version $RELEASE_VERSION is older than the installed version $installed; pass --allow-downgrade to replace it."
}

normalize_decimal() {
  local value=$1
  while [ "${#value}" -gt 1 ] && [ "${value#0}" != "$value" ]; do
    value=${value#0}
  done
  printf '%s' "$value"
}

# A prefix match alone is not a pin: `.../download/v1.2.3/../../other/asset` and
# its percent-encoded spellings still start with the prefix but resolve
# elsewhere. Require the remainder to be exactly one literal asset segment.
assert_pinned_url() {
  local url=$1
  local prefix=$2
  local label=$3
  local remainder
  local after_scheme

  case "$url" in
    "$prefix"*) ;;
    *) fail "$label was not published under $prefix." ;;
  esac
  after_scheme=${url#*://}
  case "$after_scheme" in
    *..*|*//*) fail "$label contained a path traversal or an empty path segment." ;;
  esac
  case "$url" in
    *%2e*|*%2E*|*%2f*|*%2F*) fail "$label contained a percent-encoded path separator." ;;
  esac
  remainder=${url#"$prefix"}
  case "$remainder" in
    ''|*[!A-Za-z0-9._-]*) fail "$label did not resolve to a single asset name under $prefix." ;;
  esac
}

assert_https_url() {
  local url=$1
  local label=$2
  local authority

  case "$url" in
    https://*) ;;
    *) fail "$label was not an HTTPS URL." ;;
  esac
  authority=${url#https://}
  authority=${authority%%/*}
  case "$authority" in
    ''|*'@'*|*'?'*|*'#'*|*$'\r'*|*$'\n'*|*$'\t'*)
      fail "$label had an invalid HTTPS authority."
      ;;
  esac
}

# plutil -lint validates property lists only; on macOS 26 it rejects every JSON
# document, and an XML conversion rejects JSON null (GitHub emits null labels
# and bodies). A JSON-to-JSON conversion parses exactly what extract_raw parses.
assert_json_document() {
  local document=$1
  [ -f "$document" ] && /usr/bin/plutil -convert json -o /dev/null "$document" >/dev/null 2>&1
}

extract_raw() {
  local key=$1
  local plist=$2
  /usr/bin/plutil -extract "$key" raw -o - "$plist"
}

# `plutil -extract` prints an array's element count in raw mode, so one call per
# document replaces the per-index probe that used to run plutil once per element.
# A build that does not report a count falls back to that probe.
array_count() {
  local key=$1
  local plist=$2
  local count

  if ! count=$(extract_raw "$key" "$plist" 2>/dev/null); then
    printf '%s\n' 'unknown'
    return 0
  fi
  case "$count" in
    ''|*[!0-9]*) printf '%s\n' 'unknown' ;;
    *) printf '%s\n' "$count" ;;
  esac
}

array_has_index() {
  local key=$1
  local index=$2
  local plist=$3
  local total=$4

  if [ "$total" = 'unknown' ]; then
    /usr/bin/plutil -extract "$key.$index" xml1 -o /dev/null "$plist" >/dev/null 2>&1
    return
  fi
  [ "$index" -lt "$total" ]
}

api_get() {
  local url=$1
  local destination=$2
  assert_https_url "$url" 'GitHub API URL'
  if ! /usr/bin/curl --fail --silent --show-error --location \
    --proto '=https' --proto-redir '=https' \
    --connect-timeout 20 --max-time 120 --retry 2 --retry-delay 1 \
    -H 'Accept: application/vnd.github+json' \
    -H 'User-Agent: pi-agent-bootstrap/1.0' \
    -o "$destination" "$url"; then
    fail "HTTPS request to '$url' failed."
  fi
}

resolve_release() {
  local endpoint
  local release_json="$TEMP_ROOT/release.json"
  local tag
  local version
  local draft
  local published_at
  local asset_index=0
  local asset_total
  local asset_count=0
  local asset_name
  local installer_count=0
  local installer_index=-1
  local installer_name=''
  local installer_size_raw
  local sidecar_name
  local sidecar_count=0
  local sidecar_index=-1
  local record
  local record_index

  case "$CHANNEL" in
    stable|latest)
      endpoint="$API_ROOT/releases/latest"
      ;;
    *)
      if ! is_semver "$CHANNEL"; then
        fail 'Channel must be stable, latest, or an exact semantic version such as 1.2.3.'
      fi
      endpoint="$API_ROOT/releases/tags/v$CHANNEL"
      ;;
  esac

  api_get "$endpoint" "$release_json"
  if ! assert_json_document "$release_json"; then
    fail 'GitHub Releases returned malformed JSON.'
  fi
  if ! tag=$(extract_raw 'tag_name' "$release_json" 2>/dev/null); then
    fail 'The selected GitHub release did not contain a tag name.'
  fi
  if ! draft=$(extract_raw 'draft' "$release_json" 2>/dev/null); then
    fail 'The selected GitHub release did not contain draft metadata.'
  fi
  if [ "$draft" != 'false' ]; then
    fail 'The selected GitHub release was not a published, non-draft release.'
  fi
  if ! published_at=$(extract_raw 'published_at' "$release_json" 2>/dev/null); then
    fail 'The selected GitHub release did not contain publication metadata.'
  fi
  if [ -z "$published_at" ]; then
    fail 'The selected GitHub release did not contain publication metadata.'
  fi

  case "$tag" in
    v?*) version=${tag#v} ;;
    *) fail "Release tag '$tag' was not a supported semantic version tag." ;;
  esac
  if ! is_semver "$version"; then
    fail "Release tag '$tag' was not a supported semantic version tag."
  fi
  case "$CHANNEL" in
    stable|latest) ;;
    *)
      if [ "$tag" != "v$CHANNEL" ]; then
        fail "GitHub returned tag '$tag' instead of the requested tag 'v$CHANNEL'."
      fi
      ;;
  esac

  asset_index=0
  asset_total=$(array_count 'assets' "$release_json")
  while array_has_index 'assets' "$asset_index" "$release_json" "$asset_total"; do
    if ! asset_name=$(extract_raw "assets.$asset_index.name" "$release_json" 2>/dev/null); then
      fail "Release asset $asset_index did not contain a name."
    fi
    case "$asset_name" in
      ''|*'/'*|*"\\"*|*$'\r'*|*$'\n'*|*$'\t'*)
        fail 'A release asset had an invalid name.'
        ;;
    esac
    asset_names[$asset_count]=$asset_name
    asset_indices[$asset_count]=$asset_index
    asset_count=$((asset_count + 1))
    case "$asset_name" in
      *_aarch64.dmg)
        installer_count=$((installer_count + 1))
        installer_index=$asset_index
        installer_name=$asset_name
        ;;
    esac
    asset_index=$((asset_index + 1))
  done
  if [ "$asset_count" -eq 0 ]; then
    fail 'The selected GitHub release did not contain any assets.'
  fi
  if [ "$installer_count" -ne 1 ]; then
    fail "Expected exactly one macOS ARM64 DMG asset, found $installer_count."
  fi

  sidecar_name="$installer_name.sha256"
  record=0
  while [ "$record" -lt "$asset_count" ]; do
    record_index=${asset_indices[$record]}
    if [ "${asset_names[$record]}" = "$sidecar_name" ]; then
      sidecar_count=$((sidecar_count + 1))
      sidecar_index=$record_index
    fi
    record=$((record + 1))
  done
  if [ "$sidecar_count" -ne 1 ]; then
    fail "Expected exactly one checksum sidecar named '$sidecar_name', found $sidecar_count."
  fi

  if ! RELEASE_INSTALLER_URL=$(extract_raw "assets.$installer_index.browser_download_url" "$release_json" 2>/dev/null); then
    fail "Installer asset '$installer_name' did not contain a download URL."
  fi
  if ! RELEASE_SIDECAR_URL=$(extract_raw "assets.$sidecar_index.browser_download_url" "$release_json" 2>/dev/null); then
    fail "Checksum sidecar '$sidecar_name' did not contain a download URL."
  fi
  assert_https_url "$RELEASE_INSTALLER_URL" "Installer asset '$installer_name'"
  assert_https_url "$RELEASE_SIDECAR_URL" "Checksum sidecar '$sidecar_name'"

  if ! installer_size_raw=$(extract_raw "assets.$installer_index.size" "$release_json" 2>/dev/null); then
    fail "Installer asset '$installer_name' did not contain a declared size."
  fi
  case "$installer_size_raw" in
    ''|*[!0-9]*) fail "Installer asset '$installer_name' had an invalid declared size." ;;
  esac
  RELEASE_INSTALLER_SIZE=$(normalize_decimal "$installer_size_raw")
  if [ "$RELEASE_INSTALLER_SIZE" = '0' ]; then
    fail "Installer asset '$installer_name' had a non-positive declared size."
  fi

  RELEASE_VERSION=$version
  RELEASE_INSTALLER_NAME=$installer_name

  # Only the release contract's own prefix for this exact tag is acceptable; a
  # substituted host in the release JSON is not this release.
  local expected_prefix="$DOWNLOAD_PREFIX/v$RELEASE_VERSION/"
  assert_pinned_url "$RELEASE_INSTALLER_URL" "$expected_prefix" "Installer asset '$installer_name'"
  assert_pinned_url "$RELEASE_SIDECAR_URL" "$expected_prefix" "Checksum sidecar '$sidecar_name'"
  if [ "$RELEASE_INSTALLER_SIZE" -gt "$MAX_DOWNLOAD_BYTES" ]; then
    fail "Installer asset '$installer_name' declares $RELEASE_INSTALLER_SIZE bytes, above the $MAX_DOWNLOAD_BYTES byte ceiling."
  fi
}

download_file() {
  local url=$1
  local destination=$2
  local label=$3
  assert_https_url "$url" "$label"
  if ! /usr/bin/curl --fail --silent --show-error --location \
    --proto '=https' --proto-redir '=https' \
    --connect-timeout 20 --max-time 900 --retry 2 --retry-delay 1 \
    --max-filesize "$MAX_DOWNLOAD_BYTES" \
    -o "$destination" "$url"; then
    fail "HTTPS download of $label failed."
  fi
}

verify_download_size() {
  local path=$1
  local expected=$2
  local label=$3
  local actual

  if [ ! -f "$path" ]; then
    fail "$label was not downloaded as a regular file."
  fi
  if ! actual=$(/usr/bin/stat -f%z "$path" 2>/dev/null); then
    fail "Could not determine the downloaded size of $label."
  fi
  case "$actual" in
    ''|*[!0-9]*) fail "Could not determine the downloaded size of $label." ;;
  esac
  if [ "$(normalize_decimal "$actual")" != "$(normalize_decimal "$expected")" ]; then
    fail "Downloaded size $actual for $label did not match the release-declared size $expected."
  fi
}

verify_pinned_asset() {
  local path=$1
  local asset=$2
  local tag="v$RELEASE_VERSION"
  local self=${BASH_SOURCE[0]}
  local expected
  local checksum_line
  local digest

  if [ ! -f "$self" ]; then
    fail 'Could not read this script to load its pinned release table.'
  fi
  expected=$(/usr/bin/awk -v tag="$tag" -v asset="$asset" '
    $0 == "# BEGIN PINNED" { inside = 1; next }
    $0 == "# END PINNED" { inside = 0 }
    inside && NF == 4 && $1 == "#" && $2 == tag && $3 == asset { print $4; exit }
  ' "$self")
  case "$expected" in
    '') fail "Release $tag pins no SHA-256 for '$asset' in this script; refusing to install an unpinned build." ;;
  esac
  if [ "${#expected}" -ne 64 ]; then
    fail "The pinned entry for '$asset' in $tag is malformed."
  fi
  case "$expected" in
    *[!0-9a-f]*) fail "The pinned entry for '$asset' in $tag is malformed." ;;
  esac
  if ! checksum_line=$(/usr/bin/shasum -a 256 "$path" 2>/dev/null); then
    fail "Could not compute the SHA-256 digest of '$asset'."
  fi
  digest=${checksum_line%% *}
  if [ "$digest" != "$expected" ]; then
    fail "The downloaded '$asset' did not match the SHA-256 pinned for $tag."
  fi
}

verify_checksum_sidecar() {
  local checksum_line
  local digest
  local expected_line
  local sidecar_line
  local sidecar_size
  local expected_size

  if ! checksum_line=$(/usr/bin/shasum -a 256 "$INSTALLER_PATH" 2>/dev/null); then
    fail 'Could not compute the installer SHA-256 digest.'
  fi
  digest=${checksum_line%% *}
  if [ "${#digest}" -ne 64 ]; then
    fail 'Could not compute a valid SHA-256 digest for the installer.'
  fi
  case "$digest" in
    ''|*[!0-9a-f]*) fail 'The installer digest was not lowercase hexadecimal SHA-256.' ;;
  esac

  expected_line="$digest  $RELEASE_INSTALLER_NAME"
  if ! sidecar_size=$(/usr/bin/stat -f%z "$SIDECAR_PATH" 2>/dev/null); then
    fail 'Could not determine the checksum sidecar size.'
  fi
  case "$sidecar_size" in
    ''|*[!0-9]*) fail 'The checksum sidecar had an invalid size.' ;;
  esac
  expected_size=$((${#expected_line} + 1))
  if [ "$(normalize_decimal "$sidecar_size")" != "$expected_size" ]; then
    fail 'The checksum sidecar was not exactly one LF-terminated checksum line.'
  fi
  if ! IFS= read -r sidecar_line < "$SIDECAR_PATH"; then
    fail 'The checksum sidecar was not LF-terminated.'
  fi
  if [ "$sidecar_line" != "$expected_line" ]; then
    fail 'The checksum sidecar did not match the downloaded installer and exact asset name.'
  fi
}

validate_mount_point() {
  local mount_point=$1
  local root_prefix
  local child
  local canonical_root
  local canonical_mount_point

  case "$mount_point" in
    ''|.|/|*/./*|*/../*|*/.|*/..) return 1 ;;
    *[[:cntrl:]]*) return 1 ;;
    /*) ;;
    *) return 1 ;;
  esac
  if [ -z "$MOUNT_ROOT" ] || [ ! -d "$MOUNT_ROOT" ] || [ -L "$MOUNT_ROOT" ]; then
    return 1
  fi
  if ! canonical_root=$(cd "$MOUNT_ROOT" 2>/dev/null && pwd -P); then
    return 1
  fi
  if [ "$canonical_root" != "$MOUNT_ROOT" ]; then
    return 1
  fi
  root_prefix="$MOUNT_ROOT/"
  case "$mount_point" in
    "$root_prefix"*) ;;
    *) return 1 ;;
  esac
  child=${mount_point#"$root_prefix"}
  case "$child" in
    ''|.|..|*/*) return 1 ;;
  esac
  if [ ! -d "$mount_point" ] || [ -L "$mount_point" ]; then
    return 1
  fi
  if ! canonical_mount_point=$(cd "$mount_point" 2>/dev/null && pwd -P); then
    return 1
  fi
  if [ "$canonical_mount_point" != "$mount_point" ]; then
    return 1
  fi
  case "$canonical_mount_point" in
    "$root_prefix"*) ;;
    *) return 1 ;;
  esac
  if [ "${canonical_mount_point#"$root_prefix"}" != "$child" ]; then
    return 1
  fi
}

collect_mount_points() {
  local index=0
  local mount_point
  local entity_total

  entity_total=$(array_count 'system-entities' "$ATTACH_PLIST")
  while array_has_index 'system-entities' "$index" "$ATTACH_PLIST" "$entity_total"; do
    if mount_point=$(extract_raw "system-entities.$index.mount-point" "$ATTACH_PLIST" 2>/dev/null); then
      if ! validate_mount_point "$mount_point"; then
        return 1
      fi
      MOUNT_POINTS[${#MOUNT_POINTS[@]}]=$mount_point
    fi
    index=$((index + 1))
  done
  return 0
}

collect_mount_children() {
  local candidate

  [ -n "$MOUNT_ROOT" ] || return 1
  for candidate in "$MOUNT_ROOT"/* "$MOUNT_ROOT"/.[!.]* "$MOUNT_ROOT"/..?*; do
    if [ ! -e "$candidate" ] && [ ! -L "$candidate" ]; then
      continue
    fi
    if ! validate_mount_point "$candidate"; then
      return 1
    fi
    MOUNT_POINTS[${#MOUNT_POINTS[@]}]=$candidate
  done
  return 0
}

mount_dmg() {
  local attach_status=0

  ATTACH_PLIST="$TEMP_ROOT/attach.plist"
  /usr/bin/hdiutil attach -readonly -nobrowse -noautoopen -mountroot "$MOUNT_ROOT" -plist "$DMG_PATH" \
    > "$ATTACH_PLIST" 2> "$TEMP_ROOT/hdiutil-attach.err" || attach_status=$?
  if [ "$attach_status" -ne 0 ]; then
    collect_mount_children || true
    fail 'The downloaded DMG could not be mounted read-only.'
  fi
  if ! /usr/bin/plutil -lint "$ATTACH_PLIST" >/dev/null 2>&1; then
    collect_mount_children || true
    fail 'The DMG mount response was malformed.'
  fi
  if ! collect_mount_points; then
    collect_mount_children || true
    fail 'The DMG mount response contained an invalid mount point.'
  fi
  if [ "${#MOUNT_POINTS[@]}" -eq 0 ]; then
    collect_mount_children || true
  fi
  if [ "${#MOUNT_POINTS[@]}" -eq 0 ]; then
    fail 'The DMG did not expose a mounted volume under the private mount root.'
  fi
}

locate_source_app() {
  local mount_point
  local candidate

  APP_CANDIDATES=()
  for mount_point in "${MOUNT_POINTS[@]}"; do
    while IFS= read -r -d '' candidate; do
      APP_CANDIDATES[${#APP_CANDIDATES[@]}]=$candidate
    done < <(/usr/bin/find "$mount_point" -xdev -maxdepth 2 -type d -name '*.app' -print0 2>/dev/null)
  done
  # Match by CFBundleIdentifier so the bootstrap accepts every release regardless
  # of the bundle's display name (Pi Agent.app before 0.3.0, OMP Agent.app after).
  local matched=()
  if [ "${#APP_CANDIDATES[@]}" -gt 0 ]; then
    for candidate in "${APP_CANDIDATES[@]}"; do
      if bundle_version "$candidate" >/dev/null; then
        matched[${#matched[@]}]=$candidate
      fi
    done
  fi
  if [ "${#matched[@]}" -ne 1 ]; then
    fail "Expected exactly one $BUNDLE_ID application bundle in the mounted DMG, found ${#matched[@]}."
  fi
  APP_CANDIDATES=("${matched[@]}")
  SOURCE_APP=${APP_CANDIDATES[0]}
}

bundle_version() {
  local app_path=$1
  local plist_path="$app_path/Contents/Info.plist"
  local identifier
  local version

  if [ ! -d "$app_path" ] || [ -L "$app_path" ] || [ ! -f "$plist_path" ]; then
    return 1
  fi
  if ! identifier=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist_path" 2>/dev/null); then
    return 1
  fi
  if [ "$identifier" != "$BUNDLE_ID" ]; then
    return 1
  fi
  if ! version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist_path" 2>/dev/null); then
    return 1
  fi
  if ! is_semver "$version"; then
    return 1
  fi
  printf '%s' "$version"
}

rollback_replacement() {
  local failed=0

  if [ "$TARGET_INSTALLED" -eq 1 ]; then
    if /bin/rm -rf "$TARGET_APP" >/dev/null 2>&1; then
      TARGET_INSTALLED=0
    else
      failed=1
    fi
  fi
  if [ "$TARGET_MOVED_TO_BACKUP" -eq 1 ]; then
    if [ -e "$BACKUP_APP" ] || [ -L "$BACKUP_APP" ]; then
      if /bin/mv "$BACKUP_APP" "$TARGET_APP" >/dev/null 2>&1; then
        TARGET_MOVED_TO_BACKUP=0
      else
        failed=1
      fi
    else
      failed=1
    fi
  fi
  return "$failed"
}

stage_and_replace() {
  local staged_app
  local staged_version
  local final_version
  local had_existing=0

  if ! /bin/mkdir -p "$APP_DIR"; then
    fail "Could not create per-user application directory '$APP_DIR'."
  fi
  if ! STAGE_DIR=$(/usr/bin/mktemp -d "$APP_DIR/.pi-agent-stage.XXXXXX"); then
    fail 'Could not create same-volume staging directory.'
  fi
  staged_app="$STAGE_DIR/OMP Agent.app"
  if ! /usr/bin/ditto "$SOURCE_APP" "$staged_app"; then
    fail 'Could not stage OMP Agent.app in the per-user Applications directory.'
  fi
  # ditto out of a mounted DMG carries no quarantine attribute, so Gatekeeper
  # never evaluates the copy. Mark it, and verify the signature we do ship.
  if ! /usr/bin/codesign --verify --deep --strict "$staged_app" >/dev/null 2>&1; then
    fail 'The staged OMP Agent.app failed codesign verification.'
  fi
  if ! /usr/bin/xattr -w com.apple.quarantine \
    "0081;$(/usr/bin/printf '%x' "$(/bin/date +%s)");pi-agent-bootstrap;" "$staged_app"; then
    fail 'Could not mark the staged app for Gatekeeper evaluation.'
  fi
  if ! staged_version=$(bundle_version "$staged_app"); then
    fail 'The staged app did not contain CFBundleShortVersionString.'
  fi
  if [ "$staged_version" != "$RELEASE_VERSION" ]; then
    fail "The staged app version '$staged_version' did not match release version '$RELEASE_VERSION'."
  fi

  if [ -e "$TARGET_APP" ] || [ -L "$TARGET_APP" ]; then
    had_existing=1
    if ! BACKUP_DIR=$(/usr/bin/mktemp -d "$APP_DIR/.pi-agent-backup.XXXXXX"); then
      fail 'Could not create same-volume backup directory.'
    fi
    BACKUP_APP="$BACKUP_DIR/OMP Agent.app"
    if ! /bin/mv "$TARGET_APP" "$BACKUP_APP"; then
      fail 'Could not move the existing OMP Agent.app to a rollback backup.'
    fi
    TARGET_MOVED_TO_BACKUP=1
  fi

  if ! /bin/mv "$staged_app" "$TARGET_APP"; then
    if [ "$had_existing" -eq 1 ] && ! rollback_replacement; then
      fail 'Replacement failed and rollback could not restore the previous OMP Agent.app.'
    fi
    fail 'Could not replace OMP Agent.app in the per-user Applications directory.'
  fi
  TARGET_INSTALLED=1

  if ! final_version=$(bundle_version "$TARGET_APP"); then
    if ! rollback_replacement; then
      fail 'The installed app was unreadable and rollback could not restore the previous OMP Agent.app.'
    fi
    fail 'The installed app did not contain CFBundleShortVersionString.'
  fi
  if [ "$final_version" != "$RELEASE_VERSION" ]; then
    if ! rollback_replacement; then
      fail 'The installed app version was wrong and rollback could not restore the previous OMP Agent.app.'
    fi
    fail "The installed app version '$final_version' did not match release version '$RELEASE_VERSION'."
  fi

  if [ "$had_existing" -eq 1 ]; then
    if ! /bin/rm -rf "$BACKUP_DIR"; then
      if ! rollback_replacement; then
        fail 'The replacement succeeded but backup cleanup failed and rollback could not restore the previous OMP Agent.app.'
      fi
      fail 'The replacement backup could not be cleaned up.'
    fi
    BACKUP_DIR=''
    BACKUP_APP=''
    TARGET_MOVED_TO_BACKUP=0
  fi
  if ! /bin/rm -rf "$STAGE_DIR"; then
    fail 'The staging directory could not be cleaned up.'
  fi
  STAGE_DIR=''
}

remove_legacy_bundles() {
  local name
  local legacy
  for name in "${LEGACY_APP_NAMES[@]}"; do
    legacy="$APP_DIR/$name"
    if [ ! -e "$legacy" ] && [ ! -L "$legacy" ]; then
      continue
    fi
    if ! bundle_version "$legacy" >/dev/null; then
      printf 'OMP Agent bootstrap: left %s in place; it is not a readable %s bundle.\n' "$legacy" "$BUNDLE_ID" >&2
      continue
    fi
    if /bin/rm -rf "$legacy"; then
      printf 'Removed superseded bundle %s\n' "$legacy"
    else
      printf 'OMP Agent bootstrap: could not remove superseded bundle %s; remove it manually.\n' "$legacy" >&2
    fi
  done
}

install_release() {
  # Before anything is downloaded or replaced: an app that cannot find Bun and
  # a global OMP installs cleanly and then fails at launch.
  install_launch_prerequisites
  if ! TEMP_ROOT=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/pi-agent-bootstrap.XXXXXX"); then
    fail 'Could not create a private temporary directory.'
  fi
  if ! MOUNT_ROOT=$(/usr/bin/mktemp -d "$TEMP_ROOT/mountroot.XXXXXX"); then
    fail 'Could not create a private DMG mount root.'
  fi
  if ! MOUNT_ROOT=$(cd "$MOUNT_ROOT" 2>/dev/null && pwd -P); then
    fail 'Could not canonicalize the private DMG mount root.'
  fi
  resolve_release
  INSTALLER_PATH="$TEMP_ROOT/$RELEASE_INSTALLER_NAME"
  SIDECAR_PATH="$TEMP_ROOT/$RELEASE_INSTALLER_NAME.sha256"
  DMG_PATH="$INSTALLER_PATH"
  download_file "$RELEASE_INSTALLER_URL" "$INSTALLER_PATH" "installer '$RELEASE_INSTALLER_NAME'"
  download_file "$RELEASE_SIDECAR_URL" "$SIDECAR_PATH" "checksum sidecar '$RELEASE_INSTALLER_NAME.sha256'"
  verify_download_size "$INSTALLER_PATH" "$RELEASE_INSTALLER_SIZE" "installer '$RELEASE_INSTALLER_NAME'"
  verify_pinned_asset "$INSTALLER_PATH" "$RELEASE_INSTALLER_NAME"
  verify_checksum_sidecar
  mount_dmg
  locate_source_app
  assert_not_downgrade
  stage_and_replace
  remove_legacy_bundles
  printf 'OMP Agent version %s installed at %s\n' "$RELEASE_VERSION" "$TARGET_APP"
}

uninstall_app() {
  if [ -e "$TARGET_APP" ] || [ -L "$TARGET_APP" ]; then
    if ! bundle_version "$TARGET_APP" >/dev/null; then
      fail "Refusing to remove '$TARGET_APP': it is not a readable OMP Agent bundle."
    fi
    if ! /bin/rm -rf "$TARGET_APP"; then
      fail "Could not remove '$TARGET_APP'."
    fi
    printf 'OMP Agent was uninstalled from %s\n' "$TARGET_APP"
  else
    printf 'OMP Agent is not installed at %s\n' "$TARGET_APP"
  fi
  remove_legacy_bundles
}

status_app() {
  local version
  if [ ! -e "$TARGET_APP" ] && [ ! -L "$TARGET_APP" ]; then
    printf 'OMP Agent is not installed at %s\n' "$TARGET_APP"
    return
  fi
  if ! version=$(bundle_version "$TARGET_APP"); then
    fail "Could not read CFBundleShortVersionString from '$TARGET_APP'."
  fi
  printf 'OMP Agent version %s\n' "$version"
}

assert_user_context
assert_supported_macos_arm64
parse_args "$@"

case "$ACTION" in
  install) install_release ;;
  uninstall) uninstall_app ;;
  status) status_app ;;
esac
