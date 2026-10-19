#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Monitors for USB drive insertion and prompts to encrypt with BitLocker (CMMC compliance).
.DESCRIPTION
    Runs as a background monitor. When a new removable drive is detected, it checks if
    BitLocker is enabled. If not, it prompts the user to encrypt before use.
#>

$ErrorActionPreference = 'Stop'

function Get-RemovableDrives {
    Get-WmiObject -Class Win32_DiskDrive -Filter "MediaType='Removable Media'" |
        ForEach-Object {
            $disk = $_
            Get-WmiObject -Query "ASSOCIATORS OF {Win32_DiskDrive.DeviceID='$($disk.DeviceID)'} WHERE AssocClass=Win32_DiskDriveToDiskPartition" |
                ForEach-Object {
                    Get-WmiObject -Query "ASSOCIATORS OF {Win32_DiskPartition.DeviceID='$($_.DeviceID)'} WHERE AssocClass=Win32_LogicalDiskToPartition"
                }
        } | Select-Object -ExpandProperty DeviceID
}

function Get-BitLockerStatus {
    param([string]$DriveLetter)
    try {
        $vol = Get-BitLockerVolume -MountPoint $DriveLetter -ErrorAction SilentlyContinue
        return $vol
    } catch {
        return $null
    }
}

function Invoke-EncryptDrive {
    param([string]$DriveLetter)

    $result = [System.Windows.Forms.MessageBox]::Show(
        "Drive $DriveLetter is NOT encrypted.`n`nCMMC policy requires all removable media to be encrypted with BitLocker.`n`nDo you want to encrypt this drive now?`n`n(Clicking 'No' will eject the drive.)",
        "CMMC - BitLocker Required",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    )

    if ($result -eq [System.Windows.Forms.DialogResult]::Yes) {
        Write-Host "[$(Get-Date -f 'HH:mm:ss')] Enabling BitLocker on $DriveLetter ..."

        # Use a password protector; swap for -RecoveryPasswordProtector if preferred
        $password = Read-Host -AsSecureString "Enter a strong password for $DriveLetter"

        try {
            Enable-BitLocker -MountPoint $DriveLetter `
                -EncryptionMethod Aes256 `
                -PasswordProtector `
                -Password $password `
                -UsedSpaceOnly

            Write-Host "[$(Get-Date -f 'HH:mm:ss')] BitLocker encryption started on $DriveLetter."

            [System.Windows.Forms.MessageBox]::Show(
                "BitLocker encryption has been initiated on $DriveLetter.`nEncryption will complete in the background. Do NOT remove the drive until finished.",
                "BitLocker Initiated",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information
            ) | Out-Null
        } catch {
            [System.Windows.Forms.MessageBox]::Show(
                "Failed to enable BitLocker on ${DriveLetter}:`n$($_.Exception.Message)",
                "BitLocker Error",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error
            ) | Out-Null
        }
    } else {
        Write-Host "[$(Get-Date -f 'HH:mm:ss')] User declined encryption. Ejecting $DriveLetter ..."
        $shell = New-Object -ComObject Shell.Application
        $shell.Namespace(17).ParseName($DriveLetter).InvokeVerb("Eject")
    }
}

# ── Load WinForms for message boxes ──────────────────────────────────────────
Add-Type -AssemblyName System.Windows.Forms

Write-Host "=== CMMC USB BitLocker Enforcement Monitor ==="
Write-Host "Watching for removable drives. Press Ctrl+C to stop.`n"

$knownDrives = @(Get-RemovableDrives)

while ($true) {
    Start-Sleep -Seconds 3

    $currentDrives = @(Get-RemovableDrives)
    $newDrives = $currentDrives | Where-Object { $_ -notin $knownDrives }

    foreach ($drive in $newDrives) {
        Write-Host "[$(Get-Date -f 'HH:mm:ss')] New removable drive detected: $drive"

        $blStatus = Get-BitLockerStatus -DriveLetter $drive

        if ($null -eq $blStatus) {
            Write-Host "[$(Get-Date -f 'HH:mm:ss')] WARNING: Could not query BitLocker status for $drive (may require admin or unsupported FS)."
            Invoke-EncryptDrive -DriveLetter $drive
        } elseif ($blStatus.ProtectionStatus -eq 'On' -or $blStatus.VolumeStatus -eq 'FullyEncrypted') {
            Write-Host "[$(Get-Date -f 'HH:mm:ss')] $drive is already BitLocker protected. OK."
        } else {
            Write-Host "[$(Get-Date -f 'HH:mm:ss')] $drive is NOT encrypted (Status: $($blStatus.VolumeStatus))."
            Invoke-EncryptDrive -DriveLetter $drive
        }
    }

    $knownDrives = $currentDrives
}
