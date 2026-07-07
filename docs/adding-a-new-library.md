# 如何添加一个新库

本仓库按**静态库分目录**组织：一个库 = 一个顶层目录，自带配置与构建脚本，
共用 `scripts/common.sh` 与统一命名约定。本文说明添加新库的目录约定、脚本契约、
命名规范、workflow 模板与检查清单。

## 一句话原则

> 新库 `<lib>/` 自包含：`config.env`（配置）+ `scripts/`（构建）+ 可选 `cross/` 或 `gn_args/`；
> 复用仓库根 `scripts/common.sh` 的公共函数；遵守统一命名约定；一个库对应一个
> 仅手动触发的 `.github/workflows/<lib>.yml`。

## 目录约定

```
<lib>/
├── config.env                 # 单一配置入口 (版本 + 可调开关)
├── scripts/
│   ├── build_unix.sh          # <target> -> out/<target>/{include,lib}
│   ├── build_windows.ps1      # -Target <target> (如该库支持 Windows)
│   └── package.sh             # <target> -> dist/<PACKAGE_NAME>-<ver>-<target>.<ext>
├── cross/                     # (可选) Meson 交叉文件说明，如用 meson
└── gn_args/                   # (可选) GN 参数模板，如用 GN (V8 类)
```

中间产物目录 `<lib>/work`、`<lib>/out`、`<lib>/dist` 以及大体积检出（如
`<lib>/v8-src`、`<lib>/depot_tools`）已被根 [`.gitignore`](../.gitignore) 覆盖，无需入库。

## `config.env` 规范

- 文件名固定 `config.env`，`KEY=VALUE` 形式，**不要用引号包裹**（要能被 shell `source`）。
- 必备通用键：
  - `PACKAGE_NAME`：产物基名（如 `libavif-dav1d`、`v8`）。
  - `PACKAGE_VERSION`：产物版本号，留空则回退该库主版本键。
- 库私有版本键：沿用上游习惯命名（如 `LIBAVIF_VERSION`、`DAV1D_VERSION`、`V8_VERSION`）。
- 平台相关键：复用统一名 `ANDROID_API`、`IOS_DEPLOYMENT_TARGET`、`MACOS_DEPLOYMENT_TARGET`。

## 脚本接口契约

所有库脚本对外保持相同签名，便于 workflow 复用：

| 脚本 | 调用 | 产物落点 |
| --- | --- | --- |
| `build_unix.sh` | `bash <lib>/scripts/build_unix.sh <target>` | `<lib>/out/<target>/{include,lib}` |
| `build_windows.ps1` | `pwsh <lib>/scripts/build_windows.ps1 -Target <target>` | `<lib>/out/<target>/{include,lib}`（可自带打包） |
| `package.sh` | `bash <lib>/scripts/package.sh <target>` | `<lib>/dist/<PACKAGE_NAME>-<ver>-<target>.tar.gz` |

脚本开头统一解析路径并加载公共函数：

```bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${LIB_ROOT}/.." && pwd)"
# shellcheck disable=SC1091
source "${REPO_ROOT}/scripts/common.sh"
load_env "${LIB_ROOT}/config.env"
```

`scripts/common.sh` 提供的公共函数：

- `log` / `warn` / `die`：统一日志。
- `load_env <file>`：加载 `config.env`。
- `pkg_name <PACKAGE_NAME> <version> <target>`：统一产物基名。
- `copy_license <源码目录> <stage目录> <组件名>`：复制 `LICENSE-<组件名>`。
- `write_build_info <文件> "Key: v" ...`：写 `BUILD_INFO.txt`（自动追加时间）。
- `make_archive <tar.gz|zip> <dist> <包名>`：把 `<dist>/<包名>/` 打包并清理 stage。

> 若 workflow 需要在运行时覆盖 `config.env`（如临时切版本），在脚本里于 `load_env`
> **之前**捕获同名环境变量、`load_env` **之后**回填即可（参考
> [`v8/scripts/build_unix.sh`](../v8/scripts/build_unix.sh) 的 `_OVR_*` 处理）。

## 目标平台命名（复用统一命名，选支持子集）

```
macos-arm64      macos-x86_64
ios-arm64        ios-sim-arm64      ios-sim-x86_64
linux-x86_64
android-arm64-v8a  android-armeabi-v7a
harmony-arm64-v8a
windows-x64-msvc   windows-x64-mingw
```

