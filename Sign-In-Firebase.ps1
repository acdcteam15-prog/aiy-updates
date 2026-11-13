# Sign-In-Firebase.ps1 - signs the Firebase CLI in WITHOUT needing it to open a browser by itself.
# You open the link yourself (any browser, this PC or your phone) and paste back the code Google shows.
$ErrorActionPreference = 'Continue'
Clear-Host
Write-Host ''
Write-Host '  Sign in to Firebase (manual link method)' -ForegroundColor Cyan
Write-Host '  ----------------------------------------'
Write-Host '  1. A long link starting with https://accounts.google.com/ is printed below.'
Write-Host '  2. Select the link with the mouse and press Enter to copy it (or right-click).'
Write-Host '  3. Paste it into Chrome / Edge, sign in with the account that owns the Firebase project, click Allow.'
Write-Host '  4. Google shows a code. Copy it, paste it here when asked, press Enter.'
Write-Host ''

# Turn off the CLI's usage reporting (its network call is what ends commands with "Timed out").
try {
  $dir = Join-Path (Join-Path $HOME '.config') 'configstore'
  $cfg = Join-Path $dir 'firebase-tools.json'
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  $utf8 = New-Object System.Text.UTF8Encoding($false)
  if (-not (Test-Path $cfg)) { [IO.File]::WriteAllText($cfg, '{"usage": false}', $utf8) }
  else {
    $t = [IO.File]::ReadAllText($cfg)
    if ($t -notmatch '"usage"\s*:\s*false') {
      if ($t -match '"usage"\s*:\s*(true|false)') { $t = [regex]::Replace($t, '"usage"\s*:\s*(true|false)', '"usage": false', 1) }
      elseif ($t -match '^\s*\{\s*\}\s*$') { $t = '{"usage": false}' }
      else { $t = [regex]::Replace($t, '^\s*\{', '{ "usage": false,', 1) }
      [IO.File]::WriteAllText($cfg, $t, $utf8)
    }
  }
} catch { }

& firebase.cmd login --no-localhost

Write-Host ''
Write-Host '  Checking the sign-in...' -ForegroundColor Cyan
$out = (& firebase.cmd login:list 2>&1 | Out-String)
$m = [regex]::Match($out, 'Logged in as\s+(\S+@\S+)')
if (-not $m.Success) { $m = [regex]::Match($out, '"email"\s*:\s*"([^"\s]+@[^"\s]+)"') }
if ($m.Success) {
  Write-Host ('  SIGNED IN as ' + $m.Groups[1].Value) -ForegroundColor Green
  Write-Host '  Now run START-HERE.bat and choose option 1 again.'
} else {
  Write-Host '  Not signed in yet. Run this file again and follow the 4 steps.' -ForegroundColor Yellow
  Write-Host '  If no link was printed at all, send me exactly what the window showed (without any code).'
}
Write-Host ''
Write-Host '  Press Enter to close.'
[void](Read-Host)
