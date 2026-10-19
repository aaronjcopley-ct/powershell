# Set-BitLockerAES256.ps1

Detects whether the OS drive uses XTS-AES 256 and, if not, hands the long decrypt and re-encrypt work to a background scheduled task. It is built for an Intune Platform script, and it is an alternative to the detect and remediate pair ([Detect-BitLockerAES256.md](Detect-BitLockerAES256.md), [Remediate-BitLockerAES256.md](Remediate-BitLockerAES256.md)). Use one approach, not both.

## Why it works this way

The script header gives the reasoning:

- `manage-bde -off` starts a background decrypt, and `Enable-BitLocker` fails or leaves the volume inconsistent if it runs before the decrypt finishes.
- Intune enforces a script timeout. A script killed mid-way could leave the drive decrypted, which is worse than the original 128-bit finding.
- `-TpmProtector` fails with a cryptic error when no TPM is ready, so the script checks first.
- Re-encrypting without capturing a recovery key risks a lockout.

## Requirements

- Administrator or SYSTEM. Intune setting: run using the logged-on credentials = No.
- The BitLocker module and a present, ready TPM.

## Parameters

| Parameter | Default | Purpose |
|---|---|---|
| `-UsedSpaceOnly` | on | Encrypt only used space, which is much faster. Pass `-UsedSpaceOnly:$false` for full-volume encryption |
| `-LogDir` | `%ProgramData%\BitLockerAES256` | Where dispatch and worker logs are written |

## What it does

The dispatcher, which is the script Intune runs:

1. Checks for admin rights and reads the OS drive. If it cannot read BitLocker status it logs and stops.
2. If the method is exactly `XtsAes256` it logs that and stops.
3. Checks that a TPM is present and ready. If not, it logs and stops without changing anything.
4. Writes a worker script to `<LogDir>\Worker-BitLockerAES256.ps1`.
5. Registers a one-time scheduled task named `BitLockerAES256-Worker-<HHmmss>`, running as SYSTEM with highest privileges and no execution time limit, starting about 5 seconds later.
6. Exits. If task registration fails, it says no BitLocker changes were made and it is safe to retry.

The worker, which runs in the scheduled task:

1. If protection is on, runs `manage-bde -off` and waits up to 24 hours for `FullyDecrypted`. On timeout it logs that the drive may be unprotected and stops.
2. Runs `Enable-BitLocker` with `XtsAes256` and a TPM protector, used-space-only unless disabled.
3. Waits 10 seconds, then ensures a recovery password protector exists.
4. Writes the recovery password to `C:\BitLocker-Recovery-<timestamp>.txt`.
5. Attempts an AD backup with `Backup-BitLockerKeyProtector` if the device is domain joined, and logs guidance for Entra ID joined devices.
6. Logs the final method, protection status, volume status and percentage.

## Outputs

- `Dispatch-<timestamp>.log` and `Worker-<timestamp>.log` in `-LogDir`
- The recovery key text file at the root of `C:\`

## Review notes

- The recovery password is saved in plain text. The script says to move it off the device immediately.
- The task name includes the time and nothing checks for an existing worker. Running the script again during a decrypt could start a second worker.
- The device is unprotected between the decrypt and the end of re-encryption.
- Re-run detection later to confirm completion. The script does not wait for it.
