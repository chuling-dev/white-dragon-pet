#Requires -Version 5.1
<#
.SYNOPSIS
  把白色大肥龙角色包装进 dsh-pet-indesktop 安装目录，并切换当前角色。

.EXAMPLE
  .\install.ps1 -PetDir "C:\Users\me\AppData\Local\Programs\dsh-pet-standalone-webm-chat"

.EXAMPLE
  .\install.ps1 -PetDir "D:\dsh-pet" -RoleName white_fat_dragon -DisplayName "白色大肥龙"
#>
param(
  [Parameter(Mandatory = $true)] [string] $PetDir,
  [string] $RoleName = 'white_fat_dragon',
  [string] $DisplayName = '白色大肥龙',
  [switch] $NoRestart
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $PetDir)) { throw "dsh-pet 安装目录不存在: $PetDir" }
$exe = Join-Path $PetDir 'dsh-pet-standalone-webm-chat.exe'
if (-not (Test-Path $exe)) { throw "找不到 dsh-pet 主程序: $exe" }

$repoRoot = Split-Path $PSScriptRoot -Parent
$roleSrc  = Join-Path $repoRoot "characters\$RoleName"
if (-not (Test-Path $roleSrc)) { throw "仓库里找不到角色目录: $roleSrc" }

$charsDir = Join-Path $PetDir '_internal\assets\characters'
$roleDst  = Join-Path $charsDir $RoleName
New-Item -ItemType Directory -Force -Path $roleDst | Out-Null
robocopy $roleSrc $roleDst /E /NFL /NDL /NJH /NJS /R:1 /W:1 | Out-Null
Write-Host "[1/3] 角色素材已复制 -> $roleDst"

# config lives under %APPDATA%\<exe-name>
$cfg = Join-Path $env:APPDATA 'dsh-pet-standalone-webm-chat\config.json'
if (-not (Test-Path $cfg)) {
  Write-Host "[2/3] 未找到 config.json（$cfg），首次启动桌宠后会自动生成；先启动一次再运行本脚本即可。" -ForegroundColor Yellow
} else {
  Copy-Item $cfg "$cfg.bak-$(Get-Date -Format yyyyMMdd-HHmmss)" -Force
  $raw = [IO.File]::ReadAllText($cfg)
  $raw = [regex]::Replace($raw, '"character"\s*:\s*"[^"]*"', '"character": "' + $RoleName + '"')
  if ($raw -notmatch '"' + [regex]::Escape($RoleName) + '"\s*:\s*"') {
    $raw = [regex]::Replace($raw, '"character_aliases"\s*:\s*\{', '"character_aliases": {' + "`n    `"$RoleName`": `"$DisplayName`",")
  }
  [IO.File]::WriteAllText($cfg, $raw, (New-Object Text.UTF8Encoding($false)))
  Write-Host "[2/3] config.json 已切换角色为 $RoleName（$DisplayName）"
}

if (-not $NoRestart) {
  Write-Host '[3/3] 重启桌宠以加载新角色...'
  Get-Process -Name 'dsh-pet-standalone-webm-chat' -ErrorAction SilentlyContinue | Stop-Process -Force
  Start-Sleep -Seconds 3
  Start-Process -FilePath $exe -ArgumentList '--slot','0' -WorkingDirectory $PetDir
  Start-Sleep -Seconds 8
  Write-Host '完成。桌宠日志里应出现「当前形象: ' $RoleName '」。'
}
