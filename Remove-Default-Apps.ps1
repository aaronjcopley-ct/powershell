<#
.SYNOPSIS
    Removes a set of default Windows/Microsoft apps for all existing users
    AND de-provisions them, so newly provisioned devices (and any new user
    profile created on an already-provisioned device) come up clean without
    them -- built for Intune deployment.

.DESCRIPTION
    WHY THIS DOESN'T USE winget (unlike the example commands this was built
    from): winget is unreliable when run as SYSTEM, which is how Intune
    deploys scripts/Win32 apps. App Installer registers itself per-user, and
    winget.exe is frequently not resolvable on PATH in the SYSTEM profile --
    a well-documented, common failure mode, not a style choice. All of the
    target apps here are pre-provisioned AppX/MSIX packages anyway, which
    have a purpose-built, reliable removal path that doesn't depend on
    winget at all.

    WHY BOTH Remove-AppxPackage AND Remove-AppxProvisionedPackage: these do
    different things.
      - Remove-AppxPackage (-AllUsers) removes the app for every user
        account that CURRENTLY EXISTS on the device.
      - Remove-AppxProvisionedPackage removes it from the device's
        provisioning image, which is what actually matters for "newly
        provisioned devices run clean" -- provisioned packages are what get
        auto-staged into every NEW user profile created on that device
        afterward. Skipping this step means the app would silently
        reappear the next time someone new logs into the machine.
    Both are needed for the stated objective; this script does both for
    every app, in that order.

    WHY WILDCARD MATCHING instead of exact package names: Microsoft renames
    and re-versions these package family names across Windows builds more
    often than you'd expect (Microsoft 365 Copilot alone has reused at
    least one older package ID and has a same-named-but-different sibling
    app, "Microsoft Copilot", with its own separate package). Wildcard
    matching against each app's stable name fragment is the standard,
    resilient approach recommended for exactly this reason, rather than
    one exact string that might not match on a given build.

    NOT INCLUDED: no execution policy change. Intune's own script/Win32 app
    deployment mechanism already runs this script with execution policy
    bypassed -- permanently weakening a device's execution policy to
    "Unrestricted" as a side effect of an app-cleanup script isn't
    necessary and isn't something this script does.

    Must be run elevated (Administrator) -- required for -AllUsers removal
    and for de-provisioning. Runs fine as SYSTEM (the normal Intune context).

.EXAMPLE
    .\Remove-DefaultApps.ps1
#>

[CmdletBinding()]
param(
    [string]$LogPath = "$env:ProgramData\IntuneAppCleanup\Remove-DefaultApps-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
)

function Write-Log {
    param([string]$Message, [string]$Color = 'White')
    $line = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $Message
    Write-Host $line -ForegroundColor $Color
    try {
        $logDir = Split-Path $LogPath -Parent
        if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
        Add-Content -Path $LogPath -Value $line
    } catch {
        # Logging failure shouldn't block the actual cleanup.
    }
}

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdmin)) {
    Write-Error "This script must be run as Administrator (or as SYSTEM via Intune). Re-launch elevated and try again."
    return
}

Write-Log "=== Default App Removal (for all users + de-provisioning) ===" 'Cyan'
Write-Log "Log file: $LogPath"
Write-Log ""

# Friendly name -> wildcard match pattern (matched against both
# Get-AppxPackage's Name and Get-AppxProvisionedPackage's DisplayName).
$appsToRemove = [ordered]@{
    'Microsoft Outlook (new)'        = '*OutlookForWindows*'
    'Feedback Hub'                   = '*WindowsFeedbackHub*'
    'Get Help'                       = '*GetHelp*'
    'Get Started / Tips'             = '*Getstarted*'
    'Microsoft 365 Copilot'          = '*Copilot*'
    'Microsoft News'                 = '*BingNews*'
    'Microsoft To Do'                = '*Todos*'
    'Phone Link'                     = '*YourPhone*'
    'Solitaire & Casual Games'       = '*MicrosoftSolitaireCollection*'
    'WhatsApp'                       = '*WhatsApp*'
    'LinkedIn'                       = '*LinkedIn*'
    'Xbox (full family)'             = '*Xbox*'
}

$summary = @()

