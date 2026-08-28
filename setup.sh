#!/bin/sh
set -eu

release_base=${FXXL_RELEASE_BASE_URL:-https://github.com/jcd3dr/fxXL/releases/latest/download}
install_dir=${FX_INSTALL_DIR:-"${HOME:?HOME is required}/.local/bin"}
temp_dir=
install_temp=

cleanup() {
    if [ -n "$install_temp" ] && [ -e "$install_temp" ]; then
        rm -f "$install_temp"
    fi
    if [ -n "$temp_dir" ] && [ -d "$temp_dir" ]; then
        rm -rf "$temp_dir"
    fi
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

fail() {
    printf 'fxXL installer: %s\n' "$*" >&2
    exit 1
}

download() {
    url=$1
    destination=$2
    case "$url" in
        file://*)
            cp "${url#file://}" "$destination" || fail "could not read local release asset"
            ;;
        https://*|http://127.0.0.1:*|http://localhost:*)
            if command -v curl >/dev/null 2>&1; then
                curl -fsSL --retry 3 --connect-timeout 15 -o "$destination" "$url" ||
                    fail "release asset download failed"
            elif command -v wget >/dev/null 2>&1; then
                wget -q -O "$destination" "$url" || fail "release asset download failed"
            else
                fail "curl or wget is required"
            fi
            ;;
        *)
            fail "release URL must use HTTPS (plain HTTP is allowed only for loopback tests)"
            ;;
    esac
}

case "$release_base" in
    *://*@*) fail "release URL must not contain embedded credentials" ;;
esac

case "$(uname -s)" in
    Linux) os=linux ;;
    *) fail "unsupported operating system; this installer requires Linux" ;;
esac

case "$(uname -m)" in
    x86_64|amd64) arch=x86_64 ;;
    aarch64|arm64) arch=aarch64 ;;
    *) fail "unsupported architecture; expected x86_64 or aarch64" ;;
esac

platform=$os-$arch
asset=fx-$platform.tar.gz
temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/fxxl-install.XXXXXX") ||
    fail "could not create a temporary directory"
manifest_path=$temp_dir/manifest.json
archive_path=$temp_dir/$asset
checksum_path=$archive_path.sha256
candidate_path=$temp_dir/fx

download "$release_base/manifest.json" "$manifest_path"
manifest_size=$(wc -c <"$manifest_path" | tr -d '[:space:]')
[ "$manifest_size" -le 4096 ] || fail "release manifest is too large"
grep -Eq '"schema_version"[[:space:]]*:[[:space:]]*1([,}])' "$manifest_path" ||
    fail "release manifest has an unsupported schema"
grep -Eq '"version"[[:space:]]*:[[:space:]]*"[0-9]+\.[0-9]+\.[0-9]+"' "$manifest_path" ||
    fail "release manifest has an invalid version"
grep -Eq '"upstream_commit"[[:space:]]*:[[:space:]]*"[0-9a-fA-F]{40}"' "$manifest_path" ||
    fail "release manifest has an invalid upstream commit"
grep -Eq '"source_commit"[[:space:]]*:[[:space:]]*"[0-9a-fA-F]{40}"' "$manifest_path" ||
    fail "release manifest has an invalid source commit"

download "$release_base/$asset" "$archive_path"
download "$release_base/$asset.sha256" "$checksum_path"

expected_checksum=$(sed -n '1{s/[[:space:]].*$//;p;}' "$checksum_path")
printf '%s\n' "$expected_checksum" | grep -Eq '^[0-9a-fA-F]{64}$' ||
    fail "release checksum is invalid"

if command -v sha256sum >/dev/null 2>&1; then
    actual_checksum=$(sha256sum "$archive_path" | sed 's/[[:space:]].*$//')
elif command -v shasum >/dev/null 2>&1; then
    actual_checksum=$(shasum -a 256 "$archive_path" | sed 's/[[:space:]].*$//')
else
    fail "sha256sum or shasum is required"
fi

[ "$actual_checksum" = "$expected_checksum" ] || fail "release checksum mismatch"
tar -xOzf "$archive_path" fx >"$candidate_path" || fail "could not extract fx from release archive"
chmod +x "$candidate_path" || fail "could not make downloaded fx executable"
"$candidate_path" --version >/dev/null 2>&1 || fail "downloaded fx failed validation"

mkdir -p "$install_dir" || fail "could not create install directory: $install_dir"
install_temp=$(mktemp "$install_dir/.fx-install.XXXXXX") ||
    fail "could not create a temporary file in the install directory"
cp "$candidate_path" "$install_temp" || fail "could not stage fx in the install directory"
chmod +x "$install_temp" || fail "could not make staged fx executable"
mv -f "$install_temp" "$install_dir/fx" || fail "could not install fx"
install_temp=

printf 'fxXL installed at %s\n' "$install_dir/fx"
case ":${PATH:-}:" in
    *":$install_dir:"*) ;;
    *) printf 'Add %s to PATH to run fx from any directory.\n' "$install_dir" ;;
esac
