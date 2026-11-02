[CmdletBinding()]
param(
    [string]$InstallDir = 'C:\after-effects-mcp',
    [string]$RepoUrl = 'https://github.com/Dakkshin/after-effects-mcp',
    [string]$ServerName = 'AfterEffectsMCP',
    [switch]$AllVersions,
    [switch]$SkipPrefs,
    [switch]$Doctor
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$MinAEYear = 2022
$MinNodeMajor = 18
$BridgeName = 'mcp-bridge-auto.jsx'
$PrefKey = 'Pref_SCRIPTING_FILE_NETWORK_SECURITY'
$ClaudeDownloadUrl = 'https://claude.ai/download'
$TotalSteps = 9
$ProgramFilesDir = if ($env:ProgramW6432) { $env:ProgramW6432 } else { $env:ProgramFiles }

function Step([int]$n, [string]$m) { Write-Host "`n[$n/$TotalSteps] $m" -ForegroundColor Cyan }
function Ok($m) { Write-Host "  [OK] $m" -ForegroundColor Green }
function Warn($m) { Write-Host "  [!]  $m" -ForegroundColor Yellow }
function Bad($m) { Write-Host "  [X]  $m" -ForegroundColor Red }
function Info($m) { Write-Host "       $m" -ForegroundColor DarkGray }

function Test-Cmd([string]$Name) { [bool](Get-Command $Name -ErrorAction SilentlyContinue) }

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Update-SessionPath {
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = (@($machine, $user) | Where-Object { $_ }) -join ';'
}

function Invoke-Native([string]$File, [string[]]$Arguments) {
    & $File @Arguments
    if ($LASTEXITCODE -ne 0) { throw "Command failed: $(Split-Path $File -Leaf) $($Arguments -join ' ') (exit $LASTEXITCODE)" }
}

function Quote([string]$s) { "'" + $s.Replace("'", "''") + "'" }

function Invoke-Elevated([string]$Script, [string]$Reason) {
    if (Test-Admin) {
        & ([scriptblock]::Create("`$ErrorActionPreference = 'Stop'`n$Script"))
        return
    }
    $log = Join-Path $env:TEMP "ae-mcp-elevated-$PID.log"
    Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue
    $wrapped = "`$ErrorActionPreference = 'Stop'`ntry {`n$Script`n}`ncatch { `$_ | Out-String | Set-Content -LiteralPath $(Quote $log); exit 1 }"
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($wrapped))
    Write-Host "  Administrator rights are required $Reason. Click [Yes] in the UAC prompt." -ForegroundColor Yellow
    try {
        $p = Start-Process 'powershell.exe' -Verb RunAs -Wait -PassThru -WindowStyle Hidden `
            -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $enc
    }
    catch { throw 'The administrator prompt was cancelled.' }
    $detail = $null
    if (Test-Path -LiteralPath $log) {
        $detail = (Get-Content -LiteralPath $log -Raw).Trim()
        Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue
    }
    if ($p.ExitCode -ne 0) {
        if ($detail) { throw "The elevated step failed: $detail" }
        throw "The elevated step failed (exit $($p.ExitCode))."
    }
}

function Get-FileEncoding([byte[]]$Bytes) {
    if ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF) { return New-Object Text.UTF8Encoding($true) }
    if ($Bytes.Length -ge 2 -and $Bytes[0] -eq 0xFF -and $Bytes[1] -eq 0xFE) { return [Text.Encoding]::Unicode }
    if ($Bytes.Length -ge 2 -and $Bytes[0] -eq 0xFE -and $Bytes[1] -eq 0xFF) { return [Text.Encoding]::BigEndianUnicode }
    return New-Object Text.UTF8Encoding($false)
}

function Wait-ForClose([string]$Label, [scriptblock]$GetProcs, [string]$Hint, [switch]$AllowAutoClose) {
    if (@(& $GetProcs).Count -eq 0) { return $true }
    Warn "$Label is running. $Hint"
    $keys = if ($AllowAutoClose) { 'press C to close it for you, or S to skip' } else { 'press S to skip' }
    Info "Waiting for $Label to close... ($keys)"
    while (@(& $GetProcs).Count -gt 0) {
        $key = ''
        try { if ([Console]::KeyAvailable) { $key = [string][Console]::ReadKey($true).KeyChar } } catch {}
        if ($key -match '^[sS]$') { Warn "Skipped. $Label is still running."; return $false }
        if ($AllowAutoClose -and $key -match '^[cC]$') { & $GetProcs | Stop-Process -Force -ErrorAction SilentlyContinue }
        Start-Sleep -Milliseconds 500
    }
    Start-Sleep -Seconds 2
    Ok "$Label closed"
    return $true
}

function Get-AEInstalls {
    $root = Join-Path $ProgramFilesDir 'Adobe'
    if (-not (Test-Path -LiteralPath $root)) { return @() }
    @(Get-ChildItem -LiteralPath $root -Directory -Filter 'Adobe After Effects *' -ErrorAction SilentlyContinue |
        ForEach-Object {
            if ($_.Name -notmatch '(\d{4})$') { return }
            $year = [int]$Matches[1]
            if (-not (Test-Path -LiteralPath (Join-Path $_.FullName 'Support Files\AfterFX.exe'))) { return }
            [pscustomobject]@{
                Year   = $year
                Name   = $_.Name
                Panels = Join-Path $_.FullName 'Support Files\Scripts\ScriptUI Panels'
            }
        } | Where-Object { $_.Year -ge $MinAEYear } | Sort-Object Year -Descending)
}

function Get-BridgeTargets {
    $aes = @(Get-AEInstalls)
    if ($AllVersions) { return $aes }
    return @($aes | Select-Object -First 1)
}

function Get-AEProcesses { @(Get-Process -Name 'AfterFX' -ErrorAction SilentlyContinue) }

function Get-NodeMajor {
    if (-not (Test-Cmd 'node')) { return 0 }
    try { return [int]((& node -v).Trim().TrimStart('v').Split('.')[0]) } catch { return 0 }
}

function Get-PrefFiles {
    $base = Join-Path $env:APPDATA 'Adobe\After Effects'
    if (-not (Test-Path -LiteralPath $base)) { return @() }
    $majors = @(Get-AEInstalls | ForEach-Object { $_.Year - 2000 })
    @(Get-ChildItem -LiteralPath $base -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^(\d+)\.' -and ([int]$Matches[1] -in $majors) } |
        ForEach-Object { Get-ChildItem -LiteralPath $_.FullName -Recurse -Filter '*.txt' -ErrorAction SilentlyContinue } |
        Where-Object { Select-String -LiteralPath $_.FullName -SimpleMatch "`"$PrefKey`"" -Quiet })
}

function Read-TextFile([string]$Path) {
    $encoding = Get-FileEncoding ([IO.File]::ReadAllBytes($Path))
    [pscustomobject]@{ Text = [IO.File]::ReadAllText($Path, $encoding); Encoding = $encoding }
}

function Test-PrefEnabled([string]$Text) {
    $Text -match "`"$PrefKey`"\s*=\s*(`"0*1`"|0*1\b)"
}

