# Create-AdminFolder.ps1

Creates the folder `C:\AdminInfo` if it does not already exist. It is a small helper that gives other tooling or admins a known location on the device.

## Requirements

- Permission to create a folder in the root of `C:\`, so run elevated or as SYSTEM.
- No modules or parameters.

## What it does

1. Checks whether `C:\AdminInfo` exists.
2. If not, creates it and prints `Successfully created folder: C:\AdminInfo`.
3. If it does, prints `Folder already exists: C:\AdminInfo` and changes nothing.

The script puts nothing inside the folder, so the synopsis line about an "admin explanation folder" describes the intent, not any content the script writes.

## Safety behavior

Idempotent and non-destructive. Running it repeatedly has no side effects. It returns normally in both cases and sets no custom exit code.

## Review notes

- The path is hard-coded. Change `$FolderPath` to use a different location.
