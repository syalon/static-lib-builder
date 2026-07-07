#!/usr/bin/env bash
# =============================================================================
# FFmpeg minimal static 构建 (Unix: Linux / macOS / iOS / Android / Harmony / MinGW)
# configure 参数见 config.env + configure_minimal.sh（内部引擎视频模块对齐）
#
# 用法:
#   bash ffmpeg/scripts/build_unix.sh <target>
#
# 支持 <target>（与 libavif 命名一致）:
#   macos-arm64  macos-x86_64
#   ios-arm64  ios-sim-arm64  ios-sim-x86_64
#   linux-x86_64
#   android-arm64-v8a  android-armeabi-v7a
#   harmony-arm64-v8a
#   windows-x64-mingw
#
# 环境变量:
#   ANDROID_NDK_HOME     Android 交叉编译
#   OHOS_SDK_NATIVE      HarmonyOS (.../openharmony/native)
#
# 产物: ffmpeg/out/<target>/{include,lib}
# =============================================================================
set -euo pipefail

TARGET="${1:?用法: build_unix.sh <target>}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${LIB_ROOT}/.." && pwd)"
# shellcheck disable=SC1091
source "${REPO_ROOT}/scripts/common.sh"
load_env "${LIB_ROOT}/config.env"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/configure_minimal.sh"

WORK="${LIB_ROOT}/work/${TARGET}"
PREFIX="${LIB_ROOT}/out/${TARGET}"
SRC="${WORK}/FFmpeg"
JOBS="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"

rm -rf "${PREFIX}"
mkdir -p "${WORK}" "${PREFIX}"

log "Target        : ${TARGET}"
log "FFmpeg        : release/${FFMPEG_VERSION}"
log "Prefix        : ${PREFIX}"
log "Parallel jobs : ${JOBS}"

fetch_ffmpeg() {
  if [ ! -d "${SRC}/.git" ]; then
    git clone --depth 1 -b "release/${FFMPEG_VERSION}" \
      https://github.com/FFmpeg/FFmpeg.git "${SRC}"
  fi
}

# 返回 FFmpeg --target-os 值
ffmpeg_target_os() {
  case "${TARGET}" in
    macos-*|ios-*) echo darwin ;;
    linux-x86_64) echo linux ;;
    android-*) echo android ;;
    harmony-*) echo linux ;;
    windows-x64-mingw) echo mingw64 ;;
    *) die "未知 target: ${TARGET}" ;;
  esac
}

ffmpeg_arch() {
  case "${TARGET}" in
    macos-arm64|ios-arm64|ios-sim-arm64|android-arm64-v8a|harmony-arm64-v8a)
      echo aarch64 ;;
    macos-x86_64|ios-sim-x86_64|linux-x86_64|windows-x64-mingw)
      echo x86_64 ;;
    android-armeabi-v7a)
      echo arm ;;
    *) die "未知 arch: ${TARGET}" ;;
  esac
}

