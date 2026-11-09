<#
.SYNOPSIS
  安装 Codex Desktop 的 magpie 本地 relay：Codex 保持 ChatGPT 登录，模型请求和模型列表走 magpie。

.DESCRIPTION
  1. 找 Python 3.9+（没有就提示用 winget 安装，或改用 Codex 自带的 Python）
  2. 把 relay 复制到 %USERPROFILE%\.codex\magpie-relay\，并从本机 Codex 缓存生成模型模板
  3. 把 magpie key 存进 Windows 凭据管理器（不写进任何文件）
  4. 注册登录自启动的计划任务（失败时改用启动文件夹快捷方式）
  5. 启动 relay，并自检：模型列表、一次真实对话
  6. 备份并修改 config.toml（只动 model / model_provider / model_reasoning_effort /
     model_catalog_json / openai_base_url 和 [model_providers.magpie]）
  7. 用 codex app-server 检查：账号仍是 ChatGPT、模型列表来自 magpie
  8. 安装 codex-mode 命令（OpenAI 额度用完时切换登录模式）

.EXAMPLE
  .\install.cmd
.EXAMPLE
  .\install.ps1 -Upstream https://gateway.example.com/v1
.EXAMPLE
  .\install.ps1 -Model codex/gpt-6.1-terra -ReasoningEffort high
.EXAMPLE
  .\install.ps1 -SkipConfig      # 只装好并启动 relay，不切换 Codex 配置
#>
[CmdletBinding()]
param(
    [string]$Model,
    [string]$ReasoningEffort,
    [string]$Upstream,
    [ValidateRange(1024, 65535)][int]$Port = 18765,
    [string]$PythonPath,
    [switch]$ReplaceKey,
    [switch]$SkipConfig,
    [switch]$SkipChatTest,
    [switch]$Force
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'magpie-relay-common.ps1')
trap {
    Write-Host ''
    Write-Host "安装失败：$($_.Exception.Message)" -ForegroundColor Red
    if (Test-Path -LiteralPath (Join-Path $Script:InstallDir 'uninstall.cmd')) {
        Write-Host "已经装上的部分可以用 $(Join-Path $Script:InstallDir 'uninstall.cmd') 清理。" -ForegroundColor Red
    }
    break
}

function Test-PythonExe([string]$Exe) {
    $ErrorActionPreference = 'Continue'
    if (-not $Exe -or -not (Test-Path -LiteralPath $Exe)) { return $null }
    $out = @(& $Exe -I -c "import sys; print(sys.executable); print('%d.%d' % sys.version_info[:2])" 2>$null)
    if ($LASTEXITCODE -ne 0 -or $out.Count -lt 2) { return $null }
    $exePath = "$($out[0])".Trim()
    $ver = [version]"$($out[1])".Trim()
    if ($ver -lt [version]'3.9') { return $null }
    $w = Join-Path (Split-Path $exePath) 'pythonw.exe'
    if (-not (Test-Path -LiteralPath $w)) {
        $w = Join-Path (Split-Path $Exe) 'pythonw.exe'
        if (-not (Test-Path -LiteralPath $w)) { return $null }
    }
    [pscustomobject]@{ Python = $exePath; Pythonw = $w; Version = $ver }
}

function Find-Python {
    $ErrorActionPreference = 'Continue'
    $cands = New-Object System.Collections.Generic.List[string]
    $py = Get-Command py.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($py) {
        $exe = & $py.Source -3 -c "import sys; print(sys.executable)" 2>$null | Select-Object -First 1
        if ($LASTEXITCODE -eq 0 -and $exe) { $cands.Add("$exe".Trim()) }
    }
    foreach ($c in @(Get-Command python.exe -All -ErrorAction SilentlyContinue)) { $cands.Add($c.Source) }
    foreach ($pattern in @((Join-Path $env:LOCALAPPDATA 'Programs\Python\Python3*\python.exe'),
                           (Join-Path $env:ProgramFiles 'Python3*\python.exe'))) {
        foreach ($f in @(Get-ChildItem -Path $pattern -ErrorAction SilentlyContinue)) { $cands.Add($f.FullName) }
    }
    $best = $null
    foreach ($c in ($cands | Select-Object -Unique)) {
        $r = Test-PythonExe $c
        if ($r -and (-not $best -or $r.Version -gt $best.Version)) { $best = $r }
    }
    $best
}

