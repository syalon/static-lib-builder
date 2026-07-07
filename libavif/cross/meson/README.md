# Meson 交叉编译文件 (Cross files)

dav1d 使用 Meson 构建。交叉编译时需要向 `meson setup` 传入 `--cross-file`。

为避免把随 Xcode / NDK 版本变化的 SDK 绝对路径硬编码进仓库，
这些 cross file **由 [`scripts/build_unix.sh`](../../scripts/build_unix.sh) 在构建时动态生成**
（生成到 `work/<target>/*.cross.txt`）。本目录仅作结构说明与手动构建参考。

libavif 使用 CMake，交叉参数由脚本通过 `-DCMAKE_TOOLCHAIN_FILE=` / `-DCMAKE_OSX_*`
等直接传入，不需要 cross file。

## 各平台生成逻辑

- Apple (macOS / iOS / 模拟器): 用 `xcrun --sdk <sdk> --show-sdk-path` / `--find clang`
  解析编译器与 sysroot，写入 `[binaries]` 与 `[built-in options]`（`-arch` / `-isysroot` /
  最低版本 flag）。见 `gen_apple_meson_cross`。
- Android: 依据 `ANDROID_NDK_HOME` 定位 `toolchains/llvm/prebuilt/<host>/bin` 下的
  `<triple><API>-clang`，见 `gen_android_meson_cross`。
- HarmonyOS: 依据 `OHOS_SDK_NATIVE` 定位 `llvm/bin/aarch64-unknown-linux-ohos-clang`，
  见 `gen_ohos_meson_cross`。

## 结构示例 (iOS arm64 设备)

```ini
[binaries]
c = '/Applications/Xcode.app/.../usr/bin/clang'
cpp = '/Applications/Xcode.app/.../usr/bin/clang++'
ar = '/Applications/Xcode.app/.../usr/bin/ar'
strip = '/Applications/Xcode.app/.../usr/bin/strip'
pkg-config = 'pkg-config'

[built-in options]
c_args = ['-arch', 'arm64', '-isysroot', '<iPhoneOS SDK 路径>', '-miphoneos-version-min=13.0']
c_link_args = ['-arch', 'arm64', '-isysroot', '<iPhoneOS SDK 路径>', '-miphoneos-version-min=13.0']

[host_machine]
system = 'darwin'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'
```

## 结构示例 (HarmonyOS arm64-v8a)

```ini
[binaries]
c = '<OHOS_SDK_NATIVE>/llvm/bin/aarch64-unknown-linux-ohos-clang'
cpp = '<OHOS_SDK_NATIVE>/llvm/bin/aarch64-unknown-linux-ohos-clang++'
ar = '<OHOS_SDK_NATIVE>/llvm/bin/llvm-ar'
strip = '<OHOS_SDK_NATIVE>/llvm/bin/llvm-strip'
pkg-config = 'pkg-config'

[host_machine]
system = 'linux'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'
```