run_configure_and_make() {
  local -a cfg=(./configure --prefix="${PREFIX}")
  local ff_os ff_arch

  ff_os="$(ffmpeg_target_os)"
  ff_arch="$(ffmpeg_arch)"
  ffmpeg_build_configure_args "${ff_os}"

  case "${TARGET}" in
    macos-arm64)
      cfg+=(--arch="${ff_arch}" --target-os=darwin)
      cfg+=(--extra-cflags="--target=arm64-apple-macos${MACOS_DEPLOYMENT_TARGET}")
      cfg+=(--extra-ldflags="--target=arm64-apple-macos${MACOS_DEPLOYMENT_TARGET}")
      ;;
    macos-x86_64)
      # arm64 runner 上交叉编译 x86_64，需显式 --enable-cross-compile
      cfg+=(--enable-cross-compile --arch="${ff_arch}" --target-os=darwin)
      cfg+=(--extra-cflags="--target=x86_64-apple-macos${MACOS_DEPLOYMENT_TARGET}")
      cfg+=(--extra-ldflags="--target=x86_64-apple-macos${MACOS_DEPLOYMENT_TARGET}")
      ;;
    ios-arm64)
      local sysroot sdk cc
      sysroot="$(xcrun --sdk iphoneos --show-sdk-path)"
      sdk=iphoneos
      cc="$(xcrun --sdk "${sdk}" -f clang)"
      cfg+=(--enable-cross-compile --arch=aarch64 --target-os=darwin)
      cfg+=(--sysroot="${sysroot}" --cc="${cc}")
      cfg+=(--extra-cflags="--target=arm64-apple-ios${IOS_DEPLOYMENT_TARGET}")
      cfg+=(--extra-ldflags="--target=arm64-apple-ios${IOS_DEPLOYMENT_TARGET}")
      ;;
    ios-sim-arm64)
      local sysroot cc
      sysroot="$(xcrun --sdk iphonesimulator --show-sdk-path)"
      cc="$(xcrun --sdk iphonesimulator -f clang)"
      cfg+=(--enable-cross-compile --arch=aarch64 --target-os=darwin)
      cfg+=(--sysroot="${sysroot}" --cc="${cc}")
      cfg+=(--extra-cflags="--target=arm64-apple-ios${IOS_DEPLOYMENT_TARGET}-simulator")
      cfg+=(--extra-ldflags="--target=arm64-apple-ios${IOS_DEPLOYMENT_TARGET}-simulator")
      ;;
    ios-sim-x86_64)
      local sysroot cc
      sysroot="$(xcrun --sdk iphonesimulator --show-sdk-path)"
      cc="$(xcrun --sdk iphonesimulator -f clang)"
      cfg+=(--enable-cross-compile --arch=x86_64 --target-os=darwin)
      cfg+=(--sysroot="${sysroot}" --cc="${cc}")
      cfg+=(--extra-cflags="--target=x86_64-apple-ios${IOS_DEPLOYMENT_TARGET}-simulator")
      cfg+=(--extra-ldflags="--target=x86_64-apple-ios${IOS_DEPLOYMENT_TARGET}-simulator")
      ;;
    linux-x86_64)
      cfg+=(--arch=x86_64 --target-os=linux)
      ;;
    android-arm64-v8a)
      [ -n "${ANDROID_NDK_HOME:-}" ] || die "需要 ANDROID_NDK_HOME"
      local host_tag ndk_bin triple
      case "$(uname -s)" in Darwin) host_tag=darwin-x86_64 ;; *) host_tag=linux-x86_64 ;; esac
      ndk_bin="${ANDROID_NDK_HOME}/toolchains/llvm/prebuilt/${host_tag}/bin"
      triple=aarch64-linux-android
      cfg+=(--enable-cross-compile --arch=aarch64 --target-os=android)
      cfg+=(--cc="${ndk_bin}/${triple}${ANDROID_API}-clang")
      cfg+=(--nm="${ndk_bin}/llvm-nm" --strip="${ndk_bin}/llvm-strip")
      cfg+=(--extra-cflags="-fPIC --target=${triple}${ANDROID_API}")
      cfg+=(--extra-ldflags="--target=${triple}${ANDROID_API}")
      ;;
    android-armeabi-v7a)
      [ -n "${ANDROID_NDK_HOME:-}" ] || die "需要 ANDROID_NDK_HOME"
      local host_tag ndk_bin triple
      case "$(uname -s)" in Darwin) host_tag=darwin-x86_64 ;; *) host_tag=linux-x86_64 ;; esac
      ndk_bin="${ANDROID_NDK_HOME}/toolchains/llvm/prebuilt/${host_tag}/bin"
      triple=armv7a-linux-androideabi
      cfg+=(--enable-cross-compile --arch=arm --target-os=android)
      cfg+=(--cc="${ndk_bin}/${triple}${ANDROID_API}-clang")
      cfg+=(--nm="${ndk_bin}/llvm-nm" --strip="${ndk_bin}/llvm-strip")
      cfg+=(--disable-asm)
      cfg+=(--extra-cflags="-fPIC --target=${triple}${ANDROID_API}")
      cfg+=(--extra-ldflags="--target=${triple}${ANDROID_API}")
      ;;
    harmony-arm64-v8a)
      [ -n "${OHOS_SDK_NATIVE:-}" ] || die "需要 OHOS_SDK_NATIVE (指向 .../openharmony/native)"
      local llvm_bin clang_target
      llvm_bin="${OHOS_SDK_NATIVE}/llvm/bin"
      clang_target=aarch64-unknown-linux-ohos
      cfg+=(--enable-cross-compile --arch=aarch64 --target-os=linux)
      cfg+=(--cc="${llvm_bin}/clang")
      cfg+=(--nm="${llvm_bin}/llvm-nm" --strip="${llvm_bin}/llvm-strip")
      cfg+=(--sysroot="${OHOS_SDK_NATIVE}/sysroot")
      cfg+=(--extra-cflags="-fPIC -U_FORTIFY_SOURCE --target=${clang_target} --sysroot=${OHOS_SDK_NATIVE}/sysroot")
      cfg+=(--extra-ldflags="--target=${clang_target} --sysroot=${OHOS_SDK_NATIVE}/sysroot")
      ;;
    windows-x64-mingw)
      cfg+=(--enable-cross-compile --arch=x86_64 --target-os=mingw64)
      cfg+=(--cross-prefix=x86_64-w64-mingw32-)
      ;;
    *)
      die "未实现的 target: ${TARGET}"
      ;;
  esac

  cfg+=("${CONFIGURE_ARGS[@]}")

  log "configure ${cfg[*]}"
  ( cd "${SRC}" && "${cfg[@]}" )

  log "make -j${JOBS} && make install"
  make -C "${SRC}" -j"${JOBS}"
  make -C "${SRC}" install
}

fetch_ffmpeg
run_configure_and_make
log "完成: ${PREFIX}"
