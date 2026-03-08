# opencv-gpu

Shell script to build and install **OpenCV with full CUDA + cuDNN + NumPy 2 support** from source on Ubuntu 24.04 / Python 3.12.

## Requirements

- NVIDIA GPU with CUDA drivers installed
- CUDA Toolkit (`nvcc` in PATH)
- cuDNN 8 or 9
- `sudo` access

## Install

### 1. Prerequisites

#### NVIDIA driver

```bash
sudo apt-get install -y nvidia-driver-570
sudo reboot
nvidia-smi   # verify
```

#### CUDA Toolkit

```bash
wget https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb
sudo dpkg -i cuda-keyring_1.1-1_all.deb
sudo apt-get update
sudo apt-get install -y cuda-toolkit-12-x
```

Add to `~/.bashrc`:

```bash
export PATH=/usr/local/cuda/bin:$PATH
export LD_LIBRARY_PATH=/usr/local/cuda/lib64:$LD_LIBRARY_PATH
```

```bash
source ~/.bashrc
nvcc --version   # verify
```

#### cuDNN

```bash
sudo apt-get install -y libcudnn9-cuda-12 libcudnn9-dev-cuda-12
dpkg -l | grep cudnn   # verify
```

### 2. Clone and run

```bash
git clone https://github.com/juls/opencv-gpu.git
cd opencv-gpu
bash install-ubuntu24.sh
```

The script asks for confirmation twice: once at startup and once before `sudo make install` (so you can review the cmake summary first).

To skip both prompts:

```bash
bash install-ubuntu24.sh -y
```

**Optional — NVDEC hardware decoding:** download the [Video Codec SDK](https://developer.nvidia.com/nvidia-video-codec-sdk) and place the `.zip` inside the `opencv-gpu/` folder before running the script.

### 3. Verify

```bash
python3.12 -c "import cv2, numpy; print(cv2.__version__, numpy.__version__); print(cv2.cuda.getCudaEnabledDeviceCount(), 'CUDA device(s)')"
```

> The build takes ~20–40 min depending on your CPU. Sources are kept in `~/opencv-build` and can be deleted afterwards.

## Options

```
--version=X.Y.Z   OpenCV version to build  (default: 4.12.0)
--build-dir=DIR   Directory for sources and build files (default: ~/opencv-build)
--skip-deps       Skip apt-get install and pip install
-y, --yes         Skip the confirmation prompt
```

Example:

```bash
bash install-ubuntu24.sh --version=4.10.0
```

## What the script does

1. Installs system build dependencies (GTK, FFmpeg, TBB, HDF5, etc.)
2. Installs NumPy 2 via pip (`numpy>=2.0`) — required for ABI compatibility
3. Installs NVCUVID headers from the Video Codec SDK zip if present
4. Creates `cudnn.h` / `cudnn_version.h` symlinks if cuDNN 9 is detected
5. Clones `opencv` and `opencv_contrib` at the specified tag
6. Runs `cmake` with CUDA, cuDNN, and NumPy 2 paths auto-configured
7. Builds with `make -j$(nproc)`, then **pauses for confirmation** before installing system-wide
8. Installs to `/usr/local` and verifies `cv2.cuda.getCudaEnabledDeviceCount()`

## Verify after install

```bash
python3.12 -c "import cv2, numpy; print(cv2.__version__, numpy.__version__); print(cv2.cuda.getCudaEnabledDeviceCount(), 'CUDA device(s)')"
```

## Uninstall

```bash
bash uninstall.sh
```

## cuDNN 9 note

Ubuntu 24.04 installs cuDNN 9 via apt. cuDNN 9 splits the previous monolithic
`cudnn.h` into versioned headers (`cudnn_v9.h`, `cudnn_version_v9.h`).
OpenCV's `FindCUDNN.cmake` looks for the old names, so the script creates two
symlinks automatically:

```
/usr/include/x86_64-linux-gnu/cudnn.h         → cudnn_v9.h
/usr/include/x86_64-linux-gnu/cudnn_version.h → cudnn_version_v9.h
```

## NVIDIA Video Codec SDK (NVCUVID / NVDEC)

Enabling `WITH_NVCUVID` requires headers (`nvcuvid.h`, `cuviddec.h`) that are **not**
included in the CUDA Toolkit — download from
[developer.nvidia.com/nvidia-video-codec-sdk](https://developer.nvidia.com/nvidia-video-codec-sdk)
(free NVIDIA account required).

Place the downloaded `Video_Codec_SDK_*.zip` in **any** of these locations before
running the script — it will be found and extracted automatically:

```
opencv-gpu/      ← same directory as the script (recommended)
~/
~/Downloads/
```

If the zip is not found, the script warns and builds without NVCUVID.

### Video Codec SDK 13.0.37 requirements

| Requirement | Details |
|---|---|
| GPU | NVIDIA Quadro, Tesla, GRID, or GeForce |
| NVIDIA Linux driver | 570.0 or newer |

Check your driver version:

```bash
nvidia-smi --query-gpu=driver_version --format=csv,noheader
```

If your driver is older, download an older SDK version from the
[release archive](https://developer.nvidia.com/nvidia-video-codec-sdk/download).

## License

MIT
