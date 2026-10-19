<#
.SYNOPSIS
    Detects whether the OS drive is BitLocker-encrypted with XTS-AES 256-bit.
    If not, hands off the actual decrypt + re-encrypt work to a background
    Scheduled Task and exits -- built for Intune deployment.

.DESCRIPTION
    WHY THIS DOESN'T JUST RUN THE THREE COMMANDS DIRECTLY:

    1. manage-bde -off starts a BACKGROUND decrypt, not instant. On a large
       or fairly-full drive this can take minutes to hours. Calling
       Enable-BitLocker before decryption actually finishes will fail or
       leave the volume in an inconsistent state.

    2. Intune Platform scripts have an execution timeout. If the decrypt +
       re-encrypt cycle runs longer than that timeout, Intune kills the
       script mid-operation -- which could leave the drive DECRYPTED
       (unprotected) for however long it takes someone to notice and
       manually finish the job. That is a worse outcome than the original
       AES-128 finding. This script avoids that entirely: it only detects
       the condition and hands the actual work to a Scheduled Task, which
       is NOT subject to Intune's script timeout and keeps running to
       completion even after this script reports back to Intune and exits.

    3. -TpmProtector will fail with a cryptic error if there's no ready TPM.
       This checks first and reports clearly instead.

    4. Re-encrypting without capturing a recovery key is how you end up
       locked out. The background worker adds a recovery password
       protector, saves it locally with a loud warning to escrow it
       properly, and attempts automatic AD backup if domain-joined.

    Must be run elevated (Administrator). Designed to run as SYSTEM via
    Intune (Platform script, "Run this script using the logged-on
    credentials: No").

.PARAMETER UsedSpaceOnly
    Encrypt only used disk space during re-encryption (default: on). Much
    faster than full-volume encryption, especially on a mostly-empty drive.
    Pass -UsedSpaceOnly:$false for full-volume encryption instead.

.EXAMPLE
    .\Set-BitLockerAES256.ps1
#>

[CmdletBinding()]
param(
    [switch]$UsedSpaceOnly = $true,
    [string]$LogDir = "$env:ProgramData\BitLockerAES256"
)

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdmin)) {
    Write-Error "This script must be run as Administrator (or as SYSTEM via Intune). Re-launch elevated and try again."
    return
}

if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
$dispatchLog = "$LogDir\Dispatch-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"

function Write-DispatchLog {
    param([string]$Message, [string]$Color = 'White')
    $line = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $Message
    Write-Host $line -ForegroundColor $Color
    Add-Content -Path $dispatchLog -Value $line
}

Write-DispatchLog "=== BitLocker AES-256 detection ===" 'Cyan'

# --- Detect current state ---------------------------------------------

$osVol = Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction SilentlyContinue
if (-not $osVol) {
    Write-DispatchLog "Could not query BitLocker status for $env:SystemDrive -- BitLocker module unavailable or drive not found. Aborting." 'Red'
    return
}

$currentMethod = $osVol.EncryptionMethod
$isAes256 = ($currentMethod -eq 'XtsAes256')

Write-DispatchLog "Current state: ProtectionStatus=$($osVol.ProtectionStatus), EncryptionMethod=$currentMethod, VolumeStatus=$($osVol.VolumeStatus)"

if ($isAes256) {
    Write-DispatchLog "Already XTS-AES 256-bit. No action needed." 'Green'
    return
}

# --- TPM check before committing to anything ----------------------------

$tpm = Get-Tpm -ErrorAction SilentlyContinue
if (-not $tpm -or -not $tpm.TpmPresent -or -not $tpm.TpmReady) {
    Write-DispatchLog "No ready TPM detected. Cannot safely proceed with -TpmProtector re-encryption. Aborting -- this needs manual attention (check TPM state, firmware/BIOS settings) before any BitLocker changes are attempted on this device." 'Red'
    return
}

Write-DispatchLog "TPM confirmed ready. Current encryption is $currentMethod, not XTS-AES 256 -- dispatching background re-encryption task." 'Yellow'

# --- Write the worker script that does the actual long-running work -----

$workerPath = "$LogDir\Worker-BitLockerAES256.ps1"
$workerLog = "$LogDir\Worker-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
$recoveryKeyPath = "$env:SystemDrive\BitLocker-Recovery-$(Get-Date -Format 'yyyyMMdd-HHmmss').txt"
$usedSpaceOnlyFlag = if ($UsedSpaceOnly) { '-UsedSpaceOnly' } else { '' }

$workerContent = @"
`$ErrorActionPreference = 'Continue'
`$logPath = '$workerLog'

