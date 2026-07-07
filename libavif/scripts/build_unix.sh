#!/usr/bin/env bash
# =============================================================================
# 通用构建脚本 (Unix: Linux / macOS runner)
#
# 用法:
#   scripts/build_unix.sh <target>
#
# 支持的 <target>:
#   macos-arm64            macOS Apple Silicon (native)
#   macos-x86_64           macOS Intel
#   ios-arm64              iOS 设备
#   ios-sim-arm64          iOS 模拟器 (Apple Silicon)
#   ios-sim-x86_64         iOS 模拟器 (Intel)
#   linux-x86_64           Linux (native)
#   android-arm64-v8a      Android arm64
#   android-armeabi-v7a    Android armv7
#   harmony-arm64-v8a      HarmonyOS / OpenHarmony arm64
#
# 依赖 (由 CI 或调用者预先安装):
#   meson, ninja, nasm, pkg-config, cmake, git, curl
#
# 交叉编译需要的环境变量:
#   Android : ANDROID_NDK_HOME
#   Harmony : OHOS_SDK_NATIVE  (指向 .../native 目录)
#
# 产物安装到: $PWD/out/<target>/{include,lib}
# =============================================================================
set -euo pipefail

TARGET="${1:?用法: build_unix.sh <target>}"

# --- 解析仓库根目录并加载版本配置 ---------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck disable=SC1091
source "${REPO_ROOT}/config.env"

WORK="${REPO_ROOT}/work/${TARGET}"          # 源码与中间构建目录
PREFIX="${REPO_ROOT}/out/${TARGET}"         # 最终安装前缀 (include + lib)
JOBS="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"

rm -rf "${PREFIX}"
mkdir -p "${WORK}" "${PREFIX}"

echo "==> Target        : ${TARGET}"
echo "==> libavif       : ${LIBAVIF_VERSION}"
echo "==> dav1d         : ${DAV1D_VERSION}"
echo "==> Prefix        : ${PREFIX}"
echo "==> Parallel jobs : ${JOBS}"

# =============================================================================
# 1) 获取源码
# =============================================================================
fetch_sources() {
  if [ ! -d "${WORK}/dav1d/.git" ]; then
    git clone --depth 1 --branch "${DAV1D_VERSION}" \
      https://code.videolan.org/videolan/dav1d.git "${WORK}/dav1d"
  fi
  if [ ! -d "${WORK}/libavif/.git" ]; then
    git clone --depth 1 --branch "${LIBAVIF_VERSION}" \
      https://github.com/AOMediaCodec/libavif.git "${WORK}/libavif"
  fi
}

# =============================================================================
# 2) 针对不同 target 计算构建参数
#    输出全局变量:
#      MESON_CROSS_ARGS   -> 传给 meson 的 --cross-file 参数 (可为空)
#      CMAKE_CROSS_ARGS   -> 传给 libavif cmake 的交叉参数数组
# =============================================================================
MESON_CROSS_ARGS=()
CMAKE_CROSS_ARGS=()

