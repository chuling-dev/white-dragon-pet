#Requires -Version 5.1
<#
.SYNOPSIS
  把黑底视频（AI 生成）转换成 dsh-pet 可用的透明 WebM（带 alpha、640x360、24fps）。

.DESCRIPTION
  处理流程：
    1. 缩放到 640x360
    2. 区域生长抠像：只把与画面边缘连通的暗色当背景（保住眼睛、睫毛等内部深色）
    3. 灰黑封闭块清理：清掉被角色包围的深色背景块（尾巴与身体之间的封闭黑块）
    4. 5x5 多数滤波平滑（不做腐蚀，避免细尾巴断裂）
    5. 1px 实心描边 + 两级抗锯齿过渡
    6. VP9 + yuva420p 编码

.PARAMETER InputDir    存放黑底视频的目录（.mp4 / .webm）
.PARAMETER OutputDir   输出透明 WebM 的目录（通常是角色包的某个分类目录，如 videos\random）
.PARAMETER Ffmpeg      ffmpeg.exe 路径；默认自动在 PetDir 内查找
.PARAMETER PetDir      dsh-pet 安装目录（用于定位自带的 ffmpeg）
.PARAMETER HoleMinArea 封闭黑块的最小面积（像素），默认 30；调大可减少清理力度
.PARAMETER KeepSmallParts 保留独立小部件（漂浮光球/礼物盒等）；默认会清掉面积 <= 3500 的孤立小岛
.PARAMETER NoOutline   不绘制描边

.EXAMPLE
  .\key-black.ps1 -InputDir .\raw -OutputDir .\characters\white_fat_dragon\videos\random
#>
param(
  [Parameter(Mandatory = $true)] [string] $InputDir,
  [Parameter(Mandatory = $true)] [string] $OutputDir,
  [string] $PetDir = '',
  [string] $Ffmpeg = '',
  [int] $HoleMinArea = 30,
  [switch] $KeepSmallParts,
  [switch] $NoOutline
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $InputDir)) { throw "输入目录不存在: $InputDir" }
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

if (-not $Ffmpeg) {
  $candidates = @()
  if ($PetDir) {
    $candidates += Get-ChildItem (Join-Path $PetDir '_internal\imageio_ffmpeg\binaries') -Filter 'ffmpeg*.exe' -ErrorAction SilentlyContinue
  }
  if (-not $candidates -or $candidates.Count -eq 0) {
    $cmd = Get-Command ffmpeg -ErrorAction SilentlyContinue
    if ($cmd) { $candidates = @(Get-Item $cmd.Source) } elseif ($Ffmpeg = '') { }
  }
  if ($candidates.Count -gt 0) { $Ffmpeg = $candidates[0].FullName }
}
if (-not $Ffmpeg -or -not (Test-Path $Ffmpeg)) { throw "找不到 ffmpeg.exe，请用 -Ffmpeg 指定，或用 -PetDir 指向 dsh-pet 安装目录" }

