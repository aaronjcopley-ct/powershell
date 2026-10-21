# powershell

PowerShell scripts for managing and hardening Windows endpoints in a CMMC Level 2 / NIST SP 800-171 environment, written with Microsoft Intune and Azure-backed devices in mind. They cover compliance auditing and remediation, legacy protocol removal and a few housekeeping tasks.

Every script has a matching Markdown file with the details: requirements, what it changes, outputs, exit codes and review notes. Start there before deploying anything.

Test on a pilot device before wide deployment.

## Scripts

| Script | What it does | Guide |
|---|---|---|
| [CMMC-VerifyRemediateVerify.ps1](CMMC-VerifyRemediateVerify.ps1) | Audits an endpoint against a CMMC L2 baseline, remediates a defined subset, audits again and writes CSV, HTML and PDF reports | [CMMC-VerifyRemediateVerify.md](CMMC-VerifyRemediateVerify.md) |
| [Restrict-LegacyProtocols.ps1](Restrict-LegacyProtocols.ps1) | Audits, disables and verifies NetBIOS over TCP/IP, NTLMv1, LM, TLS 1.0 and TLS 1.1 | [Restrict-LegacyProtocols.md](Restrict-LegacyProtocols.md) |
| [Remove-Default-Apps.ps1](Remove-Default-Apps.ps1) | Removes and de-provisions 12 default Windows and Microsoft apps | [Remove-Default-Apps.md](Remove-Default-Apps.md) |
| [Disable-Modern-Outlook.ps1](Disable-Modern-Outlook.ps1) | Byte-identical copy of `Remove-Default-Apps.ps1` | [Disable-Modern-Outlook.md](Disable-Modern-Outlook.md) |
| [Create-AdminFolder.ps1](Create-AdminFolder.ps1) | Creates `C:\AdminInfo` | [Create-AdminFolder.md](Create-AdminFolder.md) |

## How the scripts fit together

**Compliance pipeline.** `CMMC-VerifyRemediateVerify.ps1` is the largest script. It runs a baseline check, applies fixes for settings it can change safely, then runs the checks again so the before and after reports can be compared. It checks BitLocker state and removable drive policy but never configures BitLocker, so those rows are report-only.

**Hardening.** `Restrict-LegacyProtocols.ps1` covers a different set of settings from the pipeline script and can be used alongside it.

**Housekeeping.** `Remove-Default-Apps.ps1` and `Create-AdminFolder.ps1` stand alone.

## Deployment contexts

| Context | Scripts |
|---|---|
| Intune Platform script, runs as SYSTEM | `Restrict-LegacyProtocols.ps1`, `Remove-Default-Apps.ps1` |
| Intune Remediation, same file as detection and remediation | `Restrict-LegacyProtocols.ps1` |
| Elevated session or SYSTEM, run on demand | `CMMC-VerifyRemediateVerify.ps1`, `Create-AdminFolder.ps1` |

## Things to know before you use these

- `Disable-Modern-Outlook.ps1` and `Remove-Default-Apps.ps1` are identical, and both remove 12 apps, not only Outlook. Keep one.
- `Restrict-LegacyProtocols.ps1` and the pipeline script contain Connectium Technologies values (report folder, registry key, login banner text and policy ID). Change them before using the scripts in another organization.
- Several scripts reboot the device or change protocols and policies that can break legacy applications. Each guide lists the specifics.