新库只需支持其中可行的子集；命名务必与上表一致，方便下游按平台统一取包。

## 产物与包结构

- 命名：`<PACKAGE_NAME>-<version>-<target>.tar.gz`（Windows MSVC 用 `.zip`）。
- 包内结构：

```
include/                 # 头文件
lib/                     # 静态库 (+ 可选 pkgconfig/)
LICENSE-<component>      # 每个上游组件一个
BUILD_INFO.txt           # 版本 / 关键编译参数 / 构建时间
```

## workflow 模板

复制 [`.github/workflows/v8.yml`](../.github/workflows/v8.yml) 或
[`libavif.yml`](../.github/workflows/libavif.yml)，改动：

- `name` 与文件名 `<lib>.yml`。
- `on:` **只保留 `workflow_dispatch`**（不加 `push` / `pull_request` / tag）。
- 平台布尔开关 `build_*` 与 `if: inputs.build_*`。
- 各 job 的 `run:` 路径指向 `<lib>/scripts/...`，`upload-artifact` 路径指向 `<lib>/dist/*`。
- 保留 `publish` + `release_tag` 输入与仅 `inputs.publish` 触发的 `release` job。
- 编译较慢的库（GN/大型项目）设置合理 `timeout-minutes` 并缓存源码/工具链。

## 新库检查清单

- [ ] `config.env` 含 `PACKAGE_NAME` 与 `PACKAGE_VERSION`，键名遵守统一约定。
- [ ] 脚本签名符合契约，产物落 `out/<target>`，打包到 `dist/`。
- [ ] 复用 `scripts/common.sh`（不要重复实现打包/日志）。
- [ ] 目标平台命名与统一命名表一致。
- [ ] 产物命名与包内结构统一。
- [ ] `.gitignore` 已覆盖该库的中间目录/大体积检出（如需新增模式则补充）。
- [ ] 新增 `.github/workflows/<lib>.yml`，仅手动触发。
- [ ] README 增加该库章节（支持平台 / 配置 / 本地构建 / 下游链接）。
- [ ] 先在单个平台（如 `linux-x86_64`）跑通 fetch/build/package，再逐个开全矩阵。

## 最小新库骨架示例

`mylib/config.env`：

```bash
PACKAGE_NAME=mylib
PACKAGE_VERSION=
MYLIB_VERSION=1.2.3
ANDROID_API=21
```

`mylib/scripts/build_unix.sh`（骨架）：

```bash
#!/usr/bin/env bash
set -euo pipefail
TARGET="${1:?用法: build_unix.sh <target>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${LIB_ROOT}/.." && pwd)"
# shellcheck disable=SC1091
source "${REPO_ROOT}/scripts/common.sh"
load_env "${LIB_ROOT}/config.env"

PREFIX="${LIB_ROOT}/out/${TARGET}"
rm -rf "${PREFIX}"; mkdir -p "${PREFIX}/include" "${PREFIX}/lib"

# ... 拉源码、按 TARGET 交叉编译、install 到 ${PREFIX} ...

log "完成: ${PREFIX}"
```

`mylib/scripts/package.sh`（骨架）：

```bash
#!/usr/bin/env bash
set -euo pipefail
TARGET="${1:?用法: package.sh <target>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${LIB_ROOT}/.." && pwd)"
# shellcheck disable=SC1091
source "${REPO_ROOT}/scripts/common.sh"
load_env "${LIB_ROOT}/config.env"

VERSION="${PACKAGE_VERSION:-${MYLIB_VERSION}}"
PREFIX="${LIB_ROOT}/out/${TARGET}"
DIST="${LIB_ROOT}/dist"
PKG_NAME="$(pkg_name "${PACKAGE_NAME}" "${VERSION}" "${TARGET}")"
STAGE="${DIST}/${PKG_NAME}"

rm -rf "${STAGE}"; mkdir -p "${STAGE}/lib"
cp -R "${PREFIX}/include" "${STAGE}/include"
find "${PREFIX}/lib" -maxdepth 1 -type f -name '*.a' -exec cp {} "${STAGE}/lib/" \;
copy_license "${LIB_ROOT}/work/mylib" "${STAGE}" "mylib"
write_build_info "${STAGE}/BUILD_INFO.txt" \
  "Package : ${PKG_NAME}" "Target : ${TARGET}" "mylib : ${MYLIB_VERSION}"
mkdir -p "${DIST}"
make_archive "tar.gz" "${DIST}" "${PKG_NAME}"
```
