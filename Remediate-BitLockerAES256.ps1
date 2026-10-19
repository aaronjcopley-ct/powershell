<#
.SYNOPSIS
    Remediation script - brings the OS drive to XTS-AES 256 regardless of
    starting state:
      - Unencrypted        -> Enable-BitLocker directly with XtsAes256
      - Encrypted (128-bit)-> Disable-BitLocker (decrypt), wait, then
                              Enable-BitLocker with XtsAes256
      - Already 256-bit    -> no-op
    Ends by re-running the detection logic and logging/exiting on the
    final observed state, so the log always reflects ground truth rather
    than an assumption that the requested action worked.

.NOTES
    - Full decrypt/re-encrypt of an already-encrypted 128-bit volume is
      slow and disruptive. Pilot this before wide deployment.
    - Assumes a TPM protector is desired for unattended operation. Adjust
      if your environment requires PIN/startup key policies instead.
#>

$osDrive = $env:SystemDrive
$logPath = "$env:ProgramData\IntuneRemediation\BitLockerAES256.log"
New-Item -ItemType Directory -Path (Split-Path $logPath) -Force -ErrorAction SilentlyContinue | Out-Null

function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$timestamp - $Message" | Out-File -FilePath $logPath -Append
}

function Get-DriveState {
    param([string]$MountPoint)
    $vol = Get-BitLockerVolume -MountPoint $MountPoint -ErrorAction Stop
    [PSCustomObject]@{
        VolumeStatus     = $vol.VolumeStatus
        EncryptionMethod = $vol.EncryptionMethod
        Percentage       = $vol.EncryptionPercentage
    }
}

function Wait-ForStatus {
    param(
        [string]$MountPoint,
        [string]$TargetStatus,
        [int]$TimeoutMinutes = 180,
        [int]$IntervalSeconds = 30
    )
    $elapsed = 0
    do {
        Start-Sleep -Seconds $IntervalSeconds
        $elapsed += $IntervalSeconds
        $state = Get-DriveState -MountPoint $MountPoint
        Write-Log "  ...status: $($state.VolumeStatus), method: $($state.EncryptionMethod), percent: $($state.Percentage)"
        if ($elapsed -ge ($TimeoutMinutes * 60)) {
            Write-Log "ERROR: Timed out after $TimeoutMinutes minutes waiting for status '$TargetStatus'."
            return $false
        }
    } while ($state.VolumeStatus -ne $TargetStatus)
    return $true
}

function Enable-Aes256 {
    param([string]$MountPoint)

    $hasTpm = [bool]((Get-BitLockerVolume -MountPoint $MountPoint).KeyProtector | Where-Object { $_.KeyProtectorType -eq 'Tpm' })

    if ($hasTpm) {
        Write-Log "TPM protector already present. Enabling BitLocker using -RecoveryPasswordProtector to satisfy the required parameter set (existing TPM protector will be used for encryption)."
        Enable-BitLocker -MountPoint $MountPoint -EncryptionMethod XtsAes256 `
            -UsedSpaceOnly -SkipHardwareTest -RecoveryPasswordProtector -ErrorAction Stop | Out-Null
    }
    else {
        Write-Log "No TPM protector found. Enabling BitLocker with a new TPM protector."
        Enable-BitLocker -MountPoint $MountPoint -EncryptionMethod XtsAes256 `
            -UsedSpaceOnly -SkipHardwareTest -TpmProtector -ErrorAction Stop | Out-Null
    }

    # Sanity check: confirm BitLocker actually turned on.
    $postEnable = Get-BitLockerVolume -MountPoint $MountPoint
    Write-Log "After Enable-BitLocker call: ProtectionStatus=$($postEnable.ProtectionStatus) VolumeStatus=$($postEnable.VolumeStatus) Method=$($postEnable.EncryptionMethod)"

    if ($postEnable.VolumeStatus -eq 'FullyDecrypted') {
        Write-Log "ERROR: Enable-BitLocker returned without error but drive is still FullyDecrypted. Treating as failure."
        throw "Enable-BitLocker completed but encryption did not start."
    }

    if (-not ((Get-BitLockerVolume -MountPoint $MountPoint).KeyProtector | Where-Object { $_.KeyProtectorType -eq 'RecoveryPassword' })) {
        Add-BitLockerKeyProtector -MountPoint $MountPoint -RecoveryPasswordProtector | Out-Null
        Write-Log "Added recovery password protector."
    }

    Resume-BitLocker -MountPoint $MountPoint | Out-Null

    $recoveryProtector = (Get-BitLockerVolume -MountPoint $MountPoint).KeyProtector |
        Where-Object { $_.KeyProtectorType -eq 'RecoveryPassword' } | Select-Object -First 1

    if ($recoveryProtector) {
        manage-bde -protectors -adbackup $MountPoint -id $recoveryProtector.KeyProtectorId
        Write-Log "Backed up recovery password to Entra ID (Microsoft Entra join required for this to land)."
    }
}

try {
    Write-Log "=== Remediation run started on $osDrive ==="

    $initial = Get-DriveState -MountPoint $osDrive
    Write-Log "Initial state: Status=$($initial.VolumeStatus) Method=$($initial.EncryptionMethod)"

    if ($initial.EncryptionMethod -like "*256*") {
        Write-Log "Already 256-bit. No action needed."
    }
    elseif ($initial.VolumeStatus -eq 'FullyDecrypted') {
        Write-Log "Drive is unencrypted. Enabling BitLocker directly with XtsAes256."
        Enable-Aes256 -MountPoint $osDrive
        Write-Log "Enable-BitLocker issued. Encryption will proceed in the background."
    }
    elseif ($initial.EncryptionMethod -like "*128*") {
        Write-Log "Drive is encrypted with a 128-bit method. Decrypting first."
        Disable-BitLocker -MountPoint $osDrive | Out-Null

        $decrypted = Wait-ForStatus -MountPoint $osDrive -TargetStatus 'FullyDecrypted'
        if (-not $decrypted) {
            Write-Log "ERROR: Decryption did not complete in time. Aborting remediation."
            exit 1
        }

        Write-Log "Drive fully decrypted. Enabling BitLocker with XtsAes256."
        Enable-Aes256 -MountPoint $osDrive
        Write-Log "Enable-BitLocker issued. Encryption will proceed in the background."
    }
    else {
        Write-Log "Drive is in an unrecognized or in-progress state (Status=$($initial.VolumeStatus), Method=$($initial.EncryptionMethod)). Taking no destructive action; will re-check below."
    }

    # Re-detect: report final observed state rather than assuming success.
    # Note: if encryption was just triggered above, it runs in the background,
    # so "compliant" may not show immediately on this same run - that is expected.
    Start-Sleep -Seconds 10
    $final = Get-DriveState -MountPoint $osDrive
    Write-Log "Post-remediation state: Status=$($final.VolumeStatus) Method=$($final.EncryptionMethod) Percent=$($final.Percentage)"

    if ($final.EncryptionMethod -like "*256*") {
        Write-Log "Result: COMPLIANT (256-bit)."
        exit 0
    }
    elseif ($final.VolumeStatus -eq 'EncryptionInProgress' -or $final.VolumeStatus -eq 'DecryptionInProgress') {
        Write-Log "Result: IN PROGRESS. Re-run detection later; a follow-up remediation cycle will confirm final state."
        exit 0
    }
    else {
        Write-Log "Result: NOT YET COMPLIANT (Status=$($final.VolumeStatus), Method=$($final.EncryptionMethod)). Will retry on next remediation cycle."
        exit 1
    }
}
catch {
    Write-Log "ERROR: $($_.Exception.Message)"
    exit 1
}
