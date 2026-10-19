<#
.SYNOPSIS
    Audits, enforces and verifies the disabling of NetBIOS over TCP/IP, NTLMv1, LM authentication, TLS 1.0 and
    TLS 1.1 on Windows endpoints, and writes a report confirming the result.
    Supports CMMC CM.L2-3.4.7[l]: use of nonessential protocols is restricted, disabled, or prevented as defined.

.DESCRIPTION
    Deploy through Microsoft Intune: Devices > Scripts and remediations > Platform scripts > Add > Windows 10 and later.
      Run this script using the logged on credentials : No   (runs as SYSTEM)
      Enforce script signature check                  : No
      Run script in 64-bit PowerShell host            : Yes
    The script also re-launches itself in 64-bit PowerShell if it is started in a 32-bit host.

    One run does all three steps (default $Mode = 'Auto'):
      1. AUDIT    Reads every setting and records whether it is compliant. Nothing is changed.
      2. ENFORCE  Only if the audit found a non-compliant setting: writes the expected value to each one.
      3. VERIFY   Re-reads every setting and records the final state. The exit code and summary come from this step.
    If the audit finds everything compliant, steps 2 and 3 are skipped and the device is left untouched.
    For a pilot that must not change anything, set $Mode = 'AuditOnly'.

    What it sets (all under HKLM):
      NetBIOS over TCP/IP   NetBT\Parameters\Interfaces\Tcpip_<adapter GUID>  NetbiosOptions = 2 (disabled), every adapter
      NTLMv1 and LM         Control\Lsa  LmCompatibilityLevel = 5  (send NTLMv2 only; refuse LM and NTLM)
      LM hash storage       Control\Lsa  NoLMHash = 1
      TLS 1.0 and TLS 1.1   Control\SecurityProviders\SCHANNEL\Protocols\<protocol>\Client and \Server
                            Enabled = 0 and DisabledByDefault = 1

    A Platform script runs once per device (and again only if the script is changed in Intune). To re-apply the
    settings on a schedule, which also covers network adapters added later, deploy the same file as both the
    detection and remediation script of an Intune Remediation.

    Outputs:
      C:\ProgramData\Connectium\Reports\LegacyProtocols_<computer>_<timestamp>.csv   (one row per setting per step)
      HKLM:\SOFTWARE\Connectium\Compliance\LegacyProtocols   (last run, mode, result, report path)
      One summary line on standard output. In a Remediation this appears in Intune as the output.

.NOTES
    TLS and NetBIOS changes take effect after a restart (NetBIOS: after the adapter is reset). The script does not
    restart the device. The report and registry marker record RebootRecommended.
    If the same settings are also configured in a Settings catalog policy (for example the LAN Manager
    authentication level), remove the duplicate so the two do not conflict.
    Disabling these protocols can break legacy applications, file servers, NAS devices and printers that still
    require them. Test on a pilot device first.
#>

# ---------------------------------------------------------------- Configuration
$Mode           = 'Auto'     # 'Auto' = audit, enforce, verify.  'AuditOnly' = audit and report, change nothing.
$PolicyVersion  = '2.0'
$ReportRoot     = Join-Path $env:ProgramData 'Connectium\Reports'
$ReportsToKeep  = 12

# Scope. Set a value to $false to leave that protocol unchanged (it is then reported as NotInScope).
$DisableNetBIOS   = $true
$DisableNtlmV1LM  = $true    # LmCompatibilityLevel = 5 and NoLMHash = 1
$DisableTls10     = $true
$DisableTls11     = $true

# ---------------------------------------------------------------- 64-bit host guard
if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
    $sysnative = Join-Path $env:windir 'sysnative\WindowsPowerShell\v1.0\powershell.exe'
    if (Test-Path -LiteralPath $sysnative) {
        & $sysnative -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath
        exit $LASTEXITCODE
    }
}

# ---------------------------------------------------------------- Helpers
$ErrorActionPreference = 'Stop'
$stamp   = Get-Date -Format 'yyyyMMdd-HHmmss'
$results = New-Object System.Collections.Generic.List[object]
$Phase   = ''

function Get-RegValue {
    param([string]$Path, [string]$Name)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $p = Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction SilentlyContinue
    if ($null -eq $p) { return $null }
    return $p.$Name
}

function Set-RegDword {
    param([string]$Path, [string]$Name, [int]$Value)
    if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -Force | Out-Null }
    New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -PropertyType DWord -Force | Out-Null
}

function Show-Value {
    param($Value)
    if ($null -eq $Value) { return 'NotSet' }
    return [string]$Value
}

function Add-Result {
    param($Covers, $Setting, $Path, $Name, $Expected, $Before, $After, $Action, $Detail)
    $results.Add([pscustomobject]@{
        Computer  = $env:COMPUTERNAME
        Timestamp = (Get-Date).ToString('s')
        Mode      = $Mode
        Phase     = $Phase
        Covers    = $Covers
        Setting   = $Setting
        Path      = $Path
        Name      = $Name
        Expected  = $Expected
        Before    = (Show-Value $Before)
        After     = (Show-Value $After)
        Action    = $Action
        Detail    = $Detail
    })
}

