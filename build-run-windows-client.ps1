[CmdletBinding()]
param(
    [string]$ServerHost = "",
    [string]$ServerKey = "",
    [string]$RelayServer = "",
    [switch]$LockedServerExe,
    [switch]$NoRun,
    [switch]$ForceBuild,
    [switch]$SkipInline,
    [switch]$Help
)

$ErrorActionPreference = "Stop"

function Show-Usage {
    Write-Host "Builds the Nemo RustDesk Windows client, stages it, and runs it."
    Write-Host ""
    Write-Host "Usage from rustdesk-nemo-flavour:"
    Write-Host "  .\build-run-windows-client.ps1"
    Write-Host ""
    Write-Host "Optional:"
    Write-Host "  .\build-run-windows-client.ps1 -NoRun"
    Write-Host "  .\build-run-windows-client.ps1 -ForceBuild"
    Write-Host "  .\build-run-windows-client.ps1 -LockedServerExe -ServerHost 192.168.0.176 -ServerKey '<key>'"
    Write-Host ""
    Write-Host "Default no-argument mode launches plain rustdesk.exe, so server settings stay editable in the GUI."
    Write-Host "LockedServerExe mode launches a rustdesk-host=...,key=... executable, so the GUI server settings are read-only."
}

if ($Help) {
    Show-Usage
    return
}

function Resolve-RequiredPath {
    param(
        [string]$Path,
        [string]$Label
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "$Label not found: $Path"
    }

    return (Resolve-Path -LiteralPath $Path).Path
}

function Invoke-GitText {
    param(
        [string]$RepoPath,
        [string[]]$Arguments,
        [switch]$AllowFailure
    )

    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $output = & git -c core.autocrlf=false -C $RepoPath @Arguments 2>$null
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    if ($exitCode -ne 0 -and -not $AllowFailure) {
        throw "git $($Arguments -join ' ') failed in $RepoPath"
    }

    if ($null -eq $output) {
        return ""
    }

    return ($output -join "`n")
}

function Get-Sha256Text {
    param([string]$Text)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
        return [System.BitConverter]::ToString($sha.ComputeHash($bytes)).Replace("-", "").ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
}

function Get-FileHashValue {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return ""
    }

    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-GitFileList {
    param([string]$RepoPath)

    $tracked = Invoke-GitText $RepoPath @("ls-files")
    $untracked = Invoke-GitText $RepoPath @("ls-files", "--others", "--exclude-standard")
    return @($tracked, $untracked) |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        ForEach-Object { $_ -split "`n" } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Sort-Object -Unique
}

function Get-SubmodulePaths {
    param([string]$RepoPath)

    $raw = Invoke-GitText $RepoPath @("config", "--file", ".gitmodules", "--get-regexp", "path") -AllowFailure
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return @()
    }

    return $raw -split "`n" |
        ForEach-Object {
            $parts = $_ -split "\s+", 2
            if ($parts.Count -eq 2) { $parts[1] }
        } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
}

function Add-GitRepoFingerprintParts {
    param(
        [System.Collections.Generic.List[string]]$Parts,
        [string]$RepoPath,
        [string]$Label
    )

    $Parts.Add("$Label/head=" + (Invoke-GitText $RepoPath @("rev-parse", "HEAD")))
    $Parts.Add("$Label/status=" + (Invoke-GitText $RepoPath @("status", "--porcelain=v1", "--untracked-files=normal")))
    $Parts.Add("$Label/diff=" + (Get-Sha256Text (Invoke-GitText $RepoPath @("diff", "--binary", "--no-ext-diff", "--"))))
    $Parts.Add("$Label/cached=" + (Get-Sha256Text (Invoke-GitText $RepoPath @("diff", "--cached", "--binary", "--no-ext-diff", "--"))))

    foreach ($relative in Get-GitFileList $RepoPath) {
        $fullPath = Join-Path $RepoPath $relative
        if (Test-Path -LiteralPath $fullPath -PathType Leaf) {
            $Parts.Add("$Label/file/$relative=" + (Get-FileHashValue $fullPath))
        }
    }
}

function Get-ClientBuildFingerprint {
    param(
        [string]$ClientPath,
        [bool]$SkipInline
    )

    $parts = [System.Collections.Generic.List[string]]::new()
    $parts.Add("stamp-version=2")
    $parts.Add("profile=release")
    $parts.Add("features=inline")
    $parts.Add("skip-inline=$SkipInline")

    Add-GitRepoFingerprintParts $parts $ClientPath "client"

    foreach ($submodule in Get-SubmodulePaths $ClientPath) {
        $submodulePath = Join-Path $ClientPath $submodule
        if (Test-Path -LiteralPath $submodulePath -PathType Container) {
            Add-GitRepoFingerprintParts $parts $submodulePath "submodule/$submodule"
        }
    }

    return Get-Sha256Text ($parts -join "`n")
}

