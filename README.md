# build-static-libs

通过 GitHub Actions 从源码交叉编译多个 C/C++ 库的**全平台静态库**，
并可发布到 GitHub Release，方便其他项目直接集成。

仓库按**静态库分目录**组织，每个库自带配置与构建脚本，共用一套命名约定与
公共函数；所有构建**仅通过手动触发**（`workflow_dispatch`）。

## 已包含的库

| 目录 | 库 | 说明 | 支持平台 |
| --- | --- | --- | --- |
| [`libavif/`](libavif/) | libavif + dav1d | AVIF 解码（dav1d 仅解码） | macOS / iOS / Linux / Android / HarmonyOS / Windows(MSVC+MinGW) |
| [`v8/`](v8/) | V8 | Google JavaScript 引擎 (monolith 静态库) | macOS(arm64/x86_64) / Linux(x64) / Android(arm64) / Windows(x64 MSVC) |

> 新增库请参考 [docs/adding-a-new-library.md](docs/adding-a-new-library.md)。

## 仓库结构

```
.
├── scripts/
│   └── common.sh              # 跨库共享的 Bash 公共函数 (日志/加载 config/打包骨架)
├── docs/
│   └── adding-a-new-library.md
├── libavif/                   # 一个库 = 一个顶层目录
│   ├── config.env             # 版本与构建开关 (单一配置入口)
│   ├── cross/                 # meson 交叉文件说明
│   └── scripts/               # build_unix.sh / build_windows.ps1 / package.sh
├── v8/
│   ├── config.env
│   ├── gn_args/               # 各平台 GN 基础参数模板
│   └── scripts/               # fetch.sh / build_unix.sh / build_windows.ps1 / package.sh
└── .github/workflows/
    ├── libavif.yml            # 仅手动触发
    └── v8.yml                 # 仅手动触发
```

## 统一命名约定（各库一致，仅目标平台不同）

- **配置文件**：每个库根目录一律 `config.env`（`KEY=VALUE`，不带引号，可被 shell `source`）。
- **通用配置键**：`PACKAGE_NAME`、`PACKAGE_VERSION`（留空回退库主版本）、`ANDROID_API`、
  `IOS_DEPLOYMENT_TARGET`、`MACOS_DEPLOYMENT_TARGET`（按需）。
- **目标平台命名**：`macos-arm64`、`macos-x86_64`、`linux-x86_64`、`windows-x64-msvc`、
  `windows-x64-mingw`、`android-arm64-v8a`、`ios-arm64`、`harmony-arm64-v8a` …各库取子集。
- **产物命名**：`<PACKAGE_NAME>-<version>-<target>.tar.gz`（Windows MSVC 为 `.zip`）。
- **包内结构**：`include/`、`lib/`（静态库 + 可选 `pkgconfig/`）、`LICENSE-<component>`、`BUILD_INFO.txt`。
- **脚本接口**：`scripts/build_unix.sh <target>`、`scripts/build_windows.ps1 -Target <target>`、
  `scripts/package.sh <target>`；产物落 `<lib>/out/<target>`、打包到 `<lib>/dist/`。

## 如何触发构建 / 发布

所有 workflow **只支持手动触发**（不再有 push / tag 自动触发）：

1. 打开 GitHub 仓库的 **Actions** 页。
2. 选择要构建的库：`Build libavif + dav1d ...` 或 `Build V8 ...`。
3. 点 **Run workflow**，用平台开关选择要编译哪些平台。
4. 勾选 `publish` 可在构建后创建 Release（需填 `release_tag`，留空则回退 `config.env` 版本号）；
   不勾选则只产出 artifacts 供下载。

---

# libavif + dav1d

从源码交叉编译 **libavif（dav1d 仅解码）** 与 **libdav1d**，产出全平台**静态库**。

## 支持平台 / 架构

