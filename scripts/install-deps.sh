#!/usr/bin/env bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "run as root: sudo scripts/install-deps.sh" >&2
    exit 1
fi

apt-get update

apt-get install -y --no-install-recommends \
    build-essential \
    git \
    meson \
    ninja-build \
    pkg-config \
    cmake \
    autoconf \
    automake \
    libtool \
    nasm \
    yasm \
    curl \
    unzip \
    patchelf \
    python3 \
    python3-pip \
    python3-setuptools \
    cython3 \
    libvulkan-dev \
    vulkan-tools \
    mesa-vulkan-drivers \
    glslang-tools \
    spirv-tools \
    libpython3-dev \
    zlib1g-dev \
    libzimg-dev \
    libavcodec-dev \
    libavformat-dev \
    libavutil-dev \
    libswscale-dev \
    libswresample-dev \
    libavfilter-dev \
    libass-dev \
    libplacebo-dev \
    libjpeg-dev \
    libpng-dev \
    libx11-dev \
    libxext-dev \
    libxrandr-dev \
    libxfixes-dev \
    libxpresent-dev \
    libxss-dev \
    libxv-dev \
    libxkbcommon-dev \
    libwayland-dev \
    wayland-protocols \
    libdrm-dev \
    libgbm-dev \
    libegl-dev \
    libgl-dev \
    libpulse-dev \
    libasound2-dev \
    libpipewire-0.3-dev \
    libuchardet-dev \
    libbluray-dev \
    libdvdnav-dev \
    libcdio-dev \
    libcdio-paranoia-dev \
    liblcms2-dev \
    libsixel-dev \
    liblua5.2-dev \
    libmujs-dev \
    libarchive-dev \
    libzstd-dev \
    libsndio-dev \
    librubberband-dev \
    doctest-dev \
    libfmt-dev \
    libjack-dev \
    libva-dev \
    libvdpau-dev \
    libvulkan-volk-dev \
    glslang-dev \
    ocl-icd-opencl-dev

echo "dependencies installed"
