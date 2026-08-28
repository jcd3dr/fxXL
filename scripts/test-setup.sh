#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
installer=$repo_root/setup.sh
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/fxxl-setup-test.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT HUP INT TERM

fake_bin=$work_dir/bin
release_dir=$work_dir/release
mkdir -p "$fake_bin" "$release_dir"

cat >"$fake_bin/uname" <<'EOF'
#!/bin/sh
case "${1:-}" in
    -s) printf '%s\n' "${TEST_UNAME_S:?}" ;;
    -m) printf '%s\n' "${TEST_UNAME_M:?}" ;;
    *) exit 2 ;;
esac
EOF
chmod +x "$fake_bin/uname"

cat >"$release_dir/manifest.json" <<'EOF'
{"schema_version":1,"version":"9.9.9","upstream_commit":"0123456789abcdef0123456789abcdef01234567","source_commit":"89abcdef0123456789abcdef0123456789abcdef"}
EOF

make_archive() {
    platform=$1
    marker=$2
    payload_dir=$work_dir/payload-$platform
    mkdir -p "$payload_dir"
    cat >"$payload_dir/fx" <<EOF
#!/bin/sh
if [ "\${1:-}" = "--version" ]; then
    printf '%s\n' 'fxXL $marker'
    exit 0
fi
printf '%s\n' '$marker'
EOF
    chmod +x "$payload_dir/fx"
    archive=$release_dir/fx-$platform.tar.gz
    tar -czf "$archive" -C "$payload_dir" fx
    sha256sum "$archive" >"$archive.sha256"
}

make_archive linux-x86_64 x86-installed
make_archive linux-aarch64 arm-installed

run_installer() {
    os=$1
    arch=$2
    install_dir=$3
    PATH="$fake_bin:$PATH" \
        TEST_UNAME_S=$os \
        TEST_UNAME_M=$arch \
        FXXL_RELEASE_BASE_URL="file://$release_dir" \
        FX_INSTALL_DIR=$install_dir \
        sh "$installer"
}

assert_installs() {
    os=$1
    arch=$2
    expected=$3
    install_dir=$work_dir/install-$arch
    run_installer "$os" "$arch" "$install_dir"
    actual=$($install_dir/fx)
    [ "$actual" = "$expected" ] || {
        printf 'expected %s, got %s\n' "$expected" "$actual" >&2
        exit 1
    }
}

assert_installs Linux x86_64 x86-installed
assert_installs Linux aarch64 arm-installed

bad_install=$work_dir/install-bad-checksum
mkdir -p "$bad_install"
printf '%s\n' 'existing-binary' >"$bad_install/fx"
cp "$bad_install/fx" "$work_dir/existing-before"
printf '%064d  fx-linux-x86_64.tar.gz\n' 0 >"$release_dir/fx-linux-x86_64.tar.gz.sha256"
if run_installer Linux x86_64 "$bad_install" >/dev/null 2>&1; then
    printf 'installer accepted an invalid checksum\n' >&2
    exit 1
fi
cmp "$work_dir/existing-before" "$bad_install/fx"

if run_installer Darwin x86_64 "$work_dir/install-darwin" >/dev/null 2>&1; then
    printf 'installer accepted an unsupported operating system\n' >&2
    exit 1
fi

if run_installer Linux riscv64 "$work_dir/install-riscv" >/dev/null 2>&1; then
    printf 'installer accepted an unsupported architecture\n' >&2
    exit 1
fi

printf '%s\n' 'setup.sh tests passed'
