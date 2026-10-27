#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./build.sh                     (in a terminal: guided, asks what to build)
  ./build.sh [command] [arch] [version] [--sign] [--notarize]

Commands:
  dev       Build in debug mode and run ForelApp locally (signs with your
            code-signing identity so permission prompts persist across
            rebuilds; override with CODESIGN_IDENTITY)
  build     Build the Swift package in release mode
  test      Run the Swift test suite
  package   Build and package a Forel.app + DMG
  release   Alias for: build + package

Arguments:
  arch      universal, arm64, or x86_64 (defaults to host architecture)
  version   Release version like v1.2.3
  --sign    Sign the app and DMG with a Developer ID Application certificate
  --notarize
            Submit and staple the signed app and DMG using Notary API secrets
  -i, --interactive
            Always ask for anything missing (command, arch, version, signing)
  --no-interactive
            Never ask; use the defaults below (also implied by CI=true or
            when stdin/stdout is not a terminal)
  -h, --help
            Show this help

Interactive mode:
  When run from a terminal without a command, or with package/release but no
  version, build.sh asks for what is missing. For the version it suggests the
  next patch/minor/major after the newest one found in git tags, CHANGELOG.md
  and dist/release, and prints the equivalent one-line command before building.

Non-interactive defaults:
  command   release
  arch      host architecture
  version   the git tag at HEAD, otherwise v0.0.0-local

Examples:
  ./build.sh
  ./build.sh dev
  ./build.sh package
  ./build.sh package arm64 v1.2.3
  ./build.sh package arm64 v1.2.3 --sign
  ./build.sh package arm64 v1.2.3 --sign --notarize
  ./build.sh package universal v1.2.3 --sign --notarize
  ./build.sh release x86_64 v1.2.3
EOF
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$script_dir"
dist_dir="$repo_root/dist/release"
bundle_root="${TMPDIR:-/tmp}/Forel.app"
dev_bundle="${TMPDIR:-/tmp}/Forel-dev.app"
staging_root="${TMPDIR:-/tmp}/Forel-dmg"
icon_source="$repo_root/Sources/ForelApp/Resources/AppIcon.png"
iconset_dir="${TMPDIR:-/tmp}/Forel.iconset"
icns_path="$repo_root/dist/Forel.icns"
entitlements_path="$repo_root/Forel.entitlements"
code_sign_identity="${CODE_SIGN_IDENTITY:--}"
notary_work=""

cleanup() {
  if [[ -n "$notary_work" ]]; then
    rm -rf "$notary_work"
  fi
}
trap cleanup EXIT

generate_icns() {
  rm -rf "$iconset_dir"
  mkdir -p "$iconset_dir"

  local size src
  src="$icon_source"
  for size in 16 32 64 128 256 512; do
    sips -z "$size" "$size" "$src" --out "$iconset_dir/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) "$src" --out "$iconset_dir/icon_${size}x${size}@2x.png" >/dev/null
  done

  iconutil -c icns "$iconset_dir" -o "$icns_path" >/dev/null
}

# Copies the binary and resources from SwiftPM's exact product directory
# into a fresh "$dest_app/Contents/{MacOS,Resources}". Shared by
# `dev` and `package` so the two don't drift out of sync.
assemble_app_bundle() {
  local products_dir="$1" dest_app="$2"
  local binary_path resource_bundle contents_dir macos_dir resources_dir

  binary_path="$products_dir/ForelApp"
  if [[ ! -f "$binary_path" ]]; then
    echo "Could not find ForelApp in $products_dir after swift build" >&2
    exit 1
  fi
  resource_bundle="$products_dir/Forel_ForelApp.bundle"

  contents_dir="$dest_app/Contents"
  macos_dir="$contents_dir/MacOS"
  resources_dir="$contents_dir/Resources"
  rm -rf "$dest_app"
  mkdir -p "$macos_dir" "$resources_dir"

  cp "$binary_path" "$macos_dir/ForelApp"
  chmod +x "$macos_dir/ForelApp"
  if [[ -d "$resource_bundle" ]]; then
    cp -R "$resource_bundle" "$resources_dir/"
  fi
}

