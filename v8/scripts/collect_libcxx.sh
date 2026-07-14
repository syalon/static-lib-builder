#!/usr/bin/env bash
# =============================================================================
# 收集 Chromium custom libc++ / libc++abi 头文件与（必要时）静态库到 PREFIX。
#
# 用法 (由 build_unix.sh source):
#   collect_libcxx <v8_src> <out_dir_rel> <prefix>
#
# 包内布局:
#   <prefix>/libcxx/include/          # libc++ 头 + __config_site
#   <prefix>/libcxxabi/include/       # libc++abi 头 (若存在)
#   <prefix>/lib/libc++.a             # 仅当未并入 monolith 时
#   <prefix>/lib/libc++abi.a          # 仅当未并入 monolith 且存在时
#
# 输出变量 (供调用方写 BUILD_INFO):
#   LIBCXX_MERGED=true|false
# =============================================================================

collect_libcxx() {
  local v8_src="${1:?}"
  local out_dir="${2:?}"   # 相对 v8_src，如 out/linux-x86_64
  local prefix="${3:?}"
  local out_full="${v8_src}/${out_dir}"

  LIBCXX_MERGED="false"

  # --- 定位头文件源 ----------------------------------------------------------
  local libcxx_inc=""
  for cand in \
    "${v8_src}/third_party/libc++/src/include" \
    "${v8_src}/buildtools/third_party/libc++/trunk/include" \
    "${v8_src}/buildtools/third_party/libc++/include"
  do
    if [ -d "${cand}" ] && { [ -f "${cand}/__config" ] || [ -f "${cand}/vector" ]; }; then
      libcxx_inc="${cand}"
      break
    fi
  done
  [ -n "${libcxx_inc}" ] || die "未找到 libc++ 头文件目录 (use_custom_libcxx=true 需要打包)"

  local config_site=""
  for cand in \
    "${v8_src}/buildtools/third_party/libc++/__config_site" \
    "${out_full}/gen/buildtools/third_party/libc++/__config_site" \
    "${out_full}/gen/third_party/libc++/src/include/__config_site"
  do
    if [ -f "${cand}" ]; then
      config_site="${cand}"
      break
    fi
  done
  [ -n "${config_site}" ] || die "未找到 libc++ __config_site (ABI 命名空间定义)"

  local libcxxabi_inc=""
  for cand in \
    "${v8_src}/third_party/libc++abi/src/include" \
    "${v8_src}/buildtools/third_party/libc++abi/trunk/include" \
    "${v8_src}/buildtools/third_party/libc++abi/include"
  do
    if [ -d "${cand}" ]; then
      libcxxabi_inc="${cand}"
      break
    fi
  done

  # --- 复制头文件 ------------------------------------------------------------
  mkdir -p "${prefix}/libcxx/include"
  cp -R "${libcxx_inc}/." "${prefix}/libcxx/include/"
  cp "${config_site}" "${prefix}/libcxx/include/__config_site"

  if [ -n "${libcxxabi_inc}" ]; then
    mkdir -p "${prefix}/libcxxabi/include"
    cp -R "${libcxxabi_inc}/." "${prefix}/libcxxabi/include/"
  fi

  # --- 探测 monolith 是否已并入 libc++ 目标文件 ------------------------------
  local monolith=""
  for cand in \
    "${out_full}/obj/libv8_monolith.a" \
    "${prefix}/lib/libv8_monolith.a"
  do
    if [ -f "${cand}" ]; then
      monolith="${cand}"
      break
    fi
  done
  [ -n "${monolith}" ] || die "collect_libcxx: 未找到 libv8_monolith.a"

  local defined=0
  if command -v llvm-nm >/dev/null 2>&1; then
    if llvm-nm -g "${monolith}" 2>/dev/null | grep -E ' [TD] _?__libcpp_verbose_abort' >/dev/null; then
      defined=1
    fi
  elif command -v nm >/dev/null 2>&1; then
    if nm -g "${monolith}" 2>/dev/null | grep -E ' [TD] _?__libcpp_verbose_abort' >/dev/null; then
      defined=1
    fi
  else
    log "WARN: 无 llvm-nm/nm，无法探测 libc++ 是否并入 monolith，将尝试附带独立库"
  fi

  if [ "${defined}" -eq 1 ]; then
    LIBCXX_MERGED="true"
    log "libc++ 已并入 libv8_monolith.a (libcxx_merged=true)"
  else
    LIBCXX_MERGED="false"
    log "libc++ 未并入 monolith，收集独立静态库 (libcxx_merged=false)"
    mkdir -p "${prefix}/lib"
    local found_lib=0
    local libf base
    while IFS= read -r libf; do
      [ -n "${libf}" ] || continue
      base="$(basename "${libf}")"
      case "${base}" in
        libc++.a|libc++abi.a|libc++experimental.a)
          cp "${libf}" "${prefix}/lib/${base}"
          found_lib=1
          log "  附带 ${base}"
          ;;
      esac
    done < <(
      find "${out_full}/obj" \
        \( -path '*/buildtools/third_party/libc++/*' \
           -o -path '*/third_party/libc++/*' \
           -o -path '*/libc++abi/*' \) \
        -name '*.a' 2>/dev/null || true
    )

    for libf in \
      "${out_full}/obj/buildtools/third_party/libc++/libc++.a" \
      "${out_full}/obj/buildtools/third_party/libc++abi/libc++abi.a"
    do
      if [ -f "${libf}" ]; then
        cp "${libf}" "${prefix}/lib/$(basename "${libf}")"
        found_lib=1
        log "  附带 $(basename "${libf}")"
      fi
    done

    if [ "${found_lib}" -eq 0 ]; then
      warn "未找到独立 libc++.a；下游链接可能缺少 __libcpp_verbose_abort 等符号"
    fi
  fi

  # 验收: 包内必须有 __config_site
  [ -f "${prefix}/libcxx/include/__config_site" ] \
    || die "验收失败: 缺少 ${prefix}/libcxx/include/__config_site"

  if grep -q '_LIBCPP_ABI_NAMESPACE' "${prefix}/libcxx/include/__config_site"; then
    log "ABI: $(grep '_LIBCPP_ABI_NAMESPACE' "${prefix}/libcxx/include/__config_site" | head -1 | tr -d '\r')"
  fi
}
