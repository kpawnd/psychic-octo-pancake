#Requires -RunAsAdministrator

param(
    [switch]$PatchOnly,
    [string]$LibraryPath
)

Set-ExecutionPolicy Bypass -Scope Process -Force
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$STEAMCMD_DIR   = 'C:\SteamCMD'
$STEAMCMD_EXE   = "$STEAMCMD_DIR\steamcmd.exe"
$STEAMCMD_URL   = 'https://steamcdn-a.akamaihd.net/client/installer/steamcmd.zip'
$STEAMCMD_ZIP   = "$STEAMCMD_DIR\steamcmd.zip"
$SCRIPTS_DIR    = "$STEAMCMD_DIR\scripts"
$LOG_DIR        = "$STEAMCMD_DIR\logs"
$CREDS_FILE     = "$STEAMCMD_DIR\credentials.json"

$GAMES = @(
    [PSCustomObject]@{ Name = 'Counter-Strike 2'; AppId = '730'; InstallDir = 'Counter-Strike Global Offensive' },
    [PSCustomObject]@{ Name = 'Dota 2';           AppId = '570'; InstallDir = 'dota 2 beta' }
)

$NON_STEAM_LAUNCHERS = @(
    [PSCustomObject]@{ Name = 'Roblox';   Exe = 'RobloxPlayerInstaller.exe'; Url = 'https://www.roblox.com/download/client' },
    [PSCustomObject]@{ Name = 'Valorant'; Exe = 'ValorantInstaller.exe';     Url = 'https://valorant.secure.dyn.riotcdn.net/channels/public/x/installer/current/live.live.na.exe' }
)

# UTF-8 encoding instance without BOM required for VDF/ACF/JSON files.
# PS5's Set-Content -Encoding UTF8 prepends a BOM (EF BB BF) Steam and ConvertFrom-Json
# reject files that start with a BOM. WriteAllText with this instance works identically in PS5 and PS7.
$Utf8NoBom = [System.Text.UTF8Encoding]::new($false)

function Write-Step ([string]$msg) { Write-Host "> $msg" -ForegroundColor Yellow }
function Write-OK   ([string]$msg) { Write-Host "[OK]   $msg" -ForegroundColor Green }
function Write-Info ([string]$msg) { Write-Host "[INFO] $msg" -ForegroundColor Gray }
function Write-Warn ([string]$msg) { Write-Host "[WARN] $msg" -ForegroundColor DarkYellow }
function Write-Fail ([string]$msg) { Write-Host "[FAIL] $msg" -ForegroundColor Red }

function Write-Log {
    param([string]$Msg, [string]$Level = 'INFO')
    $ts    = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $entry = "[$ts][$Level][$env:COMPUTERNAME] $Msg"
    if (-not (Test-Path $LOG_DIR)) { New-Item -ItemType Directory $LOG_DIR -Force | Out-Null }
    Add-Content "$LOG_DIR\install_$(Get-Date -Format 'yyyyMMdd').log" $entry
}

