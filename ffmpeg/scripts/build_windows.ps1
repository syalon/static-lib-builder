<#
=============================================================================
 FFmpeg minimal static 构建 (Windows MSVC)

 用法:
   pwsh ffmpeg/scripts/build_windows.ps1 -Target windows-x64-msvc

 依赖: Visual Studio (cl/link/lib)、Git Bash、nasm
 产物: ffmpeg/out/windows-x64-msvc/{include,lib/*.lib}

 configure 参数与内部引擎 minimal 视频配置对齐；使用 --toolchain=msvc + nmake。
=============================================================================
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$Target = "windows-x64-msvc"
)

$ErrorActionPreference = "Stop"

if ($Target -ne "windows-x64-msvc") {
    throw "build_windows.ps1 仅支持 windows-x64-msvc（MinGW 请用 build_unix.sh windows-x64-mingw）"
}

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$LibRoot   = (Resolve-Path (Join-Path $ScriptDir "..")).Path
$RepoRoot  = (Resolve-Path (Join-Path $LibRoot "..")).Path

$Versions = @{}
Get-Content (Join-Path $LibRoot "config.env") | ForEach-Object {
    $line = $_.Trim()
    if ($line -and -not $line.StartsWith("#") -and $line.Contains("=")) {
        $kv = $line.Split("=", 2)
        $Versions[$kv[0].Trim()] = $kv[1].Trim()
    }
}

$FfmpegVersion = $Versions["FFMPEG_VERSION"]
$Decoders  = $Versions["FFMPEG_DECODERS"]
$Demuxers  = $Versions["FFMPEG_DEMUXERS"]
$Parsers   = $Versions["FFMPEG_PARSERS"]
$Protocols = $Versions["FFMPEG_PROTOCOLS"]

$Work   = Join-Path $LibRoot "work\$Target"
$Prefix = Join-Path $LibRoot "out\$Target"
$Src    = Join-Path $Work "FFmpeg"
$Jobs   = [Environment]::ProcessorCount

if (Test-Path $Prefix) { Remove-Item -Recurse -Force $Prefix }
New-Item -ItemType Directory -Force -Path $Work, $Prefix | Out-Null

Write-Host "==> Target  : $Target"
Write-Host "==> FFmpeg  : release/$FfmpegVersion"
Write-Host "==> Prefix  : $Prefix"

function Invoke-Checked([scriptblock]$Block) {
    & $Block
    if ($LASTEXITCODE -ne 0) { throw "命令失败，退出码 $LASTEXITCODE" }
}

# 1) 源码
if (-not (Test-Path (Join-Path $Src ".git"))) {
    Invoke-Checked { git clone --depth 1 -b "release/$FfmpegVersion" `
        https://github.com/FFmpeg/FFmpeg.git $Src }
}

# 2) configure（Git Bash 跑 FFmpeg 的 shell configure；MSVC 用 --toolchain=msvc）
$PrefixUnix = ($Prefix -replace '\\', '/')
$CfgArgs = @(
    "./configure"
    "--prefix=$PrefixUnix"
    "--toolchain=msvc"
    "--arch=x86_64"
    "--target-os=win64"
    "--disable-debug"
    "--enable-stripping"
    "--enable-static"
    "--disable-shared"
    "--enable-pic"
    "--disable-autodetect"
    "--disable-programs"
    "--disable-doc"
    "--disable-gpl"
    "--disable-version3"
    "--disable-nonfree"
    "--enable-avcodec"
    "--enable-avformat"
    "--enable-swscale"
    "--enable-swresample"
    "--disable-avdevice"
    "--disable-avfilter"
    "--disable-postproc"
    "--disable-everything"
    '--extra-cflags="-O3 -w"'
)

foreach ($d in $Decoders.Split(" ", [StringSplitOptions]::RemoveEmptyEntries)) {
    $CfgArgs += "--enable-decoder=$d"
}
foreach ($d in $Demuxers.Split(" ", [StringSplitOptions]::RemoveEmptyEntries)) {
    $CfgArgs += "--enable-demuxer=$d"
}
foreach ($p in $Parsers.Split(" ", [StringSplitOptions]::RemoveEmptyEntries)) {
    $CfgArgs += "--enable-parser=$p"
}
foreach ($p in $Protocols.Split(" ", [StringSplitOptions]::RemoveEmptyEntries)) {
    $CfgArgs += "--enable-protocol=$p"
}

$CfgLine = ($CfgArgs -join " ")
Write-Host "==> configure (bash): $CfgLine"

Invoke-Checked {
    bash -lc "cd '$($Src -replace '\\','/')' && $CfgLine"
}

# 3) make（FFmpeg 即使 --toolchain=msvc 也只支持 GNU make，不支持 nmake）
$SrcUnix = ($Src -replace '\\', '/')
Invoke-Checked {
    bash -lc "cd '$SrcUnix' && make -j$Jobs && make install"
}

Write-Host "==> 完成: $Prefix"
