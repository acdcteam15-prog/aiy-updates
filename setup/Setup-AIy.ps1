<#
  AIy - Windows setup + rebuild wizard
  Windows PowerShell 5.1 compatible. Saved as UTF-8 with BOM.
  Started by START-HERE.bat (menu) or Rebuild-APK.bat (one-click rebuild).
#>
param(
  [ValidateSet('menu', 'setup', 'rebuild', 'publish', 'health', 'output', 'reset', 'fixgoogle', 'crashlog', 'lib')]
  [string]$Mode = 'menu'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }

# ------------------------------------------------------------------ constants
$WizardVersion = '1.21.1'
$AppName = 'AIy'
$Package = 'com.aiy.app'
$KeyAlias = 'aiy'
$DesugarLib = 'com.android.tools:desugar_jdk_libs:2.1.4'
$SdkPackages = @('platform-tools', 'platforms;android-36', 'build-tools;36.0.0')
$CmdlineToolsUrls = @(
  'https://dl.google.com/android/repository/commandlinetools-win-13114758_latest.zip',
  'https://dl.google.com/android/repository/commandlinetools-win-11076708_latest.zip'
)
# Public OAuth client of firebase-tools (it is in the firebase-tools source code).
$FbClientId = '563584335869-fgrhgmd47bqnekij5i8b5pr03ho849e6.apps.googleusercontent.com'
$FbClientSecret = 'j9iVZfS8kkCEFUPaAeJV0sAi'

$OnWindows = ($env:OS -eq 'Windows_NT')
$TestMode = ($env:AIY_TEST -eq '1')
$BundleRoot = Split-Path -Parent $PSScriptRoot
if ($env:AIY_WORK) { $Work = $env:AIY_WORK } else { $Work = 'C:\AIyBuild' }
$AppDir = Join-Path $Work 'app'
$OutDir = Join-Path $Work 'Output'
$StatePath = Join-Path $Work 'state.json'
$LogPath = Join-Path $OutDir 'setup.log'
$FlutterDir = Join-Path $Work 'flutter'
$SdkDir = Join-Path $Work 'android-sdk'
$KeyDir = Join-Path $Work 'keystore'
$KeystorePath = Join-Path $KeyDir 'aiy-release.jks'
$BackupDir = Join-Path $OutDir 'keystore-backup'

if ($OnWindows) { $FirebaseExe = 'firebase.cmd'; $NpmExe = 'npm.cmd' } else { $FirebaseExe = 'firebase'; $NpmExe = 'npm' }

$Script:State = @{}
$Script:Project = ''
$Script:Account = ''
$Script:LastHint = ''
$Script:Answers = $null
if ($TestMode -and $env:AIY_ANSWERS) {
  $Script:Answers = New-Object System.Collections.Queue
  foreach ($a in ($env:AIY_ANSWERS -split '\|')) { $Script:Answers.Enqueue($a) }
}

# ------------------------------------------------------------------ output helpers
# Tokens and keys printed by tools (the Firebase CLI prints OAuth tokens) must never reach setup.log.
function Remove-Secrets([string]$s) {
  if (-not $s) { return $s }
  $s = [regex]::Replace($s, '("(?:access_token|refresh_token|id_token|client_secret|api_key|apiKey)"\s*:\s*")[^"]+', '$1<redacted>')
  $s = [regex]::Replace($s, 'ya29\.[A-Za-z0-9_\-\.]{20,}', '<redacted-token>')
  $s = [regex]::Replace($s, '1//[A-Za-z0-9_\-]{20,}', '<redacted-token>')
  $s = [regex]::Replace($s, 'eyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}', '<redacted-jwt>')
  $s = [regex]::Replace($s, 'AIza[0-9A-Za-z_\-]{30,}', '<redacted-key>')
  return $s
}
function Write-Log([string]$msg) {
  try {
    if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Force -Path $OutDir | Out-Null }
    Add-Content -Path $LogPath -Value ('[{0}] {1}' -f (Get-Date -Format 's'), (Remove-Secrets $msg))
  } catch { }
}
function Say([string]$m, [string]$color = 'Gray') { Write-Host $m -ForegroundColor $color; Write-Log $m }
function Ok([string]$m) { Say ('  [OK]  ' + $m) 'Green' }
function Warn([string]$m) { Say ('  [!]   ' + $m) 'Yellow' }
function Fail([string]$m) { Say ('  [X]   ' + $m) 'Red' }
function Info([string]$m) { Say ('        ' + $m) 'Gray' }
function Head([string]$m) { Say ''; Say ('=== ' + $m + ' ===') 'Cyan' }
function Wait-Sec([int]$s) { if ($TestMode) { return }; Start-Sleep -Seconds $s }

function Ask([string]$prompt) {
  if ($null -ne $Script:Answers) {
    if ($Script:Answers.Count -gt 0) {
      $a = [string]$Script:Answers.Dequeue()
      Write-Host ($prompt + ': ' + $a)
      Write-Log ('ASK ' + $prompt + ' -> ' + $a)
      return $a
    }
    throw ('TEST: no scripted answer for prompt: ' + $prompt)
  }
  $v = Read-Host $prompt
  if ($null -eq $v) { $v = '' }
  return $v
}

function Open-Url([string]$url) {
  Write-Log ('OPEN ' + $url)
  if ($OnWindows -and -not $TestMode) { try { Start-Process $url } catch { Warn ('Open this page yourself: ' + $url) } }
}

function New-RandomString([int]$len, [string]$chars) {
  $rng = New-Object System.Security.Cryptography.RNGCryptoServiceProvider
  $bytes = New-Object byte[] $len
  $rng.GetBytes($bytes)
  $sb = New-Object System.Text.StringBuilder
  foreach ($b in $bytes) { [void]$sb.Append($chars[$b % $chars.Length]) }
  return $sb.ToString()
}

function Write-TextFile([string]$path, [string]$text) {
  $dir = Split-Path -Parent $path
  if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  [IO.File]::WriteAllText($path, $text, (New-Object Text.UTF8Encoding $false))
}

# ------------------------------------------------------------------ state (PS 5.1: no -AsHashtable)
function ConvertTo-Hash($o) {
  if ($null -eq $o) { return $null }
  if ($o -is [System.Management.Automation.PSCustomObject]) {
    $h = @{}
    foreach ($p in $o.PSObject.Properties) { $h[$p.Name] = ConvertTo-Hash $p.Value }
    return $h
  }
  if (($o -is [System.Collections.IEnumerable]) -and -not ($o -is [string])) {
    $l = @()
    foreach ($i in $o) { $l += , (ConvertTo-Hash $i) }
    return , $l
  }
  return $o
}

function Load-State {
  $Script:State = @{}
  if (Test-Path $StatePath) {
    try { $Script:State = ConvertTo-Hash (Get-Content -Raw -Path $StatePath | ConvertFrom-Json) }
    catch { Warn 'state.json could not be read - starting with fresh progress.'; $Script:State = @{} }
  }
  if ($null -eq $Script:State) { $Script:State = @{} }
  if (-not $Script:State.ContainsKey('done') -or -not ($Script:State['done'] -is [hashtable])) { $Script:State['done'] = @{} }
  if ($Script:State.ContainsKey('projectId') -and $Script:State['projectId']) { $Script:Project = [string]$Script:State['projectId'] }
}
function Save-State {
  if (-not (Test-Path $Work)) { New-Item -ItemType Directory -Force -Path $Work | Out-Null }
  Write-TextFile $StatePath ($Script:State | ConvertTo-Json -Depth 10)
}
function Get-St([string]$k) { if ($Script:State.ContainsKey($k)) { return $Script:State[$k] }; return $null }
function Set-St([string]$k, $v) { $Script:State[$k] = $v; Save-State }

# ------------------------------------------------------------------ native commands
function Add-NativeLine($item, $list, [bool]$stream) {
  if ($item -is [System.Management.Automation.ErrorRecord]) { $t = [string]$item.Exception.Message } else { $t = [string]$item }
  $t = $t -replace '\x1b\[[0-9;]*[A-Za-z]', ''
  if ($t -match '^\s*System\.Management\.Automation\.RemoteException\s*$') { return }
  $t = $t -replace 'System\.Management\.Automation\.RemoteException', ''
  $list.Add($t)
  if ($stream) { Write-Host $t }
  Write-Log ('  | ' + $t)
}

# firebase-tools (version 15) can finish the real work, print its normal result, and THEN fail with
# "Error: An unexpected error has occurred." (the real reason, "Timed out.", is only in firebase-debug.log).
# The work is done, so that tail must not count as a failure.
function Test-FirebaseLogTimedOut([string]$dir) {
  try {
    $log = Join-Path $dir 'firebase-debug.log'
    if (-not (Test-Path $log)) { return $false }
    $tail = @(Get-Content -Path $log -Tail 40 -ErrorAction SilentlyContinue)
    return [bool]($tail | Where-Object { $_ -match 'Timed out' })
  } catch { return $false }
}

# Returns the output WITHOUT the timeout tail when the rest looks like a normal success, else $null.
function Get-FirebaseCleanOutput([string[]]$lines, [string]$dir) {
  $txt = ($lines -join "`n")
  $timedOut = ($txt -match 'Timed out')
  if (-not $timedOut -and $txt -match 'An unexpected error has occurred') { $timedOut = (Test-FirebaseLogTimedOut $dir) }
  if (-not $timedOut) { return $null }
  $txt = [regex]::Replace($txt, '\{\s*"status"\s*:\s*"error"\s*,\s*"error"\s*:\s*"Timed out\.?"\s*\}', '')
  $keep = New-Object System.Collections.Generic.List[string]
  foreach ($l in ($txt -split "`n")) {
    if ($l -match 'Timed out|An unexpected error has occurred|From firebase-debug\.log|^\s*\[(debug|error)\]') { continue }
    if ($l.Trim().Length -eq 0) { continue }
    $keep.Add($l)
  }
  if ($keep.Count -eq 0) { return $null }
  if (($keep -join "`n") -match '(?i)\berror\b|failed|denied|not found|permission|credential|quota|already exists') { return $null }
  return ,$keep
}

# Usage reporting ("analytics") is a network call the Firebase CLI makes when a command ends. If it cannot finish,
# the command fails with "Timed out" after doing its work. Turn it off in the CLI's own settings file.
$Script:UsageOff = $false
function Disable-FirebaseUsageTracking {
  if ($Script:UsageOff) { return }
  $Script:UsageOff = $true
  try {
    $dir = Join-Path (Join-Path $HOME '.config') 'configstore'
    $cfg = Join-Path $dir 'firebase-tools.json'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    if (-not (Test-Path $cfg)) { [IO.File]::WriteAllText($cfg, '{"usage": false}', $utf8); return }
    $t = [IO.File]::ReadAllText($cfg)
    if ($t -match '"usage"\s*:\s*false') { return }
    if ($t -match '"usage"\s*:\s*(true|false)') { $t = [regex]::Replace($t, '"usage"\s*:\s*(true|false)', '"usage": false', 1) }
    elseif ($t -match '^\s*\{\s*\}\s*$') { $t = '{"usage": false}' }
    else { $t = [regex]::Replace($t, '^\s*\{', '{ "usage": false,', 1) }
    [IO.File]::WriteAllText($cfg, $t, $utf8)
  } catch { }
}

function Invoke-Native {
  param([string]$Exe, [string[]]$ArgList = @(), [string]$Cwd = '', [switch]$Stream, [string]$InputText = '')
  if ($Exe -match 'firebase') { Disable-FirebaseUsageTracking }
  $old = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  $lines = New-Object System.Collections.Generic.List[string]
  $code = -1
  $pushed = $false
  try {
    if ($Cwd) { Push-Location $Cwd; $pushed = $true }
    Write-Log ('RUN ' + $Exe + ' ' + ($ArgList -join ' '))
    $global:LASTEXITCODE = 0
    if ($InputText) {
      $InputText | & $Exe @ArgList 2>&1 | ForEach-Object { Add-NativeLine $_ $lines $Stream.IsPresent }
    } else {
      & $Exe @ArgList 2>&1 | ForEach-Object { Add-NativeLine $_ $lines $Stream.IsPresent }
    }
    $code = $global:LASTEXITCODE
    if ($null -eq $code) { $code = 0 }
  } catch {
    $lines.Add([string]$_.Exception.Message)
    $code = 9009
  } finally {
    if ($pushed) { Pop-Location }
    $ErrorActionPreference = $old
  }
  Write-Log ('EXIT ' + $code)
  if ($code -ne 0 -and ($Exe -match 'firebase')) {
    $logDir = $Cwd
    if (-not $logDir) { $logDir = (Get-Location).Path }
    $clean = Get-FirebaseCleanOutput ($lines.ToArray()) $logDir
    if ($null -ne $clean) {
      Write-Log 'NOTE: firebase printed its result and then "Timed out" - treated as success.'
      $lines = $clean
      $code = 0
    }
  }
  return [pscustomobject]@{ Code = [int]$code; Out = ($lines -join "`n"); Lines = $lines.ToArray() }
}

function Invoke-Interactive([string]$Exe, [string[]]$ArgList) {
  if ($TestMode) { return (Invoke-Native $Exe $ArgList).Code }
  $old = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try { & $Exe @ArgList; return [int]$LASTEXITCODE } catch { return 9009 } finally { $ErrorActionPreference = $old }
}

function Have([string]$name) { return [bool](Get-Command $name -ErrorAction SilentlyContinue) }

function Get-BinPath([string]$dir, [string]$name, [string]$winExt) {
  $b = Join-Path $dir 'bin'
  if ($OnWindows) { return (Join-Path $b ($name + $winExt)) }
  return (Join-Path $b $name)
}

function Update-SessionPath {
  if (-not $OnWindows) { return }
  $m = [Environment]::GetEnvironmentVariable('Path', 'Machine')
  $u = [Environment]::GetEnvironmentVariable('Path', 'User')
  $parts = @()
  if ($env:JAVA_HOME) { $parts += (Join-Path $env:JAVA_HOME 'bin') }
  $parts += (Join-Path $FlutterDir 'bin')
  $parts += (Join-Path $SdkDir 'platform-tools')
  $parts += (Join-Path (Join-Path $SdkDir 'cmdline-tools') 'latest\bin')
  if ($env:APPDATA) { $parts += (Join-Path $env:APPDATA 'npm') }
  $parts += $m
  $parts += $u
  $env:Path = ($parts -join ';')
}

function Install-Winget([string]$Id) {
  if (-not (Have 'winget')) { throw ('winget is missing. Install "App Installer" from the Microsoft Store, then run START-HERE again. (Needed for ' + $Id + ')') }
  Info ('Installing ' + $Id + ' with winget (a few minutes)...')
  $r = Invoke-Native 'winget' @('install', '--id', $Id, '-e', '--silent', '--accept-package-agreements', '--accept-source-agreements') -Stream
  Update-SessionPath
  return $r.Code
}

function Get-FlutterExe {
  $bat = Join-Path (Join-Path $FlutterDir 'bin') 'flutter.bat'
  if ($OnWindows -and (Test-Path $bat)) { return $bat }
  $sh = Join-Path (Join-Path $FlutterDir 'bin') 'flutter'
  if (-not $OnWindows -and (Test-Path $sh)) { return $sh }
  if (Have 'flutter') { return 'flutter' }
  return ''
}

# 3.47: first Flutter that can build with built-in Kotlin (no more "plugins that apply KGP" warning)
$MinFlutter = [version]'3.47.0'

function Get-FlutterVersion([string]$text) {
  $m = [regex]::Match($text, 'Flutter\s+(\d+)\.(\d+)\.(\d+)')
  if (-not $m.Success) { return $null }
  return [version]('{0}.{1}.{2}' -f $m.Groups[1].Value, $m.Groups[2].Value, $m.Groups[3].Value)
}

function Test-FlutterVersion {
  $f = Get-FlutterExe
  if (-not $f) { return $false }
  $r = Invoke-Native $f @('--version')
  if ($r.Code -ne 0) { return $false }
  $v = Get-FlutterVersion $r.Out
  if ($null -eq $v) { return $false }
  if ($v -lt $MinFlutter) { $Script:LastHint = ('Flutter ' + $v + ' is older than ' + $MinFlutter + '.'); return $false }
  return $true
}

function Get-SdkManager {
  $b = Join-Path (Join-Path (Join-Path $SdkDir 'cmdline-tools') 'latest') 'bin'
  if ($OnWindows) { $p = Join-Path $b 'sdkmanager.bat' } else { $p = Join-Path $b 'sdkmanager' }
  if (Test-Path $p) { return $p }
  if (Have 'sdkmanager') { return 'sdkmanager' }
  return ''
}

function Get-Keytool {
  if ($env:JAVA_HOME) {
    $k = Get-BinPath $env:JAVA_HOME 'keytool' '.exe'
    if (Test-Path $k) { return $k }
  }
  if (Have 'keytool') { return 'keytool' }
  return ''
}

# ------------------------------------------------------------------ JSON / HTTP
function ConvertFrom-JsonLoose([string]$text) {
  if (-not $text) { return $null }
  $i = $text.IndexOf('{')
  $j = $text.LastIndexOf('}')
  if ($i -lt 0 -or $j -le $i) { return $null }
  try { return ($text.Substring($i, $j - $i + 1) | ConvertFrom-Json) } catch { return $null }
}

function New-HttpResult([int]$status, [string]$text) {
  $j = $null
  if ($text) { try { $j = $text | ConvertFrom-Json } catch { $j = $null } }
  return [pscustomobject]@{ Status = $status; Text = $text; Json = $j }
}

function Invoke-Http {
  param([string]$Method = 'GET', [string]$Uri, [hashtable]$Headers = @{}, $Body = $null, [hashtable]$Form = $null)
  Write-Log ('HTTP ' + $Method + ' ' + ($Uri -replace 'key=[^&]+', 'key=***'))
  if (Get-Command 'Mock-Http' -ErrorAction SilentlyContinue) {
    return (Mock-Http -Method $Method -Uri $Uri -Headers $Headers -Body $Body -Form $Form)
  }
  $p = @{ Method = $Method; Uri = $Uri; Headers = $Headers; UseBasicParsing = $true; TimeoutSec = 90 }
  if ($null -ne $Form) { $p['Body'] = $Form; $p['ContentType'] = 'application/x-www-form-urlencoded' }
  elseif ($null -ne $Body) {
    $p['Body'] = [Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Depth 20 -Compress))
    $p['ContentType'] = 'application/json; charset=utf-8'
  }
  try {
    $resp = Invoke-WebRequest @p
    $content = $resp.Content
    if ($content -is [byte[]]) { $content = [Text.Encoding]::UTF8.GetString($content) }
    return (New-HttpResult ([int]$resp.StatusCode) ([string]$content))
  } catch {
    $er = $_
    $status = 0
    $txt = ''
    try { if ($er.Exception.Response) { $status = [int]$er.Exception.Response.StatusCode } } catch { }
    if ($er.ErrorDetails -and $er.ErrorDetails.Message) { $txt = $er.ErrorDetails.Message }
    elseif ($er.Exception.Response) {
      try { $sr = New-Object IO.StreamReader($er.Exception.Response.GetResponseStream()); $txt = $sr.ReadToEnd() } catch { }
    }
    if (-not $txt) { $txt = [string]$er.Exception.Message }
    return (New-HttpResult $status $txt)
  }
}

function Get-ApiError($r) {
  if ($null -eq $r) { return '' }
  if ($r.Json -and $r.Json.error) {
    if ($r.Json.error.message) { return [string]$r.Json.error.message }
    return [string]$r.Json.error
  }
  if ($r.Status -ge 400) { return [string]$r.Text }
  return ''
}

# ------------------------------------------------------------------ manual step (R / C / Q)
function Invoke-Manual {
  param([string]$Title, [string[]]$Steps, [string]$Url, [scriptblock]$Check)
  Head ('Manual step: ' + $Title)
  if ($Url) { Info ('Opening: ' + $Url); Open-Url $Url }
  $n = 1
  foreach ($s in $Steps) { Say ('   {0}. {1}' -f $n, $s) 'White'; $n++ }
  [void](Ask 'Press Enter when you have done this')
  while ($true) {
    Info 'Checking...'
    $ok = $false
    try { $ok = [bool](& $Check) } catch { $ok = $false }
    if ($ok) { Ok ($Title + ' - confirmed.'); return $true }
    Warn ($Title + ' - not detected yet (changes can take a minute to appear).')
    if ($Script:LastHint) { Info ('Detail: ' + $Script:LastHint) }
    $c = ([string](Ask 'R = re-check, C = continue anyway, Q = quit')).Trim().ToUpper()
    if ($c -eq 'C') { Warn 'Continuing without confirmation.'; return $false }
    if ($c -eq 'Q') { throw 'USER_QUIT' }
    if ($c -ne 'R' -and $c -ne '') { $n = 1; foreach ($s in $Steps) { Say ('   {0}. {1}' -f $n, $s) 'White'; $n++ } }
    Wait-Sec 5
  }
}

