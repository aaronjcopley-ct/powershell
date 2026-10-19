# Disable-Modern-Outlook.ps1

This file is a byte-identical copy of `Remove-Default-Apps.ps1` (same SHA-1 hash). Despite its name it does not only remove the new Outlook app. It removes and de-provisions twelve default apps, including new Outlook, Copilot, Xbox, WhatsApp and LinkedIn.

The full description is in [Remove-Default-Apps.md](Remove-Default-Apps.md). In short:

- Runs as Administrator or SYSTEM, built for Intune.
- For each app, removes the AppX package for all existing users, then de-provisions it so new profiles do not get it.
- Does not rely on winget, apart from one best-effort `winget uninstall` of `Microsoft.Outlook` that is skipped when winget is not available.
- Logs to `%ProgramData%\IntuneAppCleanup\` and prints a per-app summary.

## Review notes

- Because the contents are identical, deploying both scripts does the same work twice. Keep one.
- If the intent of this file was to remove only the new Outlook, it needs to be trimmed to the `*OutlookForWindows*` entry. As it stands, deploying it under an Outlook-specific name will also remove the other eleven apps.
- Its `.EXAMPLE` refers to `Remove-DefaultApps.ps1`, which does not match either file name.
