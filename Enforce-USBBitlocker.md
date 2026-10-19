# Enforce-USBBitlocker.ps1

An interactive monitor that watches for removable drives and prompts the user to encrypt any that are not BitLocker protected. It is aimed at CMMC removable media requirements. It is a tool to run in a user session, not an Intune deployment script.

## Requirements

- An elevated PowerShell session (`#Requires -RunAsAdministrator`).
- A signed-in user, because it shows message boxes and prompts for a password.
- Windows PowerShell. It uses `Get-WmiObject`, which is not available in PowerShell 7.
- The BitLocker module.

## What it does

1. Records the removable drives already present.
2. Loops forever, checking every 3 seconds through WMI for removable drives and for any not seen before.
3. For each new drive, reads BitLocker status:
   - Protection on or fully encrypted: logs OK and does nothing.
   - Not encrypted, or status cannot be read: shows a message box saying CMMC policy requires BitLocker and asks whether to encrypt now.
4. If the user chooses Yes, it prompts for a password with `Read-Host`, then runs `Enable-BitLocker` with `Aes256`, a password protector and used-space-only encryption, and shows a message that encryption continues in the background.
5. If the user chooses No, it ejects the drive.
6. If `Enable-BitLocker` fails, it shows the error in a message box.

It runs until stopped with Ctrl+C.

## Review notes

- It cannot work as an Intune script running as SYSTEM, because there is no interactive session to show the dialog or read the password.
- It detects drives with `MediaType='Removable Media'`. Many USB hard drives and some flash drives report as external fixed media and may be missed.
- It uses a password protector only. No recovery password or key escrow is created, so a forgotten password means the data is unrecoverable.
- The script comments suggest swapping in `-RecoveryPasswordProtector` if preferred.
- Nothing starts it automatically, so it needs a scheduled task or startup entry in a user context if you want it always on.
