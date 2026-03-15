#!/usr/bin/env bash
# opencv-gpu — Ubuntu 24.04 / Python 3.12
# Builds OpenCV with full CUDA + cuDNN + NumPy 2 support from source.
set -euo pipefail

PYTHON_VER="3.12"
PYTHON_BIN="python3.12"

SYS_PACKAGES=(
    build-essential cmake git pkg-config
    libgtk-3-dev
    qt6-base-dev libqt6core5compat6-dev
    libavcodec-dev libavformat-dev libswscale-dev libavutil-dev
    libxvidcore-dev libx264-dev
    libtbb-dev
    libjpeg-dev libpng-dev libtiff-dev
    libdc1394-dev
    libopenexr-dev
    libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev
    python3.12-dev python3-pip
    libopenblas-dev liblapack-dev liblapacke-dev
    libv4l-dev v4l-utils
    libhdf5-dev
)

OPENCV_VERSION="${OPENCV_VERSION:-4.12.0}"
BUILD_DIR="${BUILD_DIR:-$HOME/opencv-build}"
SKIP_DEPS=0
YES=0

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info() { echo -e "\n${CYAN}${BOLD}=== $* ===${NC}"; }
step() { echo -e "  ${BLUE}» $*${NC}"; }
ok()   { echo -e "  ${GREEN}✓ $*${NC}"; }
warn() { echo -e "  ${YELLOW}! $*${NC}"; }
err()  { echo -e "  ${RED}✗ $*${NC}" >&2; exit 1; }

usage() {
    echo "Usage: $0 [options]"
    echo "  --version=X.Y.Z   OpenCV version  (default: $OPENCV_VERSION)"
    echo "  --build-dir=DIR   Build directory (default: $BUILD_DIR)"
    echo "  --skip-deps       Skip apt-get install and pip install"
    echo "  -y, --yes         Skip confirmation prompt"
    exit 0
}

for arg in "$@"; do
    case "$arg" in
        --version=*)   OPENCV_VERSION="${arg#*=}" ;;
        --build-dir=*) BUILD_DIR="${arg#*=}" ;;
        --skip-deps)   SKIP_DEPS=1 ;;
        -y|--yes)      YES=1 ;;
        -h|--help)     usage ;;
        *) echo "Unknown argument: $arg"; usage ;;
    esac
done

# ── GPU compute capability ────────────────────────────────────────────────────
detect_cuda_arch() {
    if command -v nvidia-smi &>/dev/null; then
        nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null \
            | head -1 | tr -d ' '
    else
        echo "8.6"
    fi
}

# ── NVIDIA Video Codec SDK (NVCUVID / NVDEC) ─────────────────────────────────
# Headers are NOT in the CUDA toolkit — download from developer.nvidia.com.
# Place Video_Codec_SDK_*.zip next to this script, in ~/, or ~/Downloads/.
prepare_nvcuvid() {
    local cuda_inc="/usr/local/cuda/include"

    if [[ -f "$cuda_inc/nvcuvid.h" && -f "$cuda_inc/cuviddec.h" ]]; then
        step "NVCUVID headers already present"
        return
    fi

    local zip=""
    for candidate in \
        "$(dirname "$0")/Video_Codec_SDK"*.zip \
        ~/Video_Codec_SDK*.zip \
        ~/Downloads/Video_Codec_SDK*.zip
    do
        for f in $candidate; do
            [[ -f "$f" ]] && { zip="$f"; break 2; }
        done
    done

    if [[ -z "$zip" ]]; then
        warn "Video Codec SDK zip not found — building without NVCUVID."
        warn "Download from https://developer.nvidia.com/nvidia-video-codec-sdk"
        warn "and place Video_Codec_SDK_*.zip next to this script, then re-run."
        NVCUVID_ENABLED=0
        return
    fi

    step "Installing NVCUVID headers from $(basename "$zip")"
    local tmp
    tmp=$(mktemp -d)
    unzip -q "$zip" -d "$tmp"

    local iface
    iface=$(find "$tmp" -maxdepth 3 -name "nvcuvid.h" -printf "%h\n" | head -1)
    [[ -z "$iface" ]] && err "nvcuvid.h not found inside $(basename "$zip")"

    sudo cp "$iface/nvcuvid.h"  "$cuda_inc/"
    sudo cp "$iface/cuviddec.h" "$cuda_inc/"
    [[ -f "$iface/nvEncodeAPI.h" ]] && sudo cp "$iface/nvEncodeAPI.h" "$cuda_inc/"

    local stubs_src
    stubs_src=$(find "$tmp" -path "*/linux/stubs/x86_64" -type d | head -1)
    if [[ -n "$stubs_src" ]]; then
        sudo cp "$stubs_src"/libnvcuvid.so       "$cuda_inc/../lib64/" 2>/dev/null || true
        sudo cp "$stubs_src"/libnvidia-encode.so "$cuda_inc/../lib64/" 2>/dev/null || true
    fi

    rm -rf "$tmp"
    ok "NVCUVID headers installed"
    NVCUVID_ENABLED=1
}