# Writes Info.plist into $1, with $2 as both CFBundleShortVersionString and
# CFBundleVersion, plus any extra keys (already-indented <key>/<value> XML)
# passed as $3. Shared by `dev` and `package`, which pass only their
# build-specific extras on top of the identical boilerplate and privacy keys.
write_info_plist() {
  local contents_dir="$1" version_number="$2" extra_keys="${3:-}"
  cat > "$contents_dir/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleDisplayName</key>
  <string>Forel</string>
  <key>CFBundleExecutable</key>
  <string>ForelApp</string>
  <key>CFBundleIdentifier</key>
  <string>com.lab421.forel</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>Forel</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>${version_number}</string>
  <key>CFBundleVersion</key>
  <string>${version_number}</string>
  <key>NSHumanReadableCopyright</key>
  <string>Copyright © 2026 Lab421</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPhotoLibraryUsageDescription</key>
  <string>Forel can import images and videos into your Photos library as part of automated rules.</string>
  <key>NSAppleEventsUsageDescription</key>
  <string>Forel uses automation to add files to the Music and TV libraries as part of automated rules.</string>
${extra_keys}
</dict>
</plist>
EOF
}

notarize_and_staple() {
  local target="$1"
  local submission="$target"

  if [[ "$target" == *.app ]]; then
    submission="$notary_work/$(basename "$target").zip"
    /usr/bin/ditto -c -k --keepParent "$target" "$submission"
  fi

  echo "Submitting $(basename "$target") to Apple for notarization..."
  xcrun notarytool submit "$submission" \
    --key "$notary_work/AuthKey.p8" \
    --key-id "$NOTARY_KEY_ID" \
    --issuer "$NOTARY_ISSUER_ID" \
    --wait
  xcrun stapler staple "$target"
  xcrun stapler validate "$target"
}

swift_release_build() {
  local build_arch="$1"
  local build_args=(-c release)

  if [[ "$build_arch" == "universal" ]]; then
    build_args+=(--arch arm64 --arch x86_64)
  else
    build_args+=(--arch "$build_arch")
  fi
  swift build "${build_args[@]}"
  build_products_dir="$(swift build "${build_args[@]}" --show-bin-path)"
}

# ---- Interactive mode ------------------------------------------------------
# Kept bash 3.2 compatible (stock macOS): no mapfile, no read -i, no ${x,,}.