function Confirm-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = [Security.Principal.WindowsPrincipal]$id
    if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Warn 'Not running as Administrator - re-launching elevated...'
        $passThrough = ''
        if ($PatchOnly)                                       { $passThrough += ' -PatchOnly' }
        if (-not [string]::IsNullOrWhiteSpace($LibraryPath)) { $passThrough += " -LibraryPath `"$LibraryPath`"" }
        $elevArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"$passThrough"
        Start-Process powershell -ArgumentList $elevArgs -Verb RunAs
        exit
    }
}

function Get-SteamInstallPath {
    $keys = @(
        'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam',
        'HKLM:\SOFTWARE\Valve\Steam',
        'HKCU:\Software\Valve\Steam'
    )
    foreach ($k in $keys) {
        try {
            $props = Get-ItemProperty -Path $k -ErrorAction Stop
            foreach ($name in 'InstallPath','SteamPath') {
                if ($props.PSObject.Properties[$name] -and $props.$name) {
                    $p = ($props.$name -replace '/', '\').TrimEnd('\')
                    if (Test-Path $p) { return $p }
                }
            }
        } catch {}
    }
    foreach ($p in @('C:\Program Files (x86)\Steam', 'C:\Program Files\Steam')) {
        if (Test-Path $p) { return $p }
    }
    return $null
}

function Get-SteamCredentials {
    if (Test-Path $CREDS_FILE) {
        try {
            $json = Get-Content $CREDS_FILE -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($json.Username -and $json.Password) {
                Write-Info "Loaded Steam credentials from $CREDS_FILE"
                return [PSCustomObject]@{ Username = $json.Username; Password = $json.Password }
            }
        } catch {
            Write-Warn "Could not parse $CREDS_FILE : $_"
        }
    }

    Write-Info "No credentials file at $CREDS_FILE"
    Write-Info 'To skip this prompt in future, create that file as: { "Username": "login", "Password": "pass" }'
    $u = Read-Host 'Steam username'
    $p = Read-Host 'Steam password'

    $resp = Read-Host "Save to $CREDS_FILE for future use? [y/N]"
    if ($resp -match '^[Yy]') {
        $jsonOut = [PSCustomObject]@{ Username = $u; Password = $p } | ConvertTo-Json
        [System.IO.File]::WriteAllText($CREDS_FILE, $jsonOut, $Utf8NoBom)
        Write-OK "Saved to $CREDS_FILE"
        Write-Warn 'This file stores your Steam password in plaintext. Use a dedicated lab account.'
    }

    return [PSCustomObject]@{ Username = $u; Password = $p }
}

function Stop-SteamIfRunning {
    $procs = Get-Process -Name 'steam','steamservice','steamwebhelper' -ErrorAction SilentlyContinue
    if (-not $procs) { return $true }

    Write-Warn 'Steam is currently running. It must be closed before patching libraryfolders.vdf.'
    Write-Info 'Please close Steam now (right-click tray icon -> Exit). Waiting up to 60 seconds...'

    $deadline = (Get-Date).AddSeconds(60)
    while ((Get-Date) -lt $deadline) {
        if (-not (Get-Process -Name 'steam','steamservice','steamwebhelper' -ErrorAction SilentlyContinue)) {
            Write-OK 'Steam closed.'
            return $true
        }
        Start-Sleep -Seconds 2
    }

    Write-Warn 'Steam is still running after 60 seconds.'
    $resp = Read-Host 'Force-close Steam now? [y/N]'
    if ($resp -match '^[Yy]') {
        Get-Process -Name 'steam','steamservice','steamwebhelper' -ErrorAction SilentlyContinue |
            Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
        if (Get-Process -Name 'steam','steamservice','steamwebhelper' -ErrorAction SilentlyContinue) {
            return $false
        }
        Write-OK 'Steam force-closed.'
        return $true
    }
    return $false
}

function Initialize-SteamLibrary {
    param([string]$LibraryPath, [string]$SteamDir)

    # steamapps subdirectory tree Steam expects inside every library folder
    foreach ($sub in 'steamapps','steamapps\common','steamapps\downloading','steamapps\shadercache','steamapps\workshop') {
        $d = "$LibraryPath\$sub"
        if (-not (Test-Path $d)) {
            New-Item -ItemType Directory $d -Force | Out-Null
            Write-Info "Created $d"
        }
    }

    # steam.dll must exist in the library root as Steam uses it to validate library folders on launch
    if ($SteamDir -and (Test-Path "$SteamDir\steam.dll")) {
        Copy-Item "$SteamDir\steam.dll" "$LibraryPath\steam.dll" -Force
        Write-OK "Copied steam.dll -> $LibraryPath"
        Write-Log "Copied steam.dll to library: $LibraryPath"
    } else {
        Write-Warn "steam.dll not found under $SteamDir - library may not appear in Steam after launch."
        Write-Log "steam.dll missing from $SteamDir" -Level 'WARN'
    }

    # libraryfolder.vdf (singular) lives in the library root itself.
    # This is distinct from libraryfolders.vdf in Steam's config dir.
    $escaped   = $LibraryPath -replace '\\', '\\'
    $lfContent = "`"LibraryFolder`"`n{`n`t`"path`"`t`t`"$escaped`"`n`t`"label`"`t`t`"`"`n`t`"contentid`"`t`t`"0`"`n`t`"totalsize`"`t`t`"0`"`n`t`"update_clean_bytes_tally`"`t`t`"0`"`n`t`"time_last_update_corruption`"`t`t`"0`"`n}`n"
    [System.IO.File]::WriteAllText("$LibraryPath\libraryfolder.vdf", $lfContent, $Utf8NoBom)
    Write-OK "Created $LibraryPath\libraryfolder.vdf"
    Write-Log "Created libraryfolder.vdf: $LibraryPath\libraryfolder.vdf"
}

function ConvertTo-SteamVdfPath {
    param([string]$Path)
    return ($Path.TrimEnd('\') -replace '\\', '\\')
}

function Get-LibraryTotalSize {
    param([string]$LibraryPath)

    try {
        $drive = Split-Path -Path $LibraryPath -Qualifier
        if ($drive) {
            $disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$drive'" -ErrorAction Stop
            if ($disk.Size) { return [string]$disk.Size }
        }
    } catch {}

    return '0'
}

function Get-AppSizeOnDisk {
    param([string]$LibraryPath, [pscustomobject]$Game)

    $acf = "$LibraryPath\steamapps\appmanifest_$($Game.AppId).acf"
    if (Test-Path $acf) {
        $raw = Get-Content $acf -Raw -Encoding UTF8
        if ($raw -match '"SizeOnDisk"\s+"(\d+)"') { return $Matches[1] }
    }

    return '0'
}

function New-LibraryAppsBlock {
    param(
        [string]$LibraryPath,
        [string]$Indent = "`t`t`t"
    )

    $lines = foreach ($g in $GAMES) {
        $size = Get-AppSizeOnDisk -LibraryPath $LibraryPath -Game $g
        "$Indent`"$($g.AppId)`"`t`t`"$size`""
    }

    return ($lines -join "`n")
}

