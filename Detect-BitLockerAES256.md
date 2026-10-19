# Detect-BitLockerAES256.ps1

Detection script that reports whether the OS drive is BitLocker-encrypted with a 256-bit method. It is the detection half of an Intune Remediation and changes nothing on the device. The remediation half is [Remediate-BitLockerAES256.md](Remediate-BitLockerAES256.md).

## Requirements

- The BitLocker PowerShell module (`Get-BitLockerVolume`), which needs a Windows edition that supports BitLocker.
- Rights to read BitLocker state, so run elevated or as SYSTEM.
- No parameters. It checks `$env:SystemDrive`.

## What it does

Reads the OS drive, prints the drive, volume status and encryption method, then exits with a result.

| Condition, checked in this order | Exit code |
|---|---|
| Volume status is `FullyDecrypted` | 1 (non-compliant) |
| Method name contains `256` | 0 (compliant) |
| Method name contains `128` | 1 (non-compliant) |
| Anything else, such as an unrecognized state | 1 (non-compliant) |
| Error reading the volume | 1 (non-compliant) |

## Review notes

- The method check is a text match. Any 256-bit method passes, not only `XtsAes256`. `Set-BitLockerAES256.ps1` is stricter and requires exactly `XtsAes256`.
- A volume that is still encrypting with a 256-bit method passes, because the method is checked after the `FullyDecrypted` test.
- It does not check protection status or key protectors, only the encryption method.