# ------------------------------------------------------------------ step runner
function Invoke-Step($step) {
  $id = $step.Id
  Head $step.Title
  if ($step.Note) { Info $step.Note }
  $done = $Script:State['done']
  $ok = $false
  try { $ok = [bool](& $step.Check) } catch { $ok = $false }
  if ($done.ContainsKey($id) -and $done[$id]) {
    if ($ok) { Ok 'Already done (re-verified) - skipping.'; return }
    Warn 'Was done before, but the check fails now - repairing.'
  } elseif ($ok) {
    $done[$id] = $true; Save-State; Ok 'Already in place (verified).'; return
  }
  $null = & $step.Do
  $ok = $false
  try { $ok = [bool](& $step.Check) } catch { $ok = $false }
  if (-not $ok) { throw ('Step "' + $step.Title + '" could not be verified.' + $(if ($Script:LastHint) { ' ' + $Script:LastHint } else { '' })) }
  $done[$id] = $true
  Save-State
  Ok 'Done and verified.'
}

# ------------------------------------------------------------------ Gradle patches (pure text functions, unit-tested)
$SdkHookScript = @'
// aiy-sdk-hook: raises compileSdk to 36 for Flutter PLUGIN modules only (never :app).
// Applied from the root build.gradle(.kts). Safe to apply more than once.
subprojects { p ->
    if (p.name == 'app') return
    def raise = {
        def android = p.extensions.findByName('android')
        if (android == null) return
        try {
            int cur = 0
            if (android.hasProperty('compileSdk') && android.compileSdk != null) {
                cur = android.compileSdk as int
            } else if (android.hasProperty('compileSdkVersion') && android.compileSdkVersion != null) {
                def m = (android.compileSdkVersion.toString() =~ /(\d+)/)
                if (m.find()) cur = m.group(1) as int
            }
            if (cur < 36) {
                if (android.hasProperty('compileSdk')) { android.compileSdk = 36 } else { android.compileSdkVersion(36) }
                p.logger.lifecycle("aiy-sdk-hook: ${p.name} compileSdk ${cur} -> 36")
            }
        } catch (Throwable t) {
            p.logger.warn("aiy-sdk-hook: ${p.name}: ${t.message}")
        }
    }
    if (p.state.executed) { raise() } else { p.afterEvaluate { raise() } }
}
'@

function Update-AppGradleText([string]$text, [bool]$kts, [string]$pkg) {
  $t = $text -replace "`r`n", "`n"
  # applicationId
  if ($kts) { $t = [regex]::Replace($t, '(?m)^([ \t]*)applicationId\s*=?\s*["''][^"''\n]*["'']', ('${1}applicationId = "' + $pkg + '"')) }
  else { $t = [regex]::Replace($t, '(?m)^([ \t]*)applicationId\s*=?\s*["''][^"''\n]*["'']', ('${1}applicationId "' + $pkg + '"')) }
  # minSdk 24 (firebase_core 5 / firebase_auth 7 / local_auth 3 need it; keep a higher literal number)
  $t = [regex]::Replace($t, '(?m)^([ \t]*)minSdk(?:Version)?\b[^\n]*$', {
      param($m)
      $line = $m.Value
      $num = [regex]::Match($line, '\b(\d+)\s*$')
      if ($num.Success -and [int]$num.Groups[1].Value -ge 24) { return $line }
      if ($kts) { return ($m.Groups[1].Value + 'minSdk = 24') }
      return ($m.Groups[1].Value + 'minSdkVersion 24')
    })
  # core library desugaring flag
  if ($t -notmatch 'oreLibraryDesugaringEnabled') {
    if ($kts) { $flag = 'isCoreLibraryDesugaringEnabled = true' } else { $flag = 'coreLibraryDesugaringEnabled true' }
    $rx = New-Object regex '(?m)^([ \t]*)compileOptions\s*\{[ \t]*$'
    if ($rx.IsMatch($t)) {
      $t = $rx.Replace($t, { param($m) $m.Value + "`n" + $m.Groups[1].Value + '    ' + $flag }, 1)
    } else {
      $rxA = New-Object regex '(?m)^android\s*\{[ \t]*$'
      $t = $rxA.Replace($t, { param($m) $m.Value + "`n    compileOptions {`n        " + $flag + "`n    }" }, 1)
    }
  }
  # desugaring dependency
  if ($t -notmatch [regex]::Escape('desugar_jdk_libs')) {
    if ($kts) { $dep = '    coreLibraryDesugaring("' + $DesugarLib + '")' } else { $dep = "    coreLibraryDesugaring '" + $DesugarLib + "'" }
    $rxD = New-Object regex '(?m)^dependencies\s*\{[ \t]*$'
    if ($rxD.IsMatch($t)) { $t = $rxD.Replace($t, { param($m) $m.Value + "`n" + $dep }, 1) }
    else { $t = $t.TrimEnd() + "`n`ndependencies {`n" + $dep + "`n}`n" }
  }
  # release signing (reads android/key.properties)
  # kts: inside android { } the name `java` means Gradle's Java extension, so use imports
  if ($kts) {
    foreach ($imp in @('import java.io.FileInputStream', 'import java.util.Properties')) {
      if ($t -notmatch ('(?m)^' + [regex]::Escape($imp) + '\s*$')) { $t = $imp + "`n" + $t }
    }
  }
  # older wizard versions wrote a block that does not compile - remove it so it is rewritten
  $t = [regex]::Replace($t, '(?s)[ \t]*// aiy-signing-begin.*?// aiy-signing-end[ \t]*\n?', '')
  if ($t -notmatch 'aiy-signing-begin') {
    if ($kts) {
      $block = @'
    // aiy-signing-begin
    signingConfigs {
        create("release") {
            val kp = Properties()
            val kf = rootProject.file("key.properties")
            if (kf.exists()) { FileInputStream(kf).use { stream -> kp.load(stream) } }
            keyAlias = kp.getProperty("keyAlias")
            keyPassword = kp.getProperty("keyPassword")
            val sf: String? = kp.getProperty("storeFile")
            if (sf != null) { storeFile = file(sf) }
            storePassword = kp.getProperty("storePassword")
        }
    }
    // aiy-signing-end
'@
    } else {
      $block = @'
    // aiy-signing-begin
    signingConfigs {
        release {
            def kp = new Properties()
            def kf = rootProject.file('key.properties')
            if (kf.exists()) { kf.withInputStream { kp.load(it) } }
            keyAlias kp['keyAlias']
            keyPassword kp['keyPassword']
            storeFile kp['storeFile'] ? file(kp['storeFile']) : null
            storePassword kp['storePassword']
        }
    }
    // aiy-signing-end
'@
    }
    $block = $block -replace "`r`n", "`n"
    $rxB = New-Object regex '(?m)^[ \t]*buildTypes\s*\{'
    if ($rxB.IsMatch($t)) { $t = $rxB.Replace($t, { param($m) $block + "`n" + $m.Value }, 1) }
  }
  if ($kts) { $t = [regex]::Replace($t, 'signingConfig\s*=\s*signingConfigs\.getByName\(\s*"debug"\s*\)', 'signingConfig = signingConfigs.getByName("release")') }
  else { $t = [regex]::Replace($t, 'signingConfig\s+signingConfigs\.debug\b', 'signingConfig signingConfigs.release') }
  # R8 code shrinking stripped WorkManager's database class -> app crashed at start. Keep everything.
  if ($t -notmatch 'aiy-noshrink') {
    if ($kts) {
      $ns = "`n// aiy-noshrink: R8 removed classes WorkManager needs (crash at start), so shrinking is off`nandroid {`n    buildTypes {`n        getByName(`"release`") {`n            isMinifyEnabled = false`n            isShrinkResources = false`n        }`n    }`n}`n"
    } else {
      $ns = "`n// aiy-noshrink: R8 removed classes WorkManager needs (crash at start), so shrinking is off`nandroid {`n    buildTypes {`n        release {`n            minifyEnabled false`n            shrinkResources false`n        }`n    }`n}`n"
    }
    $t = $t.TrimEnd() + "`n" + $ns
  }
  return $t
}

function Test-AppGradleText([string]$text, [bool]$kts, [string]$pkg) {
  $t = $text -replace "`r`n", "`n"
  if ($t -notmatch ('applicationId\s*=?\s*"' + [regex]::Escape($pkg) + '"')) { return $false }
  $mins = [regex]::Matches($t, '(?m)^[ \t]*minSdk(?:Version)?\s*=?\s*(\d+)\s*$')
  if ($mins.Count -lt 1) { return $false }
  foreach ($mm in $mins) { if ([int]$mm.Groups[1].Value -lt 24) { return $false } }
  if ($kts) { if ($t -notmatch 'isCoreLibraryDesugaringEnabled\s*=\s*true') { return $false } }
  else { if ($t -notmatch 'coreLibraryDesugaringEnabled\s*=?\s*true') { return $false } }
  if ($t -notmatch 'coreLibraryDesugaring\s*\(?\s*["'']com\.android\.tools:desugar_jdk_libs') { return $false }
  if ($t -notmatch 'aiy-signing-begin') { return $false }
  if ($kts) { if ($t -notmatch 'signingConfig\s*=\s*signingConfigs\.getByName\("release"\)') { return $false } }
  if ($kts) {
    if ($t -notmatch '(?m)^import java\.util\.Properties\s*$' -or $t -notmatch '(?m)^import java\.io\.FileInputStream\s*$') { return $false }
    if ($t -match 'java\.util\.Properties\(\)|java\.io\.FileInputStream\(') { return $false }
  }
  else { if ($t -notmatch 'signingConfig\s+signingConfigs\.release') { return $false } }
  if ([regex]::Matches($t, 'aiy-signing-begin').Count -ne 1) { return $false }
  if ([regex]::Matches($t, 'aiy-noshrink').Count -ne 1) { return $false }
  return $true
}

function Update-RootGradleText([string]$text, [bool]$kts) {
  $t = $text -replace "`r`n", "`n"
  if ($t -match 'aiy-sdk-hook\.gradle') { return $t }
  if ($kts) { $line = 'apply(from = "aiy-sdk-hook.gradle")' } else { $line = "apply from: 'aiy-sdk-hook.gradle'" }
  return ($t.TrimEnd() + "`n`n// aiy: raise compileSdk of plugin modules`n" + $line + "`n")
}

function Test-RootGradleText([string]$text) {
  return ([regex]::Matches($text, 'aiy-sdk-hook\.gradle').Count -eq 1)
}

$ManifestPermissions = @('android.permission.INTERNET', 'android.permission.RECORD_AUDIO', 'android.permission.CAMERA', 'android.permission.REQUEST_INSTALL_PACKAGES', 'android.permission.POST_NOTIFICATIONS', 'android.permission.ACCESS_NETWORK_STATE', 'android.permission.FOREGROUND_SERVICE', 'android.permission.FOREGROUND_SERVICE_DATA_SYNC', 'android.permission.WAKE_LOCK')

$BlockedPermissions = @('android.permission.READ_SMS', 'android.permission.RECEIVE_SMS')

function Update-ManifestText([string]$text) {
  $t = $text -replace "`r`n", "`n"
  foreach ($bp in $BlockedPermissions) {
    $t = [regex]::Replace($t, '(?m)^[ \t]*<uses-permission\s+android:name="' + [regex]::Escape($bp) + '"\s*/>[ \t]*\n?', '')
  }
  # proper app name under the icon
  $t = [regex]::Replace($t, 'android:label="aiy"', 'android:label="AIy"')
  # our Application class (crash screen) + round icon
  $t = $t.Replace('android:name="${applicationName}"', 'android:name=".AIyApp"')
  if ($t -notmatch 'android:roundIcon=') {
    $t = [regex]::Replace($t, '(?m)^([ \t]*)android:icon="@mipmap/ic_launcher"', ('${1}android:icon="@mipmap/ic_launcher"' + "`n" + '${1}android:roundIcon="@mipmap/ic_launcher_round"'), 1)
  }
  # no Android auto-backup / phone-to-phone copy of app data: the vault key cannot move, so copied keys could never be opened.
  # AIy has its own backup (Settings > Backup). aiy-no-backup
  if ($t -notmatch 'android:allowBackup=') {
    $t = [regex]::Replace($t, '(?m)^([ \t]*)android:icon="@mipmap/ic_launcher"', ('${1}android:icon="@mipmap/ic_launcher"' + "`n" + '${1}android:allowBackup="false"' + "`n" + '${1}android:fullBackupContent="false"'), 1)
  }
  if ($t -notmatch 'aiy-crash-activity') {
    $ca = @(
      '        <!-- aiy-crash-activity -->',
      '        <activity android:name=".CrashActivity" android:process=":crash" android:exported="false"',
      '            android:theme="@android:style/Theme.DeviceDefault.NoActionBar" />') -join "`n"
    $rc = New-Object regex '(?m)^([ \t]*)</application>'
    $t = $rc.Replace($t, { param($m) $ca + "`n" + $m.Value }, 1)
  }
  foreach ($perm in $ManifestPermissions) {
    if ($t -match ('android:name="' + [regex]::Escape($perm) + '"')) { continue }
    $rx = New-Object regex '(?m)^([ \t]*)<application\b'
    if ($rx.IsMatch($t)) {
      $t = $rx.Replace($t, { param($m) $m.Groups[1].Value + '<uses-permission android:name="' + $perm + '"/>' + "`n" + $m.Value }, 1)
    }
  }
  # speech_to_text: Android 11+ must be allowed to see the speech recognition service
  if ($t -notmatch 'android\.speech\.RecognitionService') {
    $intent = '        <intent>' + "`n" + '            <action android:name="android.speech.RecognitionService"/>' + "`n" + '        </intent>'
    $rq = New-Object regex '(?m)^([ \t]*)<queries>[ \t]*$'
    if ($rq.IsMatch($t)) { $t = $rq.Replace($t, { param($m) $m.Value + "`n" + $intent }, 1) }
    else { $t = $t -replace '</manifest>', ('    <queries>' + "`n" + $intent + "`n" + '    </queries>' + "`n" + '</manifest>') }
  }
  # url_launcher: Android 11+ must be allowed to see the browser (key pages, OpenRouter and GitHub sign-in)
  if ($t -notmatch 'aiy-browser-query') {
    $web = '        <!-- aiy-browser-query -->' + "`n" + '        <intent>' + "`n" + '            <action android:name="android.intent.action.VIEW"/>' + "`n" + '            <data android:scheme="https"/>' + "`n" + '        </intent>'
    $rq2 = New-Object regex '(?m)^([ \t]*)<queries>[ \t]*$'
    if ($rq2.IsMatch($t)) { $t = $rq2.Replace($t, { param($m) $m.Value + "`n" + $web }, 1) }
    else { $t = $t -replace '</manifest>', ('    <queries>' + "`n" + $web + "`n" + '    </queries>' + "`n" + '</manifest>') }
  }
  # read-aloud: Android 11+ must be allowed to see the text-to-speech engines
  if ($t -notmatch 'android\.intent\.action\.TTS_SERVICE') {
    $tts = '        <intent>' + "`n" + '            <action android:name="android.intent.action.TTS_SERVICE"/>' + "`n" + '        </intent>'
    $rq3 = New-Object regex '(?m)^([ \t]*)<queries>[ \t]*$'
    if ($rq3.IsMatch($t)) { $t = $rq3.Replace($t, { param($m) $m.Value + "`n" + $tts }, 1) }
    else { $t = $t -replace '</manifest>', ('    <queries>' + "`n" + $tts + "`n" + '    </queries>' + "`n" + '</manifest>') }
  }
  # share into AIy: text, photos, PDFs and zips from other apps (the "Share" menu) arrive at MainActivity
  if ($t -notmatch 'aiy-share-filters') {
    $sf = @(
      '            <!-- aiy-share-filters -->',
      '            <intent-filter>',
      '                <action android:name="android.intent.action.SEND"/>',
      '                <category android:name="android.intent.category.DEFAULT"/>',
      '                <data android:mimeType="text/*"/>',
      '                <data android:mimeType="image/*"/>',
      '                <data android:mimeType="application/pdf"/>',
      '                <data android:mimeType="application/zip"/>',
      '                <data android:mimeType="application/x-zip-compressed"/>',
      '            </intent-filter>',
      '            <intent-filter>',
      '                <action android:name="android.intent.action.SEND_MULTIPLE"/>',
      '                <category android:name="android.intent.category.DEFAULT"/>',
      '                <data android:mimeType="image/*"/>',
      '                <data android:mimeType="text/*"/>',
      '                <data android:mimeType="application/pdf"/>',
      '            </intent-filter>') -join "`n"
    $ra = New-Object regex '(?s)(<activity\b[^>]*android:name="\.MainActivity".*?)(\n[ \t]*</activity>)'
    if ($ra.IsMatch($t)) { $t = $ra.Replace($t, { param($m) $m.Groups[1].Value + "`n" + $sf + $m.Groups[2].Value }, 1) }
  }
  # keep working in the background: a foreground service shows the "AIy is working" notification
  if ($t -notmatch 'aiy-work-service') {
    $ws = @(
      '        <!-- aiy-work-service -->',
      '        <service android:name=".AIyWorkService" android:exported="false" android:foregroundServiceType="dataSync"/>') -join "`n"
    $rw = New-Object regex '(?m)^([ \t]*)</application>'
    $t = $rw.Replace($t, { param($m) $ws + "`n" + $m.Value }, 1)
  }
  # in-app updates: the downloaded APK is shared with the Android installer through this provider
  if ($t -notmatch 'aiy-file-provider') {
    $fp = @(
      '        <!-- aiy-file-provider -->',
      '        <provider android:name=".AIyFileProvider" android:authorities="${applicationId}.aiyfiles"',
      '            android:exported="false" android:grantUriPermissions="true">',
      '            <meta-data android:name="android.support.FILE_PROVIDER_PATHS" android:resource="@xml/aiy_file_paths"/>',
      '        </provider>') -join "`n"
    $rfp = New-Object regex '(?m)^([ \t]*)</application>'
    $t = $rfp.Replace($t, { param($m) $fp + "`n" + $m.Value }, 1)
  }
  return $t
}

function Test-ManifestText([string]$text) {
  if ($text -notmatch 'android:name="\.AIyApp"') { return $false }
  if ([regex]::Matches($text, 'aiy-crash-activity').Count -ne 1) { return $false }
  if ($text -notmatch 'android:roundIcon="@mipmap/ic_launcher_round"') { return $false }
  if ([regex]::Matches($text, 'android:allowBackup="false"').Count -ne 1) { return $false }
  foreach ($bp in $BlockedPermissions) { if ($text -match [regex]::Escape($bp)) { return $false } }
  if ([regex]::Matches($text, 'android\.speech\.RecognitionService').Count -ne 1) { return $false }
  if ([regex]::Matches($text, 'aiy-browser-query').Count -ne 1) { return $false }
  if ([regex]::Matches($text, 'aiy-file-provider').Count -ne 1) { return $false }
  if ([regex]::Matches($text, 'aiy-share-filters').Count -ne 1) { return $false }
  if ([regex]::Matches($text, 'aiy-work-service').Count -ne 1) { return $false }
  if ([regex]::Matches($text, 'android\.intent\.action\.TTS_SERVICE').Count -ne 1) { return $false }
  foreach ($perm in $ManifestPermissions) {
    if ([regex]::Matches($text, ('<uses-permission\s+android:name="' + [regex]::Escape($perm) + '"')).Count -ne 1) { return $false }
  }
  return $true
}

function Get-ManifestPath {
  $src = Join-Path (Join-Path (Join-Path $AppDir 'android') 'app') 'src'
  return (Join-Path (Join-Path $src 'main') 'AndroidManifest.xml')
}

# ------------------------------------------------------------------ native Android part
$MainActivityKotlin = @'
// aiy-main-activity: generated by the setup wizard (do not edit).
// Native helpers for the Flutter side: app updates, picking a project zip, reading and rebuilding zip files
// (streamed, so a 100 MB project never has to fit in memory) and saving to the Downloads folder.
package {PKG}

import android.Manifest
import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.media.ExifInterface
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.provider.Settings
import android.speech.tts.TextToSpeech
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.security.KeyStore
import java.util.Locale
import java.util.zip.ZipEntry
import java.util.zip.ZipFile
import java.nio.charset.Charset
import java.util.zip.ZipOutputStream
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