function New-SteamLibraryFolderEntry {
    param([int]$Index, [string]$LibraryPath)

    $t         = "`t"
    $escaped   = ConvertTo-SteamVdfPath -Path $LibraryPath
    $totalSize = Get-LibraryTotalSize -LibraryPath $LibraryPath
    $apps      = New-LibraryAppsBlock -LibraryPath $LibraryPath

    return "$t`"$Index`"`n$t{`n$t$t`"path`"$t$t`"$escaped`"`n$t$t`"label`"$t$t`"Lab Games`"`n$t$t`"contentid`"$t$t`"0`"`n$t$t`"totalsize`"$t$t`"$totalSize`"`n$t$t`"update_clean_bytes_tally`"$t$t`"0`"`n$t$t`"time_last_update_verified`"$t$t`"0`"`n$t$t`"apps`"$t$t{`n$apps`n$t$t}`n$t}"
}

function Add-GamesToLibraryEntry {
    param([string]$Entry, [string]$LibraryPath)

    $missing = @()
    foreach ($g in $GAMES) {
        $size = Get-AppSizeOnDisk -LibraryPath $LibraryPath -Game $g
        $appPattern = '"' + [regex]::Escape($g.AppId) + '"'

        if ($Entry -match $appPattern) {
            if ($size -ne '0') {
                $Entry = [regex]::Replace($Entry, "($appPattern\s+`")\d+(`")", '${1}' + $size + '${2}')
            }
        } else {
            $missing += "`t`t`t`"$($g.AppId)`"`t`t`"$size`""
        }
    }

    if ($missing.Count -eq 0) { return $Entry }

    $insert = $missing -join "`n"
    $appsMatch = [regex]::Match($Entry, '(?ms)(?<prefix>^\s*"apps"\s*\{\s*)(?<body>.*?)(?<suffix>^\s*\})')
    if ($appsMatch.Success) {
        $body = $appsMatch.Groups['body'].Value
        if ([string]::IsNullOrWhiteSpace($body)) {
            $replacement = $appsMatch.Groups['prefix'].Value + $insert + "`n" + $appsMatch.Groups['suffix'].Value
        } else {
            $trimmedBody = $body -replace '\s+$', ''
            $replacement = $appsMatch.Groups['prefix'].Value + $trimmedBody + "`n" + $insert + "`n" + $appsMatch.Groups['suffix'].Value
        }
        return $Entry.Remove($appsMatch.Index, $appsMatch.Length).Insert($appsMatch.Index, $replacement)
    }

    $close = [regex]::Match($Entry, '(\r?\n\s*\}\s*)$')
    if ($close.Success) {
        $appsBlock = "`n`t`t`"apps`"`t`t{`n$insert`n`t`t}"
        return $Entry.Insert($close.Index, $appsBlock)
    }

    return $Entry
}

function Update-LibraryFoldersContent {
    param([string]$Content, [string]$LibraryPath)

    $escaped     = ConvertTo-SteamVdfPath -Path $LibraryPath
    $pathPattern = '"path"\s*"' + [regex]::Escape($escaped) + '"'
    $entries     = [regex]::Matches($Content, '(?m)^\s*"\d+"\s*$')
    $rootClose   = [regex]::Match($Content, '(\r?\n\}\s*)$')
    $rootEnd     = if ($rootClose.Success) { $rootClose.Index } else { $Content.Length }

    for ($i = 0; $i -lt $entries.Count; $i++) {
        $start = $entries[$i].Index
        $end   = if ($i + 1 -lt $entries.Count) { $entries[$i + 1].Index } else { $rootEnd }
        $entry = $Content.Substring($start, $end - $start)

        if ($entry -match $pathPattern) {
            $updatedEntry = Add-GamesToLibraryEntry -Entry $entry -LibraryPath $LibraryPath
            $patched = $Content.Remove($start, $end - $start).Insert($start, $updatedEntry)
            return [PSCustomObject]@{
                Content = $patched
                Action  = if ($updatedEntry -eq $entry) { 'unchanged' } else { 'updated-apps' }
                Index   = $entries[$i].Value.Trim().Trim('"')
            }
        }
    }

    $newEntry = New-SteamLibraryFolderEntry -Index $entries.Count -LibraryPath $LibraryPath
    if ($rootClose.Success) {
        $patched = $Content.Insert($rootClose.Index, "`n$newEntry")
    } else {
        $patched = $Content.TrimEnd() + "`n$newEntry`n}`n"
    }

    return [PSCustomObject]@{
        Content = $patched
        Action  = 'added'
        Index   = [string]$entries.Count
    }
}