function Get-ClaudeDesktopExe {
    $exe = Join-Path $env:LOCALAPPDATA 'AnthropicClaude\claude.exe'
    if (Test-Path -LiteralPath $exe) { return $exe }
    return $null
}

function Get-ClaudePackage {
    try {
        @(Get-AppxPackage -Name '*Claude*' -ErrorAction SilentlyContinue) |
        Sort-Object { $_.Publisher -notlike '*Anthropic*' } | Select-Object -First 1
    }
    catch { $null }
}

function Test-ClaudeInstalled { [bool](Get-ClaudeDesktopExe) -or [bool](Get-ClaudePackage) }

function Get-ClaudeDataDirs {
    $dirs = @(Join-Path $env:APPDATA 'Claude')
    $pkg = Get-ClaudePackage
    if ($pkg) { $dirs += Join-Path $env:LOCALAPPDATA "Packages\$($pkg.PackageFamilyName)\LocalCache\Roaming\Claude" }
    $dirs
}

function Test-ClaudeLaunched { [bool](@(Get-ClaudeDataDirs) | Where-Object { Test-Path -LiteralPath $_ }) }

function Get-ClaudeConfigPaths {
    $dirs = @(Get-ClaudeDataDirs)
    $paths = @(Join-Path $dirs[0] 'claude_desktop_config.json')
    foreach ($d in ($dirs | Select-Object -Skip 1)) {
        if (Test-Path -LiteralPath $d) { $paths += Join-Path $d 'claude_desktop_config.json' }
    }
    $paths
}