class MainActivity : FlutterFragmentActivity() {
    private var pendingPick: MethodChannel.Result? = null
    private var pendingAny = false
    private var tts: TextToSpeech? = null
    private var ttsReady = false
    private var ttsQueue: String? = null
    private val pickCode = 4711

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val ch = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "aiy/native")
        channel = ch
        instance = this
        handleShare(intent)
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "buildInfo" -> {
                    try {
                        val pi = packageManager.getPackageInfo(packageName, 0)
                        val code = if (Build.VERSION.SDK_INT >= 28) pi.longVersionCode else pi.versionCode.toLong()
                        result.success(mapOf("name" to (pi.versionName ?: ""), "build" to code))
                    } catch (e: Exception) {
                        result.error("buildInfo", e.message, null)
                    }
                }
                "canInstallApks" -> {
                    result.success(if (Build.VERSION.SDK_INT >= 26) packageManager.canRequestPackageInstalls() else true)
                }
                "openInstallSettings" -> {
                    try {
                        startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:" + packageName)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                        result.success(true)
                    } catch (e: Exception) {
                        result.success(false)
                    }
                }
                "installApk" -> {
                    try {
                        val src = File(call.argument<String>("path") ?: "")
                        // The installer may only read files under cache/updates: copy the APK there first.
                        val dir = File(cacheDir, "updates")
                        dir.mkdirs()
                        val file = if (src.parentFile?.canonicalPath == dir.canonicalPath) src else File(dir, "AIy-update.apk").also { src.copyTo(it, overwrite = true) }
                        val uri = FileProvider.getUriForFile(this, packageName + ".aiyfiles", file)
                        val intent = Intent(Intent.ACTION_VIEW)
                            .setDataAndType(uri, "application/vnd.android.package-archive")
                            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
                        startActivity(intent)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("installApk", e.message, null)
                    }
                }
                "secretGet" -> {
                    try {
                        result.success(secretGet(call.argument<String>("name") ?: ""))
                    } catch (e: Exception) {
                        // Stored, but this phone's vault key cannot open it (backup moved to a new phone, or the key was reset).
                        result.error("KEY_LOST", e.javaClass.simpleName + ": " + (e.message ?: ""), null)
                    }
                }
                "secretSet" -> {
                    try {
                        secretSet(call.argument<String>("name") ?: "", call.argument<String>("value"))
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("secretSet", e.message, null)
                    }
                }
                "openUrl" -> {
                    try {
                        startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(call.argument<String>("url") ?: "")).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                        result.success(true)
                    } catch (e: Exception) {
                        result.success(false)
                    }
                }
                "speak" -> {
                    speak(call.argument<String>("text") ?: "")
                    result.success(true)
                }
                "stopSpeaking" -> {
                    tts?.stop()
                    result.success(true)
                }
                "notify" -> {
                    try {
                        notifyUser(call.argument<String>("title") ?: "AIy", call.argument<String>("text") ?: "")
                        result.success(true)
                    } catch (e: Exception) {
                        result.success(false)
                    }
                }
                "requestNotifications" -> {
                    if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
                        requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 4712)
                    }
                    result.success(true)
                }
                "pickZip", "pickFile" -> {
                    if (pendingPick != null) {
                        result.error("busy", "A file picker is already open.", null)
                    } else {
                        pendingPick = result
                        pendingAny = call.method == "pickFile"
                        val pick = Intent(Intent.ACTION_OPEN_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE).setType("*/*")
                        if (!pendingAny) pick.putExtra(Intent.EXTRA_MIME_TYPES, arrayOf("application/zip", "application/x-zip-compressed", "application/octet-stream"))
                        try {
                            startActivityForResult(pick, pickCode)
                        } catch (e: Exception) {
                            pendingPick = null
                            result.error("pickZip", e.message, null)
                        }
                    }
                }
                "workShow" -> {
                    try {
                        val i = Intent(this, AIyWorkService::class.java)
                            .putExtra("title", call.argument<String>("title") ?: "AIy is working")
                            .putExtra("text", call.argument<String>("text") ?: "")
                        if (Build.VERSION.SDK_INT >= 26) startForegroundService(i) else startService(i)
                        result.success(true)
                    } catch (e: Exception) {
                        result.success(false)
                    }
                }
                "networkKind" -> {
                    // wifi (not metered) | metered (a Wi-Fi hotspot that costs data) | cellular | other | none
                    try {
                        val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as android.net.ConnectivityManager
                        val nc = cm.getNetworkCapabilities(cm.activeNetwork)
                        val kind = when {
                            nc == null -> "none"
                            nc.hasTransport(android.net.NetworkCapabilities.TRANSPORT_WIFI) || nc.hasTransport(android.net.NetworkCapabilities.TRANSPORT_ETHERNET) ->
                                if (cm.isActiveNetworkMetered) "metered" else "wifi"
                            nc.hasTransport(android.net.NetworkCapabilities.TRANSPORT_CELLULAR) -> "cellular"
                            else -> "other"
                        }
                        result.success(kind)
                    } catch (e: Exception) {
                        result.success("unknown")
                    }
                }
                "storageFree" -> {
                    try {
                        val st = android.os.StatFs(filesDir.absolutePath)
                        result.success(st.availableBytes)
                    } catch (e: Exception) {
                        result.success(-1L)
                    }
                }
                "workHide" -> {
                    try {
                        stopService(Intent(this, AIyWorkService::class.java))
                    } catch (e: Exception) {
                    }
                    result.success(true)
                }
                "takeShared" -> {
                    val v = pendingShare
                    pendingShare = null
                    result.success(v)
                }
                "zipScan", "zipRead", "zipRebuild", "zipCreate", "zipBytes", "zipExtractFirst", "saveToDownloads", "shrinkImage" -> background(call, result)
                else -> result.notImplemented()
            }
        }
    }

    // ---- read aloud with the phone's own voice
    private fun speak(text: String) {
        val clean = text.take(3900)
        if (tts == null) {
            ttsQueue = clean
            tts = TextToSpeech(this) { status ->
                ttsReady = status == TextToSpeech.SUCCESS
                val q = ttsQueue
                ttsQueue = null
                if (ttsReady && q != null) say(q)
            }
        } else if (ttsReady) {
            say(clean)
        } else {
            ttsQueue = clean
        }
    }

    private fun say(text: String) {
        val t = tts ?: return
        val arabic = text.any { it.code in 0x0600..0x06FF }
        t.setLanguage(if (arabic) Locale("ar") else Locale.getDefault())
        t.stop()
        t.speak(text, TextToSpeech.QUEUE_FLUSH, null, "aiy")
    }

    override fun onDestroy() {
        tts?.shutdown()
        if (instance === this) instance = null
        super.onDestroy()
    }

    companion object {
        var instance: MainActivity? = null
    }

    // The "Stop" button of the "AIy is working" notification: tell the Flutter side.
    fun workStopped() {
        runOnUiThread { channel?.invokeMethod("onWorkStop", null) }
    }

    // ---- things shared into AIy from other apps (text, photos, PDFs, zips)
    private var channel: MethodChannel? = null
    private var pendingShare: Map<String, Any?>? = null

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleShare(intent)
    }

    @Suppress("DEPRECATION")
    private fun sharedUris(intent: Intent): List<Uri> {
        val out = ArrayList<Uri>()
        if (intent.action == Intent.ACTION_SEND_MULTIPLE) {
            val l = if (Build.VERSION.SDK_INT >= 33) intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java) else intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)
            if (l != null) out.addAll(l)
        } else {
            val u = if (Build.VERSION.SDK_INT >= 33) intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java) else intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)
            if (u != null) out.add(u)
        }
        return out
    }

    // Copies what was shared into the app's cache (on a background thread), then tells the Flutter side.
    private fun handleShare(intent: Intent?) {
        if (intent == null) return
        val act = intent.action
        if (act != Intent.ACTION_SEND && act != Intent.ACTION_SEND_MULTIPLE) return
        if (intent.getBooleanExtra("aiy_handled", false)) return
        intent.putExtra("aiy_handled", true)
        val text = intent.getStringExtra(Intent.EXTRA_TEXT) ?: ""
        val subject = intent.getStringExtra(Intent.EXTRA_SUBJECT) ?: ""
        val mime = intent.type ?: ""
        val uris = sharedUris(intent).take(5)
        Thread {
            val files = ArrayList<Map<String, Any?>>()
            var problem = ""
            try {
                val dir = File(cacheDir, "shared")
                dir.mkdirs()
                dir.listFiles()?.forEach { it.delete() }
                for ((i, uri) in uris.withIndex()) {
                    var name = "shared_" + i
                    val type = contentResolver.getType(uri) ?: mime
                    contentResolver.query(uri, null, null, null, null)?.use { c ->
                        val col = c.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                        if (col >= 0 && c.moveToFirst()) name = c.getString(col) ?: name
                    }
                    val safe = name.replace(Regex("[^A-Za-z0-9._-]"), "_")
                    val out = File(dir, i.toString() + "_" + safe)
                    val input = contentResolver.openInputStream(uri) ?: continue
                    input.use { ins -> out.outputStream().use { o -> ins.copyTo(o) } }
                    files.add(mapOf("path" to out.absolutePath, "name" to name, "size" to out.length(), "mime" to type))
                }
            } catch (e: Throwable) {
                problem = e.message ?: e.toString()
            }
            val value = mapOf("text" to text, "subject" to subject, "files" to files, "problem" to problem)
            runOnUiThread {
                pendingShare = value
                channel?.invokeMethod("onShared", null)
            }
        }.start()
    }

    // ---- a notification (a build finished while AIy was in the background)
    private fun notifyUser(title: String, text: String) {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= 26) nm.createNotificationChannel(NotificationChannel("aiy_builds", "Builds and checks", NotificationManager.IMPORTANCE_DEFAULT))
        val launch = packageManager.getLaunchIntentForPackage(packageName) ?: Intent()
        val pi = PendingIntent.getActivity(this, 0, launch, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val b = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, "aiy_builds") else Notification.Builder(this)
        val stat = resources.getIdentifier("ic_stat_aiy", "drawable", packageName)
        b.setContentTitle(title).setContentText(text).setSmallIcon(if (stat != 0) stat else applicationInfo.icon).setContentIntent(pi).setAutoCancel(true)
        nm.notify((System.currentTimeMillis() % 100000).toInt(), b.build())
    }

    // ---- key vault: AES-256-GCM with a key kept in the Android Keystore (it cannot be read out of the phone).
    private fun vaultKey(): SecretKey {
        val ks = KeyStore.getInstance("AndroidKeyStore")
        ks.load(null)
        val existing = ks.getKey("aiy_vault", null)
        if (existing is SecretKey) return existing
        val gen = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        gen.init(
            KeyGenParameterSpec.Builder("aiy_vault", KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build()
        )
        return gen.generateKey()
    }

    private fun secretSet(name: String, value: String?) {
        val sp = getSharedPreferences("aiy_vault", MODE_PRIVATE)
        if (value.isNullOrEmpty()) {
            sp.edit().remove(name).apply()
            return
        }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, vaultKey())
        val packed = cipher.iv + cipher.doFinal(value.toByteArray(Charsets.UTF_8))
        sp.edit().putString(name, Base64.encodeToString(packed, Base64.NO_WRAP)).apply()
    }

    // Null when nothing is stored. Throws when something is stored but cannot be decrypted
    // (for example after Android copied the app data to a new phone: the vault key never leaves the old one).
    private fun secretGet(name: String): String? {
        val raw = getSharedPreferences("aiy_vault", MODE_PRIVATE).getString(name, null) ?: return null
        val packed = Base64.decode(raw, Base64.NO_WRAP)
        if (packed.size < 13) throw IllegalStateException("stored value is too short")
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, vaultKey(), GCMParameterSpec(128, packed, 0, 12))
        return String(cipher.doFinal(packed, 12, packed.size - 12), Charsets.UTF_8)
    }

    // Zip work can take a while: never on the main thread.
    private fun background(call: MethodCall, result: MethodChannel.Result) {
        Thread {
            try {
                val value: Any? = when (call.method) {
                    "zipScan" -> zipScan(call.argument<String>("path") ?: "")
                    "zipRead" -> zipRead(
                        call.argument<String>("path") ?: "",
                        call.argument<List<String>>("names") ?: emptyList(),
                        call.argument<Int>("maxBytes") ?: 400000
                    )
                    "zipRebuild" -> zipRebuild(
                        call.argument<String>("src") ?: "",
                        call.argument<String>("dst") ?: "",
                        call.argument<Map<String, String>>("files") ?: emptyMap()
                    )
                    "zipCreate" -> zipCreate(
                        call.argument<String>("dst") ?: "",
                        call.argument<Map<String, String>>("files") ?: emptyMap(),
                        call.argument<Map<String, ByteArray>>("bytes") ?: emptyMap()
                    )
                    "zipBytes" -> zipBytes(call.argument<String>("path") ?: "", call.argument<String>("name") ?: "")
                    "shrinkImage" -> shrinkImage(call.argument<String>("path") ?: "", call.argument<Int>("maxSide") ?: 1024, call.argument<Int>("quality") ?: 65)
                    "zipExtractFirst" -> zipExtractFirst(
                        call.argument<String>("path") ?: "",
                        call.argument<String>("ext") ?: ".apk",
                        call.argument<String>("dir") ?: ""
                    )
                    else -> saveToDownloads(call.argument<String>("path") ?: "", call.argument<String>("name") ?: "AIy.zip")
                }
                runOnUiThread { result.success(value) }
            } catch (e: Throwable) {
                val msg = e.message ?: e.toString()
                runOnUiThread { result.error(call.method, msg, null) }
            }
        }.start()
    }

    // Makes a photo smaller (fewer pixels, JPEG) so less has to travel over a slow line. Returns the new file, or null.
    private fun shrinkImage(path: String, maxSide: Int, quality: Int): String? {
        val bounds = BitmapFactory.Options()
        bounds.inJustDecodeBounds = true
        BitmapFactory.decodeFile(path, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
        var sample = 1
        while (maxOf(bounds.outWidth, bounds.outHeight) / (sample * 2) >= maxSide) sample *= 2
        val opts = BitmapFactory.Options()
        opts.inSampleSize = sample
        var bmp = BitmapFactory.decodeFile(path, opts) ?: return null
        val longest = maxOf(bmp.width, bmp.height)
        if (longest > maxSide) {
            val k = maxSide.toFloat() / longest
            bmp = Bitmap.createScaledBitmap(bmp, maxOf(1, (bmp.width * k).toInt()), maxOf(1, (bmp.height * k).toInt()), true)
        }
        var degrees = 0f
        try {
            val o = ExifInterface(path).getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)
            degrees = when (o) {
                ExifInterface.ORIENTATION_ROTATE_90 -> 90f
                ExifInterface.ORIENTATION_ROTATE_180 -> 180f
                ExifInterface.ORIENTATION_ROTATE_270 -> 270f
                else -> 0f
            }
        } catch (e: Throwable) {
        }
        if (degrees != 0f) {
            val m = Matrix()
            m.postRotate(degrees)
            bmp = Bitmap.createBitmap(bmp, 0, 0, bmp.width, bmp.height, m, true)
        }
        val out = File(path + ".s.jpg")
        FileOutputStream(out).use { bmp.compress(Bitmap.CompressFormat.JPEG, quality, it) }
        return out.absolutePath
    }

    // Zips made by Windows' "Send to compressed folder" store non-English file names in the old DOS code page,
    // and some tools write "folder\file". Open with UTF-8 first, fall back to CP437; names always use "/".
    private fun openZip(f: File): ZipFile {
        try {
            val z = ZipFile(f)
            try {
                val en = z.entries()
                while (en.hasMoreElements()) en.nextElement().name
                return z
            } catch (e: Exception) {
                z.close()
                throw e
            }
        } catch (e: Exception) {
            if (e is java.io.FileNotFoundException) throw e
            return ZipFile(f, Charset.forName("IBM437"))
        }
    }

    private fun norm(n: String): String = n.replace('\\', '/')

    private fun entryIndex(z: ZipFile): Map<String, ZipEntry> {
        val m = HashMap<String, ZipEntry>()
        val en = z.entries()
        while (en.hasMoreElements()) {
            val e = en.nextElement()
            m.putIfAbsent(norm(e.name), e)
        }
        return m
    }

    private fun zipScan(path: String): List<Map<String, Any>> {
        val out = ArrayList<Map<String, Any>>()
        openZip(File(path)).use { z ->
            val seen = HashSet<String>()
            val en = z.entries()
            while (en.hasMoreElements()) {
                val e = en.nextElement()
                val n = norm(e.name)
                if (!e.isDirectory && !n.endsWith("/") && seen.add(n)) out.add(mapOf("name" to n, "size" to e.size))
            }
        }
        return out
    }

    // Text of the named files. Files that are too big or look binary are left out.
    private fun zipRead(path: String, names: List<String>, maxBytes: Int): Map<String, String> {
        val out = HashMap<String, String>()
        openZip(File(path)).use { z ->
            val idx = entryIndex(z)
            for (n in names) {
                val e = idx[n] ?: continue
                if (e.isDirectory || e.size > maxBytes) continue
                val bytes = z.getInputStream(e).use { it.readBytes() }
                if (bytes.size > maxBytes || bytes.contains(0.toByte())) continue
                // The invisible UTF-8 "BOM" at the start is dropped for the AI (zipRebuild puts it back).
                val start = if (bytes.size >= 3 && bytes[0] == 0xEF.toByte() && bytes[1] == 0xBB.toByte() && bytes[2] == 0xBF.toByte()) 3 else 0
                out[n] = String(bytes, start, bytes.size - start, Charsets.UTF_8)
            }
        }
        return out
    }

    // Copies the whole original zip (node_modules, .git, pictures... everything) and swaps in the changed files.
    private fun zipRebuild(src: String, dst: String, files: Map<String, String>): Int {
        val target = File(dst)
        target.parentFile?.mkdirs()
        val left = HashMap<String, String>(files)
        val seen = HashSet<String>()
        var changed = 0
        openZip(File(src)).use { z ->
            ZipOutputStream(FileOutputStream(target).buffered()).use { out ->
                val en = z.entries()
                while (en.hasMoreElements()) {
                    val e = en.nextElement()
                    val name = norm(e.name)
                    if (!seen.add(name)) continue
                    val text = if (e.isDirectory) null else left.remove(name)
                    val ne = ZipEntry(name)
                    if (text == null && e.time > 0) ne.time = e.time
                    out.putNextEntry(ne)
                    if (!e.isDirectory) {
                        if (text != null) {
                            // Keep a UTF-8 BOM the original file had (some Windows tools need it).
                            val head = z.getInputStream(e).use { val b = ByteArray(3); val r = it.read(b); if (r == 3) b else ByteArray(0) }
                            if (head.size == 3 && head[0] == 0xEF.toByte() && head[1] == 0xBB.toByte() && head[2] == 0xBF.toByte() && !text.startsWith("\uFEFF")) out.write(head)
                            out.write(text.toByteArray(Charsets.UTF_8))
                            changed++
                        } else {
                            z.getInputStream(e).use { it.copyTo(out) }
                        }
                    }
                    out.closeEntry()
                }
                for ((name, text) in left) {
                    if (!seen.add(name)) continue
                    out.putNextEntry(ZipEntry(name))
                    out.write(text.toByteArray(Charsets.UTF_8))
                    out.closeEntry()
                    changed++
                }
            }
        }
        return changed
    }

    // A new zip from text files and binary files (an app AIy has just written).
    private fun zipCreate(dst: String, files: Map<String, String>, bytes: Map<String, ByteArray>): Int {
        val target = File(dst)
        target.parentFile?.mkdirs()
        ZipOutputStream(FileOutputStream(target).buffered()).use { out ->
            for ((name, text) in files) {
                out.putNextEntry(ZipEntry(name))
                out.write(text.toByteArray(Charsets.UTF_8))
                out.closeEntry()
            }
            for ((name, b) in bytes) {
                out.putNextEntry(ZipEntry(name))
                out.write(b)
                out.closeEntry()
            }
        }
        return files.size + bytes.size
    }

    // The bytes of one file in the zip (pictures and other binary files that are uploaded to GitHub).
    private fun zipBytes(path: String, name: String): ByteArray {
        openZip(File(path)).use { z ->
            val e = entryIndex(z)[name] ?: throw IllegalStateException("Not found in the zip: " + name)
            if (e.size > 90L * 1024 * 1024) throw IllegalStateException(name + " is bigger than 90 MB: GitHub will not take it")
            return z.getInputStream(e).use { it.readBytes() }
        }
    }

    // Takes the first file with this ending (".apk") out of a zip. Returns its path, or null.
    private fun zipExtractFirst(path: String, ext: String, dir: String): String? {
        openZip(File(path)).use { z ->
            val en = z.entries()
            while (en.hasMoreElements()) {
                val e = en.nextElement()
                if (e.isDirectory || !e.name.lowercase().endsWith(ext)) continue
                val d = File(dir)
                d.mkdirs()
                val out = File(d, e.name.substringAfterLast('/').replace(Regex("[^A-Za-z0-9._-]"), "_"))
                z.getInputStream(e).use { i -> out.outputStream().use { o -> i.copyTo(o) } }
                return out.absolutePath
            }
        }
        return null
    }

    private fun saveToDownloads(path: String, name: String): String {
        if (Build.VERSION.SDK_INT < 29) throw IllegalStateException("old-android")
        val values = ContentValues()
        values.put(MediaStore.MediaColumns.DISPLAY_NAME, name)
        values.put(MediaStore.MediaColumns.MIME_TYPE, if (name.lowercase().endsWith(".apk")) "application/vnd.android.package-archive" else "application/zip")
        values.put(MediaStore.MediaColumns.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS + "/AIy")
        val uri = contentResolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
            ?: throw IllegalStateException("Could not create the file in Downloads.")
        val stream = contentResolver.openOutputStream(uri) ?: throw IllegalStateException("Could not open the file in Downloads.")
        stream.use { o -> File(path).inputStream().use { i -> i.copyTo(o) } }
        return "Downloads/AIy/" + name
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode != pickCode) {
            super.onActivityResult(requestCode, resultCode, data)
            return
        }
        val res = pendingPick ?: return
        pendingPick = null
        val any = pendingAny
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            res.success(null)
            return
        }
        Thread {
            try {
                var name = "project.zip"
                contentResolver.query(uri, null, null, null, null)?.use { c ->
                    val col = c.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    if (col >= 0 && c.moveToFirst()) name = c.getString(col) ?: name
                }
                val dir = File(cacheDir, if (any) "picked_files" else "picked")
                dir.mkdirs()
                dir.listFiles()?.forEach { it.delete() }
                val out = File(dir, if (any) name.replace(Regex("[^A-Za-z0-9._-]"), "_") else "source.zip")
                val input = contentResolver.openInputStream(uri) ?: throw IllegalStateException("Could not open the file.")
                input.use { i -> out.outputStream().use { o -> i.copyTo(o) } }
                val value = mapOf("path" to out.absolutePath, "name" to name, "size" to out.length())
                runOnUiThread { res.success(value) }
            } catch (e: Throwable) {
                val msg = e.message ?: e.toString()
                runOnUiThread { res.error("pickZip", msg, null) }
            }
        }.start()
    }
}
'@