# ── cuDNN 9 compatibility symlinks ────────────────────────────────────────────
# OpenCV's FindCUDNN.cmake looks for cudnn.h / cudnn_version.h by exact name.
# cuDNN 9 (apt) only ships cudnn_v9.h / cudnn_version_v9.h.
prepare_cudnn() {
    local inc="/usr/include/x86_64-linux-gnu"
    if [[ ! -f "$inc/cudnn.h" && -f "$inc/cudnn_v9.h" ]]; then
        sudo ln -sf cudnn_v9.h "$inc/cudnn.h"
        step "cuDNN 9: created cudnn.h symlink"
    fi
    if [[ ! -f "$inc/cudnn_version.h" && -f "$inc/cudnn_version_v9.h" ]]; then
        sudo ln -sf cudnn_version_v9.h "$inc/cudnn_version.h"
        step "cuDNN 9: created cudnn_version.h symlink"
    fi
}

# ── Find cuDNN library ────────────────────────────────────────────────────────
find_cudnn_lib() {
    local dirs=( /usr/lib/x86_64-linux-gnu /usr/local/lib /usr/local/cuda/lib64 )
    local names=( libcudnn.so libcudnn_v9.so libcudnn.so.9 libcudnn.so.8 )
    for d in "${dirs[@]}"; do
        for n in "${names[@]}"; do
            [[ -f "$d/$n" ]] && { echo "$d/$n"; return; }
        done
    done
    err "libcudnn not found. Is cuDNN installed?"
}

# ── System dependencies ───────────────────────────────────────────────────────
install_deps() {
    info "Installing system dependencies"
    sudo apt-get update -qq
    sudo apt-get install -y "${SYS_PACKAGES[@]}"
}

# ── NumPy 2 ───────────────────────────────────────────────────────────────────
install_numpy2() {
    info "Installing NumPy 2"
    "$PYTHON_BIN" -m pip install --break-system-packages "numpy>=2.0"
    local ver
    ver=$("$PYTHON_BIN" -c "import numpy; print(numpy.__version__)")
    ok "NumPy $ver"
}

# ── Clone sources ─────────────────────────────────────────────────────────────
clone_sources() {
    info "Cloning OpenCV $OPENCV_VERSION"
    mkdir -p "$BUILD_DIR"

    if [[ -d "$BUILD_DIR/opencv" ]]; then
        step "Reusing existing $BUILD_DIR/opencv"
    else
        git clone --depth 1 --branch "$OPENCV_VERSION" \
            https://github.com/opencv/opencv.git "$BUILD_DIR/opencv"
    fi

    if [[ -d "$BUILD_DIR/opencv_contrib" ]]; then
        step "Reusing existing $BUILD_DIR/opencv_contrib"
    else
        git clone --depth 1 --branch "$OPENCV_VERSION" \
            https://github.com/opencv/opencv_contrib.git "$BUILD_DIR/opencv_contrib"
    fi
}

