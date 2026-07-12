#!/usr/bin/env bash
# =============================================================================
# V8 源码获取脚本 (depot_tools + gclient)
#
# 用法:
#   v8/scripts/fetch.sh <target>
#
# <target> 决定是否需要额外的 target_os (android):
#   macos-arm64 / macos-x86_64 / linux-x86_64 / windows-x64-msvc / android-arm64-v8a
#
# 行为:
#   1. 获取 depot_tools 到 v8/depot_tools (并加入 PATH / GITHUB_PATH)
#   2. gclient config (checkout 名 v8-src)，android 目标追加 target_os=['android']
#   3. gclient sync 到 config.env 里的 V8_VERSION
#
# 产物: v8/v8-src (V8 源码 + 依赖 + 工具链/NDK)
# =============================================================================
set -euo pipefail

TARGET="${1:?用法: fetch.sh <target>}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${LIB_ROOT}/.." && pwd)"
# shellcheck disable=SC1091
source "${REPO_ROOT}/scripts/common.sh"

# 所有配置以 config.env 为唯一来源。
load_env "${LIB_ROOT}/config.env"

DEPOT_TOOLS="${LIB_ROOT}/depot_tools"
V8_SRC="${LIB_ROOT}/v8-src"

# 校验 config.env 已提供 V8_VERSION
V8_VERSION="${V8_VERSION:?config.env 缺少 V8_VERSION}"

# --- 1) depot_tools ----------------------------------------------------------
if [ ! -d "${DEPOT_TOOLS}/.git" ]; then
  log "获取 depot_tools -> ${DEPOT_TOOLS}"
  git clone --depth 1 https://chromium.googlesource.com/chromium/tools/depot_tools.git "${DEPOT_TOOLS}"
fi
export PATH="${DEPOT_TOOLS}:${PATH}"
export DEPOT_TOOLS_UPDATE=1
# Windows 上使用 runner 自带 VS，而非 depot_tools 下载的工具链
export DEPOT_TOOLS_WIN_TOOLCHAIN=0

# CI: 让后续 step 也能用到 depot_tools
if [ -n "${GITHUB_PATH:-}" ]; then
  echo "${DEPOT_TOOLS}" >> "${GITHUB_PATH}"
fi

# --- 2) gclient 配置 ---------------------------------------------------------
cd "${LIB_ROOT}"
if [ ! -f ".gclient" ]; then
  log "gclient config (checkout 名 v8-src)"
  gclient config --name v8-src --unmanaged https://chromium.googlesource.com/v8/v8.git
fi

# Android 目标需要额外的 target_os 才会拉取 NDK 等依赖
if [ "${TARGET}" = "android-arm64-v8a" ]; then
  if ! grep -q "target_os" .gclient 2>/dev/null; then
    log "为 Android 目标追加 target_os=['android']"
    printf "\ntarget_os = ['android']\n" >> .gclient
  fi
fi

# --- 3) 检出源码并同步依赖 ---------------------------------------------------
if [ ! -d "${V8_SRC}/.git" ]; then
  log "克隆 V8 源码 -> ${V8_SRC}"
  git clone https://chromium.googlesource.com/v8/v8.git "${V8_SRC}"
fi

log "检出 V8 版本: ${V8_VERSION}"
git -C "${V8_SRC}" fetch --tags --depth 1 origin "${V8_VERSION}" || \
  git -C "${V8_SRC}" fetch --tags origin
git -C "${V8_SRC}" checkout "${V8_VERSION}"

log "gclient sync (拉取依赖 / 工具链, 可能耗时较久)"
gclient sync --nohooks --no-history --shallow -D

log "运行 gclient runhooks"
gclient runhooks

PATCH_FILE="${LIB_ROOT}/patches/${V8_VERSION}-fix-msvc-no-pointer-compression.patch"
[ -f "${PATCH_FILE}" ] || die "未找到当前 V8 版本的补丁: ${PATCH_FILE}"

if git -C "${V8_SRC}" apply --reverse --check "${PATCH_FILE}" >/dev/null 2>&1; then
  log "V8 补丁已应用: $(basename "${PATCH_FILE}")"
elif git -C "${V8_SRC}" apply --check "${PATCH_FILE}"; then
  log "应用 V8 补丁: $(basename "${PATCH_FILE}")"
  git -C "${V8_SRC}" apply "${PATCH_FILE}"
else
  die "V8 补丁无法应用，请检查补丁是否匹配 V8 ${V8_VERSION}: ${PATCH_FILE}"
fi

log "V8 源码就绪: ${V8_SRC}"