foreach ($appName in $appsToRemove.Keys) {
    $pattern = $appsToRemove[$appName]
    Write-Log "--- $appName ($pattern) ---" 'Cyan'

    $userRemoved = 0
    $userFailed = 0
    $provRemoved = 0
    $provFailed = 0

    # --- Remove for all existing user accounts on this device -------------
    try {
        $installedPackages = Get-AppxPackage -AllUsers -Name $pattern -ErrorAction SilentlyContinue
        if ($installedPackages) {
            foreach ($pkg in $installedPackages) {
                try {
                    Remove-AppxPackage -Package $pkg.PackageFullName -AllUsers -ErrorAction Stop
                    Write-Log "  Removed (all users): $($pkg.PackageFullName)" 'Green'
                    $userRemoved++
                } catch {
                    Write-Log "  FAILED to remove for existing users: $($pkg.PackageFullName) -- $($_.Exception.Message)" 'Red'
                    $userFailed++
                }
            }
        } else {
            Write-Log "  Not currently installed for any existing user -- nothing to remove here." 'DarkGray'
        }
    } catch {
        Write-Log "  Could not query installed packages: $($_.Exception.Message)" 'Red'
    }

    # --- De-provision so NEW user profiles / newly provisioned devices ----
    # --- never get this app staged in the first place ---------------------
    try {
        $provisionedPackages = Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like $pattern }
        if ($provisionedPackages) {
            foreach ($pkg in $provisionedPackages) {
                try {
                    Remove-AppxProvisionedPackage -Online -PackageName $pkg.PackageName -ErrorAction Stop | Out-Null
                    Write-Log "  De-provisioned: $($pkg.PackageName)" 'Green'
                    $provRemoved++
                } catch {
                    Write-Log "  FAILED to de-provision: $($pkg.PackageName) -- $($_.Exception.Message)" 'Red'
                    $provFailed++
                }
            }
        } else {
            Write-Log "  Not currently provisioned on this device -- nothing to de-provision here." 'DarkGray'
        }
    } catch {
        Write-Log "  Could not query provisioned packages: $($_.Exception.Message)" 'Red'
    }

    $status = if (($userFailed -eq 0) -and ($provFailed -eq 0)) { 'OK' } else { 'PARTIAL/FAILED' }
    $summary += [PSCustomObject]@{
        App               = $appName
        RemovedForUsers   = $userRemoved
        RemoveFailures    = $userFailed
        Deprovisioned     = $provRemoved
        DeprovisionFails  = $provFailed
        Status            = $status
    }
    Write-Log ""
}

# --- Best-effort supplementary attempt for Outlook via winget, as originally
# --- requested. NOT relied on as the primary mechanism (see header) --
# --- explicitly non-fatal if winget isn't resolvable in this context.
Write-Log "--- Supplementary: winget removal attempt for Outlook (best-effort) ---" 'Cyan'
$wingetPath = Get-Command winget.exe -ErrorAction SilentlyContinue
if ($wingetPath) {
    try {
        & winget.exe uninstall --id Microsoft.Outlook --silent --accept-source-agreements 2>&1 | ForEach-Object { Write-Log "  winget: $_" 'DarkGray' }
    } catch {
        Write-Log "  winget attempt failed (non-fatal, AppX removal above is the real mechanism): $($_.Exception.Message)" 'Yellow'
    }
} else {
    Write-Log "  winget.exe not resolvable in this session (expected/common under SYSTEM context) -- skipped. The AppX removal and de-provisioning above already cover Outlook regardless." 'DarkGray'
}

# --- Summary ------------------------------------------------------------

Write-Log ""
Write-Log "=== SUMMARY ===" 'Cyan'
foreach ($row in $summary) {
    $color = if ($row.Status -eq 'OK') { 'Green' } else { 'Yellow' }
    Write-Log ("{0,-28} Users:{1} Fail:{2}  Deprovisioned:{3} Fail:{4}  [{5}]" -f $row.App, $row.RemovedForUsers, $row.RemoveFailures, $row.Deprovisioned, $row.DeprovisionFails, $row.Status) $color
}

$totalFailures = ($summary | Measure-Object -Property RemoveFailures, DeprovisionFails -Sum).Sum
if ($totalFailures -gt 0) {
    Write-Log "`n$totalFailures failure(s) recorded above -- check log for exact package names/errors. Common, harmless causes: the app was never present on this specific image/build, or NonRemovable=True was flagged by the OS. This is expected for a few of the Xbox-family sub-packages specifically (e.g. Xbox Identity Provider, Xbox Game Bar) -- Windows treats some of them as dependencies other apps/games rely on, so it protects them from removal even when the main Xbox storefront app itself is removed successfully." 'Yellow'
} else {
    Write-Log "`nAll targeted apps removed and de-provisioned successfully (or were already absent)." 'Green'
}