$WorkServiceKotlin = @'
// aiy-work-service: generated by the setup wizard (do not edit).
// A foreground service: while AIy works (a long answer, writing an app, a build, waiting for the internet) it shows
// the "AIy is working" notification, so Android keeps the app running in the background.
package {PKG}

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager

class AIyWorkService : Service() {
    private var wake: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == "aiy.stop") {
            MainActivity.instance?.workStopped()
            stopSelf()
            return START_NOT_STICKY
        }
        val title = intent?.getStringExtra("title") ?: "AIy is working"
        val text = intent?.getStringExtra("text") ?: ""
        try {
            show(title, text)
        } catch (e: Throwable) {
            stopSelf()
        }
        return START_NOT_STICKY
    }

    private fun show(title: String, text: String) {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= 26) nm.createNotificationChannel(NotificationChannel("aiy_work", "AIy working", NotificationManager.IMPORTANCE_LOW))
        val open = packageManager.getLaunchIntentForPackage(packageName) ?: Intent()
        val openPi = PendingIntent.getActivity(this, 0, open, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val stopIntent = Intent(this, AIyWorkService::class.java).setAction("aiy.stop")
        val stopPi = PendingIntent.getService(this, 1, stopIntent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val b = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, "aiy_work") else Notification.Builder(this)
        val stat = resources.getIdentifier("ic_stat_aiy", "drawable", packageName)
        b.setContentTitle(title)
            .setContentText(text)
            .setStyle(Notification.BigTextStyle().bigText(text))
            .setSmallIcon(if (stat != 0) stat else applicationInfo.icon)
            .setContentIntent(openPi)
            .setOngoing(true)
            .addAction(0, "Stop", stopPi)
        val n = b.build()
        try {
            if (Build.VERSION.SDK_INT >= 29) startForeground(7001, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC) else startForeground(7001, n)
        } catch (e: Exception) {
            // Android 12+ refuses a foreground service started from the background, and Android 15 limits dataSync
            // to about 6 hours a day. Without the service the work goes on while AIy is open; never crash for it.
            android.util.Log.w("AIy", "foreground service refused: " + e)
            stopSelf()
            return
        }
        if (wake == null) {
            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
            val w = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "aiy:work")
            w.setReferenceCounted(false)
            wake = w
        }
        // Kept awake only while the notification is up; refreshed by every update, never longer than 30 minutes at a time.
        wake?.acquire(30 * 60 * 1000L)
    }

    // Android 15: the daily dataSync time is used up. The service must stop at once, or Android ends the app.
    override fun onTimeout(startId: Int, fgsType: Int) {
        android.util.Log.w("AIy", "foreground service time limit reached")
        stopSelf()
    }

    override fun onTimeout(startId: Int) {
        stopSelf()
    }

    override fun onDestroy() {
        try {
            val w = wake
            if (w != null && w.isHeld) w.release()
        } catch (e: Throwable) {
        }
        super.onDestroy()
    }
}
'@

$FilePathsXml = @'
<?xml version="1.0" encoding="utf-8"?>
<!-- aiy-file-paths: generated by the setup wizard. Where the downloaded update APK lives. -->
<paths>
    <cache-path name="aiy_updates" path="updates/" />
    <files-path name="aiy_app_updates" path="../app_flutter/aiy/updates/" />
</paths>
'@

$FileProviderKotlin = @'
// aiy-file-provider: generated by the setup wizard (do not edit).
// Own subclass so the manifest merger does not clash with the FileProviders of other plugins.
package {PKG}

import androidx.core.content.FileProvider

class AIyFileProvider : FileProvider()
'@

$AppKotlin = @'
// aiy-app: generated by the setup wizard (do not edit).
// Catches any crash and shows it on screen (CrashActivity) instead of just closing.
package {PKG}

import android.app.Application
import android.content.Intent
import android.os.Build
import android.os.Process
import java.io.File
import java.io.PrintWriter
import java.io.StringWriter
import kotlin.system.exitProcess

class AIyApp : Application() {
    override fun onCreate() {
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, error ->
            try {
                val sw = StringWriter()
                error.printStackTrace(PrintWriter(sw))
                val text = "AIy crash report\n" +
                    Build.MANUFACTURER + " " + Build.MODEL + " - Android " + Build.VERSION.RELEASE +
                    " (SDK " + Build.VERSION.SDK_INT + ")\n" +
                    "Thread: " + thread.name + "\n\n" + sw.toString()
                File(filesDir, "last-crash.txt").writeText(text)
                val intent = Intent(this, CrashActivity::class.java)
                    .putExtra("text", text)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
                startActivity(intent)
                Process.killProcess(Process.myPid())
                exitProcess(10)
            } catch (t: Throwable) {
                previous?.uncaughtException(thread, error)
            }
        }
        super.onCreate()
    }
}
'@

$CrashKotlin = @'
// aiy-crash: generated by the setup wizard (do not edit).
// Plain Android screen (no Flutter) that shows the crash text with Copy / Share buttons.
package {PKG}

import android.app.Activity
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.graphics.Typeface
import android.os.Bundle
import android.widget.Button
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast
import java.io.File

class CrashActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val text = intent.getStringExtra("text")
            ?: File(filesDir, "last-crash.txt").let { if (it.exists()) it.readText() else "No crash report found." }
        val pad = (16 * resources.displayMetrics.density).toInt()
        val root = LinearLayout(this)
        root.orientation = LinearLayout.VERTICAL
        root.setPadding(pad, pad * 2, pad, pad)
        root.setBackgroundColor(Color.parseColor("#FF0B1026"))
        val title = TextView(this)
        title.text = "AIy stopped - please send this report"
        title.setTextColor(Color.WHITE)
        title.textSize = 18f
        title.setTypeface(null, Typeface.BOLD)
        root.addView(title)
        val row = LinearLayout(this)
        row.orientation = LinearLayout.HORIZONTAL
        val copy = Button(this)
        copy.text = "Copy"
        copy.setOnClickListener {
            val cm = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
            cm.setPrimaryClip(ClipData.newPlainText("AIy crash", text))
            Toast.makeText(this, "Copied", Toast.LENGTH_SHORT).show()
        }
        val share = Button(this)
        share.text = "Share"
        share.setOnClickListener {
            val send = Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, text)
            startActivity(Intent.createChooser(send, "AIy crash"))
        }
        val retry = Button(this)
        retry.text = "Retry"
        retry.setOnClickListener {
            startActivity(Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK))
            finish()
        }
        row.addView(copy)
        row.addView(share)
        row.addView(retry)
        root.addView(row)
        val body = TextView(this)
        body.text = text
        body.setTextColor(Color.parseColor("#FFE0F2F1"))
        body.textSize = 12f
        body.typeface = Typeface.MONOSPACE
        body.setTextIsSelectable(true)
        val scroll = ScrollView(this)
        scroll.addView(body)
        root.addView(scroll, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 0, 1f))
        setContentView(root)
    }
}
'@

function Get-MainActivityInfo {
  $main = Join-Path (Join-Path (Join-Path (Join-Path $AppDir 'android') 'app') 'src') 'main'
  foreach ($sub in @('kotlin', 'java')) {
    $root = Join-Path $main $sub
    if (-not (Test-Path $root)) { continue }
    $f = Get-ChildItem -Path $root -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq 'MainActivity.kt' -or $_.Name -eq 'MainActivity.java' } | Select-Object -First 1
    if ($f) {
      $m = [regex]::Match([IO.File]::ReadAllText($f.FullName), '(?m)^\s*package\s+([A-Za-z0-9_.]+)')
      if ($m.Success) { return @{ Dir = $f.DirectoryName; Package = $m.Groups[1].Value; Main = $main } }
    }
  }
  return $null
}

function Get-WidgetFiles {
  $mi = Get-MainActivityInfo
  if ($null -eq $mi) { return $null }
  $res = Join-Path $mi.Main 'res'
  return [ordered]@{
    (Join-Path $mi.Dir 'MainActivity.kt') = ($MainActivityKotlin -replace '\{PKG\}', $mi.Package)
    (Join-Path $mi.Dir 'AIyApp.kt') = ($AppKotlin -replace '\{PKG\}', $mi.Package)
    (Join-Path $mi.Dir 'CrashActivity.kt') = ($CrashKotlin -replace '\{PKG\}', $mi.Package)
    (Join-Path (Join-Path $res 'xml') 'aiy_file_paths.xml') = $FilePathsXml
    (Join-Path $mi.Dir 'AIyFileProvider.kt') = ($FileProviderKotlin -replace '\{PKG\}', $mi.Package)
    (Join-Path $mi.Dir 'AIyWorkService.kt') = ($WorkServiceKotlin -replace '\{PKG\}', $mi.Package)
  }
}

function Write-WidgetFiles {
  $files = Get-WidgetFiles
  if ($null -eq $files) { throw 'MainActivity not found - cannot add the native Android files.' }
  foreach ($k in $files.Keys) { Write-TextFile $k (([string]$files[$k]) -replace "`r`n", "`n") }
}

function Test-WidgetFiles {
  $files = Get-WidgetFiles
  if ($null -eq $files) { return $false }
  foreach ($k in $files.Keys) {
    if (-not (Test-Path $k)) { return $false }
    if (([IO.File]::ReadAllText($k) -replace "`r`n", "`n") -ne (([string]$files[$k]) -replace "`r`n", "`n")) { return $false }
  }
  return $true
}

function Get-ResOverlay {
  $src = Join-Path $PSScriptRoot 'android-res'
  $dst = Join-Path (Join-Path (Join-Path (Join-Path $AppDir 'android') 'app') 'src') 'main'
  return @{ Src = $src; Dst = (Join-Path $dst 'res') }
}

function Get-FileSha([string]$path) {
  $sha = [Security.Cryptography.SHA256]::Create()
  $fs = [IO.File]::OpenRead($path)
  try { return ([BitConverter]::ToString($sha.ComputeHash($fs)) -replace '-', '') } finally { $fs.Dispose() }
}

