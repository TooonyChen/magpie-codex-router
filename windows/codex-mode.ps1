<#
.SYNOPSIS
  在两种登录模式之间切换 Codex Desktop。

.DESCRIPTION
  chatgpt  正常的 ChatGPT 登录。请求仍然经 relay 走网关，但 ChatGPT 账号额度用完后，
           Desktop 会直接拦截发送。
  magpie   换成占位 API key 登录，Desktop 不再按 ChatGPT 额度拦截。
           这期间 ChatGPT 账号相关功能不可用。
  relay 会把 Codex 发来的任何 key 换成凭据管理器里的网关 key，所以占位 key 不会被当成真 key 用。

  切换前会先保存当前的 ChatGPT 登录（auth.chatgpt.json），不会调用 codex logout，令牌不会被注销。

.EXAMPLE
  codex-mode            # 查看当前模式
.EXAMPLE
  codex-mode magpie     # OpenAI 额度用完时
.EXAMPLE
  codex-mode chatgpt    # 额度恢复后
.EXAMPLE
  codex-mode refresh    # magpie 模式下更新网关模型列表
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][ValidateSet('status', 'magpie', 'chatgpt', 'refresh')][string]$Mode = 'status',
    [switch]$Force,
    [switch]$NoRestart
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'magpie-relay-common.ps1')
trap {
    Write-Host ''
    Write-Host "codex-mode 失败：$($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

$PlaceholderKey = 'sk-placeholder-replaced-by-magpie-relay'

function Get-RelayPort {
    $cfg = Join-Path $Script:InstallDir 'relay.json'
    try { return [int](Get-Content -LiteralPath $cfg -Raw -Encoding UTF8 | ConvertFrom-Json).listen_port } catch { return 18765 }
}
$base = "http://127.0.0.1:$(Get-RelayPort)"

function Get-StatePython {
    $s = Read-InstallState
    if ($s -and $s.python -and (Test-Path -LiteralPath $s.python)) { return $s.python }
    return $null
}

# ---------------------------------------------------------------- config.toml

function Set-CatalogLine([bool]$Enabled) {
    $text = ''
    if (Test-Path -LiteralPath $Script:ConfigPath) { $text = [IO.File]::ReadAllText($Script:ConfigPath) }
    $parts = Split-CodexConfig $text
    $hasLine = [bool]$parts.Managed['model_catalog_json']
    if ($hasLine -eq $Enabled -and
        (-not $Enabled -or (Get-TomlStringValue $parts.Managed['model_catalog_json']) -eq $Script:CatalogPath)) { return }
    $top = @()
    foreach ($k in $Script:ManagedKeys) {
        if ($k -eq 'model_catalog_json') {
            if ($Enabled) { $top += "model_catalog_json = $(ConvertTo-TomlString $Script:CatalogPath)" }
        } elseif ($parts.Managed[$k]) {
            $top += $parts.Managed[$k]
        }
    }
    $newText = Join-CodexConfig $parts $top $parts.ProviderTable
    $err = Test-TomlWithPython (Get-StatePython) $newText
    if ($err) { throw "修改后的 config.toml 无法解析，没有写入：$err" }
    Copy-Item -LiteralPath $Script:ConfigPath -Destination "$($Script:ConfigPath).bak-codex-mode" -Force
    Write-TextFileAtomic $Script:ConfigPath $newText
}

# ---------------------------------------------------------------- model catalog

function Update-Catalog {
    $ver = Get-CodexVersion (Find-CodexExe)
    if (-not $ver) { $ver = '0.167.0' }
    try { $r = Invoke-Local "$base/v1/models?client_version=$ver" -TimeoutSec 60 }
    catch { throw "无法从 relay 获取模型列表（$($_.Exception.Message)）。relay 在运行吗？看 $(Join-Path $Script:InstallDir 'relay.log')" }
    $n = 0
    try { $n = @(($r.Content | ConvertFrom-Json).models).Count } catch { }
    if ($n -eq 0) { throw 'relay 返回的模型列表无效。' }
    Write-TextFileAtomic $Script:CatalogPath $r.Content
    Write-Ok "模型列表已更新：$n 个模型（Codex $ver 格式）"
}

# ---------------------------------------------------------------- Desktop

function Stop-CodexDesktop {
    $procs = Get-CodexDesktopProcesses
    if ($procs.Count -eq 0) { return $null }
    Write-Warn 'Codex Desktop 正在运行，需要先退出（进行中的任务会中断）。'
    Write-Warn '如果你是在 Codex Desktop 的终端里运行 codex-mode，请改用独立的 PowerShell 窗口。'
    if (-not $Force -and -not (Confirm-Choice '继续？' $false)) { throw '已取消，什么都没改。' }
    $main = $procs | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
    $relaunch = if ($main -and $main.Path) { $main.Path } else { ($procs | Where-Object { $_.Path } | Select-Object -First 1).Path }
    foreach ($p in $procs) { if ($p.MainWindowHandle -ne 0) { [void]$p.CloseMainWindow() } }
    for ($i = 0; $i -lt 30 -and (Get-CodexDesktopProcesses).Count -gt 0; $i++) { Start-Sleep -Milliseconds 500 }
    if ((Get-CodexDesktopProcesses).Count -gt 0) {
        Write-Warn 'Desktop 没有自己退出（可能缩到了系统托盘）。'
        if (-not $Force -and -not (Confirm-Choice '强制结束 Codex Desktop 的进程？' $true)) {
            throw '已取消，什么都没改。请从系统托盘完全退出 Codex 后再运行。'
        }
        Get-CodexDesktopProcesses | Stop-Process -Force -ErrorAction SilentlyContinue
        for ($i = 0; $i -lt 20 -and (Get-CodexDesktopProcesses).Count -gt 0; $i++) { Start-Sleep -Milliseconds 500 }
        if ((Get-CodexDesktopProcesses).Count -gt 0) { throw 'Codex Desktop 仍在运行，什么都没改。' }
    }
    Write-Ok '已退出 Codex Desktop'
    if ($relaunch) { return $relaunch } else { return '' }
}

function Start-CodexDesktop([string]$Path) {
    if ($NoRestart) { Write-Info '按要求不重新打开 Desktop。'; return }
    if ($Path) {
        try { Start-Process -FilePath $Path; Write-Ok '已重新打开 Codex Desktop'; return } catch { }
    }
    try {
        $app = Get-StartApps -ErrorAction Stop | Where-Object { $_.Name -eq 'Codex' } | Select-Object -First 1
        if ($app) { Start-Process "shell:AppsFolder\$($app.AppID)"; Write-Ok '已重新打开 Codex Desktop'; return }
    } catch { }
    Write-Warn '没能自动打开 Codex Desktop，请手动打开。'
}

# ---------------------------------------------------------------- commands

function Show-Status {
    $mode = Get-CodexAuthMode
    switch ($mode) {
        'chatgpt' { Write-Host '当前模式：chatgpt（ChatGPT 登录，OpenAI 额度用完时 Desktop 会拦截发送）' }
        'apikey'  { Write-Host '当前模式：magpie（占位 API key，不受 OpenAI 额度拦截，ChatGPT 功能不可用）' }
        default   { Write-Host "当前模式：未知（auth_mode=$mode）" }
    }
    $text = ''
    if (Test-Path -LiteralPath $Script:ConfigPath) { $text = [IO.File]::ReadAllText($Script:ConfigPath) }
    if ((Split-CodexConfig $text).Managed['model_catalog_json']) { Write-Host '本地模型列表：已启用' } else { Write-Host '本地模型列表：未启用' }
    if (Test-Path -LiteralPath $Script:SavedAuthPath) {
        Write-Host "已保存的 ChatGPT 登录：有（$((Get-Item -LiteralPath $Script:SavedAuthPath).LastWriteTime)）"
    } else { Write-Host '已保存的 ChatGPT 登录：无' }
    try { $null = Invoke-Local "$base/__relay/health" -TimeoutSec 5; Write-Host 'relay：运行中' } catch { Write-Host 'relay：未响应' }
}

function Switch-ToMagpie {
    $mode = Get-CodexAuthMode
    if ($mode -eq 'apikey') { Write-Info '已经是 magpie 模式。'; Update-Catalog; Set-CatalogLine $true; return }
    if ($mode -ne 'chatgpt') { throw "当前 auth.json 不是 ChatGPT 登录（$mode），为安全起见不切换。" }
    Update-Catalog
    $relaunch = Stop-CodexDesktop
    # Desktop may refresh tokens while quitting; save the latest copy.
    $mode = Get-CodexAuthMode
    if ($mode -ne 'chatgpt') { throw "退出 Desktop 后 auth.json 变成了 $mode，已停止。" }
    Copy-Item -LiteralPath $Script:AuthPath -Destination $Script:SavedAuthPath -Force
    $json = [ordered]@{ auth_mode = 'apikey'; OPENAI_API_KEY = $PlaceholderKey; tokens = $null; last_refresh = $null } | ConvertTo-Json
    Write-TextFileAtomic $Script:AuthPath $json
    Set-CatalogLine $true
    Write-Ok "已切换到 magpie 模式。ChatGPT 登录已保存到 $($Script:SavedAuthPath)"
    if ($null -ne $relaunch) { Start-CodexDesktop $relaunch }
}

function Switch-ToChatGPT {
    $mode = Get-CodexAuthMode
    if ($mode -eq 'chatgpt') { Write-Info '已经是 chatgpt 模式。'; Set-CatalogLine $false; return }
    if (-not (Test-Path -LiteralPath $Script:SavedAuthPath)) { throw "找不到已保存的 ChatGPT 登录（$($Script:SavedAuthPath)）。可以在 Desktop 里重新登录。" }
    $relaunch = Stop-CodexDesktop
    Copy-Item -LiteralPath $Script:SavedAuthPath -Destination $Script:AuthPath -Force
    Set-CatalogLine $false
    Write-Ok '已切换到 chatgpt 模式。'
    if ($null -ne $relaunch) { Start-CodexDesktop $relaunch }
}

switch ($Mode) {
    'status'  { Show-Status }
    'magpie'  { Switch-ToMagpie }
    'chatgpt' { Switch-ToChatGPT }
    'refresh' {
        if ((Get-CodexAuthMode) -eq 'apikey') { Update-Catalog }
        else { Write-Info 'chatgpt 模式下模型列表由 relay 实时提供，无需刷新。' }
    }
}