function Get-ClaudeDesktopProcesses {
    @(Get-Process -Name 'claude' -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -and ($_.Path -like '*\AnthropicClaude\*' -or $_.Path -like '*\WindowsApps\*Claude*') })
}

function Start-ClaudeDesktop {
    $exe = Get-ClaudeDesktopExe
    if ($exe) { Start-Process -FilePath $exe; return $true }
    $pkg = Get-ClaudePackage
    if (-not $pkg) { return $false }
    try {
        $app = @((Get-AppxPackageManifest -Package $pkg.PackageFullName).Package.Applications.Application)[0]
        Start-Process -FilePath 'explorer.exe' -ArgumentList "shell:AppsFolder\$($pkg.PackageFamilyName)!$($app.Id)"
        return $true
    }
    catch { return $false }
}

function Assert-Prerequisites {
    Step 1 'Checking prerequisites'
    $aes = @(Get-AEInstalls)
    if ($aes.Count -eq 0) {
        throw "After Effects $MinAEYear or later was not found under $ProgramFilesDir\Adobe."
    }
    $aes | ForEach-Object { Ok $_.Name }

    if (-not (Test-ClaudeInstalled)) {
        Bad 'Claude Desktop is not installed.'
        Info "Opening $ClaudeDownloadUrl in your browser..."
        try { Start-Process $ClaudeDownloadUrl } catch {}
        throw 'Install Claude Desktop, open it once, then run install.cmd again.'
    }
    if (-not (Test-ClaudeLaunched)) {
        Bad 'Claude Desktop is installed but has never been opened.'
        Info 'Opening Claude Desktop...'
        [void](Start-ClaudeDesktop)
        throw 'Wait until Claude Desktop has opened, then run install.cmd again.'
    }
    Ok 'Claude Desktop'
}