# One setting, one step. Audit and Verify only read. Enforce writes (and logs) only settings that need it.
function Invoke-Setting {
    param([bool]$InScope, [string]$Covers, [string]$Setting, [string]$Path, [string]$Name, [int]$Expected)

    if (-not $InScope) {
        if ($Phase -ne 'Enforce') {
            Add-Result $Covers $Setting $Path $Name $Expected '' '' 'NotInScope' 'Disabled in script configuration'
        }
        return
    }

    $before = Get-RegValue -Path $Path -Name $Name
    $ok = ($null -ne $before -and [int]$before -eq $Expected)

    if ($Phase -ne 'Enforce') {
        if ($ok) { Add-Result $Covers $Setting $Path $Name $Expected $before $before 'Compliant' '' }
        else     { Add-Result $Covers $Setting $Path $Name $Expected $before $before 'NonCompliant' '' }
        return
    }

    if ($ok) { return }    # Enforce step: nothing to do for a setting that is already correct

    try {
        Set-RegDword -Path $Path -Name $Name -Value $Expected
        $after = Get-RegValue -Path $Path -Name $Name
        if ($null -ne $after -and [int]$after -eq $Expected) {
            Add-Result $Covers $Setting $Path $Name $Expected $before $after 'Set' ''
        }
        else {
            Add-Result $Covers $Setting $Path $Name $Expected $before $after 'Failed' 'Value did not match after write'
        }
    }
    catch {
        Add-Result $Covers $Setting $Path $Name $Expected $before (Get-RegValue -Path $Path -Name $Name) 'Failed' $_.Exception.Message
    }
}

# Runs every setting through the current $Phase.
function Invoke-Pass {
    # NetBIOS over TCP/IP: NetbiosOptions 2 on every adapter key
    $netbtPath = 'HKLM:\SYSTEM\CurrentControlSet\Services\NetBT\Parameters\Interfaces'
    $adapterNames = @{}
    try {
        foreach ($c in (Get-CimInstance -ClassName Win32_NetworkAdapterConfiguration -ErrorAction Stop)) {
            if ($c.SettingID) { $adapterNames[[string]$c.SettingID] = [string]$c.Description }
        }
    } catch { }

    $adapterKeys = @()
    if (Test-Path -LiteralPath $netbtPath) {
        $adapterKeys = @(Get-ChildItem -LiteralPath $netbtPath -ErrorAction SilentlyContinue |
            Where-Object { $_.PSChildName -like 'Tcpip_*' })
    }
    if ($adapterKeys.Count -eq 0 -and $Phase -ne 'Enforce') {
        Add-Result 'NetBIOS' 'NetBIOS over TCP/IP' $netbtPath 'NetbiosOptions' 2 '' '' 'Compliant' 'No adapter keys found'
    }
    foreach ($k in $adapterKeys) {
        $guid  = $k.PSChildName -replace '^Tcpip_', ''
        $label = 'NetBIOS over TCP/IP, adapter ' + $guid
        if ($adapterNames.ContainsKey($guid)) { $label += ' (' + $adapterNames[$guid] + ')' }
        Invoke-Setting $DisableNetBIOS 'NetBIOS' $label (Join-Path $netbtPath $k.PSChildName) 'NetbiosOptions' 2
    }

    # NTLMv1 and LM authentication
    $lsa = 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa'
    Invoke-Setting $DisableNtlmV1LM 'NTLMv1;LM' 'LAN Manager authentication level (5 = NTLMv2 only, refuse LM and NTLM)' $lsa 'LmCompatibilityLevel' 5
    Invoke-Setting $DisableNtlmV1LM 'LM'        'Do not store LAN Manager hash'                                         $lsa 'NoLMHash'              1

    # TLS 1.0 and TLS 1.1 (Schannel), client and server
    $schannel = 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols'
    foreach ($proto in @(
            @{ Name = 'TLS 1.0'; Scope = $DisableTls10 },
            @{ Name = 'TLS 1.1'; Scope = $DisableTls11 })) {
        foreach ($role in @('Client', 'Server')) {
            $p = Join-Path (Join-Path $schannel $proto.Name) $role
            Invoke-Setting $proto.Scope $proto.Name ("{0} {1}: Enabled" -f $proto.Name, $role)           $p 'Enabled'           0
            Invoke-Setting $proto.Scope $proto.Name ("{0} {1}: DisabledByDefault" -f $proto.Name, $role) $p 'DisabledByDefault' 1
        }
    }
}

# ---------------------------------------------------------------- Main
if ($Mode -notin @('Auto', 'AuditOnly')) { throw "Invalid `$Mode '$Mode'. Use 'Auto' or 'AuditOnly'." }