function Copy-AndroidRes {
  $o = Get-ResOverlay
  if (-not (Test-Path $o.Src)) { throw ('Icon resources missing: ' + $o.Src) }
  foreach ($f in (Get-ChildItem -Path $o.Src -Recurse -File)) {
    $rel = $f.FullName.Substring($o.Src.Length).TrimStart('\', '/')
    $to = Join-Path $o.Dst $rel
    $dir = Split-Path -Parent $to
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    Copy-Item -Force $f.FullName $to
  }
}

function Test-AndroidRes {
  $o = Get-ResOverlay
  if (-not (Test-Path $o.Src)) { return $false }
  foreach ($f in (Get-ChildItem -Path $o.Src -Recurse -File)) {
    $rel = $f.FullName.Substring($o.Src.Length).TrimStart('\', '/')
    $to = Join-Path $o.Dst $rel
    if (-not (Test-Path $to)) { return $false }
    if ((Get-FileSha $f.FullName) -ne (Get-FileSha $to)) { return $false }
  }
  return $true
}

function Update-TextFileKeepEol([string]$path, [scriptblock]$transform) {
  $raw = [IO.File]::ReadAllText($path)
  $crlf = $raw.Contains("`r`n")
  $new = & $transform $raw
  if ($crlf) { $new = ($new -replace "`r`n", "`n") -replace "`n", "`r`n" }
  if ($new -ne $raw) { Write-TextFile $path $new; return $true }
  return $false
}

function Get-GradleFiles {
  $android = Join-Path $AppDir 'android'
  $appK = Join-Path (Join-Path $android 'app') 'build.gradle.kts'
  $appG = Join-Path (Join-Path $android 'app') 'build.gradle'
  $rootK = Join-Path $android 'build.gradle.kts'
  $rootG = Join-Path $android 'build.gradle'
  $r = @{ Android = $android; App = ''; AppKts = $false; Root = ''; RootKts = $false }
  if (Test-Path $appK) { $r.App = $appK; $r.AppKts = $true } elseif (Test-Path $appG) { $r.App = $appG }
  if (Test-Path $rootK) { $r.Root = $rootK; $r.RootKts = $true } elseif (Test-Path $rootG) { $r.Root = $rootG }
  return $r
}

function Invoke-GradlePatches {
  $g = Get-GradleFiles
  if (-not $g.App -or -not $g.Root) { throw 'Android Gradle files not found - the Flutter project was not created.' }
  $kts = $g.AppKts
  [void](Update-TextFileKeepEol $g.App { param($s) Update-AppGradleText $s $kts $Package })
  $rk = $g.RootKts
  [void](Update-TextFileKeepEol $g.Root { param($s) Update-RootGradleText $s $rk })
  Write-TextFile (Join-Path $g.Android 'aiy-sdk-hook.gradle') ($SdkHookScript -replace "`r`n", "`n")
  $mf = Get-ManifestPath
  if (-not (Test-Path $mf)) { throw ('AndroidManifest.xml not found: ' + $mf) }
  [void](Update-TextFileKeepEol $mf { param($s) Update-ManifestText $s })
  Write-WidgetFiles
  Copy-AndroidRes
}

function Test-GradlePatches {
  $g = Get-GradleFiles
  if (-not $g.App -or -not $g.Root) { return $false }
  if (-not (Test-AppGradleText ([IO.File]::ReadAllText($g.App)) $g.AppKts $Package)) { return $false }
  if (-not (Test-RootGradleText ([IO.File]::ReadAllText($g.Root)))) { return $false }
  if (-not (Test-Path (Join-Path $g.Android 'aiy-sdk-hook.gradle'))) { return $false }
  $mf = Get-ManifestPath
  if (-not (Test-Path $mf)) { return $false }
  if (-not (Test-ManifestText ([IO.File]::ReadAllText($mf)))) { return $false }
  if (-not (Test-WidgetFiles)) { return $false }
  return (Test-AndroidRes)
}

# ------------------------------------------------------------------ JDK (re-detected before EVERY build)
function Get-JavaMajor([string]$javaExe) {
  $r = Invoke-Native $javaExe @('-version')
  if ($r.Out -match 'version "(\d+)(?:\.(\d+))?') {
    $m = [int]$Matches[1]
    if ($m -eq 1 -and $Matches[2]) { $m = [int]$Matches[2] }
    return $m
  }
  return 0
}

function Find-Jdk {
  $c = New-Object System.Collections.Generic.List[string]
  if ($env:AIY_JDK_CANDIDATES) { foreach ($x in ($env:AIY_JDK_CANDIDATES -split ';')) { if ($x) { $c.Add($x) } } }
  if ($env:JAVA_HOME) { $c.Add($env:JAVA_HOME) }
  if ($OnWindows) {
    $u = [Environment]::GetEnvironmentVariable('JAVA_HOME', 'User'); if ($u) { $c.Add($u) }
    $mach = [Environment]::GetEnvironmentVariable('JAVA_HOME', 'Machine'); if ($mach) { $c.Add($mach) }
    foreach ($root in @((Join-Path $env:ProgramFiles 'Microsoft'), (Join-Path $env:ProgramFiles 'Eclipse Adoptium'), (Join-Path $env:ProgramFiles 'Java'), (Join-Path $env:ProgramFiles 'Zulu'))) {
      if (Test-Path $root) { Get-ChildItem -Path $root -Directory -ErrorAction SilentlyContinue | ForEach-Object { $c.Add($_.FullName) } }
    }
    $c.Add((Join-Path $env:ProgramFiles 'Android\Android Studio\jbr'))
  }
  $best = ''
  $bestMajor = 0
  $seen = @{}
  foreach ($dir in $c) {
    if ($seen.ContainsKey($dir)) { continue }
    $seen[$dir] = $true
    $java = Get-BinPath $dir 'java' '.exe'
    if (-not (Test-Path $java)) { continue }   # removed / broken folder
    $m = Get-JavaMajor $java
    if ($m -lt 17) { continue }
    if ($m -eq 17) { return $dir }
    if (-not $best -or $m -lt $bestMajor) { $best = $dir; $bestMajor = $m }
  }
  return $best
}

function Ensure-Jdk {
  $j = Find-Jdk
  if (-not $j) {
    Warn 'No working JDK 17+ found - installing Microsoft OpenJDK 17.'
    [void](Install-Winget 'Microsoft.OpenJDK.17')
    $j = Find-Jdk
  }
  if (-not $j) { throw 'JDK 17 could not be found after installing it. Reboot Windows and run again.' }
  $env:JAVA_HOME = $j
  if ($OnWindows) { [Environment]::SetEnvironmentVariable('JAVA_HOME', $j, 'User') }
  Update-SessionPath
  $f = Get-FlutterExe
  if ($f) { [void](Invoke-Native $f @('config', '--jdk-dir', $j)) }
  Ok ('JDK: ' + $j)
  return $j
}

# ------------------------------------------------------------------ keystore
function Get-KeystoreSha1 {
  $kt = Get-Keytool
  $pw = Get-St 'storePass'
  if (-not $kt -or -not $pw -or -not (Test-Path $KeystorePath)) { return '' }
  $r = Invoke-Native $kt @('-list', '-v', '-keystore', $KeystorePath, '-alias', $KeyAlias, '-storepass', $pw)
  $m = [regex]::Match($r.Out, 'SHA1:\s*([0-9A-Fa-f]{2}(?::[0-9A-Fa-f]{2}){19})')
  if ($m.Success) { return $m.Groups[1].Value.ToUpper() }
  return ''
}

function Write-KeyProperties {
  $pw = Get-St 'storePass'
  $store = $KeystorePath -replace '\\', '/'
  $txt = "storePassword=$pw`nkeyPassword=$pw`nkeyAlias=$KeyAlias`nstoreFile=$store`n"
  Write-TextFile (Join-Path (Join-Path $AppDir 'android') 'key.properties') $txt
}

function Backup-Keystore {
  if (-not (Test-Path $KeystorePath)) { return }
  New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null
  Copy-Item -Force $KeystorePath (Join-Path $BackupDir 'aiy-release.jks')
  $info = "KEEP THIS FOLDER SAFE (USB / cloud). Without it you can never update the installed app.`r`n" +
    "Keystore: aiy-release.jks`r`nAlias: $KeyAlias`r`nPassword (store and key): $(Get-St 'storePass')`r`nSHA-1: $(Get-St 'sha1')`r`n"
  Write-TextFile (Join-Path $BackupDir 'KEYSTORE-PASSWORD-PRIVATE.txt') $info
}

function Ensure-Keystore {
  if (-not (Test-Path $KeystorePath)) {
    $bk = Join-Path $BackupDir 'aiy-release.jks'
    $bkInfo = Join-Path $BackupDir 'KEYSTORE-PASSWORD-PRIVATE.txt'
    if ((Test-Path $bk) -and (Test-Path $bkInfo)) {
      Warn 'Keystore missing in the work folder - restoring it from the backup (same key = updates keep working).'
      New-Item -ItemType Directory -Force -Path $KeyDir | Out-Null
      Copy-Item -Force $bk $KeystorePath
      $m = [regex]::Match([IO.File]::ReadAllText($bkInfo), 'Password \(store and key\):\s*(\S+)')
      if ($m.Success) { Set-St 'storePass' $m.Groups[1].Value }
    }
  }
  if (-not (Test-Path $KeystorePath)) {
    Info 'Creating your release signing key (one time).'
    New-Item -ItemType Directory -Force -Path $KeyDir | Out-Null
    $pw = New-RandomString 20 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789'
    Set-St 'storePass' $pw
    $kt = Get-Keytool
    if (-not $kt) { throw 'keytool not found (part of the JDK).' }
    $r = Invoke-Native $kt @('-genkeypair', '-v', '-keystore', $KeystorePath, '-storetype', 'PKCS12', '-keyalg', 'RSA', '-keysize', '2048',
      '-validity', '10000', '-alias', $KeyAlias, '-storepass', $pw, '-keypass', $pw, '-dname', 'CN=AIy, O=Home, C=AE')
    if ($r.Code -ne 0) { throw ('keytool failed: ' + $r.Out) }
  }
  $sha = Get-KeystoreSha1
  if ($sha) { Set-St 'sha1' $sha }
  Backup-Keystore
}

# ------------------------------------------------------------------ app source
# "1.6.0" from "version: 1.6.0+1" in a pubspec.yaml ('?' when it cannot be read).
function Get-PubspecVersion([string]$path) {
  try {
    $m = [regex]::Match([IO.File]::ReadAllText($path), '(?m)^version:\s*([0-9][^\s+]*)')
    if ($m.Success) { return $m.Groups[1].Value }
  } catch { }
  return '?'
}

function Sync-AppSource {
  $src = Join-Path $BundleRoot 'app'
  if (-not (Test-Path $src)) { throw ('App source folder not found: ' + $src) }
  Info ('App code comes from: ' + $src + '   (AIy version ' + (Get-PubspecVersion (Join-Path $src 'pubspec.yaml')) + ')')
  New-Item -ItemType Directory -Force -Path $AppDir | Out-Null
  foreach ($item in @('lib', 'test', 'assets')) {
    $s = Join-Path $src $item
    if (Test-Path $s) {
      $d = Join-Path $AppDir $item
      if (Test-Path $d) { Remove-Item -Recurse -Force $d }
      Copy-Item -Recurse -Force $s $d
    }
  }
  foreach ($f in @('pubspec.yaml', 'analysis_options.yaml', 'firebase.json')) {
    $s = Join-Path $src $f
    if (Test-Path $s) { Copy-Item -Force $s (Join-Path $AppDir $f) }
  }
  # the copied lib/ has the placeholders - put the real config back
  if (Get-St 'cfg') { Write-FirebaseConfigFiles (Get-St 'cfg') }
  Write-OwnerConfig
}

# ------------------------------------------------------------------ owner config (GitHub sign-in button)
# "Connect GitHub" in the app uses GitHub's device sign-in. That needs the public Client ID of a GitHub OAuth app
# (no secret). Without it the app still works: people paste a GitHub token instead.
function Get-DartLiteral([string]$s) { return "'" + ($s -replace '\\', '\\' -replace "'", "\'" -replace '\$', '\$') + "'" }

function Write-OwnerConfig {
  $id = [string](Get-St 'ghClientId')
  $txt = "// GENERATED by the AIy setup wizard. Do not edit.`nclass OwnerConfig {`n  /// Public Client ID of the owner's GitHub OAuth app (device flow). Empty = people paste a token instead.`n  static const String githubClientId = " + (Get-DartLiteral $id) + ";`n}`n"
  Write-TextFile (Join-Path (Join-Path $AppDir 'lib') 'owner_config.dart') $txt
}

function Test-OwnerConfig {
  if (-not (Get-St 'ghClientAsked')) { return $false }
  $p = Join-Path (Join-Path $AppDir 'lib') 'owner_config.dart'
  if (-not (Test-Path $p)) { return $false }
  return ([IO.File]::ReadAllText($p)).Contains((Get-DartLiteral ([string](Get-St 'ghClientId'))))
}

function Ask-GitHubClientId {
  if (-not (Get-St 'ghClientAsked')) {
    Say '' 'White'
    Say 'OPTIONAL - one-tap "Connect GitHub" button (about 2 minutes, one time)' 'Cyan'
    Info '1) Open github.com/settings/developers  ->  OAuth Apps  ->  New OAuth App.'
    Info '2) Application name: AIy.  Homepage URL and Authorization callback URL: https://github.com  (any address works).'
    Info '3) Tick "Enable Device Flow", click Register application, then copy the "Client ID" (starts with Ov or Iv).'
    Info 'Leave empty to skip: people can then paste a GitHub token in the app instead.'
    Open-Url 'https://github.com/settings/developers'
    $id = ([string](Ask 'GitHub OAuth Client ID (Enter = skip)')).Trim()
    Set-St 'ghClientId' $id
    Set-St 'ghClientAsked' $true
  }
  Write-OwnerConfig
}

function Test-FlutterProject {
  return ((Test-Path (Join-Path (Join-Path $AppDir 'lib') 'main.dart')) -and (Get-GradleFiles).App -ne '')
}

function New-FlutterProject {
  $f = Get-FlutterExe
  if (-not $f) { throw 'Flutter is not installed.' }
  Sync-AppSource
  Info 'Creating the Android project around the app code (flutter create)...'
  $r = Invoke-Native $f @('create', '--org', 'com.aiy', '--project-name', 'aiy', '--platforms', 'android', '.') -Cwd $AppDir -Stream
  if ($r.Code -ne 0) { throw ('flutter create failed: ' + $r.Out) }
}

# ------------------------------------------------------------------ Firebase CLI
function Get-FirebaseAccount {
  $r = Invoke-Native $FirebaseExe @('login:list', '--json')
  # The CLI can print the account list and then a SECOND json block ({"status":"error","error":"Timed out."}),
  # so the output is not one valid JSON document and the exit code is not 0. The account is still in the text.
  $m0 = [regex]::Match($r.Out, '"email"\s*:\s*"([^"\s]+@[^"\s]+)"')
  if ($m0.Success) { return $m0.Groups[1].Value }
  $j = ConvertFrom-JsonLoose $r.Out
  if ($j -and $j.result) {
    foreach ($a in @($j.result)) { if ($a -and $a.user -and $a.user.email) { return [string]$a.user.email } }
  }
  $m = [regex]::Match($r.Out, 'Logged in as\s+(\S+@\S+)')
  if ($m.Success) { return $m.Groups[1].Value }
  return ''
}

function Get-ConsoleUrl([string]$path) {
  $u = 'https://console.firebase.google.com/project/' + $Script:Project + '/' + $path
  if ($Script:Account) { $u = $u + '?authuser=' + [uri]::EscapeDataString($Script:Account) }
  return $u
}

function Get-CloudUrl([string]$path) {
  $u = 'https://console.cloud.google.com/' + $path + '?project=' + $Script:Project
  if ($Script:Account) { $u = $u + '&authuser=' + [uri]::EscapeDataString($Script:Account) }
  return $u
}

function Invoke-FirebaseLogin([bool]$reauth) {
  Info 'A browser will open - sign in with the Google account that should own the Firebase project.'
  Info 'No browser, or no link shown within 20 seconds? Press Ctrl+C, double-click Sign-In-Firebase.bat (same folder as START-HERE.bat),'
  Info 'follow its 4 steps, then run START-HERE.bat again.'
  if ($reauth) { $a = @('login', '--reauth') } else { $a = @('login') }
  [void](Invoke-Interactive $FirebaseExe $a)
  $Script:Account = Get-FirebaseAccount
}

function Ensure-FirebaseLogin {
  $Script:Account = Get-FirebaseAccount
  if (-not $Script:Account) { Invoke-FirebaseLogin $false }
  if (-not $Script:Account) { throw 'Firebase CLI is not signed in. Double-click Sign-In-Firebase.bat (same folder as START-HERE.bat), then run START-HERE.bat again.' }
  Ok ('Firebase CLI uses Google account: ' + $Script:Account)
  Info 'Console pages open with ?authuser=<this account>. If a page says "project does not exist", you are viewing it with another account.'
}

function Test-ProjectReachable([string]$id) {
  if (-not $id) { return $false }
  $r = Invoke-Native $FirebaseExe @('apps:list', '--project', $id, '--json')
  if ($r.Code -eq 0) { return $true }
  $l = Invoke-Native $FirebaseExe @('projects:list', '--json')
  if ($l.Code -eq 0) {
    $j = ConvertFrom-JsonLoose $l.Out
    if ($j) { foreach ($p in @($j.result)) { if ($p -and $p.projectId -eq $id) { return $true } } }
  }
  return $false
}

function Wait-ProjectVisible([string]$id, [int]$tries) {
  for ($i = 1; $i -le $tries; $i++) {
    if (Test-ProjectReachable $id) { return $true }
    Info ('Waiting for Google to finish creating ' + $id + ' (' + $i + '/' + $tries + ')...')
    Wait-Sec 10
  }
  return $false
}

function Switch-FirebaseAccount {
  Info ('Currently signed in as: ' + $Script:Account)
  Info 'Signing out, then a browser opens: choose the Google account that OWNS the Firebase project.'
  [void](Invoke-Interactive $FirebaseExe @('logout'))
  [void](Invoke-Interactive $FirebaseExe @('login'))
  $Script:Account = Get-FirebaseAccount
  if ($Script:Account) { Ok ('Firebase CLI now uses: ' + $Script:Account); Set-St 'account' $Script:Account }
  else { Warn 'No account signed in - type L to try again.' }
}

function Ask-ExistingProject {
  Info ('Signed in as ' + $Script:Account + '. If the project belongs to another Google account, type L.')
  while ($true) {
    $id = ([string](Ask 'Paste an existing Firebase project ID (L = use another Google account, Q = quit)')).Trim()
    if ($id.ToUpper() -eq 'Q') { throw 'USER_QUIT' }
    if ($id.ToUpper() -eq 'L') { Switch-FirebaseAccount; continue }
    if (-not $id) { continue }
    if (Test-ProjectReachable $id) { return $id }
    Warn ('Project ' + $id + ' is not reachable with ' + $Script:Account + '.')
    Info 'Check the ID (Firebase console > Project settings > Project ID), or type L to sign in with the account that owns it.'
  }
}

function Get-FirebaseDebugErrors {
  $log = Join-Path $Work 'firebase-debug.log'
  if (-not (Test-Path $log)) { return '' }
  $lines = @(Get-Content -Path $log -Tail 200 -ErrorAction SilentlyContinue |
      Where-Object { $_ -match '(?i)(error|denied|terms|permission|quota|billing|PRECONDITION|FAILED_PRECONDITION|"message")' })
  return (($lines | Select-Object -Last 8) -join "`n")
}

function Test-GcpCreated([string]$out) {
  return ($out -match '(?m)^\s*[^\s\-]\s+Creating Google Cloud Platform project')
}

function Add-FirebaseToProject([string]$id) {
  $r = Invoke-Native $FirebaseExe @('projects:addfirebase', $id) -Cwd $Work -Stream
  if ($r.Code -ne 0 -and $r.Out -notmatch '(?i)already') {
    $Script:LastHint = (Get-FirebaseDebugErrors)
    return $false
  }
  return (Wait-ProjectVisible $id 6)
}

function Resume-GcpProject([string]$id) {
  Warn ('Google Cloud project ' + $id + ' exists, but Firebase could not be added to it yet.')
  Info 'Most common reason on a new account: the Firebase terms have not been accepted.'
  $dbg = Get-FirebaseDebugErrors
  if ($dbg) { Info 'From firebase-debug.log:'; foreach ($l in ($dbg -split "`n")) { Info ('  ' + $l.Trim()) } }
  $url = 'https://console.firebase.google.com/'
  if ($Script:Account) { $url = $url + '?authuser=' + [uri]::EscapeDataString($Script:Account) }
  $ok = Invoke-Manual -Title ('Add Firebase to ' + $id) -Url $url -Steps @(
    ('Check the top-right avatar is ' + $Script:Account + ' (switch account if not).'),
    'If a "Terms of service" / welcome box appears, tick the box and click Continue / Accept.',
    'Do NOT create a new project. Just close the console tab after accepting.',
    'Come back here and press Enter - the wizard adds Firebase to the existing project itself.') -Check { Add-FirebaseToProject $id }
  if ($ok) {
    Set-St 'projectId' $id
    $Script:Project = $id
    Ok ('Firebase added to ' + $id)
    return $true
  }
  return $false
}

function Ensure-Project {
  $saved = Get-St 'projectId'
  if ($saved) {
    if (Test-ProjectReachable $saved) { $Script:Project = $saved; return }
    Warn ('Saved project ' + $saved + ' is not reachable with account ' + $Script:Account + '.')
    $c = ([string](Ask 'L = log in with another account, P = paste another project ID, Q = quit')).Trim().ToUpper()
    if ($c -eq 'Q') { throw 'USER_QUIT' }
    if ($c -eq 'L') { Switch-FirebaseAccount; if (Test-ProjectReachable $saved) { $Script:Project = $saved; return } }
    $id = Ask-ExistingProject
    Set-St 'projectId' $id; $Script:Project = $id; return
  }
  $gcp = Get-St 'gcpProjectId'
  if ($gcp) {
    if (Test-ProjectReachable $gcp) { Set-St 'projectId' $gcp; $Script:Project = $gcp; return }
    if (Resume-GcpProject $gcp) { return }
    $id = Ask-ExistingProject
    Set-St 'projectId' $id; $Script:Project = $id; return
  }
  $pending = Get-St 'pendingProjectId'
  if ($pending) {
    Info ('A project was already created earlier (' + $pending + ') - waiting for it instead of creating another one.')
    if (Wait-ProjectVisible $pending 18) { Set-St 'projectId' $pending; $Script:Project = $pending; return }
    Warn ('Project ' + $pending + ' is still not visible.')
    $id = Ask-ExistingProject
    Set-St 'projectId' $id; $Script:Project = $id; return
  }
  $relogged = $false
  $id = 'aiy-' + (New-RandomString 6 'abcdefghijkmnpqrstuvwxyz23456789')
  while ($true) {
    Info ('Creating Firebase project ' + $id + ' (one time)...')
    $r = Invoke-Native $FirebaseExe @('projects:create', $id, '--display-name', 'AIy') -Cwd $Work -Stream
    if ($r.Code -eq 0) {
      Set-St 'pendingProjectId' $id     # remember BEFORE waiting: never create twice
      if (-not (Wait-ProjectVisible $id 18)) {
        Warn 'The project was created but is not visible yet (Google lags). Re-run START-HERE in a few minutes; it will NOT create another one.'
        throw ('Project ' + $id + ' not visible yet.')
      }
      Set-St 'projectId' $id; $Script:Project = $id
      Ok ('Created project ' + $id)
      return
    }
    $out = $r.Out
    if (Test-GcpCreated $out) {
      Set-St 'gcpProjectId' $id     # never create a second one
      if (Resume-GcpProject $id) { return }
      $p = Ask-ExistingProject
      Set-St 'projectId' $p; $Script:Project = $p; return
    }
    $dbg = Get-FirebaseDebugErrors
    if ($dbg) { Info 'From firebase-debug.log:'; foreach ($l in ($dbg -split "`n")) { Info ('  ' + $l.Trim()) } }
    if ($out -match '(?i)(project quota|quota exceeded|too many projects|exceeded your quota|project limit)') {
      Warn 'Google refused to create another project (project quota reached). Earlier attempts may already have created one: reuse it.'
      Info 'See your projects: https://console.firebase.google.com  (or run: firebase projects:list). Paste the ID of the one named AIy.'
      Info 'Open https://console.firebase.google.com, pick or create a project there, and paste its ID.'
      $p = Ask-ExistingProject
      Set-St 'projectId' $p; $Script:Project = $p; return
    }
    if ($out -match '(?i)already exists|ALREADY_EXISTS|not available|is taken') {
      if (Get-St 'replacementUsed') { Warn 'The project ID is taken again.'; $p = Ask-ExistingProject; Set-St 'projectId' $p; $Script:Project = $p; return }
      Set-St 'replacementUsed' $true
      $id = 'aiy-' + (New-RandomString 8 'abcdefghijkmnpqrstuvwxyz23456789')
      Warn ('ID taken - trying ONE replacement: ' + $id)
      continue
    }
    if (($out -match '(?i)permission|PERMISSION_DENIED|403|credential|authenticat|login') -and -not $relogged) {
      Warn 'Permission error from Google.'
      $c = ([string](Ask 'L = log in again (another account?), P = paste existing project ID, Q = quit')).Trim().ToUpper()
      if ($c -eq 'Q') { throw 'USER_QUIT' }
      if ($c -eq 'L') { Switch-FirebaseAccount; $relogged = $true; continue }
      $p = Ask-ExistingProject; Set-St 'projectId' $p; $Script:Project = $p; return
    }
    Fail ('Project creation failed: ' + $out)
    $p = Ask-ExistingProject
    Set-St 'projectId' $p; $Script:Project = $p; return
  }
}

function Get-AndroidAppId {
  $r = Invoke-Native $FirebaseExe @('apps:list', 'ANDROID', '--project', $Script:Project, '--json')
  if ($r.Code -ne 0) { return '' }
  $j = ConvertFrom-JsonLoose $r.Out
  if ($null -eq $j) { return '' }
  foreach ($a in @($j.result)) { if ($a -and $a.packageName -eq $Package) { return [string]$a.appId } }
  return ''
}

function Ensure-AndroidApp {
  $id = Get-AndroidAppId
  if (-not $id) {
    Info ('Registering Android app ' + $Package + '...')
    $r = Invoke-Native $FirebaseExe @('apps:create', 'ANDROID', 'AIy', '--package-name', $Package, '--project', $Script:Project, '--json')
    if ($r.Code -ne 0) { throw ('apps:create failed: ' + $r.Out) }
    for ($i = 0; $i -lt 12 -and -not $id; $i++) { $id = Get-AndroidAppId; if (-not $id) { Wait-Sec 5 } }
  }
  if ($id) { Set-St 'appId' $id }
}

function Test-ShaRegistered {
  $sha = Get-St 'sha1'; $app = Get-St 'appId'
  if (-not $sha -or -not $app) { return $false }
  $r = Invoke-Native $FirebaseExe @('apps:android:sha:list', $app, '--project', $Script:Project)
  if ($r.Code -ne 0) { return $false }
  $want = ($sha -replace ':', '').ToLower()
  $have = ($r.Out -replace ':', '').ToLower()
  return $have.Contains($want)
}

function Register-Sha {
  $r = Invoke-Native $FirebaseExe @('apps:android:sha:create', (Get-St 'appId'), (Get-St 'sha1'), '--project', $Script:Project)
  if ($r.Code -ne 0 -and $r.Out -notmatch '(?i)already exists') { Warn ('SHA-1 registration said: ' + $r.Out) }
  Wait-Sec 3
}

# ------------------------------------------------------------------ config generation (no flutterfire_cli)
function Get-SdkConfig {
  $r = Invoke-Native $FirebaseExe @('apps:sdkconfig', 'ANDROID', (Get-St 'appId'), '--project', $Script:Project, '--json')
  if ($r.Code -ne 0) { return $null }
  $j = ConvertFrom-JsonLoose $r.Out
  if ($null -eq $j -or $null -eq $j.result) { return $null }
  $contents = $j.result.fileContents
  if ($contents -is [string]) { try { return ($contents | ConvertFrom-Json) } catch { return $null } }
  return $contents
}

function ConvertTo-FirebaseCfg($gs, [string]$pkg) {
  if ($null -eq $gs) { return $null }
  $client = $null
  foreach ($c in @($gs.client)) {
    if ($c -and $c.client_info -and $c.client_info.android_client_info -and $c.client_info.android_client_info.package_name -eq $pkg) { $client = $c }
  }
  if ($null -eq $client) { return $null }
  $web = ''
  foreach ($o in @($client.oauth_client)) { if ($o -and [int]$o.client_type -eq 3) { $web = [string]$o.client_id } }
  if (-not $web -and $client.services -and $client.services.appinvite_service) {
    foreach ($o in @($client.services.appinvite_service.other_platform_oauth_client)) { if ($o -and [int]$o.client_type -eq 3) { $web = [string]$o.client_id } }
  }
  $bucket = ''
  if ($gs.project_info.storage_bucket) { $bucket = [string]$gs.project_info.storage_bucket }
  return @{
    apiKey = [string](@($client.api_key)[0].current_key)
    appId = [string]$client.client_info.mobilesdk_app_id
    senderId = [string]$gs.project_info.project_number
    projectId = [string]$gs.project_info.project_id
    bucket = $bucket
    webClientId = $web
    json = ($gs | ConvertTo-Json -Depth 20)
  }
}

function Get-DartString([string]$s) { return "'" + ($s -replace '\\', '\\' -replace "'", "\'" -replace '\$', '\$') + "'" }

function New-FirebaseOptionsDart($cfg) {
  return @"
// GENERATED by the AIy setup wizard from ``firebase apps:sdkconfig``. Do not edit.
import 'package:firebase_core/firebase_core.dart';

class DefaultFirebaseOptions {
  static const FirebaseOptions currentPlatform = FirebaseOptions(
    apiKey: $(Get-DartString $cfg.apiKey),
    appId: $(Get-DartString $cfg.appId),
    messagingSenderId: $(Get-DartString $cfg.senderId),
    projectId: $(Get-DartString $cfg.projectId),
    storageBucket: $(Get-DartString $cfg.bucket),
  );

  /// OAuth "web" client id (client_type 3) used by Google Sign-In.
  static const String googleWebClientId = $(Get-DartString $cfg.webClientId);
}
"@
}

function Write-FirebaseConfigFiles($cfg) {
  Write-TextFile (Join-Path (Join-Path $AppDir 'lib') 'firebase_options.dart') ((New-FirebaseOptionsDart $cfg) -replace "`r`n", "`n")
  $gsPath = Join-Path (Join-Path (Join-Path $AppDir 'android') 'app') 'google-services.json'
  if (Test-Path (Split-Path -Parent $gsPath)) { Write-TextFile $gsPath ([string]$cfg.json) }
}

function Update-FirebaseConfig {
  $gs = Get-SdkConfig
  $cfg = ConvertTo-FirebaseCfg $gs $Package
  if ($null -eq $cfg) { throw 'Could not read the app config from Firebase (apps:sdkconfig).' }
  Set-St 'cfg' $cfg
  Write-FirebaseConfigFiles $cfg
  return $cfg
}

function Test-FirebaseConfigFile {
  $p = Join-Path (Join-Path $AppDir 'lib') 'firebase_options.dart'
  if (-not (Test-Path $p)) { return $false }
  $t = [IO.File]::ReadAllText($p)
  $cfg = Get-St 'cfg'
  if ($null -eq $cfg) { return $false }
  return ($t -notmatch 'REPLACE_ME' -and $t.Contains([string]$cfg.apiKey) -and $t.Contains([string]$cfg.projectId))
}

# ------------------------------------------------------------------ Google APIs (best effort via firebase-tools token)
function Get-GoogleAccessToken {
  if ($env:AIY_FIREBASE_CONFIG) { $cfgPath = $env:AIY_FIREBASE_CONFIG }
  else { $cfgPath = Join-Path (Join-Path (Join-Path $HOME '.config') 'configstore') 'firebase-tools.json' }
  if (-not (Test-Path $cfgPath)) { return '' }
  try { $j = Get-Content -Raw -Path $cfgPath | ConvertFrom-Json } catch { return '' }
  if ($null -eq $j.tokens -or -not $j.tokens.refresh_token) { return '' }
  $r = Invoke-Http -Method 'POST' -Uri 'https://oauth2.googleapis.com/token' -Form @{
    grant_type = 'refresh_token'; refresh_token = [string]$j.tokens.refresh_token; client_id = $FbClientId; client_secret = $FbClientSecret
  }
  if ($r.Json -and $r.Json.access_token) { return [string]$r.Json.access_token }
  return ''
}

function Test-ApiEnabled([string]$api, [string]$tok) {
  $r = Invoke-Http -Uri ('https://serviceusage.googleapis.com/v1/projects/' + $Script:Project + '/services/' + $api) -Headers @{ Authorization = 'Bearer ' + $tok }
  return ($r.Json -and $r.Json.state -eq 'ENABLED')
}

function Enable-GoogleApis([string[]]$apis) {
  $tok = Get-GoogleAccessToken
  if (-not $tok) { Warn 'Could not get a Google token from firebase-tools - APIs will be checked by the next steps.'; return $false }
  $all = $true
  foreach ($api in $apis) {
    if (Test-ApiEnabled $api $tok) { Ok ($api + ' enabled'); continue }
    Info ('Enabling ' + $api + '...')
    $base = 'https://serviceusage.googleapis.com/v1/projects/' + $Script:Project + '/services/' + $api
    $e = Invoke-Http -Method 'POST' -Uri ($base + ':enable') -Headers @{ Authorization = 'Bearer ' + $tok } -Body @{}
    $done = $false
    for ($i = 0; $i -lt 12; $i++) { if (Test-ApiEnabled $api $tok) { $done = $true; break }; Wait-Sec 5 }
    if ($done) { Ok ($api + ' enabled') }
    else {
      $all = $false
      Warn ($api + ' not enabled yet: ' + (Get-ApiError $e))
      $null = Invoke-Manual -Title ('Enable ' + $api) -Url (Get-CloudUrl ('apis/library/' + $api)) -Steps @(
        ('Make sure the top bar shows project ' + $Script:Project + ' and account ' + $Script:Account + '.'),
        'Click the blue "Enable" button and wait until the page shows "API enabled".') -Check { Test-ApiEnabled $api $tok }
    }
  }
  return $all
}

# ------------------------------------------------------------------ Firestore + rules




function Get-FileHashText([string]$path) {
  $sha = [Security.Cryptography.SHA256]::Create()
  $bytes = [Text.Encoding]::UTF8.GetBytes(([IO.File]::ReadAllText($path) -replace "`r`n", "`n"))
  return ([BitConverter]::ToString($sha.ComputeHash($bytes)) -replace '-', '')
}





# ------------------------------------------------------------------ Auth
function Get-AndroidHeaders {
  return @{ 'X-Android-Package' = $Package; 'X-Android-Cert' = ((Get-St 'sha1') -replace ':', '').ToUpper() }
}

function Get-IdentityUrl([string]$path) {
  $cfg = Get-St 'cfg'
  return ('https://identitytoolkit.googleapis.com/v1/' + $path + '?key=' + $cfg.apiKey)
}





function Test-GoogleAuthEnabled {
  $Script:LastHint = ''
  $tok = Get-GoogleAccessToken
  if ($tok) {
    $h = @{ Authorization = 'Bearer ' + $tok; 'x-goog-user-project' = $Script:Project }
    $r = Invoke-Http -Uri ('https://identitytoolkit.googleapis.com/admin/v2/projects/' + $Script:Project + '/defaultSupportedIdpConfigs/google.com') -Headers $h
    if ($r.Json -and $r.Json.enabled -eq $true) {
      $cfg = ConvertTo-FirebaseCfg (Get-SdkConfig) $Package
      if ($cfg -and $cfg.webClientId) { return $true }
      $Script:LastHint = 'Google is enabled, but the web client ID is not in the app config yet.'
      return $false
    }
    if ($r.Status -eq 200 -or $r.Status -eq 404) { $Script:LastHint = 'Google provider is still off.'; return $false }
  }
  # fallback: the web OAuth client appears in the app config once Google is enabled
  $cfg = ConvertTo-FirebaseCfg (Get-SdkConfig) $Package
  if ($cfg -and $cfg.webClientId) { return $true }
  $Script:LastHint = 'No Google web client in the app config yet.'
  return $false
}

function Enable-GoogleAuth {
  if (-not (Test-GoogleAuthEnabled)) {
    $null = Invoke-Manual -Title 'Turn on Google sign-in' -Url (Get-ConsoleUrl 'authentication/providers') -Steps @(
      'If you see a "Get started" button, click it first.',
      'Click "Google" in the list (or "Add new provider", then "Google").',
      'Switch the "Enable" toggle ON.',
      ('Pick a "Project support email" (your Gmail ' + $Script:Account + ').'),
      'Click Save.') -Check { Test-GoogleAuthEnabled }
  }
  [void](Update-FirebaseConfig)
}

function Test-GoogleConfigReady {
  $cfg = Get-St 'cfg'
  return ($cfg -and $cfg.webClientId -and (Test-FirebaseConfigFile))
}

# ------------------------------------------------------------------ accounts via REST




# ------------------------------------------------------------------ live rules test










# ------------------------------------------------------------------ user accounts (optional)




# ------------------------------------------------------------------ build
$KnownOverrides = @{ 'record_linux' = '1.1.1' }

function Add-DependencyOverride([string]$name, [string]$ver) {
  $p = Join-Path $AppDir 'pubspec.yaml'
  $t = [IO.File]::ReadAllText($p) -replace "`r`n", "`n"
  if ($t -match ('(?m)^\s+' + [regex]::Escape($name) + ':')) { if ($t -match '(?m)^dependency_overrides:') { return } }
  if ($t -notmatch '(?m)^dependency_overrides:') { $t = $t.TrimEnd() + "`n`ndependency_overrides:`n" }
  $t = $t.TrimEnd() + "`n  " + $name + ': ' + $ver + "`n"
  Write-TextFile $p $t
  Info ('Added dependency override ' + $name + ': ' + $ver)
}

function Invoke-PubGet([string]$f) {
  $r = Invoke-Native $f @('pub', 'get') -Cwd $AppDir -Stream
  if ($r.Code -eq 0) { return }
  foreach ($k in $KnownOverrides.Keys) { if ($r.Out -match [regex]::Escape($k)) { Add-DependencyOverride $k $KnownOverrides[$k] } }
  Warn 'pub get failed - trying to upgrade package versions.'
  $null = Invoke-Native $f @('pub', 'upgrade', '--major-versions', 'firebase_core', 'firebase_auth', 'google_sign_in', 'local_auth', 'flutter_lints', 'shared_preferences', 'provider') -Cwd $AppDir -Stream
  $r = Invoke-Native $f @('pub', 'get') -Cwd $AppDir -Stream
  if ($r.Code -ne 0) {
    Write-BuildError $r.Lines 'flutter pub get'
    throw 'Downloading Dart packages failed - see Output\build-error.txt.'
  }
}

function Get-BuildHints([string]$text) {
  $h = @()
  if ($text -match '(?i)Unsupported class file major version|Could not determine java version|JAVA_HOME is set to an invalid|requires Java 17|Java 17') { $h += 'Java/JDK problem: run Rebuild again (the JDK is re-detected each time). If it repeats, uninstall old JDKs.' }
  if ($text -match '(?i)License for package .+ not accepted|You have not accepted the license agreements') { $h += 'Android SDK licenses not accepted: run START-HERE option 1 (it accepts them).' }
  if ($text -match '(?i)Could not (resolve|GET|download)|Connection (timed out|refused|reset)|UnknownHostException|PKIX') { $h += 'Network problem downloading build files (proxy, VPN, firewall or SSL inspection). Try another network.' }
  if ($text -match '(?i)compileSdk|android-36|checkDebugAarMetadata|checkReleaseAarMetadata|requires libraries and applications that depend on it to compile against version') { $h += 'Android SDK level problem: run START-HERE option 3 (Health check) - it verifies platform android-36 and the compileSdk hook.' }
  if ($text -match '(?i)coreLibraryDesugaring|desugar') { $h += 'Desugaring problem: the Gradle patch may have been undone. Rebuild re-applies it; if it repeats, send build-error.txt.' }
  if ($text -match '(?i)minSdk(Version)? \d+ cannot be smaller|uses-sdk:minSdkVersion') { $h += 'minSdk problem: Rebuild re-applies minSdk 24.' }
  if ($text -match '(?i)Script compilation error|build\.gradle(\.kts)?:\d+:\d+: Unresolved reference') { $h += 'Android build-file (Gradle) error: run Rebuild again - the wizard re-checks and rewrites its build-file changes. If it repeats, send build-error.txt.' }
  if ($text -match '(?i)Keystore was tampered|password was incorrect|keystore.*not found|Failed to read key') { $h += 'Signing key problem: key.properties does not match the keystore. Do NOT create a new key; send setup.log.' }
  if ($text -match '(?i)Filename too long|path too long|MAX_PATH') { $h += 'Windows path too long: keep the work folder at C:\AIyBuild.' }
  if ($text -match '(?i)No space left|not enough space') { $h += 'Disk is full: free at least 10 GB.' }
  if ($text -match '(?i)version solving failed') { $h += 'Dart package versions conflict: send build-error.txt.' }
  if ($text -match '(?i)\berror\b.*\.dart:\d+') { $h += 'Dart code error in the app: send build-error.txt and analyze-report.txt.' }
  return $h
}

function Write-BuildError([string[]]$lines, [string]$what) {
  $errs = @($lines | Where-Object { $_ -match '(?i)(\berror\b|FAILURE:|What went wrong|Exception:|\* Error)' -and $_ -notmatch '(?i)RemoteException' })
  $tail = @($lines | Select-Object -Last 150)
  $hints = Get-BuildHints ($lines -join "`n")
  $txt = @('AIY BUILD ERROR - ' + $what, (Get-Date -Format 's'), '')
  if ($hints.Count -gt 0) { $txt += 'WHAT IT PROBABLY MEANS:'; foreach ($x in $hints) { $txt += ('  - ' + $x) }; $txt += '' }
  $txt += '=== ERROR LINES ==='
  $txt += ($errs | Select-Object -First 80)
  $txt += ''
  $txt += '=== LAST 150 LINES ==='
  $txt += $tail
  Write-TextFile (Join-Path $OutDir 'build-error.txt') ($txt -join "`r`n")
  Fail ($what + ' failed.')
  if ($hints.Count -gt 0) { foreach ($x in $hints) { Warn $x } } else { Info 'No known cause matched - please send Output\build-error.txt.' }
  foreach ($e in ($errs | Select-Object -First 8)) { Info $e }
}

function Invoke-Analyze([string]$f) {
  Info 'Checking the code (flutter analyze)...'
  $r = Invoke-Native $f @('analyze', '--no-fatal-infos', '--no-fatal-warnings') -Cwd $AppDir
  Write-TextFile (Join-Path $OutDir 'analyze-report.txt') ($r.Lines -join "`r`n")
  $errs = @($r.Lines | Where-Object { $_ -match '^\s*error\s*[•-]' })
  if ($errs.Count -gt 0) {
    Fail ('The code has ' + $errs.Count + ' error(s) - see Output\analyze-report.txt')
    foreach ($e in ($errs | Select-Object -First 10)) { Info $e }
    return $false
  }
  Ok 'Code check passed (warnings/infos, if any, are in analyze-report.txt).'
  return $true
}

# ------------------------------------------------------------------ built-in Kotlin
# Flutter warns "plugins that apply Kotlin Gradle Plugin (KGP)" while the app still uses the old Kotlin plugin.
# With Flutter 3.47+ and Android Gradle Plugin 9+, Kotlin comes from AGP itself: the app drops kotlin-android,
# gradle.properties says android.builtInKotlin=true, and every plugin (updated ones and the local copies in
# app\packages) stops applying KGP. Skipped on older Flutter / AGP, or when AIY_NO_BUILTIN_KOTLIN is set.
function Get-AgpMajor {
  $android = Join-Path $AppDir 'android'
  foreach ($n in @('settings.gradle.kts', 'settings.gradle')) {
    $p = Join-Path $android $n
    if (Test-Path $p) {
      $m = [regex]::Match([IO.File]::ReadAllText($p), 'com\.android\.application["'']\s*\)?\s*version\s*["''](\d+)\.')
      if ($m.Success) { return [int]$m.Groups[1].Value }
    }
  }
  return 0
}

function Update-AppGradleBuiltInKotlin([string]$text) {
  $t = $text -replace "`r`n", "`n"
  if ($t -match 'aiy-builtin-kotlin') { return $t }
  # keep the app's Java level for Kotlin (JavaVersion.VERSION_17 -> JVM_17, VERSION_1_8 -> JVM_1_8)
  $jvm = 'JVM_17'
  $jm = [regex]::Match($t, 'jvmTarget\s*=\s*JavaVersion\.VERSION_(\d+)(?:_(\d+))?')
  if ($jm.Success) { if ($jm.Groups[2].Success) { $jvm = 'JVM_' + $jm.Groups[1].Value + '_' + $jm.Groups[2].Value } else { $jvm = 'JVM_' + $jm.Groups[1].Value } }
  $t = [regex]::Replace($t, '(?m)^[ \t]*id\(\s*["'']?(?:kotlin-android|org\.jetbrains\.kotlin\.android)["'']?\s*\)[^\n]*\n', '')
  $t = [regex]::Replace($t, '(?m)^[ \t]*id\s+["''](?:kotlin-android|org\.jetbrains\.kotlin\.android)["''][^\n]*\n', '')
  $t = [regex]::Replace($t, '(?m)^[ \t]*apply plugin:\s*["'']kotlin-android["''][^\n]*\n', '')
  $t = [regex]::Replace($t, '(?ms)^[ \t]*kotlinOptions\s*\{[^{}]*\}[ \t]*\n?', '')
  $block = "`n// aiy-builtin-kotlin: Kotlin comes from the Android Gradle Plugin (android.builtInKotlin=true)`nkotlin {`n    compilerOptions {`n        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget." + $jvm + "`n    }`n}`n"
  return ($t.TrimEnd() + "`n" + $block)
}

function Update-GradlePropertiesBuiltInKotlin([string]$text) {
  $t = $text -replace "`r`n", "`n"
  if ($t -match '(?m)^android\.builtInKotlin\s*=') { return [regex]::Replace($t, '(?m)^android\.builtInKotlin\s*=.*$', 'android.builtInKotlin=true') }
  return ($t.TrimEnd() + "`nandroid.builtInKotlin=true`n")
}

function Enable-BuiltInKotlin {
  if ($env:AIY_NO_BUILTIN_KOTLIN) { Info 'Built-in Kotlin: skipped (AIY_NO_BUILTIN_KOTLIN is set).'; return }
  try {
    $f = Get-FlutterExe
    $r = Invoke-Native $f @('--version')
    $v = Get-FlutterVersion $r.Out
    if ($null -eq $v -or $v -lt [version]'3.47.0') { Warn 'Built-in Kotlin needs Flutter 3.47+ - skipped (the Kotlin warnings stay; the build still works).'; return }
    $agp = Get-AgpMajor
    if ($agp -lt 9) { Info ('Built-in Kotlin: this Android project uses Android Gradle Plugin ' + $agp + ' (needs 9+) - skipped.'); return }
    $g = Get-GradleFiles
    if (-not $g.App) { return }
    $props = Join-Path $g.Android 'gradle.properties'
    foreach ($file in @($props, $g.App)) {
      if ((Test-Path $file) -and -not (Test-Path ($file + '.aiy-bak'))) { Copy-Item -Force $file ($file + '.aiy-bak') }
    }
    if (Test-Path $props) { [void](Update-TextFileKeepEol $props { param($s) Update-GradlePropertiesBuiltInKotlin $s }) }
    else { Write-TextFile $props "android.builtInKotlin=true`n" }
    [void](Update-TextFileKeepEol $g.App { param($s) Update-AppGradleBuiltInKotlin $s })
    Ok 'Built-in Kotlin is on (no more "plugins that apply KGP" warning). To undo: set AIY_NO_BUILTIN_KOTLIN=1 and restore the .aiy-bak files in C:\AIyBuild\app\android.'
  } catch {
    Warn ('Built-in Kotlin could not be enabled (' + $_.Exception.Message + ') - building without it.')
  }
}

function Invoke-Build {
  Head 'Building the APK'
  [void](Ensure-Jdk)
  $f = Get-FlutterExe
  if (-not $f) { throw 'Flutter not found - run START-HERE option 1.' }
  if (-not (Test-FlutterVersion)) {
    Warn ('Flutter must be ' + $MinFlutter + ' or newer - upgrading the stable channel.')
    [void](Invoke-Native $f @('upgrade', '--force') -Stream)
    if (-not (Test-FlutterVersion)) { throw 'Flutter could not be upgraded to 3.47+.' }
  }
  if (Test-GradlePatches) { Ok 'Android build files: verified.' }
  else {
    Info 'Android build files need (re)patching - applying the current version...'
    Invoke-GradlePatches
    if (-not (Test-GradlePatches)) { throw 'Gradle patches could not be applied/verified.' }
    Ok 'Android build files: repaired and verified.'
  }
  Enable-BuiltInKotlin
  # A failed build must never leave an OLD apk that looks like the new one.
  foreach ($stale in @('AIy-latest.apk')) {
    $sp = Join-Path $OutDir $stale
    if (Test-Path $sp) { Remove-Item -Force $sp }
  }
  Ensure-Keystore
  Write-KeyProperties
  if (-not (Test-FirebaseConfigFile)) { if (Get-St 'cfg') { Write-FirebaseConfigFiles (Get-St 'cfg') } }
  if (-not (Test-FirebaseConfigFile)) { throw 'lib/firebase_options.dart has no real Firebase values - run START-HERE option 1.' }
  Invoke-PubGet $f
  if (-not (Invoke-Analyze $f)) {
    $c = ([string](Ask 'Build anyway? (y/N)')).Trim().ToUpper()
    if ($c -ne 'Y') { throw 'Stopped because of code errors (see Output\analyze-report.txt). NO new APK was made - send me that file.' }
  }
  $n = 1
  if (Get-St 'buildNumber') { $n = [int](Get-St 'buildNumber') + 1 }
  Info ('Building release APK #' + $n + '. The FIRST build takes 10-20 minutes (downloads Gradle and Android parts). Later builds: 2-5 minutes.')
  $r = Invoke-Native $f @('build', 'apk', '--release', '--no-shrink', '--build-number', [string]$n) -Cwd $AppDir -Stream
  $apk = Join-Path $AppDir 'build\app\outputs\flutter-apk\app-release.apk'
  if (-not $OnWindows) { $apk = Join-Path $AppDir 'build/app/outputs/flutter-apk/app-release.apk' }
  if ($r.Code -ne 0 -or -not (Test-Path $apk)) {
    Write-BuildError $r.Lines 'flutter build apk'
    throw 'Build failed - see Output\build-error.txt (send it together with setup.log).'
  }
  Set-St 'buildNumber' $n
  New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
  $ver = Get-PubspecVersion (Join-Path $AppDir 'pubspec.yaml')
  $named = Join-Path $OutDir ('AIy-' + $ver + '-build' + $n + '.apk')
  Copy-Item -Force $apk $named
  Copy-Item -Force $apk (Join-Path $OutDir 'AIy-latest.apk')
  $err = Join-Path $OutDir 'build-error.txt'
  if (Test-Path $err) { Remove-Item -Force $err }
  Ok ('APK ready: ' + $named)
  Ok ('This is AIy ' + $ver + '. After installing, Settings > About must show version ' + $ver + '. If it shows another number, the old app is still installed or the app folder next to START-HERE.bat is old.')
  Set-St 'lastBuildOk' $true
}

# ------------------------------------------------------------------ output files
# ------------------------------------------------------------------ in-app updates (Firebase Hosting)
# After every build the wizard puts the APK and a small version.json on Firebase Hosting
# (https://PROJECT.web.app/update/). The app checks it and offers "Update available". Free (Spark plan).
# Set AIY_NO_PUBLISH=1 to skip; AIY_MIN_BUILD=N makes every older build ask for the update as required.
function Get-LatestChangeNotes {
  $p = Join-Path $BundleRoot 'CHANGES.md'
  if (-not (Test-Path $p)) { return '' }
  $t = ([IO.File]::ReadAllText($p) -replace "`r`n", "`n")
  $m = [regex]::Match($t, '(?s)\n## ([^\n]*)\n(.*?)(?=\n## |\z)')
  if (-not $m.Success) { return '' }
  $n = ($m.Groups[1].Value + "`n" + $m.Groups[2].Value).Trim()
  if ($n.Length -gt 1800) { $n = $n.Substring(0, 1800) + '...' }
  return $n
}

# Firebase Hosting on the free (Spark) plan REFUSES .apk files ("Executable files are forbidden"), so the APK itself
# is stored as a GitHub Release (free, public repository). Hosting only keeps version.json and the landing page.
function Initialize-GitHubTarget {
  $repo = [string](Get-St 'ghRepo')
  $tok = [string](Get-St 'ghToken')
  if ($repo -and $tok) { return @{ Repo = $repo; Token = $tok } }
  Say '' 'White'
  Say 'FREE UPDATES - one-time setup (about 2 minutes)' 'Cyan'
  Info 'Firebase Hosting (free plan) does not accept APK files, so the APK is stored on GitHub Releases (free).'
  Info '1) github.com > New repository. Name: aiy-updates. Public. Tick "Add a README file". Create repository.'
  Info '2) github.com/settings/personal-access-tokens/new  ->  Repository access: Only select repositories > aiy-updates;'
  Info '   Permissions > Repository permissions > Contents: Read and write.  Generate token and copy it.'
  Info 'The token stays on this computer. Leave the first answer empty to skip (phones then get no in-app updates).'
  $r = ([string](Ask 'GitHub repository as owner/name (for example badert/aiy-updates)')).Trim()
  if (-not $r) { return $null }
  $t = ([string](Ask 'GitHub token (starts with github_pat_)')).Trim()
  if (-not $t) { return $null }
  $r = $r -replace '^https?://github\.com/', ''
  $r = $r -replace '\.git$', ''
  $r = $r.Trim('/')
  Set-St 'ghRepo' $r
  Set-St 'ghToken' $t
  return @{ Repo = $r; Token = $t }
}

# Uploads the APK as a release asset and returns its public download address ('' when it did not work).
function Publish-ApkToGitHub([string]$apkPath, [string]$apkName, [string]$tag, [string]$title, [string]$notes) {
  $gh = Initialize-GitHubTarget
  if ($null -eq $gh) { return '' }
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  $oldPref = $ProgressPreference
  $ProgressPreference = 'SilentlyContinue'
  try {
    $h = @{ Authorization = ('Bearer ' + $gh.Token); 'User-Agent' = 'AIyWizard'; Accept = 'application/vnd.github+json'; 'X-GitHub-Api-Version' = '2022-11-28' }
    $api = 'https://api.github.com/repos/' + $gh.Repo
    try { $repoInfo = Invoke-RestMethod -Method Get -Uri $api -Headers $h -TimeoutSec 60 }
    catch {
      Warn ('GitHub says: ' + $_.Exception.Message + ' - check the repository name and the token (it is asked again next time).')
      Set-St 'ghToken' ''
      return ''
    }
    if ($repoInfo.private) {
      Warn 'The GitHub repository is PRIVATE, so phones could not download from it. Make it public: repository Settings > General > Danger Zone > Change visibility.'
      return ''
    }
    # Already uploaded (a retry of the same build)? Then reuse it instead of uploading again.
    $rel = $null
    try { $rel = Invoke-RestMethod -Method Get -Uri ($api + '/releases/tags/' + $tag) -Headers $h -TimeoutSec 60 } catch { $rel = $null }
    if ($rel) {
      foreach ($a in @($rel.assets)) {
        if ($a -and [string]$a.name -eq $apkName -and [string]$a.state -eq 'uploaded') {
          Info 'This build is already on GitHub - using it.'
          return [string]$a.browser_download_url
        }
      }
    }
    Info ('Uploading the APK to GitHub (' + $gh.Repo + ') - about 2 minutes...')
    if (-not $rel) {
      $payload = ConvertTo-Json -InputObject @{ tag_name = $tag; name = $title; body = $notes; draft = $false; prerelease = $false }
      $bytes = [Text.Encoding]::UTF8.GetBytes($payload)
      $rel = Invoke-RestMethod -Method Post -Uri ($api + '/releases') -Headers $h -Body $bytes -ContentType 'application/json; charset=utf-8' -TimeoutSec 120
    }
    $upl = ([string]$rel.upload_url) -replace '\{.*$', ''
    $asset = Invoke-RestMethod -Method Post -Uri ($upl + '?name=' + [uri]::EscapeDataString($apkName)) -Headers $h -ContentType 'application/vnd.android.package-archive' -InFile $apkPath -TimeoutSec 3600
    return [string]$asset.browser_download_url
  } catch {
    Warn ('Could not upload the APK to GitHub: ' + $_.Exception.Message)
    return ''
  } finally {
    $ProgressPreference = $oldPref
  }
}

function Publish-Update {
  if ($env:AIY_NO_PUBLISH) { Info 'Update publishing skipped (AIY_NO_PUBLISH is set).'; return }
  $apk = Join-Path $OutDir 'AIy-latest.apk'
  if (-not (Test-Path $apk)) { return }
  if (-not $Script:Project) { $Script:Project = [string](Get-St 'projectId') }
  if (-not $Script:Project) { Warn 'No Firebase project known - the update was not published.'; return }
  try {
    $acct = Get-FirebaseAccount
    if (-not $acct) { Warn 'Firebase CLI is not logged in - the update was NOT published. Run START-HERE option 3 (Health check), then Rebuild.'; return }
    $ver = Get-PubspecVersion (Join-Path $AppDir 'pubspec.yaml')
    $n = [int](Get-St 'buildNumber')
    $fj = Join-Path $AppDir 'firebase.json'
    if (-not (Test-Path $fj) -or ([IO.File]::ReadAllText($fj) -notmatch '"hosting"')) { Warn 'firebase.json has no hosting section - copy the new app folder next to START-HERE.bat. Update not published.'; return }
    $apkName = 'AIy-' + $ver + '-build' + $n + '.apk'
    $notes = Get-LatestChangeNotes
    # 1) the APK goes to GitHub Releases
    $apkUrl = Publish-ApkToGitHub $apk $apkName ('v' + $ver + '-build' + $n) ('AIy ' + $ver + ' (build ' + $n + ')') $notes
    if (-not $apkUrl) {
      Warn 'The update was NOT published (no APK address). Phones can still use AIy-latest.apk. Run Rebuild again after fixing the message above.'
      return
    }
    # 2) version.json and the landing page go to Firebase Hosting (small files, allowed on the free plan)
    $site = Join-Path $AppDir 'hosting'
    if (Test-Path $site) { Remove-Item -Recurse -Force $site }
    $upd = Join-Path $site 'update'
    New-Item -ItemType Directory -Force -Path $upd | Out-Null
    $minBuild = 0
    if ($env:AIY_MIN_BUILD) { try { $minBuild = [int]$env:AIY_MIN_BUILD } catch { $minBuild = 0 } }
    $info = [ordered]@{
      versionName = $ver; build = $n; apk = $apkUrl
      sha256 = (Get-FileSha $apk).ToLower(); size = (Get-Item $apk).Length
      minBuild = $minBuild; date = (Get-Date).ToString('yyyy-MM-dd'); notes = $notes
    }
    $enc = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText((Join-Path $upd 'version.json'), (ConvertTo-Json -InputObject $info -Depth 4), $enc)
    $base = 'https://' + $Script:Project + '.web.app'
    $html = @"
<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>AIy</title>
<style>body{font-family:system-ui,sans-serif;margin:0;background:#0b1026;color:#e8ebff;text-align:center}
main{max-width:420px;margin:0 auto;padding:48px 24px}h1{font-size:2rem;margin:0 0 4px}
a.btn{display:block;margin:24px 0 12px;padding:18px;border-radius:16px;background:#4f6bff;color:#fff;font-size:1.2rem;text-decoration:none}
p{line-height:1.6;color:#b9c0e6}small{color:#8a92bd}</style></head>
<body><main>
<h1>AIy</h1>
<p>Version $ver</p>
<a class="btn" href="$apkUrl">Download</a>
<p>Open the downloaded file and tap Install. If Android asks, allow installing from this browser.</p>
<small>Already installed? AIy updates itself: Settings &rarr; About &rarr; Check for updates.</small>
</main></body></html>
"@
    [IO.File]::WriteAllText((Join-Path $site 'index.html'), $html, $enc)
    Info ('Publishing the version file to ' + $base + ' ...')
    $dep = @('deploy', '--only', 'hosting', '--project', $Script:Project, '--non-interactive')
    $r = $null
    $tries = 0
    while ($true) {
      $tries++
      $r = Invoke-Native $FirebaseExe $dep -Cwd $AppDir -Stream
      if ($r.Code -eq 0) { break }
      if ($r.Out -match '(?i)no hosting|site .* not found|has not been set up') {
        Info 'Creating the Firebase Hosting site (first time only)...'
        [void](Invoke-Native $FirebaseExe @('hosting:sites:create', $Script:Project, '--project', $Script:Project, '--non-interactive') -Cwd $AppDir)
        $r = Invoke-Native $FirebaseExe $dep -Cwd $AppDir -Stream
        if ($r.Code -eq 0) { break }
      }
      # "Failed to get Firebase project", time-outs and resets are usually the network (or an expired sign-in): try again.
      if ($tries -ge 3) { break }
      Info ('Firebase did not answer (try ' + $tries + ' of 3) - waiting a few seconds and trying again...')
      Start-Sleep -Seconds 8
    }
    if ($r.Code -ne 0) {
      Warn 'The version file could not be published. The APK is already on GitHub, so nothing is lost.'
      Info ('Firebase account signed in here: ' + $acct + '   project: ' + $Script:Project)
      Info 'If the account is not the one that owns this project, or the error says "Failed to get Firebase project": run START-HERE option 3 (Health check) to sign in again.'
      Info 'Then double-click Publish-Update.bat (it publishes the last build again WITHOUT rebuilding).'
      return
    }
    Set-St 'updatePublishedBuild' $n
    $msgEn = "AIy $ver is ready. Open this link on your phone: $base`r`nIf AIy is already installed it updates itself (Settings > About > Check for updates)."
    Write-TextFile (Join-Path $OutDir 'Update-link.txt') $msgEn
    Ok ('Update published: ' + $base + '   (AIy ' + $ver + ' build ' + $n + ')')
    Info 'Phones with AIy see "Update available" the next time the app opens. New phones: send them that link (Output\Update-link.txt).'
  } catch {
    Warn ('The update could not be published: ' + $_.Exception.Message)
  }
}

function Write-OutputFiles {
  New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
  Backup-Keystore
  $en = @"
Hi! Here is AIy, a personal AI assistant and coding helper.

1) Install the file AIy-latest.apk I sent you. If Android asks, allow "Install unknown apps" for the app you opened it from (WhatsApp / Files).
2) Open AIy and tap "Continue with Google".
3) Follow the short setup inside the app: it connects your free AI accounts step by step (Gemini, OpenRouter, and optionally Groq and GitHub). Use the same Google account everywhere.

Your keys stay on your phone only.
"@
  Write-TextFile (Join-Path $OutDir 'Message-to-users.txt') ($en -replace "`r?`n", "`r`n")
}

function Show-FinalScreen {
  Head 'ALL DONE'
  Ok ('Output folder: ' + $OutDir)
  Info 'AIy-latest.apk              -> install on the phones'
  Info 'Message-to-users.txt        -> ready to send with the APK'
  Info 'keystore-backup\            -> COPY TO USB/CLOUD. Needed for every future update.'
  Say ''
  Say 'TEST CHECKLIST' 'Cyan'
  $items = @(
    'Install the APK. Tap "Continue with Google".',
    'Setup inside the app: Gemini (copy the key, come back - AIy picks it up from the clipboard), OpenRouter (Connect), optional Groq and GitHub. Each one shows a green tick after its test.',
    'Chat: ask a question; the answer should appear word by word; tap the square Stop button in the middle of a long answer (the part that arrived stays). In Settings switch on Advanced mode: a small badge under each answer then shows which provider and model answered.',
    'First start on a phone that never had AIy: after the Google sign-in three welcome screens appear; try Skip. Settings > Help > Show the welcome tour again brings them back.',
    'Share into AIy: in another app (browser, gallery, files) tap Share and pick AIy, once with text, once with a photo, once with a project zip. AIy asks Chat, Code or Build each time; try each one.',
    'Chat: long-press an answer (or tap the three dots under it) > Answer again with another model. Open the menu: make a folder with the + Folder chip, move a chat into it (three dots on the chat), long-press the folder chip to rename or delete it, and try the search box.',
    'OpenRouter pop-up: in Code pick a paid model while the OpenRouter account has no credit (or switch the internet off during a request). A pop-up must explain the problem; try Details, Copy, Retry and Switch model (the price of the new model is shown before anything is sent).',
    'Slow line: use a very slow connection (a weak hotspot, or limit the speed in the router). Ask for a long answer: AIy must wait longer instead of failing, and after two timeouts a yellow banner must say the internet is slow and offer Lite mode. Turn Lite mode on: the box says "Ask AIy (Lite mode)", photos get smaller, answers get shorter. Settings > Slow connection has the same switch. Download an update or a built APK and switch the connection off for a moment in the middle: it must continue, not start again.',
    'More free AI: in Settings > Accounts & keys connect Mistral, Cerebras, NVIDIA and Cloudflare (Cloudflare asks for the account number and the token). Each must show a green tick after its test; Settings > Help > Test everything lists them. Then in chat tap the sliders icon (Advanced mode) and choose one as "first": the answer badge shows who answered.',
    'Background: start a long Build-tab app and press Home. A quiet "AIy is working" notification must stay with the current step (for example the file being written); the work must finish while the phone is in your pocket. Tap Stop in the notification: the work ends. Also start a chat answer, switch flight mode on, close AIy from the recent apps, open it again with the internet back: the chat should ask again by itself.',
    'Internet loss: start a long chat answer, a Code patch with a paid model and a Build tab question, switch on flight mode in the middle. A red banner must say how many requests wait (open the list, try Cancel). Switch flight mode off: a notification arrives, the banner says it is sending again, and the answers come by themselves. After a paid request was lost, Settings > Spending may show a small "lost" cost.',
    'The orb: it turns fast while AIy thinks, shows rings while you use the microphone, and swells while an answer is read aloud. Build tab > Write the app and the GitHub build screen show a list of steps with ticks.',
    'Chat: attach a photo (+ button) and ask about it; switch on the globe (live search) and ask about today''s news; try the microphone.',
    'Code: pick a project zip. Check the numbers (all files -> source files), then "Explain this codebase".',
    'Code: type a small change, "Find the files", pick a model (try a free one first), confirm the cost, wait for the patch.',
    'Code: open the diff of each file, then Save to Downloads / Share the new zip. Unzip it on the PC and check it still builds.',
    'Retries (1.13.0): switch on flight mode while a Code or Build job writes: the busy text counts Try 2 of 5; after 5 tries the job waits; switch the internet on: a free job continues by itself, a paid job asks (Continue / Discard) with the price.',
    'Updates (1.12.0): publish a newer version, open AIy on Wi-Fi: the update downloads by itself (notification with %), leave AIy and come back, it continues; when done a banner with Install appears. Settings > Update shows What is new, Pause, Skip.',
    'Job pages (1.9.0): start a build, open Settings > Running and waiting: steps animate; a failed build shows the error card under the step where it stopped.',
    'GitHub build (1.8.0): push a change to a NEW branch, then Build the app: the build must start within a minute or two and download the APK.',
    'Review (1.8.0): in Code, open a changed file with several changes, turn one off, push: only the kept changes reach GitHub. Settings > Storage and Running and waiting must open.',
    'Errors (1.7.0): turn on flight mode while Code writes a paid change, close AIy, turn the internet on and open AIy: a card must ask Continue / Discard with the price. On an error card try Ask AIy and Copy report.',
    'Safe data (1.6.1): Settings > Backup > Export, then Restore the same file: it must say Restored and your chats stay. Settings > About must show 1.6.1.',
    'Settings > Help > Test everything: every line should be green (a yellow note is fine). Tap Copy the report.',
    'Chat: attach a text file and ask about it, attach a PDF, long-press your message > Edit and ask again, tap the refresh icon, the speaker icon (read aloud), the sliders icon (which AI answers); drawer > Share this chat.',
    'Settings > Security: switch the app lock on, leave AIy for the chosen time and come back; try the fingerprint; Save a backup, then Restore it.',
    'Code: add a photo of the problem to a request; Ask about it; after a push use Quick check, then break something on purpose and try Fix and rebuild automatically; Undo the push (before any build).',
    'Build a release (Version question > Also publish a GitHub Release), leave AIy while it builds (a notification should arrive), then QR code on the finished build.',
    'Build tab: tap +, explain a small app, set the question slider (try 3), choose name, icon and colours, answer the questions (tap, type, "You decide", Back), read the brief, pick a model, write the app. Check the file list and that the app shows in Code.',
    'Build tab: "Push to GitHub" (new repository) then "Build the app": the installed app must show the name, the icon and the version you chose. Open the app and try it.',
    'Build tab: leave in the middle (back arrow), come back from "Your apps and ideas" and continue where you stopped.',
    'Code > Publish: "Push to GitHub" (a zip can go to a NEW repository), then "Build the app": type the version, wait, tap Install. Check Settings > About shows that version.',
    'Build that fails on purpose (add a typo in a file by hand and push): the build screen lists the errors; "Fix it with AI" picks the files, then write the change, push and build again.',
    'History > Apps: install an older build again, share it, open its release page.',
    'History: open an older build, share it again, or use it as the new starting point.',
    'Menu > Settings: change the theme and colour; set the spending cap per request; check the daily usage numbers.',
    'Network: test on mobile data AND Wi-Fi. A VPN, work Wi-Fi or DNS filter can block Google sign-in or the AI services.',
    'If Google sign-in shows an error code, run START-HERE option 6 and send me the code.'
  )
  $i = 1
  foreach ($x in $items) { Say ('  [ ] ' + $i + '. ' + $x) 'White'; $i++ }
  Say ''
  Info ('Updates later: put the new app folder next to START-HERE.bat and double-click Rebuild-APK.bat. The wizard also publishes the update: phones with AIy offer it by themselves (Settings > About > Check for updates), and Output\Update-link.txt has the link for new phones. The same signing key is reused, so the app updates in place.')
  if ($OnWindows -and -not $TestMode) { try { Start-Process explorer.exe $OutDir } catch { } }
}

# ------------------------------------------------------------------ steps
$Steps = @(
  @{ Id = 'workdir'; Title = 'Work folder ' + $Work; Check = { Test-Path $OutDir }; Do = { New-Item -ItemType Directory -Force -Path $OutDir | Out-Null } },
  @{ Id = 'git'; Title = 'Git'; Check = { Have 'git' }; Do = { [void](Install-Winget 'Git.Git') } },
  @{ Id = 'node'; Title = 'Node.js LTS'; Check = { Have $NpmExe }; Do = { [void](Install-Winget 'OpenJS.NodeJS.LTS') } },
  @{ Id = 'jdk'; Title = 'Java JDK 17'; Check = { [bool](Find-Jdk) }; Do = { [void](Ensure-Jdk) } },
  @{ Id = 'flutter'; Title = 'Flutter SDK (stable, 3.47 or newer)'; Note = 'First run downloads ~1 GB.'
    Check = { Test-FlutterVersion }
    Do = {
      if (-not (Test-Path $FlutterDir)) {
        $r = Invoke-Native 'git' @('clone', 'https://github.com/flutter/flutter.git', '-b', 'stable', '--depth', '1', $FlutterDir) -Stream
        if ($r.Code -ne 0) { throw ('git clone of Flutter failed: ' + $r.Out) }
      }
      Update-SessionPath
      $f = Get-FlutterExe
      [void](Invoke-Native $f @('config', '--no-analytics'))
      if (-not (Test-FlutterVersion)) {
        Info 'Flutter is older than 3.47 - upgrading (stable channel)...'
        [void](Invoke-Native $f @('channel', 'stable') -Stream)
        [void](Invoke-Native $f @('upgrade', '--force') -Stream)
      }
      [void](Invoke-Native $f @('--version') -Stream)
    } },
  @{ Id = 'android-sdk'; Title = 'Android SDK (command-line tools, platform 36, build-tools)'
    Check = { (Get-SdkManager) -and (Test-Path (Join-Path (Join-Path $SdkDir 'platforms') 'android-36')) -and (Test-Path (Join-Path $SdkDir 'platform-tools')) }
    Do = {
      if (-not (Get-SdkManager)) {
        $zip = Join-Path $Work 'cmdline-tools.zip'
        $okDl = $false
        foreach ($u in $CmdlineToolsUrls) {
          try { Info ('Downloading ' + $u); Invoke-WebRequest -Uri $u -OutFile $zip -UseBasicParsing; $okDl = $true; break } catch { Warn ('Download failed: ' + $_.Exception.Message) }
        }
        if (-not $okDl) { throw 'Could not download Android command-line tools.' }
        $tmp = Join-Path $Work 'cmdline-tmp'
        if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp }
        Expand-Archive -Path $zip -DestinationPath $tmp -Force
        $dest = Join-Path (Join-Path $SdkDir 'cmdline-tools') 'latest'
        if (Test-Path $dest) { Remove-Item -Recurse -Force $dest }
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest) | Out-Null
        Move-Item (Join-Path $tmp 'cmdline-tools') $dest
        Remove-Item -Recurse -Force $tmp; Remove-Item -Force $zip
      }
      [void](Ensure-Jdk)
      $sm = Get-SdkManager
      $yes = ((1..60 | ForEach-Object { 'y' }) -join "`n")
      $args1 = @(('--sdk_root=' + $SdkDir)) + @($SdkPackages | ForEach-Object { '"' + $_ + '"' })   # literal quotes: cmd.exe splits on ';'
      $r = Invoke-Native $sm $args1 -InputText $yes -Stream
      if ($r.Code -ne 0) { Warn ('sdkmanager: ' + $r.Out) }
    } },
  @{ Id = 'licenses'; Title = 'Android SDK licenses'
    Check = { Test-Path (Join-Path (Join-Path $SdkDir 'licenses') 'android-sdk-license') }
    Do = {
      [void](Ensure-Jdk)
      $yes = ((1..60 | ForEach-Object { 'y' }) -join "`n")
      [void](Invoke-Native (Get-SdkManager) @('--licenses', ('--sdk_root=' + $SdkDir)) -InputText $yes)
      if ($OnWindows) { [Environment]::SetEnvironmentVariable('ANDROID_HOME', $SdkDir, 'User') }
      $env:ANDROID_HOME = $SdkDir
      [void](Invoke-Native (Get-FlutterExe) @('config', '--android-sdk', $SdkDir))
    } },
  @{ Id = 'firebase-tools'; Title = 'Firebase CLI'
    Check = { (Invoke-Native $FirebaseExe @('--version')).Code -eq 0 }
    Do = { $r = Invoke-Native $NpmExe @('install', '-g', 'firebase-tools') -Stream; Update-SessionPath; if ($r.Code -ne 0) { throw ('npm install firebase-tools failed: ' + $r.Out) } } },
  @{ Id = 'project-files'; Title = 'App project files'
    Check = { Test-FlutterProject }; Do = { New-FlutterProject } },
  @{ Id = 'gradle'; Title = 'Android build settings (minSdk 24, desugaring, signing, SDK 36 hook, permissions, native helpers)'
    Check = { Test-GradlePatches }; Do = { Invoke-GradlePatches } },
  @{ Id = 'keystore'; Title = 'Release signing key'
    Check = { (Test-Path $KeystorePath) -and [bool](Get-KeystoreSha1) -and (Test-Path (Join-Path $BackupDir 'aiy-release.jks')) }
    Do = { [void](Ensure-Jdk); Ensure-Keystore } },
  @{ Id = 'login'; Title = 'Firebase login'
    Check = { $Script:Account = Get-FirebaseAccount; return [bool]$Script:Account }
    Do = { Ensure-FirebaseLogin } },
  @{ Id = 'project'; Title = 'Firebase project'
    Check = { $p = Get-St 'projectId'; if ($p -and (Test-ProjectReachable $p)) { $Script:Project = $p; return $true }; return $false }
    Do = { Ensure-Project } },
  @{ Id = 'android-app'; Title = 'Android app in Firebase (' + $Package + ')'
    Check = { $id = Get-AndroidAppId; if ($id) { Set-St 'appId' $id }; return [bool]$id }
    Do = { Ensure-AndroidApp } },
  @{ Id = 'sha'; Title = 'SHA-1 fingerprint registered (needed for Google sign-in)'
    Check = { Test-ShaRegistered }; Do = { Register-Sha } },
  @{ Id = 'apis'; Title = 'Google API for sign-in (Identity Toolkit)'
    Check = { [bool](Get-St 'apisEnabled') }
    Do = { [void](Enable-GoogleApis @('identitytoolkit.googleapis.com')); Set-St 'apisEnabled' $true } },
  @{ Id = 'config'; Title = 'App config (firebase_options.dart)'
    Check = { Test-FirebaseConfigFile }; Do = { [void](Update-FirebaseConfig) } },
  @{ Id = 'auth-google'; Title = 'Google sign-in'
    Check = { Test-GoogleConfigReady }; Do = { Enable-GoogleAuth } },
  @{ Id = 'github-oauth'; Title = 'GitHub "Connect" button (optional)'
    Check = { Test-OwnerConfig }; Do = { Ask-GitHubClientId } }
)