$relayFiles = @('relay.py', 'magpie-relay-common.ps1', 'uninstall.ps1', 'uninstall.cmd', 'codex-mode.ps1', 'codex-mode.cmd')
$templatesPath = Join-Path $Script:InstallDir 'templates.json'
$relayPy = Join-Path $Script:InstallDir 'relay.py'
$relayLog = Join-Path $Script:InstallDir 'relay.log'
$base = "http://127.0.0.1:$Port"

# ------------------------------------------------------------------ 0. 预检
Write-Step '预检'
foreach ($f in $relayFiles) {
    if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot $f))) { throw "安装包里缺少 $f，请把整个文件夹一起复制" }
}
if (-not (Test-Path -LiteralPath $Script:CodexHome)) { throw "找不到 $($Script:CodexHome)，请先安装 Codex Desktop 并用 ChatGPT 登录" }
$authPath = Join-Path $Script:CodexHome 'auth.json'
$loggedIn = $false
if (Test-Path -LiteralPath $authPath) {
    try {
        $auth = Get-Content -LiteralPath $authPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $loggedIn = ($auth.auth_mode -eq 'chatgpt') -and [bool]$auth.tokens
    } catch { $loggedIn = $false }
    $auth = $null
}
if ($loggedIn) { Write-Ok 'auth.json 里有 ChatGPT 登录（不会读取或复制 token 内容）' }
elseif ((Get-CodexAuthMode) -eq 'apikey' -and (Test-Path -LiteralPath $Script:SavedAuthPath)) {
    Write-Ok '当前是 codex-mode 的 magpie 模式，ChatGPT 登录已保存（codex-mode chatgpt 可切回）'
}
else {
    Write-Warn '没有在 auth.json 里找到 ChatGPT 登录。这个方案依赖 ChatGPT 登录态，切换后 Codex 会要求重新登录。'
    if (-not $SkipConfig -and -not $Force -and -not (Confirm-Choice '仍然继续？' $false)) { throw '已取消' }
}
if (-not $SkipConfig) {
    $codexProcs = @(Get-Process -Name 'Codex' -ErrorAction SilentlyContinue)
    if ($codexProcs.Count -gt 0) {
        Write-Warn 'Codex Desktop 正在运行。它运行时可能改写 config.toml，而且切换要在完全退出再重开后才生效。'
        Write-Warn '建议先完全退出 Codex（包括系统托盘），再从普通 PowerShell 窗口运行本脚本。'
        if (-not $Force -and -not (Confirm-Choice '仍然继续？' $false)) { throw '已取消' }
    }
}
$oldState = Read-InstallState

# 网关地址：参数 > 已有 relay.json > 询问
if (-not $Upstream) {
    $oldRelayCfg = Join-Path $Script:InstallDir 'relay.json'
    if (Test-Path -LiteralPath $oldRelayCfg) {
        try { $Upstream = (Get-Content -LiteralPath $oldRelayCfg -Raw -Encoding UTF8 | ConvertFrom-Json).upstream } catch { }
        if ($Upstream) { Write-Ok "沿用已有网关地址：$Upstream" }
    }
}
if (-not $Upstream) { $Upstream = Read-Host '    网关 base URL（例如 https://gateway.example.com/v1）' }
$Upstream = "$Upstream".Trim().TrimEnd('/')
if ($Upstream -notmatch '^https?://[^/]+') { throw "网关地址无效：$Upstream" }
if ($Upstream -notmatch '^https://') { Write-Warn '网关不是 https，key 会以明文传输。' }