configure_target() {
  case "${TARGET}" in
    macos-arm64)
      CMAKE_CROSS_ARGS=(
        -DCMAKE_OSX_ARCHITECTURES=arm64
        -DCMAKE_OSX_DEPLOYMENT_TARGET="${MACOS_DEPLOYMENT_TARGET}"
      )
      ;;
    macos-x86_64)
      # Apple 的 SDK 路径依赖 Xcode 版本，用 xcrun 动态生成 meson cross file。
      gen_apple_meson_cross "macosx" "x86_64" "darwin" "x86_64" \
        "-mmacosx-version-min=${MACOS_DEPLOYMENT_TARGET}"
      MESON_CROSS_ARGS=(--cross-file "${WORK}/apple.cross.txt")
      CMAKE_CROSS_ARGS=(
        -DCMAKE_OSX_ARCHITECTURES=x86_64
        -DCMAKE_OSX_DEPLOYMENT_TARGET="${MACOS_DEPLOYMENT_TARGET}"
      )
      ;;
    ios-arm64)
      gen_apple_meson_cross "iphoneos" "arm64" "darwin" "aarch64" \
        "-miphoneos-version-min=${IOS_DEPLOYMENT_TARGET}"
      MESON_CROSS_ARGS=(--cross-file "${WORK}/apple.cross.txt")
      CMAKE_CROSS_ARGS=(
        -DCMAKE_SYSTEM_NAME=iOS
        -DCMAKE_OSX_ARCHITECTURES=arm64
        -DCMAKE_OSX_SYSROOT=iphoneos
        -DCMAKE_OSX_DEPLOYMENT_TARGET="${IOS_DEPLOYMENT_TARGET}"
      )
      ;;
    ios-sim-arm64)
      gen_apple_meson_cross "iphonesimulator" "arm64" "darwin" "aarch64" \
        "-mios-simulator-version-min=${IOS_DEPLOYMENT_TARGET}"
      MESON_CROSS_ARGS=(--cross-file "${WORK}/apple.cross.txt")
      CMAKE_CROSS_ARGS=(
        -DCMAKE_SYSTEM_NAME=iOS
        -DCMAKE_OSX_ARCHITECTURES=arm64
        -DCMAKE_OSX_SYSROOT=iphonesimulator
        -DCMAKE_OSX_DEPLOYMENT_TARGET="${IOS_DEPLOYMENT_TARGET}"
      )
      ;;
    ios-sim-x86_64)
      gen_apple_meson_cross "iphonesimulator" "x86_64" "darwin" "x86_64" \
        "-mios-simulator-version-min=${IOS_DEPLOYMENT_TARGET}"
      MESON_CROSS_ARGS=(--cross-file "${WORK}/apple.cross.txt")
      CMAKE_CROSS_ARGS=(
        -DCMAKE_SYSTEM_NAME=iOS
        -DCMAKE_OSX_ARCHITECTURES=x86_64
        -DCMAKE_OSX_SYSROOT=iphonesimulator
        -DCMAKE_OSX_DEPLOYMENT_TARGET="${IOS_DEPLOYMENT_TARGET}"
      )
      ;;
    linux-x86_64)
      : # native, 无需交叉参数
      ;;
    android-arm64-v8a|android-armeabi-v7a)
      : "${ANDROID_NDK_HOME:?Android 目标需要设置 ANDROID_NDK_HOME}"
      local abi="${TARGET#android-}"
      # 动态生成 meson cross file (依赖 NDK 路径)
      gen_android_meson_cross "${abi}"
      MESON_CROSS_ARGS=(--cross-file "${WORK}/android-${abi}.cross.txt")
      CMAKE_CROSS_ARGS=(
        -DCMAKE_TOOLCHAIN_FILE="${ANDROID_NDK_HOME}/build/cmake/android.toolchain.cmake"
        -DANDROID_ABI="${abi}"
        -DANDROID_PLATFORM="android-${ANDROID_API}"
      )
      ;;
    harmony-arm64-v8a)
      : "${OHOS_SDK_NATIVE:?HarmonyOS 目标需要设置 OHOS_SDK_NATIVE (指向 .../native)}"
      gen_ohos_meson_cross
      MESON_CROSS_ARGS=(--cross-file "${WORK}/ohos-arm64.cross.txt")
      CMAKE_CROSS_ARGS=(
        -DCMAKE_TOOLCHAIN_FILE="${OHOS_SDK_NATIVE}/build/cmake/ohos.toolchain.cmake"
        -DOHOS_ARCH=arm64-v8a
        -DOHOS_PLATFORM=OHOS
      )
      ;;
    windows-x64-mingw)
      # 在 Linux 上用 mingw-w64 交叉编译 Windows x64 (gcc 工具链, 产物 .a)
      gen_mingw_meson_cross
      MESON_CROSS_ARGS=(--cross-file "${WORK}/mingw-x64.cross.txt")
      CMAKE_CROSS_ARGS=(
        -DCMAKE_SYSTEM_NAME=Windows
        -DCMAKE_C_COMPILER=x86_64-w64-mingw32-gcc
        -DCMAKE_CXX_COMPILER=x86_64-w64-mingw32-g++
        -DCMAKE_RC_COMPILER=x86_64-w64-mingw32-windres
      )
      ;;
    *)
      echo "未知 target: ${TARGET}" >&2
      exit 1
      ;;
  esac
}