function Invoke-FullSetup {
  Head ('AIy setup - everything is saved, you can stop and re-run any time')
  Info ('Work folder: ' + $Work + '   Log: ' + $LogPath)
  Update-SessionPath
  foreach ($s in $Steps) { Invoke-Step $s }
  Invoke-Build
  Write-OutputFiles
  Publish-Update
  Show-FinalScreen
}

function Invoke-Rebuild {
  Head 'Rebuild APK'
  Update-SessionPath
  if (-not (Get-St 'cfg') -or -not (Test-Path $AppDir)) { throw 'Setup has not been completed yet - run START-HERE option 1 first.' }
  $Script:Project = [string](Get-St 'projectId')
  Info 'Copying the latest app code from the app\ folder next to START-HERE.bat...'
  Sync-AppSource
  Invoke-Build
  Write-OutputFiles
  Publish-Update
  Ok 'Rebuild finished. Phones with AIy offer the update by themselves; new phones: Output\Update-link.txt.'
  if ($OnWindows -and -not $TestMode) { try { Start-Process explorer.exe $OutDir } catch { } }
}

# Publishes the last APK again (GitHub + Firebase Hosting) without rebuilding: for when only the publishing failed.
function Invoke-PublishOnly {
  Head 'Publish the last build (no rebuild)'
  Update-SessionPath
  if (-not (Get-St 'cfg') -or -not (Test-Path $AppDir)) { throw 'Setup has not been completed yet - run START-HERE option 1 first.' }
  $Script:Project = [string](Get-St 'projectId')
  if (-not (Test-Path (Join-Path $OutDir 'AIy-latest.apk'))) { throw 'There is no Output\AIy-latest.apk yet - run Rebuild-APK.bat first.' }
  Info ('Publishing AIy ' + (Get-PubspecVersion (Join-Path $AppDir 'pubspec.yaml')) + ' (build ' + (Get-St 'buildNumber') + ')...')
  Publish-Update
}

