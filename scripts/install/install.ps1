<#
Install os.ivan.gg on a phone from Windows.

  curl.exe -fLO https://os.ivan.gg/install.ps1
  powershell -ExecutionPolicy Bypass -File .\install.ps1

  -Check        check the computer, fastboot and the phone, then stop; changes nothing
  -NoLock       flash but leave the bootloader unlocked
  -Zip PATH     use a downloaded <codename>-install-<build>.zip instead of downloading
  -Send PATH    send an install.log to Ivan (asks first)

Steps: 1 computer, 2 fastboot, 3 phone, 4 download, 5 unlock, 6 flash, 7 lock.
Everything goes to %USERPROFILE%\os-ivan-gg-install\<time>\install.log. On failure the script
shows what went wrong and offers to send the log. Works with Windows PowerShell 5.1.
#>
[CmdletBinding()]
param(
    [switch]$Check,
    [switch]$NoLock,
    [string]$Zip = '',
    [string]$Send = '',
    [switch]$Help
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # Invoke-WebRequest is very slow with its progress bar

$Version = 1
function Get-Setting([string]$Name, [string]$Default) {
    $v = [Environment]::GetEnvironmentVariable($Name)
    if ($v) { return $v } else { return $Default }
}
$Site = Get-Setting 'OSIVANGG_SITE' 'https://os.ivan.gg'
$Releases = Get-Setting 'OSIVANGG_RELEASES' 'https://github.com/os-ivan-gg/releases/releases/download'
# SHA-256 of avb_pkmd.bin, the public half of the verified boot key. Fetched from a different
# host than the zip, so a swapped zip is caught even if its checksum file was swapped too.
$Fingerprint = '65894abf95040084e7f27ff8cb8e0d291b04abc266103fb88cef5e0c8c8bf161'
$FastbootMin = '35.0.1'
$PtVersion = '37.0.1'
$PtSha256 = '45f4d63113e895ebde0c90f194099a4676b6ac653bd28d54314a9e022bbc1a99'
$NeedGB = [int](Get-Setting 'OSIVANGG_NEED_GB' '10')
$Wait = [int](Get-Setting 'OSIVANGG_WAIT' '180')
# Answers come from the console; the tests point OSIVANGG_TTY at a file instead.
$AnswerFile = Get-Setting 'OSIVANGG_TTY' ''
$OnWindows = ($env:OS -eq 'Windows_NT')
$UserHome = if ($env:USERPROFILE) { $env:USERPROFILE } else { $HOME }
$Base = Get-Setting 'OSIVANGG_HOME' (Join-Path $UserHome 'os-ivan-gg-install')
$Cache = Join-Path $Base 'cache'
$Total = 7

$script:Step = 0
$script:StepName = 'start'
$script:LastCmd = ''
$script:LastRc = ''
$script:Serial = ''
$script:Flashing = $false
$script:Log = ''
$script:Answers = $null
$script:AnswerIndex = 0
$Utf8 = New-Object System.Text.UTF8Encoding($false)

if ($Help) {
    (Get-Content -LiteralPath $PSCommandPath -TotalCount 15 | Select-Object -Skip 1) -join "`n"
    exit 0
}

# ---------------------------------------------------------------- output and log

function Say([string]$Text = '', [string]$Color = '') {
    if ($Color) { Write-Host $Text -ForegroundColor $Color } else { Write-Host $Text }
    if ($script:Log) { [IO.File]::AppendAllText($script:Log, $Text + "`n", $Utf8) }
}

function Write-Step([int]$N, [string]$Name) {
    $script:Step = $N; $script:StepName = $Name; $script:LastCmd = ''
    Say ''
    Say "== Step $N of ${Total}: $Name" 'Cyan'
}

# Fail throws; the catch at the bottom prints the summary and offers the report.
function Fail([string]$Message) {
    $e = New-Object System.Exception $Message
    $e.Data['install-stop'] = $true
    throw $e
}

# Run a native command, log it and its output (fastboot writes to stderr), keep its exit code.
function Invoke-Logged([string]$Exe, [string[]]$ArgList) {
    $script:LastCmd = (@($Exe) + $ArgList) -join ' '
    Say "> $($script:LastCmd)"
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    & $Exe @ArgList 2>&1 | ForEach-Object { Say ([string]$_) }
    $code = $LASTEXITCODE
    $ErrorActionPreference = $old
    $script:LastRc = $code
    return $code
}

function Invoke-Must([string]$Exe, [string[]]$ArgList) {
    if ((Invoke-Logged $Exe $ArgList) -ne 0) { Fail 'This command failed.' }
}

# Output of a native command as text, stderr included, not logged.
function Get-Output([string]$Exe, [string[]]$ArgList) {
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $out = & $Exe @ArgList 2>&1 | ForEach-Object { [string]$_ }
    $ErrorActionPreference = $old
    return @($out)
}

function Ask([string]$Prompt) {
    if ($AnswerFile) {
        if ($null -eq $script:Answers) { $script:Answers = @(Get-Content -LiteralPath $AnswerFile -ErrorAction SilentlyContinue) }
        Write-Host "$Prompt " -NoNewline
        $a = ''
        if ($script:AnswerIndex -lt $script:Answers.Count) { $a = $script:Answers[$script:AnswerIndex] }
        $script:AnswerIndex++
        Write-Host ''
    } else {
        $a = Read-Host $Prompt
    }
    if ($script:Log) { [IO.File]::AppendAllText($script:Log, "$Prompt (answered: $a)`n", $Utf8) }
    Write-Host "(answered: $a)"
    return $a
}

function Get-Sha256([string]$Path) { return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLower() }

function Format-Grouped([string]$Hex) { return (($Hex -split '(.{8})' | Where-Object { $_ }) -join ' ') }

function Save-Url([string]$Url, [string]$OutFile) {
    # curl.exe ships with Windows 10 1803 and later; it resumes and shows progress.
    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
    if ($curl) {
        $script:LastCmd = "curl.exe -fL --retry 3 -C - -o $OutFile $Url"
        Say "> $($script:LastCmd)"
        & $curl.Source -fL --retry 3 --progress-bar -C - -o $OutFile $Url
        $script:LastRc = $LASTEXITCODE
        if ($LASTEXITCODE -eq 0) { return }
        Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue
        & $curl.Source -fL --retry 3 --progress-bar -o $OutFile $Url
        $script:LastRc = $LASTEXITCODE
        if ($LASTEXITCODE -ne 0) { Fail "Download failed: $Url" }
    } else {
        $script:LastCmd = "Invoke-WebRequest $Url"
        Say "> $($script:LastCmd)"
        try { Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $OutFile } catch { Fail "Download failed: $Url ($($_.Exception.Message))" }
    }
}

function Get-Text([string]$Url) {
    try { $c = (Invoke-WebRequest -UseBasicParsing -TimeoutSec 30 -Uri $Url).Content } catch { return $null }
    # GitHub serves release files as application/octet-stream, which arrives as bytes.
    if ($c -is [byte[]]) { $c = $Utf8.GetString($c) }
    return [string]$c
}

# A copy of the log for sending: the phone's serial becomes a short hash, the home folder ~.
function Get-Redacted([string]$Path) {
    $text = [IO.File]::ReadAllText($Path, $Utf8)
    if ($script:Serial) {
        $sha = [Security.Cryptography.SHA256]::Create()
        $h = -join ($sha.ComputeHash($Utf8.GetBytes($script:Serial)) | ForEach-Object { $_.ToString('x2') })
        $text = $text.Replace($script:Serial, 'serial-' + $h.Substring(0, 8))
    }
    $text = [regex]::Replace($text, [regex]::Escape($UserHome), '~', 'IgnoreCase')
    return $text
}

function Send-Log([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { Say "No log at $Path."; return }
    $out = $Path -replace '\.log$', '.sent.log'
    $text = Get-Redacted $Path
    # The endpoint takes up to 1 MB; keep the end, where the error is.
    if ($text.Length -gt 1000000) { $text = $text.Substring($text.Length - 1000000) }
    [IO.File]::WriteAllText($out, $text, $Utf8)
    Say "Sending $out ..."
    try {
        $r = Invoke-WebRequest -UseBasicParsing -TimeoutSec 60 -Method Post -Uri "$Site/api/report" `
            -ContentType 'text/plain; charset=utf-8' -Headers @{ 'X-Install-Script' = "ps1/$Version" } `
            -Body ([IO.File]::ReadAllBytes($out))
        $id = ([string]$r.Content).Trim()
        Say ''
        Say "Sent. Report ID: $id" 'Green'
        Say 'Tell Ivan this ID when you message him.'
    } catch {
        Say 'Sending failed (no internet, or the site is down).'
        Say "Send this file to Ivan yourself: $out"
    }
}

function Show-Failure([string]$Message) {
    $last = @()
    if ($script:Log -and (Test-Path -LiteralPath $script:Log)) { $last = @(Get-Content -LiteralPath $script:Log -Tail 20) }
    Say ''
    Say "Install stopped in step $($script:Step) of $Total ($($script:StepName))." 'Red'
    Say $Message
    if ($script:LastCmd) { Say "Last command: $($script:LastCmd) (exit code $($script:LastRc))" }
    if ($script:Flashing) {
        Say "The phone may be partly flashed. Don't lock the bootloader. Run this script again"
        Say 'to flash it again; nothing on the phone needs saving at this point.'
    }
    Say ''
    Say 'Last lines of the log:'
    foreach ($l in $last) { Say "  | $l" }
    Say ''
    Say "The full log is $($script:Log)"
    $a = ''
    try { $a = Ask "Send this log to Ivan? It goes to os.ivan.gg with your phone's serial number and home folder removed. [y/N]" } catch { $a = '' }   # no console to ask on
    if ($a -match '^[yY]') { Send-Log $script:Log } else { Say 'Not sent.' }
}

function Get-VersionNumber([string]$V) {
    $p = ($V -replace '^\d+:', '') -split '[.-]'
    return [int64]$p[0] * 1000000 + [int64]$p[1] * 1000 + [int64]$p[2]
}

# fastboot getvar prints "name: value" on stderr.
function Get-Var([string]$Name) {
    foreach ($l in (Get-Output $script:Fastboot @('-s', $script:Serial, 'getvar', $Name))) {
        $l = $l -replace '^\(bootloader\) ', ''
        if ($l.StartsWith("${Name}: ")) { return $l.Substring($Name.Length + 2).Trim() }
    }
    return ''
}

function Get-UnlockAbility {
    foreach ($l in (Get-Output $script:Fastboot @('-s', $script:Serial, 'flashing', 'get_unlock_ability'))) {
        if ($l -match 'get_unlock_ability: *(\d)') { return $Matches[1] }
    }
    return ''
}

function Wait-Unlocked([string]$Want, [string]$What) {
    $waited = 0
    while ((Get-Var 'unlocked') -ne $Want) {
        if ($waited -ge 300) { Fail "The bootloader still isn't $What after 5 minutes. Was it confirmed on the phone?" }
        Start-Sleep -Seconds 5; $waited += 5
    }
}

# ---------------------------------------------------------------- the install

function Install {
    Write-Step 1 'Check the computer'
    if ($OnWindows) {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
        Say "$($os.Caption) $($os.Version), $env:PROCESSOR_ARCHITECTURE"
    } else {
        Say "$([Environment]::OSVersion.VersionString) (not Windows: test run)"
    }
    Say "PowerShell $($PSVersionTable.PSVersion)"

    if ($OnWindows) {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        if ((New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
            Fail 'Run this in a normal PowerShell window, not one opened "as administrator".'
        }
    }

    $drive = New-Object IO.DriveInfo([IO.Path]::GetPathRoot($Base))
    $freeGB = [math]::Floor($drive.AvailableFreeSpace / 1GB)
    Say "Free space in ${Base}: $freeGB GB"
    if ($freeGB -lt $NeedGB) { Fail "The install needs about $NeedGB GB free in $Base. Free some space and run the script again." }

    if ($OnWindows) {
        $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
        if ("$($cs.Manufacturer) $($cs.Model)" -match 'Virtual|VMware|VirtualBox|KVM|QEMU|Parallels') {
            Say "Warning: this looks like a virtual machine ($($cs.Model)). USB pass-through often drops"
            Say 'the phone halfway through flashing. Use a real computer if you can.'
        }
    }

    if ($null -eq (Get-Text "$Site/")) { Fail "Can't reach $Site. Check the internet connection." }
    Say 'Internet: OK'

    # ------------------------------------------------------------ 2
    Write-Step 2 'Find fastboot'
    $script:Fastboot = ''
    $have = Get-Command fastboot -ErrorAction SilentlyContinue
    if ($have) {
        $v = ''
        foreach ($l in (Get-Output $have.Source @('--version'))) { if ($l -match 'fastboot version (\S+)') { $v = $Matches[1]; break } }
        if ($v) { Say "Installed fastboot: $($have.Source), version $v" } else { Say "Installed fastboot: $($have.Source), version unknown" }
        if ($v -and (Get-VersionNumber $v) -ge (Get-VersionNumber $FastbootMin)) { $script:Fastboot = $have.Source }
        else { Say "That's older than $FastbootMin, so the script uses its own copy." }
    }
    if (-not $script:Fastboot) {
        $ptzip = Join-Path $Cache "platform-tools_r$PtVersion-win.zip"
        if (-not (Test-Path -LiteralPath $ptzip) -or (Get-Sha256 $ptzip) -ne $PtSha256) {
            Save-Url "https://dl.google.com/android/repository/platform-tools_r$PtVersion-win.zip" $ptzip
        }
        $got = Get-Sha256 $ptzip
        if ($got -ne $PtSha256) {
            Remove-Item -LiteralPath $ptzip -Force
            Fail "platform-tools download doesn't match its expected SHA-256 (got $got). Run the script again."
        }
        Say "platform-tools ${PtVersion}: SHA-256 OK"
        Remove-Item -LiteralPath (Join-Path $Cache 'platform-tools') -Recurse -Force -ErrorAction SilentlyContinue
        Expand-Zip $ptzip $Cache
        $script:Fastboot = Join-Path $Cache 'platform-tools\fastboot.exe'
    }
    # Only for this script and the flash script it runs; nothing changes system-wide.
    $env:Path = (Split-Path -Parent $script:Fastboot) + [IO.Path]::PathSeparator + $env:Path
    $fv = (Get-Output $script:Fastboot @('--version') | Select-Object -First 1) -replace 'fastboot version ', ''
    Say "Using $($script:Fastboot) ($fv)"

    # ------------------------------------------------------------ 3
    Write-Step 3 'Find the phone'
    $hint = $false; $driverHint = $false; $waited = 0
    while ($true) {
        $list = @(Get-Output $script:Fastboot @('devices') | Where-Object { $_ })
        # A phone is a "<serial><tab>fastboot" line; anything else is a message from fastboot.
        $phones = @($list | Where-Object { ($_ -split "`t")[1] -eq 'fastboot' })
        if ($phones.Count -ge 1) { break }
        if (-not $hint) {
            Say 'Waiting for a phone in fastboot mode.'
            Say '  Turn the phone off, then hold volume down and press power until the bootloader'
            Say '  screen shows. Connect it with a USB cable that carries data (not a charge-only'
            Say '  cable), straight to the computer, not through a hub.'
            $hint = $true
        }
        if ($OnWindows -and -not $driverHint -and $waited -ge 15) {
            $bad = @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
                Where-Object { $_.Status -ne 'OK' -and $_.FriendlyName -match 'Android|Pixel|Bootloader|fastboot|Unknown' })
            foreach ($d in $bad) { Say "  Device without a working driver: $($d.FriendlyName) ($($d.Status))" }
            Say '  If the phone shows "Fastboot Mode" but nothing is found: open Settings > Windows Update >'
            Say '  Advanced options > Optional updates > Driver updates, install the Android bootloader'
            Say '  interface driver (it may be called LeMobile Android Device), then unplug and reconnect.'
            $driverHint = $true
        }
        if ($waited -ge $Wait) { Fail "No phone in fastboot mode after $([math]::Floor($Wait / 60)) minutes." }
        Start-Sleep -Seconds 3; $waited += 3
    }
    if ($phones.Count -gt 1) {
        $list | ForEach-Object { Say $_ }
        Fail 'More than one phone is connected. Leave only the one you want to install on.'
    }
    $script:Serial = ($phones[0] -split "`t")[0]
    Say "Found phone $($script:Serial)"

    if ((Get-Var 'is-userspace') -eq 'yes') {
        Fail "The phone is in fastbootd (the recovery's fastboot), not the bootloader. Run: fastboot reboot bootloader, then run the script again."
    }
    $codename = Get-Var 'product'
    $unlocked = Get-Var 'unlocked'
    $u = if ($unlocked) { $unlocked } else { 'unknown' }
    Say "Phone: $codename, bootloader unlocked: $u"
    Say "Bootloader $(Get-Var 'version-bootloader'), radio $(Get-Var 'version-baseband'), slot $(Get-Var 'current-slot')"
    if (-not $codename) { Fail "fastboot found the phone but couldn't read its codename." }

    # Which build to install: the newest on the stable channel, or the one in -Zip.
    $zipPath = $Zip
    if ($zipPath) {
        if (-not (Test-Path -LiteralPath $zipPath)) { Fail "No file at $zipPath." }
        $zipPath = (Resolve-Path -LiteralPath $zipPath).Path
        $zname = Split-Path -Leaf $zipPath
        if ($zname -notmatch '^(.+)-install-(.+)\.zip$') { Fail "$zname isn't an install zip (expected <codename>-install-<build>.zip)." }
        $zcode = $Matches[1]; $build = $Matches[2]
        if ($zcode -ne $codename) { Fail "$zname is for $zcode, but the phone is a $codename." }
    } else {
        $chan = Get-Text "$Releases/updates/$codename-stable"
        $build = ''
        if ($chan) { $build = ($chan -split '\s+')[0] }
        if (-not $build) { Fail "There is no os.ivan.gg build for $codename yet. The list is at $Site/devices." }
    }
    Say "Build to install: $build"

    if ($Check) {
        Say ''
        Say "Check passed. The computer, fastboot and the phone are ready for build $build." 'Green'
        if ($unlocked -eq 'no' -and (Get-UnlockAbility) -ne '1') {
            Say 'But OEM unlocking is off: turn it on in Developer options before installing.'
        }
        Say "Run the script without -Check to install. Log: $($script:Log)"
        return
    }

    # ------------------------------------------------------------ 4
    Write-Step 4 "Download and check build $build"
    $name = "$codename-install-$build"
    if (-not $zipPath) {
        $zipPath = Join-Path $Cache "$name.zip"
        $sums = Join-Path $Cache "SHA256SUMS-$build"
        Save-Url "$Releases/$build/SHA256SUMS-$build" $sums
        $want = ''
        foreach ($l in (Get-Content -LiteralPath $sums)) { $p = $l -split '\s+'; if ($p[1] -eq "$name.zip") { $want = $p[0] } }
        if (-not $want) { Fail "SHA256SUMS-$build doesn't list $name.zip." }
        if ((Test-Path -LiteralPath $zipPath) -and (Get-Sha256 $zipPath) -eq $want) {
            Say "Already downloaded: $zipPath"
        } else {
            # Older builds in the cache are no longer needed.
            Get-ChildItem -LiteralPath $Cache -Filter '*-install-*' | Remove-Item -Recurse -Force
            Say "Downloading $name.zip (about 2 GB)."
            Save-Url "$Releases/$build/$name.zip" "$zipPath.part"
            Move-Item -LiteralPath "$zipPath.part" $zipPath -Force
        }
        $got = Get-Sha256 $zipPath
        Say "SHA-256 $got"
        if ($got -ne $want) {
            Remove-Item -LiteralPath $zipPath -Force
            Fail "The download doesn't match SHA256SUMS-$build. It was deleted; run the script again."
        }
        Say "Matches SHA256SUMS-$build."
    } else {
        $sums = Join-Path (Split-Path -Parent $zipPath) "SHA256SUMS-$build"
        if (Test-Path -LiteralPath $sums) {
            $want = ''
            foreach ($l in (Get-Content -LiteralPath $sums)) { $p = $l -split '\s+'; if ($p[1] -eq "$name.zip") { $want = $p[0] } }
            if ((Get-Sha256 $zipPath) -ne $want) { Fail "$zipPath doesn't match $sums." }
            Say "Matches $sums."
        } else {
            Say "No SHA256SUMS-$build next to the zip; relying on the key check below."
        }
    }

    # The unpacked folder is reused only if it came from this exact zip.
    $dir = Join-Path $Cache $name
    $marker = Join-Path $dir '.unpacked'
    $zsum = Get-Sha256 $zipPath
    $prev = ''
    if (Test-Path -LiteralPath $marker) { $prev = (Get-Content -LiteralPath $marker -TotalCount 1) }
    if ($prev -ne $zsum) {
        Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        Say 'Unpacking (about 4.5 GB).'
        Expand-Zip $zipPath $Cache
        if (-not (Test-Path -LiteralPath $dir)) { Fail "The zip didn't contain a $name folder." }
        [IO.File]::WriteAllText($marker, $zsum, $Utf8)
    }
    $pkmd = Join-Path $dir 'avb_pkmd.bin'
    $flashScript = if ($OnWindows) { 'flash-all.bat' } else { 'flash-all.sh' }
    if (-not (Test-Path -LiteralPath $pkmd)) { Fail 'The zip has no avb_pkmd.bin.' }
    if (-not (Test-Path -LiteralPath (Join-Path $dir $flashScript))) { Fail "The zip has no $flashScript." }
    $key = Get-Sha256 $pkmd
    Say "Key fingerprint in the zip: $(Format-Grouped $key)"
    if ($key -ne $Fingerprint) {
        Remove-Item -LiteralPath $dir -Recurse -Force
        Fail "This zip is not signed with os.ivan.gg's key. Expected $(Format-Grouped $Fingerprint). Don't flash it."
    }
    Say "Matches os.ivan.gg's key."

    # ------------------------------------------------------------ 5
    Write-Step 5 'Unlock the bootloader'
    if ($unlocked -eq 'yes') {
        Say 'Already unlocked.'
        Say ''
        Say 'Flashing erases everything on the phone.' 'Yellow'
        if ((Ask 'Type FLASH to continue, anything else to stop:') -cne 'FLASH') { Say 'Stopped. Nothing was changed on the phone.'; return }
    } else {
        $ability = Get-UnlockAbility
        Say "OEM unlocking allowed: $(if ($ability) { $ability } else { 'unknown' })"
        if ($ability -eq '0') {
            Fail 'OEM unlocking is off. Start the phone, turn it on in Settings > System > Developer options, then come back to the bootloader and run the script again.'
        }
        Say 'Unlocking erases everything on the phone: apps, photos, accounts, all of it.' 'Yellow'
        Say 'The phone then asks you to confirm: use the volume keys to pick Unlock, press power.'
        if ((Ask 'Type UNLOCK to continue, anything else to stop:') -cne 'UNLOCK') { Say 'Stopped. Nothing was changed on the phone.'; return }
        Invoke-Must $script:Fastboot @('-s', $script:Serial, 'flashing', 'unlock')
        Say 'Confirm on the phone. Waiting for the bootloader to report unlocked ...'
        Wait-Unlocked 'yes' 'unlocked'
        Say 'Unlocked.'
    }

    # ------------------------------------------------------------ 6
    Write-Step 6 "Flash build $build"
    Say "This takes a few minutes. Don't touch the cable or the phone until it's done."
    $script:Flashing = $true
    Push-Location -LiteralPath $dir
    try {
        if ($OnWindows) {
            # flash-all.bat ends with "pause"; reading from NUL lets it finish on its own. Its exit
            # code isn't reliable, so its output is checked too.
            $script:LastCmd = "flash-all.bat (in $dir)"
            Say "> $($script:LastCmd)"
            $out = New-Object System.Collections.ArrayList
            $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
            & cmd.exe /c 'flash-all.bat < NUL 2>&1' | ForEach-Object { $s = [string]$_; Say $s; [void]$out.Add($s) }
            $script:LastRc = $LASTEXITCODE
            $ErrorActionPreference = $old
        } else {
            $script:LastCmd = "sh flash-all.sh (in $dir)"
            Say "> $($script:LastCmd)"
            $out = New-Object System.Collections.ArrayList
            $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
            & sh flash-all.sh 2>&1 | ForEach-Object { $s = [string]$_; Say $s; [void]$out.Add($s) }
            $script:LastRc = $LASTEXITCODE
            $ErrorActionPreference = $old
        }
    } finally { Pop-Location }
    $bad = @($out | Where-Object { $_ -match '^FAILED|^Error|fastboot: error|fastboot not found|older than the minimum' })
    if ($script:LastRc -ne 0 -or $bad.Count -gt 0) { Fail 'The flash script failed.' }
    # The flash script installs the key itself; older zips didn't.
    if (-not (Select-String -LiteralPath (Join-Path $dir $flashScript) -Pattern 'flash avb_custom_key' -Quiet)) {
        Invoke-Must $script:Fastboot @('-s', $script:Serial, 'erase', 'avb_custom_key')
        Invoke-Must $script:Fastboot @('-s', $script:Serial, 'flash', 'avb_custom_key', $pkmd)
    }
    $script:Flashing = $false
    if ((Get-Var 'product') -ne $codename) { Fail "The phone didn't come back to the bootloader after flashing." }
    Say 'Flashed.'

    # ------------------------------------------------------------ 7
    Write-Step 7 'Lock the bootloader'
    if ($NoLock) {
        Say 'Skipped (-NoLock). The bootloader stays unlocked and the phone shows an orange warning'
        Say 'on every boot. To lock later, in the bootloader: fastboot flashing lock'
    } else {
        Say 'Locking turns on full verified boot. The phone then only boots software signed with'
        Say 'this key:'
        Say ''
        $g = (Format-Grouped $Fingerprint) -split ' '
        Say ('    ' + ($g[0..3] -join ' '))
        Say ('    ' + ($g[4..7] -join ' '))
        Say ''
        Say 'Locking erases the phone again. Confirm on the phone with the volume keys and power.' 'Yellow'
        if ((Ask 'Type LOCK to lock, anything else to leave it unlocked:') -ceq 'LOCK') {
            Invoke-Must $script:Fastboot @('-s', $script:Serial, 'flashing', 'lock')
            Say 'Confirm on the phone. Waiting for the bootloader to report locked ...'
            Wait-Unlocked 'no' 'locked'
            Say 'Locked.'
        } else {
            Say 'Left unlocked. To lock later, in the bootloader: fastboot flashing lock'
        }
    }

    Say ''
    Say 'Done. With Start selected in the bootloader, press power.' 'Green'
    Say 'A locked phone shows a yellow notice on every boot, "Your device is loading a different'
    Say 'operating system", with the key''s fingerprint; compare it with the one above. An orange'
    Say "warning means the bootloader is unlocked. Once the phone has booted and you've checked it,"
    Say 'turn OEM unlocking off in Developer options.'
    Say ''
    Say "Log: $($script:Log)"
}

function Expand-Zip([string]$ZipFile, [string]$Dest) {
    # tar.exe (Windows 10 1803 and later) is much faster than Expand-Archive on big zips.
    $tar = Get-Command tar.exe -ErrorAction SilentlyContinue
    if ($OnWindows -and $tar) { Invoke-Must $tar.Source @('-xf', $ZipFile, '-C', $Dest) }
    elseif (-not $OnWindows) { Invoke-Must 'unzip' @('-q', '-o', $ZipFile, '-d', $Dest) }
    else {
        $script:LastCmd = "Expand-Archive $ZipFile"
        Say "> $($script:LastCmd)"
        Expand-Archive -LiteralPath $ZipFile -DestinationPath $Dest -Force
    }
}

# ---------------------------------------------------------------- main

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch { Write-Verbose 'TLS 1.2 already on' }

if ($Send) {
    Send-Log $Send
    exit 0
}

$run = Join-Path $Base (Get-Date -Format 'yyyyMMdd-HHmmss')
New-Item -ItemType Directory -Force -Path $run, $Cache | Out-Null
$script:Log = Join-Path $run 'install.log'
[IO.File]::WriteAllText($script:Log, '', $Utf8)
$mode = if ($Check) { 'check' } else { 'install' }
if ($NoLock) { $mode += ', no lock' }
Say "os.ivan.gg installer (script version $Version, mode: $mode)"
Say "Started $((Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm')) UTC. Log: $($script:Log)"

$code = 0
try {
    Install
} catch {
    if ($_.Exception.Data['install-stop']) { Show-Failure $_.Exception.Message }
    # Anything else is a bug in this script; the position helps fix it.
    else { Show-Failure ("Unexpected error: $($_.Exception.Message)`n$($_.InvocationInfo.PositionMessage)") }
    $code = 1
}
exit $code
