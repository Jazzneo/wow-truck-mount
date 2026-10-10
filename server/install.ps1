# =============================================================================
#  Truck Mount installer for AzerothCore (WoW 3.3.5a) - Windows
#  Started by install.bat. Gives every character both truck mounts (spells 55531 + 60424).
# =============================================================================
param([string]$ConfPath = "", [switch]$Uninstall)
$ErrorActionPreference = "Stop"
$Here  = Split-Path -Parent $MyInvocation.MyCommand.Path
$Spell = 55531

function Step($t)  { Write-Host ""; Write-Host "== $t" -ForegroundColor White }
function Ok($t)    { Write-Host $t -ForegroundColor Green }
function Fail($t)  { Write-Host ""; Write-Host "ERROR: $t" -ForegroundColor Red; exit 1 }

# ----------------------------------------------------------------------------- 1. find worldserver.conf
Step "1/4  Finding worldserver.conf"
if (-not $ConfPath) {
    $roots = @()
    $p = $Here
    for ($i = 0; $i -lt 3 -and $p; $i++) { $roots += $p; $p = Split-Path -Parent $p }
    $roots += $env:USERPROFILE
    $roots += (Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Free -ne $null } | ForEach-Object { $_.Root })
    $found = @()
    foreach ($r in $roots) {
        if (-not (Test-Path $r)) { continue }
        Write-Host "  searching $r ..."
        $found += Get-ChildItem -Path $r -Filter "worldserver.conf" -File -Recurse -Depth 6 -ErrorAction SilentlyContinue |
                  Select-Object -ExpandProperty FullName
        if ($found.Count -gt 0) { break }
    }
    $found = @($found | Select-Object -Unique)
    if ($found.Count -eq 0) {
        Fail "worldserver.conf not found. Drag your worldserver.conf onto install.bat.`n       (If you only have worldserver.conf.dist, copy it and rename the copy to worldserver.conf.)"
    } elseif ($found.Count -gt 1) {
        Write-Host "Found more than one:"
        for ($i = 0; $i -lt $found.Count; $i++) { Write-Host ("  {0}) {1}" -f ($i + 1), $found[$i]) }
        $n = Read-Host "Which one does your server use? [1-$($found.Count)]"
        if (-not ($n -match '^\d+$') -or [int]$n -lt 1 -or [int]$n -gt $found.Count) { Fail "Invalid choice." }
        $ConfPath = $found[[int]$n - 1]
    } else { $ConfPath = $found[0] }
}
if (-not (Test-Path $ConfPath)) { Fail "File not found: $ConfPath" }
$ConfPath = (Resolve-Path $ConfPath).Path
Ok "Using $ConfPath"

# ----------------------------------------------------------------------------- 2. read database logins
Step "2/4  Reading database logins"
$confText = [IO.File]::ReadAllText($ConfPath)
function ConfValue($key) {
    $m = [regex]::Matches($confText, "(?m)^[ \t]*$([regex]::Escape($key))[ \t]*=[ \t]*`"?([^`"\r\n]*)`"?")
    if ($m.Count -eq 0) { return "" }
    return $m[$m.Count - 1].Groups[1].Value.Trim()
}
function SplitInfo($info) {
    $a = $info.Split(';')
    if ($a.Count -lt 5) { Fail "Could not read database login: $info" }
    return @{ Host = $a[0]; Port = $a[1]; User = $a[2]; Pass = $a[3]; Name = $a[4] }
}
$worldInfo = ConfValue "WorldDatabaseInfo"
$charInfo  = ConfValue "CharacterDatabaseInfo"

# Docker setups (docker-compose.yml next to the server) ignore the logins in worldserver.conf:
# the real ones are AC_*_DATABASE_INFO in docker-compose.yml, with the password from .env.
$dockerRoot = $null; $d = Split-Path -Parent $ConfPath
for ($i = 0; $i -lt 5 -and $d; $i++) {
    if ((Test-Path (Join-Path $d "docker-compose.yml")) -or (Test-Path (Join-Path $d "docker-compose.override.yml"))) { $dockerRoot = $d; break }
    $d = Split-Path -Parent $d
}
function EnvValue($name, $default) {
    $f = if ($dockerRoot) { Join-Path $dockerRoot ".env" } else { $null }
    if ($f -and (Test-Path $f)) {
        $m = [regex]::Matches([IO.File]::ReadAllText($f), "(?m)^[ \t]*$([regex]::Escape($name))=([^\r\n]*)")
        if ($m.Count -gt 0) { $v = $m[$m.Count - 1].Groups[1].Value.Trim().Trim('"').Trim("'"); if ($v) { return $v } }
    }
    return $default
}
function ResolveVars($text) {
    return [regex]::Replace($text, '\$\{([A-Za-z_][A-Za-z0-9_]*)(:-([^}]*))?\}', { param($m) EnvValue $m.Groups[1].Value $m.Groups[3].Value })
}
function ComposeInfo($key) {
    foreach ($name in @("docker-compose.override.yml", "docker-compose.yml")) {
        $f = Join-Path $dockerRoot $name
        if (-not (Test-Path $f)) { continue }
        $m = [regex]::Match([IO.File]::ReadAllText($f), "(?m)^[ \t-]*$([regex]::Escape($key))[ \t]*[:=][ \t]*[`"']?([^`"'\r\n]*)")
        if ($m.Success) { return ResolveVars $m.Groups[1].Value.Trim() }
    }
    return $null
}
if ($dockerRoot) {
    Write-Host "Docker setup found in $dockerRoot - using its database login."
    $port = EnvValue "DOCKER_DB_EXTERNAL_PORT" "3306"
    foreach ($which in @("WORLD", "CHARACTER")) {
        $info = ComposeInfo "AC_$($which)_DATABASE_INFO"
        if (-not $info) { continue }
        $p = $info.Split(';')
        $new = "127.0.0.1;$port;$($p[2]);$($p[3]);$($p[4])"     # from this PC the container is reached on the published port
        if ($which -eq "WORLD") { $worldInfo = $new } else { $charInfo = $new }
    }
}
$world = SplitInfo $worldInfo
$chars = SplitInfo $charInfo
Write-Host ("World database:      {0} on {1}:{2} (user {3})" -f $world.Name, $world.Host, $world.Port, $world.User)
Write-Host ("Characters database: {0} on {1}:{2} (user {3})" -f $chars.Name, $chars.Host, $chars.Port, $chars.User)

# find mysql.exe: PATH, next to the server (repacks), then MySQL / MariaDB install folders
$mysql = $null
$cmd = Get-Command mysql.exe -ErrorAction SilentlyContinue
if ($cmd) { $mysql = $cmd.Source }
if (-not $mysql) {
    $p = Split-Path -Parent $ConfPath
    for ($i = 0; $i -lt 4 -and $p -and -not $mysql; $i++) {
        $hit = Get-ChildItem -Path $p -Filter "mysql.exe" -File -Recurse -Depth 4 -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($hit) { $mysql = $hit.FullName }
        $p = Split-Path -Parent $p
    }
}
if (-not $mysql) {
    foreach ($pf in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, "C:\xampp")) {
        if (-not $pf -or -not (Test-Path $pf)) { continue }
        $hit = Get-ChildItem -Path $pf -Filter "mysql.exe" -File -Recurse -Depth 4 -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($hit) { $mysql = $hit.FullName; break }
    }
}
if (-not $mysql) { Fail "mysql.exe not found. Install MySQL, or run sql\install_world.sql on the world DB and sql\install_characters.sql on the characters DB with HeidiSQL." }
Write-Host "MySQL client: $mysql"

