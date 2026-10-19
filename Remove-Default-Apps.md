# Remove-Default-Apps.ps1

Removes a set of default Windows and Microsoft apps for every existing user and de-provisions them, so newly provisioned devices and new user profiles come up without them. It is built for Intune deployment and runs fine as SYSTEM.

`Disable-Modern-Outlook.ps1` is a byte-identical copy of this file. See [Disable-Modern-Outlook.md](Disable-Modern-Outlook.md).

## Requirements

- Administrator or SYSTEM. It exits with an error if not elevated.
- No winget dependency. The script header explains that winget is unreliable under SYSTEM because App Installer registers per user and `winget.exe` is often not on the SYSTEM path.
- The script does not change the execution policy. Intune already runs scripts with it bypassed.

## Parameters

| Parameter | Default | Purpose |
|---|---|---|
| `-LogPath` | `%ProgramData%\IntuneAppCleanup\Remove-DefaultApps-<timestamp>.log` | Log file |

## What it does

For each app in a friendly-name to wildcard table, the script does two things, in this order:

1. `Remove-AppxPackage -AllUsers` removes the app for every account that currently exists.
2. `Remove-AppxProvisionedPackage -Online` removes it from the device's provisioning image. Without this step the app would reappear for the next new user.

Patterns match both the AppX package `Name` and the provisioned package `DisplayName`. Wildcards are used because Microsoft renames and re-versions these packages across builds.

| App | Pattern |
|---|---|
| Microsoft Outlook (new) | `*OutlookForWindows*` |
| Feedback Hub | `*WindowsFeedbackHub*` |
| Get Help | `*GetHelp*` |
| Get Started / Tips | `*Getstarted*` |
| Microsoft 365 Copilot | `*Copilot*` |
| Microsoft News | `*BingNews*` |
| Microsoft To Do | `*Todos*` |
| Phone Link | `*YourPhone*` |
| Solitaire and Casual Games | `*MicrosoftSolitaireCollection*` |
| WhatsApp | `*WhatsApp*` |
| LinkedIn | `*LinkedIn*` |
| Xbox (full family) | `*Xbox*` |

After the loop it makes a best-effort `winget uninstall --id Microsoft.Outlook`, skipped when `winget.exe` cannot be found. It then prints a per-app summary of packages removed, packages de-provisioned and failures.

## Outputs

A timestamped log and a console summary. Each app shows `OK` or `PARTIAL/FAILED`. If any failures were recorded the script prints the total and notes that common causes are an app that was never on the image or a package flagged `NonRemovable`.

## Review notes

- `*Copilot*` and `*Xbox*` are broad patterns and match every package whose name contains them. Check that this is what you intend, including the separate "Microsoft Copilot" app.
- Windows protects some Xbox sub-packages (for example Xbox Identity Provider and Game Bar), so failures there are expected.
- A failed removal does not stop the run, and the script sets no exit code from the summary. Use the log to see what failed.
- The name `Remove-DefaultApps.ps1` appears in the script's own `.EXAMPLE`, which differs from the file name `Remove-Default-Apps.ps1`.
