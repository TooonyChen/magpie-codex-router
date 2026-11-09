# Shared helpers for install.ps1 / uninstall.ps1 (dot-sourced). Windows PowerShell 5.1+ and PowerShell 7.

$Script:CodexHome   = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }
$Script:InstallDir  = Join-Path $Script:CodexHome 'magpie-relay'
$Script:StatePath   = Join-Path $Script:InstallDir 'install-state.json'
$Script:ConfigPath  = Join-Path $Script:CodexHome 'config.toml'
# MAGPIE_RELAY_TASK_NAME / MAGPIE_RELAY_CRED_TARGET exist only so the scripts can be tested in isolation.
$Script:TaskName    = if ($env:MAGPIE_RELAY_TASK_NAME) { $env:MAGPIE_RELAY_TASK_NAME } else { 'Codex magpie relay' }
$Script:StartupDir   = [Environment]::GetFolderPath('Startup')
$Script:ShortcutPath = if ($Script:StartupDir) { Join-Path $Script:StartupDir ($Script:TaskName + '.lnk') } else { $null }
$Script:CredTarget  = if ($env:MAGPIE_RELAY_CRED_TARGET) { $env:MAGPIE_RELAY_CRED_TARGET } else { 'magpie-api-key' }
$Script:ProviderId  = 'magpie'
# codex-mode (switch between ChatGPT login and a placeholder API-key login).
$Script:AuthPath      = Join-Path $Script:CodexHome 'auth.json'
$Script:SavedAuthPath = Join-Path $Script:InstallDir 'auth.chatgpt.json'
$Script:CatalogPath   = Join-Path $Script:InstallDir 'catalog.json'
# %LOCALAPPDATA%\Microsoft\WindowsApps is on the user PATH by default on Windows 10/11.
$Script:ShimPath      = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\codex-mode.cmd'
$Script:ShimMarker    = 'rem magpie-codex-router codex-mode shim'
# Top-level config keys this tool owns. Everything else in config.toml is left alone.
$Script:ManagedKeys = @('model', 'model_provider', 'model_reasoning_effort', 'model_catalog_json', 'openai_base_url')

function Write-Step([string]$m) { Write-Host ''; Write-Host "==> $m" -ForegroundColor Cyan }
function Write-Ok([string]$m)   { Write-Host "    [OK] $m" -ForegroundColor Green }
function Write-Info([string]$m) { Write-Host "    $m" }
function Write-Warn([string]$m) { Write-Host "    [!] $m" -ForegroundColor Yellow }

function Confirm-Choice([string]$Question, [bool]$Default = $false) {
    $hint = if ($Default) { '[Y/n]' } else { '[y/N]' }
    $a = Read-Host "    $Question $hint"
    if ([string]::IsNullOrWhiteSpace($a)) { return $Default }
    return $a.Trim().ToLower().StartsWith('y')
}

# ---------------------------------------------------------------- Credential Manager

