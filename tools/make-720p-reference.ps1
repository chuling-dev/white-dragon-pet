#Requires -Version 5.1
<#
.SYNOPSIS
  把 640x360 桌宠素材升采样成 1280x720 MP4，用于 AI 平台（豆包等）的参考视频。

.DESCRIPTION
  豆包要求参考视频的分辨率在 409600–2086876 像素之间；640x360（230400）不达标，
  1280x720（921600）达标。本脚本批量转换并输出 H.264 + faststart 的 MP4。

.EXAMPLE
  .\make-720p-reference.ps1 -InputDir .\clips -OutputDir .\desktop
#>
param(
  [Parameter(Mandatory = $true)] [string] $InputDir,
  [Parameter(Mandatory = $true)] [string] $OutputDir,
  [string] $Ffmpeg = ''
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path $InputDir)) { throw "输入目录不存在: $InputDir" }
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

if (-not $Ffmpeg) {
  $cmd = Get-Command ffmpeg -ErrorAction SilentlyContinue
  if ($cmd) { $Ffmpeg = $cmd.Source }
}
if (-not $Ffmpeg -or -not (Test-Path $Ffmpeg)) { throw '找不到 ffmpeg.exe，请用 -Ffmpeg 指定' }

$files = Get-ChildItem $InputDir -File | Where-Object { $_.Extension -in '.webm', '.mp4' }
Write-Host "待转换 $($files.Count) 个视频..."
foreach ($f in $files) {
  $base = [IO.Path]::GetFileNameWithoutExtension($f.Name)
  $out = Join-Path $OutputDir ($base + '-1280x720.mp4')
  & $Ffmpeg -hide_banner -loglevel error -i $f.FullName -vf 'scale=1280:720:flags=lanczos' -c:v libx264 -pix_fmt yuv420p -crf 18 -preset medium -movflags +faststart -an -y $out
  if (Test-Path $out) {
    Write-Host ("  OK  {0}  ({1:N0} 字节)" -f (Split-Path $out -Leaf), (Get-Item $out).Length)
  } else {
    Write-Host ("  FAIL {0}" -f $base) -ForegroundColor Red
  }
}
