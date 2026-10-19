# Restrict-LegacyProtocols.ps1

Audits, enforces and verifies the disabling of NetBIOS over TCP/IP, NTLMv1, LM authentication, TLS 1.0 and TLS 1.1, then writes a report confirming the result. It supports CMMC CM.L2-3.4.7[l], which requires nonessential protocols to be restricted, disabled or prevented. It is built for Intune and runs as SYSTEM.

## Deployment

Intune: Devices > Scripts and remediations > Platform scripts > Add > Windows 10 and later.

- Run this script using the logged on credentials: No
- Enforce script signature check: No
- Run script in 64-bit PowerShell host: Yes

The script also relaunches itself in 64-bit PowerShell if it starts in a 32-bit host.

A Platform script runs once per device and again only if the script changes in Intune. To re-apply on a schedule, which also covers network adapters added later, deploy the same file as both the detection and remediation script of an Intune Remediation.

## Configuration

There are no parameters. Edit the variables at the top of the script.

| Variable | Default | Purpose |
|---|---|---|
| `$Mode` | `Auto` | `Auto` runs audit, enforce and verify. `AuditOnly` audits and reports without changing anything |
| `$PolicyVersion` | `2.0` | Written to the registry marker |
| `$ReportRoot` | `%ProgramData%\Connectium\Reports` | Report folder |
| `$ReportsToKeep` | `12` | Number of CSV reports kept |
| `$DisableNetBIOS` | `$true` | Scope switch for NetBIOS |
| `$DisableNtlmV1LM` | `$true` | Scope switch for NTLMv1 and LM |
| `$DisableTls10` | `$true` | Scope switch for TLS 1.0 |
| `$DisableTls11` | `$true` | Scope switch for TLS 1.1 |

A protocol switched to `$false` is left unchanged and reported as `NotInScope`.

## How a run works

1. **Audit.** Reads every setting and records Compliant or NonCompliant. Nothing is changed.
2. **Enforce.** Only if the audit found a non-compliant setting and `$Mode` is `Auto`, writes the expected value to each setting that needs it, then rereads it to confirm.
3. **Verify.** Reads every setting again. The exit code and summary come from this step.

If the audit finds everything compliant, enforce and verify are skipped and the device is left untouched.

## Settings managed

All under `HKLM`.

| Protocol | Setting |
|---|---|
| NetBIOS over TCP/IP | `NetBT\Parameters\Interfaces\Tcpip_<adapter GUID>`, `NetbiosOptions = 2`, on every adapter key |
| NTLMv1 and LM | `Control\Lsa`, `LmCompatibilityLevel = 5` (NTLMv2 only, refuse LM and NTLM) |
| LM hash storage | `Control\Lsa`, `NoLMHash = 1` |
| TLS 1.0 and TLS 1.1 | `Control\SecurityProviders\SCHANNEL\Protocols\<protocol>\Client` and `\Server`, `Enabled = 0` and `DisabledByDefault = 1` |

Adapter rows in the report include the adapter description when it can be read from CIM.

## Outputs

- A CSV at `C:\ProgramData\Connectium\Reports\LegacyProtocols_<computer>_<timestamp>.csv`, with one row per setting per step. Older reports beyond `$ReportsToKeep` are deleted.
- A registry marker at `HKLM:\SOFTWARE\Connectium\Compliance\LegacyProtocols` holding last run, mode, policy version, compliant flag, non-compliant and changed counts, reboot recommended flag, summary, flow and report path.
- One summary line on standard output, which shows up in Intune when run as a Remediation. It lists non-compliant and failed settings when there are any.

Exit code is 0 when the final state is compliant and 1 otherwise. The per-protocol summary uses `Disabled`, `NotDisabled` or `NotInScope`.

## Review notes

- The script does not restart the device. TLS changes need a restart and NetBIOS changes need an adapter reset. The registry marker records `RebootRecommended`.
- If the same values are also set by a Settings catalog policy, such as the LAN Manager authentication level, remove the duplicate so the two do not conflict.
- Disabling these protocols can break legacy applications, file servers, NAS devices and printers. Pilot on one device first.
- The report folder and registry key use the Connectium name, so change them before using this elsewhere.
