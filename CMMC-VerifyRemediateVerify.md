# CMMC-VerifyRemediateVerify.ps1

A single PowerShell script that audits a Windows endpoint against a CMMC Level 2 / NIST SP 800-171 Rev 2 baseline, fixes the settings it can fix safely, then audits again and reports the difference. It is written for Intune-managed and GCC High environments and runs unattended.

## Requirements

- Run from an elevated PowerShell session (or as SYSTEM). The script exits with an error if it is not admin.
- Windows with Defender, the NetSecurity and ScheduledTasks cmdlets, and the CIM classes it queries. Some checks report INFO or "build too old" on older Windows builds.
- Microsoft Edge or Google Chrome, only if you want the PDF report. Without one, the CSV and HTML reports are still written.

## Parameters

| Parameter | Default | Purpose |
|---|---|---|
| `-NtpServer` | `time.nist.gov` | Time source applied during NTP remediation |
| `-PollIntervalSeconds` | `14400` | NTP poll interval applied during remediation |
| `-LogPath` | `%TEMP%\CMMC-Pipeline-<timestamp>.log` | Run log |
| `-ReportDir` | `%ProgramData%\temp` | Where the CSV, HTML and PDF reports are written |
| `-SkipPdfReport` | off | Skip PDF generation |
| `-SkipEnrollmentPrompts` | off | Skip the Windows Hello enrollment check |
| `-Force` | off | Declared in the `param()` block but not referenced anywhere in the script |

## How a run works

The pipeline has three phases.

1. **Phase 1, baseline verification.** Runs every check, prints a results table, prints reference and fix text for each failure, and writes the reports.
2. **Phase 2, remediation.** Applies fixes for a defined subset of settings. Each setting is read first and only changed if it is out of compliance. Nothing prompts for confirmation.
3. **Phase 3, final verification.** Runs the same checks again and writes a second set of reports, so the baseline and final results can be compared.

A progress window is shown in the signed-in user's session when full PowerShell language mode is available. When the script runs as SYSTEM it schedules the window as a short-lived task in the interactive user's session. In constrained language mode the window is skipped and progress goes to the console and log only.

## What gets checked

Each check is tagged with a source area and mapped to a CMMC / NIST 800-171 control taken from the check's note text. Checks with the same name in more than one area are consolidated into one row.

| Source area | Examples |
|---|---|
| Audit and crypto | Audit policy subcategories (credential validation, file system, process creation, removable storage, account management, privilege use), FIPS algorithm policy, NTP client and server, command line in process creation events |
| Defender and ASR configuration | Real-time, behavior and cloud protection, PUA blocking, signature interval, scheduled scan type, day and time, Network Protection, SmartScreen, sideloading and MSI controls, Game DVR, Edge SmartScreen, firewall dropped-packet logging |
| Endpoint protection | Credential Guard and VBS, BitLocker state of the OS and fixed drives (read-only), firewall profile settings, NTLM session security, machine inactivity limit |
| Login banner and SAS | Legal notice title and text, secure attention sequence settings |
| Security hardening | Account lockout (on builds that support it), UAC, guest account, privacy settings |
| General hardening | AutoPlay and AutoRun, RDS session limits and encryption, event log sizes, BitLocker policy for removable drives (read-only), Edge sync, FIPS |
| Windows LAPS | CSP and GPO LAPS policy values |
| ASR rules | 19 Attack Surface Reduction rules plus Controlled Folder Access |
| Device control | Removable storage, Bluetooth and device control policy |
| Windows Hello for Business | PIN length, expiration, history, recovery, anti-spoofing |

Each result carries a status of PASS, FAIL, INFO, REVIEW or UNKNOWN, plus the expected value, actual value, a short explanation and a fix command.

## What gets remediated

Remediation is deliberately narrower than verification. It covers seven areas.

1. **NTP.** Sets the NTP server, `Type=NTP` and the poll interval, and replaces `time.windows.com`.
2. **FIPS.** Enables the FIPS algorithm policy. A reboot is required.
3. **Defender, ASR, SmartScreen and firewall.** About ten items, including scan day and time, SmartScreen and firewall profile settings.
4. **General hardening.** AutoRun, AutoPlay for all drives, and Edge sync.
5. **Firewall, VBS and Credential Guard.** Firewall profile values, Virtualization Based Security, and Credential Guard with a UEFI lock. Credential Guard needs two reboots.
6. **Device control.** Guidance only. The script prints instructions and writes nothing, because the policy lives in a structured `PolicyRules` value that is easy to corrupt by hand.
7. **Windows Hello for Business.** Writes PIN policy values. It checks whether a PIN is already enrolled but never launches a setup prompt. Intune handles enrollment.

Login banner, security hardening, LAPS, ASR rules and device control checks are verify-only. They show up as pass or fail but the script does not change them.

## Safety behavior

- Before each registry change, the previous value is saved under a `_PreRemediationBackup` subkey next to the original (a missing value is stored as `-9999`).
- Settings that already match are logged and skipped.
- If any change needs a reboot, the script warns the signed-in user with `msg.exe`, waits two minutes and restarts the machine. If nothing needs a reboot it does not restart.
- If the machine is managed by Intune or GPO, many values will revert at the next policy sync unless the source policy is corrected too. The per-check notes say which ones.

## Outputs

For each verification phase, in `-ReportDir`, named `<COMPUTERNAME>-<timestamp>`:

- `.csv` with source, name, reference, setting, expected, actual, status, note and fix
- `.html` with a filterable, searchable table and summary cards
- `.pdf` grouped by control, so a check that maps to several controls appears under each one

The run log goes to `-LogPath`. The end of the run prints pass, fail and other counts for all three phases and the paths to the baseline and final reports.

## Environment-specific values to review

- The login banner check compares against hard-coded Connectium Technologies title and text, including the Acceptable Use Policy reference `CT-POL-AUP-001`. Change these before using the script elsewhere.
- The defender scan day check expects Saturday (`7`). The script notes that a source policy value of `6` is Friday, so fix the source policy as well as the device.
- Several notes cite specific CMMC and NIST control numbers. Confirm them against your own SSP before using the output as assessment evidence.

## Scope note

BitLocker is report-only in this script. The checks for the OS drive, fixed drives and removable drive policy still run and appear in the CSV, HTML and PDF reports, but the script never enables, changes or backs up BitLocker and has no BitLocker parameters. Remediation does not touch BitLocker or the removable drive write-block, so a failing BitLocker row stays failing after Phase 2 until it is fixed outside this script, for example by an Intune policy. The fix text shown in a failing row is guidance for an admin and is not run by the script.