# Prints a numbered menu on stderr and stores the picked option's value in
# $choice. Args: title, default index (1-based), then "value|label" pairs.
choose() {
  local title="$1" default_index="$2" answer i
  shift 2
  local options=("$@")
  while true; do
    echo "" >&2
    echo "$title" >&2
    for ((i = 0; i < ${#options[@]}; i++)); do
      local marker="  "
      [[ $((i + 1)) -eq $default_index ]] && marker="> "
      echo "  ${marker}$((i + 1))) ${options[$i]#*|}" >&2
    done
    read -r -p "Choose [${default_index}]: " answer || exit 1
    answer="${answer:-$default_index}"
    if [[ "$answer" =~ ^[0-9]+$ ]] && ((answer >= 1 && answer <= ${#options[@]})); then
      choice="${options[$((answer - 1))]%%|*}"
      return
    fi
    echo "Please enter a number between 1 and ${#options[@]}." >&2
  done
}

# Asks a yes/no question. Args: question, default (y or n). Returns 0 for yes.
confirm() {
  local question="$1" default="$2" hint answer
  if [[ "$default" == y ]]; then hint="Y/n"; else hint="y/N"; fi
  while true; do
    read -r -p "$question [$hint]: " answer || exit 1
    answer="${answer:-$default}"
    case "$answer" in
      y|Y|yes|YES|Yes|s|S|sim|Sim) return 0 ;;
      n|N|no|NO|No|nao|não|Não) return 1 ;;
    esac
    echo "Please answer y or n." >&2
  done
}

is_version() {
  [[ "${1#v}" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]]
}

# Newest released version found in git tags, CHANGELOG.md headers, and DMGs
# already in dist/release (without the leading v), or nothing if none exist.
latest_known_version() {
  local dmg name
  {
    git -C "$repo_root" tag -l 2>/dev/null || true
    sed -n 's/^## \[\([0-9][^]]*\)\].*/\1/p' "$repo_root/CHANGELOG.md" 2>/dev/null || true
    for dmg in "$dist_dir"/Forel-v*.dmg; do
      [[ -e "$dmg" ]] || continue
      name="${dmg##*/Forel-}"
      name="${name%.dmg}"
      echo "${name%-darwin-*}"
    done
  } | sed 's/^v//' |
    grep -E '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$' |
    grep -vE -- '-(local|dev)$' |
    sort -t. -k1,1n -k2,2n -k3,3n |
    tail -n 1
}

# Bumps x.y.z[-suffix] by patch, minor, or major, keeping any suffix
# (e.g. 1.3.5-fork -> 1.3.6-fork).
bump_version() {
  local current="$1" part="$2" core suffix="" major minor patch
  core="${current%%-*}"
  [[ "$current" == *-* ]] && suffix="-${current#*-}"
  IFS=. read -r major minor patch <<<"$core"
  case "$part" in
    patch) patch=$((patch + 1)) ;;
    minor) minor=$((minor + 1)); patch=0 ;;
    major) major=$((major + 1)); minor=0; patch=0 ;;
  esac
  echo "${major}.${minor}.${patch}${suffix}"
}

ask_version() {
  local latest head_tag options=() default_index=1 entered
  head_tag="$(git -C "$repo_root" describe --tags --exact-match 2>/dev/null || true)"
  latest="$(latest_known_version)"

  if [[ -n "$head_tag" ]]; then
    options+=("$head_tag|$head_tag (tag at the current commit)")
  fi
  if [[ -n "$latest" ]]; then
    options+=("v$(bump_version "$latest" patch)|v$(bump_version "$latest" patch)  next patch: fixes only")
    options+=("v$(bump_version "$latest" minor)|v$(bump_version "$latest" minor)  next minor: new features")
    options+=("v$(bump_version "$latest" major)|v$(bump_version "$latest" major)  next major: breaking changes")
  fi
  options+=("custom|Type another version")
  options+=("v0.0.0-local|v0.0.0-local  local test build, not for release")

  local title="Version"
  [[ -n "$latest" ]] && title="Version (newest found: v$latest)"
  choose "$title" "$default_index" "${options[@]}"

  if [[ "$choice" == custom ]]; then
    while true; do
      read -r -p "Version (e.g. v1.2.3 or v1.2.3-fork): " entered || exit 1
      if is_version "$entered"; then
        choice="$entered"
        break
      fi
      echo "Use the form v1.2.3 (an optional -suffix is allowed)." >&2
    done
  fi
  version="$choice"
}

run_interactive_setup() {
  local host_arch summary
  host_arch="$(uname -m)"
  echo "Forel build — press Return to accept the default (marked with >)." >&2

  if [[ "$command_given" != true ]]; then
    choose "What do you want to do?" 4 \
      "dev|dev      Build in debug and run Forel locally" \
      "build|build    Release build only (no app bundle)" \
      "test|test     Run the test suite" \
      "package|package  Build Forel.app and a DMG to distribute" \
      "release|release  Same as package"
    command="$choice"
  fi

  if [[ "$arch_given" != true ]] && [[ "$command" == build || "$command" == package || "$command" == release ]]; then
    local arch_default=1
    [[ "$host_arch" == x86_64 ]] && arch_default=2
    choose "Architecture" "$arch_default" \
      "arm64|arm64      Apple silicon$([[ "$host_arch" == arm64 ]] && echo " (this Mac)")" \
      "x86_64|x86_64     Intel$([[ "$host_arch" == x86_64 ]] && echo " (this Mac)")" \
      "universal|universal  Apple silicon + Intel in one app"
    arch="$choice"
  fi

  if [[ "$command" == package || "$command" == release ]]; then
    [[ -z "$version" ]] && ask_version

    echo "" >&2
    if [[ "$sign_given" != true ]]; then
      if confirm "Sign with your Developer ID Application certificate?" n; then
        sign_requested=true
      fi
    fi
    if [[ "$sign_requested" == true && "$notarize_given" != true ]]; then
      if [[ -z "${NOTARY_API_KEY_P8:-}" || -z "${NOTARY_KEY_ID:-}" || -z "${NOTARY_ISSUER_ID:-}" ]]; then
        echo "Skipping notarization: set NOTARY_API_KEY_P8, NOTARY_KEY_ID and NOTARY_ISSUER_ID to enable it." >&2
      elif confirm "Notarize with Apple (takes a few minutes)?" n; then
        notarize_requested=true
      fi
    fi
  fi

  summary="./build.sh $command"
  if [[ "$command" == build || "$command" == package || "$command" == release ]]; then
    summary+=" $arch"
  fi
  if [[ "$command" == package || "$command" == release ]]; then
    summary+=" $version"
    [[ "$sign_requested" == true ]] && summary+=" --sign"
    [[ "$notarize_requested" == true ]] && summary+=" --notarize"
  fi
  echo "" >&2
  echo "About to run: $summary" >&2
  echo "(run that line directly next time to skip these questions)" >&2
  if ! confirm "Continue?" y; then
    echo "Cancelled." >&2
    exit 1
  fi
  echo "" >&2
}

command="release"
command_given=false
if [[ $# -gt 0 ]]; then
  case "$1" in
    dev|build|test|package|release)
      command="$1"
      command_given=true
      shift
      ;;
  esac
fi

sign_requested=false
sign_given=false
notarize_requested=false
notarize_given=false
interactive_mode=auto
positional_args=()
for arg in "$@"; do
  case "$arg" in
    -h|--help)
      usage
      exit 0
      ;;
    --sign)
      sign_requested=true
      sign_given=true
      ;;
    --notarize)
      notarize_requested=true
      notarize_given=true
      ;;
    -i|--interactive)
      interactive_mode=always
      ;;
    --no-interactive)
      interactive_mode=never
      ;;
    -*)
      echo "Unknown option: $arg" >&2
      usage
      exit 1
      ;;
    *)
      positional_args+=("$arg")
      ;;
  esac