# 生成 Apple (macOS/iOS/模拟器) meson cross file
#   参数: <sdk> <arch> <cpu_family> <cpu> <min_version_flag>
#   sdk: macosx / iphoneos / iphonesimulator
gen_apple_meson_cross() {
  local sdk="$1" arch="$2" cpu_family="$3" cpu="$4" minflag="$5"
  local sysroot cc cxx
  sysroot="$(xcrun --sdk "${sdk}" --show-sdk-path)"
  cc="$(xcrun --sdk "${sdk}" --find clang)"
  cxx="$(xcrun --sdk "${sdk}" --find clang++)"
  local ar strip
  ar="$(xcrun --sdk "${sdk}" --find ar)"
  strip="$(xcrun --sdk "${sdk}" --find strip)"

  cat > "${WORK}/apple.cross.txt" <<EOF
[binaries]
c = '${cc}'
cpp = '${cxx}'
ar = '${ar}'
strip = '${strip}'
pkg-config = 'pkg-config'

[built-in options]
c_args = ['-arch', '${arch}', '-isysroot', '${sysroot}', '${minflag}']
c_link_args = ['-arch', '${arch}', '-isysroot', '${sysroot}', '${minflag}']
cpp_args = ['-arch', '${arch}', '-isysroot', '${sysroot}', '${minflag}']
cpp_link_args = ['-arch', '${arch}', '-isysroot', '${sysroot}', '${minflag}']

[host_machine]
system = 'darwin'
cpu_family = '${cpu_family}'
cpu = '${cpu}'
endian = 'little'
EOF
}

# 生成 Android meson cross file (需要 NDK 的实际路径)
gen_android_meson_cross() {
  local abi="$1"
  local host_tag
  case "$(uname -s)" in
    Darwin) host_tag="darwin-x86_64" ;;
    *)      host_tag="linux-x86_64" ;;
  esac
  local ndk_bin="${ANDROID_NDK_HOME}/toolchains/llvm/prebuilt/${host_tag}/bin"
  local triple cpu cpu_family
  case "${abi}" in
    arm64-v8a)   triple="aarch64-linux-android";  cpu_family="aarch64"; cpu="aarch64" ;;
    armeabi-v7a) triple="armv7a-linux-androideabi"; cpu_family="arm";   cpu="armv7" ;;
  esac
  cat > "${WORK}/android-${abi}.cross.txt" <<EOF
[binaries]
c = '${ndk_bin}/${triple}${ANDROID_API}-clang'
cpp = '${ndk_bin}/${triple}${ANDROID_API}-clang++'
ar = '${ndk_bin}/llvm-ar'
strip = '${ndk_bin}/llvm-strip'
pkg-config = 'pkg-config'

[host_machine]
system = 'android'
cpu_family = '${cpu_family}'
cpu = '${cpu}'
endian = 'little'
EOF
}

# 生成 OpenHarmony meson cross file
gen_ohos_meson_cross() {
  local llvm_bin="${OHOS_SDK_NATIVE}/llvm/bin"
  cat > "${WORK}/ohos-arm64.cross.txt" <<EOF
[binaries]
c = '${llvm_bin}/aarch64-unknown-linux-ohos-clang'
cpp = '${llvm_bin}/aarch64-unknown-linux-ohos-clang++'
ar = '${llvm_bin}/llvm-ar'
strip = '${llvm_bin}/llvm-strip'
pkg-config = 'pkg-config'

[host_machine]
system = 'linux'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'
EOF
}