Add-Type -ReferencedAssemblies System.Core @"
using System;
public class BlackKeyPipeline {
  static bool[] Dilate(bool[] m, int w, int h) {
    bool[] r = new bool[w*h];
    for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) {
      int i = y*w+x; if (!m[i]) continue;
      for (int dy = -1; dy <= 1; dy++) { int ny = y+dy; if (ny < 0 || ny >= h) continue;
        for (int dx = -1; dx <= 1; dx++) { int nx = x+dx; if (nx < 0 || nx >= w) continue; r[ny*w+nx] = true; } }
    }
    return r;
  }
  static bool[] Majority5(bool[] m, int w, int h) {
    bool[] r = new bool[w*h];
    for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) {
      int cnt = 0, tot = 0;
      for (int dy = -2; dy <= 2; dy++) { int ny = y+dy; if (ny < 0 || ny >= h) continue;
        for (int dx = -2; dx <= 2; dx++) { int nx = x+dx; if (nx < 0 || nx >= w) continue; tot++; if (m[ny*w+nx]) cnt++; } }
      r[y*w+x] = cnt * 2 > tot;
    }
    return r;
  }
  static bool IsGreyDark(byte r, byte g, byte b, int vMax, float satMax) {
    int mx = Math.Max(r, Math.Max(g, b));
    int mn = Math.Min(r, Math.Min(g, b));
    if (mx >= vMax) return false;
    float sat = (mx == 0) ? 0f : (float)(mx - mn) / mx;
    return sat < satMax;
  }
  public static byte[] ProcessFrame(byte[] rgb, int w, int h, int smallIslandMax, int holeMinArea, int outline) {
    int n = w * h;
    bool[] seed = new bool[n], grow = new bool[n], holeNear = new bool[n];
    for (int i = 0; i < n; i++) {
      int o = i * 3;
      int mx = Math.Max(rgb[o], Math.Max(rgb[o+1], rgb[o+2]));
      seed[i] = mx < 20;
      grow[i] = mx < 58;
      holeNear[i] = IsGreyDark(rgb[o], rgb[o+1], rgb[o+2], 55, 0.40f);
    }
    bool[] bg = new bool[n];
    int[] q = new int[n * 4];
    int head = 0, tail = 0;
    for (int y = 0; y < h; y++) for (int xx = 0; xx < 2; xx++) {
      int x = xx == 0 ? 0 : w - 1; int i = y*w+x;
      if (seed[i] && !bg[i]) { bg[i] = true; q[tail++] = i; }
    }
    for (int x = 0; x < w; x++) for (int yy = 0; yy < 2; yy++) {
      int y = yy == 0 ? 0 : h - 1; int i = y*w+x;
      if (seed[i] && !bg[i]) { bg[i] = true; q[tail++] = i; }
    }
    while (head < tail) {
      int i = q[head++]; int x = i % w, y = i / w;
      if (x > 0)     { int j = i-1; if (grow[j] && !bg[j]) { bg[j] = true; q[tail++] = j; } }
      if (x < w-1)   { int j = i+1; if (grow[j] && !bg[j]) { bg[j] = true; q[tail++] = j; } }
      if (y > 0)     { int j = i-w; if (grow[j] && !bg[j]) { bg[j] = true; q[tail++] = j; } }
      if (y < h-1)   { int j = i+w; if (grow[j] && !bg[j]) { bg[j] = true; q[tail++] = j; } }
    }
    bool[] visited = new bool[n];
    int[] cq = new int[n];
    for (int i = 0; i < n; i++) {
      if (bg[i] || visited[i] || !holeNear[i]) continue;
      int cHead = 0, cTail = 0;
      visited[i] = true; cq[cTail++] = i;
      while (cHead < cTail) {
        int j = cq[cHead++]; int x = j % w, y = j / w;
        if (x > 0)   { int k = j-1; if (!bg[k] && !visited[k] && holeNear[k]) { visited[k] = true; cq[cTail++] = k; } }
        if (x < w-1) { int k = j+1; if (!bg[k] && !visited[k] && holeNear[k]) { visited[k] = true; cq[cTail++] = k; } }
        if (y > 0)   { int k = j-w; if (!bg[k] && !visited[k] && holeNear[k]) { visited[k] = true; cq[cTail++] = k; } }
        if (y < h-1) { int k = j+w; if (!bg[k] && !visited[k] && holeNear[k]) { visited[k] = true; cq[cTail++] = k; } }
      }
      if (cTail >= holeMinArea) { for (int k = 0; k < cTail; k++) bg[cq[k]] = true; }
    }
    if (smallIslandMax > 0) {
      for (int i = 0; i < n; i++) visited[i] = false;
      for (int i = 0; i < n; i++) {
        if (bg[i] || visited[i]) continue;
        int cHead = 0, cTail = 0;
        visited[i] = true; cq[cTail++] = i;
        while (cHead < cTail) {
          int j = cq[cHead++]; int x = j % w, y = j / w;
          if (x > 0)   { int k = j-1; if (!bg[k] && !visited[k]) { visited[k] = true; cq[cTail++] = k; } }
          if (x < w-1) { int k = j+1; if (!bg[k] && !visited[k]) { visited[k] = true; cq[cTail++] = k; } }
          if (y > 0)   { int k = j-w; if (!bg[k] && !visited[k]) { visited[k] = true; cq[cTail++] = k; } }
          if (y < h-1) { int k = j+w; if (!bg[k] && !visited[k]) { visited[k] = true; cq[cTail++] = k; } }
        }
        if (cTail <= smallIslandMax) { for (int k = 0; k < cTail; k++) bg[cq[k]] = true; }
      }
    }
    bool[] mask = new bool[n];
    for (int i = 0; i < n; i++) mask[i] = !bg[i];
    mask = Majority5(mask, w, h);
    mask = Majority5(mask, w, h);
    int[] dist = new int[n];
    for (int i = 0; i < n; i++) dist[i] = -1;
    int[] dq = new int[n];
    int dh = 0, dt = 0;
    if (outline > 0) {
      for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) {
        int i = y*w+x;
        if (mask[i]) continue;
        bool adj = false;
        if (x > 0 && mask[i-1]) adj = true;
        if (x < w-1 && mask[i+1]) adj = true;
        if (y > 0 && mask[i-w]) adj = true;
        if (y < h-1 && mask[i+w]) adj = true;
        if (adj) { dist[i] = 1; dq[dt++] = i; }
      }
      while (dh < dt) {
        int i = dq[dh++];
        if (dist[i] >= 3) continue;
        int x = i % w, y = i / w;
        if (x > 0)     { int j = i-1; if (!mask[j] && dist[j] < 0) { dist[j] = dist[i] + 1; dq[dt++] = j; } }
        if (x < w-1)   { int j = i+1; if (!mask[j] && dist[j] < 0) { dist[j] = dist[i] + 1; dq[dt++] = j; } }
        if (y > 0)     { int j = i-w; if (!mask[j] && dist[j] < 0) { dist[j] = dist[i] + 1; dq[dt++] = j; } }
        if (y < h-1)   { int j = i+w; if (!mask[j] && dist[j] < 0) { dist[j] = dist[i] + 1; dq[dt++] = j; } }
      }
    }
    byte[] outBuf = new byte[n + n / 4 + n / 4 + n];
    int yOff = 0, uOff = n, vOff = n + n / 4, aOff = n + n / 2;
    for (int i = 0; i < n; i++) {
      int o = i * 3;
      float r, g, b; byte a;
      if (mask[i]) { r = rgb[o]; g = rgb[o+1]; b = rgb[o+2]; a = 255; }
      else if (dist[i] == 1) { r = 0; g = 0; b = 0; a = 255; }
      else if (dist[i] == 2) { r = 0; g = 0; b = 0; a = 128; }
      else if (dist[i] == 3) { r = 0; g = 0; b = 0; a = 42; }
      else { r = rgb[o]; g = rgb[o+1]; b = rgb[o+2]; a = 0; }
      float yy = 16 + 0.257f * r + 0.504f * g + 0.098f * b;
      if (yy < 16) yy = 16; if (yy > 235) yy = 235;
      outBuf[yOff + i] = (byte)yy;
      outBuf[aOff + i] = a;
    }
    for (int y = 0; y < h; y += 2) {
      for (int x = 0; x < w; x += 2) {
        int i00 = y * w + x, i01 = i00 + 1, i10 = i00 + w, i11 = i10 + 1;
        float r = (rgb[i00*3] + rgb[i01*3] + rgb[i10*3] + rgb[i11*3]) / 4f;
        float g = (rgb[i00*3+1] + rgb[i01*3+1] + rgb[i10*3+1] + rgb[i11*3+1]) / 4f;
        float b = (rgb[i00*3+2] + rgb[i01*3+2] + rgb[i10*3+2] + rgb[i11*3+2]) / 4f;
        float u = 128 - 0.148f * r - 0.291f * g + 0.439f * b;
        float v = 128 + 0.439f * r - 0.368f * g - 0.071f * b;
        if (u < 16) u = 16; if (u > 240) u = 240;
        if (v < 16) v = 16; if (v > 240) v = 240;
        int idx = (y / 2) * (w / 2) + (x / 2);
        outBuf[uOff + idx] = (byte)u;
        outBuf[vOff + idx] = (byte)v;
      }
    }
    return outBuf;
  }
}
"@