function Add-SteamLibrary {
    param([string]$LibraryPath)

    $steamDir = Get-SteamInstallPath
    if (-not $steamDir) {
        Write-Warn 'No Steam installation detected (registry + common paths checked).'
        $manual = Read-Host 'Enter Steam install directory (blank to skip)'
        if ([string]::IsNullOrWhiteSpace($manual)) {
            Write-Log 'Skipped library setup: Steam install not found.' -Level 'WARN'
            return
        }
        $steamDir = $manual.TrimEnd('\')
    }
    Write-Info "Steam install: $steamDir"
    Write-Log "Steam install detected: $steamDir"

    Initialize-SteamLibrary -LibraryPath $LibraryPath -SteamDir $steamDir

    $configVdf    = "$steamDir\config\libraryfolders.vdf"
    $steamappsVdf = "$steamDir\steamapps\libraryfolders.vdf"
    $targets      = @($configVdf, $steamappsVdf)

    if (-not (Test-Path $configVdf) -and -not (Test-Path $steamappsVdf)) {
        Write-Info 'libraryfolders.vdf not found - creating from scratch.'
        $resp = Read-Host 'Create libraryfolders.vdf with the lab library entry? [Y/n]'
        if ($resp -match '^[Nn]') {
            Write-Info 'Skipping VDF creation.'
            Write-Log 'User declined to create libraryfolders.vdf from scratch.' -Level 'WARN'
            return
        }

        if (-not (Stop-SteamIfRunning)) {
            Write-Warn 'Steam still running - aborting VDF creation.'
            Write-Log 'Skipped VDF creation: Steam still running.' -Level 'WARN'
            return
        }

        $t        = "`t"
        $steamEsc = $steamDir    -replace '\\', '\\'
        $entry0   = "$t`"0`"`n$t{`n$t$t`"path`"$t$t`"$steamEsc`"`n$t$t`"label`"$t$t`"`"`n$t$t`"contentid`"$t$t`"0`"`n$t$t`"totalsize`"$t$t`"0`"`n$t$t`"update_clean_bytes_tally`"$t$t`"0`"`n$t$t`"time_last_update_corruption`"$t$t`"0`"`n$t$t`"apps`"$t$t{}`n$t}"
        $entry1   = New-SteamLibraryFolderEntry -Index 1 -LibraryPath $LibraryPath
        $newContent = "`"libraryfolders`"`n{`n$entry0`n$entry1`n}`n"

        foreach ($vdf in $targets) {
            $parent = Split-Path $vdf -Parent
            if (-not (Test-Path $parent)) {
                try { New-Item -ItemType Directory $parent -Force | Out-Null } catch {
                    Write-Fail "Could not create $parent : $_"
                    Write-Log "Could not create $parent : $_" -Level 'ERROR'
                    continue
                }
            }
            try {
                [System.IO.File]::WriteAllText($vdf, $newContent, $Utf8NoBom)
                Write-OK "Created $(Split-Path $vdf -Leaf) with default + lab entries"
                Write-Log "Created libraryfolders.vdf: $vdf"
            } catch {
                Write-Fail "Failed to write $vdf : $_"
                Write-Log "Failed to write $vdf : $_" -Level 'ERROR'
            }
        }
        return
    }

    if (-not (Stop-SteamIfRunning)) {
        Write-Warn 'Steam still running - skipping VDF patch to avoid corruption.'
        Write-Log 'Skipped VDF patch: Steam still running.' -Level 'WARN'
        return
    }

    $escaped          = ConvertTo-SteamVdfPath -Path $LibraryPath
    $exactPathPattern = '"path"\s*"' + [regex]::Escape($escaped) + '"'

    foreach ($vdf in $targets) {
        $leaf = Split-Path $vdf -Leaf
        if (-not (Test-Path $vdf)) { Write-Info "$leaf not present - skipping."; continue }

        $raw = Get-Content $vdf -Raw -Encoding UTF8

        $backup = "$vdf.bak"
        Copy-Item $vdf $backup -Force
        Write-Info "Backup: $backup"

        $result = Update-LibraryFoldersContent -Content $raw -LibraryPath $LibraryPath
        [System.IO.File]::WriteAllText($vdf, $result.Content, $Utf8NoBom)

        $verify = Get-Content $vdf -Raw -Encoding UTF8
        if ($verify -match $exactPathPattern) {
            if ($result.Action -eq 'unchanged') {
                Write-Info "$leaf already references $LibraryPath with required AppIDs - no change."
            } else {
                Write-OK "Patched $leaf -> entry $($result.Index) $($result.Action) = $LibraryPath"
            }
            Write-Log "VDF patched OK: $vdf  action=$($result.Action)  entry=$($result.Index)  path=$LibraryPath"
        } else {
            Write-Fail "Verification failed for $leaf - restoring backup"
            Copy-Item $backup $vdf -Force
            Write-Log "VDF verify FAILED: $vdf - restored from backup" -Level 'ERROR'
        }
    }
}

function Install-NonSteamLaunchers {
    param([string]$InstallerDir)

    if (-not (Test-Path $InstallerDir)) {
        New-Item -ItemType Directory $InstallerDir -Force | Out-Null
        Write-Info "Created installer staging directory: $InstallerDir"
    }

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    foreach ($launcher in $NON_STEAM_LAUNCHERS) {
        Write-Step "$($launcher.Name) setup"
        $path = "$InstallerDir\$($launcher.Exe)"

        if (-not (Test-Path $path)) {
            if ($launcher.Url) {
                Write-Info "Downloading $($launcher.Name) installer..."
                try {
                    Invoke-WebRequest -Uri $launcher.Url -OutFile $path -UseBasicParsing -WarningAction SilentlyContinue
                    $hdr = [System.IO.File]::ReadAllBytes($path) | Select-Object -First 2
                    if ($hdr[0] -ne 0x4D -or $hdr[1] -ne 0x5A) {
                        Remove-Item $path -Force
                        throw 'Response was not an executable (no MZ header)'
                    }
                    Write-OK "Downloaded: $($launcher.Exe)"
                    Write-Log "$($launcher.Name) installer downloaded"
                } catch {
                    Write-Warn "Auto-download failed: $_"
                }
            }

            if (-not (Test-Path $path)) {
                Write-Warn "$($launcher.Name) installer not found."
                Write-Info "Manually download the installer and place it at:"
                Write-Info "  $path"
                $resp = Read-Host "Press Enter when ready, or type SKIP to skip $($launcher.Name)"
                if ($resp -imatch '^skip') {
                    Write-Log "$($launcher.Name) skipped by user" -Level 'WARN'
                    continue
                }
                if (-not (Test-Path $path)) {
                    Write-Warn "Installer still not found - skipping $($launcher.Name)"
                    Write-Log "$($launcher.Name) skipped - installer missing" -Level 'WARN'
                    continue
                }
            }
        } else {
            Write-Info "$($launcher.Name) installer already staged at $path"
        }

        Write-Info "$($launcher.Name) does not support silent install."
        Write-Info "Complete the installation in the window that opens, then return here."
        Read-Host "Press Enter to launch the $($launcher.Name) installer"

        $proc = Start-Process $path -PassThru
        Write-Info "Waiting for $($launcher.Name) setup to finish..."
        $proc.WaitForExit()
        Write-OK "$($launcher.Name) setup done (exit $($proc.ExitCode))"
        Write-Log "$($launcher.Name) install done (exit $($proc.ExitCode))"
    }
}

function Repair-AppManifests {
    param([string]$LibraryPath)

    $steamappsDir = "$LibraryPath\steamapps"

    foreach ($g in $GAMES) {
        $acfName   = "appmanifest_$($g.AppId).acf"
        $targetAcf = "$steamappsDir\$acfName"

        if (-not (Test-Path $targetAcf)) {
            # SteamCMD places the ACF inside <force_install_dir>\steamapps\ when it treats
            # force_install_dir as a library root. Check that location first, then fall back
            # to a recursive search anywhere under the library path.
            $candidates = @(
                "$steamappsDir\common\$($g.InstallDir)\steamapps\$acfName",
                "$steamappsDir\common\$acfName",
                "$STEAMCMD_DIR\steamapps\$acfName"
            )
            $moved = $false
            foreach ($c in $candidates) {
                if (Test-Path $c) {
                    Move-Item $c $targetAcf -Force
                    Write-OK "ACF moved to library: $acfName"
                    Write-Log "ACF moved: $c -> $targetAcf"
                    $moved = $true
                    break
                }
            }
            if (-not $moved) {
                $found = Get-ChildItem $LibraryPath -Filter $acfName -Recurse -ErrorAction SilentlyContinue |
                         Select-Object -First 1
                if ($found) {
                    Move-Item $found.FullName $targetAcf -Force
                    Write-OK "ACF moved from $($found.DirectoryName)"
                    Write-Log "ACF moved: $($found.FullName) -> $targetAcf"
                } else {
                    Write-Warn "$acfName not found - $($g.Name) may not appear in Steam library"
                    Write-Log "ACF missing after install: $acfName" -Level 'WARN'
                    continue
                }
            }
        }

        # Ensure installdir is the relative folder name Steam uses (not a full path).
        # Steam resolves it as <library>\steamapps\common\<installdir>.
        $acf = Get-Content $targetAcf -Raw -Encoding UTF8
        if ($acf -match '"installdir"\s+"([^"]+)"') {
            $current = $Matches[1]
            if ($current -ne $g.InstallDir) {
                $desired = $g.InstallDir
                $acf = $acf -replace '(?<="installdir"\s+")[^"]+', $desired
                [System.IO.File]::WriteAllText($targetAcf, $acf, $Utf8NoBom)
                Write-OK "Fixed installdir in $acfName : '$current' -> '$desired'"
                Write-Log "ACF installdir fixed: $acfName"
            }
        }

        Write-OK "ACF OK: $acfName"
        Write-Log "ACF OK: $targetAcf"
    }
}

Confirm-Admin

if ($PatchOnly) {
    Write-Log 'Patch-only mode'
    Write-Step 'Patch-only mode: library registration only'

    $defaultPath = 'T:\SteamLibrary'
    if ([string]::IsNullOrWhiteSpace($LibraryPath)) {
        if (Test-Path 'T:\') {
            Write-Info "ThawSpace (T:\) is online. Suggested default: $defaultPath"
        } else {
            Write-Warn "Drive T:\ not detected - ThawSpace may not be mounted yet."
        }
        $LibraryPath = ''
        while ($LibraryPath.Length -lt 3) {
            $in = Read-Host "Enter existing Steam library path to register [default: $defaultPath]"
            $LibraryPath = if ([string]::IsNullOrWhiteSpace($in)) { $defaultPath } else { $in.TrimEnd('\') }
            if ($LibraryPath.Length -lt 3) { Write-Warn 'Please enter a full path, e.g. T:\SteamLibrary' }
        }
    } else {
        $LibraryPath = $LibraryPath.TrimEnd('\')
    }

    if (-not (Test-Path $LibraryPath)) {
        Write-Warn "Library path does not exist: $LibraryPath"
        $resp = Read-Host 'Continue and patch anyway? [y/N]'
        if ($resp -notmatch '^[Yy]') {
            Write-Info 'Aborted.'
            Write-Log 'Patch-only aborted: path missing and user declined.' -Level 'WARN'
            exit 1
        }
    }

    Write-OK "Library path: $LibraryPath"
    Write-Log "Patch-only library path: $LibraryPath"
    Write-Step 'Registering library with Steam'
    Add-SteamLibrary -LibraryPath $LibraryPath
    Write-Log 'Patch-only complete'
    Write-OK 'Library registration complete.'
    Read-Host 'Press Enter to close'
    exit 0
}

Write-Log 'Install started'

Write-Step 'Steam credentials'
Write-Info 'SteamCMD will use this account to download all games.'
Write-Info 'If Steam Guard is active, SteamCMD will prompt for the code during the authentication step.'
$Creds = Get-SteamCredentials
Write-OK "Account: $($Creds.Username)"
Write-Log "Steam account: $($Creds.Username)"

Write-Step 'Game library location'
$extraDrives = (Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Name -ne 'C' }).Name
if ($extraDrives) { Write-Info "Visible non-system drives: $($extraDrives -join ', ')" }
$defaultPath = 'T:\SteamLibrary'
if (Test-Path 'T:\') {
    Write-Info "ThawSpace (T:\) is online. Suggested default: $defaultPath"
} else {
    Write-Warn "Drive T:\ not detected - ThawSpace may not be mounted yet."
}
$BaseInstallPath = ''
while ($BaseInstallPath.Length -lt 3) {
    $in = Read-Host "Enter install base path [default: $defaultPath]"
    $BaseInstallPath = if ([string]::IsNullOrWhiteSpace($in)) { $defaultPath } else { $in.TrimEnd('\') }
    if ($BaseInstallPath.Length -lt 3) { Write-Warn 'Please enter a full path, e.g. T:\SteamLibrary' }
}
Write-OK "Install path: $BaseInstallPath"
Write-Log "Install path: $BaseInstallPath"

$InstallerDir = Join-Path (Split-Path -Path $BaseInstallPath -Qualifier) 'Installers'

Write-Step 'Creating directories'
foreach ($d in @($STEAMCMD_DIR, $SCRIPTS_DIR, $LOG_DIR, $BaseInstallPath, $InstallerDir)) {
    if (-not (Test-Path $d)) {
        try   { New-Item -ItemType Directory $d -Force | Out-Null; Write-OK "Created $d"; Write-Log "mkdir $d" }
        catch { Write-Fail "Could not create $d - $_"; Write-Log "ERROR mkdir $d : $_" -Level 'ERROR' }
    } else {
        Write-Info "Exists $d"
    }
}

Write-Step 'Non-Steam launchers (Roblox, Valorant)'
Write-Info "Installers staged at: $InstallerDir"
Write-Warn 'Roblox and Valorant require interactive installation - complete each setup window before continuing.'
Write-Warn 'Valorant: download RiotClientInstaller.exe from playvalorant.com/en-us/download/ and place it in the staging directory above if the script cannot download it automatically.'
Install-NonSteamLaunchers -InstallerDir $InstallerDir

Write-Step "Installing SteamCMD -> $STEAMCMD_DIR"
if (Test-Path $STEAMCMD_EXE) {
    Write-Info 'steamcmd.exe already present - skipping download.'
    Write-Log 'SteamCMD already installed.'
} else {
    Write-Info 'Downloading steamcmd.zip from Valve...'
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $STEAMCMD_URL -OutFile $STEAMCMD_ZIP -UseBasicParsing -WarningAction SilentlyContinue
        Write-OK 'Download complete.'
        Write-Log 'SteamCMD downloaded.'
    } catch {
        Write-Fail "Download failed: $_"
        Write-Log "FATAL: Download failed: $_" -Level 'ERROR'
        Read-Host 'Press Enter to exit'; exit 1
    }
    Write-Info 'Extracting...'
    try {
        Expand-Archive -Path $STEAMCMD_ZIP -DestinationPath $STEAMCMD_DIR -Force
        Remove-Item $STEAMCMD_ZIP -Force
        Write-OK "Extracted to $STEAMCMD_DIR"
        Write-Log 'SteamCMD extracted.'
    } catch {
        Write-Fail "Extraction failed: $_"
        Write-Log "FATAL: Extraction failed: $_" -Level 'ERROR'
        Read-Host 'Press Enter to exit'; exit 1
    }
}

Write-Info 'Bootstrapping SteamCMD (first-run self-update)...'
$boot = Start-Process $STEAMCMD_EXE -ArgumentList '+quit' -Wait -PassThru -NoNewWindow
Write-Log "Bootstrap exit code: $($boot.ExitCode)"
if ($boot.ExitCode -in @(0, 7)) { Write-OK 'SteamCMD ready.' }
else { Write-Warn "Bootstrap exit $($boot.ExitCode) - usually harmless, continuing." }

Write-Step 'Steam Guard authentication'
Write-Info 'SteamCMD will open a login session.'
Write-Info 'If Steam Guard is enabled, enter the code when prompted.'
& $STEAMCMD_EXE '+login' $Creds.Username $Creds.Password '+quit'
$loginExit = $LASTEXITCODE
Write-Log "SteamCMD login exit: $loginExit"
if ($loginExit -in @(0, 7)) { Write-OK 'SteamCMD login complete.' }
else { Write-Warn "SteamCMD login exit $loginExit - install may fail if Steam Guard was not completed." }

Write-Step 'Writing install runscript'
$installScript = "$SCRIPTS_DIR\install_all.txt"
# Each game gets its own force_install_dir so their files land in separate steamapps\common\<InstallDir> folders.
# SteamCMD treats force_install_dir as the game root; without per-game dirs both games collide in the same tree.
$sc  = "@ShutdownOnFailedCommand 0`n"
$sc += "@NoPromptForPassword 1`n"
$sc += "login $($Creds.Username) $($Creds.Password)`n"
foreach ($g in $GAMES) {
    $gameDir = "$BaseInstallPath\steamapps\common\$($g.InstallDir)"
    $sc += "force_install_dir `"$gameDir`"`n"
    $sc += "app_update $($g.AppId) validate`n"
}
$sc += 'quit'
Set-Content $installScript $sc -Encoding Ascii
Write-OK "Runscript -> $installScript"
Write-Log "Install runscript: $installScript"

Write-Step 'Installing games'
Write-Info "Games: $($GAMES.Name -join ', ')"
Write-Info "Destination: $BaseInstallPath\steamapps\common\<game>"
Write-Info 'Steam Guard prompts are handled in the authentication step.'
$proc = Start-Process $STEAMCMD_EXE -ArgumentList "+runscript `"$installScript`"" -NoNewWindow -Wait -PassThru
$installExit = $proc.ExitCode
if ($installExit -in @(0, 7)) {
    Write-OK "All games installed (SteamCMD exit $installExit)"
    Write-Log "Install complete  exit=$installExit"
    $allOk = $true
} else {
    Write-Warn "SteamCMD exited $installExit - check $LOG_DIR for details"
    Write-Log "WARN: SteamCMD install exit=$installExit" -Level 'WARN'
    $allOk = $false
}

Write-Step 'Repairing app manifests'
Repair-AppManifests -LibraryPath $BaseInstallPath

Write-Step 'Registering Steam library'
Add-SteamLibrary -LibraryPath $BaseInstallPath

Write-Step 'Summary'
Write-Info "SteamCMD:    $STEAMCMD_DIR"
Write-Info "Installers:  $InstallerDir"
foreach ($l in $NON_STEAM_LAUNCHERS) { Write-Info "  $($l.Name) (interactive install)" }
Write-Info "Library:     $BaseInstallPath\steamapps\common\"
foreach ($g in $GAMES) { Write-Info "  $($g.Name) (AppID $($g.AppId))" }
Write-Info "Account:     $($Creds.Username)"
Write-Info "Logs:        $LOG_DIR"

if ($allOk) {
    Write-OK 'Setup complete. You may now freeze C:\ in Deep Freeze.'
} else {
    Write-Warn 'Setup finished with one or more non-zero SteamCMD exits.'
    Write-Info '    Re-run Install.ps1 to retry, or launch the game in Steam to trigger an update.'
}

Write-Log "Install complete. AllOk=$allOk"
Read-Host 'Press Enter to close'
