# powershell

PowerShell scripts for managing and hardening Windows endpoints in a CMMC Level 2 / NIST SP 800-171 environment, written with Microsoft Intune and Azure-backed devices in mind. They cover compliance auditing and remediation, BitLocker enforcement, legacy protocol removal and a few housekeeping tasks.

Every script has a matching Markdown file with the details: requirements, what it changes, outputs, exit codes and review notes. Start there before deploying anything.

Test on a pilot device before wide deployment.

## Scripts

| Script | What it does | Guide |
|---|---|---|
| [CMMC-VerifyRemediateVerify.ps1](CMMC-VerifyRemediateVerify.ps1) | Audits an endpoint against a CMMC L2 baseline, remediates a defined subset, audits again and writes CSV, HTML and PDF reports | [CMMC-VerifyRemediateVerify.md](CMMC-VerifyRemediateVerify.md) |
| [Restrict-LegacyProtocols.ps1](Restrict-LegacyProtocols.ps1) | Audits, disables and verifies NetBIOS over TCP/IP, NTLMv1, LM, TLS 1.0 and TLS 1.1 | [Restrict-LegacyProtocols.md](Restrict-LegacyProtocols.md) |
| [Detect-BitLockerAES256.ps1](Detect-BitLockerAES256.ps1) | Reports whether the OS drive uses a 256-bit BitLocker method (Intune Remediation detection) | [Detect-BitLockerAES256.md](Detect-BitLockerAES256.md) |
| [Remediate-BitLockerAES256.ps1](Remediate-BitLockerAES256.ps1) | Brings the OS drive to XTS-AES 256 in one synchronous run (Intune Remediation) | [Remediate-BitLockerAES256.md](Remediate-BitLockerAES256.md) |
| [Set-BitLockerAES256.ps1](Set-BitLockerAES256.ps1) | Same goal, but hands the long decrypt and re-encrypt to a background scheduled task (Intune Platform script) | [Set-BitLockerAES256.md](Set-BitLockerAES256.md) |
| [Enforce-USBBitlocker.ps1](Enforce-USBBitlocker.ps1) | Watches for removable drives and prompts the user to encrypt them | [Enforce-USBBitlocker.md](Enforce-USBBitlocker.md) |
| [Remove-Default-Apps.ps1](Remove-Default-Apps.ps1) | Removes and de-provisions 12 default Windows and Microsoft apps | [Remove-Default-Apps.md](Remove-Default-Apps.md) |
| [Disable-Modern-Outlook.ps1](Disable-Modern-Outlook.ps1) | Byte-identical copy of `Remove-Default-Apps.ps1` | [Disable-Modern-Outlook.md](Disable-Modern-Outlook.md) |
| [Create-AdminFolder.ps1](Create-AdminFolder.ps1) | Creates `C:\AdminInfo` | [Create-AdminFolder.md](Create-AdminFolder.md) |

## How the scripts fit together

**Compliance pipeline.** `CMMC-VerifyRemediateVerify.ps1` is the largest script. It runs a baseline check, applies fixes for settings it can change safely, then runs the checks again so the before and after reports can be compared. It checks BitLocker state and removable drive policy but never configures BitLocker, so those rows are report-only.

**BitLocker.** The pipeline script reports BitLocker state. The scripts that actually configure it are separate:

- `Detect-BitLockerAES256.ps1` and `Remediate-BitLockerAES256.ps1` are a detection and remediation pair for an Intune Remediation.
- `Set-BitLockerAES256.ps1` is an alternative for an Intune Platform script. It avoids the Intune script timeout by running the long work in a scheduled task. Use it or the pair, not both.
- `Enforce-USBBitlocker.ps1` handles removable drives and needs a signed-in user.

**Hardening.** `Restrict-LegacyProtocols.ps1` covers a different set of settings from the pipeline script and can be used alongside it.

**Housekeeping.** `Remove-Default-Apps.ps1` and `Create-AdminFolder.ps1` stand alone.

## Deployment contexts

| Context | Scripts |
|---|---|
| Intune Platform script, runs as SYSTEM | `Restrict-LegacyProtocols.ps1`, `Set-BitLockerAES256.ps1`, `Remove-Default-Apps.ps1` |
| Intune Remediation, detection and remediation pair | `Detect-BitLockerAES256.ps1` with `Remediate-BitLockerAES256.ps1`; `Restrict-LegacyProtocols.ps1` can also be used as both halves |
| Elevated session or SYSTEM, run on demand | `CMMC-VerifyRemediateVerify.ps1`, `Create-AdminFolder.ps1` |
| Interactive admin session, needs a signed-in user | `Enforce-USBBitlocker.ps1` |

## Things to know before you use these

- `Disable-Modern-Outlook.ps1` and `Remove-Default-Apps.ps1` are identical, and both remove 12 apps, not only Outlook. Keep one.
- `Restrict-LegacyProtocols.ps1` and the pipeline script contain Connectium Technologies values (report folder, registry key, login banner text and policy ID). Change them before using the scripts in another organization.
- `Remediate-BitLockerAES256.ps1` logs an Entra ID key backup but uses `manage-bde -adbackup`, which targets Active Directory. Confirm where the recovery key lands.
- Several scripts reboot the device or change protocols and policies that can break legacy applications. Each guide lists the specifics.
