# Script guide

What each PowerShell script in this repository does, how it is meant to be deployed, and what to watch for. `CMMC-VerifyRemediateVerify.ps1` has its own write-up in [CMMC-VerifyRemediateVerify.md](CMMC-VerifyRemediateVerify.md) and is only listed here for completeness.

## At a glance

| Script | Purpose | Deployment context | Changes the device? |
|---|---|---|---|
| `CMMC-VerifyRemediateVerify.ps1` | Full CMMC L2 audit, remediation and re-audit | Elevated or SYSTEM | Yes |
| `Create-AdminFolder.ps1` | Creates `C:\AdminInfo` | Any | Yes (one folder) |
| `Detect-BitLockerAES256.ps1` | Reports whether the OS drive uses a 256-bit BitLocker method | Intune Remediation, detection | No |
| `Remediate-BitLockerAES256.ps1` | Brings the OS drive to XTS-AES 256 in one synchronous run | Intune Remediation, remediation | Yes |
| `Set-BitLockerAES256.ps1` | Same goal, but hands the long work to a scheduled task | Intune Platform script | Yes |
| `Enforce-USBBitlocker.ps1` | Watches for USB drives and prompts to encrypt them | Interactive admin session | Yes |
| `Remove-Default-Apps.ps1` | Removes and de-provisions 12 default apps | Intune, SYSTEM | Yes |
| `Disable-Modern-Outlook.ps1` | Identical copy of `Remove-Default-Apps.ps1` | Intune, SYSTEM | Yes |
| `Restrict-LegacyProtocols.ps1` | Audits and disables NetBIOS, NTLMv1, LM, TLS 1.0 and 1.1 | Intune, SYSTEM | Yes |

BitLocker handling lives in the four BitLocker scripts above. The pipeline script no longer evaluates or configures it.

## Create-AdminFolder.ps1

Creates `C:\AdminInfo` if it does not exist and prints whether it created the folder or found it already there. It puts nothing in the folder. Safe to run repeatedly.

## Detect-BitLockerAES256.ps1

Detection script for an Intune Remediation. It reads the OS drive with `Get-BitLockerVolume` and prints the drive, volume status and encryption method.

| Result | Exit code |
|---|---|
| Volume is `FullyDecrypted` | 1 (non-compliant) |
| Method name contains `256` | 0 (compliant) |
| Method name contains `128` | 1 (non-compliant) |
| Anything else, or an error reading the volume | 1 (non-compliant) |

The method check is a text match, so any 256-bit method passes, not only `XtsAes256`. A volume that is still encrypting with a 256-bit method also passes.

## Remediate-BitLockerAES256.ps1

Remediation partner for the detection script. It runs start to finish in one session and logs to `%ProgramData%\IntuneRemediation\BitLockerAES256.log`.

What it does, by starting state:

- **Already 256-bit:** nothing.
- **Unencrypted:** enables BitLocker with `XtsAes256`, used-space-only, and a TPM protector (or a recovery password protector if a TPM protector already exists).
- **Encrypted with a 128-bit method:** runs `Disable-BitLocker`, polls every 30 seconds for up to 180 minutes until the drive is `FullyDecrypted`, then enables BitLocker with `XtsAes256`.
- **Any other state:** takes no action and re-checks.

After enabling, it makes sure a recovery password protector exists, resumes protection, and attempts `manage-bde -protectors -adbackup`. It then waits 10 seconds, re-reads the drive state and exits 0 if the method is 256-bit or encryption is in progress, otherwise 1.

Things to know:

- The decrypt-and-re-encrypt path leaves the drive unprotected for the length of the decrypt and is slow. The script's own notes say to pilot it first.
- The log says the key is backed up to Entra ID, but `manage-bde -adbackup` targets Active Directory. Entra ID escrow normally uses `BackupToAAD-BitLockerKeyProtector`, so confirm the key actually lands where you expect.
- It does not save the recovery key to a file, unlike `Set-BitLockerAES256.ps1`.

## Set-BitLockerAES256.ps1

A different answer to the same problem, built for an Intune Platform script. The header explains the reasoning: a decrypt and re-encrypt can outlast Intune's script timeout, and a script killed mid-way could leave the drive decrypted. So this script only detects, then dispatches the work.

Steps:

1. Requires admin. Reads the OS drive. If the method is exactly `XtsAes256`, it logs that and stops.
2. Checks for a present and ready TPM. If there is none, it logs and stops without changing anything.
3. Writes a worker script to `%ProgramData%\BitLockerAES256\Worker-BitLockerAES256.ps1`.
4. Registers a one-time scheduled task, running as SYSTEM with no time limit, that starts about 5 seconds later.
5. Exits. The task does the rest.

The worker turns BitLocker off with `manage-bde -off` if protection is on, waits up to 24 hours for `FullyDecrypted`, then runs `Enable-BitLocker` with `XtsAes256` and a TPM protector (used-space-only by default, controlled by `-UsedSpaceOnly`). It then ensures a recovery password protector, writes the recovery password to `C:\BitLocker-Recovery-<timestamp>.txt`, and attempts an AD backup if the device is domain joined.

Parameters: `-UsedSpaceOnly` (default on) and `-LogDir` (default `%ProgramData%\BitLockerAES256`).

Things to know:

