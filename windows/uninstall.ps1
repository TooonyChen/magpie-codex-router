<#
.SYNOPSIS
  卸载 Codex magpie relay，并把 config.toml 还原成安装前的样子。

.DESCRIPTION
  0. 如果当前是 codex-mode 的 magpie 模式，先恢复保存的 ChatGPT 登录
  1. 删除计划任务 / 启动文件夹快捷方式和 codex-mode 命令，停止 relay
  2. 还原 config.toml：默认只把 install 改过的键（model、model_provider、model_reasoning_effort、
     model_catalog_json、openai_base_url）和 [model_providers.magpie] 恢复成安装前的原值，
     其余设置保持当前状态；-RestoreBackup 则整份恢复第一次安装前的备份
  3. 询问是否删除凭据管理器里的 magpie-api-key（-DeleteKey / -KeepKey 可跳过询问）
  4. 删除 %USERPROFILE%\.codex\magpie-relay\（-KeepFiles 保留）

.EXAMPLE
  .\uninstall.cmd
.EXAMPLE
  .\uninstall.ps1 -RestoreBackup -DeleteKey
#>
[CmdletBinding()]
param(
    [switch]$RestoreBackup,
    [switch]$KeepConfig,
    [switch]$DeleteKey,
    [switch]$KeepKey,
    [switch]$KeepFiles,
    [switch]$Force
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'magpie-relay-common.ps1')
# 不要占用将被删除的目录
Set-Location -LiteralPath $env:USERPROFILE
[Environment]::CurrentDirectory = $env:USERPROFILE

$state = Read-InstallState
if (-not $state) { Write-Warn "没有找到 $($Script:StatePath)：只清理任务、进程和文件，不修改 config.toml" }
$port = 18765
if ($state -and $state.port) { $port = [int]$state.port }
$hasOriginal = [bool]($state -and $state.PSObject.Properties['originalConfig'] -and $state.originalConfig)
$willEditConfig = (-not $KeepConfig) -and $state -and ($hasOriginal -or $RestoreBackup)

if ($willEditConfig) {
    $codexProcs = @(Get-Process -Name 'Codex' -ErrorAction SilentlyContinue)
    if ($codexProcs.Count -gt 0) {
        Write-Warn 'Codex Desktop 正在运行。它运行时可能改写 config.toml，还原要在完全退出再重开后才生效。'
        if (-not $Force -and -not (Confirm-Choice '仍然继续？' $false)) { throw '已取消' }
    }
}

# ------------------------------------------------------------------ 0. ChatGPT 登录
if ((Get-CodexAuthMode) -eq 'apikey' -and (Test-Path -LiteralPath $Script:SavedAuthPath)) {
    Write-Step '恢复 ChatGPT 登录（当前是 codex-mode 的 magpie 模式）'
    if ((Get-CodexDesktopProcesses).Count -gt 0) {
        throw '请先完全退出 Codex Desktop（包括系统托盘）再运行卸载，需要先恢复 ChatGPT 登录。'
    }
    Copy-Item -LiteralPath $Script:SavedAuthPath -Destination $Script:AuthPath -Force
    Write-Ok '已恢复 auth.json'
}

# ------------------------------------------------------------------ 1. 自启动和进程
Write-Step '停止 relay 并移除自启动'
Remove-RelayAutostart
if (Remove-CodexModeShim) { Write-Ok "已删除 $($Script:ShimPath)" }
Stop-Relay
$left = @(Get-RelayProcesses)
if ($left.Count -gt 0) { Write-Warn "仍有 relay 进程：$(($left | ForEach-Object { $_.ProcessId }) -join ', ')" } else { Write-Ok 'relay 已停止' }