# Step 1: audit
$Phase = 'Audit'
Invoke-Pass
$auditNonCompliant = @($results | Where-Object { $_.Phase -eq 'Audit' -and $_.Action -eq 'NonCompliant' })
$finalPhase = 'Audit'
$flow = "Audit: {0} non-compliant" -f $auditNonCompliant.Count

# Steps 2 and 3: enforce, then verify (only when something needs fixing and the mode allows changes)
if ($Mode -eq 'Auto' -and $auditNonCompliant.Count -gt 0) {
    $Phase = 'Enforce'
    Invoke-Pass
    $setCount    = @($results | Where-Object { $_.Phase -eq 'Enforce' -and $_.Action -eq 'Set' }).Count
    $failedCount = @($results | Where-Object { $_.Phase -eq 'Enforce' -and $_.Action -eq 'Failed' }).Count

    $Phase = 'Verify'
    Invoke-Pass
    $finalPhase = 'Verify'
    $flow += (" > Enforce: {0} set, {1} failed" -f $setCount, $failedCount)
}

# ---------------------------------------------------------------- Report and result
New-Item -ItemType Directory -Path $ReportRoot -Force | Out-Null
$reportPath = Join-Path $ReportRoot ("LegacyProtocols_{0}_{1}.csv" -f $env:COMPUTERNAME, $stamp)
$results | Export-Csv -LiteralPath $reportPath -NoTypeInformation -Encoding UTF8

Get-ChildItem -LiteralPath $ReportRoot -Filter 'LegacyProtocols_*.csv' |
    Sort-Object LastWriteTime -Descending | Select-Object -Skip $ReportsToKeep |
    Remove-Item -Force -ErrorAction SilentlyContinue

# The final state is the last step that ran (Verify, or Audit when nothing needed changing)
$final        = @($results | Where-Object { $_.Phase -eq $finalPhase })
$nonCompliant = @($final | Where-Object { $_.Action -eq 'NonCompliant' })
$changed      = @($results | Where-Object { $_.Phase -eq 'Enforce' -and $_.Action -eq 'Set' })
$failed       = @($results | Where-Object { $_.Phase -eq 'Enforce' -and $_.Action -eq 'Failed' })
$compliant    = ($nonCompliant.Count -eq 0)
$reboot       = ($changed.Count -gt 0)
$flow        += (" > Final: {0} non-compliant" -f $nonCompliant.Count)

# Per-protocol status for the summary line
$summary = @()
foreach ($pr in @('NetBIOS', 'NTLMv1', 'LM', 'TLS 1.0', 'TLS 1.1')) {
    $rows = @($final | Where-Object { ($_.Covers -split ';') -contains $pr })
    if ($rows.Count -eq 0 -or @($rows | Where-Object { $_.Action -ne 'NotInScope' }).Count -eq 0) { $state = 'NotInScope' }
    elseif (@($rows | Where-Object { $_.Action -eq 'NonCompliant' }).Count -gt 0) { $state = 'NotDisabled' }
    else { $state = 'Disabled' }
    $summary += ("{0}={1}" -f ($pr -replace ' ', ''), $state)
}

$regPath = 'HKLM:\SOFTWARE\Connectium\Compliance\LegacyProtocols'
New-Item -Path $regPath -Force | Out-Null
Set-ItemProperty -Path $regPath -Name LastRun             -Value (Get-Date).ToString('s')
Set-ItemProperty -Path $regPath -Name Mode                -Value $Mode
Set-ItemProperty -Path $regPath -Name PolicyVersion       -Value $PolicyVersion
Set-ItemProperty -Path $regPath -Name Compliant           -Value ([int]$compliant) -Type DWord
Set-ItemProperty -Path $regPath -Name NonCompliantCount   -Value $nonCompliant.Count -Type DWord
Set-ItemProperty -Path $regPath -Name ChangedCount        -Value $changed.Count -Type DWord
Set-ItemProperty -Path $regPath -Name RebootRecommended   -Value ([int]$reboot) -Type DWord
Set-ItemProperty -Path $regPath -Name Summary             -Value ($summary -join '; ')
Set-ItemProperty -Path $regPath -Name Flow                -Value $flow
Set-ItemProperty -Path $regPath -Name ReportPath          -Value $reportPath

Write-Output ("Mode={0} Compliant={1} Changed={2} RebootRecommended={3} | {4} | {5} | Report={6}" -f `
    $Mode, $compliant, $changed.Count, $reboot, $flow, ($summary -join ' '), $reportPath)
if ($nonCompliant.Count -gt 0) {
    Write-Output ("Non-compliant: " + (($nonCompliant | Select-Object -First 6 | ForEach-Object { "$($_.Setting)" }) -join '; '))
}
if ($failed.Count -gt 0) {
    Write-Output ("Failed: " + (($failed | Select-Object -First 4 | ForEach-Object { "$($_.Setting): $($_.Detail)" }) -join '; '))
}

if ($compliant) { exit 0 } else { exit 1 }