$W = 640; $H = 360; $FPS = 24
$islandMax = if ($KeepSmallParts) { 0 } else { 3500 }
$outlinePx = if ($NoOutline) { 0 } else { 1 }

$files = Get-ChildItem $InputDir -File | Where-Object { $_.Extension -in '.mp4', '.webm' }
if ($files.Count -eq 0) { throw "输入目录里没有找到 .mp4/.webm: $InputDir" }
Write-Host "待处理 $($files.Count) 个视频..."

foreach ($f in $files) {
  $base = [IO.Path]::GetFileNameWithoutExtension($f.Name)
  $dest = Join-Path $OutputDir ($base + '.webm')
  $tmp  = Join-Path $OutputDir 'tmp-key.webm'
  Remove-Item $tmp -Force -ErrorAction SilentlyContinue

  $p1 = New-Object System.Diagnostics.Process
  $p1.StartInfo.FileName = $Ffmpeg
  $p1.StartInfo.Arguments = "-loglevel error -i `"$($f.FullName)`" -vf scale=640:360 -f rawvideo -pix_fmt rgb24 -"
  $p1.StartInfo.UseShellExecute = $false
  $p1.StartInfo.RedirectStandardOutput = $true
  $p1.StartInfo.RedirectStandardError = $true
  $p2 = New-Object System.Diagnostics.Process
  $p2.StartInfo.FileName = $Ffmpeg
  $p2.StartInfo.Arguments = "-y -loglevel error -f rawvideo -pix_fmt yuva420p -s 640x360 -r $FPS -i - -c:v libvpx-vp9 -pix_fmt yuva420p -crf 18 -b:v 0 -auto-alt-ref 0 -deadline good -cpu-used 4 -an `"$tmp`""
  $p2.StartInfo.UseShellExecute = $false
  $p2.StartInfo.RedirectStandardInput = $true
  $p2.StartInfo.RedirectStandardError = $true
  $p1.Start() | Out-Null
  $p2.Start() | Out-Null
  $frameSize = $W * $H * 3
  $in = New-Object System.IO.BinaryReader($p1.StandardOutput.BaseStream)
  $outW = New-Object System.IO.BinaryWriter($p2.StandardInput.BaseStream)
  $count = 0
  while ($true) {
    $buf = $in.ReadBytes($frameSize)
    if ($buf.Length -lt $frameSize) { break }
    $outW.Write([BlackKeyPipeline]::ProcessFrame($buf, $W, $H, $islandMax, $HoleMinArea, $outlinePx))
    $count++
  }
  $outW.Flush(); $outW.Close()
  $p1.WaitForExit(); $p2.WaitForExit()
  if (Test-Path $tmp) {
    Move-Item -LiteralPath $tmp -Destination $dest -Force
    Write-Host ("  OK  {0}.webm  ({1} 帧, {2:N0} 字节)" -f $base, $count, (Get-Item $dest).Length)
  } else {
    Write-Host ("  FAIL {0}" -f $base) -ForegroundColor Red
  }
}
Write-Host '全部完成。把输出目录里的 webm 放进角色包的对应分类目录即可。'
