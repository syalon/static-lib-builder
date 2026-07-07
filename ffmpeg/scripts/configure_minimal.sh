# shellcheck shell=bash
# =============================================================================
# FFmpeg ./configure 参数：与内部引擎 minimal 视频配置对齐
#
# 用法（在 load_env config.env 之后）:
#   source ffmpeg/scripts/configure_minimal.sh
#   ffmpeg_build_configure_args <target_os>   # target_os: linux|darwin|android|windows|...
#   "${CONFIGURE_ARGS[@]}" 传给 ./configure
# =============================================================================

# 输出：填充全局数组 CONFIGURE_ARGS（不含 --prefix / 交叉编译专用参数）
ffmpeg_build_configure_args() {
  local target_os="${1:?target_os 必填 (linux|darwin|android|windows|...)}"
  CONFIGURE_ARGS=()

  CONFIGURE_ARGS+=(
    --disable-debug
    --enable-stripping
    --enable-static
    --disable-shared
    --enable-pic
    --disable-autodetect
    --disable-programs
    --disable-doc
    "--extra-cflags=-O3 -ffast-math -funroll-loops -w"
  )

  if [ "${FFMPEG_ENABLE_GPL:-0}" = "1" ]; then
    CONFIGURE_ARGS+=(--enable-gpl)
  else
    CONFIGURE_ARGS+=(--disable-gpl)
  fi
  if [ "${FFMPEG_ENABLE_VERSION3:-0}" = "1" ]; then
    CONFIGURE_ARGS+=(--enable-version3)
  else
    CONFIGURE_ARGS+=(--disable-version3)
  fi
  if [ "${FFMPEG_ENABLE_NONFREE:-0}" = "1" ]; then
    CONFIGURE_ARGS+=(--enable-nonfree)
  else
    CONFIGURE_ARGS+=(--disable-nonfree)
  fi

  # 引擎视频模块默认链接的四个子库
  [ "${FFMPEG_ENABLE_AVCODEC:-1}" = "1" ]    && CONFIGURE_ARGS+=(--enable-avcodec)    || CONFIGURE_ARGS+=(--disable-avcodec)
  [ "${FFMPEG_ENABLE_AVFORMAT:-1}" = "1" ]   && CONFIGURE_ARGS+=(--enable-avformat)   || CONFIGURE_ARGS+=(--disable-avformat)
  [ "${FFMPEG_ENABLE_SWSCALE:-1}" = "1" ]    && CONFIGURE_ARGS+=(--enable-swscale)    || CONFIGURE_ARGS+=(--disable-swscale)
  [ "${FFMPEG_ENABLE_SWRESAMPLE:-1}" = "1" ] && CONFIGURE_ARGS+=(--enable-swresample) || CONFIGURE_ARGS+=(--disable-swresample)
  CONFIGURE_ARGS+=(--disable-avdevice --disable-avfilter --disable-postproc)

  # minimal codecs
  CONFIGURE_ARGS+=(--disable-everything)
  local item
  for item in ${FFMPEG_DECODERS}; do
    CONFIGURE_ARGS+=(--enable-decoder="${item}")
  done
  for item in ${FFMPEG_DEMUXERS}; do
    CONFIGURE_ARGS+=(--enable-demuxer="${item}")
  done
  for item in ${FFMPEG_PARSERS}; do
    CONFIGURE_ARGS+=(--enable-parser="${item}")
  done
  for item in ${FFMPEG_PROTOCOLS}; do
    CONFIGURE_ARGS+=(--enable-protocol="${item}")
  done

  # Windows(MinGW) 走 w32threads；其它平台 pthreads + LTO（对齐引擎 release 构建）
  # 注意 ffmpeg_target_os 对 MinGW 返回的是 mingw64，不是 windows。
  case "${target_os}" in
    mingw*|win*)
      CONFIGURE_ARGS+=(--enable-w32threads)
      ;;
    *)
      CONFIGURE_ARGS+=(--enable-pthreads --extra-ldflags=-flto)
      ;;
  esac
}