done
if [[ ${#positional_args[@]} -gt 0 ]]; then
  set -- "${positional_args[@]}"
else
  set --
fi

if [[ $# -gt 2 ]]; then
  echo "Too many arguments" >&2
  usage
  exit 1
fi

arch_given=false
[[ $# -ge 1 ]] && arch_given=true
arch="${1:-$(uname -m)}"
version="${2:-}"

# Interactive mode only kicks in from a real terminal, so CI and scripts that
# pass full arguments keep the exact same behavior.
if [[ "$interactive_mode" == auto ]]; then
  interactive_mode=never
  if [[ -t 0 && -t 1 && -z "${CI:-}" ]]; then
    if [[ "$command_given" != true ]] ||
       { [[ "$command" == package || "$command" == release ]] && [[ -z "$version" ]]; }; then
      interactive_mode=always
    fi
  fi
fi
if [[ "$interactive_mode" == always ]]; then
  run_interactive_setup
fi

if [[ "$sign_requested" == true ]]; then
  if [[ "$command" != "package" && "$command" != "release" ]]; then
    echo "--sign is only supported with package or release" >&2
    exit 1
  fi
  if [[ "$code_sign_identity" == "-" ]]; then
    code_sign_identity="$(
      security find-identity -v -p codesigning |
        awk '/Developer ID Application:/ && !identity { identity=$2 } END { print identity }'
    )"
    if [[ -z "$code_sign_identity" ]]; then
      echo "No valid Developer ID Application identity was found in the keychain" >&2
      exit 1
    fi
  fi
fi

if [[ "$notarize_requested" == true ]]; then
  if [[ "$command" != "package" && "$command" != "release" ]]; then
    echo "--notarize is only supported with package or release" >&2
    exit 1
  fi
  if [[ "$sign_requested" != true ]]; then
    echo "--notarize requires --sign" >&2
    exit 1
  fi
  if [[ -z "${NOTARY_API_KEY_P8:-}" || -z "${NOTARY_KEY_ID:-}" || -z "${NOTARY_ISSUER_ID:-}" ]]; then
    echo "Notarization requires NOTARY_API_KEY_P8, NOTARY_KEY_ID, and NOTARY_ISSUER_ID" >&2
    exit 1
  fi
  notary_work="$(mktemp -d "${TMPDIR:-/tmp}/Forel-notary.XXXXXX")"
  printf '%s' "$NOTARY_API_KEY_P8" | base64 --decode > "$notary_work/AuthKey.p8"
  chmod 600 "$notary_work/AuthKey.p8"
fi

case "$command" in
  dev)
    cd "$repo_root"
    # Build and run from inside a debug .app bundle rather than the bare
    # `swift run` binary. macOS attributes TCC checks (Photos, Automation,
    # Removable Volumes) to the bundle's code-signing identity; an unbundled
    # binary has none, so those checks get misattributed to whatever launched
    # it (e.g. the terminal you're using) instead of Forel, making them
    # unreliable to test.
    swift build

    build_products_dir="$(swift build --show-bin-path)"
    assemble_app_bundle "$build_products_dir" "$dev_bundle"
    contents_dir="$dev_bundle/Contents"
    macos_dir="$contents_dir/MacOS"

    write_info_plist "$contents_dir" "0.0.0-dev"

    # Sign with a real identity when one is available, so TCC grants
    # (removable volumes, Photos, automation) survive rebuilds. An ad-hoc
    # signature changes with every rebuild, and macOS treats each rebuild
    # as a new program — re-prompting for permissions the user already gave.
    signing_identity="${CODESIGN_IDENTITY:-}"
    if [[ -z "$signing_identity" ]]; then
      # bash 3.2 (stock macOS) has no mapfile; parse into a newline list.
      identity_list="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/^ *[0-9]+\) .+"/ {print $2}')"
      identity_count="$(printf '%s\n' "$identity_list" | grep -c . || true)"
      if [[ "$identity_count" -eq 1 ]]; then
        signing_identity="$identity_list"
      elif [[ "$identity_count" -gt 1 ]]; then
        echo "Multiple code-signing identities found; set CODESIGN_IDENTITY to pick one:" >&2
        printf '%s\n' "$identity_list" >&2
      fi
    fi

    if [[ -n "$signing_identity" ]]; then
      codesign --force --deep --sign "$signing_identity" "$dev_bundle" >/dev/null 2>&1 || {
        echo "Signing with '$signing_identity' failed — falling back to ad-hoc." >&2
        codesign --force --deep --sign - "$dev_bundle" >/dev/null 2>&1
        signing_identity=""
      }
    else
      codesign --force --deep --sign - "$dev_bundle" >/dev/null 2>&1
    fi

    if [[ -n "$signing_identity" ]]; then
      echo "Signed dev bundle with: $signing_identity"
      echo "Permission prompts should now appear only once per permission."
    else
      echo "Ad-hoc signed: macOS will re-ask for folder/volume permissions after every rebuild." >&2
      echo "For one-time-only prompts, sign with a stable certificate (set CODESIGN_IDENTITY)." >&2
    fi

    # Exec the binary inside the bundle (not `open`) so stdout/stderr stay
    # attached to this terminal while macOS still reads the adjacent
    # Info.plist for the bundle identity TCC checks need.
    exec "$macos_dir/ForelApp"
    ;;

  build)
    cd "$repo_root"
    swift_release_build "$arch"
    ;;

  test)
    cd "$repo_root"
    swift test
    ;;

  package|release)
    if [[ -z "$version" ]]; then
      if git -C "$repo_root" describe --tags --exact-match >/dev/null 2>&1; then
        version="$(git -C "$repo_root" describe --tags --exact-match)"
      else
        version="v0.0.0-local"
      fi
    fi

    if [[ "$version" == v* ]]; then
      version_number="${version#v}"
    else
      version_number="$version"
      version="v$version"
    fi

    case "$arch" in
      universal)
        dmg_suffix=""
        ;;
      arm64)
        dmg_suffix="darwin-arm64"
        ;;
      x86_64)
        dmg_suffix="darwin-x86_64"
        ;;
      *)
        echo "Unsupported architecture: $arch" >&2
        exit 1
        ;;
    esac

    cd "$repo_root"
    swift_release_build "$arch"

    if [[ -f "$icon_source" ]]; then
      mkdir -p "$repo_root/dist"
      generate_icns
    fi

    assemble_app_bundle "$build_products_dir" "$bundle_root"
    contents_dir="$bundle_root/Contents"

    if [[ "$arch" == "universal" ]]; then
      lipo "$bundle_root/Contents/MacOS/ForelApp" -verify_arch arm64
      lipo "$bundle_root/Contents/MacOS/ForelApp" -verify_arch x86_64
    fi

    write_info_plist "$contents_dir" "$version_number" '  <key>CFBundleIconFile</key>
  <string>Forel</string>
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.productivity</string>'

    if [[ -f "$icns_path" ]]; then
      cp "$icns_path" "$bundle_root/Contents/Resources/Forel.icns"
    fi

    if [[ "$sign_requested" == true ]]; then
      # Sign outside the repository. Folders under Documents can receive
      # File Provider/provenance metadata after a copy, invalidating an
      # otherwise-correct signature before the DMG is assembled.
      xattr -cr "$bundle_root"
      codesign \
        --force \
        --deep \
        --options runtime \
        --timestamp \
        --entitlements "$entitlements_path" \
        --sign "$code_sign_identity" \
        "$bundle_root"
      codesign --verify --deep --strict --verbose=2 "$bundle_root"
      if [[ "$notarize_requested" == true ]]; then
        notarize_and_staple "$bundle_root"
      fi
    fi

    mkdir -p "$dist_dir"
    rm -rf "$dist_dir/Forel.app"
    /usr/bin/ditto --noextattr --noqtn "$bundle_root" "$dist_dir/Forel.app"

    rm -rf "$staging_root"
    mkdir -p "$staging_root"
    /usr/bin/ditto --noextattr --noqtn "$bundle_root" "$staging_root/Forel.app"
    if [[ "$sign_requested" == true ]]; then
      codesign --verify --deep --strict --verbose=2 "$staging_root/Forel.app"
      if [[ "$notarize_requested" == true ]]; then
        xcrun stapler validate "$staging_root/Forel.app"
      fi
    fi
    ln -s /Applications "$staging_root/Applications"

    if [[ "$arch" == "universal" ]]; then
      dmg_path="$dist_dir/Forel-${version}.dmg"
    else
      dmg_path="$dist_dir/Forel-${version}-${dmg_suffix}.dmg"
    fi
    hdiutil create \
      -volname "Forel" \
      -srcfolder "$staging_root" \
      -ov \
      -format UDZO \
      "$dmg_path"

    if [[ "$sign_requested" == true ]]; then
      codesign --force --timestamp --sign "$code_sign_identity" "$dmg_path"
      codesign --verify --strict --verbose=2 "$dmg_path"
      if [[ "$notarize_requested" == true ]]; then
        notarize_and_staple "$dmg_path"
        codesign --verify --strict --verbose=2 "$dmg_path"
      fi
    fi

    echo "Created $dmg_path"
    rm -rf "$iconset_dir" "$staging_root" "$icns_path"
    ;;

  *)
    usage
    exit 1
    ;;
esac
