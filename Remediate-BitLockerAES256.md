# Remediate-BitLockerAES256.ps1

Remediation script that brings the OS drive to XTS-AES 256, whatever state it starts in. It is the remediation half of an Intune Remediation, paired with [Detect-BitLockerAES256.md](Detect-BitLockerAES256.md). It runs start to finish in one session and logs to `%ProgramData%\IntuneRemediation\BitLockerAES256.log`.

## Requirements

- Elevated or SYSTEM context.
- The BitLocker module and, for the unencrypted path, a TPM.
- For Entra ID escrow, an Entra-joined device (see review notes).
- No parameters. It works on `$env:SystemDrive`.

## What it does

The action depends on the starting state.

| Starting state | Action |
|---|---|
| Method already contains `256` | Nothing |
| `FullyDecrypted` | Enable BitLocker with `XtsAes256` |
| Method contains `128` | Run `Disable-BitLocker`, poll every 30 seconds for up to 180 minutes until `FullyDecrypted`, then enable BitLocker with `XtsAes256` |
| Anything else, including in-progress states | No destructive action, then re-check |

When enabling, it uses used-space-only encryption and `-SkipHardwareTest`. If a TPM protector already exists it passes `-RecoveryPasswordProtector` to satisfy the parameter set, otherwise it adds a new TPM protector. It then confirms the drive actually left `FullyDecrypted`, adds a recovery password protector if one is missing, resumes protection, and attempts `manage-bde -protectors -adbackup` for the recovery password.

Finally it waits 10 seconds, reads the drive state again and exits:

- 0 if the method is 256-bit, or if encryption or decryption is in progress
- 1 if it is still not compliant, or if anything throws

## Safety behavior

- The 128-bit path decrypts the whole drive first, so the device is unprotected for the length of the decrypt and the run can be slow and disruptive. The script's notes say to pilot it before wide deployment.
- If decryption does not finish within 180 minutes it logs an error and exits 1 without re-encrypting.
- It reports the final observed state instead of assuming the change worked.

## Review notes

- The log says the recovery password is backed up to Entra ID, but `manage-bde -adbackup` targets Active Directory. Entra ID escrow normally uses `BackupToAAD-BitLockerKeyProtector`, so confirm where the key actually ends up.
- It does not save the recovery key to a file, unlike [Set-BitLockerAES256.md](Set-BitLockerAES256.md).
- It assumes a TPM protector is wanted. Adjust it if you require a PIN or startup key.
- Because it runs synchronously, a long decrypt can run into an Intune script timeout. `Set-BitLockerAES256.ps1` exists to avoid that.
