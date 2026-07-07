#!/usr/bin/env bash
# =============================================================================
# FFmpeg minimal static 构建 (Windows MSVC)
#
# 必须在 MSYS2 shell 中运行，且已激活 MSVC 环境（cl.exe / link.exe 在 PATH，
# INCLUDE / LIB 等环境变量已设置，通常由 ilammy/msvc-dev-cmd 完成）。
#
# 为什么用 MSYS2 的 make：
#   FFmpeg 即使 --toolchain=msvc 也只支持 GNU make，且其 MSVC 依赖生成用的
#   awk 脚本 (gsub(/\\/, "/")) 只有在 POSIX shell 下执行 recipe 才正确；用
#   native make / cmd 执行会把 \\ 吞成 \ 导致 awk 语法错误 (FFmpeg trac #9360)。
#   因此这里改用 MSYS2 的 make，在 sh 下跑 recipe。
#
# 用法（本地）:
#   在 “x64 Native Tools” 环境的 MSYS2 shell 中:
#     bash ffmpeg/scripts/build_windows_msvc.sh
#
# 产物: ffmpeg/out/windows-x64-msvc/{include,lib/*.lib}
# =============================================================================
set -euo pipefail

TARGET=windows-x64-msvc

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${LIB_ROOT}/.." && pwd)"
# shellcheck disable=SC1091
source "${REPO_ROOT}/scripts/common.sh"
load_env "${LIB_ROOT}/config.env"

WORK="${LIB_ROOT}/work/${TARGET}"
PREFIX="${LIB_ROOT}/out/${TARGET}"
SRC="${WORK}/FFmpeg"
JOBS="$(nproc 2>/dev/null || echo 4)"

command -v cl >/dev/null 2>&1 || command -v cl.exe >/dev/null 2>&1 \
  || die "未找到 cl.exe，请先激活 MSVC 环境 (ilammy/msvc-dev-cmd)"

rm -rf "${PREFIX}"
mkdir -p "${WORK}" "${PREFIX}"

log "Target        : ${TARGET}"
log "FFmpeg        : release/${FFMPEG_VERSION}"
log "Prefix        : ${PREFIX}"
log "Parallel jobs : ${JOBS}"

if [ ! -d "${SRC}/.git" ]; then
  git clone --depth 1 -b "release/${FFMPEG_VERSION}" \
    https://github.com/FFmpeg/FFmpeg.git "${SRC}"
fi

# MSVC 专用 configure 参数（cl.exe 只认少量 gcc 风格 flag，故 extra-cflags 仅用 -O3 -w）。
cfg=(./configure
  --prefix="${PREFIX}"
  --toolchain=msvc
  --arch=x86_64
  --target-os=win64
  --disable-debug
  --enable-stripping
  --enable-static
  --disable-shared
  --enable-pic
  --disable-autodetect
  --disable-programs
  --disable-doc
  --enable-avcodec
  --enable-avformat
  --enable-swscale
  --enable-swresample
  --disable-avdevice
  --disable-avfilter
  --disable-postproc
  --disable-everything
  --enable-w32threads
  "--extra-cflags=-O3 -w"
)

# 许可：与 config.env 对齐（引擎默认 LGPL）
[ "${FFMPEG_ENABLE_GPL:-0}" = "1" ]      && cfg+=(--enable-gpl)      || cfg+=(--disable-gpl)
[ "${FFMPEG_ENABLE_VERSION3:-0}" = "1" ] && cfg+=(--enable-version3) || cfg+=(--disable-version3)
[ "${FFMPEG_ENABLE_NONFREE:-0}" = "1" ]  && cfg+=(--enable-nonfree)  || cfg+=(--disable-nonfree)

for d in ${FFMPEG_DECODERS};  do cfg+=(--enable-decoder="${d}");  done
for d in ${FFMPEG_DEMUXERS};  do cfg+=(--enable-demuxer="${d}");  done
for p in ${FFMPEG_PARSERS};   do cfg+=(--enable-parser="${p}");   done
for p in ${FFMPEG_PROTOCOLS}; do cfg+=(--enable-protocol="${p}"); done

log "configure ${cfg[*]}"
( cd "${SRC}" && "${cfg[@]}" )

log "make -j${JOBS} && make install"
make -C "${SRC}" -j"${JOBS}"
make -C "${SRC}" install
log "完成: ${PREFIX}"