# 生成 mingw-w64 (Windows x64) meson cross file
gen_mingw_meson_cross() {
  cat > "${WORK}/mingw-x64.cross.txt" <<EOF
[binaries]
c = 'x86_64-w64-mingw32-gcc'
cpp = 'x86_64-w64-mingw32-g++'
ar = 'x86_64-w64-mingw32-ar'
strip = 'x86_64-w64-mingw32-strip'
windres = 'x86_64-w64-mingw32-windres'
pkg-config = 'pkg-config'

[host_machine]
system = 'windows'
cpu_family = 'x86_64'
cpu = 'x86_64'
endian = 'little'
EOF
}

# =============================================================================
# 3) 构建 dav1d (Meson，静态库，仅解码)
# =============================================================================
build_dav1d() {
  local bdir="${WORK}/dav1d/build-${TARGET}"
  rm -rf "${bdir}"
  meson setup "${bdir}" "${WORK}/dav1d" \
    --prefix="${PREFIX}" \
    --libdir=lib \
    --buildtype=release \
    --default-library=static \
    -Denable_tools=false \
    -Denable_tests=false \
    ${MESON_CROSS_ARGS[@]+"${MESON_CROSS_ARGS[@]}"}
  meson compile -C "${bdir}" -j "${JOBS}"
  meson install -C "${bdir}"
}

# =============================================================================
# 4) 构建 libavif (CMake，静态库，dav1d=SYSTEM)
# =============================================================================
build_libavif() {
  local bdir="${WORK}/libavif/build-${TARGET}"
  rm -rf "${bdir}"

  # 让 libavif 通过 pkg-config 找到我们刚安装的 dav1d
  export PKG_CONFIG_PATH="${PREFIX}/lib/pkgconfig"
  export PKG_CONFIG_LIBDIR="${PREFIX}/lib/pkgconfig"

  # 交叉编译时 (iOS/Android/HarmonyOS) 工具链会把 CMAKE_FIND_ROOT_PATH_MODE_LIBRARY
  # 设为 ONLY，导致 libavif 的 Finddav1d.cmake 里的 find_library 只在目标 sysroot
  # 中搜索，找不到装在 workspace prefix 里的 libdav1d.a。
  # 直接把 DAV1D_INCLUDE_DIR / DAV1D_LIBRARY 作为缓存变量传入，find_path/find_library
  # 会跳过搜索，从而绕开 root path 限制 (pkg-config 仍用于版本探测)。
  local dav1d_lib="${PREFIX}/lib/libdav1d.a"

  cmake -S "${WORK}/libavif" -B "${bdir}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF \
    -DAVIF_CODEC_DAV1D=SYSTEM \
    -DAVIF_LIBYUV="${ENABLE_LIBYUV}" \
    -DAVIF_BUILD_APPS=OFF \
    -DAVIF_BUILD_TESTS=OFF \
    -DAVIF_BUILD_EXAMPLES=OFF \
    -DCMAKE_INSTALL_PREFIX="${PREFIX}" \
    -DCMAKE_INSTALL_LIBDIR=lib \
    -DCMAKE_PREFIX_PATH="${PREFIX}" \
    -DDAV1D_INCLUDE_DIR="${PREFIX}/include" \
    -DDAV1D_LIBRARY="${dav1d_lib}" \
    -DCMAKE_FIND_ROOT_PATH="${PREFIX}" \
    -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=BOTH \
    -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=BOTH \
    ${CMAKE_CROSS_ARGS[@]+"${CMAKE_CROSS_ARGS[@]}"}

  cmake --build "${bdir}" --config Release --parallel "${JOBS}"
  cmake --install "${bdir}" --config Release
}

# =============================================================================
main() {
  fetch_sources
  configure_target
  build_dav1d
  build_libavif
  echo "==> 完成: 产物位于 ${PREFIX}"
  ls -R "${PREFIX}" || true
}

main