function Get-LatestGitFileWriteTimeUtc {
    param([string]$RepoPath)

    $latest = [DateTime]::MinValue
    foreach ($relative in Get-GitFileList $RepoPath) {
        $fullPath = Join-Path $RepoPath $relative
        if (Test-Path -LiteralPath $fullPath -PathType Leaf) {
            $mtime = (Get-Item -LiteralPath $fullPath).LastWriteTimeUtc
            if ($mtime -gt $latest) {
                $latest = $mtime
            }
        }
    }

    foreach ($submodule in Get-SubmodulePaths $RepoPath) {
        $submodulePath = Join-Path $RepoPath $submodule
        if (Test-Path -LiteralPath $submodulePath -PathType Container) {
            $mtime = Get-LatestGitFileWriteTimeUtc $submodulePath
            if ($mtime -gt $latest) {
                $latest = $mtime
            }
        }
    }

    return $latest
}

function Read-BuildStamp {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }

    try {
        return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    }
    catch {
        return $null
    }
}

function Write-BuildStamp {
    param(
        [string]$Path,
        [string]$Fingerprint,
        [string]$ClientExe,
        [string]$ServiceExe,
        [string]$Reason
    )

    $stamp = [ordered]@{
        version = 2
        builtAt = (Get-Date).ToString("o")
        reason = $Reason
        fingerprint = $Fingerprint
        rustdeskExeHash = Get-FileHashValue $ClientExe
        serviceExeHash = Get-FileHashValue $ServiceExe
    }

    $stamp | ConvertTo-Json | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Test-ExistingBuildLooksCurrent {
    param(
        [string]$ClientPath,
        [string]$ClientExe,
        [string]$ServiceExe
    )

    if (-not (Test-Path -LiteralPath $ClientExe -PathType Leaf)) { return $false }
    if (-not (Test-Path -LiteralPath $ServiceExe -PathType Leaf)) { return $false }

    $oldestTarget = (Get-Item -LiteralPath $ClientExe).LastWriteTimeUtc
    $serviceTime = (Get-Item -LiteralPath $ServiceExe).LastWriteTimeUtc
    if ($serviceTime -lt $oldestTarget) {
        $oldestTarget = $serviceTime
    }

    return (Get-LatestGitFileWriteTimeUtc $ClientPath) -le $oldestTarget
}

function Copy-IfChanged {
    param(
        [string]$Source,
        [string]$Destination
    )

    if ((Test-Path -LiteralPath $Destination -PathType Leaf) -and
        ((Get-FileHashValue $Source) -eq (Get-FileHashValue $Destination))) {
        return $false
    }

    Copy-Item -LiteralPath $Source -Destination $Destination -Force
    return $true
}

$Root = $PSScriptRoot
$ClientPath = Resolve-RequiredPath (Join-Path $Root "rustdesk-client-nemo") "Client repo"
$StagePath = Join-Path $Root "run-windows-client"
$UseLockedServerExe = $LockedServerExe -or
    -not [string]::IsNullOrWhiteSpace($ServerHost) -or
    -not [string]::IsNullOrWhiteSpace($ServerKey) -or
    -not [string]::IsNullOrWhiteSpace($RelayServer)

if ($UseLockedServerExe -and [string]::IsNullOrWhiteSpace($ServerHost)) {
    throw "Locked server executable mode requires -ServerHost."
}

New-Item -ItemType Directory -Path $StagePath -Force | Out-Null

if ($UseLockedServerExe) {
    $parts = @("host=$ServerHost")
    if (-not [string]::IsNullOrWhiteSpace($ServerKey)) {
        $parts += "key=$ServerKey"
    }
    if (-not [string]::IsNullOrWhiteSpace($RelayServer)) {
        $parts += "relay=$RelayServer"
    }
    $ExeName = "rustdesk-" + ($parts -join ",") + ",.exe"
} else {
    $ExeName = "rustdesk.exe"
}

$ClientExe = Join-Path $ClientPath "target\release\rustdesk.exe"
$ServiceExe = Join-Path $ClientPath "target\release\service.exe"
$StagedClientExe = Join-Path $StagePath $ExeName
$StagedServiceExe = Join-Path $StagePath "service.exe"
$StampPath = Join-Path $StagePath ".nemo-windows-client-build-stamp.json"

Write-Host "Root:          $Root"
Write-Host "Client repo:   $ClientPath"
Write-Host "Stage folder:  $StagePath"
Write-Host "Launch mode:   $(if ($UseLockedServerExe) { 'locked executable server config' } else { 'editable GUI server config' })"
Write-Host ""

$CurrentFingerprint = Get-ClientBuildFingerprint $ClientPath ([bool]$SkipInline)
$BuildNeeded = $false
$BuildReason = "build stamp matches current code"
$Stamp = Read-BuildStamp $StampPath

if ($ForceBuild) {
    $BuildNeeded = $true
    $BuildReason = "ForceBuild requested"
} elseif (-not (Test-Path -LiteralPath $ClientExe -PathType Leaf)) {
    $BuildNeeded = $true
    $BuildReason = "target rustdesk.exe is missing"
} elseif (-not (Test-Path -LiteralPath $ServiceExe -PathType Leaf)) {
    $BuildNeeded = $true
    $BuildReason = "target service.exe is missing"
} elseif ($null -eq $Stamp) {
    if (Test-ExistingBuildLooksCurrent $ClientPath $ClientExe $ServiceExe) {
        $BuildReason = "no stamp found, but target binaries are newer than tracked client sources"
        Write-Host "Build check:   $BuildReason"
        Write-BuildStamp $StampPath $CurrentFingerprint $ClientExe $ServiceExe $BuildReason
    } else {
        $BuildNeeded = $true
        $BuildReason = "build stamp is missing and target binaries look older than source files"
    }
} elseif ($Stamp.fingerprint -ne $CurrentFingerprint) {
    $BuildNeeded = $true
    $BuildReason = "client code fingerprint changed"
} elseif ($Stamp.rustdeskExeHash -ne (Get-FileHashValue $ClientExe)) {
    $BuildNeeded = $true
    $BuildReason = "target rustdesk.exe does not match build stamp"
} elseif ($Stamp.serviceExeHash -ne (Get-FileHashValue $ServiceExe)) {
    $BuildNeeded = $true
    $BuildReason = "target service.exe does not match build stamp"
}

if ($BuildNeeded) {
    $VcpkgRoot = Resolve-RequiredPath (Join-Path $Root "tools\vcpkg-120deac") "VCPKG root"
    $LlvmBin = Resolve-RequiredPath (Join-Path $Root "tools\llvm-15.0.6\bin") "LLVM bin"
    $CargoExe = Join-Path $env:USERPROFILE ".cargo\bin\cargo.exe"

    if (-not (Test-Path -LiteralPath $CargoExe)) {
        $CargoCommand = Get-Command cargo -ErrorAction SilentlyContinue
        if (-not $CargoCommand) {
            throw "cargo not found. Expected $CargoExe or cargo on PATH."
        }
        $CargoExe = $CargoCommand.Source
    }

    if (-not $SkipInline -and -not (Get-Command python -ErrorAction SilentlyContinue)) {
        throw "python not found on PATH. It is needed to regenerate the inline Sciter UI."
    }

    $env:VCPKG_ROOT = $VcpkgRoot
    $env:LIBCLANG_PATH = $LlvmBin

    Write-Host "Build check:   $BuildReason"
    Write-Host "VCPKG_ROOT:    $env:VCPKG_ROOT"
    Write-Host "LIBCLANG_PATH: $env:LIBCLANG_PATH"
    Write-Host ""

    Push-Location $ClientPath
    # cargo and python write progress and warnings to stderr. Under the script-level
    # ErrorActionPreference=Stop, PowerShell 5.1 turns the first stderr line from a
    # native command into a terminating NativeCommandError and aborts the build even
    # when the tool exits 0. Drop to Continue for the native calls and rely on the
    # explicit $LASTEXITCODE checks below (an explicit `throw` still terminates).
    $previousBuildEap = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        if (-not $SkipInline) {
            Write-Host "Regenerating inline Sciter UI..."
            & python .\res\inline-sciter.py
            if ($LASTEXITCODE -ne 0) {
                throw "inline-sciter.py failed with exit code $LASTEXITCODE"
            }
        }

        Write-Host "Building RustDesk Windows client..."
        & $CargoExe build --release --features inline
        if ($LASTEXITCODE -ne 0) {
            throw "cargo build failed with exit code $LASTEXITCODE"
        }
    }
    finally {
        $ErrorActionPreference = $previousBuildEap
        Pop-Location
    }

    $CurrentFingerprint = Get-ClientBuildFingerprint $ClientPath ([bool]$SkipInline)
    Write-BuildStamp $StampPath $CurrentFingerprint $ClientExe $ServiceExe $BuildReason
} else {
    Write-Host "Build check:   no rebuild needed"
}

$CopiedClient = Copy-IfChanged $ClientExe $StagedClientExe
$CopiedService = Copy-IfChanged $ServiceExe $StagedServiceExe

if ($CopiedClient -or $CopiedService) {
    Write-Host "Stage update:  copied changed build outputs"
} else {
    Write-Host "Stage update:  staged build outputs already current"
}

if (-not (Test-Path -LiteralPath (Join-Path $StagePath "sciter.dll"))) {
    Write-Warning "sciter.dll is missing in $StagePath. The client may not start until it is copied there."
}

Write-Host ""
Write-Host "Staged client:"
Get-Item -LiteralPath $StagedClientExe | Select-Object FullName, Length, LastWriteTime

if (-not $NoRun) {
    Write-Host ""
    Write-Host "Starting RustDesk client..."
    Start-Process -FilePath $StagedClientExe -WorkingDirectory $StagePath
}
