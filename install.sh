#!/bin/bash
set -euo pipefail
export LC_ALL=C

# Generated source: BaxterCooper/pi-agent apps/desktop/bootstrap/install.sh. The
# desktop release workflow publishes this file to BaxterCooper/pi-agent-releases.
API_ROOT='https://api.github.com/repos/BaxterCooper/pi-agent-releases'
BUNDLE_ID='dev.baxter.pi-agent'
# Bundle names installed by earlier bootstraps under the same bundle identifier.
LEGACY_APP_NAMES=('Pi Agent.app')
ACTION='install'
CHANNEL='stable'
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
    'Usage: install.sh [install [stable|latest|VERSION] | uninstall | status]' \
    '' \
    'Install is the default action. VERSION must be an exact semantic version such as 1.2.3.'
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

normalize_decimal() {
  local value=$1
  while [ "${#value}" -gt 1 ] && [ "${value#0}" != "$value" ]; do
    value=${value#0}
  done
  printf '%s' "$value"
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
  while /usr/bin/plutil -extract "assets.$asset_index" xml1 -o /dev/null "$release_json" >/dev/null 2>&1; do
    if ! asset_name=$(extract_raw "assets.$asset_index.name" "$release_json" 2>/dev/null); then
      fail "Release asset $asset_index did not contain a name."
    fi
    case "$asset_name" in
      ''|*'/'*|*'\\'*|*$'\r'*|*$'\n'*|*$'\t'*)
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
}

download_file() {
  local url=$1
  local destination=$2
  local label=$3
  assert_https_url "$url" "$label"
  if ! /usr/bin/curl --fail --silent --show-error --location \
    --proto '=https' --proto-redir '=https' \
    --connect-timeout 20 --max-time 900 --retry 2 --retry-delay 1 \
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

  while /usr/bin/plutil -extract "system-entities.$index" xml1 -o /dev/null "$ATTACH_PLIST" >/dev/null 2>&1; do
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
  verify_checksum_sidecar
  mount_dmg
  locate_source_app
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
