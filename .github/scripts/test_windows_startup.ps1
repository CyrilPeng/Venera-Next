[CmdletBinding(DefaultParameterSetName = 'Application')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Application')]
    [string]$Application,
    [Parameter(Mandatory, ParameterSetName = 'Installer')]
    [string]$Installer,
    [string]$OutputDirectory = 'build/windows/startup-smoke'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# This test installs and runs the real app. Never use a daily-use user profile.
if (-not $IsWindows -or $env:GITHUB_ACTIONS -ne 'true') {
    throw 'Full application startup tests require a disposable GitHub Actions Windows runner.'
}
if (@(Get-Process -Name VeneraNext -ErrorAction SilentlyContinue).Count -ne 0) {
    throw 'VeneraNext is already running. Refusing to touch existing processes.'
}
foreach ($hive in 'HKLM:', 'HKCU:') {
    foreach ($subkey in 'SOFTWARE', 'SOFTWARE\WOW6432Node') {
        $key = "$hive\$subkey\Microsoft\Windows\CurrentVersion\Uninstall\{C6B7E69A-0FD6-4F2A-AC64-7D1AE8A40FB8}_is1"
        if (Test-Path -LiteralPath $key) {
            throw 'An existing VeneraNext installation was found. Use a fresh runner.'
        }
    }
}
if (Test-Path -LiteralPath 'C:\Program Files (x86)\Venera') {
    throw 'A legacy Venera installation was found. Use a fresh runner.'
}
foreach ($root in $env:APPDATA, $env:LOCALAPPDATA) {
    foreach ($relative in @(
        'com.github.cyrilpeng\VeneraNext',
        'CyrilPeng_venera-next\VeneraNext',
        'CyrilPeng_venera-next\venera',
        'com.github.wgh136\venera'
    )) {
        if (Test-Path -LiteralPath (Join-Path $root $relative)) {
            throw "Existing app data was found: $relative. Use a fresh runner."
        }
    }
}

$workspace = (Resolve-Path -LiteralPath $env:GITHUB_WORKSPACE).Path.TrimEnd('\') + '\'
$output = [IO.Path]::GetFullPath($OutputDirectory)
if (-not $output.StartsWith($workspace, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Test output must be inside the current CI workspace.'
}
$testRoot = Join-Path $output ([Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
$startupLog = Join-Path $env:LOCALAPPDATA 'com.github.cyrilpeng\VeneraNext\logs\windows-startup.log'
$appPath = $null
$uninstaller = $null
$started = [Collections.Generic.List[Diagnostics.Process]]::new()

Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class StartupSmokeWindow {
    [DllImport("user32.dll")]
    public static extern bool IsIconic(IntPtr window);
    [DllImport("user32.dll")]
    public static extern bool ShowWindowAsync(IntPtr window, int command);
}
'@

function Wait-ForCondition([scriptblock]$Condition, [string]$Message, [int]$Seconds = 30) {
    $watch = [Diagnostics.Stopwatch]::StartNew()
    while ($watch.Elapsed.TotalSeconds -lt $Seconds) {
        if (& $Condition) { return }
        Start-Sleep -Milliseconds 200
    }
    throw $Message
}

function Wait-ForExit(
    [Diagnostics.Process]$Process,
    [int]$Seconds,
    [int]$Expected = 0,
    [switch]$ExpectFailure
) {
    if (-not $Process.WaitForExit($Seconds * 1000)) {
        throw "Process $($Process.Id) did not exit within $Seconds seconds."
    }
    $Process.Refresh()
    if ($ExpectFailure) {
        if ($Process.ExitCode -eq 0) {
            throw "Process $($Process.Id) succeeded despite missing Flutter resources."
        }
    } elseif ($Process.ExitCode -ne $Expected) {
        throw "Process $($Process.Id) returned $($Process.ExitCode); expected $Expected."
    }
}

function Start-TestProcess([string]$Path, [string]$Name) {
    $process = Start-Process -FilePath $Path -WorkingDirectory $testRoot `
        -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput (Join-Path $testRoot "$Name.stdout.log") `
        -RedirectStandardError (Join-Path $testRoot "$Name.stderr.log")
    $started.Add($process)
    # Retain the handle so even a fast secondary launch has a readable exit code.
    $null = $process.Handle
    return $process
}

function Has-StartupEvent([int]$ProcessId, [string]$Event) {
    try {
        $stream = [IO.File]::Open($startupLog, [IO.FileMode]::Open,
            [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        try {
            $reader = [IO.StreamReader]::new($stream)
            try {
                return $reader.ReadToEnd().Contains("pid=$ProcessId $Event")
            } finally {
                $reader.Dispose()
            }
        } finally {
            $stream.Dispose()
        }
    } catch [IO.IOException] {
        return $false
    }
}

try {
    if ($PSCmdlet.ParameterSetName -eq 'Installer') {
        $installerPath = (Resolve-Path -LiteralPath $Installer).Path
        $installDir = Join-Path $testRoot 'installed'
        $appPath = Join-Path $installDir 'VeneraNext.exe'
        $uninstaller = Join-Path $installDir 'unins000.exe'
        $installLog = Join-Path $testRoot 'installer.log'
        $setup = Start-Process -FilePath $installerPath -WindowStyle Hidden -PassThru `
            -ArgumentList @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-', '/ALLUSERS',
                "/DIR=`"$installDir`"", "/LOG=`"$installLog`"")
        $started.Add($setup)
        $null = $setup.Handle
        Wait-ForExit $setup 180 0
        Start-Sleep -Seconds 2
        if (@(Get-Process -Name VeneraNext -ErrorAction SilentlyContinue).Count -ne 0 -or
            (Test-Path -LiteralPath $startupLog)) {
            throw 'Silent installation unexpectedly started VeneraNext.'
        }
        Write-Output 'PASS: silent installation did not start the application.'
    } else {
        $appPath = (Resolve-Path -LiteralPath $Application).Path
    }
    if (-not (Test-Path -LiteralPath $appPath -PathType Leaf)) {
        throw "Application not found: $appPath"
    }

    $primary = Start-TestProcess $appPath 'primary'
    Wait-ForCondition {
        $primary.Refresh()
        if ($primary.HasExited) { throw "First launch exited early: $($primary.ExitCode)" }
        return $primary.MainWindowHandle -ne [IntPtr]::Zero -and
            (Has-StartupEvent $primary.Id 'First Flutter frame rendered')
    } 'First launch did not produce a window and a Flutter frame.' 60
    $watch = [Diagnostics.Stopwatch]::StartNew()
    while ($watch.Elapsed.TotalSeconds -lt 12) {
        if ($primary.HasExited) { throw 'The primary instance exited during the startup observation period.' }
        Start-Sleep -Milliseconds 200
    }
    Write-Output 'PASS: first launch rendered a frame and remained running for over 10 seconds.'

    $window = $primary.MainWindowHandle
    [StartupSmokeWindow]::ShowWindowAsync($window, 6) | Out-Null
    Wait-ForCondition { [StartupSmokeWindow]::IsIconic($window) } 'Could not minimize the primary window.'
    foreach ($attempt in 1..5) {
        $secondary = Start-TestProcess $appPath "secondary-$attempt"
        Wait-ForExit $secondary 10 0
        if (-not (Has-StartupEvent $secondary.Id 'Existing instance handled; exiting successfully')) {
            throw 'Repeated launch did not report an existing-instance handoff.'
        }
        if ($primary.HasExited) { throw 'Repeated launch stopped the primary instance.' }
    }
    Wait-ForCondition { -not [StartupSmokeWindow]::IsIconic($window) } 'Repeated launch did not restore the window.'
    Write-Output 'PASS: five repeated launches returned 0 and restored the original window.'
    $primary.CloseMainWindow() | Out-Null
    Wait-ForExit $primary 15 0

    # Copy binaries only: missing Flutter data must fail, not look like a handoff.
    $brokenDir = Join-Path $testRoot 'missing-data'
    New-Item -ItemType Directory -Path $brokenDir | Out-Null
    Get-ChildItem -LiteralPath (Split-Path -Parent $appPath) -File |
        Where-Object { $_.Extension -in '.exe', '.dll' } |
        ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $brokenDir }
    $broken = Start-TestProcess (Join-Path $brokenDir 'VeneraNext.exe') 'missing-data'
    Wait-ForExit $broken 30 -ExpectFailure
    if (-not (Has-StartupEvent $broken.Id 'Creating Flutter engine and view')) {
        throw 'A failing startup did not leave native diagnostics.'
    }
    if ((Get-Item -LiteralPath $startupLog).Length -gt 131072) {
        throw 'The startup log exceeded its size limit.'
    }
    Write-Output 'PASS: missing Flutter data produced a nonzero exit and startup diagnostics.'
} finally {
    # Only stop handles started by this test, plus an installer-launched instance
    # whose executable path belongs to this fresh test installation.
    if ($uninstaller -and $appPath) {
        Get-Process -Name VeneraNext -ErrorAction SilentlyContinue |
            Where-Object { $_.Path -eq $appPath } |
            ForEach-Object { $started.Add($_) }
    }
    foreach ($process in $started) {
        if (-not $process.HasExited) {
            $process.Kill()
            $process.WaitForExit(5000) | Out-Null
        }
        $process.Dispose()
    }
    if (Test-Path -LiteralPath $startupLog) {
        Copy-Item -LiteralPath $startupLog -Destination (Join-Path $testRoot 'windows-startup.log')
    }
    if ($uninstaller -and (Test-Path -LiteralPath $uninstaller)) {
        $cleanup = Start-Process -FilePath $uninstaller -WindowStyle Hidden -PassThru `
            -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART'
        try {
            $null = $cleanup.Handle
            Wait-ForExit $cleanup 90 0
        } finally {
            if (-not $cleanup.HasExited) { $cleanup.Kill() }
            $cleanup.Dispose()
        }
    }
    Write-Output "Startup test diagnostics: $testRoot"
}