- The recovery password is saved in plain text at the root of `C:\`. The script says to move it off the device immediately.
- The scheduled task name includes the time, and the script does not check for an existing worker. Running it again while a decrypt is underway could start a second worker.
- If the decrypt times out after 24 hours, the worker logs that the drive may be unprotected and stops.

## Enforce-USBBitlocker.ps1

An interactive monitor, not a deployment script. It requires an elevated session (`#Requires -RunAsAdministrator`) and loops forever, checking every 3 seconds for removable drives through WMI.

When a new drive appears it checks BitLocker status. If the drive is not protected (or the status cannot be read), a message box says CMMC policy requires encryption and asks whether to encrypt now.

- **Yes:** prompts for a password with `Read-Host`, then runs `Enable-BitLocker` with `Aes256`, a password protector and used-space-only encryption.
- **No:** ejects the drive.

Things to know:

- It needs a signed-in user to see the dialog and answer the prompt, so it will not work as an Intune script running as SYSTEM.
- It uses `Get-WmiObject`, which is not available in PowerShell 7.
- It matches `MediaType='Removable Media'`. Many USB hard drives and some flash drives report as external fixed media and may not be detected.
- It uses a password protector only. No recovery password or key escrow is created.
- Nothing starts it automatically. It runs until someone presses Ctrl+C.

## Remove-Default-Apps.ps1 and Disable-Modern-Outlook.ps1

These two files are byte-identical (same SHA-1). Despite its name, `Disable-Modern-Outlook.ps1` does not only touch Outlook, and its own header refers to `Remove-DefaultApps.ps1`. One of the two is redundant.

What the script does: requires admin, then for each of 12 apps matched by wildcard against AppX package names, it runs `Remove-AppxPackage -AllUsers` for existing users and `Remove-AppxProvisionedPackage` so the app does not return in new profiles.

Apps targeted: new Outlook, Feedback Hub, Get Help, Get Started/Tips, Microsoft 365 Copilot (the `*Copilot*` pattern), Microsoft News, Microsoft To Do, Phone Link, Solitaire and Casual Games, WhatsApp, LinkedIn, and the Xbox family (`*Xbox*`).

It also makes a best-effort `winget uninstall` of `Microsoft.Outlook`, which is skipped when `winget.exe` cannot be found, as is common under SYSTEM. It logs to `%ProgramData%\IntuneAppCleanup\` and prints a per-app summary.

Things to know:

- `*Copilot*` and `*Xbox*` are broad patterns and will match every package whose name contains them.
- Some Xbox sub-packages are protected by Windows. Failures there are expected and the script says so.
- The script does not change the execution policy.
- A failed removal does not stop the run. The exit code is not set from the summary, so rely on the log.

## Restrict-LegacyProtocols.ps1

Audits, enforces and verifies the disabling of legacy protocols, supporting CMMC CM.L2-3.4.7[l]. It is built for an Intune Platform script (SYSTEM, 64-bit host) and relaunches itself in 64-bit PowerShell if it starts in 32-bit.

It runs three steps in one pass, controlled by `$Mode` (default `Auto`):

1. **Audit:** read every setting and record compliant or non-compliant.
2. **Enforce:** only if the audit found something wrong, write the expected values.
3. **Verify:** read everything again. The exit code and summary come from this step.

If the audit finds everything compliant, enforce and verify are skipped. `AuditOnly` mode never changes anything.

Settings it manages, all under `HKLM`:

| Protocol | Setting |
|---|---|
| NetBIOS over TCP/IP | `NetbiosOptions = 2` on every `Tcpip_*` adapter key |
| NTLMv1 and LM | `LmCompatibilityLevel = 5` and `NoLMHash = 1` under `Control\Lsa` |
| TLS 1.0 and TLS 1.1 | `Enabled = 0` and `DisabledByDefault = 1`, client and server, under SCHANNEL |

Each protocol has a scope switch near the top (`$DisableNetBIOS`, `$DisableNtlmV1LM`, `$DisableTls10`, `$DisableTls11`). Setting one to `$false` leaves it unchanged and reports it as `NotInScope`.

Outputs:

- A CSV at `C:\ProgramData\Connectium\Reports\LegacyProtocols_<computer>_<timestamp>.csv`, keeping the 12 most recent.
- A registry marker at `HKLM:\SOFTWARE\Connectium\Compliance\LegacyProtocols` with last run, mode, result, counts, reboot flag, summary and report path.
- One summary line on standard output, which shows up in Intune when run as a Remediation.

Exit code is 0 when the final state is compliant and 1 otherwise.

Things to know:

- It does not restart the device. TLS changes need a restart and NetBIOS changes need an adapter reset. The registry marker records `RebootRecommended`.
- A Platform script runs once per device. To re-apply on a schedule, which also covers adapters added later, deploy the same file as both detection and remediation script of an Intune Remediation.
- If the same values are also set by a Settings catalog policy, remove the duplicate to avoid a conflict.
- Disabling these protocols can break legacy applications, file servers, NAS devices and printers. Pilot first.
- The report path and registry key use the Connectium name.

## How the scripts relate

- **BitLocker OS drive:** `Detect-BitLockerAES256.ps1` and `Remediate-BitLockerAES256.ps1` are a detection and remediation pair. `Set-BitLockerAES256.ps1` is an alternative that avoids the script timeout by using a scheduled task. Use one approach, not both.
- **Removable media:** `Enforce-USBBitlocker.ps1` is separate and interactive.
- **Hardening:** `Restrict-LegacyProtocols.ps1` and the pipeline script cover different settings and can be used together.
- **Housekeeping:** `Remove-Default-Apps.ps1` (and its duplicate) and `Create-AdminFolder.ps1` stand alone.