function Invoke-HealthCheck {
  Head 'Health check (changes nothing)'
  Update-SessionPath
  $Script:Project = [string](Get-St 'projectId')
  $jh = Find-Jdk
  if ($jh) { $env:JAVA_HOME = $jh; Update-SessionPath }
  $bad = 0
  foreach ($s in $Steps) {
    $ok = $false
    try { $ok = [bool](& $s.Check) } catch { $ok = $false }
    if ($ok) { Ok $s.Title } else { Fail $s.Title; $bad++ }
  }
  if ($jh) { Ok ('JDK found: ' + $jh) } else { Fail 'No JDK 17+ found'; $bad++ }
  if (Test-Path (Join-Path $OutDir 'AIy-latest.apk')) { Ok 'APK exists in Output' } else { Warn 'No APK built yet' }
  if ($Script:Account) { Info ('Firebase CLI account: ' + $Script:Account) }
  if ($bad -eq 0) { Ok 'Everything looks healthy.' } else { Warn ($bad.ToString() + ' item(s) need attention - option 1 repairs them.') }
}

function Invoke-FixGoogle {
  Head 'Fix Google sign-in'
  Update-SessionPath
  $Script:Project = [string](Get-St 'projectId')
  if (-not $Script:Project) { throw 'No Firebase project yet - run option 1 first.' }
  Ensure-FirebaseLogin
  [void](Ensure-Jdk)
  Ensure-Keystore
  Info ('Release key SHA-1: ' + (Get-St 'sha1'))
  Ensure-AndroidApp
  if (Test-ShaRegistered) { Ok 'SHA-1 is registered in Firebase.' } else { Register-Sha; if (Test-ShaRegistered) { Ok 'SHA-1 registered now.' } else { Fail 'SHA-1 could not be registered.' } }
  Enable-GoogleAuth
  if (Test-GoogleConfigReady) { Ok 'Google web client ID is in the app config.' } else { Fail 'Google web client ID is still missing.' }
  Info 'Error 10 = SHA-1/package not registered; 12500 = support email missing; 7 = network.'
  $c = ([string](Ask 'Rebuild the APK now with the fixed config? (Y/n)')).Trim().ToUpper()
  if ($c -ne 'N') { Invoke-Build; Write-OutputFiles; Publish-Update }
}

