#!/usr/bin/env bash
# opencv-gpu — uninstaller
set -euo pipefail

GREEN='\033[0;32m'; BLUE='\033[0;34m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'

info() { echo -e "\n${BLUE}${BOLD}=== $* ===${NC}"; }
ok()   { echo -e "  ${GREEN}✓ $*${NC}"; }
warn() { echo -e "  ${YELLOW}! $*${NC}"; }

PYTHON_BIN="python3.12"
YES=0

usage() {
    echo "Usage: $0 [python_executable] [-y]"
    echo "  python_executable  Python to remove cv2 from (default: python3.12)"
    echo "  -y                 Skip confirmation"
    exit 0
}

for arg in "$@"; do
    case "$arg" in
        -y|--yes)  YES=1 ;;
        -h|--help) usage ;;
        -*)        echo "Unknown flag: $arg"; usage ;;
        *)         PYTHON_BIN="$arg" ;;
    esac
done

PYTHON_EXECUTABLE=$(command -v "$PYTHON_BIN" 2>/dev/null) \
    || { echo "  '$PYTHON_BIN' not found."; exit 1; }

PYTHON_VER=$("$PYTHON_EXECUTABLE" -c \
    "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")

SITE_PKG=$("$PYTHON_EXECUTABLE" -c \
    "import site; p=site.getsitepackages(); print(p[0] if p else '')" 2>/dev/null || echo "")

echo ""
echo -e "${BOLD}opencv-gpu uninstaller${NC}"
echo ""
echo "  Python   : $PYTHON_EXECUTABLE ($PYTHON_VER)"
echo "  cv2 path : ${SITE_PKG}/cv2"
echo "  C++ libs : /usr/local (libopencv_*, include/opencv4)"
echo ""

if [[ "$YES" -ne 1 ]]; then
    read -r -p "Proceed? [y/N] " answer
    [[ "$answer" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
fi

info "Removing Python bindings"
if [[ -n "$SITE_PKG" && -d "$SITE_PKG/cv2" ]]; then
    sudo rm -rf "$SITE_PKG/cv2"
    ok "Removed $SITE_PKG/cv2"
else
    warn "cv2 not found in $SITE_PKG — nothing to remove"
fi

info "Removing OpenCV C++ libraries"

[[ -d /usr/local/include/opencv4 ]] && \
    sudo rm -rf /usr/local/include/opencv4 && ok "Removed /usr/local/include/opencv4"

shopt -s nullglob
libs=( /usr/local/lib/libopencv_* )
if [[ ${#libs[@]} -gt 0 ]]; then
    sudo rm -f "${libs[@]}"
    ok "Removed ${#libs[@]} libopencv_* files"
else
    warn "No libopencv_* found in /usr/local/lib"
fi
shopt -u nullglob

[[ -d /usr/local/lib/cmake/opencv4 ]] && \
    sudo rm -rf /usr/local/lib/cmake/opencv4 && ok "Removed cmake config"

[[ -f /usr/local/lib/pkgconfig/opencv4.pc ]] && \
    sudo rm -f /usr/local/lib/pkgconfig/opencv4.pc && ok "Removed pkg-config file"

find /usr/local/lib -name "cv2*" -delete 2>/dev/null || true

sudo ldconfig
ok "ldconfig updated"

echo ""
ok "Uninstall complete."