| 平台 | 架构 | 产物包名 |
| --- | --- | --- |
| macOS | arm64 | `libavif-dav1d-<ver>-macos-arm64.tar.gz` |
| macOS | x86_64 | `libavif-dav1d-<ver>-macos-x86_64.tar.gz` |
| iOS (设备) | arm64 | `libavif-dav1d-<ver>-ios-arm64.tar.gz` |
| iOS (模拟器) | arm64 | `libavif-dav1d-<ver>-ios-sim-arm64.tar.gz` |
| iOS (模拟器) | x86_64 | `libavif-dav1d-<ver>-ios-sim-x86_64.tar.gz` |
| Android | arm64-v8a | `libavif-dav1d-<ver>-android-arm64-v8a.tar.gz` |
| Android | armeabi-v7a | `libavif-dav1d-<ver>-android-armeabi-v7a.tar.gz` |
| HarmonyOS | arm64-v8a | `libavif-dav1d-<ver>-harmony-arm64-v8a.tar.gz` |
| Windows | x64 (MSVC) | `libavif-dav1d-<ver>-windows-x64-msvc.zip` |
| Windows | x64 (MinGW) | `libavif-dav1d-<ver>-windows-x64-mingw.tar.gz` |
| Linux | x86_64 | `libavif-dav1d-<ver>-linux-x86_64.tar.gz` |

> Windows 提供 **MSVC**（`avif.lib` / `dav1d.lib`）与 **MinGW**（`libavif.a` / `libdav1d.a`）两版，
> ABI 不兼容，请按项目编译器选择。libavif 以 `AVIF_CODEC_DAV1D=SYSTEM` 静态链接 dav1d，**仅解码**。

## 配置入口

所有版本集中在 [`libavif/config.env`](libavif/config.env)：

```bash
PACKAGE_NAME=libavif-dav1d
LIBAVIF_VERSION=v1.3.0     # libavif tag
DAV1D_VERSION=1.5.1        # dav1d tag
OHOS_CLI_VERSION=5.0.5.200 # OpenHarmony commandline-tools 版本
ANDROID_API=21
IOS_DEPLOYMENT_TARGET=13.0
MACOS_DEPLOYMENT_TARGET=11.0
ENABLE_LIBYUV=ON           # 是否内置 libyuv 加速色彩转换
PACKAGE_VERSION=           # 产物版本号，留空则用 LIBAVIF_VERSION
```

## 本地构建

```bash
# Unix (macOS / Linux)
bash libavif/scripts/build_unix.sh macos-arm64
bash libavif/scripts/package.sh    macos-arm64        # 产物在 libavif/dist/

# 交叉编译需提供工具链路径:
ANDROID_NDK_HOME=/path/to/ndk bash libavif/scripts/build_unix.sh android-arm64-v8a
OHOS_SDK_NATIVE=/path/to/ohos/native bash libavif/scripts/build_unix.sh harmony-arm64-v8a
bash libavif/scripts/build_unix.sh windows-x64-mingw  # 需 apt install mingw-w64
```

```powershell
# Windows MSVC (VS Developer PowerShell + meson ninja nasm)
pwsh libavif/scripts/build_windows.ps1 -Target windows-x64-msvc
```

## 下游链接

```cmake
target_include_directories(your_target PRIVATE ${AVIF_ROOT}/include)
target_link_libraries(your_target PRIVATE
    ${AVIF_ROOT}/lib/libavif.a
    ${AVIF_ROOT}/lib/libdav1d.a)   # Windows MSVC: avif.lib / dav1d.lib
```

pkg-config：`PKG_CONFIG_PATH=${AVIF_ROOT}/lib/pkgconfig pkg-config --cflags --libs libavif`。
各平台交叉工具链见 [`libavif/cross/meson/README.md`](libavif/cross/meson/README.md)。

---

# V8

用 GN + Ninja + depot_tools 从源码编译 V8，产出 **monolith 静态库**（`libv8_monolith.a` /
Windows `v8_monolith.lib`）。

## 支持平台 / 架构

| 平台 | 架构 | 产物 | 产物包名 |
| --- | --- | --- | --- |
| macOS | arm64 | `libv8_monolith.a` | `v8-<ver>-macos-arm64.tar.gz` |
| macOS | x86_64 | `libv8_monolith.a` | `v8-<ver>-macos-x86_64.tar.gz` |
| Linux | x86_64 | `libv8_monolith.a` | `v8-<ver>-linux-x86_64.tar.gz` |
| Android | arm64-v8a | `libv8_monolith.a` | `v8-<ver>-android-arm64-v8a.tar.gz` |
| Windows | x64 (MSVC) | `v8_monolith.lib` | `v8-<ver>-windows-x64-msvc.zip` |

