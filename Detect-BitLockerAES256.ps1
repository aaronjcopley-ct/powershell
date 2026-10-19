<#
.SYNOPSIS
    Detection script - checks OS drive BitLocker state.
    Exit 0 = Compliant  (already encrypted with a 256-bit method)
    Exit 1 = Non-Compliant (unencrypted OR encrypted with a 128-bit method OR
             in an unrecognized/in-progress state)
#>

try {
    $osDrive = $env:SystemDrive
    $volume = Get-BitLockerVolume -MountPoint $osDrive -ErrorAction Stop

    $status = $volume.VolumeStatus
    $method = $volume.EncryptionMethod

    Write-Output "Drive: $osDrive"
    Write-Output "VolumeStatus: $status"
    Write-Output "EncryptionMethod: $method"

    if ($status -eq 'FullyDecrypted') {
        Write-Output "Non-compliant: drive is unencrypted."
        exit 1
    }

    if ($method -like "*256*") {
        Write-Output "Compliant: drive is encrypted with a 256-bit method."
        exit 0
    }

    if ($method -like "*128*") {
        Write-Output "Non-compliant: drive is encrypted with a 128-bit method."
        exit 1
    }

    Write-Output "Non-compliant: unrecognized or in-progress state ($status / $method)."
    exit 1
}
catch {
    Write-Output "Error checking BitLocker status: $($_.Exception.Message)"
    exit 1
}
