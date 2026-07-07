# =============================================================================
# 跨库共享的 Bash 公共函数库 (Single source of shared logic)
#
# 用法: 在各库的 scripts/*.sh 中 source 本文件:
#     source "<repo_root>/scripts/common.sh"
#
# 提供:
#   log / warn / die                  统一日志
#   load_env <file>                   加载 KEY=VALUE 形式的 config.env
#   pkg_name <name> <ver> <target>    统一产物基名
#   copy_license <src> <staged-name>  从源码目录挑一个 LICENSE 复制
#   write_build_info <file> <k=v>...  写 BUILD_INFO.txt
#   make_archive <format> <dist> <name>  打包 stage 目录为 tar.gz / zip
#
# 约定 (所有库统一):
#   - 配置文件名一律 config.env
#   - 产物命名: <PACKAGE_NAME>-<version>-<target>.<ext>
#   - 包内结构: include/  lib/  LICENSE-<component>  BUILD_INFO.txt
# =============================================================================

# --- 日志 --------------------------------------------------------------------
log()  { echo "==> $*"; }
warn() { echo "警告: $*" >&2; }
die()  { echo "错误: $*" >&2; exit 1; }

# --- 加载 config.env ---------------------------------------------------------
# 用法: load_env "<repo_root>/config.env"
load_env() {
  local f="$1"
  [ -f "${f}" ] || die "未找到配置文件: ${f}"
  # shellcheck disable=SC1090
  source "${f}"
}

# --- 统一产物基名 ------------------------------------------------------------
# 用法: pkg_name "<PACKAGE_NAME>" "<version>" "<target>"
pkg_name() {
  local name="$1" ver="$2" target="$3"
  [ -n "${name}" ] || die "pkg_name: PACKAGE_NAME 为空"
  [ -n "${ver}" ]  || die "pkg_name: version 为空"
  [ -n "${target}" ] || die "pkg_name: target 为空"
  echo "${name}-${ver}-${target}"
}

# --- 复制许可证 --------------------------------------------------------------
# 用法: copy_license <源码目录> <staged 目录> <组件名>
# 从常见文件名中挑第一个存在的，复制为 <staged>/LICENSE-<组件名>
copy_license() {
  local src="$1" staged="$2" name="$3" f
  for f in LICENSE LICENSE.txt LICENSE.md COPYING COPYING.txt; do
    if [ -f "${src}/${f}" ]; then
      cp "${src}/${f}" "${staged}/LICENSE-${name}"
      return 0
    fi
  done
  warn "未在 ${src} 找到许可证文件 (组件 ${name})"
  return 0
}

# --- 写 BUILD_INFO.txt -------------------------------------------------------
# 用法: write_build_info <目标文件> "Key1: v1" "Key2: v2" ...
# 额外自动追加构建时间与 Built by 行。
write_build_info() {
  local out="$1"; shift
  {
    local line
    for line in "$@"; do
      echo "${line}"
    done
    echo "Built (UTC) : $(date -u '+%Y-%m-%d %H:%M:%S')"
    echo "Built by    : GitHub Actions (build-static-libs)"
  } > "${out}"
}

# --- 打包 --------------------------------------------------------------------
# 用法: make_archive <tar.gz|zip> <dist 目录> <包名(不含扩展名)>
# 假设 <dist>/<包名>/ 已经是完整的 stage 目录。产出后删除 stage。
make_archive() {
  local format="$1" dist="$2" name="$3"
  local stage="${dist}/${name}"
  [ -d "${stage}" ] || die "make_archive: 未找到 stage 目录 ${stage}"
  case "${format}" in
    tar.gz)
      tar -czf "${dist}/${name}.tar.gz" -C "${dist}" "${name}"
      log "打包完成: ${dist}/${name}.tar.gz"
      ls -lh "${dist}/${name}.tar.gz"
      ;;
    zip)
      ( cd "${dist}" && zip -qr "${name}.zip" "${name}" )
      log "打包完成: ${dist}/${name}.zip"
      ls -lh "${dist}/${name}.zip"
      ;;
    *)
      die "make_archive: 未知格式 ${format} (仅支持 tar.gz / zip)"
      ;;
  esac
  rm -rf "${stage}"
}