function Write-WorkerLog {
    param([string]`$Message)
    `$line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), `$Message
    Add-Content -Path `$logPath -Value `$line
}

Write-WorkerLog "=== BitLocker AES-256 background worker started ==="

`$sysDrive = '$env:SystemDrive'
`$osVol = Get-BitLockerVolume -MountPoint `$sysDrive -ErrorAction SilentlyContinue

if (`$osVol -and `$osVol.ProtectionStatus -eq 'On') {
    Write-WorkerLog "Turning BitLocker off to allow re-encryption at a different algorithm..."
    manage-bde -off `$sysDrive | Out-Null

    Write-WorkerLog "Waiting for decryption to fully complete before re-encrypting (this is the long-running part)..."
    `$maxWaitHours = 24
    `$deadline = (Get-Date) + (New-TimeSpan -Hours `$maxWaitHours)
    do {
        Start-Sleep -Seconds 30
        `$osVol = Get-BitLockerVolume -MountPoint `$sysDrive -ErrorAction SilentlyContinue
        if (`$osVol) {
            Write-WorkerLog "  VolumeStatus=`$(`$osVol.VolumeStatus), EncryptionPercentage=`$(`$osVol.EncryptionPercentage)%"
        }
    } while (`$osVol -and `$osVol.VolumeStatus -ne 'FullyDecrypted' -and (Get-Date) -lt `$deadline)

    if (`$osVol.VolumeStatus -ne 'FullyDecrypted') {
        Write-WorkerLog "TIMED OUT waiting for decryption after `$maxWaitHours hours (VolumeStatus=`$(`$osVol.VolumeStatus)). Aborting re-encryption -- manual investigation needed. Drive may currently be UNPROTECTED; treat as urgent."
        exit 1
    }
    Write-WorkerLog "Decryption confirmed complete."
} else {
    Write-WorkerLog "Drive was not already BitLocker-protected -- skipping decrypt step, proceeding straight to encryption."
}

Write-WorkerLog "Enabling BitLocker with XtsAes256 + TPM protector..."
try {
    if ('$usedSpaceOnlyFlag') {
        Enable-BitLocker -MountPoint `$sysDrive -EncryptionMethod XtsAes256 -TpmProtector -UsedSpaceOnly -ErrorAction Stop
    } else {
        Enable-BitLocker -MountPoint `$sysDrive -EncryptionMethod XtsAes256 -TpmProtector -ErrorAction Stop
    }
    Write-WorkerLog "Enable-BitLocker command completed."
} catch {
    Write-WorkerLog "Enable-BitLocker FAILED: `$(`$_.Exception.Message)"
    exit 1
}

Write-WorkerLog "Waiting a moment for the protector list to settle, then adding/confirming a recovery password protector..."
Start-Sleep -Seconds 10
`$osVol = Get-BitLockerVolume -MountPoint `$sysDrive -ErrorAction SilentlyContinue
`$recoveryProtector = `$osVol.KeyProtector | Where-Object { `$_.KeyProtectorType -eq 'RecoveryPassword' } | Select-Object -First 1

if (-not `$recoveryProtector) {
    Add-BitLockerKeyProtector -MountPoint `$sysDrive -RecoveryPasswordProtector | Out-Null
    `$osVol = Get-BitLockerVolume -MountPoint `$sysDrive -ErrorAction SilentlyContinue
    `$recoveryProtector = `$osVol.KeyProtector | Where-Object { `$_.KeyProtectorType -eq 'RecoveryPassword' } | Select-Object -First 1
}

if (`$recoveryProtector) {
    "BitLocker Recovery Key for `$sysDrive`nGenerated: `$(Get-Date -Format 'o')`nComputer: `$env:COMPUTERNAME`nRecovery Key ID: `$(`$recoveryProtector.KeyProtectorId)`nRecovery Password: `$(`$recoveryProtector.RecoveryPassword)" |
        Out-File -FilePath '$recoveryKeyPath' -Encoding UTF8
    Write-WorkerLog "RECOVERY KEY SAVED TO: $recoveryKeyPath -- move this off the device immediately (secure share, password manager, escrow system). Anyone with disk access to this unencrypted text file could read it."

    try {
        `$csInfo = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        if (`$csInfo.PartOfDomain) {
            Backup-BitLockerKeyProtector -MountPoint `$sysDrive -KeyProtectorId `$recoveryProtector.KeyProtectorId -ErrorAction Stop
            Write-WorkerLog "Recovery key also backed up to Active Directory."
        } else {
            Write-WorkerLog "Device is not domain-joined -- skipped AD backup. If Entra ID (Azure AD) joined, confirm the key escrowed automatically, or back it up manually: manage-bde -protectors -adbackup `$sysDrive -id `$(`$recoveryProtector.KeyProtectorId)"
        }
    } catch {
        Write-WorkerLog "AD/Entra backup of recovery key failed or wasn't applicable: `$(`$_.Exception.Message). Key is still saved locally -- back it up manually."
    }
} else {
    Write-WorkerLog "Could not confirm a recovery password protector was created. Check manually: Get-BitLockerVolume -MountPoint `$sysDrive | Select -ExpandProperty KeyProtector"
}

`$finalVol = Get-BitLockerVolume -MountPoint `$sysDrive -ErrorAction SilentlyContinue
Write-WorkerLog "=== FINAL STATE: EncryptionMethod=`$(`$finalVol.EncryptionMethod), ProtectionStatus=`$(`$finalVol.ProtectionStatus), VolumeStatus=`$(`$finalVol.VolumeStatus), EncryptionPercentage=`$(`$finalVol.EncryptionPercentage)% ==="
Write-WorkerLog "=== Worker finished ==="
"@

Set-Content -Path $workerPath -Value $workerContent -Encoding UTF8

# --- Schedule it to run immediately, independent of this script's lifetime ---

try {
    $taskName = "BitLockerAES256-Worker-$(Get-Date -Format 'HHmmss')"
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$workerPath`""
    $trigger = New-ScheduledTaskTrigger -Once -At ((Get-Date) + (New-TimeSpan -Seconds 5))
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    # No time limit set on the task action itself -- Scheduled Tasks default
    # to no execution time cap unless one is explicitly configured, which is
    # the whole point: this survives past Intune's own script timeout.
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Force -ErrorAction Stop | Out-Null

    Write-DispatchLog "Background re-encryption task '$taskName' scheduled successfully (starts in ~5 seconds, runs as SYSTEM, no execution time limit)." 'Green'
    Write-DispatchLog "This script is now DONE -- the actual decrypt/re-encrypt work continues independently. Progress log: $workerLog" 'Cyan'
    Write-DispatchLog "Re-run verification later to confirm completion (this can take from under an hour to several hours depending on drive size)." 'Cyan'
} catch {
    Write-DispatchLog "Could not schedule the background worker task: $($_.Exception.Message). No changes were made to BitLocker -- safe to retry." 'Red'
}
