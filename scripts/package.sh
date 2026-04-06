#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
VPN_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="/tmp/vpn-build-$$"

C_BOLD='\033[1m'
C_GREEN='\033[32m'
C_CYAN='\033[36m'
C_RED='\033[31m'
C_RESET='\033[0m'

die() { echo -e "${C_RED}Error: $1${C_RESET}" >&2; exit 1; }

get_current_version() {
    git -C "$VPN_DIR" describe --tags --abbrev=0 2>/dev/null | sed 's/^v//'
}

bump_version() {
    local current="$1" part="$2"
    local major minor patch
    IFS='.' read -r major minor patch <<< "$current"
    case "$part" in
        major) echo "$((major + 1)).0.0" ;;
        minor) echo "${major}.$((minor + 1)).0" ;;
        patch) echo "${major}.${minor}.$((patch + 1))" ;;
    esac
}

show_usage() {
    echo -e "${C_BOLD}VPN Package Builder${C_RESET}"
    echo ""
    echo "Usage: vpn package [major|minor|patch|vX.Y.Z]"
    echo ""
    echo "  major     Bump major version (1.2.3 -> 2.0.0)"
    echo "  minor     Bump minor version (1.2.3 -> 1.3.0)"
    echo "  patch     Bump patch version (1.2.3 -> 1.2.4)"
    echo "  vX.Y.Z    Set explicit version"
    echo ""
    local cur=$(get_current_version)
    if [ -n "$cur" ]; then
        echo "  Current version: v${cur}"
    else
        echo "  No version tags found. First release will be v1.0.0"
    fi
}

build_package() {
    local version="$1"
    local tag="v${version}"
    local zip_name="vpn-manager-${version}.zip"
    local stage="$BUILD_DIR/vpn"

    echo -e "${C_BOLD}Building ${C_CYAN}${zip_name}${C_RESET}"
    echo ""

    # Ensure clean git state
    if [ -n "$(git -C "$VPN_DIR" status --porcelain)" ]; then
        die "Working directory is not clean. Commit or stash changes first."
    fi

    # Prepare staging directory
    rm -rf "$BUILD_DIR"
    mkdir -p "$stage/scripts"

    # Copy core files (exclude dev/build scripts and backups)
    cp "$VPN_DIR/scripts/config.sh"  "$stage/scripts/"
    cp "$VPN_DIR/scripts/manager.sh" "$stage/scripts/"
    cp "$VPN_DIR/scripts/cli.sh"     "$stage/scripts/"
    cp "$VPN_DIR/scripts/setup.sh"   "$stage/scripts/"
    cp "$VPN_DIR/vpn.conf.example.yaml" "$stage/"

    # Write version file
    echo "$version" > "$stage/VERSION"

    # Strip package/build commands from cli.sh
    sed -i '/# --- PACKAGE-ONLY-START ---/,/# --- PACKAGE-ONLY-END ---/d' "$stage/scripts/cli.sh"

    # Make scripts executable
    chmod +x "$stage/scripts/"*.sh

    # Generate install script
    cat > "$stage/install.sh" << 'INSTALL_EOF'
#!/bin/bash
set -e

C_BOLD='\033[1m'
C_GREEN='\033[32m'
C_CYAN='\033[36m'
C_RED='\033[31m'
C_RESET='\033[0m'

INSTALL_DIR="/opt/vpn-manager"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VERSION=$(cat "$SCRIPT_DIR/VERSION" 2>/dev/null || echo "unknown")

echo -e "${C_BOLD}VPN Manager ${C_CYAN}v${VERSION}${C_RESET}"
echo ""

if [ "$EUID" -ne 0 ] && ! sudo -n true 2>/dev/null; then
    echo -e "${C_RED}Needs sudo access.${C_RESET}"
    exit 1
fi

echo -e "  Installing to ${C_CYAN}${INSTALL_DIR}${C_RESET}..."
sudo mkdir -p "$INSTALL_DIR"
sudo cp -r "$SCRIPT_DIR/scripts"  "$INSTALL_DIR/"
sudo cp    "$SCRIPT_DIR/VERSION"  "$INSTALL_DIR/"
sudo cp    "$SCRIPT_DIR/vpn.conf.example.yaml" "$INSTALL_DIR/"
sudo chmod +x "$INSTALL_DIR/scripts/"*.sh
sudo ln -sf "$INSTALL_DIR/scripts/cli.sh" /usr/local/bin/vpn

if command -v vpn &>/dev/null; then
    echo -e "${C_GREEN}Installed.${C_RESET} (v${VERSION} at ${INSTALL_DIR})"
    echo ""
    echo "  cp vpn.conf.example.yaml vpn.conf.yaml  # configure"
    echo "  vpn setup                                # first run"
else
    echo -e "${C_RED}'vpn' not in PATH — add /usr/local/bin to PATH${C_RESET}"
fi

echo ""
rm -f "$SCRIPT_DIR/install.sh"
INSTALL_EOF

    chmod +x "$stage/install.sh"

    # Create zip
    echo "  Creating zip..."
    (cd "$BUILD_DIR" && zip -r "$VPN_DIR/dist/${zip_name}" vpn/)

    # Tag only after successful zip
    echo -e "  Tagging ${C_CYAN}${tag}${C_RESET}..."
    git -C "$VPN_DIR" tag -a "$tag" -m "Release ${tag}"

    # Cleanup
    rm -rf "$BUILD_DIR"

    local zip_path="$VPN_DIR/dist/${zip_name}"
    local zip_size=$(du -h "$zip_path" | awk '{print $1}')

    echo ""
    echo -e "${C_GREEN}Package built successfully!${C_RESET}"
    echo ""
    echo "  File:    dist/${zip_name}"
    echo "  Size:    ${zip_size}"
    echo "  Tag:     ${tag}"
    echo ""
    echo "  To install on a target machine:"
    echo "    unzip ${zip_name} && cd vpn && ./install.sh"
}

case "${1:-}" in
    -h|--help|"")
        show_usage
        ;;
    major|minor|patch)
        current=$(get_current_version)
        if [ -z "$current" ]; then
            current="0.0.0"
        fi
        version=$(bump_version "$current" "$1")
        mkdir -p "$VPN_DIR/dist"
        build_package "$version"
        ;;
    v*.*.*)
        version="${1#v}"
        mkdir -p "$VPN_DIR/dist"
        build_package "$version"
        ;;
    *)
        die "Invalid argument: $1. Use major, minor, patch, or vX.Y.Z"
        ;;
esac
