# =============================================================================
#  Truck Mount - PLAYER install (Windows). Started by install-client.bat.
#  Copies the truck patch into your WoW 3.3.5a Data folder and clears the Cache.
# =============================================================================
param([string]$Wow = "", [switch]$Uninstall)
$ErrorActionPreference = "Stop"
$Here  = Split-Path -Parent $MyInvocation.MyCommand.Path
$Patch = Join-Path $Here "patch-5.MPQ"
# every truck patch ever released (md5), so older versions get replaced, not duplicated
$Known = @("3b5052290da276b4244b9ff970de40cf","8387ac3404978353458d9d90fa792a6e","c48da617122aff79ee0b9ff9bac0f1a6",
           "f5ced18351ad483a4363be07601ded5d","fcd993c0be67705b97336d8bbdc34478")

function Step($t) { Write-Host ""; Write-Host "== $t" -ForegroundColor White }
function Ok($t)   { Write-Host $t -ForegroundColor Green }
function Warn($t) { Write-Host $t -ForegroundColor Yellow }
function Fail($t) { Write-Host ""; Write-Host "ERROR: $t" -ForegroundColor Red; exit 1 }
function Child($dir, $name) { Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -ieq $name } | Select-Object -First 1 }
function IsWow($dir) { (Test-Path -LiteralPath $dir -PathType Container) -and (Child $dir "Wow.exe") -and (Child $dir "Data") }
function IsOurs($file) { $Known -contains (Get-FileHash -LiteralPath $file -Algorithm MD5).Hash.ToLower() }

if (-not $Uninstall -and -not (Test-Path -LiteralPath $Patch)) { Fail "patch-5.MPQ is missing. Keep it in the same folder as install-client.bat." }

# ----------------------------------------------------------------------------- 1. find WoW
Step "1/3  Finding your WoW 3.3.5a folder"
if ($Wow) {
    if (Test-Path -LiteralPath $Wow -PathType Leaf) { $Wow = Split-Path -Parent $Wow }   # they dropped Wow.exe itself
    if (-not (IsWow $Wow)) { Fail "No Wow.exe + Data folder in: $Wow" }
} else {
    $roots = @((Split-Path -Parent $Here), $env:USERPROFILE, "C:\Program Files", "C:\Program Files (x86)")
    $roots += (Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Free -ne $null } | ForEach-Object { $_.Root })
    $found = @()
    foreach ($r in $roots) {
        if (-not $r -or -not (Test-Path -LiteralPath $r)) { continue }
        Write-Host "  searching $r ..."
        $found += Get-ChildItem -LiteralPath $r -Filter "Wow.exe" -File -Recurse -Depth 5 -Force -ErrorAction SilentlyContinue |
                  ForEach-Object { $_.DirectoryName } | Where-Object { IsWow $_ }
        if ($found.Count -gt 0) { break }
    }
    $found = @($found | Sort-Object -Unique)
    if ($found.Count -eq 0) {
        Fail "WoW not found. Drag your WoW folder (or Wow.exe) onto install-client.bat."
    } elseif ($found.Count -gt 1) {
        Write-Host "Found more than one WoW folder:"
        for ($i = 0; $i -lt $found.Count; $i++) { Write-Host ("  {0}) {1}" -f ($i + 1), $found[$i]) }
        $n = Read-Host "Which one do you play with? [1-$($found.Count)]"
        if (-not ($n -match '^\d+$') -or [int]$n -lt 1 -or [int]$n -gt $found.Count) { Fail "Invalid choice." }
        $Wow = $found[[int]$n - 1]
    } else { $Wow = $found[0] }
}
$Wow  = (Resolve-Path -LiteralPath $Wow).Path
$Data = (Child $Wow "Data").FullName
Ok "Using $Wow"

$patches = @(Get-ChildItem -LiteralPath $Data -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^patch-.\.mpq$' })

# ----------------------------------------------------------------------------- 2. patch
if ($Uninstall) {
    Step "2/3  Removing the truck patch"
    $removed = $false
    foreach ($f in $patches) {
        if (IsOurs $f.FullName) {
            try { Remove-Item -LiteralPath $f.FullName -Force } catch { Fail "Could not delete $($f.Name) (is WoW running? close it first)." }
            Ok "Removed $($f.Name)"; $removed = $true
        }
    }
    if (-not $removed) { Warn "No truck patch found in $Data (already removed?)." }
} else {
    Step "2/3  Copying the truck patch"
    $target = $null
    foreach ($f in $patches) { if (IsOurs $f.FullName) { $target = $f.FullName; break } }     # update in place
    if (-not $target) {
        foreach ($c in @("5","6","7","8","9") + [char[]](65..90)) {                             # never overwrite another mod
            if (-not ($patches | Where-Object { $_.Name -ieq "patch-$c.MPQ" })) { $target = Join-Path $Data "patch-$c.MPQ"; break }
        }
        if (-not $target) { Fail "Every patch name from patch-5 to patch-Z is taken in $Data." }
        if ((Split-Path -Leaf $target) -ne "patch-5.MPQ") { Warn "patch-5.MPQ is already used by another mod, so the truck goes in as $(Split-Path -Leaf $target)." }
    }
    try { Copy-Item -LiteralPath $Patch -Destination $target -Force } catch { Fail "Could not copy into $Data (is WoW running? close it first). $_" }
    Ok "Installed as $target"
}

# ----------------------------------------------------------------------------- 3. cache
Step "3/3  Clearing the WoW Cache"
$cache = Child $Wow "Cache"
if ($cache) { Remove-Item -LiteralPath $cache.FullName -Recurse -Force -ErrorAction SilentlyContinue; Ok "Cache cleared." } else { Ok "No Cache folder (fine)." }

Write-Host ""
if ($Uninstall) { Ok "UNINSTALLED. Restart WoW." }
else {
    Ok "ALL DONE. Start WoW, open Spellbook > Mounts:"
    Write-Host '  "Truck with Lights" and "Truck with No Lights" - drag them to your action bar.'
    Write-Host "  (The server must have the truck installed too - ask your server admin.)"
}