# ── Detect Python + NumPy paths for cmake ─────────────────────────────────────
get_python_paths() {
    PYTHON_EXECUTABLE=$(command -v "$PYTHON_BIN") \
        || err "$PYTHON_BIN not found."

    PYTHON_INCLUDE=$("$PYTHON_BIN" -c \
        "import sysconfig; print(sysconfig.get_path('include'))")

    PYTHON_PACKAGES=$("$PYTHON_BIN" -c \
        "import site; print(site.getsitepackages()[0])")

    NUMPY_INCLUDE=$("$PYTHON_BIN" -c \
        "import numpy; print(numpy.get_include())")

    local lib_dir lib_name
    lib_dir=$("$PYTHON_BIN" -c \
        "import sysconfig; print(sysconfig.get_config_var('LIBDIR') or '')")
    lib_name=$("$PYTHON_BIN" -c \
        "import sysconfig; print(sysconfig.get_config_var('LDLIBRARY') or '')")

    PYTHON_LIBRARY=""
    if [[ -n "$lib_dir" && -n "$lib_name" && -f "$lib_dir/$lib_name" ]]; then
        PYTHON_LIBRARY="$lib_dir/$lib_name"
    fi

    if [[ -z "$PYTHON_LIBRARY" ]]; then
        for candidate in \
            "/usr/lib/x86_64-linux-gnu/libpython${PYTHON_VER}.so" \
            "/usr/lib/x86_64-linux-gnu/libpython${PYTHON_VER}.so.1" \
            "/usr/lib/libpython${PYTHON_VER}.so"
        do
            [[ -f "$candidate" ]] && { PYTHON_LIBRARY="$candidate"; break; }
        done
    fi
}