# ------------------------------------------------------------------ 1. Python
Write-Step '查找 Python'
if ($PythonPath) {
    $py = Test-PythonExe $PythonPath
    if (-not $py) { throw "-PythonPath 指定的不是可用的 Python 3.9+（还需要同目录下的 pythonw.exe）：$PythonPath" }
} else {
    $py = Find-Python
}
if (-not $py) {
    Write-Warn '没有找到可用的 Python 3.9+（WindowsApps 里的 python.exe 只是商店占位符）。'
    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($winget -and (Confirm-Choice '用 winget 为当前用户安装 Python 3.12？' $true)) {
        & $winget.Source install -e --id Python.Python.3.12 --scope user --silent --accept-package-agreements --accept-source-agreements
        $py = Find-Python
    }
    $codexPy = Join-Path $env:USERPROFILE '.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe'
    if (-not $py -and (Test-Path -LiteralPath $codexPy)) {
        Write-Warn "可以改用 Codex 自带的 Python：$codexPy"
        Write-Warn 'Codex 更新时这个运行时可能被替换，到时需要重新运行 install。'
        if (Confirm-Choice '使用 Codex 自带的 Python？' $false) { $py = Test-PythonExe $codexPy }
    }
    if (-not $py) { throw '需要 Python 3.9+。可以先运行 winget install Python.Python.3.12，或用 -PythonPath 指定 python.exe。' }
}
Write-Ok "Python $($py.Version): $($py.Python)"