function Install-NodeFromMsi {
    $arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64' -or $env:PROCESSOR_ARCHITEW6432 -eq 'ARM64') { 'arm64' } else { 'x64' }
    Write-Host '  Downloading the latest Node.js LTS installer from nodejs.org...'
    $lts = Invoke-RestMethod 'https://nodejs.org/dist/index.json' | Where-Object { $_.lts } | Select-Object -First 1
    $ver = $lts.version
    $msi = Join-Path $env:TEMP "node-$ver-$arch.msi"
    Invoke-WebRequest "https://nodejs.org/dist/$ver/node-$ver-$arch.msi" -OutFile $msi -UseBasicParsing
    Write-Host "  Installing Node.js $ver. Click [Yes] in the UAC prompt." -ForegroundColor Yellow
    try {
        $p = Start-Process 'msiexec.exe' -Verb RunAs -Wait -PassThru -ArgumentList "/i `"$msi`" /qn /norestart"
    }
    catch { throw 'The administrator prompt was cancelled, so Node.js could not be installed.' }
    Remove-Item -LiteralPath $msi -Force -ErrorAction SilentlyContinue
    if ($p.ExitCode -notin 0, 3010) { throw "Node.js installation failed (msiexec exit $($p.ExitCode))." }
}

function Ensure-Node {
    Step 2 "Checking for Node.js v$MinNodeMajor+ and npm"
    $cur = Get-NodeMajor
    if ($cur -lt $MinNodeMajor) {
        Write-Host "  Node.js $(if ($cur) { "v$cur is too old" } else { 'not found' }). Installing..."
        if (Test-Cmd 'winget') {
            & winget install -e --id OpenJS.NodeJS.LTS --silent --accept-source-agreements --accept-package-agreements | Out-Host
            Update-SessionPath
        }
        if ((Get-NodeMajor) -lt $MinNodeMajor) {
            Install-NodeFromMsi
            Update-SessionPath
        }
    }
    if ((Get-NodeMajor) -lt $MinNodeMajor) {
        throw "Node.js v$MinNodeMajor or later is required. Uninstall the old version (or run 'nvm use' if you use nvm) and try again."
    }
    if (-not (Test-Cmd 'npm.cmd')) { throw 'npm was not found. Please reinstall Node.js.' }
    Ok "node $(& node -v) / npm $(& npm.cmd -v)"
}

function Ensure-Git {
    Step 3 'Checking for Git'
    if (-not (Test-Cmd 'git') -and (Test-Cmd 'winget')) {
        Write-Host '  Git not found. Installing with winget...'
        & winget install -e --id Git.Git --silent --accept-source-agreements --accept-package-agreements | Out-Host
        Update-SessionPath
    }
    if (Test-Cmd 'git') { Ok (& git --version); return $true }
    Warn 'Git could not be installed. Falling back to a zip download.'
    return $false
}

function Resolve-InstallDir {
    if (Test-Path -LiteralPath $InstallDir) { return }
    $parent = Split-Path $InstallDir -Parent
    $probe = Join-Path $parent ".ae-mcp-probe-$PID"
    try {
        New-Item -ItemType Directory -Path $probe -ErrorAction Stop | Out-Null
        Remove-Item -LiteralPath $probe -Force
    }
    catch {
        $fallback = Join-Path $env:LOCALAPPDATA 'after-effects-mcp'
        Warn "Cannot create folders in $parent. Installing to $fallback instead."
        $script:InstallDir = $fallback
    }
}

function Get-Source([bool]$UseGit) {
    Resolve-InstallDir
    Step 4 "Downloading source to $InstallDir"

    if ($UseGit -and (Test-Path -LiteralPath (Join-Path $InstallDir '.git'))) {
        Write-Host '  Existing install found. Updating to the latest version...'
        Invoke-Native 'git' @('-C', $InstallDir, 'fetch', '--depth', '1', 'origin', 'HEAD')
        Invoke-Native 'git' @('-C', $InstallDir, 'reset', '--hard', 'FETCH_HEAD')
        Ok 'Updated'
        return
    }

    if (Test-Path -LiteralPath $InstallDir) {
        $bak = "$InstallDir.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        Warn "Moving the existing folder to $bak"
        Move-Item -LiteralPath $InstallDir -Destination $bak
    }

    if ($UseGit) {
        Invoke-Native 'git' @('clone', '--depth', '1', "$RepoUrl.git", $InstallDir)
    }
    else {
        $tmp = Join-Path $env:TEMP "ae-mcp-$PID"
        New-Item -ItemType Directory -Force -Path $tmp | Out-Null
        try {
            $zip = Join-Path $tmp 'src.zip'
            Invoke-WebRequest "$RepoUrl/archive/refs/heads/main.zip" -OutFile $zip -UseBasicParsing
            Expand-Archive -LiteralPath $zip -DestinationPath $tmp -Force
            $inner = Get-ChildItem -LiteralPath $tmp -Directory | Select-Object -First 1
            Move-Item -LiteralPath $inner.FullName -Destination $InstallDir
        }
        finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    }
    Ok 'Source ready'
}

function Build-Server {
    Step 5 'Running npm install and npm run build'
    $npm = (Get-Command 'npm.cmd').Source
    Push-Location -LiteralPath $InstallDir
    try {
        Invoke-Native $npm @('install', '--no-fund', '--no-audit')
        Invoke-Native $npm @('run', 'build')
    }
    finally { Pop-Location }
    $entry = Join-Path $InstallDir 'build\index.js'
    if (-not (Test-Path -LiteralPath $entry)) { throw "Build output not found: $entry" }
    Ok 'Build complete'
}

function Install-Bridge {
    Step 6 'Installing the bridge panel'
    $src = Join-Path $InstallDir "build\scripts\$BridgeName"
    if (-not (Test-Path -LiteralPath $src)) { $src = Join-Path $InstallDir "src\scripts\$BridgeName" }
    if (-not (Test-Path -LiteralPath $src)) { throw "$BridgeName was not found in the source." }

    $targets = @(Get-BridgeTargets)
    $lines = foreach ($t in $targets) {
        "New-Item -ItemType Directory -Force -Path $(Quote $t.Panels) | Out-Null"
        "Copy-Item -Force -LiteralPath $(Quote $src) -Destination $(Quote $t.Panels)"
    }
    Invoke-Elevated ($lines -join "`n") 'to write into the After Effects folder'

    foreach ($t in $targets) {
        if (Test-Path -LiteralPath (Join-Path $t.Panels $BridgeName)) { Ok "$($t.Name) <- $BridgeName" }
        else { throw "Failed to copy the panel into $($t.Name)." }
    }
}

function Show-ManualPrefHelp {
    Info 'Enable it manually in After Effects:'
    Info "  Edit > Preferences > Scripting & Expressions > 'Allow Scripts to Write Files and Access Network'"
}

function Enable-ScriptingPref {
    Step 7 'Enabling "Allow Scripts to Write Files and Access Network"'
    if ($SkipPrefs) { Warn 'Skipped (-SkipPrefs).'; Show-ManualPrefHelp; return $false }

    $files = @(Get-PrefFiles)
    if ($files.Count -eq 0) {
        Warn 'The setting was not found in any preferences file (After Effects may never have been launched).'
        Show-ManualPrefHelp
        return $false
    }

    $closed = Wait-ForClose 'After Effects' { Get-AEProcesses } 'Save your work and close it so its preferences can be changed.'
    if (-not $closed) { Show-ManualPrefHelp; return $false }

    $allOn = $true
    foreach ($f in $files) {
        $label = $f.Directory.Name
        $file = Read-TextFile $f.FullName
        if (Test-PrefEnabled $file.Text) { Ok "Already enabled ($label)"; continue }

        $new = [regex]::Replace($file.Text, "(`"$PrefKey`"\s*=\s*)`"\d+`"", '${1}"1"')
        $new = [regex]::Replace($new, "(`"$PrefKey`"\s*=\s*)\d+", '${1}01')
        if (-not (Test-PrefEnabled $new)) {
            Warn "Unrecognized preferences format, could not enable ($label)"
            $allOn = $false
            continue
        }

        if (-not (Test-Path -LiteralPath "$($f.FullName).bak")) { Copy-Item -LiteralPath $f.FullName -Destination "$($f.FullName).bak" }
        [IO.File]::WriteAllText($f.FullName, $new, $file.Encoding)

        if (Test-PrefEnabled (Read-TextFile $f.FullName).Text) { Ok "Enabled ($label, backup: $($f.Name).bak)" }
        else { Warn "Failed to enable ($label)"; $allOn = $false }
    }
    if (-not $allOn) { Show-ManualPrefHelp }
    return $allOn
}

function Set-ClaudeConfig([string]$Path, [string]$NodeExe, [string]$Entry) {
    $dir = Split-Path $Path -Parent
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }

    $cfg = $null
    if (Test-Path -LiteralPath $Path) {
        $raw = [IO.File]::ReadAllText($Path)
        if ($raw.Trim()) {
            try { $cfg = $raw | ConvertFrom-Json }
            catch { throw "The Claude config file is not valid JSON. Fix it and run again: $Path" }
        }
        if (-not (Test-Path -LiteralPath "$Path.bak")) { Copy-Item -LiteralPath $Path -Destination "$Path.bak" }
    }
    if ($null -eq $cfg) { $cfg = New-Object psobject }

    if (-not ($cfg.PSObject.Properties.Name -contains 'mcpServers') -or $null -eq $cfg.mcpServers) {
        $cfg | Add-Member -NotePropertyName 'mcpServers' -NotePropertyValue (New-Object psobject) -Force
    }
    $server = [pscustomobject]@{ command = $NodeExe; args = @($Entry) }
    $cfg.mcpServers | Add-Member -NotePropertyName $ServerName -NotePropertyValue $server -Force

    $json = ConvertTo-Json -InputObject $cfg -Depth 32
    [IO.File]::WriteAllText($Path, $json, (New-Object Text.UTF8Encoding($false)))
}

function Register-ClaudeDesktop {
    Step 8 'Registering the MCP server in Claude Desktop'
    $wasRunning = @(Get-ClaudeDesktopProcesses).Count -gt 0
    $closed = Wait-ForClose 'Claude Desktop' { Get-ClaudeDesktopProcesses } `
        'It must be fully quit before its config is changed (right-click the tray icon > Quit).' -AllowAutoClose

    $node = (Get-Command 'node').Source
    $entry = Join-Path $InstallDir 'build\index.js'
    foreach ($p in Get-ClaudeConfigPaths) {
        Set-ClaudeConfig $p $node $entry
        Ok "Updated $p"
    }
    Info "command: $node"
    Info "args   : $entry"

    if (-not $closed) {
        Warn 'Claude Desktop was left running and may overwrite the config when it quits.'
        return $false
    }
    if ($wasRunning) {
        if (Start-ClaudeDesktop) { Ok 'Claude Desktop reopened'; return $true }
        Warn 'Could not reopen Claude Desktop automatically.'
        return $false
    }
    return $true
}

function Invoke-Doctor {
    $script:okAll = $true
    function Check([bool]$Cond, [string]$Good, [string]$BadMsg) {
        if ($Cond) { Ok $Good } else { Bad $BadMsg; $script:okAll = $false }
    }

    $aes = @(Get-AEInstalls)
    Check ($aes.Count -gt 0) "After Effects: $(($aes | ForEach-Object Year) -join ', ')" "After Effects $MinAEYear or later not found"
    Check (Test-ClaudeInstalled) 'Claude Desktop installed' "Claude Desktop not installed ($ClaudeDownloadUrl)"
    $nm = Get-NodeMajor
    Check ($nm -ge $MinNodeMajor) "Node.js v$nm" "Node.js v$MinNodeMajor or later required (found: $(if ($nm) { "v$nm" } else { 'none' }))"

    $entry = Join-Path $InstallDir 'build\index.js'
    Check (Test-Path -LiteralPath $entry) "MCP server built: $entry" "Build output missing: $entry"

    foreach ($t in Get-BridgeTargets) {
        Check (Test-Path -LiteralPath (Join-Path $t.Panels $BridgeName)) "$($t.Name): bridge panel installed" "$($t.Name): bridge panel missing"
    }

    $prefs = @(Get-PrefFiles)
    if ($prefs.Count -eq 0) { Warn 'AE scripting permission: could not verify (check it in After Effects)' }
    foreach ($f in $prefs) {
        $on = Test-PrefEnabled (Read-TextFile $f.FullName).Text
        Check $on "AE scripting permission enabled ($($f.Directory.Name))" "AE scripting permission disabled ($($f.Directory.Name))"
    }

    foreach ($p in Get-ClaudeConfigPaths) {
        $has = $false
        if (Test-Path -LiteralPath $p) {
            try {
                $cfg = [IO.File]::ReadAllText($p) | ConvertFrom-Json
                $has = [bool]$cfg.mcpServers -and ($cfg.mcpServers.PSObject.Properties.Name -contains $ServerName)
            }
            catch {}
        }
        Check $has "Claude config has $ServerName" "Claude config is missing $ServerName ($p)"
    }
    return $script:okAll
}

try {
    Write-Host ''
    Write-Host '  ============================================' -ForegroundColor Magenta
    Write-Host '    After Effects MCP for Claude Desktop'       -ForegroundColor Magenta
    Write-Host '  ============================================' -ForegroundColor Magenta
    Update-SessionPath

    if ($Doctor) {
        $alt = Join-Path $env:LOCALAPPDATA 'after-effects-mcp'
        if (-not (Test-Path -LiteralPath $InstallDir) -and (Test-Path -LiteralPath $alt)) { $InstallDir = $alt }
        Write-Host "`nHealth check" -ForegroundColor Cyan
        if (Invoke-Doctor) { exit 0 } else { exit 1 }
    }

    Assert-Prerequisites
    Ensure-Node
    $useGit = Ensure-Git
    Get-Source $useGit
    Build-Server
    Install-Bridge
    $prefOk = Enable-ScriptingPref
    $claudeOk = Register-ClaudeDesktop

    Step 9 'Health check'
    $allOk = Invoke-Doctor

    $n = 1
    $lines = @('', '==================================================', ' Setup complete. Next steps:', '')
    if (-not $claudeOk) {
        $lines += " $n. Fully quit and reopen Claude Desktop"; $n++
        $lines += '    (closing the window is not enough: right-click the tray icon > Quit)'
    }
    $lines += " $n. Open After Effects (restart it if it is already running)"; $n++
    if (-not $prefOk) {
        $lines += " $n. Edit > Preferences > Scripting & Expressions"; $n++
        $lines += "    > enable 'Allow Scripts to Write Files and Access Network'"
    }
    $lines += " $n. Window > $BridgeName"; $n++
    $lines += "    > make sure 'Auto-run commands' is checked"
    $lines += " $n. Try this in Claude Desktop:"
    $lines += "    `"Create a 1920x1080 30fps composition with a text layer that says Hello`""
    $lines += ''
    $lines += ' Something wrong? Run: install.cmd -Doctor'
    $lines += '=================================================='
    Write-Host ($lines -join "`n") -ForegroundColor $(if ($allOk) { 'Green' } else { 'Yellow' })
    exit 0
}
catch {
    Write-Host ''
    Bad $_.Exception.Message
    Write-Host '  Setup stopped. Fix the issue above and run install.cmd again (it is safe to re-run).' -ForegroundColor Yellow
    exit 1
}