function Invoke-Reset {
  Head 'Reset progress'
  Info 'Every step will be re-checked next time. Your signing key and its backup are NEVER deleted.'
  $forget = ([string](Ask 'Also forget the Firebase project ID? (y/N)')).Trim().ToUpper()
  $keep = @{}
  foreach ($k in @('storePass', 'sha1', 'buildNumber', 'accounts')) { if ($Script:State.ContainsKey($k)) { $keep[$k] = $Script:State[$k] } }
  if ($forget -ne 'Y') { foreach ($k in @('projectId', 'appId', 'cfg', 'firestoreCreated')) { if ($Script:State.ContainsKey($k)) { $keep[$k] = $Script:State[$k] } } }
  $keep['done'] = @{}
  $Script:State = $keep
  Save-State
  Ok 'Progress reset.'
}

function Get-Adb {
  $p = Join-Path (Join-Path $SdkDir 'platform-tools') 'adb.exe'
  if (-not $OnWindows) { $p = Join-Path (Join-Path $SdkDir 'platform-tools') 'adb' }
  if (Test-Path $p) { return $p }
  if (Have 'adb') { return 'adb' }
  return ''
}

function Test-AdbDevice {
  $adb = Get-Adb
  if (-not $adb) { return $false }
  $r = Invoke-Native $adb @('devices')
  if ($r.Out -match '(?m)^\S+\s+unauthorized') { $Script:LastHint = 'The phone is connected but USB debugging was not allowed yet - unlock the phone and tap "Allow".' }
  return ($r.Out -match '(?m)^\S+\s+device\s*$')
}

function Invoke-CrashLog {
  Head 'Read crash log from phone (USB)'
  $adb = Get-Adb
  if (-not $adb) { throw 'adb not found - run START-HERE option 1 first (it installs the Android SDK).' }
  [void](Invoke-Native $adb @('start-server'))
  if (-not (Test-AdbDevice)) {
    $null = Invoke-Manual -Title 'Connect the phone with USB debugging' -Steps @(
      'On the phone: Settings > About phone > Software information > tap "Build number" 7 times (Developer options turn on).',
      'Settings > Developer options > switch ON "USB debugging".',
      'Connect the phone to this PC with a USB cable (a data cable, not charge-only).',
      'Unlock the phone; when it asks "Allow USB debugging?" tick "Always allow" and tap Allow.') -Check { Test-AdbDevice }
  }
  if (-not (Test-AdbDevice)) { throw 'No phone found over USB.' }
  Ok 'Phone connected.'
  $apk = Join-Path $OutDir 'AIy-latest.apk'
  if (Test-Path $apk) {
    $c = ([string](Ask 'Install the latest APK on this phone first? (Y/n)')).Trim().ToUpper()
    if ($c -ne 'N') {
      $ir = Invoke-Native $adb @('install', '-r', $apk) -Stream
      if ($ir.Code -eq 0) { Ok 'Installed.' } else { Warn ('Install said: ' + $ir.Out) }
    }
  }
  [void](Invoke-Native $adb @('logcat', '-c'))
  Info ('Starting AIy on the phone and recording for 15 seconds...')
  [void](Invoke-Native $adb @('shell', 'monkey', '-p', $Package, '-c', 'android.intent.category.LAUNCHER', '1'))
  Wait-Sec 15
  $crash = Invoke-Native $adb @('logcat', '-d', '-b', 'crash', '-v', 'time')
  $all = Invoke-Native $adb @('logcat', '-d', '-v', 'time')
  $keep = @($all.Lines | Where-Object { $_ -match '(?i)(AndroidRuntime|FATAL|flutter|aiy|Firebase|DartVM|libc\b|DEBUG\s*:|E/)' })
  $pidLine = Invoke-Native $adb @('shell', 'pidof', $Package)
  $report = @('AIY CRASH LOG - ' + (Get-Date -Format 's'), ('App running after 15 s: ' + $(if ($pidLine.Out.Trim()) { 'YES (pid ' + $pidLine.Out.Trim() + ')' } else { 'NO' })), '',
    '=== CRASH BUFFER ===') + $crash.Lines + @('', '=== ERRORS / FLUTTER / FIREBASE (filtered) ===') + ($keep | Select-Object -Last 400)
  $file = Join-Path $OutDir 'crash-log.txt'
  Write-TextFile $file ($report -join "`r`n")
  $fatal = @($crash.Lines + $keep | Where-Object { $_ -match '(?i)(FATAL EXCEPTION|Caused by|Exception:|Error:)' } | Select-Object -First 8)
  if ($fatal.Count -gt 0) { Fail 'Crash found:'; foreach ($l in $fatal) { Info $l } } else { Ok 'No crash recorded in this run.' }
  Ok ('Saved: ' + $file + '  - please send this file.')
  if ($OnWindows -and -not $TestMode) { try { Start-Process notepad.exe $file } catch { } }
}

function Show-Menu {
  while ($true) {
    Say ''
    Say '  ==============================================' 'Cyan'
    Say '     AIY - setup & build' 'Cyan'
    Say '  ==============================================' 'Cyan'
    if (Get-St 'projectId') { Info ('Project: ' + (Get-St 'projectId')) }
    Say '   1. Full setup (safe to re-run; resumes where it stopped)'
    Say '   2. Rebuild APK'
    Say '   3. Health check'
    Say '   4. Open Output folder'
    Say '   5. Reset progress'
    Say '   6. Fix Google sign-in'
    Say '   7. Read crash log from phone (USB)'
    Say '   0. Exit'
    $c = ([string](Ask 'Choose')).Trim()
    try {
      switch ($c) {
        '1' { Invoke-FullSetup }
        '2' { Invoke-Rebuild }
        '3' { Invoke-HealthCheck }
        '4' { New-Item -ItemType Directory -Force -Path $OutDir | Out-Null; if ($OnWindows -and -not $TestMode) { Start-Process explorer.exe $OutDir } else { Info $OutDir } }
        '5' { Invoke-Reset }
        '6' { Invoke-FixGoogle }
        '7' { Invoke-CrashLog }
        '0' { return }
        default { Warn 'Type a number from the menu.' }
      }
    } catch {
      if ($_.Exception.Message -eq 'USER_QUIT') { Warn 'Stopped. Progress is saved.' }
      else { Fail $_.Exception.Message; Info ('Full log: ' + $LogPath); Write-Log ($_ | Out-String) }
    }
  }
}

# ------------------------------------------------------------------ entry
if ($Mode -eq 'lib') { return }
if ($TestMode -and $env:AIY_HTTP_MOCK) { . $env:AIY_HTTP_MOCK }
Load-State
Write-Host ('AIy wizard v' + $WizardVersion) -ForegroundColor Cyan
Write-Log ('==== start wizard v' + $WizardVersion + ' mode=' + $Mode + ' PS ' + $PSVersionTable.PSVersion.ToString() + ' wizard ' + $WizardVersion + ' from ' + $PSScriptRoot)
Say ('AIy wizard v' + $WizardVersion + '  (' + $PSScriptRoot + ')') 'DarkGray'
$exit = 0
try {
  switch ($Mode) {
    'menu' { Show-Menu }
    'setup' { Invoke-FullSetup }
    'rebuild' { Invoke-Rebuild }
    'publish' { Invoke-PublishOnly }
    'health' { Invoke-HealthCheck }
    'output' { New-Item -ItemType Directory -Force -Path $OutDir | Out-Null; if ($OnWindows) { Start-Process explorer.exe $OutDir } }
    'reset' { Invoke-Reset }
    'fixgoogle' { Invoke-FixGoogle }
    'crashlog' { Invoke-CrashLog }
  }
} catch {
  if ($_.Exception.Message -eq 'USER_QUIT') { Warn 'Stopped. Progress is saved - run again to continue.'; $exit = 2 }
  else { Fail $_.Exception.Message; Info ('Full log: ' + $LogPath); Write-Log ($_ | Out-String); $exit = 1 }
}
exit $exit