# ------------------------------------------------------------------ 2. 复制文件
Write-Step "复制 relay 到 $($Script:InstallDir)"
New-Item -ItemType Directory -Force -Path $Script:InstallDir | Out-Null
$srcDir = (Resolve-Path -LiteralPath $PSScriptRoot).Path.TrimEnd('\')
if ($srcDir -ne (Resolve-Path -LiteralPath $Script:InstallDir).Path.TrimEnd('\')) {
    foreach ($f in $relayFiles) { Copy-Item -LiteralPath (Join-Path $srcDir $f) -Destination $Script:InstallDir -Force }
}
$relayCfg = [ordered]@{ listen_host = '127.0.0.1'; listen_port = $Port; upstream = $Upstream.TrimEnd('/')
                        credential_target = $Script:CredTarget; env_fallback = 'MAGPIE_API_KEY' }
Write-TextFileAtomic (Join-Path $Script:InstallDir 'relay.json') ($relayCfg | ConvertTo-Json)
Write-Ok 'relay.py、relay.json、codex-mode、卸载脚本已就位'

# 模型模板：安装包里带了就用；已装过就沿用；否则从本机 Codex 缓存提取官方模型条目。
# Codex 会用 relay 提供的列表覆盖 models_cache.json，所以只能在接入 relay 之前提取。
$pkgTemplates = Join-Path $srcDir 'templates.json'
if ((Test-Path -LiteralPath $pkgTemplates) -and ($srcDir -ne (Split-Path $templatesPath))) {
    Copy-Item -LiteralPath $pkgTemplates -Destination $templatesPath -Force
    Write-Ok '使用安装包里的 templates.json'
} elseif (Test-Path -LiteralPath $templatesPath) {
    Write-Ok '沿用已有的 templates.json'
} else {
    $cache = Join-Path $Script:CodexHome 'models_cache.json'
    $code = @'
import json, os, sys
src, dst = sys.argv[1:]
try:
    d = json.load(open(src, encoding="utf-8"))
except Exception as e:
    sys.exit("cannot read %s: %s" % (src, e))
models = [m for m in d.get("models", []) if "/" not in m.get("slug", "/")]
if not models:
    sys.exit("no official models in cache")
with open(dst + ".tmp", "w", encoding="utf-8") as f:
    json.dump({"source_client_version": d.get("client_version"), "models": models}, f)
os.replace(dst + ".tmp", dst)
print("%d templates from Codex %s" % (len(models), d.get("client_version")))
'@
    $ErrorActionPreference = 'Continue'
    $out = & $py.Python -I -c $code $cache $templatesPath 2>&1
    $rc = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    if ($rc -ne 0) {
        throw ("无法从 $cache 生成模型模板（$(($out | Out-String).Trim())）。" +
               '请暂时删掉 config.toml 里的 model_provider，打开一次 Codex Desktop 让它下载官方模型列表，再重新运行 install。')
    }
    Write-Ok "已生成 templates.json：$(($out | Out-String).Trim())"
}

# ------------------------------------------------------------------ 3. magpie key
Write-Step "magpie key（Windows 凭据管理器，目标名 $($Script:CredTarget)）"
$credCreated = $false
if ((Test-MagpieCredential) -and -not $ReplaceKey) {
    Write-Ok '凭据已存在，直接复用（要换 key 请加 -ReplaceKey）'
} else {
    $envKey = [Environment]::GetEnvironmentVariable('MAGPIE_API_KEY', 'User')
    $stored = $false
    if ($envKey -and -not $ReplaceKey) {
        if (Confirm-Choice '检测到用户环境变量 MAGPIE_API_KEY，把它导入凭据管理器？' $true) {
            $sec = ConvertTo-SecureString -String $envKey.Trim() -AsPlainText -Force
            Set-MagpieCredential $sec
            $stored = $true
        }
    }
    $envKey = $null
    if (-not $stored) {
        $sec = Read-Host '    请输入 magpie API key（输入不会显示）' -AsSecureString
        if ($sec.Length -eq 0) { throw '没有输入 key' }
        Set-MagpieCredential $sec
    }
    $credCreated = $true
    Write-Ok '已保存到凭据管理器'
}

# ------------------------------------------------------------------ 4. 自启动
Write-Step '配置登录自启动'
$userId = "$env:USERDOMAIN\$env:USERNAME"
$taskArg = '-I "' + $relayPy + '"'
$autostart = $null
try {
    $action = New-ScheduledTaskAction -Execute $py.Pythonw -Argument $taskArg -WorkingDirectory $Script:InstallDir
    $atLogon = New-ScheduledTaskTrigger -AtLogOn -User $userId
    # 看门狗：每 5 分钟触发一次；relay 还在运行时 IgnoreNew 会忽略，挂掉了就重新拉起
    $watchdog = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(5) -RepetitionInterval (New-TimeSpan -Minutes 5)
    $settingsArgs = @{
        AllowStartIfOnBatteries = $true; DontStopIfGoingOnBatteries = $true; StartWhenAvailable = $true
        ExecutionTimeLimit = [TimeSpan]::Zero; MultipleInstances = 'IgnoreNew'
        RestartCount = 3; RestartInterval = (New-TimeSpan -Minutes 1)
    }
    $settings = New-ScheduledTaskSettingsSet @settingsArgs
    $principal = New-ScheduledTaskPrincipal -UserId $userId -LogonType Interactive -RunLevel Limited
    $taskArgs = @{
        TaskName = $Script:TaskName; Action = $action; Trigger = @($atLogon, $watchdog); Settings = $settings
        Principal = $principal; Force = $true
        Description = 'Local relay: Codex (ChatGPT login) -> magpie gateway. 127.0.0.1 only.'
    }
    Register-ScheduledTask @taskArgs | Out-Null
    if (Test-Path -LiteralPath $Script:ShortcutPath) { Remove-Item -LiteralPath $Script:ShortcutPath -Force }
    $autostart = 'task'
    Write-Ok "计划任务 '$($Script:TaskName)'：登录时启动，每 5 分钟检查一次"
} catch {
    Write-Warn "无法注册计划任务（$($_.Exception.Message)），改用启动文件夹快捷方式"
    $shell = New-Object -ComObject WScript.Shell
    $lnk = $shell.CreateShortcut($Script:ShortcutPath)
    $lnk.TargetPath = $py.Pythonw
    $lnk.Arguments = $taskArg
    $lnk.WorkingDirectory = $Script:InstallDir
    $lnk.WindowStyle = 7
    $lnk.Description = 'Codex magpie relay'
    $lnk.Save()
    $autostart = 'startup'
    Write-Ok "启动文件夹快捷方式：$($Script:ShortcutPath)（relay 意外退出后不会自动重启）"
}

function New-State([string]$Backup, $Original, [bool]$Switched) {
    $first = $null
    if ($oldState -and $oldState.PSObject.Properties['firstConfigBackup']) { $first = $oldState.firstConfigBackup }
    if (-not $first) { $first = $Backup }
    [ordered]@{
        version                    = 1
        installedAt                = (Get-Date).ToString('o')
        codexHome                  = $Script:CodexHome
        installDir                 = $Script:InstallDir
        port                       = $Port
        upstream                   = $Upstream
        python                     = $py.Python
        pythonw                    = $py.Pythonw
        autostart                  = $autostart
        credentialTarget           = $Script:CredTarget
        credentialCreatedByInstall = ($credCreated -or ($oldState -and [bool]$oldState.credentialCreatedByInstall))
        configSwitched             = $Switched
        firstConfigBackup          = $first
        lastConfigBackup           = $Backup
        originalConfig             = $Original
    }
}
$origConfig = $null
if ($oldState -and $oldState.PSObject.Properties['originalConfig'] -and $oldState.originalConfig) { $origConfig = $oldState.originalConfig }
$wasSwitched = [bool]($oldState -and $oldState.configSwitched)
$lastBackup = $null
if ($oldState -and $oldState.PSObject.Properties['lastConfigBackup']) { $lastBackup = $oldState.lastConfigBackup }
Save-InstallState (New-State $lastBackup $origConfig $wasSwitched)

# ------------------------------------------------------------------ 5. 启动 relay
Write-Step '启动 relay'
Stop-Relay
$busy = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
if ($busy) {
    $owner = Get-Process -Id $busy.OwningProcess -ErrorAction SilentlyContinue
    throw "端口 $Port 已被 $($owner.ProcessName)（PID $($busy.OwningProcess)）占用，请用 -Port 换一个端口"
}
if ($autostart -eq 'task') { Start-ScheduledTask -TaskName $Script:TaskName }
else { Start-Process -FilePath $py.Pythonw -ArgumentList $taskArg -WorkingDirectory $Script:InstallDir -WindowStyle Hidden }
$health = $null
for ($i = 0; $i -lt 40 -and -not $health; $i++) {
    Start-Sleep -Milliseconds 500
    try { $health = (Invoke-Local "$base/__relay/health" -TimeoutSec 3).Content | ConvertFrom-Json } catch { }
}
if (-not $health) {
    if (Test-Path -LiteralPath $relayLog) { Get-Content -LiteralPath $relayLog -Tail 15 | ForEach-Object { Write-Info $_ } }
    throw "relay 没有在 $base 启动，日志见 $relayLog"
}
if (-not $health.key) { throw 'relay 已启动但读不到 magpie key。请用 -ReplaceKey 重新运行。' }
Write-Ok "relay PID $($health.pid) 正在监听 $base（key 来源 $($health.key_source)）"

# ------------------------------------------------------------------ 6. relay 自检
Write-Step 'relay 自检'
$codex = Find-CodexExe
$codexVer = Get-CodexVersion $codex
if ($codex) { Write-Info "Codex: $codex（$codexVer）" } else { Write-Warn '没找到 codex.exe，跳过 app-server 检查' }
$clientVer = if ($codexVer) { $codexVer } else { '0.167.0' }
try {
    $cat = (Invoke-Local "$base/v1/models?client_version=$clientVer" -TimeoutSec 60).Content | ConvertFrom-Json
} catch {
    throw "从 magpie 获取模型列表失败：$($_.Exception.Message)。如果是 401，说明 key 不对，请用 -ReplaceKey 重新运行。"
}
$slugs = @($cat.models | ForEach-Object { $_.slug })
if ($slugs.Count -eq 0) { throw 'magpie 返回的模型列表是空的' }
Write-Ok "模型列表转换成功：$($slugs.Count) 个模型"
Write-Info ($slugs -join ', ')

$currentText = ''
if (Test-Path -LiteralPath $Script:ConfigPath) { $currentText = [IO.File]::ReadAllText($Script:ConfigPath) }
$parts = Split-CodexConfig $currentText
$currentModel = Get-TomlStringValue $parts.Managed['model']
$currentEffort = Get-TomlStringValue $parts.Managed['model_reasoning_effort']

if ($Model) {
    $chosen = $Model
    if ($slugs -notcontains $Model) { Write-Warn "magpie 列表里没有 $Model，仍按你的指定写入" }
} else {
    $chosen = @($currentModel, 'auto/gpt-6.1-terra', 'codex/gpt-6.1-terra') |
        Where-Object { $_ -and ($slugs -contains $_) } | Select-Object -First 1
    if (-not $chosen) { $chosen = $slugs[0] }
}
$entry = $cat.models | Where-Object { $_.slug -eq $chosen } | Select-Object -First 1
$efforts = @()
if ($entry) { $efforts = @($entry.supported_reasoning_levels | ForEach-Object { $_.effort }) }
if ($ReasoningEffort) {
    $effort = $ReasoningEffort
    if ($efforts.Count -and ($efforts -notcontains $effort)) { Write-Warn "$chosen 不支持推理强度 $effort（支持：$($efforts -join ', ')），仍按你的指定写入" }
} else {
    $effort = @($currentEffort, 'high') | Where-Object { $_ -and ($efforts.Count -eq 0 -or ($efforts -contains $_)) } | Select-Object -First 1
    if (-not $effort -and $entry) { $effort = $entry.default_reasoning_level }
    if (-not $effort) { $effort = 'medium' }
}
Write-Info "默认模型：$chosen，推理强度：$effort"

if ($SkipChatTest) {
    Write-Warn '按要求跳过对话测试'
} else {
    $req = @{ model = $chosen; input = 'Reply with exactly OK.'; stream = $true } | ConvertTo-Json -Compress
    try { $r = Invoke-Local "$base/v1/responses" -Method POST -Body $req -TimeoutSec 180 }
    catch { throw "通过 relay 发送测试对话失败：$($_.Exception.Message)。config.toml 尚未修改；可以换 -Model 再试，或加 -SkipChatTest。" }
    if ($r.Content -notmatch 'response\.completed') {
        throw "测试对话没有收到 response.completed，config.toml 尚未修改。返回内容开头：$($r.Content.Substring(0, [Math]::Min(300, $r.Content.Length)))"
    }
    Write-Ok "测试对话成功（$chosen，流式 SSE 收到 response.completed）"
}

# ------------------------------------------------------------------ 7. config.toml
$backup = $lastBackup
if ($SkipConfig) {
    Write-Step '按要求跳过 config.toml 修改'
    Write-Info '以后要切换，去掉 -SkipConfig 再运行一次 install 即可。'
} else {
    Write-Step "修改 $($Script:ConfigPath)"
    if (Test-Path -LiteralPath $Script:ConfigPath) {
        $backup = "$($Script:ConfigPath).before-magpie-relay-$(Get-Date -Format 'yyyyMMddTHHmmss').bak"
        Copy-Item -LiteralPath $Script:ConfigPath -Destination $backup
        Write-Ok "已备份到 $backup"
    }
    if (-not $origConfig) {
        # 第一次切换时记下原值，卸载时据此还原（重复安装不会覆盖它）
        $origConfig = [ordered]@{ managed = $parts.Managed; providerTable = $parts.ProviderTable }
    }
    $top = @(
        "model = $(ConvertTo-TomlString $chosen)",
        "model_provider = $(ConvertTo-TomlString $Script:ProviderId)",
        "model_reasoning_effort = $(ConvertTo-TomlString $effort)"
    )
    $table = @(
        "[model_providers.$($Script:ProviderId)]",
        'name = "magpie"',
        "base_url = $(ConvertTo-TomlString "$base/v1")",
        'wire_api = "responses"',
        'requires_openai_auth = true',
        'supports_websockets = false'
    ) -join "`n"
    $newText = Join-CodexConfig $parts $top $table
    $tomlErr = Test-TomlWithPython $py.Python $newText
    if ($tomlErr) { throw "生成的 config.toml 无法解析，没有写入：$tomlErr" }
    Write-TextFileAtomic $Script:ConfigPath $newText
    foreach ($k in @('model_catalog_json', 'openai_base_url')) {
        if ($parts.Managed[$k]) { Write-Info "已移除：$($parts.Managed[$k])" }
    }
    if ($parts.ProviderTable) { Write-Info '已替换原来的 [model_providers.magpie]（env_key 等自带认证会让 Desktop 每次启动都进 onboarding）' }
    Write-Ok "model_provider = magpie -> $base/v1（requires_openai_auth = true），其余设置保持不变"
    $wasSwitched = $true
}
Save-InstallState (New-State $backup $origConfig $wasSwitched)

# ------------------------------------------------------------------ 8. Codex 检查
if (-not $SkipConfig -and $codex) {
    Write-Step '用 codex app-server 检查登录状态和模型列表'
    try {
        $chk = Invoke-CodexAppServerCheck $codex
        if ($chk.AccountType -eq 'chatgpt') { Write-Ok "account/read：ChatGPT 账号（requiresOpenaiAuth = $($chk.RequiresOpenaiAuth)）" }
        else { Write-Warn "account/read 返回的账号类型是 '$($chk.AccountType)'，Desktop 可能会要求登录" }
        $hits = @($chk.Models | Where-Object { $slugs -contains $_ })
        if ($hits.Count -gt 0) { Write-Ok "model/list：$($hits.Count) 个 magpie 模型" }
        else { Write-Warn "model/list 没有返回 magpie 模型（返回了：$($chk.Models -join ', ')）" }
    } catch {
        Write-Warn "codex app-server 检查失败：$($_.Exception.Message)"
    }
}

# ------------------------------------------------------------------ 9. codex-mode 命令
Write-Step '安装 codex-mode 命令'
try {
    Install-CodexModeShim
    Write-Ok "已创建 $($Script:ShimPath)，在新开的终端里直接运行 codex-mode"
} catch {
    Write-Warn "没能创建 codex-mode 快捷命令（$($_.Exception.Message)），可以直接运行 $(Join-Path $Script:InstallDir 'codex-mode.cmd')"
}

# ------------------------------------------------------------------ 完成
Write-Host ''
Write-Host '安装完成。' -ForegroundColor Green
Write-Info "relay：     $base/v1（只监听本机）"
Write-Info "日志：      $relayLog"
Write-Info ('自启动：    ' + $(if ($autostart -eq 'task') { "计划任务 '$($Script:TaskName)'" } else { $Script:ShortcutPath }))
if (-not $SkipConfig) {
    Write-Info "默认模型：  $chosen（$effort）"
    Write-Info "配置备份：  $backup"
    Write-Host ''
    Write-Info '下一步：完全退出 Codex Desktop（包括系统托盘），再重新打开。确认：'
    Write-Info '  1. 没有出现 onboarding，仍是 ChatGPT 登录'
    Write-Info '  2. 模型选择器里是 magpie 的模型'
    Write-Info '  3. 发一条消息能收到回复'
    Write-Info '  Desktop 首次启动后可能改写 model / model_reasoning_effort，必要时在设置里再选一次。'
}
Write-Info 'OpenAI 额度用完、Desktop 拦截发送时：codex-mode magpie；额度恢复后：codex-mode chatgpt'
Write-Info "卸载：运行 $(Join-Path $Script:InstallDir 'uninstall.cmd')"