# ── cmake + make + install ────────────────────────────────────────────────────
build_opencv() {
    info "Configuring and building OpenCV"

    local CUDA_ARCH BUILD_SUBDIR CUDNN_INCLUDE CUDNN_LIB
    CUDA_ARCH=$(detect_cuda_arch)
    BUILD_SUBDIR="$BUILD_DIR/opencv/build"
    CUDNN_INCLUDE="/usr/include/x86_64-linux-gnu"
    CUDNN_LIB=$(find_cudnn_lib)

    step "GPU compute capability: $CUDA_ARCH"
    step "cuDNN library:          $CUDNN_LIB"
    step "NumPy include:          $NUMPY_INCLUDE"
    step "Python packages path:   $PYTHON_PACKAGES"

    mkdir -p "$BUILD_SUBDIR"

    CMAKE_ARGS=(
        -D CMAKE_BUILD_TYPE=RELEASE
        -D CMAKE_INSTALL_PREFIX=/usr/local
        # ── CUDA ──────────────────────────────────────────────────────────────
        -D WITH_CUDA=ON
        -D WITH_CUDNN=ON
        -D OPENCV_DNN_CUDA=ON
        -D CUDA_ARCH_BIN="$CUDA_ARCH"
        -D ENABLE_FAST_MATH=1
        -D CUDA_FAST_MATH=1
        -D WITH_CUBLAS=1
        -D WITH_NVCUVID="${NVCUVID_ENABLED:-0}"
        # ── cuDNN ─────────────────────────────────────────────────────────────
        -D CUDNN_INCLUDE_DIR="$CUDNN_INCLUDE"
        -D CUDNN_LIBRARY="$CUDNN_LIB"
        # ── Python ────────────────────────────────────────────────────────────
        -D PYTHON3_EXECUTABLE="$PYTHON_EXECUTABLE"
        -D PYTHON3_INCLUDE_DIR="$PYTHON_INCLUDE"
        -D PYTHON3_NUMPY_INCLUDE_DIRS="$NUMPY_INCLUDE"
        -D PYTHON3_PACKAGES_PATH="${PYTHON_PACKAGES#/usr/local/}"
        -D BUILD_opencv_python2=OFF
        -D BUILD_opencv_python3=ON
        # ── Extra modules ─────────────────────────────────────────────────────
        -D OPENCV_ENABLE_NONFREE=ON
        -D OPENCV_EXTRA_MODULES_PATH="$BUILD_DIR/opencv_contrib/modules"
        # ── Hardware ──────────────────────────────────────────────────────────
        -D WITH_QT=ON
        -D WITH_TBB=ON
        -D WITH_V4L=ON
        -D WITH_OPENGL=ON
        -D WITH_GSTREAMER=ON
        # ── Skip unneeded targets ─────────────────────────────────────────────
        -D BUILD_EXAMPLES=OFF
        -D INSTALL_C_EXAMPLES=OFF
        -D INSTALL_PYTHON_EXAMPLES=OFF
        -D BUILD_TESTS=OFF
        -D BUILD_PERF_TESTS=OFF
    )

    [[ -n "$PYTHON_LIBRARY" ]] && CMAKE_ARGS+=(-D PYTHON3_LIBRARY="$PYTHON_LIBRARY")

    # cblas.h and lapacke.h live in different dirs; cmake's OpenBLAS detection
    # needs both in the same directory.
    local cblas_dir
    cblas_dir=$(find /usr/include -name "cblas.h" -path "*openblas*" -printf "%h\n" 2>/dev/null | head -1)
    if [[ -n "$cblas_dir" && ! -f "$cblas_dir/lapacke.h" && -f /usr/include/lapacke.h ]]; then
        sudo ln -sf /usr/include/lapacke.h "$cblas_dir/lapacke.h"
        step "Created lapacke.h symlink in $cblas_dir"
    fi

    cmake "${CMAKE_ARGS[@]}" -S "$BUILD_DIR/opencv" -B "$BUILD_SUBDIR"
    make -C "$BUILD_SUBDIR" -j"$(nproc)"

    echo ""
    echo -e "${BOLD}Build complete. Review the cmake summary above before installing.${NC}"
    echo -e "  Install prefix : /usr/local"
    echo -e "  Python target  : $PYTHON_PACKAGES"
    echo ""
    read -r -p "Proceed with 'sudo make install'? [y/N] " confirm </dev/tty
    [[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted. Build artifacts kept in $BUILD_SUBDIR"; exit 0; }

    sudo make -C "$BUILD_SUBDIR" install
    sudo ldconfig
}

# ── Verify ────────────────────────────────────────────────────────────────────
verify() {
    info "Verifying installation"
    "$PYTHON_BIN" - <<'PYEOF'
import cv2, numpy
print(f"  OpenCV : {cv2.__version__}")
print(f"  NumPy  : {numpy.__version__}")
n = cv2.cuda.getCudaEnabledDeviceCount()
print(f"  CUDA devices: {n}")
assert n > 0, "No CUDA devices detected — check your build configuration"
PYEOF
    ok "Installation verified!"
}

# ── Main ──────────────────────────────────────────────────────────────────────
NVCUVID_ENABLED=1   # may be set to 0 by prepare_nvcuvid if SDK zip not found

echo ""
echo -e "${BOLD}opencv-gpu — Ubuntu 24.04 / Python ${PYTHON_VER}${NC}"
echo ""
echo "  OpenCV version : ${OPENCV_VERSION}"
echo "  Build dir      : $BUILD_DIR"
echo "  Jobs           : $(nproc)"
echo "  CUDA arch      : sm_$(detect_cuda_arch | tr -d '.')"
echo ""

if [[ "$YES" -ne 1 ]]; then
    read -r -p "Continue? [y/N] " answer
    [[ "$answer" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
fi

if [[ "$SKIP_DEPS" -ne 1 ]]; then
    install_deps
    install_numpy2
fi

prepare_nvcuvid
prepare_cudnn
clone_sources
get_python_paths
build_opencv
verify

echo ""
ok "Done! Run: $PYTHON_BIN -c \"import cv2; print(cv2.cuda.getCudaEnabledDeviceCount(), 'CUDA device(s)')\""