# ------------------------------------------------------------------ 2. config.toml
Write-Step "还原 $($Script:ConfigPath)"
if ($KeepConfig) {
    Write-Info '按要求保留当前 config.toml（注意它仍指向已删除的 relay）'
} elseif (-not $state) {
    Write-Info '没有安装记录，跳过'
} elseif ($RestoreBackup) {
    $b = $state.firstConfigBackup
    if (-not $b -or -not (Test-Path -LiteralPath $b)) { throw "找不到安装前的备份：$b" }
    $safety = "$($Script:ConfigPath).before-magpie-relay-uninstall-$(Get-Date -Format 'yyyyMMddTHHmmss').bak"
    if (Test-Path -LiteralPath $Script:ConfigPath) { Copy-Item -LiteralPath $Script:ConfigPath -Destination $safety; Write-Ok "当前配置已另存为 $safety" }
    Write-TextFileAtomic $Script:ConfigPath ([IO.File]::ReadAllText($b))
    Write-Ok "已整份恢复 $b"
} elseif (-not $hasOriginal) {
    Write-Info 'install 没有修改过 config.toml（用了 -SkipConfig 或中途失败），跳过'
} else {
    $text = ''
    if (Test-Path -LiteralPath $Script:ConfigPath) { $text = [IO.File]::ReadAllText($Script:ConfigPath) }
    $parts = Split-CodexConfig $text
    $proceed = $true
    if ($parts.ProviderTable -and ($parts.ProviderTable -notmatch [regex]::Escape("127.0.0.1:$port"))) {
        Write-Warn '当前的 [model_providers.magpie] 已经不指向 relay，可能被手动改过。'
        if (-not $Force) { $proceed = Confirm-Choice '仍然恢复成安装前的样子？' $false }
    }
    if ($proceed) {
        $safety = "$($Script:ConfigPath).before-magpie-relay-uninstall-$(Get-Date -Format 'yyyyMMddTHHmmss').bak"
        if (Test-Path -LiteralPath $Script:ConfigPath) { Copy-Item -LiteralPath $Script:ConfigPath -Destination $safety; Write-Ok "当前配置已另存为 $safety" }
        $orig = $state.originalConfig
        $top = @()
        foreach ($k in $Script:ManagedKeys) {
            $line = $null
            if ($orig.managed -and $orig.managed.PSObject.Properties[$k]) { $line = $orig.managed.$k }
            if ($line) { $top += $line }
        }
        $newText = Join-CodexConfig $parts $top $orig.providerTable
        $py = $null
        if ($state.python -and (Test-Path -LiteralPath $state.python)) { $py = $state.python }
        $tomlErr = Test-TomlWithPython $py $newText
        if ($tomlErr) { throw "还原后的 config.toml 无法解析，没有写入：$tomlErr。可以改用 -RestoreBackup。" }
        Write-TextFileAtomic $Script:ConfigPath $newText
        foreach ($l in $top) { Write-Info "还原：$l" }
        if ($orig.providerTable) { Write-Info '还原：原来的 [model_providers.magpie]' } else { Write-Info '已删除 [model_providers.magpie]（安装前没有这个表）' }
        Write-Ok '其余设置保持当前状态'
    } else {
        Write-Info '跳过 config.toml'
    }
}

# ------------------------------------------------------------------ 3. key
Write-Step "凭据管理器里的 $($Script:CredTarget)"
if (Test-MagpieCredential) {
    $del = $false
    if ($DeleteKey) { $del = $true }
    elseif (-not $KeepKey) { $del = Confirm-Choice "删除凭据管理器里的 '$($Script:CredTarget)'？" $false }
    if ($del) { [void](Remove-MagpieCredential); Write-Ok '已删除' } else { Write-Info '保留' }
} else {
    Write-Info '不存在，跳过'
}
if ([Environment]::GetEnvironmentVariable('MAGPIE_API_KEY', 'User')) { Write-Info '用户环境变量 MAGPIE_API_KEY 没有被动过' }

# ------------------------------------------------------------------ 4. 文件
Write-Step "删除 $($Script:InstallDir)"
if ($KeepFiles) {
    Write-Info '按要求保留'
} elseif (Test-Path -LiteralPath $Script:InstallDir) {
    try { Remove-Item -LiteralPath $Script:InstallDir -Recurse -Force; Write-Ok '已删除（config.toml 的备份在 .codex 目录里，没有删）' }
    catch { Write-Warn "删除失败：$($_.Exception.Message)。可以稍后手动删除这个文件夹。" }
} else {
    Write-Info '不存在，跳过'
}

Write-Host ''
Write-Host '卸载完成。完全退出 Codex Desktop（包括系统托盘）再重新打开，改动才会生效。' -ForegroundColor Green