function RunSql($db, [string]$sqlText, [switch]$Query) {
    $env:MYSQL_PWD = $db.Pass
    $margs = @("-h", $db.Host, "-P", $db.Port, "-u", $db.User, $db.Name)
    if ($Query) { $margs = @("-N", "-B", "-e", $sqlText) + $margs; $out = & $mysql @margs 2>&1 }
    else        { $out = $sqlText | & $mysql @margs 2>&1 }
    $code = $LASTEXITCODE
    Remove-Item Env:\MYSQL_PWD -ErrorAction SilentlyContinue
    if ($code -ne 0) { Fail "MySQL said: $out`n       (Is MySQL running? Is the login in worldserver.conf right?)" }
    return $out
}

# ----------------------------------------------------------------------------- 3. run the SQL
$act = if ($Uninstall) { "uninstall" } else { "install" }
if ($Uninstall) { Step "3/4  Removing the truck from the databases" } else { Step "3/4  Adding the truck to the databases" }
RunSql $world ([IO.File]::ReadAllText((Join-Path $Here "sql\$($act)_world.sql"))) | Out-Null
if ($Uninstall) { Ok "World database: new characters no longer get the truck." } else { Ok "World database: new characters will start with the truck." }
RunSql $chars ([IO.File]::ReadAllText((Join-Path $Here "sql\$($act)_characters.sql"))) | Out-Null
$count = (RunSql $chars "SELECT COUNT(*) FROM character_spell WHERE spell=$Spell" -Query | Out-String).Trim()
if ($Uninstall) {
    Ok "Characters database: truck buttons removed ($count characters still have spell $Spell, e.g. a crafted Mechano-Hog)."
    Write-Host ""
    Ok "UNINSTALLED. Restart worldserver. Players can run client\uninstall-client.bat."
    Write-Host "(PlayerStart.CustomSpells was left on in case other custom spells use it.)"
    exit 0
}
Ok "Characters database: $count characters now have the truck."

# ----------------------------------------------------------------------------- 4. turn on PlayerStart.CustomSpells
Step "4/4  Turning on PlayerStart.CustomSpells"
if ($confText -match '(?m)^[ \t]*PlayerStart\.CustomSpells[ \t]*=[ \t]*1') {
    Ok "Already on."
} else {
    Copy-Item $ConfPath "$ConfPath.bak-truck" -Force
    if ($confText -match '(?m)^[ \t]*PlayerStart\.CustomSpells[ \t]*=') {
        $confText = [regex]::Replace($confText, '(?m)^([ \t]*PlayerStart\.CustomSpells[ \t]*=[ \t]*)\d+', '${1}1')
    } else {
        $confText += "`r`nPlayerStart.CustomSpells = 1`r`n"
    }
    [IO.File]::WriteAllText($ConfPath, $confText, (New-Object System.Text.UTF8Encoding($false)))
    Ok "Done (backup saved as worldserver.conf.bak-truck)."
}

Write-Host ""
Ok "ALL DONE. Restart worldserver, then look in Spellbook > Mounts."
Write-Host '  "Truck with Lights" and "Truck with No Lights".'
Write-Host "Give players the client folder: they run install-client.bat (Windows) or install-client.sh (Linux/Steam Deck)."
