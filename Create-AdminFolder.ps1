<#
.SYNOPSIS
    Creates an admin explanation folder on the C: drive.
#>

$FolderPath = "C:\AdminInfo"

# Check if the folder exists, create it if it does not
if (-not (Test-Path -Path $FolderPath)) {
    New-Item -Path $FolderPath -ItemType Directory -Force | Out-Null
    Write-Output "Successfully created folder: $FolderPath"
} else {
    Write-Output "Folder already exists: $FolderPath"
}