if (-not ('MagpieRelay.NativeCred' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace MagpieRelay {
  public static class NativeCred {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct CREDENTIAL {
      public uint Flags; public uint Type; public string TargetName; public string Comment;
      public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
      public uint CredentialBlobSize; public IntPtr CredentialBlob; public uint Persist;
      public uint AttributeCount; public IntPtr Attributes; public string TargetAlias; public string UserName;
    }
    [DllImport("advapi32.dll", EntryPoint = "CredWriteW", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool CredWrite(ref CREDENTIAL cred, uint flags);
    [DllImport("advapi32.dll", EntryPoint = "CredReadW", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool CredRead(string target, uint type, uint flags, out IntPtr cred);
    [DllImport("advapi32.dll", EntryPoint = "CredDeleteW", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool CredDelete(string target, uint type, uint flags);
    [DllImport("advapi32.dll")]
    static extern void CredFree(IntPtr cred);

    public static bool Exists(string target) {
      IntPtr p;
      if (!CredRead(target, 1, 0, out p)) return false;
      CredFree(p);
      return true;
    }
    // secret points to UTF-16 characters (SecureStringToGlobalAllocUnicode); stored as UTF-16LE like cmdkey.
    public static void Write(string target, string user, IntPtr secret, int charCount) {
      CREDENTIAL c = new CREDENTIAL();
      c.Type = 1; c.Persist = 2; c.TargetName = target; c.UserName = user;
      c.Comment = "Codex magpie relay";
      c.CredentialBlob = secret; c.CredentialBlobSize = (uint)(charCount * 2);
      if (!CredWrite(ref c, 0)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
    }
    public static bool Delete(string target) {
      if (CredDelete(target, 1, 0)) return true;
      int e = Marshal.GetLastWin32Error();
      if (e == 1168) return false;
      throw new System.ComponentModel.Win32Exception(e);
    }
  }
}
'@
}

function Test-MagpieCredential([string]$Target = $Script:CredTarget) { [MagpieRelay.NativeCred]::Exists($Target) }

function Set-MagpieCredential([Security.SecureString]$Secret, [string]$Target = $Script:CredTarget) {
    if ($Secret.Length -eq 0) { throw 'key 为空' }
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToGlobalAllocUnicode($Secret)
    try { [MagpieRelay.NativeCred]::Write($Target, 'magpie', $ptr, $Secret.Length) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeGlobalAllocUnicode($ptr) }
}

function Remove-MagpieCredential([string]$Target = $Script:CredTarget) { [MagpieRelay.NativeCred]::Delete($Target) }

# ---------------------------------------------------------------- relay process / autostart

function Get-RelayProcesses([string]$Dir = $Script:InstallDir) {
    $relay = Join-Path $Dir 'relay.py'
    @(Get-CimInstance Win32_Process -Filter "Name='pythonw.exe' OR Name='python.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine.IndexOf($relay, [StringComparison]::OrdinalIgnoreCase) -ge 0 })
}

function Stop-Relay([string]$Dir = $Script:InstallDir) {
    $task = Get-ScheduledTask -TaskName $Script:TaskName -ErrorAction SilentlyContinue
    if ($task -and $task.State -eq 'Running') { Stop-ScheduledTask -TaskName $Script:TaskName -ErrorAction SilentlyContinue }
    foreach ($p in (Get-RelayProcesses $Dir)) {
        Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
        Write-Info "已停止 relay 进程 $($p.ProcessId)"
    }
}

function Remove-RelayAutostart {
    if (Get-ScheduledTask -TaskName $Script:TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $Script:TaskName -Confirm:$false
        Write-Ok "已删除计划任务 '$($Script:TaskName)'"
    }
    if (Test-Path -LiteralPath $Script:ShortcutPath) {
        Remove-Item -LiteralPath $Script:ShortcutPath -Force
        Write-Ok '已删除启动文件夹快捷方式'
    }
}

function Invoke-Local {
    param([string]$Uri, [string]$Method = 'GET', [string]$Body, [int]$TimeoutSec = 30)
    $args2 = @{ Uri = $Uri; Method = $Method; UseBasicParsing = $true; TimeoutSec = $TimeoutSec
                Headers = @{ Authorization = 'Bearer relay-selftest' } }
    if ($Body) { $args2.Body = [Text.Encoding]::UTF8.GetBytes($Body); $args2.ContentType = 'application/json' }
    if ($PSVersionTable.PSVersion.Major -ge 7) { $args2.NoProxy = $true }
    else { [Net.WebRequest]::DefaultWebProxy = New-Object Net.WebProxy }
    $r = Invoke-WebRequest @args2
    $c = $r.Content
    if ($c -is [byte[]]) { $c = [Text.Encoding]::UTF8.GetString($c) }
    [pscustomobject]@{ Status = [int]$r.StatusCode; Content = $c }
}

# ---------------------------------------------------------------- config.toml editing

function Get-TomlHeaderName([string]$Line) {
    # Only unindented headers, so array continuation lines can't be mistaken for tables.
    if ($Line -match '^\[\[?\s*([^\[\]]+?)\s*\]\]?\s*(#.*)?$') {
        return (($Matches[1] -replace '\s*\.\s*', '.') -replace '["'']', '')
    }
    return $null
}

function Split-CodexConfig([string]$Text) {
    $nl = if ($Text -match "\r\n") { "`r`n" } else { "`n" }
    $lines = [regex]::Split($Text, '\r?\n')
    if ($lines.Count -gt 0 -and $lines[$lines.Count - 1] -eq '') { $lines = $lines[0..($lines.Count - 2)] }
    if ($Text -eq '') { $lines = @() }
    $keys = @{}
    $body = New-Object System.Collections.Generic.List[string]
    $provider = New-Object System.Collections.Generic.List[string]
    $inProvider = $false; $seenHeader = $false
    $pid0 = "model_providers.$($Script:ProviderId)"
    foreach ($line in $lines) {
        $h = Get-TomlHeaderName $line
        if ($null -ne $h) {
            $seenHeader = $true
            $inProvider = ($h -eq $pid0 -or $h.StartsWith("$pid0."))
        }
        if ($inProvider) { $provider.Add($line); continue }
        if (-not $seenHeader) {
            $hit = $null
            foreach ($k in $Script:ManagedKeys) {
                if ($line -match ('^\s*' + [regex]::Escape($k) + '\s*=')) { $hit = $k; break }
            }
            if ($hit) {
                if ($line -match "'''" -or $line -match '"""' -or $line -match '=\s*\[\s*(#.*)?$') {
                    throw "config.toml 里的 $hit 是多行值，脚本不敢自动修改，请手动处理"
                }
                if ($keys.ContainsKey($hit)) { throw "config.toml 里 $hit 出现了两次" }
                $keys[$hit] = $line
                continue
            }
        }
        $body.Add($line)
    }
    while ($provider.Count -gt 0 -and [string]::IsNullOrWhiteSpace($provider[$provider.Count - 1])) { $provider.RemoveAt($provider.Count - 1) }
    $pt = if ($provider.Count -gt 0) { $provider -join "`n" } else { $null }
    [pscustomobject]@{ NewLine = $nl; Managed = $keys; ProviderTable = $pt; Body = $body }
}

function Join-CodexConfig($Parts, [string[]]$TopLines, [string]$ProviderTable) {
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($l in $TopLines) { if ($l) { $out.Add($l) } }
    $body = New-Object System.Collections.Generic.List[string]
    foreach ($l in $Parts.Body) { $body.Add($l) }
    while ($body.Count -gt 0 -and [string]::IsNullOrWhiteSpace($body[$body.Count - 1])) { $body.RemoveAt($body.Count - 1) }
    foreach ($l in $body) { $out.Add($l) }
    if ($ProviderTable) {
        $out.Add('')
        foreach ($l in [regex]::Split($ProviderTable, '\r?\n')) { $out.Add($l) }
    }
    ($out -join $Parts.NewLine) + $Parts.NewLine
}

function Get-TomlStringValue([string]$Line) {
    if ($Line -and $Line -match '=\s*"((?:[^"\\]|\\.)*)"') { return ($Matches[1] -replace '\\(.)', '$1') }
    if ($Line -and $Line -match "=\s*'([^']*)'") { return $Matches[1] }
    return $null
}

function ConvertTo-TomlString([string]$Value) { '"' + ($Value -replace '\\', '\\' -replace '"', '\"') + '"' }

function Write-TextFileAtomic([string]$Path, [string]$Text) {
    $tmp = "$Path.tmp-$PID"
    [IO.File]::WriteAllText($tmp, $Text, (New-Object Text.UTF8Encoding $false))
    for ($i = 0; $i -lt 20; $i++) {
        try { Move-Item -LiteralPath $tmp -Destination $Path -Force; return }
        catch { Start-Sleep -Milliseconds 250 }
    }
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    throw "无法写入 $Path（文件被占用？）"
}

function Test-TomlWithPython([string]$Python, [string]$Text) {
    # Returns $null when the text parses, the error message otherwise. Skipped (returns $null) without tomllib.
    $ErrorActionPreference = 'Continue'
    if (-not $Python) { return $null }
    $tmp = Join-Path $env:TEMP ("magpie-config-check-$PID.toml")
    [IO.File]::WriteAllText($tmp, $Text, (New-Object Text.UTF8Encoding $false))
    try {
        $code = 'import sys' + "`n" +
                'try: import tomllib' + "`n" +
                'except ImportError: sys.exit(0)' + "`n" +
                'tomllib.load(open(sys.argv[1], ''rb''))'
        $out = & $Python -I -c $code $tmp 2>&1
        if ($LASTEXITCODE -ne 0) { return ($out | Out-String).Trim() }
        return $null
    } finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
}

# ---------------------------------------------------------------- Codex binary / app-server check

function Find-CodexExe {
    $bundled = Get-ChildItem -Path (Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\bin\*\codex.exe') -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($bundled) { return $bundled.FullName }
    $cmd = Get-Command codex.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return $cmd.Source }
    return $null
}

function Get-CodexVersion([string]$Codex) {
    $ErrorActionPreference = 'Continue'
    if (-not $Codex) { return $null }
    $v = (& $Codex --version 2>$null | Select-Object -First 1)
    if ($v -match '(\d+\.\d+\.\d+\S*)') { return $Matches[1] }
    return $null
}

function Invoke-CodexAppServerCheck([string]$Codex, [int]$TimeoutMs = 60000) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo $Codex, 'app-server'
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
    $p = [Diagnostics.Process]::Start($psi)
    $null = $p.StandardError.ReadToEndAsync()
    $send = { param($o) $p.StandardInput.WriteLine(($o | ConvertTo-Json -Compress -Depth 10)); $p.StandardInput.Flush() }
    $read = {
        param($id)
        $sw = [Diagnostics.Stopwatch]::StartNew()
        while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
            $t = $p.StandardOutput.ReadLineAsync()
            if (-not $t.Wait($TimeoutMs)) { break }
            if ($null -eq $t.Result) { break }
            $m = $t.Result | ConvertFrom-Json
            if ($m.PSObject.Properties['id'] -and $m.id -eq $id) { return $m }
        }
        throw "codex app-server 在 $([int]($TimeoutMs / 1000)) 秒内没有回应请求 $id"
    }
    try {
        & $send @{ id = 1; method = 'initialize'; params = @{ clientInfo = @{ name = 'magpie-relay-install'; version = '1.0' } } }
        $init = & $read 1
        if ($init.PSObject.Properties['error']) { throw "initialize 失败: $($init.error | ConvertTo-Json -Compress)" }
        & $send @{ method = 'initialized' }
        & $send @{ id = 2; method = 'account/read'; params = @{ refreshToken = $false } }
        $acct = & $read 2
        & $send @{ id = 3; method = 'model/list'; params = @{} }
        $ml = & $read 3
        $type = $null; $req = $null; $ids = @()
        if ($acct.PSObject.Properties['result']) {
            if ($acct.result.account) { $type = $acct.result.account.type }
            $req = $acct.result.requiresOpenaiAuth
        }
        if ($ml.PSObject.Properties['result']) { $ids = @($ml.result.data | ForEach-Object { $_.id }) }
        [pscustomobject]@{ AccountType = $type; RequiresOpenaiAuth = $req; Models = $ids }
    } finally {
        try { $p.StandardInput.Close() } catch { }
        if (-not $p.WaitForExit(5000)) { try { $p.Kill() } catch { } }
    }
}

# ---------------------------------------------------------------- codex-mode helpers

function Get-CodexAuthMode {
    if (-not (Test-Path -LiteralPath $Script:AuthPath)) { return 'none' }
    try {
        $m = (Get-Content -LiteralPath $Script:AuthPath -Raw -Encoding UTF8 | ConvertFrom-Json).auth_mode
        if ($m) { return [string]$m } else { return 'unknown' }
    } catch { return 'unreadable' }
}

function Install-CodexModeShim {
    $dir = Split-Path $Script:ShimPath
    if (-not (Test-Path -LiteralPath $dir)) { throw "$dir 不存在" }
    if ((Test-Path -LiteralPath $Script:ShimPath) -and
        -not ((Get-Content -LiteralPath $Script:ShimPath -Raw) -match [regex]::Escape($Script:ShimMarker))) {
        throw "$($Script:ShimPath) 已存在且不是本工具创建的，没有覆盖"
    }
    $target = Join-Path $Script:InstallDir 'codex-mode.cmd'
    # Keep the .cmd ASCII where possible: cmd.exe reads it in the OEM code page.
    if ($target.StartsWith($env:USERPROFILE, [StringComparison]::OrdinalIgnoreCase)) {
        $target = '%USERPROFILE%' + $target.Substring($env:USERPROFILE.Length)
    }
    $text = "@echo off`r`n$($Script:ShimMarker)`r`ncall `"$target`" %*`r`n"
    [IO.File]::WriteAllText($Script:ShimPath, $text, (New-Object Text.UTF8Encoding $false))
}

function Remove-CodexModeShim {
    if ((Test-Path -LiteralPath $Script:ShimPath) -and
        ((Get-Content -LiteralPath $Script:ShimPath -Raw) -match [regex]::Escape($Script:ShimMarker))) {
        Remove-Item -LiteralPath $Script:ShimPath -Force
        return $true
    }
    return $false
}

function Get-CodexDesktopProcesses {
    # Desktop runs as Codex.exe; exclude the CLI / app-server binaries, which are also named codex.exe.
    $cli = @(Get-Command codex.exe -All -ErrorAction SilentlyContinue | ForEach-Object { $_.Source })
    @(Get-Process -Name 'Codex' -ErrorAction SilentlyContinue | Where-Object {
        $p = $_.Path
        (-not $p) -or (($p -notmatch '\\OpenAI\\Codex\\bin\\') -and ($cli -notcontains $p))
    })
}

# ---------------------------------------------------------------- state

function Read-InstallState {
    if (Test-Path -LiteralPath $Script:StatePath) {
        return (Get-Content -LiteralPath $Script:StatePath -Raw -Encoding UTF8 | ConvertFrom-Json)
    }
    return $null
}

function Save-InstallState($State) {
    $json = $State | ConvertTo-Json -Depth 6
    Write-TextFileAtomic $Script:StatePath $json
}
