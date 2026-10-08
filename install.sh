#!/usr/bin/env bash
set -Eeuo pipefail

repo="${ZPEEK_REPO:-aleksandraleksandrov/zpeek}"
release_base="https://github.com/${repo}/releases/latest/download"

die() {
    printf 'zpeek installer: %s\n' "$*" >&2
    exit 1
}

command -v curl >/dev/null 2>&1 || die "curl is required"

kernel="$(uname -s)"
machine="$(uname -m)"

case "$kernel" in
    Darwin) os="macos" ;;
    Linux) os="linux" ;;
    MINGW* | MSYS* | CYGWIN*) os="windows" ;;
    *) die "unsupported operating system: ${kernel}" ;;
esac

case "$machine" in
    x86_64 | amd64) arch="x86_64" ;;
    arm64 | aarch64) arch="aarch64" ;;
    *) die "unsupported architecture: ${machine}" ;;
esac

if [[ "$os" == "windows" ]]; then
    extension="zip"
    binary_name="zpeek.exe"
else
    extension="tar.gz"
    binary_name="zpeek"
fi
asset="zpeek-${os}-${arch}.${extension}"

if [[ -n "${ZPEEK_INSTALL_DIR:-}" ]]; then
    install_dir="$ZPEEK_INSTALL_DIR"
elif [[ "$os" == "windows" ]]; then
    windows_local_app_data="${LOCALAPPDATA:-$HOME/AppData/Local}"
    if command -v cygpath >/dev/null 2>&1; then
        install_dir="$(cygpath -u "$windows_local_app_data")/zpeek/bin"
    else
        install_dir="${windows_local_app_data}/zpeek/bin"
    fi
else
    install_dir="${XDG_BIN_HOME:-$HOME/.local/bin}"
fi

temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/zpeek.XXXXXX")"
cleanup() {
    [[ -n "${temp_dir:-}" && -d "$temp_dir" ]] && rm -rf -- "$temp_dir"
}
trap cleanup EXIT

archive="$temp_dir/$asset"
printf 'Downloading %s...\n' "$asset"
curl -fL --retry 3 --retry-delay 1 "${release_base}/${asset}" -o "$archive"

checksum_file="$temp_dir/checksums.txt"
if curl -fsSL --retry 3 "${release_base}/checksums.txt" -o "$checksum_file"; then
    expected="$(awk -v asset="$asset" '{ name=$2; sub(/^\*/, "", name); if (name == asset) { print $1; exit } }' "$checksum_file")"
    [[ -n "$expected" ]] || die "checksum for ${asset} is missing"
    if command -v sha256sum >/dev/null 2>&1; then
        actual="$(sha256sum "$archive" | awk '{print $1}')"
    elif command -v shasum >/dev/null 2>&1; then
        actual="$(shasum -a 256 "$archive" | awk '{print $1}')"
    else
        die "sha256sum or shasum is required to verify the download"
    fi
    [[ "$actual" == "$expected" ]] || die "checksum verification failed"
else
    printf 'Warning: checksums.txt is unavailable; the download was not verified.\n' >&2
fi

extract_dir="$temp_dir/extract"
mkdir -p "$extract_dir"
if [[ "$extension" == "zip" ]]; then
    command -v unzip >/dev/null 2>&1 || die "unzip is required on Windows"
    unzip -q "$archive" -d "$extract_dir"
else
    command -v tar >/dev/null 2>&1 || die "tar is required"
    tar -xzf "$archive" -C "$extract_dir"
fi

source_binary="$extract_dir/$binary_name"
[[ -f "$source_binary" ]] || die "${asset} does not contain ${binary_name}"
mkdir -p "$install_dir"
destination="$install_dir/$binary_name"
temporary_destination="${destination}.new.$$"
cp "$source_binary" "$temporary_destination"
chmod 0755 "$temporary_destination"
mv -f "$temporary_destination" "$destination"

path_contains_install_dir=false
case ":${PATH}:" in
    *":${install_dir}:"*) path_contains_install_dir=true ;;
esac

if [[ "$path_contains_install_dir" == false ]]; then
    if [[ "$os" == "windows" ]] && command -v powershell.exe >/dev/null 2>&1 && command -v cygpath >/dev/null 2>&1; then
        install_dir_windows="$(cygpath -w "$install_dir")"
        ZPEEK_INSTALL_DIR_WINDOWS="$install_dir_windows" powershell.exe -NoProfile -Command \
            '$dir=$env:ZPEEK_INSTALL_DIR_WINDOWS; $path=[Environment]::GetEnvironmentVariable("Path", "User"); if (($path -split ";") -notcontains $dir) { [Environment]::SetEnvironmentVariable("Path", (($path.TrimEnd(";") + ";" + $dir).TrimStart(";")), "User") }' \
            >/dev/null
        printf 'Added %s to the Windows user PATH.\n' "$install_dir_windows"
    else
        shell_name="$(basename "${SHELL:-sh}")"
        case "$shell_name" in
            zsh) profile="$HOME/.zshrc" ;;
            bash) profile="$HOME/.bashrc" ;;
            fish)
                profile="$HOME/.config/fish/conf.d/zpeek.fish"
                mkdir -p "$(dirname "$profile")"
                path_line="fish_add_path \"$install_dir\""
                ;;
            *) profile="$HOME/.profile" ;;
        esac
        path_line="${path_line:-export PATH=\"$install_dir:\$PATH\"}"
        if ! grep -Fqx "$path_line" "$profile" 2>/dev/null; then
            printf '\n# zpeek\n%s\n' "$path_line" >>"$profile"
        fi
        printf 'Added %s to PATH in %s.\n' "$install_dir" "$profile"
    fi
fi

printf 'zpeek installed at %s\n' "$destination"
if [[ "$path_contains_install_dir" == false ]]; then
    printf 'Restart the terminal, then run: zpeek\n'
else
    printf 'Run: zpeek\n'
fi