> iOS 与 HarmonyOS 未纳入：iOS 需 jitless 且政策受限（通常用 JavaScriptCore），
> HarmonyOS 无 V8 官方支持。Windows 仅 MSVC/clang-cl（V8 不走 MinGW）。

## 配置入口

版本与构建开关集中在 [`v8/config.env`](v8/config.env)：

```bash
PACKAGE_NAME=v8
V8_VERSION=14.9.207.29                 # 对应 Chromium 里程碑的稳定 tag
IS_DEBUG=false
SYMBOL_LEVEL=0                         # 0=无符号(最小体积)
V8_ENABLE_I18N=false                   # 关 ICU 可显著减小体积
V8_ENABLE_WEBASSEMBLY=false
V8_ENABLE_POINTER_COMPRESSION=true     # 须与下游一致
ANDROID_API=24                         # V8 要求 >= 23
```

各平台 GN 基础参数模板见 [`v8/gn_args/`](v8/gn_args/)；脚本会把 `config.env` 的可调项
追加进最终 `args.gn`。所有构建配置**一律以 `v8/config.env` 为准**，手动触发表单只保留
平台开关与 `publish` / `release_tag`，不再暴露构建参数——要改配置请直接改 `v8/config.env`。

## 本地构建

```bash
# Unix (macOS / Linux / Android)。先拉源码 (较慢)，再构建、打包
bash v8/scripts/fetch.sh       macos-arm64        # 或 macos-x86_64
bash v8/scripts/build_unix.sh  macos-arm64
bash v8/scripts/package.sh     macos-arm64        # 产物在 v8/dist/
```

```powershell
# Windows MSVC (自包含: 拉源码 + 构建 + 打包)
pwsh v8/scripts/build_windows.ps1 -Target windows-x64-msvc
```

> V8 编译耗时长（数十分钟至数小时），且 `.a` 文件可达数十~数百 MB；实际链接进程序后
> 由链接器裁剪，最终体积通常远小于归档文件。

## 下游链接

```cmake
target_include_directories(your_target PRIVATE ${V8_ROOT}/include)
target_link_libraries(your_target PRIVATE ${V8_ROOT}/lib/libv8_monolith.a)
# Windows MSVC: ${V8_ROOT}/lib/v8_monolith.lib
```

嵌入示例见 [V8 官方 embed 文档](https://v8.dev/docs/embed)。注意下游的
`v8_enable_pointer_compression` 等编译期开关须与本仓库产物一致。

> Linux 与 macOS 版都用 V8 自带 libc++ 编译，并已把 `libc++`/`libc++abi` 合并进
> `libv8_monolith.a`，下游仍只需链接这一个 `.a`。
> - Linux 起因：sysroot 的 libstdc++ 太老、缺 `std::bit_cast`；下游用系统 gcc/clang（走
>   libstdc++）与内部 libc++ 的 `std::__1` 符号一般互不冲突。
> - macOS 起因：Xcode SDK 的 libc++ 与 partition_alloc 的 `-fvisibility-global-new-delete=force-hidden`
>   冲突（`operator new/delete` 可见性不一致）。
>
> 若下游自身也静态链接同一套 libc++，可能出现符号重复，属自带 libc++ 嵌入的已知取舍。

## 实现说明

- **libavif**：dav1d 用 Meson 交叉编译为静态库，libavif 用 CMake（`AVIF_CODEC_DAV1D=SYSTEM`）静态链接。
- **V8**：depot_tools + `gclient sync` 拉源码与工具链（Android NDK 由 DEPS 自带），
  `gn gen` + `ninja v8_monolith` 产出单一静态库。
- 工作流：[`.github/workflows/libavif.yml`](.github/workflows/libavif.yml)、
  [`.github/workflows/v8.yml`](.github/workflows/v8.yml)。
