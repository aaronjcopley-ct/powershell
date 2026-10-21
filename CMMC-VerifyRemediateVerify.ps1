[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$Force,
    [switch]$SkipEnrollmentPrompts,
    [string]$NtpServer = 'time.nist.gov',
    [int]$PollIntervalSeconds = 14400,
    [string]$LogPath = "$env:TEMP\CMMC-Pipeline-$(Get-Date -Format 'yyyyMMdd-HHmmss').log",
    [string]$ReportDir = "$env:ProgramData\temp",
    [switch]$SkipPdfReport
)
function Test-IsAdmin {
    $null = net session 2>&1
    return ($LASTEXITCODE -eq 0)
}
$script:IsConstrainedLanguage = ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage')
function Get-RegValue {
    param([string]$Path, [string]$Name)
    try { return (Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop).$Name }
    catch { return $null }
}
$script:CmmcDomainMap = @{
    '3.1' = 'AC'; '3.2' = 'AT'; '3.3' = 'AU'; '3.4' = 'CM'; '3.5' = 'IA'
    '3.6' = 'IR'; '3.7' = 'MA'; '3.8' = 'MP'; '3.9' = 'PS'; '3.10' = 'PE'
    '3.11' = 'RA'; '3.12' = 'CA'; '3.13' = 'SC'; '3.14' = 'SI'
}
function Get-CmmcReference {
    param([string]$NoteText)
    if (($null -eq $NoteText) -or ($NoteText -match '^\s*$')) {
        return 'CMMC L2 Scoping/Assessment Guide -- organizational control (no specific NIST 800-171 control cited)'
    }
    $pattern = '3\.(?:1[0-4]|[1-9])\.\d+'
    $parts = $NoteText -split "($pattern)"
    $ctrlMatches = $parts | Where-Object { $_ -match "^$pattern$" }
    if (@($ctrlMatches).Count -eq 0) {
        return 'CMMC L2 Scoping/Assessment Guide -- organizational control (no specific NIST 800-171 control cited)'
    }
    $refs = foreach ($ctrl in $ctrlMatches) {
        $family = ($ctrl -split '\.')[0..1] -join '.'
        $domain = $script:CmmcDomainMap[$family]
        if ($domain) { "CMMC $domain.L2-$ctrl / NIST SP 800-171 Rev 2 $ctrl" }
        else { "NIST SP 800-171 Rev 2 $ctrl" }
    }
    return (($refs | Select-Object -Unique) -join '; ')
}
function ConvertTo-CsvLine {
    param([string[]]$Fields)
    $escaped = foreach ($f in $Fields) {
        $val = if ($null -eq $f) { '' } else { [string]$f }
        '"' + ($val -replace '"', '""') + '"'
    }
    return ($escaped -join ',')
}
function Add-Result {
    param(
        [string]$Name,
        [string]$OmaUri,
        [string]$SettingRef,
        [string]$Expected,
        [string]$Actual,
        [Nullable[bool]]$Pass,
        [string]$Status,
        [string]$Note,
        [string]$Fix,
        [switch]$Informational
    )
    $ref = if ($SettingRef) { $SettingRef } elseif ($OmaUri) { $OmaUri } else { '' }
    $finalStatus =
        if ($Status) { $Status }
        elseif ($Informational) { 'INFO' }
        elseif ($Pass -eq $true) { 'PASS' }
        elseif ($Pass -eq $false) { 'FAIL' }
        else { 'UNKNOWN' }
    $showDetail = ($finalStatus -ne 'PASS')
    $script:AllResults += @{
        Source    = $script:CurrentSource
        Name      = $Name
        Reference = (Get-CmmcReference -NoteText $Note)
        Setting   = $ref
        Expected  = $Expected
        Actual    = $Actual
        Status    = $finalStatus
        Note      = if ($showDetail) { $Note } else { '' }
        Fix       = if ($showDetail) { $Fix } else { '' }
    }
}
function Add-Padding {
    param([string]$Text, [int]$Width)
    $len = $Text.Length
    if ($len -ge $Width) { return $Text }
    return $Text + (' ' * ($Width - $len))
}
function Limit-StringWidth {
    param([string]$Text, [int]$MaxWidth)
    if ($Text.Length -le $MaxWidth) { return $Text }
    if ($MaxWidth -le 0) { return '' }
    return ($Text[0..($MaxWidth - 1)] -join '')
}
function Write-SimpleTable {
    param([array]$Rows, [string[]]$Columns, [int]$MaxWidth = 40)
    if ($Rows.Count -eq 0) { return }
    $widths = @{}
    foreach ($col in $Columns) {
        $maxDataLen = $col.Length
        foreach ($row in $Rows) {
            $val = [string]$row[$col]
            if ($val.Length -gt $maxDataLen) { $maxDataLen = $val.Length }
        }
        $widths[$col] = if ($maxDataLen -lt $MaxWidth) { $maxDataLen } else { $MaxWidth }
    }
    $headerLine = ''
    $sepLine = ''
    foreach ($col in $Columns) {
        $w = $widths[$col]
        $headerLine += (Add-Padding -Text $col -Width ($w + 2))
        $sepLine += (Add-Padding -Text ('-' * $w) -Width ($w + 2))
    }
    Write-Host $headerLine
    Write-Host $sepLine
    foreach ($row in $Rows) {
        $line = ''
        foreach ($col in $Columns) {
            $w = $widths[$col]
            $val = Limit-StringWidth -Text ([string]$row[$col]) -MaxWidth $w
            $line += (Add-Padding -Text $val -Width ($w + 2))
        }
        Write-Host $line
    }
}
function ConvertTo-HtmlSafe {
    param([string]$Text)
    if ($null -eq $Text) { return '' }
    $t = [string]$Text
    $t = $t -replace '&', '&amp;'
    $t = $t -replace '<', '&lt;'
    $t = $t -replace '>', '&gt;'
    $t = $t -replace '"', '&quot;'
    $t = $t -replace "'", '&#39;'
    return $t
}
function Export-HtmlReport {
    param(
        [Parameter(Mandatory)] [array]$Results,
        [Parameter(Mandatory)] [string]$Path,
        [int]$PassCount,
        [int]$FailCount,
        [int]$OtherCount,
        [int]$DupCount
    )
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $total = $Results.Count
    $passPct = if ($total -gt 0) { "{0:N1}" -f (($PassCount / $total) * 100) } else { '0' }
    $rowsHtml = @()
    foreach ($r in ($Results | Sort-Object -Property {$_.Source}, {$_.Name})) {
        $statusClass = switch ($r.Status) {
            'PASS' { 'pass' }
            'FAIL' { 'fail' }
            default { 'other' }
        }
        $detailHtml = ''
        if ($r.Status -ne 'PASS') {
            $noteHtml = if ($r.Note) { "<div class='detail-line'><span class='detail-label'>Why:</span> $((ConvertTo-HtmlSafe $r.Note))</div>" } else { '' }
            $fixHtml  = if ($r.Fix)  { "<div class='detail-line'><span class='detail-label'>Fix:</span> <code>$((ConvertTo-HtmlSafe $r.Fix))</code></div>" } else { '' }
            $detailHtml = "<div class='detail'>$noteHtml$fixHtml</div>"
        }
        $rowsHtml += @"
        <tr class="row-$statusClass" data-status="$statusClass" data-search="$((ConvertTo-HtmlSafe "$($r.Source) $($r.Name) $($r.Reference)"))">
            <td class="col-source">$((ConvertTo-HtmlSafe $r.Source))</td>
            <td class="col-name"><div class="name-text">$((ConvertTo-HtmlSafe $r.Name))</div>$detailHtml</td>
            <td class="col-ref">$((ConvertTo-HtmlSafe $r.Reference))</td>
            <td class="col-status"><span class="badge badge-$statusClass">$((ConvertTo-HtmlSafe $r.Status))</span></td>
            <td class="col-val">$((ConvertTo-HtmlSafe $r.Expected))</td>
            <td class="col-val">$((ConvertTo-HtmlSafe $r.Actual))</td>
        </tr>
"@
    }
    $dupNote = if ($DupCount -gt 0) { "<p class='dup-note'>$DupCount exact-name duplicate check(s) across source areas were consolidated.</p>" } else { '' }
    $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>CMMC Level 2 / NIST 800-171 Compliance Report -- $((ConvertTo-HtmlSafe $env:COMPUTERNAME))</title>
<style>
  :root {
    --pass: #1a7f37; --pass-bg: #dafbe1;
    --fail: #b91c1c; --fail-bg: #fee2e2;
    --other: #9a6700; --other-bg: #fff3cd;
    --ink: #1f2328; --muted: #57606a; --line: #d1d9e0; --bg: #f6f8fa;
  }
  * { box-sizing: border-box; }
  body {
    font-family: -apple-system, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
    background: var(--bg); color: var(--ink); margin: 0; padding: 24px;
  }
  .wrap { max-width: 1200px; margin: 0 auto; }
  h1 { font-size: 22px; margin: 0 0 4px 0; }
  .meta { color: var(--muted); font-size: 13px; margin-bottom: 20px; }
  .meta strong { color: var(--ink); }
  .cards { display: flex; gap: 12px; margin-bottom: 20px; flex-wrap: wrap; }
  .card {
    background: #fff; border: 1px solid var(--line); border-radius: 8px;
    padding: 14px 20px; min-width: 130px;
  }
  .card .num { font-size: 26px; font-weight: 700; line-height: 1.1; }
  .card .lbl { font-size: 12px; color: var(--muted); text-transform: uppercase; letter-spacing: .03em; }
  .card.pass .num { color: var(--pass); }
  .card.fail .num { color: var(--fail); }
  .card.other .num { color: var(--other); }
  .dup-note { color: var(--muted); font-size: 13px; margin: -8px 0 16px 0; }
  .controls { display: flex; gap: 10px; margin-bottom: 14px; flex-wrap: wrap; align-items: center; }
  .controls input[type=text] {
    padding: 8px 12px; border: 1px solid var(--line); border-radius: 6px; font-size: 14px; min-width: 260px;
  }
  .filter-btn {
    padding: 7px 14px; border: 1px solid var(--line); border-radius: 6px; background: #fff;
    cursor: pointer; font-size: 13px; color: var(--ink);
  }
  .filter-btn.active { background: var(--ink); color: #fff; border-color: var(--ink); }
  table { width: 100%; border-collapse: collapse; background: #fff; border: 1px solid var(--line); border-radius: 8px; overflow: hidden; }
  thead th {
    text-align: left; font-size: 12px; text-transform: uppercase; letter-spacing: .03em;
    color: var(--muted); padding: 10px 12px; border-bottom: 1px solid var(--line); background: var(--bg);
  }
  tbody td { padding: 10px 12px; border-bottom: 1px solid var(--line); font-size: 13px; vertical-align: top; }
  tbody tr:last-child td { border-bottom: none; }
  tbody tr:hover { background: #fafbfc; }
  .col-source { color: var(--muted); white-space: nowrap; }
  .col-ref { color: var(--muted); font-size: 12px; max-width: 220px; }
  .name-text { font-weight: 500; }
  .badge {
    display: inline-block; padding: 3px 10px; border-radius: 999px; font-size: 11px;
    font-weight: 700; text-transform: uppercase; letter-spacing: .03em;
  }
  .badge-pass { background: var(--pass-bg); color: var(--pass); }
  .badge-fail { background: var(--fail-bg); color: var(--fail); }
  .badge-other { background: var(--other-bg); color: var(--other); }
  .detail { margin-top: 6px; padding: 8px 10px; background: var(--bg); border-left: 3px solid var(--line); border-radius: 4px; }
  .row-fail .detail { border-left-color: var(--fail); }
  .row-other .detail { border-left-color: var(--other); }
  .detail-line { font-size: 12.5px; color: var(--muted); margin: 3px 0; }
  .detail-label { font-weight: 600; color: var(--ink); }
  .detail code { background: #eef1f4; padding: 1px 5px; border-radius: 3px; font-size: 12px; }
  .hidden { display: none !important; }
  footer { color: var(--muted); font-size: 12px; margin-top: 24px; text-align: center; }
</style>
</head>
<body>
<div class="wrap">
  <h1>CMMC Level 2 / NIST SP 800-171 Rev 2 Compliance Report</h1>
  <p class="meta">Device: <strong>$((ConvertTo-HtmlSafe $env:COMPUTERNAME))</strong> &nbsp;|&nbsp; Generated: <strong>$timestamp</strong> &nbsp;|&nbsp; Source: DoD CMMC Assessment Guide L2 v2 / CMMC Scoping Guide L2 v2</p>

  <div class="cards">
    <div class="card"><div class="num">$total</div><div class="lbl">Total Checks</div></div>
    <div class="card pass"><div class="num">$PassCount</div><div class="lbl">Pass ($passPct%)</div></div>
    <div class="card fail"><div class="num">$FailCount</div><div class="lbl">Fail</div></div>
    <div class="card other"><div class="num">$OtherCount</div><div class="lbl">Other</div></div>
  </div>
  $dupNote

  <div class="controls">
    <input type="text" id="searchBox" placeholder="Search by name, source, or reference...">
    <button class="filter-btn active" data-filter="all">All</button>
    <button class="filter-btn" data-filter="fail">Fail only</button>
    <button class="filter-btn" data-filter="pass">Pass only</button>
    <button class="filter-btn" data-filter="other">Other</button>
  </div>

  <table>
    <thead>
      <tr>
        <th>Source Area</th>
        <th>Check</th>
        <th>Reference</th>
        <th>Status</th>
        <th>Expected</th>
        <th>Actual</th>
      </tr>
    </thead>
    <tbody id="resultsBody">
$($rowsHtml -join "`n")
    </tbody>
  </table>

  <footer>Generated by Test-CMMC-Level2-Compliance.ps1</footer>
</div>

<script>
  var rows = Array.prototype.slice.call(document.querySelectorAll('#resultsBody tr'));
  var searchBox = document.getElementById('searchBox');
  var filterBtns = document.querySelectorAll('.filter-btn');
  var currentFilter = 'all';

  function applyFilters() {
    var q = searchBox.value.toLowerCase();
    rows.forEach(function (row) {
      var matchesFilter = (currentFilter === 'all') || (row.getAttribute('data-status') === currentFilter);
      var matchesSearch = !q || row.getAttribute('data-search').toLowerCase().indexOf(q) !== -1;
      row.classList.toggle('hidden', !(matchesFilter && matchesSearch));
    });
  }

  searchBox.addEventListener('input', applyFilters);
  filterBtns.forEach(function (btn) {
    btn.addEventListener('click', function () {
      filterBtns.forEach(function (b) { b.classList.remove('active'); });
      btn.classList.add('active');
      currentFilter = btn.getAttribute('data-filter');
      applyFilters();
    });
  });
</script>
</body>
</html>
"@
    $html | Out-File -FilePath $Path -Encoding utf8
}
function Find-BrowserExe {
    $candidates = @(
        "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
        "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
        "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
        "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe"
    )
    foreach ($c in $candidates) {
        if (Test-Path $c) { return $c }
    }
    foreach ($name in @('msedge.exe', 'chrome.exe')) {
        $onPath = Get-Command $name -ErrorAction SilentlyContinue
        if ($onPath) { return $onPath.Source }
    }
    return $null
}
function Get-ControlTokens {
    param([string]$Reference)
    if ([string]::IsNullOrWhiteSpace($Reference)) { return @('Unmapped / Organizational Control') }
    $parts = $Reference -split '\s*;\s*' | Where-Object { $_ -and $_.Trim() -ne '' }
    if (-not $parts -or $parts.Count -eq 0) { return @($Reference.Trim()) }
    return $parts
}
function Export-PdfReport {
    <#
      Builds a print-ready, control-grouped HTML document from the same $deduped
      results used for the CSV/HTML exports, then renders it to PDF via headless
      Microsoft Edge (falls back to Chrome). No third-party modules required.
      A check whose Reference lists multiple controls (separated by ';') is
      listed once under each control it maps to, so the PDF can be read
      strictly "by control" rather than "by source area".
    #>
    param(
        [Parameter(Mandatory)] [array]$Results,
        [Parameter(Mandatory)] [string]$Path,
        [string]$DeviceName = $env:COMPUTERNAME,
        [int]$PassCount,
        [int]$FailCount,
        [int]$OtherCount
    )
    $browser = Find-BrowserExe
    if (-not $browser) {
        Write-Warning "Could not find Microsoft Edge or Google Chrome on this device -- skipping PDF generation. (CSV and HTML reports were still written.)"
        return $null
    }

    $expanded = foreach ($r in $Results) {
        foreach ($ctrl in (Get-ControlTokens -Reference $r.Reference)) {
            [PSCustomObject]@{
                Control  = $ctrl.Trim()
                Source   = $r.Source
                Name     = $r.Name
                Setting  = $r.Setting
                Expected = $r.Expected
                Actual   = $r.Actual
                Status   = $r.Status
                Note     = $r.Note
                Fix      = $r.Fix
            }
        }
    }
    $grouped = $expanded | Group-Object Control | Sort-Object Name
    $genDate = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $deviceEsc = ConvertTo-HtmlSafe $DeviceName
    $total = $Results.Count

    function Get-StatusClass {
        param([string]$Status)
        switch ($Status) {
            'PASS' { 'pass' }
            'FAIL' { 'fail' }
            default { 'other' }
        }
    }

    $sectionsHtml = New-Object System.Text.StringBuilder
    foreach ($grp in $grouped) {
        $ctrlName = ConvertTo-HtmlSafe $grp.Name
        $ctrlPass = ($grp.Group | Where-Object { $_.Status -eq 'PASS' }).Count
        $ctrlFail = ($grp.Group | Where-Object { $_.Status -eq 'FAIL' }).Count
        $ctrlOther = ($grp.Group | Where-Object { $_.Status -notin @('PASS', 'FAIL') }).Count

        [void]$sectionsHtml.Append("<div class='control-block'>")
        [void]$sectionsHtml.Append("<h2>$ctrlName</h2>")
        [void]$sectionsHtml.Append("<div class='control-tally'>$ctrlPass pass &nbsp;|&nbsp; $ctrlFail fail &nbsp;|&nbsp; $ctrlOther other</div>")
        [void]$sectionsHtml.Append("<table>")
        [void]$sectionsHtml.Append("<thead><tr><th>Setting / Check</th><th>Source Area</th><th>Status</th><th>Expected</th><th>Actual</th><th>How It Was Evaluated</th></tr></thead><tbody>")

        foreach ($item in ($grp.Group | Sort-Object Status, Name)) {
            $cls = Get-StatusClass $item.Status
            $name = ConvertTo-HtmlSafe $item.Name
            $source = ConvertTo-HtmlSafe $item.Source
            $status = ConvertTo-HtmlSafe $item.Status
            $expected = ConvertTo-HtmlSafe $item.Expected
            $actual = ConvertTo-HtmlSafe $item.Actual
            $setting = ConvertTo-HtmlSafe $item.Setting
            $note = ConvertTo-HtmlSafe $item.Note
            $fix = ConvertTo-HtmlSafe $item.Fix

            $howText = if ($setting) { "Registry/CSP setting: <code>$setting</code>" } else { "Evaluated via script logic (no single registry/CSP path)." }
            if ($note) { $howText += "<div class='note'>$note</div>" }
            if ($fix -and $status -ne 'PASS') { $howText += "<div class='fix'><strong>Fix:</strong> <code>$fix</code></div>" }

            [void]$sectionsHtml.Append("<tr class='row-$cls'>")
            [void]$sectionsHtml.Append("<td class='name-cell'>$name</td>")
            [void]$sectionsHtml.Append("<td>$source</td>")
            [void]$sectionsHtml.Append("<td><span class='badge badge-$cls'>$status</span></td>")
            [void]$sectionsHtml.Append("<td>$expected</td>")
            [void]$sectionsHtml.Append("<td>$actual</td>")
            [void]$sectionsHtml.Append("<td class='how-cell'>$howText</td>")
            [void]$sectionsHtml.Append("</tr>")
        }
        [void]$sectionsHtml.Append("</tbody></table></div>")
    }

    $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>CMMC Level 2 / NIST SP 800-171 / GCC High Compliance Report -- $deviceEsc</title>
<style>
  * { box-sizing: border-box; }
  body { font-family: Calibri, Arial, sans-serif; color: #1f2328; margin: 0; padding: 28px 32px; font-size: 11px; }
  h1 { font-size: 19px; margin: 0 0 4px 0; }
  h2 { font-size: 13px; margin: 22px 0 4px 0; padding: 6px 10px; background: #f0f3f7; border-left: 4px solid #445; }
  .meta { color: #57606a; font-size: 11px; margin-bottom: 14px; }
  .cards { display: flex; gap: 10px; margin-bottom: 16px; }
  .card { border: 1px solid #d1d9e0; border-radius: 6px; padding: 8px 14px; min-width: 90px; }
  .card .num { font-size: 18px; font-weight: 700; }
  .card .lbl { font-size: 9px; color: #57606a; text-transform: uppercase; }
  .card.pass .num { color: #1a7f37; }
  .card.fail .num { color: #b91c1c; }
  .card.other .num { color: #9a6700; }
  .control-block { page-break-inside: avoid; margin-bottom: 10px; }
  .control-tally { font-size: 10px; color: #57606a; margin-bottom: 6px; }
  table { width: 100%; border-collapse: collapse; margin-bottom: 6px; }
  thead th { text-align: left; font-size: 9.5px; text-transform: uppercase; letter-spacing: .02em; color: #57606a; padding: 5px 6px; border-bottom: 1px solid #d1d9e0; background: #fafbfc; }
  tbody td { padding: 5px 6px; border-bottom: 1px solid #eaeef2; vertical-align: top; font-size: 10.5px; }
  .name-cell { font-weight: 600; width: 15%; }
  .how-cell { width: 26%; }
  .badge { display: inline-block; padding: 2px 7px; border-radius: 999px; font-size: 9px; font-weight: 700; text-transform: uppercase; }
  .badge-pass { background: #dafbe1; color: #1a7f37; }
  .badge-fail { background: #fee2e2; color: #b91c1c; }
  .badge-other { background: #fff3cd; color: #9a6700; }
  .row-fail td { background: #fff8f8; }
  .row-other td { background: #fffdf5; }
  .note { margin-top: 3px; font-size: 9.5px; color: #57606a; }
  .fix { margin-top: 3px; font-size: 9.5px; }
  code { background: #eef1f4; padding: 1px 4px; border-radius: 3px; font-size: 9.5px; word-break: break-all; }
  footer { color: #8b949e; font-size: 9px; margin-top: 20px; text-align: center; }
</style>
</head>
<body>
  <h1>CMMC Level 2 / NIST SP 800-171 Rev 2 / GCC High Compliance Report</h1>
  <p class="meta">
    Device: <strong>$deviceEsc</strong> &nbsp;|&nbsp;
    Report generated: <strong>$genDate</strong> &nbsp;|&nbsp;
    Baseline: DoD CMMC Assessment Guide L2 v2 / CMMC Scoping Guide L2 v2
  </p>
  <div class="cards">
    <div class="card"><div class="num">$total</div><div class="lbl">Total Checks</div></div>
    <div class="card pass"><div class="num">$PassCount</div><div class="lbl">Pass</div></div>
    <div class="card fail"><div class="num">$FailCount</div><div class="lbl">Fail</div></div>
    <div class="card other"><div class="num">$OtherCount</div><div class="lbl">Other</div></div>
  </div>
  <p class="meta">Grouped below by GCC High / NIST 800-171 / CMMC control reference. Checks that map to more than one control are listed once under each applicable control.</p>
  $($sectionsHtml.ToString())
  <footer>Generated by Invoke-CMMC-VerifyRemediateVerify1.ps1 (Export-PdfReport)</footer>
</body>
</html>
"@

    $tempHtmlPath = [System.IO.Path]::ChangeExtension([System.IO.Path]::GetTempFileName(), 'html')
    Set-Content -Path $tempHtmlPath -Value $html -Encoding UTF8

    try {
        $fileUri = ([Uri]$tempHtmlPath).AbsoluteUri
        $edgeArgs = @(
            '--headless=new',
            '--disable-gpu',
            '--no-sandbox',
            '--print-to-pdf-no-header',
            "--print-to-pdf=`"$Path`"",
            "`"$fileUri`""
        )
        $proc = Start-Process -FilePath $browser -ArgumentList $edgeArgs -Wait -PassThru -WindowStyle Hidden
        if ($proc.ExitCode -ne 0 -or -not (Test-Path $Path)) {
            Write-Warning "PDF generation failed (browser exit code $($proc.ExitCode)). CSV and HTML reports are still available."
            return $null
        }
        return $Path
    } finally {
        Remove-Item $tempHtmlPath -ErrorAction SilentlyContinue
    }
}
function Write-Log {
    param([string]$Message, [string]$Color = 'White')
    $line = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $Message
    Write-Host $line -ForegroundColor $Color
    Add-Content -Path $LogPath -Value $line
}
function Set-RegValueTracked {
    param([string]$Path, [string]$Name, $Value, [string]$Type = 'DWord', [string]$BackupPath)
    $current = Get-RegValue -Path $Path -Name $Name
    if ($current -eq $Value) {
        Write-Log "  $Name already = $current -- no change needed." 'DarkGray'
        return $false
    }
    if (-not (Test-Path $BackupPath)) { New-Item -Path $BackupPath -Force | Out-Null }
    Set-ItemProperty -Path $BackupPath -Name $Name -Value $(if ($null -eq $current) { -9999 } else { $current }) -Type $Type -Force
    if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
    Set-ItemProperty -Path $Path -Name $Name -Value $Value -Type $Type -Force
    Write-Log "  $Name changed: $current -> $Value" 'Green'
    return $true
}
function Add-Summary {
    param(
        [string]$Name,
        [Nullable[bool]]$Pass,
        [string]$Status,
        [string]$Detail
    )
    $finalStatus =
        if ($Status) { $Status }
        elseif ($Pass -eq $true) { 'PASS' }
        elseif ($Pass -eq $false) { 'FAIL' }
        else { 'UNKNOWN' }
    $script:Summary += @{
        Source = $script:CurrentSource
        Name   = $Name
        Status = $finalStatus
        Detail = $Detail
    }
}
function Get-InteractiveUser {
    try {
        $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        if ($cs.UserName) { return $cs.UserName }
    } catch {}
    return $null
}
function Start-InteractiveProcess {
    param([string]$Command, [string]$Description)
    $whoamiOutput = whoami 2>&1
    $isSystem = ($whoamiOutput -match 'nt authority\\system')
    $parts = $Command -split ' ', 2
    $filePath = $parts[0]
    $arguments = if ($parts.Count -gt 1) { $parts[1] } else { $null }
    if (-not $isSystem) {
        try {
            if ($arguments) {
                Start-Process -FilePath $filePath -ArgumentList $arguments | Out-Null
            } else {
                Start-Process -FilePath $filePath | Out-Null
            }
            Write-Log "Launched: $Description" 'Green'
            return $true
        } catch {
            Write-Log "Failed to launch $Description : $($_.Exception.Message)" 'Red'
            return $false
        }
    }
    $interactiveUser = Get-InteractiveUser
    if (-not $interactiveUser) {
        Write-Log "Running as SYSTEM and no interactively logged-on user was detected -- cannot show $Description to anyone right now. It will need to be launched manually next time someone is signed in: $Command" 'Yellow'
        return $false
    }
    try {
        $taskName = "CMMC-Prompt-$(Get-Date -Format 'HHmmss')-$(Get-Random -Maximum 9999)"
        $childCommand = if ($arguments) { "Start-Process -FilePath '$filePath' -ArgumentList '$arguments'" } else { "Start-Process -FilePath '$filePath'" }
        $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -WindowStyle Hidden -Command `"$childCommand`""
        $trigger = New-ScheduledTaskTrigger -Once -At ((Get-Date) + (New-TimeSpan -Seconds 10))
        $principal = New-ScheduledTaskPrincipal -UserId $interactiveUser -LogonType Interactive -RunLevel Limited
        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Force -ErrorAction Stop | Out-Null
        Write-Log "Running as SYSTEM -- scheduled $Description to open in $interactiveUser's session in ~10 seconds (task: $taskName)." 'Green'
        Start-Job -ScriptBlock {
            param($tn)
            Start-Sleep -Seconds 60
            Unregister-ScheduledTask -TaskName $tn -Confirm:$false -ErrorAction SilentlyContinue
        } -ArgumentList $taskName | Out-Null
        return $true
    } catch {
        Write-Log "Could not schedule $Description for the interactive session: $($_.Exception.Message)" 'Red'
        Write-Log "Manual fallback: have the user (currently: $interactiveUser) run this themselves: Start-Process $Command" 'Yellow'
        return $false
    }
}
$script:ProgressStatusPath = "$env:ProgramData\CMMC\progress.json"
function Update-ProgressNotification {
    param([int]$Step, [int]$Total = 10, [string]$Label, [switch]$Done, [string]$RebootNote = 'Will reboot after applied.')
    if ($script:IsConstrainedLanguage) { return }
    try {
        $statusDir = Split-Path $script:ProgressStatusPath -Parent
        if (-not (Test-Path $statusDir)) { New-Item -ItemType Directory -Path $statusDir -Force | Out-Null }
        [PSCustomObject]@{ Step = $Step; Total = $Total; Label = $Label; Done = [bool]$Done; RebootNote = $RebootNote } |
            ConvertTo-Json | Set-Content -Path $script:ProgressStatusPath -Encoding UTF8
    } catch {
        Write-Log "Could not update progress notification: $($_.Exception.Message)" 'DarkGray'
    }
}
function Start-ProgressNotification {
    if ($script:IsConstrainedLanguage) {
        Write-Log "Progress notification window skipped: this session is running in $($ExecutionContext.SessionState.LanguageMode) mode, which does not support the WinForms-based progress window (requires Add-Type/FullLanguage). Progress will be reported via console/log output only." 'DarkGray'
        return
    }
    $progressDir = Split-Path $script:ProgressStatusPath -Parent
    if (-not (Test-Path $progressDir)) { New-Item -ItemType Directory -Path $progressDir -Force | Out-Null }
    $companionScriptPath = "$env:TEMP\CMMC-ProgressWindow.ps1"
    $statusPathForCompanion = $script:ProgressStatusPath
    $companionScript = @"
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

`$statusPath = '$statusPathForCompanion'

`$form = New-Object System.Windows.Forms.Form
`$form.Text = 'GCCH Compliance Remediation'
`$form.Size = New-Object System.Drawing.Size(420,150)
`$form.FormBorderStyle = 'FixedToolWindow'
`$form.StartPosition = 'Manual'
`$screen = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
`$form.Location = New-Object System.Drawing.Point((`$screen.Width - 440), (`$screen.Height - 170))
`$form.TopMost = `$true
`$form.ShowInTaskbar = `$false

`$headerLabel = New-Object System.Windows.Forms.Label
`$headerLabel.Text = 'GCCH Compliance Remediation in Effect'
`$headerLabel.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
`$headerLabel.AutoSize = `$false
`$headerLabel.Size = New-Object System.Drawing.Size(390,20)
`$headerLabel.Location = New-Object System.Drawing.Point(15,10)
`$form.Controls.Add(`$headerLabel)

`$areaLabel = New-Object System.Windows.Forms.Label
`$areaLabel.Text = 'Starting compliance check...'
`$areaLabel.AutoSize = `$false
`$areaLabel.Size = New-Object System.Drawing.Size(390,18)
`$areaLabel.Location = New-Object System.Drawing.Point(15,34)
`$form.Controls.Add(`$areaLabel)

`$progressLabel = New-Object System.Windows.Forms.Label
`$progressLabel.Text = 'Progress: [................................] 0%'
`$progressLabel.Font = New-Object System.Drawing.Font('Consolas', 9)
`$progressLabel.AutoSize = `$false
`$progressLabel.Size = New-Object System.Drawing.Size(390,20)
`$progressLabel.Location = New-Object System.Drawing.Point(15,58)
`$form.Controls.Add(`$progressLabel)

`$rebootLabel = New-Object System.Windows.Forms.Label
`$rebootLabel.Text = 'Will reboot after applied.'
`$rebootLabel.AutoSize = `$false
`$rebootLabel.Size = New-Object System.Drawing.Size(390,18)
`$rebootLabel.Location = New-Object System.Drawing.Point(15,84)
`$form.Controls.Add(`$rebootLabel)

function Get-BracketProgress {
    param([int]`$Percent, [int]`$Width = 32)
    `$filled = [int]([Math]::Round((`$Percent / 100) * `$Width))
    `$filled = [Math]::Min([Math]::Max(`$filled,0),`$Width)
    `$bar = ('x' * `$filled) + ('.' * (`$Width - `$filled))
    return "Progress: [`$bar] `$Percent%"
}

`$closeTimer = New-Object System.Windows.Forms.Timer
`$closeTimer.Interval = 5000
`$closeTimer.Add_Tick({ `$form.Close() })

`$pollTimer = New-Object System.Windows.Forms.Timer
`$pollTimer.Interval = 500
`$pollTimer.Add_Tick({
    if (Test-Path `$statusPath) {
        try {
            `$s = Get-Content `$statusPath -Raw | ConvertFrom-Json
            `$pct = if (`$s.Total -gt 0) { [int]((`$s.Step / `$s.Total) * 100) } else { 0 }
            `$areaLabel.Text = `$s.Label
            `$progressLabel.Text = Get-BracketProgress -Percent `$pct
            if (`$s.RebootNote) { `$rebootLabel.Text = `$s.RebootNote }
            if (`$s.Done -and -not `$closeTimer.Enabled) {
                `$pollTimer.Stop()
                `$closeTimer.Start()
            }
        } catch {}
    }
})
`$pollTimer.Start()

[System.Windows.Forms.Application]::Run(`$form)
"@
    Set-Content -Path $companionScriptPath -Value $companionScript -Encoding UTF8
    Update-ProgressNotification -Step 0 -Total 10 -Label 'Starting CMMC compliance pipeline...'
    $isSystem = ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value -eq 'S-1-5-18')
    if (-not $isSystem) {
        try {
            Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$companionScriptPath`"" | Out-Null
            Write-Log "Progress notification window launched." 'DarkGray'
        } catch {
            Write-Log "Could not launch progress notification window: $($_.Exception.Message)" 'DarkGray'
        }
        return
    }
    $interactiveUser = Get-InteractiveUser
    if (-not $interactiveUser) {
        Write-Log "Running as SYSTEM with no interactive user logged on -- skipping the progress notification window (nothing to show it to). Remediation proceeds normally, just without a visible progress UI." 'DarkGray'
        return
    }
    Write-Log "Detected interactive user for progress window: $interactiveUser" 'DarkGray'
    try {
        $taskName = "CMMC-ProgressWindow-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$companionScriptPath`""
        $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddSeconds(5)
        $principal = New-ScheduledTaskPrincipal -UserId $interactiveUser -LogonType Interactive -RunLevel Limited
        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Force -ErrorAction Stop | Out-Null
        Write-Log "Running as SYSTEM -- scheduled the progress notification window to open in $interactiveUser's session in ~5 seconds (task: $taskName)." 'DarkGray'
        Start-Sleep -Seconds 8
        try {
            $taskInfo = Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction Stop
            if ($taskInfo.LastTaskResult -eq 0) {
                Write-Log "Progress notification window launch confirmed (task ran successfully)." 'DarkGray'
            } else {
                Write-Log "Progress notification window task ran but reported a non-zero result (0x$('{0:X}' -f $taskInfo.LastTaskResult)) -- it may not have actually appeared. This does not affect remediation, which continues normally." 'Yellow'
            }
        } catch {
            Write-Log "Could not confirm whether the progress notification window actually launched: $($_.Exception.Message). Remediation continues normally regardless." 'DarkGray'
        }
        Start-Job -ScriptBlock {
            param($tn)
            Start-Sleep -Seconds 60
            Unregister-ScheduledTask -TaskName $tn -Confirm:$false -ErrorAction SilentlyContinue
        } -ArgumentList $taskName | Out-Null
    } catch {
        Write-Log "Could not schedule the progress notification window: $($_.Exception.Message)" 'DarkGray'
    }
}
function Get-AuditAndCryptoResults {
    $script:CurrentSource = 'Audit & Crypto'
    Write-Host ""
    function Get-AuditSubcategory {
        param([Parameter(Mandatory)][string]$Subcategory)
        $raw = auditpol /get /subcategory:"$Subcategory" /r 2>$null
        if (-not $raw) { return $null }
        $csv = $raw | ConvertFrom-Csv
        if (-not $csv) { return $null }
        return ($csv | Select-Object -First 1).'Inclusion Setting'
    }
    function Convert-AuditValueToText {
        param([int]$Value)
        switch ($Value) {
            0 { 'No Auditing' }
            1 { 'Success' }
            2 { 'Failure' }
            3 { 'Success and Failure' }
            default { 'Unknown' }
        }
    }
    $auditChecks = @(
        @{ Name = 'Audit Credential Validation';          Sub = 'Credential Validation';        Expected = 3; OmaUri = 'Audit/AccountLogon_AuditCredentialValidation' }
        @{ Name = 'Audit File System';                     Sub = 'File System';                  Expected = 3; OmaUri = 'Audit/ObjectAccess_AuditFileSystem' }
        @{ Name = 'Audit System Events';                    Sub = 'Security System Extension';    Expected = 3; OmaUri = 'Audit/System_AuditSecuritySystemExtension' }
        @{ Name = 'Audit Process Creation';                 Sub = 'Process Creation';             Expected = 1; OmaUri = 'Audit/DetailedTracking_AuditProcessCreation' }
        @{ Name = 'Audit Removable Storage';                Sub = 'Removable Storage';            Expected = 3; OmaUri = 'Audit/ObjectAccess_AuditRemovableStorage' }
        @{ Name = 'Audit PNP Activity';                     Sub = 'Plug and Play Events';         Expected = 1; OmaUri = 'Audit/DetailedTracking_AuditPNPActivity' }
        @{ Name = 'Audit User Account Management';          Sub = 'User Account Management';      Expected = 3; OmaUri = 'Audit/AccountManagement_AuditUserAccountManagement' }
        @{ Name = 'Audit Computer Account Management';      Sub = 'Computer Account Management';  Expected = 3; OmaUri = 'Audit/AccountManagement_AuditComputerAccountManagement' }
        @{ Name = 'Audit Sensitive Privilege Use';          Sub = 'Sensitive Privilege Use';      Expected = 3; OmaUri = 'Audit/PrivilegeUse_AuditSensitivePrivilegeUse' }
        @{ Name = 'Audit Non-Sensitive Privilege Use';      Sub = 'Non Sensitive Privilege Use';  Expected = 3; OmaUri = 'Audit/PrivilegeUse_AuditNonSensitivePrivilegeUse' }
    )
    foreach ($chk in $auditChecks) {
        $expectedText = Convert-AuditValueToText -Value $chk.Expected
        $actualText   = Get-AuditSubcategory -Subcategory $chk.Sub
        if ($null -eq $actualText) {
            Add-Result -Name $chk.Name -OmaUri $chk.OmaUri -Expected $expectedText -Actual 'NOT FOUND' -Pass $false `
                -Note "auditpol could not read subcategory '$($chk.Sub)'. Either the subcategory name changed in this Windows build or auditpol failed to run." `
                -Fix "Run 'auditpol /list /subcategory:*' to confirm the exact subcategory name, then re-apply the policy via Intune/GPO."
            continue
        }
        $pass = ($actualText -eq $expectedText)
        Add-Result -Name $chk.Name -OmaUri $chk.OmaUri -Expected $expectedText -Actual $actualText -Pass $pass `
            -Note "Subcategory '$($chk.Sub)' is set to '$actualText' instead of the required '$expectedText'. This subcategory maps to NIST 800-171 3.3.1 (audit event generation) and won't produce the log data needed for review/investigation." `
            -Fix "Set via GPO/Intune (OMA-URI $($chk.OmaUri) = $($chk.Expected)), or locally: auditpol /set /subcategory:`"$($chk.Sub)`" /success:enable /failure:$(if($chk.Expected -eq 3){'enable'}else{'disable'})"
    }
    $fipsPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\FipsAlgorithmPolicy'
    $fipsVal  = (Get-ItemProperty -Path $fipsPath -Name Enabled -ErrorAction SilentlyContinue).Enabled
    $fipsPass = ($fipsVal -eq 1)
    Add-Result -Name 'Enable FIPS Mode' -OmaUri 'Cryptography/AllowFipsAlgorithmPolicy' -Expected '1 (Enabled)' `
        -Actual $(if ($null -eq $fipsVal) { 'NOT SET' } else { $fipsVal }) -Pass $fipsPass `
        -Note "FIPS 140 validated cryptography is not being enforced. NIST 800-171 3.13.11 requires FIPS-validated cryptographic modules for protecting CUI." `
        -Fix "Apply via Intune (OMA-URI Cryptography/AllowFipsAlgorithmPolicy = 1), or locally: Set-ItemProperty -Path '$fipsPath' -Name Enabled -Value 1 (requires reboot; TEST on one device first - this can break apps using non-FIPS algorithms)."
    $ntpClientPath = 'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\TimeProviders\NtpClient'
    $ntpClientEnabled = (Get-ItemProperty -Path $ntpClientPath -Name Enabled -ErrorAction SilentlyContinue).Enabled
    $ntpClientPass = ($ntpClientEnabled -eq 1)
    Add-Result -Name 'Enable NTP Client' -OmaUri 'ADMX_W32Time/W32TIME_POLICY_ENABLE_NTPCLIENT' -Expected '1 (Enabled)' `
        -Actual $(if ($null -eq $ntpClientEnabled) { 'NOT SET' } else { $ntpClientEnabled }) -Pass $ntpClientPass `
        -Note "Windows Time (NTP) client is not enabled. NIST 800-171 3.3.7 requires system clocks to be synchronized with an authoritative time source for accurate audit timestamps." `
        -Fix "Apply via Intune (OMA-URI ADMX_W32Time/W32TIME_POLICY_ENABLE_NTPCLIENT = <enabled/>), or locally: Set-ItemProperty -Path '$ntpClientPath' -Name Enabled -Value 1; Restart-Service W32Time"
    $ntpParamsPath = 'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Parameters'
    $ntpServer = (Get-ItemProperty -Path $ntpParamsPath -Name NtpServer -ErrorAction SilentlyContinue).NtpServer
    $ntpType   = (Get-ItemProperty -Path $ntpParamsPath -Name Type -ErrorAction SilentlyContinue).Type
    $ntpServerConfigured = -not (($null -eq $ntpServer) -or ($ntpServer -match '^\s*$'))
    $usesConsumerEndpoint = $ntpServer -match 'time\.windows\.com'
    $ntpServerPass = $ntpServerConfigured -and ($ntpType -eq 'NTP') -and (-not $usesConsumerEndpoint)
    $ntpNote = if (-not $ntpServerConfigured) {
        "No NTP server configured. Audit timestamps cannot be tied to an authoritative time source (NIST 3.3.7)."
    } elseif ($usesConsumerEndpoint) {
        "NTP server is set to 'time.windows.com', a consumer Microsoft endpoint. This is not generally accepted as an authoritative, documentable time source for NIST 800-171/CMMC AU.L2-3.3.7 evidence in GCC High assessments."
    } elseif ($ntpType -ne 'NTP') {
        "Time provider Type is '$ntpType' instead of 'NTP' - client isn't actively syncing against the configured server."
    } else { '' }
    $ntpFix = "Point to an authoritative source: w32tm /config /manualpeerlist:`"time.nist.gov,0x9`" /syncfromflags:manual /reliable:yes /update; Restart-Service W32Time. (Or sync domain-joined machines from the PDC emulator, which itself syncs to time.nist.gov.)"
    Add-Result -Name 'Configure NTP Server' -OmaUri 'ADMX_W32Time/W32TIME_POLICY_CONFIGURE_NTPCLIENT' `
        -Expected 'Authoritative NTP server (e.g. time.nist.gov), Type=NTP' `
        -Actual "$ntpServer (Type=$ntpType)" -Pass $ntpServerPass -Note $ntpNote -Fix $(if ($ntpServerPass) { '' } else { $ntpFix })
    $cmdLinePath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\Audit'
    $cmdLineVal  = (Get-ItemProperty -Path $cmdLinePath -Name ProcessCreationIncludeCmdLine_Enabled -ErrorAction SilentlyContinue).ProcessCreationIncludeCmdLine_Enabled
    $cmdLinePass = ($cmdLineVal -eq 1)
    Add-Result -Name 'Audit Include Command Line' -OmaUri 'ADMX_AuditSettings/IncludeCmdLine' -Expected '1 (Enabled)' `
        -Actual $(if ($null -eq $cmdLineVal) { 'NOT SET' } else { $cmdLineVal }) -Pass $cmdLinePass `
        -Note "Command-line arguments are not being included in process creation events (4688). NIST 3.3.1/3.14.6 rely on this detail for detecting malicious activity (e.g. distinguishing a benign vs. malicious use of powershell.exe)." `
        -Fix "Apply via Intune (OMA-URI ADMX_AuditSettings/IncludeCmdLine = <enabled/>), or locally: New-Item -Path '$cmdLinePath' -Force | Out-Null; Set-ItemProperty -Path '$cmdLinePath' -Name ProcessCreationIncludeCmdLine_Enabled -Value 1 -Type DWord. Requires 'Audit Process Creation' subcategory to also be enabled to take effect."
}
function Get-DefenderASRConfigResults {
    $script:CurrentSource = 'Defender & ASR Configuration'
    Write-Host ""
    $mp = Get-MpPreference -ErrorAction SilentlyContinue
    if (-not $mp) {
        Write-Error "Get-MpPreference failed. Windows Defender may be disabled or replaced by a third-party AV. Aborting Defender checks."
    } else {
        Add-Result -Name 'Defender Scan Removable' -OmaUri 'Defender/AllowFullScanRemovableDriveScanning' `
            -Expected 'Enabled' -Actual $(if ($mp.DisableRemovableDriveScanning) { 'Disabled' } else { 'Enabled' }) `
            -Pass (-not $mp.DisableRemovableDriveScanning) `
            -Note "Removable drive scanning is off. NIST 3.7.4 requires controlling media (USB/removable) before use to prevent malware introduction." `
            -Fix 'Set-MpPreference -DisableRemovableDriveScanning $false'
        Add-Result -Name 'Defender Real-Time' -OmaUri 'Defender/AllowRealtimeMonitoring' `
            -Expected 'Enabled' -Actual $(if ($mp.DisableRealtimeMonitoring) { 'Disabled' } else { 'Enabled' }) `
            -Pass (-not $mp.DisableRealtimeMonitoring) `
            -Note "Real-time monitoring is off. NIST 3.14.2 requires malicious code protection at endpoints, updated as new releases become available -- this is the core always-on scanning engine." `
            -Fix 'Set-MpPreference -DisableRealtimeMonitoring $false'
        Add-Result -Name 'Defender Scan Downloads' -OmaUri 'Defender/AllowIOAVProtection' `
            -Expected 'Enabled' -Actual $(if ($mp.DisableIOAVProtection) { 'Disabled' } else { 'Enabled' }) `
            -Pass (-not $mp.DisableIOAVProtection) `
            -Note "Scanning of downloaded files/attachments (IE/Outlook) is off. Part of NIST 3.14.2 malicious code protection at entry/exit points." `
            -Fix 'Set-MpPreference -DisableIOAVProtection $false'
        Add-Result -Name 'Defender Behavior Monitor' -OmaUri 'Defender/AllowBehaviorMonitoring' `
            -Expected 'Enabled' -Actual $(if ($mp.DisableBehaviorMonitoring) { 'Disabled' } else { 'Enabled' }) `
            -Pass (-not $mp.DisableBehaviorMonitoring) `
            -Note "Behavior-based detection is off. NIST 3.14.2 -- this catches fileless/novel malware that signature scanning alone misses." `
            -Fix 'Set-MpPreference -DisableBehaviorMonitoring $false'
        $mapsOk = ($mp.MAPSReporting -ne 0)
        Add-Result -Name 'Defender Cloud Protection' -OmaUri 'Defender/AllowCloudProtection' `
            -Expected 'Enabled (Basic or Advanced)' -Actual $(switch ($mp.MAPSReporting) {0{'Disabled'} 1{'Basic'} 2{'Advanced'} default{"Unknown ($($mp.MAPSReporting))"}}) `
            -Pass $mapsOk `
            -Note "Cloud-delivered protection (MAPS) is off. NIST 3.14.2 -- this provides near-real-time signature/heuristic updates against emerging threats that offline signatures haven't caught up to yet." `
            -Fix 'Set-MpPreference -MAPSReporting Advanced'
        $puaOk = ($mp.PUAProtection -eq 1)
        Add-Result -Name 'Defender PUA Block' -OmaUri 'Defender/PUAProtection' `
            -Expected '1 (Block)' -Actual $mp.PUAProtection `
            -Pass $puaOk `
            -Note "Potentially Unwanted Application blocking is not set to Block. NIST 3.14.2 -- PUAs (adware, bundled toolbars, cryptomining droppers) are a common initial-access vector." `
            -Fix 'Set-MpPreference -PUAProtection Enabled'
        $sigOk = ($mp.SignatureUpdateInterval -eq 4)
        Add-Result -Name 'Defender Sig Update 4hr' -OmaUri 'Defender/SignatureUpdateInterval' `
            -Expected '4 (hours)' -Actual $mp.SignatureUpdateInterval `
            -Pass $sigOk `
            -Note "Signature update interval is not every 4 hours. NIST 3.14.4 requires malicious code protection mechanisms be updated as new releases are available." `
            -Fix 'Set-MpPreference -SignatureUpdateInterval 4'
        $scanParamOk = ($mp.ScanParameters -eq 2)
        Add-Result -Name 'Defender Full Scan' -OmaUri 'Defender/ScanParameter' `
            -Expected '2 (Full scan)' -Actual $mp.ScanParameters `
            -Pass $scanParamOk `
            -Note "Scheduled scan type is not Full scan. NIST 3.14.5 -- periodic full-system scans catch dormant/inactive malware that real-time and quick scans can miss." `
            -Fix 'Set-MpPreference -ScanParameters FullScan'
        $expectedScanDay = 7
        $scanDayOk = ($mp.ScanScheduleDay -eq $expectedScanDay)
        $scanDayNote = if ($mp.ScanScheduleDay -eq 6) {
            "Scheduled scan day is set to 6, which is FRIDAY, not Saturday. The CSV's own value (6) appears to be a data-entry error -- Microsoft's ScheduleScanDay enum is 0=Every day, 1=Sun...6=Fri, 7=Sat. If Saturday is genuinely intended (per the row's description), the source policy/CSV needs correcting to 7, not just this device."
        } else {
            "Scheduled scan day is not set to Saturday (7). NIST 3.14.5 requires a defined periodic full-scan schedule."
        }
        Add-Result -Name 'Defender Scan Saturday' -OmaUri 'Defender/ScheduleScanDay' `
            -Expected '7 (Saturday)' -Actual $mp.ScanScheduleDay `
            -Pass $scanDayOk -Note $scanDayNote `
            -Fix 'Set-MpPreference -ScanScheduleDay 7   (# then fix the source Intune/GPO policy value too -- it currently pushes 6)'
        $expectedMinutes = 120
        $actualScanTime = $mp.ScanScheduleTime
        $actualMinutes = if ($actualScanTime -is [TimeSpan]) { [int]$actualScanTime.TotalMinutes } else { $null }
        $scanTimeOk = ($actualMinutes -eq $expectedMinutes)
        Add-Result -Name 'Defender Scan 2AM' -OmaUri 'Defender/ScheduleScanTime' `
            -Expected '120 min (2:00 AM)' -Actual "$actualScanTime ($actualMinutes min)" `
            -Pass $scanTimeOk `
            -Note "Scheduled scan time is not 2:00 AM. Not itself a hard NIST citation, but scans should run during low-usage hours to ensure they actually complete without being interrupted or skipped due to user activity." `
            -Fix 'Set-MpPreference -ScanScheduleTime 120'
        $netProtOk = ($mp.EnableNetworkProtection -eq 1)
        Add-Result -Name 'Network Protection Block' -OmaUri 'Defender/EnableNetworkProtection' `
            -Expected '1 (Enabled/Block)' -Actual $mp.EnableNetworkProtection `
            -Pass $netProtOk `
            -Note "Network Protection is not in Block mode (0=Disabled, 2=Audit only doesn't actually block). NIST 3.13.6 requires denying network traffic by default / blocking known-malicious connections." `
            -Fix 'Set-MpPreference -EnableNetworkProtection Enabled'
    }
    $appInstallPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\SmartScreen'
    $appInstallVal = Get-RegValue -Path $appInstallPath -Name 'ConfigureAppInstallControlEnabled'
    $appInstallOk = ($appInstallVal -eq 1)
    Add-Result -Name 'Smart App Control' -OmaUri 'SmartScreen/EnableAppInstallControl' `
        -Expected '1 (Store apps only)' -Actual $(if ($null -eq $appInstallVal) {'NOT SET'} else {$appInstallVal}) `
        -Pass $appInstallOk `
        -Note "App Install Control is not restricting installs to the Store. NIST 3.4.8 -- restricts installation of software not explicitly authorized. Note: despite the row name, this is Windows' 'Configure App Install Control' (SmartScreen), not the newer Windows 11 'Smart App Control' feature, which isn't MDM-configurable the same way -- worth relabeling this row for clarity." `
        -Fix "New-Item -Path '$appInstallPath' -Force | Out-Null; Set-ItemProperty -Path '$appInstallPath' -Name ConfigureAppInstallControlEnabled -Value 1 -Type DWord"
    $shellSmartScreenPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'
    $shellSmartScreenVal = Get-RegValue -Path $shellSmartScreenPath -Name 'EnableSmartScreenInShell'
    $shellSmartScreenOk = ($shellSmartScreenVal -eq 1)
    Add-Result -Name 'SmartScreen in Shell' -OmaUri 'SmartScreen/EnableSmartScreenInShell' `
        -Expected '1 (Enabled)' -Actual $(if ($null -eq $shellSmartScreenVal) {'NOT SET'} else {$shellSmartScreenVal}) `
        -Pass $shellSmartScreenOk `
        -Note "SmartScreen file reputation checks in File Explorer are off. NIST 3.14.2 -- catches malicious executables at the point a user tries to run them, independent of AV signatures." `
        -Fix "New-Item -Path '$shellSmartScreenPath' -Force | Out-Null; Set-ItemProperty -Path '$shellSmartScreenPath' -Name EnableSmartScreenInShell -Value 1 -Type DWord"
    $devUnlockPath = 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\ApplicationManagement'
    $devUnlockVal = Get-RegValue -Path $devUnlockPath -Name 'AllowDeveloperUnlock'
    $devUnlockOk = ($devUnlockVal -eq 0) -or ($null -eq $devUnlockVal)
    Add-Result -Name 'Block Sideloading' -OmaUri 'ApplicationManagement/AllowDeveloperUnlock' `
        -Expected '0 (Blocked)' -Actual $(if ($null -eq $devUnlockVal) {'NOT SET (defaults to blocked)'} else {$devUnlockVal}) `
        -Pass $devUnlockOk `
        -Note "Developer Unlock / sideloading is permitted. NIST 3.4.7 -- restricts installation of unauthorized/unsigned software outside approved channels." `
        -Fix "Push via Intune (OMA-URI ApplicationManagement/AllowDeveloperUnlock = 0). This is a native MDM-only policy with no local GPO equivalent -- if this check shows NOT SET on a non-MDM-enrolled device, that's expected and not a finding."
    $trustedAppsPath = 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\ApplicationManagement'
    $trustedAppsVal = Get-RegValue -Path $trustedAppsPath -Name 'AllowAllTrustedApps'
    $trustedAppsOk = ($trustedAppsVal -eq 0) -or ($null -eq $trustedAppsVal)
    Add-Result -Name 'Block Unknown Source Apps' -OmaUri 'ApplicationManagement/AllowAllTrustedApps' `
        -Expected '0 (Blocked)' -Actual $(if ($null -eq $trustedAppsVal) {'NOT SET (defaults to blocked)'} else {$trustedAppsVal}) `
        -Pass $trustedAppsOk `
        -Note "Sideloaded apps signed by any trusted certificate (not just Store-verified) are permitted. NIST 3.4.8 -- restricts unauthorized software installation." `
        -Fix "Push via Intune (OMA-URI ApplicationManagement/AllowAllTrustedApps = 0). Native MDM-only policy -- NOT SET on a non-MDM-enrolled device is expected, not a finding."
    $msiPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Installer'
    $msiUserCtrlVal = Get-RegValue -Path $msiPath -Name 'EnableUserControl'
    $msiUserCtrlOk = ($msiUserCtrlVal -eq 0)
    Add-Result -Name 'Block MSI User Control' -OmaUri 'ApplicationManagement/MSIAllowUserControlOverInstall' `
        -Expected '0 (Blocked)' -Actual $(if ($null -eq $msiUserCtrlVal) {'NOT SET'} else {$msiUserCtrlVal}) `
        -Pass $msiUserCtrlOk `
        -Note "Standard users can override MSI install options (e.g. change install location/target). NIST 3.4.9 -- restricts non-privileged users from altering security-relevant install behavior." `
        -Fix "New-Item -Path '$msiPath' -Force | Out-Null; Set-ItemProperty -Path '$msiPath' -Name EnableUserControl -Value 0 -Type DWord"
    $msiElevatedVal = Get-RegValue -Path $msiPath -Name 'AlwaysInstallElevated'
    $msiElevatedOk = ($msiElevatedVal -eq 0) -or ($null -eq $msiElevatedVal)
    Add-Result -Name 'Block MSI Elevated' -OmaUri 'ApplicationManagement/MSIAlwaysInstallWithElevatedPrivileges' `
        -Expected '0 (Blocked)' -Actual $(if ($null -eq $msiElevatedVal) {'NOT SET (defaults to blocked)'} else {$msiElevatedVal}) `
        -Pass $msiElevatedOk `
        -Note "MSI packages can self-elevate to install with SYSTEM privileges regardless of the invoking user's rights. This is a well-known local-privilege-escalation vector (any user-run MSI runs as SYSTEM). NIST 3.4.9." `
        -Fix "New-Item -Path '$msiPath' -Force | Out-Null; Set-ItemProperty -Path '$msiPath' -Name AlwaysInstallElevated -Value 0 -Type DWord"
    $gameDvrPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR'
    $gameDvrVal = Get-RegValue -Path $gameDvrPath -Name 'AllowGameDVR'
    $gameDvrOk = ($gameDvrVal -eq 0)
    Add-Result -Name 'Disable Game DVR' -OmaUri 'ApplicationManagement/AllowGameDVR' `
        -Expected '0 (Disabled)' -Actual $(if ($null -eq $gameDvrVal) {'NOT SET'} else {$gameDvrVal}) `
        -Pass $gameDvrOk `
        -Note "Game DVR/Xbox Game Bar screen capture is enabled. NIST 3.4.6 -- unauthorized/unnecessary screen-recording functionality on a system handling CUI is an unneeded attack surface and potential data-exposure path." `
        -Fix "New-Item -Path '$gameDvrPath' -Force | Out-Null; Set-ItemProperty -Path '$gameDvrPath' -Name AllowGameDVR -Value 0 -Type DWord"
    $edgePath = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'
    $edgeSmartScreenVal = Get-RegValue -Path $edgePath -Name 'SmartScreenEnabled'
    $edgeSmartScreenOk = ($edgeSmartScreenVal -eq 1)
    Add-Result -Name 'Edge SmartScreen' -OmaUri 'Browser/AllowSmartScreen' `
        -Expected '1 (Enabled)' -Actual $(if ($null -eq $edgeSmartScreenVal) {'NOT SET'} else {$edgeSmartScreenVal}) `
        -Pass $edgeSmartScreenOk `
        -Note "SmartScreen is off in Microsoft Edge. NIST 3.14.2 -- browser-based phishing/malware URL and download reputation checking." `
        -Fix "New-Item -Path '$edgePath' -Force | Out-Null; Set-ItemProperty -Path '$edgePath' -Name SmartScreenEnabled -Value 1 -Type DWord"
    $edgeSiteBypassVal = Get-RegValue -Path $edgePath -Name 'PreventSmartScreenPromptOverride'
    $edgeSiteBypassOk = ($edgeSiteBypassVal -eq 1)
    Add-Result -Name 'Block SmartScreen Site Bypass' -OmaUri 'Browser/PreventSmartScreenPromptOverride' `
        -Expected '1 (Enabled)' -Actual $(if ($null -eq $edgeSiteBypassVal) {'NOT SET'} else {$edgeSiteBypassVal}) `
        -Pass $edgeSiteBypassOk `
        -Note "Users can click through SmartScreen site warnings. NIST 3.14.2 -- a security control that end users can bypass at will provides little real protection." `
        -Fix "New-Item -Path '$edgePath' -Force | Out-Null; Set-ItemProperty -Path '$edgePath' -Name PreventSmartScreenPromptOverride -Value 1 -Type DWord"
    $edgeDlBypassVal = Get-RegValue -Path $edgePath -Name 'PreventSmartScreenPromptOverrideForFiles'
    $edgeDlBypassOk = ($edgeDlBypassVal -eq 1)
    Add-Result -Name 'Block SmartScreen DL Bypass' -OmaUri 'Browser/PreventSmartScreenPromptOverrideForFiles' `
        -Expected '1 (Enabled)' -Actual $(if ($null -eq $edgeDlBypassVal) {'NOT SET'} else {$edgeDlBypassVal}) `
        -Pass $edgeDlBypassOk `
        -Note "Users can click through SmartScreen download warnings. Same rationale as site-bypass above -- NIST 3.14.2." `
        -Fix "New-Item -Path '$edgePath' -Force | Out-Null; Set-ItemProperty -Path '$edgePath' -Name PreventSmartScreenPromptOverrideForFiles -Value 1 -Type DWord"
    foreach ($profile in @('Domain','Private','Public')) {
        $fwProfile = Get-NetFirewallProfile -Profile $profile -ErrorAction SilentlyContinue
        $logBlockedOk = ($fwProfile.LogBlocked -eq 'True')
        Add-Result -Name "Firewall Log Dropped $($profile)Profile" -OmaUri "Vendor/MSFT/Firewall/MdmStore/$($profile)Profile/EnableLogDroppedPackets" `
            -Expected 'True' -Actual $fwProfile.LogBlocked -Pass $logBlockedOk `
            -Note "Dropped/blocked packets are not being logged on the $profile firewall profile. NIST 3.3.1 -- audit records need to capture denied network connection attempts for incident investigation." `
            -Fix "Set-NetFirewallProfile -Profile $profile -LogBlocked True"
    }
}
function Get-EndpointProtectionResults {
    $script:CurrentSource = 'Endpoint Protection (Credential Guard/BitLocker/Firewall/UAC)'
    Write-Host ""
    $dg = Get-CimInstance -ClassName Win32_DeviceGuard -Namespace root\Microsoft\Windows\DeviceGuard -ErrorAction SilentlyContinue
    if (-not $dg) {
        Add-Result -Name 'Credential Guard' -SettingRef 'DeviceGuardLocalSystemAuthorityCredentialGuardSettings' `
            -Expected 'Running' -Actual 'UNABLE TO QUERY' -Pass $false `
            -Note "Could not query Win32_DeviceGuard. This WMI class may be unavailable on this SKU/build." `
            -Fix "Verify manually: Get-CimInstance -ClassName Win32_DeviceGuard -Namespace root\Microsoft\Windows\DeviceGuard"
    } else {
        $credGuardRunning = $dg.SecurityServicesRunning -contains 1
        Add-Result -Name 'Credential Guard' -SettingRef 'DeviceGuardLocalSystemAuthorityCredentialGuardSettings' `
            -Expected 'Running (SecurityServicesRunning contains 1)' -Actual "$($dg.SecurityServicesRunning -join ',')" `
            -Pass $credGuardRunning `
            -Note "Credential Guard is not running. NIST 3.5.10/3.13.11-adjacent (DISA STIG, CAT III) -- protects LSASS secrets (NTLM hashes, Kerberos tickets) from credential-theft tools like Mimikatz via virtualization-based isolation." `
            -Fix "Requires UEFI+TPM+virtualization hardware support. Set via Intune (DeviceGuardLocalSystemAuthorityCredentialGuardSettings = Enabled with UEFI lock), or locally: New-Item -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceGuard' -Force | Out-Null; Set-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceGuard' -Name LsaCfgFlags -Value 1 -Type DWord; then reboot twice."
        $vbsRunning = ($dg.VirtualizationBasedSecurityStatus -eq 2)
        Add-Result -Name 'Virtualization Based Security' -SettingRef 'DeviceGuardEnableVirtualizationBasedSecurity' `
            -Expected '2 (Enabled and Running)' -Actual $dg.VirtualizationBasedSecurityStatus -Pass $vbsRunning `
            -Note "VBS is not enabled and running (0=Not enabled, 1=Enabled but not running -- usually a hardware/firmware gap, 2=Running). VBS is the hypervisor-based isolation foundation Credential Guard and other Device Guard features depend on." `
            -Fix "New-Item -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard' -Force | Out-Null; Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard' -Name EnableVirtualizationBasedSecurity -Value 1 -Type DWord; reboot. Requires virtualization enabled in BIOS/UEFI."
        $dmaOk = ($dg.RequiredSecurityProperties -contains 4) -or ($dg.AvailableSecurityProperties -contains 4)
        Add-Result -Name 'Secure Boot with DMA Protection' -SettingRef 'DeviceGuardEnableSecureBootWithDMA' `
            -Expected 'DMA protection available/required' -Actual "Available: $($dg.AvailableSecurityProperties -join ','); Required: $($dg.RequiredSecurityProperties -join ',')" `
            -Pass $dmaOk `
            -Note "Secure Boot + DMA protection (against physical/Thunderbolt-based memory attacks) is not configured. This requires IOMMU-capable hardware -- if this system's hardware doesn't support it, this will always show unavailable regardless of policy." `
            -Fix "Set RequirePlatformSecurityFeatures = 3 (Secure Boot and DMA Protection) under the DeviceGuard registry key alongside EnableVirtualizationBasedSecurity. Requires compatible hardware (IOMMU)."
    }
    foreach ($fwProfile in @('Domain','Private','Public')) {
        $fw = Get-NetFirewallProfile -Profile $fwProfile -ErrorAction SilentlyContinue
        $enabledOk = ($fw.Enabled -eq $true)
        Add-Result -Name "Firewall $fwProfile Enabled" -SettingRef "FirewallProfile${fwProfile}FirewallEnabled" `
            -Expected 'True' -Actual $fw.Enabled -Pass $enabledOk `
            -Note "$fwProfile firewall profile is disabled. NIST 3.13.1 -- boundary protection is a foundational control; an unprotected profile leaves the device exposed on that network type." `
            -Fix "Set-NetFirewallProfile -Profile $fwProfile -Enabled True"
        if ($fwProfile -in @('Public')) {
            $inboundOk = ($fw.DefaultInboundAction -eq 'Block')
            Add-Result -Name "Firewall $fwProfile Inbound Blocked" -SettingRef "FirewallProfilePublicIncomingTrafficBlocked" `
                -Expected 'Block' -Actual $fw.DefaultInboundAction -Pass $inboundOk `
                -Note "Public profile does not block inbound traffic by default. NIST 3.13.1/3.13.6 -- default-deny is the baseline expectation on untrusted networks." `
                -Fix "Set-NetFirewallProfile -Profile Public -DefaultInboundAction Block"
        }
        if ($fwProfile -in @('Domain')) {
            $unicastOk = ($fw.AllowUnicastResponseToMulticast -eq $false)
            Add-Result -Name "Firewall Domain Unicast-to-Multicast Blocked" -SettingRef "FirewallProfileDomainUnicastResponsesToMulticastBroadcastsBlocked" `
                -Expected 'False (blocked)' -Actual $fw.AllowUnicastResponseToMulticast -Pass $unicastOk `
                -Note "Unicast responses to multicast/broadcast requests are allowed on the Domain profile -- a minor recon/amplification exposure (allows network reconnaissance of live hosts)." `
                -Fix "Set-NetFirewallProfile -Profile Domain -AllowUnicastResponseToMulticast False"
        }
        if ($fwProfile -in @('Public','Private')) {
            $notifyOk = ($fw.NotifyOnListen -eq $false)
            Add-Result -Name "Firewall $fwProfile Inbound Notifications Blocked" -SettingRef "FirewallProfile${fwProfile}InboundNotificationsBlocked" `
                -Expected 'False (notifications off)' -Actual $fw.NotifyOnListen -Pass $notifyOk `
                -Note "Inbound-blocked notifications are showing to users on the $fwProfile profile. Not itself a hard compliance gap, but STIG baseline expects these suppressed to reduce noise/training users to dismiss security prompts." `
                -Fix "Set-NetFirewallProfile -Profile $fwProfile -NotifyOnListen False"
        }
    }
    $lsaPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa'
    $noLmHash = Get-RegValue -Path $lsaPath -Name 'NoLMHash'
    Add-Result -Name 'Do Not Store LM Hash' -SettingRef 'LocalSecurityOptionsDoNotStoreLANManagerHashValueOnNextPasswordChange' `
        -Expected '1' -Actual $(if ($null -eq $noLmHash) {'NOT SET'} else {$noLmHash}) -Pass ($noLmHash -eq 1) `
        -Note "LAN Manager hashes are being stored on password change. LM hashes are cryptographically weak and crackable in seconds -- a significant credential-theft risk. NIST 3.13.11 / DISA STIG." `
        -Fix "Set-ItemProperty -Path '$lsaPath' -Name NoLMHash -Value 1 -Type DWord"
    $blankPw = Get-RegValue -Path $lsaPath -Name 'LimitBlankPasswordUse'
    Add-Result -Name 'Block Remote Logon with Blank Password' -SettingRef 'LocalSecurityOptionsBlockRemoteLogonWithBlankPassword' `
        -Expected '1' -Actual $(if ($null -eq $blankPw) {'NOT SET (default=1)'} else {$blankPw}) -Pass (($blankPw -eq 1) -or ($null -eq $blankPw)) `
        -Note "Accounts with blank passwords can log on remotely. NIST 3.5.7/3.13.11 -- trivially exploitable if any local account is ever left without a password." `
        -Fix "Set-ItemProperty -Path '$lsaPath' -Name LimitBlankPasswordUse -Value 1 -Type DWord"
    $restrictAnonSam = Get-RegValue -Path $lsaPath -Name 'RestrictAnonymousSAM'
    Add-Result -Name 'Restrict Anonymous SAM Enumeration' -SettingRef 'LocalSecurityOptionsDoNotAllowAnonymousEnumerationOfSAMAccounts' `
        -Expected '1' -Actual $(if ($null -eq $restrictAnonSam) {'NOT SET'} else {$restrictAnonSam}) -Pass ($restrictAnonSam -eq 1) `
        -Note "Anonymous users can enumerate local SAM accounts. NIST 3.1.1/3.13.11 -- gives an unauthenticated attacker a list of valid local usernames to target for password attacks." `
        -Fix "Set-ItemProperty -Path '$lsaPath' -Name RestrictAnonymousSAM -Value 1 -Type DWord"
    $restrictNullSess = Get-RegValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\LanManServer\Parameters' -Name 'RestrictNullSessAccess'
    Add-Result -Name 'Restrict Anonymous Access to Named Pipes/Shares' -SettingRef 'LocalSecurityOptionsRestrictAnonymousAccessToNamedPipesAndShares' `
        -Expected '1' -Actual $(if ($null -eq $restrictNullSess) {'NOT SET'} else {$restrictNullSess}) -Pass ($restrictNullSess -eq 1) `
        -Note "Anonymous (null session) access to named pipes and shares is permitted. NIST 3.1.1 -- classic lateral-movement/enumeration vector." `
        -Fix "Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\LanManServer\Parameters' -Name RestrictNullSessAccess -Value 1 -Type DWord"
    $insecureGuest = Get-RegValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\LanmanWorkstation' -Name 'AllowInsecureGuestAuth'
    Add-Result -Name 'Disable Insecure Guest Logons' -SettingRef 'LanManagerWorkstationDisableInsecureGuestLogons' `
        -Expected '0' -Actual $(if ($null -eq $insecureGuest) {'NOT SET'} else {$insecureGuest}) -Pass ($insecureGuest -eq 0) `
        -Note "Insecure (unauthenticated) guest logons to remote SMB shares are allowed. This is a well-known SMB relay/downgrade risk. NIST 3.1.1/3.13.11." `
        -Fix "New-Item -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\LanmanWorkstation' -Force | Out-Null; Set-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\LanmanWorkstation' -Name AllowInsecureGuestAuth -Value 0 -Type DWord"
    $uacPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
    $adminPrompt = Get-RegValue -Path $uacPath -Name 'ConsentPromptBehaviorAdmin'
    Add-Result -Name 'Admin Elevation Prompt Behavior' -SettingRef 'LocalSecurityOptionsAdministratorElevationPromptBehavior' `
        -Expected '2 (Prompt for consent on secure desktop)' -Actual $(if ($null -eq $adminPrompt) {'NOT SET'} else {$adminPrompt}) -Pass ($adminPrompt -eq 2) `
        -Note "Admin elevation prompt is not set to 'Prompt for consent on secure desktop'. A lower value can allow silent/non-secure-desktop elevation, weakening UAC's protection against credential-prompt spoofing. NIST 3.1.5/3.1.6." `
        -Fix "Set-ItemProperty -Path '$uacPath' -Name ConsentPromptBehaviorAdmin -Value 2 -Type DWord"
    $userPrompt = Get-RegValue -Path $uacPath -Name 'ConsentPromptBehaviorUser'
    if ($userPrompt -eq 1) {
        Add-Result -Name 'Standard User Elevation Prompt Behavior' -SettingRef 'LocalSecurityOptionsStandardUserElevationPromptBehavior' `
            -Expected '0 (Automatically deny) OR 1 (Prompt for credentials -- accepted org exception)' -Actual $userPrompt `
            -Status 'OTHER' `
            -Note "Approved organizational exception: this environment has no standard, on-site IT department and a remote-heavy user base, so admins elevate via dedicated .adm accounts at the credential prompt or LAPS rather than relying on a locally-present technician. Value 1 (prompt for credentials on the secure desktop) still requires a valid admin credential to elevate -- standard users cannot self-elevate -- so it meets the intent of NIST 3.1.5/3.1.6 least-privilege without the fully auto-deny setting, which would block remote admin support entirely." `
            -Fix ''
        } else {
            Add-Result -Name 'Standard User Elevation Prompt Behavior' -SettingRef 'LocalSecurityOptionsStandardUserElevationPromptBehavior' `
                -Expected '0 (Automatically deny) OR 1 (Prompt for credentials -- accepted org exception)' -Actual $(if ($null -eq $userPrompt) {'NOT SET'} else {$userPrompt}) -Pass ($userPrompt -eq 0) `
                -Note "Standard (non-admin) users are not set to have elevation requests automatically denied, and the value present is not the approved exception (1 -- prompt for credentials). NIST 3.1.5/3.1.6 -- least privilege; standard users should not be able to self-elevate without a valid admin credential." `
                -Fix "Set-ItemProperty -Path '$uacPath' -Name ConsentPromptBehaviorUser -Value 0 -Type DWord   # or -Value 1 for the accepted remote-admin exception"
        }
    $adminApproval = Get-RegValue -Path $uacPath -Name 'EnableLUA'
    Add-Result -Name 'UAC Admin Approval Mode' -SettingRef 'LocalSecurityOptionsUseAdminApprovalMode' `
        -Expected '1' -Actual $(if ($null -eq $adminApproval) {'NOT SET (default=1)'} else {$adminApproval}) -Pass (($adminApproval -eq 1) -or ($null -eq $adminApproval)) `
        -Note "UAC (LUA/Admin Approval Mode) is disabled. This is the core mechanism that makes local administrator accounts run with standard-user tokens by default. NIST 3.1.5/AC-6." `
        -Fix "Set-ItemProperty -Path '$uacPath' -Name EnableLUA -Value 1 -Type DWord; reboot required"
    $msvPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\MSV1_0'
    $ntlmClient = Get-RegValue -Path $msvPath -Name 'NTLMMinClientSec'
    $ntlmServer = Get-RegValue -Path $msvPath -Name 'NTLMMinServerSec'
    $ntlmExpected = 537395200
    Add-Result -Name 'NTLM Minimum Session Security (Clients)' -SettingRef 'LocalSecurityOptionsMinimumSessionSecurityForNtlmSspBasedClients' `
        -Expected "$ntlmExpected (0x20080000)" -Actual $(if ($null -eq $ntlmClient) {'NOT SET'} else {$ntlmClient}) -Pass ($ntlmClient -eq $ntlmExpected) `
        -Note "NTLM client sessions do not require NTLMv2 + 128-bit encryption. Weaker NTLM negotiation is vulnerable to relay and downgrade attacks. NIST 3.13.11." `
        -Fix "Set-ItemProperty -Path '$msvPath' -Name NTLMMinClientSec -Value $ntlmExpected -Type DWord"
    Add-Result -Name 'NTLM Minimum Session Security (Servers)' -SettingRef 'LocalSecurityOptionsMinimumSessionSecurityForNtlmSspBasedServers' `
        -Expected "$ntlmExpected (0x20080000)" -Actual $(if ($null -eq $ntlmServer) {'NOT SET'} else {$ntlmServer}) -Pass ($ntlmServer -eq $ntlmExpected) `
        -Note "NTLM server sessions do not require NTLMv2 + 128-bit encryption. Same rationale as the client-side setting. NIST 3.13.11." `
        -Fix "Set-ItemProperty -Path '$msvPath' -Name NTLMMinServerSec -Value $ntlmExpected -Type DWord"
    $inactivityPath = $uacPath
    $inactivity = Get-RegValue -Path $inactivityPath -Name 'InactivityTimeoutSecs'
    $inactivityOk = ($null -ne $inactivity) -and ($inactivity -gt 0) -and ($inactivity -le 900)
    Add-Result -Name 'Machine Inactivity Limit' -SettingRef 'LocalSecurityOptionsMachineInactivityLimit' `
        -Expected '<= 900 seconds (15 min)' -Actual $(if ($null -eq $inactivity) {'NOT SET'} else {"$inactivity sec"}) -Pass $inactivityOk `
        -Note "Machine inactivity/session lock timeout is not set to 15 minutes or less. NIST 3.1.10/3.1.11 explicitly requires session lock after a defined period of inactivity." `
        -Fix "Set-ItemProperty -Path '$inactivityPath' -Name InactivityTimeoutSecs -Value 900 -Type DWord"
    $blModule = Get-Module -ListAvailable -Name BitLocker
    if (-not $blModule) {
        Add-Result -Name 'BitLocker Module' -SettingRef 'N/A' -Expected 'Available' -Actual 'NOT AVAILABLE' -Pass $false `
            -Note "BitLocker PowerShell module isn't available on this system (may be Windows Home edition, which doesn't support BitLocker/only Device Encryption)." `
            -Fix "BitLocker requires Windows Pro/Enterprise/Education. Verify edition with: (Get-CimInstance Win32_OperatingSystem).Caption"
    } else {
        $osVol = Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction SilentlyContinue
        $protectionStatus = if ($osVol) { $osVol.ProtectionStatus } else { $null }
        $encryptOk = ($protectionStatus -eq 'On')
        Add-Result -Name 'BitLocker Encrypt Device (OS Drive)' -SettingRef 'BitLockerEncryptDevice' `
            -Expected 'On' -Actual $(if ($null -eq $protectionStatus) { 'UNKNOWN / NOT ENCRYPTED' } else { $protectionStatus }) -Pass $encryptOk `
            -Note "The OS drive ($env:SystemDrive) is not BitLocker-protected. NIST 3.8.6/3.1.19 -- protects CUI at rest against offline/physical disk access (lost or stolen device)." `
            -Fix "Enable-BitLocker -MountPoint $env:SystemDrive -EncryptionMethod XtsAes256 -UsedSpaceOnly -TpmProtector"
        $keyProtectorTypes = @()
        if ($osVol -and $osVol.KeyProtector) {
            $keyProtectorTypes = @($osVol.KeyProtector | ForEach-Object { $_.KeyProtectorType })
        }
        $startupAuthOk = ($keyProtectorTypes -contains 'Tpm') -or ($keyProtectorTypes -contains 'TpmPin')
        Add-Result -Name 'BitLocker Startup Authentication' -SettingRef 'BitLockerSystemDrivesRequireStartupAuthentication' `
            -Expected 'TPM or TPM+PIN protector present' -Actual $(if ($keyProtectorTypes.Count -gt 0) { $keyProtectorTypes -join ',' } else { 'NONE' }) -Pass $startupAuthOk `
            -Note "No TPM-based startup key protector found on the OS drive. Without this, BitLocker may be relying on a weaker protector or none, undermining pre-boot protection." `
            -Fix "Manage-bde -protectors -add $env:SystemDrive -TPMAndPIN   (or -TPM alone, per your org's PIN policy)"
        $method = if ($osVol) { $osVol.EncryptionMethod } else { $null }
        $methodOk = ($method -match 'XtsAes256')
        Add-Result -Name 'BitLocker Encryption Method' -SettingRef 'BitLockerEncryptionMethodByDriveType' `
            -Expected 'XtsAes256' -Actual $(if ($null -eq $method) { 'NONE' } else { $method }) -Pass $methodOk `
            -Note "OS drive is not using XTS-AES 256. NIST 3.13.11 requires FIPS-validated, strong encryption -- AES-128 or legacy CBC mode are weaker choices than the XTS-AES 256 baseline." `
            -Fix "Requires decrypt + re-encrypt: manage-bde -off $env:SystemDrive; then Enable-BitLocker -MountPoint $env:SystemDrive -EncryptionMethod XtsAes256 -TpmProtector"
        $fixedVols = Get-BitLockerVolume -ErrorAction SilentlyContinue | Where-Object { $_.VolumeType -eq 'Data' -and $_.MountPoint -ne $env:SystemDrive }
        if ($fixedVols) {
            $allFixedEncrypted = -not ($fixedVols | Where-Object { $_.ProtectionStatus -ne 'On' })
            Add-Result -Name 'BitLocker Fixed Drives Require Encryption' -SettingRef 'BitLockerFixedDrivesRequireEncryption' `
                -Expected 'On (all fixed data drives)' -Actual "$(($fixedVols | ForEach-Object {"$($_.MountPoint)=$($_.ProtectionStatus)"}) -join '; ')" -Pass $allFixedEncrypted `
                -Note "One or more fixed (non-OS) drives are not BitLocker-encrypted. NIST 3.8.6 applies to all drives storing CUI, not just the OS drive." `
                -Fix "Enable-BitLocker -MountPoint <drive> -EncryptionMethod XtsAes256 -UsedSpaceOnly for each unencrypted fixed drive"
        } else {
            Add-Result -Name 'BitLocker Fixed Drives Require Encryption' -SettingRef 'BitLockerFixedDrivesRequireEncryption' `
                -Expected 'N/A' -Actual 'No additional fixed data drives present' -Pass $true -Informational `
                -Note "No non-OS fixed drives found on this system." -Fix ''
        }
        $osRecoveryConfigured = ($null -ne (Get-RegValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\FVE' -Name 'OSRecovery'))
        Add-Result -Name 'BitLocker System Drive Recovery Options' -SettingRef 'BitLockerSystemDrivesRecoveryOptions' `
            -Expected 'Configured per org policy' -Actual $(if ($osRecoveryConfigured) {'Configured'} else {'NOT CONFIGURED'}) `
            -Pass $osRecoveryConfigured -Informational `
            -Note "No universal 'correct' value -- this defines whether recovery keys can be saved to AD/Entra, printed, etc. Confirm against your org's actual recovery/escrow policy rather than a generic baseline." `
            -Fix "Configure via Intune Endpoint Protection profile per your org's key-escrow requirements (e.g. require AD/Entra backup before allowing encryption)."
        $fdvRecoveryConfigured = ($null -ne (Get-RegValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\FVE' -Name 'FDVRecovery'))
        Add-Result -Name 'BitLocker Fixed Drive Recovery Options' -SettingRef 'BitLockerFixedDrivesRecoveryOptions' `
            -Expected 'Configured per org policy' -Actual $(if ($fdvRecoveryConfigured) {'Configured'} else {'NOT CONFIGURED'}) `
            -Pass $fdvRecoveryConfigured -Informational `
            -Note "Same as above -- org-specific recovery/escrow choice, not a single correct value." `
            -Fix "Configure via Intune per your org's key-escrow requirements."
        $recoveryMsgConfigured = ($null -ne (Get-RegValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\FVE' -Name 'OSRecoveryMessage')) -or ($null -ne (Get-RegValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\FVE' -Name 'OSRecoveryURL'))
        Add-Result -Name 'BitLocker Recovery Message' -SettingRef 'BitLockerSystemDrivesRecoveryMessage' `
            -Expected 'Configured with org contact info' -Actual $(if ($recoveryMsgConfigured) {'Configured'} else {'NOT CONFIGURED (default message)'}) `
            -Pass $recoveryMsgConfigured -Informational `
            -Note "Custom pre-boot recovery message/URL not set. Not a hard compliance requirement, but best practice for a locked-out user (physical device recovery) to know who to contact." `
            -Fix "Configure a custom recovery message/URL via Intune pointing to your IT help desk."
        $warningSuppressed = Get-RegValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\FVE' -Name 'FVEComplianceOverride'
        Add-Result -Name 'BitLocker Suppress Other-Encryption Warning' -SettingRef 'BitLockerDisableWarningForOtherDiskEncryption' `
            -Expected 'Per org policy' -Actual $(if ($null -eq $warningSuppressed) {'NOT SET'} else {$warningSuppressed}) `
            -Pass $true -Informational `
            -Note "This suppresses a UI warning when third-party disk encryption is detected alongside BitLocker. Not a security control itself -- confirm against your org's intended value; no universal correct answer." `
            -Fix "Set per your org's documented Intune profile value."
    }
}
function Get-LoginBannerResults {
    $script:CurrentSource = 'Login Banner & Secure Attention Sequence'
    Write-Host ""
    $sysPolicyPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
    $expectedTitle = 'CONNECTIUM TECHNOLOGIES'
    $actualTitle = Get-RegValue -Path $sysPolicyPath -Name 'LegalNoticeCaption'
    $titlePass = ($actualTitle -eq $expectedTitle)
    Add-Result -Name 'Login Banner Title' -SettingRef 'LocalPoliciesSecurityOptions/InteractiveLogon_MessageTitleForUsersAttemptingToLogOn' `
        -Expected $expectedTitle -Actual $(if ($null -eq $actualTitle) {'NOT SET'} else {$actualTitle}) `
        -Status $(if ($titlePass) {'PASS'} else {'FAIL'}) `
        -Note "Login banner title does not match. NIST 3.1.9 requires a system use notification displayed before granting access." `
        -Fix "New-Item -Path '$sysPolicyPath' -Force | Out-Null; Set-ItemProperty -Path '$sysPolicyPath' -Name LegalNoticeCaption -Value '$expectedTitle' -Type String"
    $expectedText = 'This system is the property of Connectium Technologies LLC. Access to this system is restricted to authorized users only. All activity on this system is monitored and recorded. Unauthorized access is prohibited and may result in criminal prosecution. By logging in you acknowledge and agree to the Connectium Technologies Acceptable Use Policy (CT-POL-AUP-001).'
    $actualText = Get-RegValue -Path $sysPolicyPath -Name 'LegalNoticeText'
    $textPresent = -not (($null -eq $actualText) -or ($actualText -match '^\s*$'))
    $textMatchesExpected = ($actualText -eq $expectedText)
    $hasMonitoringNotice = $actualText -match '(?i)monitor'
    $hasAuthorizedUseOnly = $actualText -match '(?i)authorized user'
    $hasLegalConsequence = $actualText -match '(?i)(prosecut|criminal|penalt)'
    $hasNoPrivacyExpectation = $actualText -match '(?i)(no reasonable expectation of privacy|no expectation of privacy)'
    $missingElements = @()
    if (-not $hasMonitoringNotice) { $missingElements += 'monitoring notice' }
    if (-not $hasAuthorizedUseOnly) { $missingElements += 'authorized-use-only statement' }
    if (-not $hasLegalConsequence) { $missingElements += 'legal consequences statement' }
    if (-not $hasNoPrivacyExpectation) { $missingElements += 'explicit "no expectation of privacy" statement' }
    $textStatus = if (-not $textPresent) { 'FAIL' } elseif ($textMatchesExpected -and $missingElements.Count -eq 0) { 'PASS' } else { 'REVIEW' }
    $textNote = if (-not $textPresent) {
        "No login banner text configured. NIST 3.1.9 requires a system use notification before granting access."
    } elseif ($missingElements.Count -gt 0) {
        "Banner text is present but appears to be missing: $($missingElements -join ', '). NIST 3.1.9 doesn't mandate exact wording, but these elements are commonly expected by CMMC assessors on DoD/GCC High systems (aligned with CNSSI 1013 standard banner language). This needs a compliance/legal judgment call, not just a script's opinion -- flagging for your review rather than failing outright."
    } elseif (-not $textMatchesExpected) {
        "Configured text differs from the CSV's specified text, but contains the commonly-expected elements. Confirm this is intentional (e.g. updated policy number) and not configuration drift."
    } else {
        ''
    }
    $truncatedActual = if ($textPresent) {
        if ($actualText.Length -gt 60) { (($actualText[0..59] -join '')) + '...' } else { $actualText }
    } else { 'NOT SET' }
    Add-Result -Name 'Login Banner Text' -SettingRef 'LocalPoliciesSecurityOptions/InteractiveLogon_MessageTextForUsersAttemptingToLogOn' `
        -Expected '(configured, see CSV for full text)' -Actual $truncatedActual `
        -Status $textStatus -Note $textNote `
        -Fix "New-Item -Path '$sysPolicyPath' -Force | Out-Null; Set-ItemProperty -Path '$sysPolicyPath' -Name LegalNoticeText -Value '<full banner text>' -Type String   -- consider adding an explicit 'no reasonable expectation of privacy' statement if this system is subject to DoD/CNSSI 1013 banner requirements; confirm with your compliance lead."
    $actualCad = Get-RegValue -Path $sysPolicyPath -Name 'DisableCAD'
    $cadPass = ($actualCad -eq 0)
    Add-Result -Name 'Require Ctrl Alt Del' -SettingRef 'LocalPoliciesSecurityOptions/InteractiveLogon_DoNotRequireCTRLALTDEL' `
        -Expected '0 (Ctrl+Alt+Del required)' -Actual $(if ($null -eq $actualCad) {'NOT SET (default=0, required)'} else {$actualCad}) `
        -Status $(if ($cadPass -or $null -eq $actualCad) {'PASS'} else {'FAIL'}) `
        -Note "Ctrl+Alt+Del is not required before logon. NIST 3.1.10 -- the secure attention sequence (SAS) prevents credential-capture malware from spoofing the logon screen (a fake login prompt can't intercept keystrokes if the OS mediates via Ctrl+Alt+Del first)." `
        -Fix "Set-ItemProperty -Path '$sysPolicyPath' -Name DisableCAD -Value 0 -Type DWord"
}
function Get-SecurityHardeningResults {
    $script:CurrentSource = 'Security Hardening (Lockout/UAC/Guest/Privacy)'
    Write-Host ""
    $build = [int](Get-CimInstance Win32_OperatingSystem).BuildNumber
    $buildSupportsLockoutPolicy = ($build -ge 26100)
    $netAccountsRaw = net accounts 2>$null
    $lockoutThreshold = $null
    $lockoutDuration = $null
    $lockoutWindow = $null
    foreach ($line in $netAccountsRaw) {
        if ($line -match 'Lockout threshold:\s*(\d+|Never)') { $lockoutThreshold = $matches[1] }
        if ($line -match 'Lockout duration \(minutes\):\s*(\d+|Never)') { $lockoutDuration = $matches[1] }
        if ($line -match 'Lockout observation window \(minutes\):\s*(\d+|Never)') { $lockoutWindow = $matches[1] }
    }
    $lockoutThresholdInt = $lockoutThreshold -as [int]
    $lockoutDurationInt  = $lockoutDuration -as [int]
    $lockoutWindowInt    = $lockoutWindow -as [int]
    $lockoutMeetsMin = ($lockoutThresholdInt -ge 1) -and ($lockoutThresholdInt -le 5) -and ($lockoutDurationInt -ge 15) -and ($lockoutWindowInt -ge 15)
    $lockoutExceedsMin = $lockoutMeetsMin -and (($lockoutThresholdInt -lt 5) -or ($lockoutDurationInt -gt 15) -or ($lockoutWindowInt -gt 15))
    if (-not $buildSupportsLockoutPolicy) {
        Add-Result -Name 'Account Lockout Policy' -SettingRef 'DeviceLock/AccountLockoutPolicy' `
            -Expected 'Threshold 1-5, Duration>=15, Window>=15 (meets or exceeds NIST 3.1.8 minimum)' -Actual "Threshold=$lockoutThreshold, Duration=$lockoutDuration, Window=$lockoutWindow (OS build $build)" `
            -Status 'BUILD TOO OLD' `
            -Note "This OMA-URI requires Windows 11 24H2 / Server 2025 (build 26100) or later to actually take effect. This device is on build $build. The policy may be 'successfully' deployed in Intune while doing nothing locally -- this isn't a config error, it's a platform limitation." `
            -Fix "Upgrade to Windows 11 24H2 or later. Until then, configure account lockout via classic Local Security Policy / GPO instead (secpol.msc > Account Policies > Account Lockout Policy) as a stopgap on older builds."
    } elseif ($lockoutExceedsMin) {
        Add-Result -Name 'Account Lockout Policy' -SettingRef 'DeviceLock/AccountLockoutPolicy' `
            -Expected 'Threshold 1-5, Duration>=15, Window>=15 (meets or exceeds NIST 3.1.8 minimum)' -Actual "Threshold=$lockoutThreshold, Duration=$lockoutDuration, Window=$lockoutWindow" `
            -Status 'OTHER' `
            -Note "Approved organizational exception: configured policy is stricter than the NIST 3.1.8 baseline of 5 attempts / 15 min lockout / 15 min observation window (fewer allowed attempts and/or a longer lockout/observation period). This meets or exceeds the control's intent, so it is not treated as a deficiency." `
            -Fix ''
    } else {
        Add-Result -Name 'Account Lockout Policy' -SettingRef 'DeviceLock/AccountLockoutPolicy' `
            -Expected 'Threshold 1-5, Duration>=15, Window>=15 (meets or exceeds NIST 3.1.8 minimum)' -Actual "Threshold=$lockoutThreshold, Duration=$lockoutDuration, Window=$lockoutWindow" `
            -Status $(if ($lockoutMeetsMin) {'PASS'} else {'FAIL'}) `
            -Note "Account lockout policy does not meet or exceed NIST 3.1.8 (<=5 failed attempts, >=15 min lockout, >=15 min observation window). Without this, an attacker gets unlimited (or excessive) password guesses." `
            -Fix "net accounts /lockoutthreshold:5 /lockoutduration:15 /lockoutwindow:15"
    }
    $uacPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
    $adminApproval = Get-RegValue -Path $uacPath -Name 'EnableLUA'
    Add-Result -Name 'UAC Admin Approval Mode' -SettingRef 'LocalPoliciesSecurityOptions/UserAccountControl_RunAllAdministratorsInAdminApprovalMode' `
        -Expected '1' -Actual $(if ($null -eq $adminApproval) {'NOT SET (default=1)'} else {$adminApproval}) `
        -Status $(if (($adminApproval -eq 1) -or ($null -eq $adminApproval)) {'PASS'} else {'FAIL'}) `
        -Note "Admin Approval Mode is disabled. NIST 3.1.6 -- privileged accounts should not operate with full admin rights by default; UAC forces an explicit elevation step." `
        -Fix "Set-ItemProperty -Path '$uacPath' -Name EnableLUA -Value 1 -Type DWord; reboot required"
    $secureDesktop = Get-RegValue -Path $uacPath -Name 'PromptOnSecureDesktop'
    Add-Result -Name 'UAC Secure Desktop' -SettingRef 'LocalPoliciesSecurityOptions/UserAccountControl_SwitchToTheSecureDesktopWhenPromptingForElevation' `
        -Expected '1' -Actual $(if ($null -eq $secureDesktop) {'NOT SET (default=1)'} else {$secureDesktop}) `
        -Status $(if (($secureDesktop -eq 1) -or ($null -eq $secureDesktop)) {'PASS'} else {'FAIL'}) `
        -Note "UAC elevation prompts are not shown on the secure desktop. NIST 3.1.7 -- without this, malware can spoof or interact with the elevation dialog since it runs in the normal (compromisable) user session." `
        -Fix "Set-ItemProperty -Path '$uacPath' -Name PromptOnSecureDesktop -Value 1 -Type DWord"
    try {
        $guest = Get-LocalUser -Name 'Guest' -ErrorAction Stop
        $guestDisabled = -not $guest.Enabled
        Add-Result -Name 'Disable Guest Account' -SettingRef 'LocalPoliciesSecurityOptions/Accounts_EnableGuestAccountStatus' `
            -Expected 'Disabled' -Actual $(if ($guest.Enabled) {'Enabled'} else {'Disabled'}) `
            -Status $(if ($guestDisabled) {'PASS'} else {'FAIL'}) `
            -Note "The built-in Guest account is enabled. NIST 3.1.1 -- unauthenticated/shared access via a well-known default account is a basic access-control gap." `
            -Fix "Disable-LocalUser -Name 'Guest'"
    } catch {
        Add-Result -Name 'Disable Guest Account' -SettingRef 'LocalPoliciesSecurityOptions/Accounts_EnableGuestAccountStatus' `
            -Expected 'Disabled' -Actual 'Guest account not found' -Status 'PASS' `
            -Note '' -Fix ''
    }
    $appPrivacyPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy'
    $cameraVal = Get-RegValue -Path $appPrivacyPath -Name 'LetAppsAccessCamera'
    $cameraOk = ($cameraVal -eq 0)
    Add-Result -Name 'Camera User Consent' -SettingRef 'Privacy/LetAppsAccessCamera' `
        -Expected '0 (User in control -- CSV literal value of 1 means Force Allow, a data-entry error)' -Actual $(if ($null -eq $cameraVal) {'NOT SET (default=0, User in control)'} else {$cameraVal}) `
        -Status $(if (($cameraOk) -or ($null -eq $cameraVal)) {'PASS'} else {'FAIL'}) `
        -Note "IMPORTANT: if this shows 1, every app has FORCED camera access with no user prompt and no ability to deny -- this is worse than doing nothing, not just non-compliant. The source CSV's value (1) is Microsoft's 'Force Allow' enum value, not 'user control' as the CSV describes it. This needs to be corrected in the source Intune profile, not just this device, or every enrolled device has this exposure." `
        -Fix "Push corrected value via Intune (OMA-URI Privacy/LetAppsAccessCamera = 0), or locally: New-Item -Path '$appPrivacyPath' -Force | Out-Null; Set-ItemProperty -Path '$appPrivacyPath' -Name LetAppsAccessCamera -Value 0 -Type DWord"
    $micVal = Get-RegValue -Path $appPrivacyPath -Name 'LetAppsAccessMicrophone'
    $micOk = ($micVal -eq 0)
    Add-Result -Name 'Microphone User Consent' -SettingRef 'Privacy/LetAppsAccessMicrophone' `
        -Expected '0 (User in control -- CSV literal value of 1 means Force Allow, a data-entry error)' -Actual $(if ($null -eq $micVal) {'NOT SET (default=0, User in control)'} else {$micVal}) `
        -Status $(if (($micOk) -or ($null -eq $micVal)) {'PASS'} else {'FAIL'}) `
        -Note "Same issue as Camera above: if this shows 1, every app has FORCED microphone access with no prompt or ability to deny. Correct the source Intune profile." `
        -Fix "Push corrected value via Intune (OMA-URI Privacy/LetAppsAccessMicrophone = 0), or locally: New-Item -Path '$appPrivacyPath' -Force | Out-Null; Set-ItemProperty -Path '$appPrivacyPath' -Name LetAppsAccessMicrophone -Value 0 -Type DWord"
    try {
        $admin = Get-LocalUser -Name 'Administrator' -ErrorAction Stop
        $adminEnabled = $admin.Enabled
        $lapsConfigured = (Test-Path 'HKLM:\SOFTWARE\Microsoft\Policies\LAPS') -or (Get-RegValue -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\LAPS' -Name 'BackupDirectory')
        $note = if ($adminEnabled -and -not $lapsConfigured) {
            "Built-in Administrator is enabled (per design, for LAPS management), but no LAPS policy configuration was detected on this device. An enabled built-in admin account WITHOUT active LAPS password rotation is a significant risk -- a well-known account name with a static, potentially never-rotated password. Confirm LAPS is actually deployed and managing this account before treating this as compliant."
        } elseif ($adminEnabled -and $lapsConfigured) {
            ''
        } else {
            "Built-in Administrator is disabled. The CSV specifies this should be enabled specifically so LAPS can manage/rotate its password -- confirm this is intentional for your environment before changing it."
        }
        Add-Result -Name 'Enable Built-in Administrator Account' -SettingRef 'LocalPoliciesSecurityOptions/Accounts_EnableAdministratorAccountStatus' `
            -Expected '1 (Enabled, paired with active LAPS management)' -Actual $(if ($adminEnabled) {"Enabled (LAPS configured: $lapsConfigured)"} else {'Disabled'}) `
            -Status $(if ($adminEnabled -and $lapsConfigured) {'PASS'} elseif ($adminEnabled -and -not $lapsConfigured) {'REVIEW'} else {'FAIL'}) `
            -Note $note `
            -Fix "Enable-LocalUser -Name 'Administrator'; then confirm Windows LAPS is deployed and actively rotating this account's password (Get-LapsDiagnostics, if the LAPS module is installed)."
    } catch {
        Add-Result -Name 'Enable Built-in Administrator Account' -SettingRef 'LocalPoliciesSecurityOptions/Accounts_EnableAdministratorAccountStatus' `
            -Expected '1' -Actual 'Administrator account not found' -Status 'FAIL' `
            -Note 'Could not query the built-in Administrator account.' -Fix ''
    }
}
function Get-GeneralHardeningResults {
    $script:CurrentSource = 'General Hardening (AutoPlay/RDS/EventLog/BitLocker-Removable/Edge/Firewall)'
    Write-Host ""
    $explorerPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer'
    $nonVolume = Get-RegValue -Path $explorerPath -Name 'NoAutoplayfornonVolume'
    Add-Result -Name 'Disallow Autoplay for non-volume devices' -SettingRef 'Administrative Templates\AutoPlay Policies' `
        -Expected '1' -Actual $(if ($null -eq $nonVolume) {'NOT SET'} else {$nonVolume}) -Status $(if ($nonVolume -eq 1) {'PASS'} else {'FAIL'}) `
        -Note "Autoplay for MTP devices (phones, cameras) is not disabled. NIST 3.4.8/3.8.7 -- autoplay on non-volume devices is a malware delivery vector similar to removable-media autorun." `
        -Fix "New-Item -Path '$explorerPath' -Force | Out-Null; Set-ItemProperty -Path '$explorerPath' -Name NoAutoplayfornonVolume -Value 1 -Type DWord"
    $noAutorun = Get-RegValue -Path $explorerPath -Name 'NoAutorun'
    Add-Result -Name 'Default AutoRun Behavior' -SettingRef 'Administrative Templates\AutoPlay Policies' `
        -Expected '1 (Do not execute any autorun commands)' -Actual $(if ($null -eq $noAutorun) {'NOT SET'} else {$noAutorun}) -Status $(if ($noAutorun -eq 1) {'PASS'} else {'FAIL'}) `
        -Note "AutoRun commands (autorun.inf) can still execute automatically. NIST 3.4.8/3.14.2 -- this is one of the most common USB-malware delivery mechanisms; disabling it is basic hygiene." `
        -Fix "New-Item -Path '$explorerPath' -Force | Out-Null; Set-ItemProperty -Path '$explorerPath' -Name NoAutorun -Value 1 -Type DWord"
    $driveTypeAutoRun = Get-RegValue -Path $explorerPath -Name 'NoDriveTypeAutoRun'
    $autoplayAllDrivesOk = ($driveTypeAutoRun -eq 255)
    Add-Result -Name 'Turn off Autoplay (All drives)' -SettingRef 'Administrative Templates\AutoPlay Policies' `
        -Expected '255 (0xFF, All drives)' -Actual $(if ($null -eq $driveTypeAutoRun) {'NOT SET'} else {$driveTypeAutoRun}) -Status $(if ($autoplayAllDrivesOk) {'PASS'} else {'FAIL'}) `
        -Note "Autoplay is not turned off for all drive types. Same rationale as above -- consistent policy across removable, fixed, network, and unknown drive types closes this attack surface entirely rather than partially." `
        -Fix "New-Item -Path '$explorerPath' -Force | Out-Null; Set-ItemProperty -Path '$explorerPath' -Name NoDriveTypeAutoRun -Value 255 -Type DWord"
    $ntpEnabled = Get-RegValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\TimeProviders\NtpClient' -Name 'Enabled'
    Add-Result -Name 'Enable Windows NTP Client' -SettingRef 'Windows Time Service > Time Providers' `
        -Expected '1' -Actual $(if ($null -eq $ntpEnabled) {'NOT SET'} else {$ntpEnabled}) -Status $(if ($ntpEnabled -eq 1) {'PASS'} else {'FAIL'}) `
        -Note "NTP client is not enabled. NIST 3.3.7 -- accurate, synchronized time is required for meaningful audit log correlation." `
        -Fix "Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\TimeProviders\NtpClient' -Name Enabled -Value 1 -Type DWord; Restart-Service W32Time"
    $tsPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services'
    $oneHourMs = 3600000
    $maxConn = Get-RegValue -Path $tsPath -Name 'MaxConnectionTime'
    Add-Result -Name 'Active RDS Session Time Limit' -SettingRef 'RDS > Session Host > Session Time Limits' `
        -Expected "$oneHourMs ms (1 hour)" -Actual $(if ($null -eq $maxConn) {'NOT SET'} else {"$maxConn ms"}) -Status $(if ($maxConn -eq $oneHourMs) {'PASS'} else {'FAIL'}) `
        -Note "Active RDS session time limit is not set to 1 hour. NIST 3.1.11 -- session termination after a defined period reduces the window an attacker has if a session is hijacked or left unattended." `
        -Fix "New-Item -Path '$tsPath' -Force | Out-Null; Set-ItemProperty -Path '$tsPath' -Name MaxConnectionTime -Value $oneHourMs -Type DWord"
    $maxDisc = Get-RegValue -Path $tsPath -Name 'MaxDisconnectionTime'
    Add-Result -Name 'Disconnected RDS Session Time Limit' -SettingRef 'RDS > Session Host > Session Time Limits' `
        -Expected "$oneHourMs ms (1 hour)" -Actual $(if ($null -eq $maxDisc) {'NOT SET'} else {"$maxDisc ms"}) -Status $(if ($maxDisc -eq $oneHourMs) {'PASS'} else {'FAIL'}) `
        -Note "Disconnected RDS sessions are not force-terminated after 1 hour. NIST 3.1.11 -- a disconnected-but-not-logged-off session still holds resources/state and is a lingering access path." `
        -Fix "New-Item -Path '$tsPath' -Force | Out-Null; Set-ItemProperty -Path '$tsPath' -Name MaxDisconnectionTime -Value $oneHourMs -Type DWord"
    $encLevel = Get-RegValue -Path $tsPath -Name 'MinEncryptionLevel'
    Add-Result -Name 'RDS Encryption Level' -SettingRef 'RDS > Session Host > Security' `
        -Expected '3 (High)' -Actual $(if ($null -eq $encLevel) {'NOT SET'} else {$encLevel}) -Status $(if ($encLevel -eq 3) {'PASS'} else {'FAIL'}) `
        -Note "RDP encryption level is not set to High. NIST 3.13.8/3.13.11 -- weaker encryption levels permit downgraded, more easily intercepted RDP sessions." `
        -Fix "New-Item -Path '$tsPath' -Force | Out-Null; Set-ItemProperty -Path '$tsPath' -Name MinEncryptionLevel -Value 3 -Type DWord"
    $secureRpc = Get-RegValue -Path $tsPath -Name 'fEncryptRPCTraffic'
    Add-Result -Name 'Require Secure RPC Communication' -SettingRef 'RDS > Session Host > Security' `
        -Expected '1' -Actual $(if ($null -eq $secureRpc) {'NOT SET'} else {$secureRpc}) -Status $(if ($secureRpc -eq 1) {'PASS'} else {'FAIL'}) `
        -Note "RDS RPC traffic is not required to be encrypted. NIST 3.13.8 -- protects the RPC channel underlying RDP session setup from interception/tampering." `
        -Fix "New-Item -Path '$tsPath' -Force | Out-Null; Set-ItemProperty -Path '$tsPath' -Name fEncryptRPCTraffic -Value 1 -Type DWord"
    $secLayer = Get-RegValue -Path $tsPath -Name 'SecurityLayer'
    Add-Result -Name 'RDP Security Layer' -SettingRef 'RDS > Session Host > Security' `
        -Expected '1 (Negotiate)' -Actual $(if ($null -eq $secLayer) {'NOT SET'} else {$secLayer}) -Status $(if ($secLayer -eq 1) {'PASS'} else {'FAIL'}) `
        -Note "RDP security layer is not set to Negotiate. Note: your organization configured 'Negotiate' (value 1), which is Microsoft's default and enforces the strongest method the client supports -- CIS/DISA STIG baselines more commonly recommend the stricter 'SSL/TLS-only' option (value 2), which refuses the connection outright if TLS isn't supported instead of silently falling back to native RDP encryption. Confirm 'Negotiate' vs 'SSL' was a deliberate choice for your environment." `
        -Fix "New-Item -Path '$tsPath' -Force | Out-Null; Set-ItemProperty -Path '$tsPath' -Name SecurityLayer -Value 1 -Type DWord   (use -Value 2 instead for the stricter SSL/TLS-only baseline some assessors expect)"
    $eventLogSizes = @{
        'System'      = 51200
        'Security'    = 102400
        'Application' = 32768
    }
    foreach ($channel in $eventLogSizes.Keys) {
        $logPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\EventLog\$channel"
        $expectedSize = $eventLogSizes[$channel]
        $actualSize = Get-RegValue -Path $logPath -Name 'MaxSize'
        Add-Result -Name "$channel Event Log Max Size" -SettingRef "Event Log Service > $channel" `
            -Expected "$expectedSize KB" -Actual $(if ($null -eq $actualSize) {'NOT SET'} else {"$actualSize KB"}) `
            -Status $(if ($actualSize -eq $expectedSize) {'PASS'} else {'FAIL'}) `
            -Note "$channel event log max size does not match the configured value. NIST 3.3.1 (AU-4 audit storage capacity) -- an undersized log rotates/overwrites before incidents can be investigated, silently destroying evidence." `
            -Fix "New-Item -Path '$logPath' -Force | Out-Null; Set-ItemProperty -Path '$logPath' -Name MaxSize -Value $expectedSize -Type DWord"
    }
    $fvePath = 'HKLM:\SOFTWARE\Policies\Microsoft\FVE'
    $rdvConfigure = Get-RegValue -Path $fvePath -Name 'RDVConfigureBDE'
    Add-Result -Name 'Control use of BitLocker on removable drives' -SettingRef 'BitLocker > Removable Data Drives' `
        -Expected '1 (Enabled)' -Actual $(if ($null -eq $rdvConfigure) {'NOT SET'} else {$rdvConfigure}) -Status $(if ($rdvConfigure -eq 1) {'PASS'} else {'FAIL'}) `
        -Note "BitLocker removable-drive policy is not enabled. NIST 3.8.6/3.1.19 -- without this, removable media policy for CUI protection isn't enforced at all." `
        -Fix "New-Item -Path '$fvePath' -Force | Out-Null; Set-ItemProperty -Path '$fvePath' -Name RDVConfigureBDE -Value 1 -Type DWord"
    $rdvAllow = Get-RegValue -Path $fvePath -Name 'RDVAllowBDE'
    Add-Result -Name 'Allow users to apply BitLocker on removable drives' -SettingRef 'BitLocker > Removable Data Drives' `
        -Expected '1 (True)' -Actual $(if ($null -eq $rdvAllow) {'NOT SET'} else {$rdvAllow}) -Status $(if ($rdvAllow -eq 1) {'PASS'} else {'FAIL'}) `
        -Note "Users are not permitted to apply BitLocker protection to removable drives themselves." `
        -Fix "New-Item -Path '$fvePath' -Force | Out-Null; Set-ItemProperty -Path '$fvePath' -Name RDVAllowBDE -Value 1 -Type DWord"
    $rdvDisable = Get-RegValue -Path $fvePath -Name 'RDVDisableBDE'
    Add-Result -Name 'Allow users to suspend/decrypt BitLocker on removable drives' -SettingRef 'BitLocker > Removable Data Drives' `
        -Expected '1 (True)' -Actual $(if ($null -eq $rdvDisable) {'NOT SET'} else {$rdvDisable}) -Status $(if ($rdvDisable -eq 1) {'PASS'} else {'FAIL'}) `
        -Note "Users are not permitted to suspend/decrypt BitLocker on removable drives." `
        -Fix "New-Item -Path '$fvePath' -Force | Out-Null; Set-ItemProperty -Path '$fvePath' -Name RDVDisableBDE -Value 1 -Type DWord"
    $rdvDenyWrite = Get-RegValue -Path $fvePath -Name 'RDVDenyWriteAccess'
    Add-Result -Name 'Deny write access to unprotected removable drives' -SettingRef 'BitLocker > Removable Data Drives' `
        -Expected '1 (Enabled)' -Actual $(if ($null -eq $rdvDenyWrite) {'NOT SET'} else {$rdvDenyWrite}) -Status $(if ($rdvDenyWrite -eq 1) {'PASS'} else {'FAIL'}) `
        -Note "Removable drives without BitLocker protection can still be written to. NIST 3.8.6 -- this is the control that actually enforces encryption-before-write for CUI leaving the device on removable media; without it, the other BitLocker settings above are advisory only." `
        -Fix "New-Item -Path '$fvePath' -Force | Out-Null; Set-ItemProperty -Path '$fvePath' -Name RDVDenyWriteAccess -Value 1 -Type DWord"
    $rdvCrossOrg = Get-RegValue -Path $fvePath -Name 'RDVDenyCrossOrg'
    Add-Result -Name 'Deny write access to devices from another organization' -SettingRef 'BitLocker > Removable Data Drives' `
        -Expected '1 (True)' -Actual $(if ($null -eq $rdvCrossOrg) {'NOT SET'} else {$rdvCrossOrg}) -Status $(if ($rdvCrossOrg -eq 1) {'PASS'} elseif ($null -eq $rdvCrossOrg) {'REVIEW'} else {'FAIL'}) `
        -Note "LOWER CONFIDENCE MAPPING: this specific sub-option's registry value name is less consistently documented than the other BitLocker settings above. If this shows NOT SET/REVIEW rather than a clear PASS/FAIL, verify manually via: rsop.msc > Computer Configuration > Administrative Templates > Windows Components > BitLocker Drive Encryption > Removable Data Drives, rather than trusting this check alone." `
        -Fix "Verify the exact registry value via rsop.msc first, then: Set-ItemProperty -Path '$fvePath' -Name RDVDenyCrossOrg -Value 1 -Type DWord"
    $fipsVal = Get-RegValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\FipsAlgorithmPolicy' -Name 'Enabled'
    Add-Result -Name 'Allow Fips Algorithm Policy' -SettingRef 'Cryptography' `
        -Expected '1 (Allow)' -Actual $(if ($null -eq $fipsVal) {'NOT SET'} else {$fipsVal}) -Status $(if ($fipsVal -eq 1) {'PASS'} else {'FAIL'}) `
        -Note "FIPS 140 validated cryptography is not enforced. NIST 3.13.11. (Same control verified earlier in this session via Set-CompliantFIPS.ps1.)" `
        -Fix "Re-run Set-CompliantFIPS.ps1 from earlier in this session."
    $edgePath = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'
    $syncDisabled = Get-RegValue -Path $edgePath -Name 'SyncDisabled'
    Add-Result -Name 'Do Not Sync Browser Settings' -SettingRef 'Experience' `
        -Expected '1 (Sync disabled)' -Actual $(if ($null -eq $syncDisabled) {'NOT SET'} else {$syncDisabled}) -Status $(if ($syncDisabled -eq 1) {'PASS'} else {'FAIL'}) `
        -Note "Browser settings sync is not disabled. Not tied to a single specific NIST control number, but reduces the risk of CUI-adjacent data (saved passwords, browsing history, autofill) leaving the managed device boundary via a personal Microsoft account sync." `
        -Fix "New-Item -Path '$edgePath' -Force | Out-Null; Set-ItemProperty -Path '$edgePath' -Name SyncDisabled -Value 1 -Type DWord"
    foreach ($fwProfile in @('Domain','Private','Public')) {
        $fw = Get-NetFirewallProfile -Profile $fwProfile -ErrorAction SilentlyContinue
        Add-Result -Name "Enable $fwProfile Network Firewall" -SettingRef 'Firewall' `
            -Expected 'True' -Actual $fw.Enabled -Status $(if ($fw.Enabled -eq $true) {'PASS'} else {'FAIL'}) `
            -Note "$fwProfile firewall is disabled. NIST 3.13.1." `
            -Fix "Set-NetFirewallProfile -Profile $fwProfile -Enabled True"
        Add-Result -Name "Enable Log Dropped Packets ($fwProfile)" -SettingRef 'Firewall' `
            -Expected 'True' -Actual $fw.LogBlocked -Status $(if ($fw.LogBlocked -eq 'True') {'PASS'} else {'FAIL'}) `
            -Note "$fwProfile firewall is not logging dropped packets. NIST 3.3.1 -- needed to investigate blocked connection attempts." `
            -Fix "Set-NetFirewallProfile -Profile $fwProfile -LogBlocked True"
    }
    $popupSetting = Get-RegValue -Path $edgePath -Name 'DefaultPopupsSetting'
    Add-Result -Name 'Default Pop-up Window Setting' -SettingRef 'Microsoft Edge > Content settings' `
        -Expected '2 (Block)' -Actual $(if ($null -eq $popupSetting) {'NOT SET'} else {$popupSetting}) -Status $(if ($popupSetting -eq 2) {'PASS'} else {'FAIL'}) `
        -Note "Edge does not block popups by default. NIST 3.14.2 -- popups are a common malvertising/drive-by-download and phishing vector." `
        -Fix "New-Item -Path '$edgePath' -Force | Out-Null; Set-ItemProperty -Path '$edgePath' -Name DefaultPopupsSetting -Value 2 -Type DWord"
    $wifiSense = Get-RegValue -Path 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Wifi' -Name 'AllowAutoConnectToWiFiSenseHotspots'
    Add-Result -Name 'Allow Auto Connect To Wi-Fi Sense Hotspots' -SettingRef 'Wi-Fi Settings' `
        -Expected '0 (Block)' -Actual $(if ($null -eq $wifiSense) {'NOT SET (native MDM policy -- expected if not Intune-enrolled)'} else {$wifiSense}) `
        -Status $(if (($wifiSense -eq 0) -or ($null -eq $wifiSense)) {'PASS'} else {'FAIL'}) `
        -Note "Auto-connect to open/suggested hotspots is allowed. NIST 3.1.16 -- rogue-AP/MitM exposure." `
        -Fix "Push via Intune (OMA-URI Wifi/AllowAutoConnectToWifiSenseHotspots = 0). Native MDM-only policy, no local GPO equivalent."
}
function Get-LAPSResults {
    $script:CurrentSource = 'Windows LAPS'
    Write-Host ""
    $cspRoot = 'HKLM:\SOFTWARE\Microsoft\Policies\LAPS'
    $gpoRoot = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\LAPS'
    function Test-RootHasAnySetting {
        param([string]$Path)
        if (-not (Test-Path $Path)) { return $false }
        $props = Get-ItemProperty -Path $Path -ErrorAction SilentlyContinue
        if (-not $props) { return $false }
        $names = $props.PSObject.Properties.Name | Where-Object { $_ -notlike 'PS*' }
        return ($names.Count -gt 0)
    }
    $activeRoot = $null
    $activeRootLabel = $null
    if (Test-RootHasAnySetting -Path $cspRoot) {
        $activeRoot = $cspRoot
        $activeRootLabel = 'LAPS CSP (Intune) -- HKLM\SOFTWARE\Microsoft\Policies\LAPS'
    } elseif (Test-RootHasAnySetting -Path $gpoRoot) {
        $activeRoot = $gpoRoot
        $activeRootLabel = 'LAPS Group Policy (on-prem) -- HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\LAPS'
    } else {
        Add-Result -Name 'Backup Directory' -SettingRef 'BackupDirectory' `
            -Expected '1 (Microsoft Entra ID only)' -Actual 'NOT CONFIGURED' -Pass $false `
            -Note "No Windows LAPS policy settings found under either the CSP root ($cspRoot) or the GPO root ($gpoRoot). LAPS does not appear to be configured on this device at all -- BackupDirectory defaults to 0 (Disabled), meaning no password backup or rotation is occurring. NIST 3.5.7/3.1.5 -- unique, centrally-escrowed, rotated local admin credentials." `
            -Fix "Deploy the Windows LAPS policy via Intune (LAPS CSP) or GPO -- see the other LAPS checks in this report for the specific settings expected once deployed."
        return
    }
    Write-Host "Active LAPS policy root: $activeRootLabel" -ForegroundColor DarkGray
    Write-Host ""
    function Get-RegValue {
        param([string]$Name)
        try { return (Get-ItemProperty -Path $activeRoot -Name $Name -ErrorAction Stop).$Name }
        catch { return $null }
    }
    $backupDir = Get-RegValue -Name 'BackupDirectory'
    $backupDirText = switch ($backupDir) {
        0 { 'Disabled' }
        1 { 'Microsoft Entra ID only' }
        2 { 'Windows Server Active Directory only' }
        default { if ($null -eq $backupDir) { 'NOT SET (defaults to Disabled)' } else { "Unknown ($backupDir)" } }
    }
    Add-Result -Name 'Backup Directory' -Expected '1 (Microsoft Entra ID only)' -Actual $backupDirText -Pass ($backupDir -eq 1) `
        -Note "Passwords are not being backed up to Microsoft Entra ID as specified. If BackupDirectory is 0/unset, NO password backup or rotation happens at all -- this is the single most critical LAPS setting; every other setting below is meaningless if this is wrong. NIST 3.5.7/3.1.5 -- unique, centrally-escrowed, rotated local admin credentials." `
        -Fix "Correct via Intune (LAPS policy > Backup Directory = 'Back up the password to Microsoft Entra ID only'), or locally: Set-ItemProperty -Path '$activeRoot' -Name BackupDirectory -Value 1 -Type DWord"
    $ageDays = Get-RegValue -Name 'PasswordAgeDays'
    Add-Result -Name 'Password Age Days' -Expected '30' -Actual $(if ($null -eq $ageDays) {'NOT SET (default=30)'} else {$ageDays}) -Pass (($ageDays -eq 30) -or ($null -eq $ageDays)) `
        -Note "Password rotation interval does not match the configured 30-day value. NIST 3.5.6/3.5.9 -- bounds the window a compromised local admin credential remains valid." `
        -Fix "Set-ItemProperty -Path '$activeRoot' -Name PasswordAgeDays -Value 30 -Type DWord"
    $complexity = Get-RegValue -Name 'PasswordComplexity'
    $complexityText = switch ($complexity) {
        1 { 'Large letters' }
        2 { 'Large letters + small letters' }
        3 { 'Large letters + small letters + numbers' }
        4 { 'Large letters + small letters + numbers + special characters' }
        5 { 'Large letters + small letters + numbers + special characters (improved readability)' }
        6 { 'Passphrase (long words)' }
        7 { 'Passphrase (short words)' }
        8 { 'Passphrase (short words with unique prefixes)' }
        default { if ($null -eq $complexity) { 'NOT SET (default=4)' } else { "Unknown ($complexity)" } }
    }
    Add-Result -Name 'Password Complexity' -Expected '5 (improved readability variant)' -Actual $complexityText -Pass ($complexity -eq 5) `
        -Note "Password complexity does not match the configured value 5. NIST 3.5.7 -- complexity requirement for generated credentials. Note: value 5 requires Windows 11 24H2 / Server 2025 or later; on older builds Windows LAPS silently falls back to the default (4), which is still strong but not the specific readability-optimized variant configured here." `
        -Fix "Set-ItemProperty -Path '$activeRoot' -Name PasswordComplexity -Value 5 -Type DWord   (verify OS build supports value 5 -- Windows 11 24H2/Server 2025+)"
    $pwLength = Get-RegValue -Name 'PasswordLength'
    Add-Result -Name 'Password Length' -Expected '14' -Actual $(if ($null -eq $pwLength) {'NOT SET (default=14)'} else {$pwLength}) -Pass (($pwLength -eq 14) -or ($null -eq $pwLength)) `
        -Note "Password length does not match the configured 14-character value. NIST 3.5.7 -- longer generated passwords increase brute-force resistance." `
        -Fix "Set-ItemProperty -Path '$activeRoot' -Name PasswordLength -Value 14 -Type DWord"
    $postAuthAction = Get-RegValue -Name 'PostAuthenticationActions'
    $postAuthActionText = switch ($postAuthAction) {
        1 { 'Reset password' }
        3 { 'Reset password and sign out' }
        5 { 'Reset password and reboot' }
        11 { 'Reset password, sign out, and terminate remaining processes' }
        default { if ($null -eq $postAuthAction) { 'NOT SET (default=3)' } else { "Unknown ($postAuthAction)" } }
    }
    Add-Result -Name 'Post Authentication Actions' -Expected '3 (Reset password and sign out)' -Actual $postAuthActionText -Pass (($postAuthAction -eq 3) -or ($null -eq $postAuthAction)) `
        -Note "Post-authentication action does not match. NIST 3.1.11/AC-12 (session termination) -- ensures the LAPS password is invalidated and any interactive session using it is force-ended after use, rather than remaining valid indefinitely." `
        -Fix "Set-ItemProperty -Path '$activeRoot' -Name PostAuthenticationActions -Value 3 -Type DWord"
    $resetDelay = Get-RegValue -Name 'PostAuthenticationResetDelay'
    Add-Result -Name 'Post Authentication Reset Delay' -Expected '1 (hour)' -Actual $(if ($null -eq $resetDelay) {'NOT SET (default=24)'} else {$resetDelay}) -Pass ($resetDelay -eq 1) `
        -Note "Grace period before the post-authentication action fires does not match the configured 1-hour value (default is 24 hours -- a full day the password remains valid after use, if this hasn't been explicitly tightened). Shorter delay reduces the window an admin session/credential stays live after checkout." `
        -Fix "Set-ItemProperty -Path '$activeRoot' -Name PostAuthenticationResetDelay -Value 1 -Type DWord"
}
function Get-ASRRulesResults {
    $script:CurrentSource = 'Attack Surface Reduction Rules (19 rules) + Controlled Folder Access'
    Write-Host ""
    $asrRules = [ordered]@{
        'Block execution of potentially obfuscated scripts'                                                      = '5beb7efe-fd9a-4556-801d-275e5ffc04cc'
        'Block Office communication application from creating child processes'                                   = '26190899-1602-49e8-8b27-eb1d0a1ce869'
        'Block all Office applications from creating child processes'                                             = 'd4f940ab-401b-4efc-aadc-ad5f3c50688a'
        'Block Win32 API calls from Office macros'                                                                = '92e97fa1-2edf-4476-bdd6-9dd0b4dddc7b'
        'Block executable files from running unless they meet a prevalence, age, or trusted list criterion'       = '01443614-cd74-433a-b99e-2ecdc07bfc25'
        'Block untrusted and unsigned processes that run from USB'                                                = 'b2b3f03d-6a65-4f7b-a9c7-1c7ef74a9ba4'
        'Block JavaScript or VBScript from launching downloaded executable content'                               = 'd3e037e1-3eb8-44c8-a917-57927947596d'
        'Block Webshell creation for Servers'                                                                      = 'a8f5898e-1dc8-49a9-9878-85004b8a61e6'
        'Block Adobe Reader from creating child processes'                                                        = '7674ba52-37eb-4a4f-a9a1-f0f9a1619a2c'
        'Block credential stealing from the Windows local security authority subsystem'                           = '9e6c4e1f-7d60-472f-ba1a-a39ef669e4b2'
        'Block abuse of exploited vulnerable signed drivers'                                                       = '56a863a9-875e-4185-98a7-b882c64b5ce5'
        'Block persistence through WMI event subscription'                                                        = 'e6db77e5-3df2-4cf1-b95a-636979351e5b'
        'Block use of copied or impersonated system tools'                                                        = 'c0033c00-d16d-4114-a5a0-dc9b3a7d2ceb'
        'Block Office applications from injecting code into other processes'                                      = '75668c1f-73b5-4cf0-bb93-3ecf5cb7cc84'
        'Use advanced protection against ransomware'                                                               = 'c1db55ab-c21a-4637-bb3f-a12568109d35'
        'Block process creations originating from PSExec and WMI commands'                                        = 'd1e49aac-8f56-4280-b9ba-993a6d77406c'
        'Block rebooting machine in Safe Mode'                                                                     = '33ddedf1-c6e0-47cb-833e-de6133960387'
        'Block executable content from email client and webmail'                                                  = 'be9ba2d9-53ea-4cdc-84e5-9b1eeee46550'
        'Block Office applications from creating executable content'                                               = '3b576869-a4ec-4529-8536-b80a7769e899'
    }
    $mp = Get-MpPreference -ErrorAction SilentlyContinue
    if (-not $mp) {
        Write-Error "Get-MpPreference failed. Microsoft Defender Antivirus may be disabled or replaced by a third-party AV -- ASR rules require Defender AV as the active engine. Aborting."
        return
    }
    $configuredIds = $mp.AttackSurfaceReductionRules_Ids
    $configuredActions = $mp.AttackSurfaceReductionRules_Actions
    $ruleState = @{}
    if ($configuredIds) {
        for ($i = 0; $i -lt $configuredIds.Count; $i++) {
            $ruleState[$configuredIds[$i]] = $configuredActions[$i]
        }
    }
    function Convert-ActionToText {
        param($Action)
        switch ($Action) {
            0 { 'Disabled' }
            1 { 'Block' }
            2 { 'Audit' }
            6 { 'Warn' }
            $null { 'Not configured (= Disabled)' }
            default { "Unknown ($Action)" }
        }
    }
    foreach ($ruleName in $asrRules.Keys) {
        $guid = $asrRules[$ruleName]
        $action = $ruleState[$guid]
        $pass = ($action -eq 1)
        Add-Result -Name $ruleName -OmaUri $guid -Expected 'Block (1)' -Actual (Convert-ActionToText $action) -Pass $pass `
            -Note "This ASR rule is not in Block mode. Each rule maps to a specific MITRE ATT&CK technique (e.g. credential dumping, process injection, LOLBin abuse) and supports NIST 3.14.2 (malicious code protection). A rule left in Audit mode logs the attack technique but doesn't stop it." `
            -Fix "Add-MpPreference -AttackSurfaceReductionRules_Ids $guid -AttackSurfaceReductionRules_Actions Enabled"
    }
    $cfaValue = $mp.EnableControlledFolderAccess
    $cfaText = switch ($cfaValue) {
        0 { 'Disabled' }
        1 { 'Enabled (Block)' }
        2 { 'Audit Mode' }
        3 { 'Block Disk Modification Only' }
        4 { 'Audit Disk Modification Only' }
        default { "Unknown ($cfaValue)" }
    }
    $cfaPass = ($cfaValue -eq 1)
    Add-Result -Name 'Enable Controlled Folder Access' -OmaUri 'N/A (separate Defender feature, not an ASR rule)' -Expected 'Enabled (1)' -Actual $cfaText -Pass $cfaPass `
        -Note "Controlled Folder Access is not in Block mode. NIST 3.13.11/3.14.2-adjacent -- this is Defender's primary anti-ransomware control, blocking unauthorized processes from writing to protected folders (Documents, Desktop, etc.) regardless of whether the process is otherwise flagged as malicious." `
        -Fix "Set-MpPreference -EnableControlledFolderAccess Enabled"
}
function Get-DeviceControlResults {
    $script:CurrentSource = 'Device Control / Removable Storage / Bluetooth'
    Write-Host ""
    $mpStatus = Get-MpComputerStatus -ErrorAction SilentlyContinue
    if (-not $mpStatus) {
        Write-Error "Get-MpComputerStatus failed. Microsoft Defender Antivirus may be disabled or replaced by a third-party AV -- Device Control requires Defender AV. Aborting Defender Device Control checks."
    } else {
        $dcState = $mpStatus.DeviceControlState
        Add-Result -Name 'Device Control Enabled' -Expected 'Enabled' -Actual $(if ($null -eq $dcState) {'NOT AVAILABLE'} else {$dcState}) `
            -Status $(if ($dcState -eq 'Enabled') {'PASS'} else {'FAIL'}) `
            -Note "Defender Device Control is not enabled. NIST 3.8.7/3.1.21 -- without this, none of the device allow/deny rules (including the approved-USB rule below) are enforced at all, regardless of how they're configured." `
            -Fix "Push via Intune (OMA-URI ./Vendor/MSFT/Defender/Configuration/DeviceControlEnabled = 1)."
        $dcEnforcement = $mpStatus.DeviceControlDefaultEnforcement
        $dcEnforcementText = switch ($dcEnforcement) {
            'DefaultDeny' { 'Default Deny' }
            'DefaultAllow' { 'Default Allow' }
            default { if ($null -eq $dcEnforcement) { 'NOT AVAILABLE' } else { $dcEnforcement } }
        }
        Add-Result -Name 'Default Enforcement' -Expected 'DefaultDeny' -Actual $dcEnforcementText `
            -Status $(if ($dcEnforcement -eq 'DefaultDeny') {'PASS'} else {'FAIL'}) `
            -Note "Default Device Control enforcement is not Deny. NIST 3.1.21/3.8.7 -- with Default Allow, any device NOT explicitly matched by a rule is permitted by default; the whole point of an allowlist model (only approved USB drives work, everything else is blocked) requires Default Deny as the baseline." `
            -Fix "Push via Intune (OMA-URI ./Vendor/MSFT/Defender/Configuration/DefaultEnforcement = 2)."
        $prereqsOk = ($dcState -eq 'Enabled') -and ($dcEnforcement -eq 'DefaultDeny')
        Add-Result -Name 'Allow Approved USB Drives (rule prerequisites)' -Expected 'Device Control Enabled + Default Deny' `
            -Actual "State=$dcState, Enforcement=$dcEnforcement" `
            -Status $(if ($prereqsOk) {'PASS'} else {'FAIL'}) `
            -Note "This checks only the PREREQUISITES for the approved-USB allow rule to function -- Device Control state and default enforcement. The specific rule content (which USB devices are in the approved group, and the exact access mask granted) lives in a deployed policy XML, not a single registry value there's a simple cmdlet for. To confirm the rule itself is actually working as configured, use Microsoft's own documented test: insert an APPROVED USB drive and confirm full read/write/execute access, then insert an UNAPPROVED USB drive and confirm it's blocked. Both prerequisites passing here means the rule CAN work; it doesn't confirm the specific device group membership is correct." `
            -Fix "If prerequisites above show FAIL, fix those first. If prerequisites PASS but the rule still doesn't behave as expected, review the deployed device control policy in Intune (Endpoint security > Device control) to confirm the approved device group's hardware/instance IDs are correct."
    }
    $wpdGuids = @('{6AC27878-A6FA-4155-BA85-F98F491D4F33}', '{F33FDC04-D1AC-4E8E-9A30-19BBD4B108AE}')
    function Get-LoggedOnUserHivePaths {
        $paths = @()
        try {
            $hkuKeys = Get-ChildItem 'Registry::HKEY_USERS' -ErrorAction Stop
            foreach ($key in $hkuKeys) {
                if ($key.PSChildName -match '^S-1-5-21-\d+-\d+-\d+-\d+$') {
                    $paths += "Registry::HKEY_USERS\$($key.PSChildName)"
                }
            }
        } catch {}
        return $paths
    }
    function Test-WpdDenyAll {
        param([string]$Hive, [string]$ValueName)
        if ($Hive -eq 'HKCU') {
            $userHives = Get-LoggedOnUserHivePaths
            if ($userHives.Count -eq 0) { return $null }
            foreach ($hivePath in $userHives) {
                foreach ($guid in $wpdGuids) {
                    $path = "$hivePath\SOFTWARE\Policies\Microsoft\Windows\RemovableStorageDevices\$guid"
                    $val = Get-RegValue -Path $path -Name $ValueName
                    if ($val -ne 1) { return $false }
                }
            }
            return $true
        }
        foreach ($guid in $wpdGuids) {
            $path = "$Hive`:\SOFTWARE\Policies\Microsoft\Windows\RemovableStorageDevices\$guid"
            $val = Get-RegValue -Path $path -Name $ValueName
            if ($val -ne 1) { return $false }
        }
        return $true
    }
    $wpdChecks = @(
        @{ Name = 'WPD Devices: Deny read access';         Hive = 'HKLM'; Value = 'Deny_Read' }
        @{ Name = 'WPD Devices: Deny read access (User)';  Hive = 'HKCU'; Value = 'Deny_Read' }
        @{ Name = 'WPD Devices: Deny write access';         Hive = 'HKLM'; Value = 'Deny_Write' }
        @{ Name = 'WPD Devices: Deny write access (User)'; Hive = 'HKCU'; Value = 'Deny_Write' }
    )
    foreach ($chk in $wpdChecks) {
        $pass = Test-WpdDenyAll -Hive $chk.Hive -ValueName $chk.Value
        if ($chk.Hive -eq 'HKCU' -and $null -eq $pass) {
            Add-Result -Name $chk.Name -Expected '1 on BOTH WPD class GUIDs (all logged-on users)' -Actual 'No interactive user session found at scan time' -Status 'INFO' `
                -Note "This is a User-scoped policy setting -- it can only be checked against an actual logged-on user's registry hive, which requires someone to be interactively signed in when this script runs. No logged-on user hive was found under HKEY_USERS at scan time (this script runs as SYSTEM; if nobody was signed in, there is nothing to check). This does NOT mean the policy is misconfigured -- if it's deployed via Intune (confirmed correctly configured for this setting), it will apply automatically the next time a user signs in and Group Policy/CSP processing runs for their session." `
                -Fix "Re-run the verification script while a user is actively signed into this device, not purely in a background/SYSTEM-only context, to get a real result for this check."
            continue
        }
        if ($chk.Hive -eq 'HKCU') {
            $userHives = Get-LoggedOnUserHivePaths
            $detail = ($userHives | ForEach-Object {
                $userPath = $_
                $sid = ($userPath -split '\\')[-1]
                $vals = ($wpdGuids | ForEach-Object {
                    $path = "$userPath\SOFTWARE\Policies\Microsoft\Windows\RemovableStorageDevices\$_"
                    "$_=$(Get-RegValue -Path $path -Name $chk.Value)"
                }) -join ', '
                "[$sid] $vals"
            }) -join ' | '
        } else {
            $detail = ($wpdGuids | ForEach-Object {
                $path = "$($chk.Hive)`:\SOFTWARE\Policies\Microsoft\Windows\RemovableStorageDevices\$_"
                "$_ = $(Get-RegValue -Path $path -Name $chk.Value)"
            }) -join '; '
        }
        $fixText = if ($chk.Hive -eq 'HKCU') {
            "This is a User-scoped setting -- it must be set in each logged-on user's own hive (HKEY_USERS\<user-SID>\SOFTWARE\Policies\Microsoft\Windows\RemovableStorageDevices\<GUID>), never in HKCU under a SYSTEM-context script (that resolves to SYSTEM's own irrelevant profile). If this is deployed via Intune and shows FAIL for an ACTUAL signed-in user (see Actual column above for which user SID was checked), confirm the device has synced recently (Settings > Accounts > Access work or school > Info > Sync), or run gpupdate /force /target:user while that user is signed in."
        } else {
            "New-Item -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\RemovableStorageDevices\$($wpdGuids[0])' -Force | Out-Null; Set-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\RemovableStorageDevices\$($wpdGuids[0])' -Name $($chk.Value) -Value 1 -Type DWord   (repeat for $($wpdGuids[1]))"
        }
        Add-Result -Name $chk.Name -Expected '1 on BOTH WPD class GUIDs' -Actual $detail -Status $(if ($pass) {'PASS'} else {'FAIL'}) `
            -Note "WPD (Windows Portable Devices -- phones, cameras, MTP media players) $($chk.Value -replace '_',' ' -replace 'Deny','deny of') is not fully enforced. This device class requires TWO separate class GUIDs both be set for the restriction to apply consistently -- a partial configuration (only one GUID set) is a common misconfiguration that looks compliant in a quick registry glance but leaves a gap. NIST 3.1.21/3.8.7 -- MTP devices are a common uncontrolled-egress path that USB storage-class blocking alone doesn't cover." `
            -Fix $fixText
    }
    $mp = Get-MpPreference -ErrorAction SilentlyContinue
    if ($mp) {
        $removableScanOk = (-not $mp.DisableRemovableDriveScanning)
        Add-Result -Name 'Allow Full Scan Removable Drive Scanning' -Expected 'Enabled' -Actual $(if ($mp.DisableRemovableDriveScanning) {'Disabled'} else {'Enabled'}) `
            -Status $(if ($removableScanOk) {'PASS'} else {'FAIL'}) `
            -Note "Removable drive scanning is off. NIST 3.14.2/3.14.5 -- even an approved USB drive should be scanned for malware before granting broad access; approval based on device identity doesn't mean the media's contents are trusted." `
            -Fix 'Set-MpPreference -DisableRemovableDriveScanning $false'
    }
    $btPath = 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Bluetooth'
    $prepairing = Get-RegValue -Path $btPath -Name 'AllowPrepairing'
    Add-Result -Name 'Allow Prepairing' -Expected '0 (Block)' -Actual $(if ($null -eq $prepairing) {'NOT SET (native MDM policy -- expected if not Intune-enrolled)'} else {$prepairing}) `
        -Status $(if (($prepairing -eq 0) -or ($null -eq $prepairing)) {'PASS'} else {'FAIL'}) `
        -Note "Bluetooth pre-pairing (automatic pairing of specific bundled peripherals without user action) is allowed. NIST 3.1.16 -- an automatic, non-consented pairing path is a wireless attack surface worth closing on systems handling CUI." `
        -Fix "Push via Intune (OMA-URI Bluetooth/AllowPrepairing = 0). Native MDM-only policy, no local GPO equivalent."
    $proximal = Get-RegValue -Path $btPath -Name 'AllowPromptedProximalConnections'
    Add-Result -Name 'Allow Prompted Proximal Connections' -Expected '0 (Block)' -Actual $(if ($null -eq $proximal) {'NOT SET (native MDM policy -- expected if not Intune-enrolled)'} else {$proximal}) `
        -Status $(if (($proximal -eq 0) -or ($null -eq $proximal)) {'PASS'} else {'FAIL'}) `
        -Note "Swift Pair and other proximity-based Bluetooth pairing prompts are allowed. NIST 3.1.16 -- proximity pairing prompts are a known social-engineering/rogue-device vector (attacker's device shows a pairing prompt the user accepts without verifying it's legitimate)." `
        -Fix "Push via Intune (OMA-URI Bluetooth/AllowPromptedProximalConnections = 0). Native MDM-only policy, no local GPO equivalent."
}
function Get-WHfBResults {
    $script:CurrentSource = 'Windows Hello for Business'
    Write-Host ""
    $phwRoot = 'HKLM:\SOFTWARE\Policies\Microsoft\PassportForWork'
    $pinRoot = "$phwRoot\PINComplexity"
    $bioRoot = "$phwRoot\Biometrics"
    function Get-RegValue {
        param([string]$Path, [string]$Name)
        try { return (Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop).$Name }
        catch { return $null }
    }
    $useWHfB = Get-RegValue -Path $phwRoot -Name 'UsePassportForWork'
    Add-Result -Name 'Configure Windows Hello for Business' -Expected '1 (Enabled)' `
        -Actual $(if ($null -eq $useWHfB) {'NOT SET (default=Enabled/True)'} else {$useWHfB}) `
        -Pass (($useWHfB -eq 1) -or ($null -eq $useWHfB)) `
        -Note "Windows Hello for Business is explicitly disabled. NIST 3.5.3 (MFA)/3.5.10 -- WHfB replaces password-only authentication with a TPM-backed key/PIN, providing phishing-resistant, hardware-bound authentication." `
        -Fix "New-Item -Path '$phwRoot' -Force | Out-Null; Set-ItemProperty -Path '$phwRoot' -Name UsePassportForWork -Value 1 -Type DWord"
    $minLen = Get-RegValue -Path $pinRoot -Name 'MinimumPINLength'
    Add-Result -Name 'Minimum PIN length' -Expected '6' -Actual $(if ($null -eq $minLen) {'NOT SET (default=4)'} else {$minLen}) -Pass ($minLen -eq 6) `
        -Note "Minimum PIN length does not match the configured value of 6. NIST 3.5.7 -- longer PINs increase resistance to shoulder-surfing and brute-force attempts against the local TPM-rate-limited PIN gesture." `
        -Fix "New-Item -Path '$pinRoot' -Force | Out-Null; Set-ItemProperty -Path '$pinRoot' -Name MinimumPINLength -Value 6 -Type DWord"
    $maxLen = Get-RegValue -Path $pinRoot -Name 'MaximumPINLength'
    Add-Result -Name 'Maximum PIN length' -Expected '127' -Actual $(if ($null -eq $maxLen) {'NOT SET (default=127)'} else {$maxLen}) -Pass (($maxLen -eq 127) -or ($null -eq $maxLen)) `
        -Note "Maximum PIN length does not match the configured value of 127 (the platform maximum)." `
        -Fix "New-Item -Path '$pinRoot' -Force | Out-Null; Set-ItemProperty -Path '$pinRoot' -Name MaximumPINLength -Value 127 -Type DWord"
    function Test-PinCharClass {
        param([string]$RegName, [string]$DisplayName)
        $val = Get-RegValue -Path $pinRoot -Name $RegName
        $valText = switch ($val) {
            0 { 'Allowed' }
            1 { 'Required' }
            2 { 'Disallow' }
            default { if ($null -eq $val) { 'NOT SET (default=Allowed)' } else { "Unknown ($val)" } }
        }
        $pass = ($val -eq 0) -or ($null -eq $val)
        Add-Result -Name $DisplayName -Expected '0 (Allowed -- optional, not required)' -Actual $valText -Pass $pass `
            -Note "$DisplayName is not set to Allowed. Value 1 (Required) is stricter than specified and would reject PINs that don't include this character class; value 2 (Disallow) blocks it entirely. Either deviates from the configured policy of making it optional." `
            -Fix "New-Item -Path '$pinRoot' -Force | Out-Null; Set-ItemProperty -Path '$pinRoot' -Name $RegName -Value 0 -Type DWord"
    }
    Test-PinCharClass -RegName 'LowercaseLetters' -DisplayName 'Lowercase letters in PIN'
    Test-PinCharClass -RegName 'UppercaseLetters' -DisplayName 'Uppercase letters in PIN'
    Test-PinCharClass -RegName 'SpecialCharacters' -DisplayName 'Special characters in PIN'
    $expiration = Get-RegValue -Path $pinRoot -Name 'Expiration'
    Add-Result -Name 'PIN expiration (days)' -Expected '180' -Actual $(if ($null -eq $expiration) {'NOT SET (default=0, never expires)'} else {$expiration}) -Pass ($expiration -eq 180) `
        -Note "PIN expiration does not match the configured 180-day value. If unset, PINs never expire (default=0) -- NIST 3.5.6 expects a bounded credential lifetime." `
        -Fix "New-Item -Path '$pinRoot' -Force | Out-Null; Set-ItemProperty -Path '$pinRoot' -Name Expiration -Value 180 -Type DWord"
    $history = Get-RegValue -Path $pinRoot -Name 'History'
    Add-Result -Name 'Remember PIN history' -Expected '10' -Actual $(if ($null -eq $history) {'NOT SET (default=0, no history enforced)'} else {$history}) -Pass ($history -eq 10) `
        -Note "PIN history does not match the configured value of 10. NIST 3.5.8 -- prevents immediate reuse of recent PINs when a PIN change is required." `
        -Fix "New-Item -Path '$pinRoot' -Force | Out-Null; Set-ItemProperty -Path '$pinRoot' -Name History -Value 10 -Type DWord"
    $pinRecovery = Get-RegValue -Path $phwRoot -Name 'EnablePinRecovery'
    Add-Result -Name 'Enable PIN recovery' -Expected '1 (Enabled)' -Actual $(if ($null -eq $pinRecovery) {'NOT SET (default=Disabled)'} else {$pinRecovery}) -Pass ($pinRecovery -eq 1) `
        -Note "PIN recovery is not enabled. Without this, a forgotten PIN requires deleting and re-registering the entire WHfB credential rather than a controlled recovery flow -- an availability/usability gap more than a hard security control, but the org has specified it should be on." `
        -Fix "New-Item -Path '$phwRoot' -Force | Out-Null; Set-ItemProperty -Path '$phwRoot' -Name EnablePinRecovery -Value 1 -Type DWord"
    $antiSpoof = Get-RegValue -Path $bioRoot -Name 'FacialFeaturesUseEnhancedAntiSpoofing'
    Add-Result -Name 'Use enhanced anti-spoofing, when available' -Expected '1 (Enabled)' -Actual $(if ($null -eq $antiSpoof) {'NOT SET (default=Disabled)'} else {$antiSpoof}) -Pass ($antiSpoof -eq 1) `
        -Note "Enhanced anti-spoofing for Windows Hello face authentication is not required. NIST 3.5.2/3.13.11-adjacent -- without this, face authentication on devices that support enhanced anti-spoofing doesn't get the hardware-backed liveness/spoof detection, making photo/video spoofing attacks more feasible on capable hardware." `
        -Fix "New-Item -Path '$bioRoot' -Force | Out-Null; Set-ItemProperty -Path '$bioRoot' -Name FacialFeaturesUseEnhancedAntiSpoofing -Value 1 -Type DWord"
}
function Invoke-NTPRemediation {
    $script:CurrentSource = 'NTP'
    Write-Log "--- Area 1: Configure NTP Server ---" 'Cyan'
    Update-ProgressNotification -Step 2 -Total 10 -Label 'Area 1: Configure NTP Server'
    $paramsPath = 'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Parameters'
    $ntpClientPath = 'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\TimeProviders\NtpClient'
    $backupPath = 'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Parameters\_PreRemediationBackup'
    $currentServer = (Get-ItemProperty -Path $paramsPath -Name NtpServer -ErrorAction SilentlyContinue).NtpServer
    $currentType   = (Get-ItemProperty -Path $paramsPath -Name Type -ErrorAction SilentlyContinue).Type
    $currentPoll   = (Get-ItemProperty -Path $ntpClientPath -Name SpecialPollInterval -ErrorAction SilentlyContinue).SpecialPollInterval
    Write-Log "Current NtpServer : $currentServer"
    Write-Log "Current Type      : $currentType"
    Write-Log "Current PollInterval: $currentPoll"
    $alreadyCompliant = ($currentServer -eq $NtpServer) -and ($currentType -eq 'NTP') -and ($currentPoll -eq $PollIntervalSeconds) -and (-not ($currentServer -match 'time\.windows\.com'))
    if ($alreadyCompliant) {
        Write-Log "NTP is already configured correctly (server=$currentServer, type=$currentType, poll=$currentPoll) -- no change needed." 'DarkGray'
        Add-Summary -Name 'Configure NTP Server' -Status 'PASS' -Detail "Already compliant: NtpServer=$currentServer, Type=$currentType, PollInterval=$currentPoll"
        return
    }
    if (-not (Test-Path $backupPath)) {
        New-Item -Path $backupPath -Force | Out-Null
    }
    Set-ItemProperty -Path $backupPath -Name NtpServer -Value $currentServer -Type String -Force
    Set-ItemProperty -Path $backupPath -Name Type -Value $currentType -Type String -Force
    Set-ItemProperty -Path $backupPath -Name SpecialPollInterval -Value $currentPoll -Type DWord -Force
    Set-ItemProperty -Path $backupPath -Name BackupTimestamp -Value (Get-Date -Format 'o') -Type String -Force
    Write-Log "Backed up previous config to $backupPath" 'DarkGray'
    if ($currentServer -match 'time\.windows\.com') {
        Write-Log "Confirmed non-compliant source detected (time.windows.com). Proceeding with remediation." 'Yellow'
    } else {
        Write-Log "Current configuration does not match the target -- proceeding with remediation." 'Yellow'
    }
        w32tm /config /manualpeerlist:"$NtpServer,0x9" /syncfromflags:manual /reliable:yes /update | Out-Null
        Set-ItemProperty -Path $paramsPath -Name Type -Value 'NTP' -Type String -Force
        Set-ItemProperty -Path $paramsPath -Name CrossSiteSyncFlags -Value 2 -Type DWord -Force -ErrorAction SilentlyContinue
        Set-ItemProperty -Path $ntpClientPath -Name Enabled -Value 1 -Type DWord -Force
        Set-ItemProperty -Path $ntpClientPath -Name SpecialPollInterval -Value $PollIntervalSeconds -Type DWord -Force
        Set-ItemProperty -Path $ntpClientPath -Name ResolvePeerBackoffMinutes -Value 15 -Type DWord -Force -ErrorAction SilentlyContinue
        Set-ItemProperty -Path $ntpClientPath -Name ResolvePeerBackoffMaxTimes -Value 7 -Type DWord -Force -ErrorAction SilentlyContinue
        Set-ItemProperty -Path $ntpClientPath -Name EventLogFlags -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
        Write-Log "Restarting W32Time service..." 
        Restart-Service W32Time -Force
        Start-Sleep -Seconds 2
        Write-Log "Forcing immediate resync..."
        w32tm /resync /force | Out-Null
    Start-Sleep -Seconds 2
    $newServer = (Get-ItemProperty -Path $paramsPath -Name NtpServer -ErrorAction SilentlyContinue).NtpServer
    $newType   = (Get-ItemProperty -Path $paramsPath -Name Type -ErrorAction SilentlyContinue).Type
    $newPoll   = (Get-ItemProperty -Path $ntpClientPath -Name SpecialPollInterval -ErrorAction SilentlyContinue).SpecialPollInterval
    $statusRaw = w32tm /query /status 2>$null
    Write-Log ""
    Write-Log "--- Verification ---" 'Cyan'
    Write-Log "NtpServer : $newServer"
    Write-Log "Type      : $newType"
    Write-Log "PollInterval: $newPoll"
    Write-Log ""
    Write-Log ($statusRaw -join "`n")
    $pass = ($newServer -like "*$NtpServer*") -and ($newType -eq 'NTP') -and (-not ($newServer -match 'time\.windows\.com'))
    if ($pass) {
        Write-Log "`nRESULT: PASS - NTP server is now set to an authoritative source ($NtpServer)." 'Green'
    } else {
        Write-Log "`nRESULT: FAIL - NTP server did not update as expected. Check for a GPO/MDM policy overwriting this setting, or run 'gpresult /h report.html' to see what's applying." 'Red'
    }
    Add-Summary -Name 'Configure NTP Server' -Status $(if ($pass) {'PASS'} else {'FAIL'}) -Detail "NtpServer=$newServer, Type=$newType (expected $NtpServer, NTP)"
    Write-Log "`nReminder: if this device is Intune/GPO-managed, update the source policy (OMA-URI ADMX_W32Time/W32TIME_POLICY_CONFIGURE_NTPCLIENT) or this will revert on next policy refresh." 'Yellow'
    Write-Log "Rollback: registry backup of the prior values is stored at $backupPath if you need to revert manually." 'DarkGray'
}
function Invoke-FIPSRemediation {
    $script:CurrentSource = 'FIPS'
    Write-Log ""
    Write-Log "--- Area 2: Enable FIPS Mode ---" 'Cyan'
    Update-ProgressNotification -Step 3 -Total 10 -Label 'Area 2: Enable FIPS Mode'
    $fipsPath   = 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\FipsAlgorithmPolicy'
    $backupPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\FipsAlgorithmPolicy\_PreRemediationBackup'
    $currentValue = (Get-ItemProperty -Path $fipsPath -Name Enabled -ErrorAction SilentlyContinue).Enabled
    Write-Log "Current FipsAlgorithmPolicy\Enabled : $(if ($null -eq $currentValue) { 'NOT SET' } else { $currentValue })"
    if ($currentValue -eq 1) {
        Write-Log "FIPS mode is already enabled. No change needed." 'Green'
        Write-Log "RESULT: PASS (no action taken)" 'Green'
        Add-Summary -Name 'Enable FIPS Mode' -Status 'PASS' -Detail 'Already enabled, no change needed.'
        return
    }
    if (-not (Test-Path $backupPath)) {
        New-Item -Path $backupPath -Force | Out-Null
    }
    Set-ItemProperty -Path $backupPath -Name Enabled -Value $(if ($null -eq $currentValue) { -1 } else { $currentValue }) -Type DWord -Force
    Set-ItemProperty -Path $backupPath -Name BackupTimestamp -Value (Get-Date -Format 'o') -Type String -Force
    Write-Log "Backed up previous value to $backupPath (-1 = was not set)" 'DarkGray'
    Write-Log ""
    Write-Log "NOTE: FIPS mode can break applications that rely on non-FIPS-validated" 'Yellow'
    Write-Log "algorithms. If this device hasn't been piloted for FIPS mode yet, stop" 'Yellow'
    Write-Log "here (Ctrl+C) and test on one machine before running this fleet-wide." 'Yellow'
    Write-Log ""
        Set-ItemProperty -Path $fipsPath -Name Enabled -Value 1 -Type DWord -Force
        Write-Log "Set FipsAlgorithmPolicy\Enabled = 1" 'Green'
    $newValue = (Get-ItemProperty -Path $fipsPath -Name Enabled -ErrorAction SilentlyContinue).Enabled
    Write-Log ""
    Write-Log "--- Verification ---" 'Cyan'
    Write-Log "FipsAlgorithmPolicy\Enabled : $newValue"
    $pass = ($newValue -eq 1)
    if ($pass) {
        Write-Log "`nRESULT: PASS - FIPS 140 algorithm policy is set. A REBOOT IS REQUIRED for this to be fully in effect." 'Green'
    } else {
        Write-Log "`nRESULT: FAIL - Value did not update as expected. Check for a GPO/MDM policy overwriting this setting." 'Red'
    }
    Write-Log "`nRollback: registry backup of the prior value is stored at $backupPath if you need to revert manually." 'DarkGray'
    Add-Summary -Name 'Enable FIPS Mode' -Status $(if ($pass) {'PENDING REBOOT'} else {'FAIL'}) -Detail "FipsAlgorithmPolicy\Enabled=$newValue (expected 1). $(if ($pass) {'Reboot required for this to be fully in effect -- see consolidated reboot notice at the end of this run.'} else {''})"
}
function Invoke-DefenderASRRemediation {
    $script:CurrentSource = 'Defender/ASR/Firewall'
    Write-Log ""
    Write-Log "--- Area 3: Defender / ASR / SmartScreen / Firewall (10 items) ---" 'Cyan'
    Update-ProgressNotification -Step 4 -Total 10 -Label 'Area 3: Defender / ASR / SmartScreen / Firewall'
        $before = (Get-MpPreference).ScanScheduleDay
        if ($before -eq 7) {
            Write-Log "ScheduleScanDay already = 7 -- no change needed." 'DarkGray'
            Add-Summary -Name 'Defender Scan Saturday' -Status 'PASS' -Detail "Already compliant: ScanScheduleDay=7"
        } else {
            Set-MpPreference -ScanScheduleDay 7
            $after = (Get-MpPreference).ScanScheduleDay
            Add-Summary -Name 'Defender Scan Saturday' -Pass ($after -eq 7) -Detail "Was $before, now $after (expected 7)"
            Write-Log "ScheduleScanDay: $before -> $after"
        }
    $appInstallPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\SmartScreen'
    $appInstallBackup = "$appInstallPath\_PreRemediationBackup"
        Set-RegValueTracked -Path $appInstallPath -Name 'ConfigureAppInstallControlEnabled' -Value 1 -BackupPath $appInstallBackup
        $after = Get-RegValue -Path $appInstallPath -Name 'ConfigureAppInstallControlEnabled'
        Add-Summary -Name 'Smart App Control' -Pass ($after -eq 1) -Detail "ConfigureAppInstallControlEnabled = $after (expected 1)"
        Write-Log "App Install Control -> $after"
    $shellPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'
    $shellBackup = "$shellPath\_PreRemediationBackup"
        Set-RegValueTracked -Path $shellPath -Name 'EnableSmartScreenInShell' -Value 1 -BackupPath $shellBackup
        $after = Get-RegValue -Path $shellPath -Name 'EnableSmartScreenInShell'
        Add-Summary -Name 'SmartScreen in Shell' -Pass ($after -eq 1) -Detail "EnableSmartScreenInShell = $after (expected 1)"
        Write-Log "SmartScreen in Shell -> $after"
    $gameDvrPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR'
    $gameDvrBackup = "$gameDvrPath\_PreRemediationBackup"
        Set-RegValueTracked -Path $gameDvrPath -Name 'AllowGameDVR' -Value 0 -BackupPath $gameDvrBackup
        $after = Get-RegValue -Path $gameDvrPath -Name 'AllowGameDVR'
        Add-Summary -Name 'Disable Game DVR' -Pass ($after -eq 0) -Detail "AllowGameDVR = $after (expected 0)"
        Write-Log "Game DVR -> $after"
    $edgePath = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'
    $edgeBackup = "$edgePath\_PreRemediationBackup"
        Set-RegValueTracked -Path $edgePath -Name 'SmartScreenEnabled' -Value 1 -BackupPath $edgeBackup
        $after = Get-RegValue -Path $edgePath -Name 'SmartScreenEnabled'
        Add-Summary -Name 'Edge SmartScreen' -Pass ($after -eq 1) -Detail "SmartScreenEnabled = $after (expected 1)"
        Write-Log "Edge SmartScreenEnabled -> $after"
        Set-RegValueTracked -Path $edgePath -Name 'PreventSmartScreenPromptOverride' -Value 1 -BackupPath $edgeBackup
        $after = Get-RegValue -Path $edgePath -Name 'PreventSmartScreenPromptOverride'
        Add-Summary -Name 'Block SmartScreen Site Bypass' -Pass ($after -eq 1) -Detail "PreventSmartScreenPromptOverride = $after (expected 1)"
        Write-Log "PreventSmartScreenPromptOverride -> $after"
        Set-RegValueTracked -Path $edgePath -Name 'PreventSmartScreenPromptOverrideForFiles' -Value 1 -BackupPath $edgeBackup
        $after = Get-RegValue -Path $edgePath -Name 'PreventSmartScreenPromptOverrideForFiles'
        Add-Summary -Name 'Block SmartScreen DL Bypass' -Pass ($after -eq 1) -Detail "PreventSmartScreenPromptOverrideForFiles = $after (expected 1)"
        Write-Log "PreventSmartScreenPromptOverrideForFiles -> $after"
    foreach ($fwProfile in @('Domain','Private','Public')) {
            $before = (Get-NetFirewallProfile -Profile $fwProfile).LogBlocked
            if ($before -eq 'True') {
                Write-Log "$fwProfile firewall LogBlocked already True -- no change needed." 'DarkGray'
                Add-Summary -Name "Firewall Log Dropped $($fwProfile)Profile" -Status 'PASS' -Detail "Already compliant: LogBlocked=True"
            } else {
                Set-NetFirewallProfile -Profile $fwProfile -LogBlocked True
                $after = (Get-NetFirewallProfile -Profile $fwProfile).LogBlocked
                Add-Summary -Name "Firewall Log Dropped $($fwProfile)Profile" -Pass ($after -eq 'True') -Detail "Was $before, now $after (expected True)"
                Write-Log "$fwProfile firewall LogBlocked: $before -> $after"
            }
    }
}
function Invoke-HardeningRemediation {
    $script:CurrentSource = 'General Hardening'
    Write-Log ""
    Write-Log "--- Area 4: AutoRun / Autoplay / Edge sync (3 items) ---" 'Cyan'
    Update-ProgressNotification -Step 5 -Total 10 -Label 'Area 4: General Hardening'
    $explorerPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer'
    $explorerBackup = "$explorerPath\_PreRemediationBackup"
        Set-RegValueTracked -Path $explorerPath -Name 'NoAutorun' -Value 1 -BackupPath $explorerBackup
        $after = Get-RegValue -Path $explorerPath -Name 'NoAutorun'
        Add-Summary -Name 'Default AutoRun Behavior' -Pass ($after -eq 1) -Detail "NoAutorun = $after (expected 1)"
        Write-Log "NoAutorun -> $after"
        Set-RegValueTracked -Path $explorerPath -Name 'NoDriveTypeAutoRun' -Value 255 -BackupPath $explorerBackup
        $after = Get-RegValue -Path $explorerPath -Name 'NoDriveTypeAutoRun'
        Add-Summary -Name 'Turn off Autoplay (All drives)' -Pass ($after -eq 255) -Detail "NoDriveTypeAutoRun = $after (expected 255)"
        Write-Log "NoDriveTypeAutoRun -> $after"
    $edgePath = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'
    $edgeBackup = "$edgePath\_PreRemediationBackup"
        Set-RegValueTracked -Path $edgePath -Name 'SyncDisabled' -Value 1 -BackupPath $edgeBackup
        $after = Get-RegValue -Path $edgePath -Name 'SyncDisabled'
        Add-Summary -Name 'Do Not Sync Browser Settings' -Pass ($after -eq 1) -Detail "SyncDisabled = $after (expected 1). Edge must be restarted for this to take effect for any currently-open browser session."
        Write-Log "Edge SyncDisabled -> $after"
}
function Invoke-EndpointProtectionRemediation {
    $script:CurrentSource = 'Endpoint Protection'
    Write-Log ""
    Write-Log "--- Area 5: Firewall / VBS / Credential Guard ---" 'Cyan'
    Update-ProgressNotification -Step 6 -Total 10 -Label 'Area 5: Endpoint Protection'
        $before = (Get-NetFirewallProfile -Profile Domain).AllowUnicastResponseToMulticast
        if ($before -eq $false) {
            Write-Log "Domain AllowUnicastResponseToMulticast already False -- no change needed." 'DarkGray'
            Add-Summary -Name 'Firewall Domain Unicast-to-Multicast Blocked' -Status 'PASS' -Detail 'Already compliant'
        } else {
            Set-NetFirewallProfile -Profile Domain -AllowUnicastResponseToMulticast False
            $after = (Get-NetFirewallProfile -Profile Domain).AllowUnicastResponseToMulticast
            Add-Summary -Name 'Firewall Domain Unicast-to-Multicast Blocked' -Status $(if ($after -eq $false) {'PASS'} else {'FAIL'}) -Detail "Was $before, now $after"
            Write-Log "Domain AllowUnicastResponseToMulticast: $before -> $after"
        }
        $before = (Get-NetFirewallProfile -Profile Private).NotifyOnListen
        if ($before -eq $false) {
            Write-Log "Private NotifyOnListen already False -- no change needed." 'DarkGray'
            Add-Summary -Name 'Firewall Private Inbound Notifications Blocked' -Status 'PASS' -Detail 'Already compliant'
        } else {
            Set-NetFirewallProfile -Profile Private -NotifyOnListen False
            $after = (Get-NetFirewallProfile -Profile Private).NotifyOnListen
            Add-Summary -Name 'Firewall Private Inbound Notifications Blocked' -Status $(if ($after -eq $false) {'PASS'} else {'FAIL'}) -Detail "Was $before, now $after"
            Write-Log "Private NotifyOnListen: $before -> $after"
        }
        $before = (Get-NetFirewallProfile -Profile Public).DefaultInboundAction
        if ($before -eq 'Block') {
            Write-Log "Public DefaultInboundAction already Block -- no change needed." 'DarkGray'
            Add-Summary -Name 'Firewall Public Inbound Blocked' -Status 'PASS' -Detail 'Already compliant'
        } else {
            Set-NetFirewallProfile -Profile Public -DefaultInboundAction Block
            $after = (Get-NetFirewallProfile -Profile Public).DefaultInboundAction
            Add-Summary -Name 'Firewall Public Inbound Blocked' -Status $(if ($after -eq 'Block') {'PASS'} else {'FAIL'}) -Detail "Was $before, now $after"
            Write-Log "Public DefaultInboundAction: $before -> $after"
        }
        $before = (Get-NetFirewallProfile -Profile Public).NotifyOnListen
        if ($before -eq $false) {
            Write-Log "Public NotifyOnListen already False -- no change needed." 'DarkGray'
            Add-Summary -Name 'Firewall Public Inbound Notifications Blocked' -Status 'PASS' -Detail 'Already compliant'
        } else {
            Set-NetFirewallProfile -Profile Public -NotifyOnListen False
            $after = (Get-NetFirewallProfile -Profile Public).NotifyOnListen
            Add-Summary -Name 'Firewall Public Inbound Notifications Blocked' -Status $(if ($after -eq $false) {'PASS'} else {'FAIL'}) -Detail "Was $before, now $after"
            Write-Log "Public NotifyOnListen: $before -> $after"
        }
    $dg = Get-CimInstance -ClassName Win32_DeviceGuard -Namespace root\Microsoft\Windows\DeviceGuard -ErrorAction SilentlyContinue
    $hwSupportsVbs = $dg -and ($dg.AvailableSecurityProperties -contains 2)
    if (-not $dg) {
        Write-Log "`nCould not query Win32_DeviceGuard -- skipping VBS/Credential Guard remediation. Verify manually." 'Yellow'
        Add-Summary -Name 'Virtualization Based Security' -Status 'SKIPPED' -Detail 'Could not query hardware capability'
        Add-Summary -Name 'Credential Guard' -Status 'SKIPPED' -Detail 'Could not query hardware capability'
    } elseif (-not $hwSupportsVbs) {
        Write-Log "`nHardware does not appear to support VBS (no Secure Boot capability detected in AvailableSecurityProperties: $($dg.AvailableSecurityProperties -join ',')). Skipping VBS/Credential Guard -- setting the registry keys anyway would silently do nothing and give a false sense of compliance." 'Yellow'
        Add-Summary -Name 'Virtualization Based Security' -Status 'SKIPPED' -Detail 'Hardware does not support VBS (no Secure Boot/UEFI capability detected)'
        Add-Summary -Name 'Credential Guard' -Status 'SKIPPED' -Detail 'Depends on VBS -- also skipped'
        Write-Log "This is a hardware/firmware limitation, not something this script can fix. Check UEFI/BIOS settings for Secure Boot and virtualization (Intel VT-x/AMD-V), and confirm with your hardware vendor that this model supports VBS." 'Yellow'
    } else {
        $dvcGuardPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard'
        $dvcGuardBackup = "$dvcGuardPath\_PreRemediationBackup"
            $vbsChanged = Set-RegValueTracked -Path $dvcGuardPath -Name 'EnableVirtualizationBasedSecurity' -Value 1 -BackupPath $dvcGuardBackup
            $dmaAvailable = $dg.AvailableSecurityProperties -contains 4
            $platformFeatureValue = if ($dmaAvailable) { 3 } else { 1 }
            $vbsChanged = (Set-RegValueTracked -Path $dvcGuardPath -Name 'RequirePlatformSecurityFeatures' -Value $platformFeatureValue -BackupPath $dvcGuardBackup) -or $vbsChanged
            if ($vbsChanged) {
                Write-Log "VBS registry keys set (EnableVirtualizationBasedSecurity=1, RequirePlatformSecurityFeatures=$platformFeatureValue). Will not be active until reboot." 'Green'
                Add-Summary -Name 'Virtualization Based Security' -Status 'PENDING REBOOT' -Detail "Registry set. RequirePlatformSecurityFeatures=$platformFeatureValue ($(if($dmaAvailable){'Secure Boot + DMA'}else{'Secure Boot only'}))"
            } else {
                $vbsActuallyRunning = ($dg.VirtualizationBasedSecurityStatus -eq 2)
                Add-Summary -Name 'Virtualization Based Security' -Status $(if ($vbsActuallyRunning) {'PASS'} else {'PENDING REBOOT'}) -Detail "Registry already compliant. VirtualizationBasedSecurityStatus=$($dg.VirtualizationBasedSecurityStatus)$(if(-not $vbsActuallyRunning){' (registry correct but not yet running -- reboot needed)'})"
            }
        $credGuardPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceGuard'
        $credGuardBackup = "$credGuardPath\_PreRemediationBackup"
            $cgChanged = Set-RegValueTracked -Path $credGuardPath -Name 'LsaCfgFlags' -Value 1 -BackupPath $credGuardBackup
            if ($cgChanged) {
                Write-Log "Credential Guard registry key set (LsaCfgFlags=1, Enabled with UEFI lock). Requires TWO reboots to fully take effect due to UEFI lock provisioning -- this is expected Microsoft behavior, not a bug." 'Green'
                Add-Summary -Name 'Credential Guard' -Status 'PENDING REBOOT (x2)' -Detail 'LsaCfgFlags=1 set. Verify with Get-CimInstance Win32_DeviceGuard after 2 reboots.'
            } else {
                $cgActuallyRunning = ($dg.SecurityServicesRunning -contains 1)
                Add-Summary -Name 'Credential Guard' -Status $(if ($cgActuallyRunning) {'PASS'} else {'PENDING REBOOT'}) -Detail "Registry already compliant. SecurityServicesRunning=$($dg.SecurityServicesRunning -join ',')$(if(-not $cgActuallyRunning){' (registry correct but not yet running -- reboot needed)'})"
            }
    }
}
function Invoke-DeviceControlGuidance {
    $script:CurrentSource = 'Device Control'
    Write-Log ""
    Write-Log "--- Area 6: Device Control (guidance only -- no registry write) ---" 'Cyan'
    Update-ProgressNotification -Step 7 -Total 10 -Label 'Area 6: Device Control'
    Write-Host "Device Control remediation guidance (no direct registry writes -- see why below)" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "WHY THIS SCRIPT DOESN'T JUST FLIP A REGISTRY VALUE:" -ForegroundColor Yellow
    Write-Host "  DeviceControlEnabled and DefaultEnforcement are stored in a complex" -ForegroundColor Yellow
    Write-Host "  'PolicyRules' structure, not a simple DWORD. Manually editing it is a" -ForegroundColor Yellow
    Write-Host "  documented cause of policy corruption in production environments." -ForegroundColor Yellow
    Write-Host "  The safe fix goes through the actual policy management channel below." -ForegroundColor Yellow
    Write-Host ""
    $mpStatus = Get-MpComputerStatus -ErrorAction SilentlyContinue
    if ($mpStatus) {
        Write-Host "Current state:" -ForegroundColor Cyan
        Write-Host "  Device Control Enabled : $($mpStatus.DeviceControlState)"
        Write-Host "  Default Enforcement    : $($mpStatus.DeviceControlDefaultEnforcement)"
        Write-Host ""
    } else {
        Write-Host "Could not read current state via Get-MpComputerStatus." -ForegroundColor Red
    }
    $csInfo = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue
    $isDomainJoined = $csInfo.PartOfDomain
    $dsreg = dsregcmd /status 2>$null
    $isMdmEnrolled = ($dsreg -join "`n") -match 'MDMUrl\s*:\s*\S+' -or ($dsreg -join "`n") -match 'AzureAdJoined\s*:\s*YES'
    Write-Host "Management channel detected on this device:" -ForegroundColor Cyan
    Write-Host "  Domain-joined  : $isDomainJoined"
    Write-Host "  MDM/Entra ID   : $isMdmEnrolled"
    Write-Host ""
    if ($isMdmEnrolled) {
        Write-Host "--- RECOMMENDED PATH: Intune (this device is MDM-enrolled) ---" -ForegroundColor Green
        Write-Host "1. In the Intune admin center, go to Endpoint security > Device control"
        Write-Host "   (or Devices > Configuration profiles for a custom OMA-URI profile)."
        Write-Host "2. Set the following, matching the walkthrough Microsoft documents:"
        Write-Host "     OMA-URI: ./Vendor/MSFT/Defender/Configuration/DeviceControlEnabled"
        Write-Host "     Value  : 1"
        Write-Host "     OMA-URI: ./Vendor/MSFT/Defender/Configuration/DefaultEnforcement"
        Write-Host "     Value  : 2   (2 = Deny)"
        Write-Host "3. Assign the profile to this device/group and allow time for MDM sync"
        Write-Host "   (or run the sync manually below)."
        Write-Host ""
        try {
            Get-ScheduledTask | Where-Object { $_.TaskName -eq 'PushLaunch' } | Start-ScheduledTask -ErrorAction Stop
            Write-Host "Sync triggered automatically. Allow a few minutes, then re-run the verification script." -ForegroundColor Green
        } catch {
            Write-Host "Could not trigger sync automatically: $($_.Exception.Message)" -ForegroundColor Yellow
            Write-Host "Trigger it manually from Settings > Accounts > Access work or school > Info > Sync." -ForegroundColor Yellow
        }
    }
    if ($isDomainJoined -and -not $isMdmEnrolled) {
        Write-Host "--- RECOMMENDED PATH: Group Policy (this device is domain-joined, not MDM-enrolled) ---" -ForegroundColor Green
        Write-Host "1. On a machine with GPMC, download WindowsDefender.adml/.admx from:"
        Write-Host "   https://github.com/microsoft/mdatp-devicecontrol"
        Write-Host "2. Copy them into your GPO Central Store (or local PolicyDefinitions if testing locally):"
        Write-Host "   %windir%\PolicyDefinitions\ and the matching en-US subfolder"
        Write-Host "3. In Group Policy Management Editor, go to:"
        Write-Host "   Computer Configuration > Administrative Templates > Windows Components >"
        Write-Host "   Microsoft Defender Antivirus > Features > Device Control"
        Write-Host "   -> set 'Device Control' to Enabled"
        Write-Host "   -> set 'Select Device Control Default Enforcement Policy' to Default Deny"
        Write-Host "4. Run 'gpupdate /force' on this device, then re-run Verify-DeviceControl-Compliance.ps1."
        Write-Host ""
        Write-Host "(Local Group Policy Editor not opened automatically -- running unattended. Follow the steps above manually, or via your GPO management tooling.)" -ForegroundColor DarkGray
    }
    if (-not $isDomainJoined -and -not $isMdmEnrolled) {
        Write-Host "--- This device is neither domain-joined nor MDM-enrolled ---" -ForegroundColor Yellow
        Write-Host "Device Control (and most of the other NIST/CMMC controls checked in this" -ForegroundColor Yellow
        Write-Host "session) are designed to be centrally managed. A standalone device isn't" -ForegroundColor Yellow
        Write-Host "the right target for this control in a compliance context -- enroll it in" -ForegroundColor Yellow
        Write-Host "Intune or join it to the domain before applying this policy." -ForegroundColor Yellow
    }
    Write-Host ""
    Write-Host "After applying the fix through the appropriate channel above, re-run this script's verification counterpart to confirm it landed." -ForegroundColor Cyan
    Write-Host "MDM/GPO policy application isn't instant -- allow a few minutes (Intune) or run gpupdate /force (GPO) before re-checking." -ForegroundColor Cyan
    $deviceControlPathLabel = if ($isMdmEnrolled) { 'Intune' } elseif ($isDomainJoined) { 'GPO' } else { 'enrollment' }
    Add-Summary -Name 'Device Control Enabled / Default Enforcement' -Status 'GUIDANCE ONLY' -Detail "No registry write performed by design (see script header). Follow the $deviceControlPathLabel steps printed above, then re-verify."
}
function Invoke-WHfBRemediation {
    $script:CurrentSource = 'Windows Hello for Business'
    Write-Log ""
    Write-Log "--- Area 7: Windows Hello for Business (PIN policy + enrollment) ---" 'Cyan'
    Update-ProgressNotification -Step 8 -Total 10 -Label 'Area 7: Windows Hello for Business'
    $phwRoot = 'HKLM:\SOFTWARE\Policies\Microsoft\PassportForWork'
    $pinRoot = "$phwRoot\PINComplexity"
    $bioRoot = "$phwRoot\Biometrics"
    $phwBackup = "$phwRoot\_PreRemediationBackup"
    $pinBackup = "$pinRoot\_PreRemediationBackup"
    $bioBackup = "$bioRoot\_PreRemediationBackup"
    $whfbFixes = @(
        @{ Name = 'Enable PIN recovery';                        Path = $phwRoot; Reg = 'EnablePinRecovery';                    Value = 1;   Backup = $phwBackup }
        @{ Name = 'Minimum PIN length';                         Path = $pinRoot; Reg = 'MinimumPINLength';                     Value = 6;   Backup = $pinBackup }
        @{ Name = 'PIN expiration (days)';                      Path = $pinRoot; Reg = 'Expiration';                           Value = 180; Backup = $pinBackup }
        @{ Name = 'Remember PIN history';                       Path = $pinRoot; Reg = 'History';                             Value = 10;  Backup = $pinBackup }
        @{ Name = 'Use enhanced anti-spoofing, when available'; Path = $bioRoot; Reg = 'FacialFeaturesUseEnhancedAntiSpoofing'; Value = 1;   Backup = $bioBackup }
    )
    foreach ($fix in $whfbFixes) {
            Set-RegValueTracked -Path $fix.Path -Name $fix.Reg -Value $fix.Value -BackupPath $fix.Backup
            $after = Get-RegValue -Path $fix.Path -Name $fix.Reg
            $pass = ($after -eq $fix.Value)
            Add-Summary -Name $fix.Name -Status $(if ($pass) {'PASS'} else {'FAIL'}) -Detail "$($fix.Reg) = $after (expected $($fix.Value))"
            Write-Log "$($fix.Name): $($fix.Reg) -> $after"
    }
    Write-Log "Policy values set. This configures the RULES a PIN must follow -- it does not create a PIN for anyone. Checking enrollment status next (Intune enforces actual enrollment at device enrollment time, so no setup prompt is launched here)." 'DarkGray'
    if ($SkipEnrollmentPrompts) {
        Write-Log "Windows Hello enrollment check: SKIPPED (-SkipEnrollmentPrompts)." 'Yellow'
        return
    }
    $ngcPath = "$env:ProgramData\Microsoft\Ngc"
    $ngcEnrollments = if (Test-Path $ngcPath) { @(Get-ChildItem $ngcPath -ErrorAction SilentlyContinue) } else { @() }
    $helloAppearsEnrolled = $ngcEnrollments.Count -gt 0
    if ($helloAppearsEnrolled) {
        Write-Log "Windows Hello appears to already be enrolled ($($ngcEnrollments.Count) NGC credential folder(s) found)." 'Green'
        Add-Summary -Name 'Windows Hello Enrollment' -Status 'PASS (heuristic)' -Detail "$($ngcEnrollments.Count) NGC credential folder(s) present"
    } else {
        Write-Log "No Windows Hello credentials detected (heuristic check). Not launching a setup prompt -- Intune enforces enrollment at device enrollment time. Logged for visibility only." 'Yellow'
        Add-Summary -Name 'Windows Hello Enrollment' -Status 'NOT ENROLLED (informational)' -Detail 'No NGC credentials detected. Expected to be handled by Intune enrollment-time PIN policy, not this script.'
    }
}
function Invoke-FullVerification {
    param(
        [string]$Phase = 'Verification',
        [int]$ProgressStep = 1
    )
    Update-ProgressNotification -Step $ProgressStep -Total 10 -Label $Phase
    Write-Host ""
    Write-Host "=== CMMC Level 2 / NIST SP 800-171 Rev 2 Compliance Check -- $Phase ===" -ForegroundColor Cyan
    Write-Host "Source: DoD CMMC Assessment Guide L2 v2 / CMMC Scoping Guide L2 v2" -ForegroundColor DarkGray
    Write-Host ""
    $script:AllResults = @()
    Get-AuditAndCryptoResults
    Get-DefenderASRConfigResults
    Get-EndpointProtectionResults
    Get-LoginBannerResults
    Get-SecurityHardeningResults
    Get-GeneralHardeningResults
    Get-LAPSResults
    Get-ASRRulesResults
    Get-DeviceControlResults
    Get-WHfBResults
    $beforeCount = $script:AllResults.Count
    $deduped = $script:AllResults | Group-Object -Property {$_.Name} | ForEach-Object { $_.Group[0] }
    $dupCount = $beforeCount - $deduped.Count
    $passCount = @($deduped | Where-Object { $_.Status -eq 'PASS' }).Count
    $failCount = @($deduped | Where-Object { $_.Status -eq 'FAIL' }).Count
    $otherCount = @($deduped | Where-Object { $_.Status -notin @('PASS','FAIL') }).Count
    Write-Host ""
    Write-Host "Results ($Phase): $passCount PASS / $failCount FAIL / $otherCount OTHER (INFO/REVIEW/etc.) out of $($deduped.Count) checks" -ForegroundColor $(if ($failCount -eq 0) { 'Green' } else { 'Yellow' })
    if ($dupCount -gt 0) {
        Write-Host "($dupCount exact-name duplicate check(s) across source areas were consolidated.)" -ForegroundColor DarkGray
    }
    Write-Host ""
    Write-SimpleTable -Rows ($deduped | Sort-Object -Property {$_.Source}, {$_.Name}) -Columns @('Source','Name','Status','Actual')
    if ($failCount -gt 0) {
        Write-Host "`n--- FAILED CHECKS ($Phase): REFERENCE & FIX ACTION ---`n" -ForegroundColor Red
        foreach ($r in @($deduped | Where-Object { $_.Status -eq 'FAIL' } | Sort-Object -Property {$_.Source}, {$_.Name})) {
            Write-Host "[$($r.Source)] $($r.Name)" -ForegroundColor Red
            Write-Host "  Reference : $($r.Reference)"
            Write-Host "  Expected  : $($r.Expected)"
            Write-Host "  Actual    : $($r.Actual)"
            Write-Host "  Why       : $($r.Note)"
            Write-Host "  Fix       : $($r.Fix)"
            Write-Host ""
        }
    }
    if ($otherCount -gt 0) {
        Write-Host "`n--- OTHER ($Phase): INFO / REVIEW / BUILD TOO OLD / etc. ---`n" -ForegroundColor Cyan
        foreach ($r in @($deduped | Where-Object { $_.Status -notin @('PASS','FAIL') } | Sort-Object -Property {$_.Source}, {$_.Name})) {
            Write-Host "[$($r.Source)] $($r.Name) -- $($r.Status)" -ForegroundColor Cyan
            if ($r.Note) { Write-Host "  $($r.Note)" }
            Write-Host ""
        }
    }
    $reportBaseName = "$env:COMPUTERNAME-$(Get-Date -Format 'yyyyMMddHHmmss')"
    $csvPath = Join-Path $ReportDir "$reportBaseName.csv"
    $htmlPath = Join-Path $ReportDir "$reportBaseName.html"
    try {
        if (-not (Test-Path $ReportDir)) { New-Item -ItemType Directory -Path $ReportDir -Force | Out-Null }
        $csvLines = @()
        $csvLines += (ConvertTo-CsvLine -Fields @('Source','Name','Reference','Setting','Expected','Actual','Status','Note','Fix'))
        foreach ($r in ($deduped | Sort-Object -Property {$_.Source}, {$_.Name})) {
            $csvLines += (ConvertTo-CsvLine -Fields @($r.Source, $r.Name, $r.Reference, $r.Setting, $r.Expected, $r.Actual, $r.Status, $r.Note, $r.Fix))
        }
        $csvLines | Out-File -FilePath $csvPath -Encoding utf8
        Write-Host "Full CSV report exported to: $csvPath" -ForegroundColor Cyan
    } catch {
        Write-Warning "Could not write CSV report to $csvPath : $($_.Exception.Message)"
    }
    try {
        Export-HtmlReport -Results $deduped -Path $htmlPath -PassCount $passCount -FailCount $failCount -OtherCount $otherCount -DupCount $dupCount
        Write-Host "Viewable HTML report exported to: $htmlPath" -ForegroundColor Cyan
    } catch {
        Write-Warning "Could not write HTML report to $htmlPath : $($_.Exception.Message)"
    }
    $pdfPath = $null
    if (-not $SkipPdfReport) {
        $pdfPath = Join-Path $ReportDir "$reportBaseName.pdf"
        try {
            $result = Export-PdfReport -Results $deduped -Path $pdfPath -DeviceName $env:COMPUTERNAME -PassCount $passCount -FailCount $failCount -OtherCount $otherCount
            if ($result) {
                Write-Host "PDF report exported to: $pdfPath" -ForegroundColor Cyan
            } else {
                $pdfPath = $null
            }
        } catch {
            Write-Warning "Could not write PDF report to $pdfPath : $($_.Exception.Message)"
            $pdfPath = $null
        }
    }
    return @{
        Phase      = $Phase
        Results    = $deduped
        PassCount  = $passCount
        FailCount  = $failCount
        OtherCount = $otherCount
        CsvPath    = $csvPath
        HtmlPath   = $htmlPath
        PdfPath    = $pdfPath
    }
}
function Invoke-FullRemediation {
    Write-Log ""
    Write-Log "=== CMMC Level 2 / NIST SP 800-171 Remediation ===" 'Cyan'
    Write-Log "Running unattended -- no confirmation prompts. Each setting is checked against its expected value first; only settings that are actually out of compliance are changed." 'Cyan'
    Write-Log ""
    if (-not $SkipEnrollmentPrompts) {
        Write-Log "NOTE: Windows Hello enrollment is checked and reported only -- no setup screen is launched for it (Intune handles that at enrollment time)." 'Yellow'
    }
    $script:Summary = @()
    Invoke-NTPRemediation
    Invoke-FIPSRemediation
    Invoke-DefenderASRRemediation
    Invoke-HardeningRemediation
    Invoke-EndpointProtectionRemediation
    Invoke-DeviceControlGuidance
    Invoke-WHfBRemediation
    Write-Log ""
    Write-Log "=== REMEDIATION SUMMARY (all areas) ===" 'Cyan'
    Write-SimpleTable -Rows ($script:Summary | Sort-Object -Property {$_.Source}, {$_.Name}) -Columns @('Source','Name','Status','Detail')
    $passCount = @($script:Summary | Where-Object { $_.Status -eq 'PASS' }).Count
    $failCount = @($script:Summary | Where-Object { $_.Status -eq 'FAIL' }).Count
    $rebootCount = @($script:Summary | Where-Object { $_.Status -like 'PENDING REBOOT*' }).Count
    $otherCount = $script:Summary.Count - $passCount - $failCount - $rebootCount
    Write-Log "$passCount PASS / $failCount FAIL / $rebootCount PENDING REBOOT / $otherCount OTHER (SKIPPED/GUIDANCE/IN PROGRESS) out of $($script:Summary.Count) items" $(if ($failCount -eq 0) { 'Green' } else { 'Yellow' })
    if ($rebootCount -gt 0) {
        Write-Log "" 'Yellow'
        Write-Log "REBOOT REQUIRED for the following to fully take effect (Credential Guard needs TWO reboots):" 'Yellow'
        foreach ($r in @($script:Summary | Where-Object { $_.Status -like 'PENDING REBOOT*' })) {
            Write-Log "  - $($r.Name)" 'Yellow'
        }
        Write-Log "(Restart is deferred until after Phase 3 -- final verification -- completes. See script header.)" 'Yellow'
    }
    Write-Log ""
    Write-Log "Rollback: pre-change values are backed up under '_PreRemediationBackup' subkeys at each modified registry path; firewall changes can be reverted with the equivalent Set-NetFirewallProfile commands." 'DarkGray'
    Write-Log "Reminder: if these devices are Intune/GPO-managed, several of these values will revert on next policy sync unless the SOURCE policy is also corrected -- see individual notes above for which ones." 'DarkGray'
    return @{
        RebootCount = $rebootCount
        PassCount   = $passCount
        FailCount   = $failCount
    }
}
if (-not (Test-IsAdmin)) {
    Write-Error "This script must be run as Administrator. Re-launch PowerShell as Admin and try again."
    return
}
Start-ProgressNotification
$phase1 = Invoke-FullVerification -Phase 'Phase 1: Baseline Verification' -ProgressStep 1
$phase2 = Invoke-FullRemediation
$phase3 = Invoke-FullVerification -Phase 'Phase 3: Final Verification' -ProgressStep 9
Write-Host ""
Write-Host "=== PIPELINE SUMMARY ===" -ForegroundColor Cyan
Write-Host "Phase 1 (Baseline)  : $($phase1.PassCount) PASS / $($phase1.FailCount) FAIL / $($phase1.OtherCount) OTHER" -ForegroundColor Cyan
Write-Host "Phase 2 (Remediate) : $($phase2.PassCount) PASS / $($phase2.FailCount) FAIL / $($phase2.RebootCount) PENDING REBOOT" -ForegroundColor Cyan
Write-Host "Phase 3 (Final)     : $($phase3.PassCount) PASS / $($phase3.FailCount) FAIL / $($phase3.OtherCount) OTHER" -ForegroundColor Cyan
Write-Host ""
Write-Host "Baseline report : $($phase1.CsvPath)" -ForegroundColor DarkGray
Write-Host "                  $($phase1.HtmlPath)" -ForegroundColor DarkGray
Write-Host "Final report    : $($phase3.CsvPath)" -ForegroundColor DarkGray
Write-Host "                  $($phase3.HtmlPath)" -ForegroundColor DarkGray
if ($phase2.RebootCount -gt 0) {
    Update-ProgressNotification -Step 10 -Total 10 -Label 'Complete.' -Done -RebootNote 'Will reboot in 2 minutes.'
    Write-Log "" 'Yellow'
    Write-Log "Restarting automatically in 2 minutes to apply the pending change(s) from remediation." 'Yellow'
    try {
        msg.exe * "This device will restart automatically in 2 minutes to complete a required compliance update. Please save your work now." 2>$null
    } catch {
    }
    Start-Sleep -Seconds 120
    Restart-Computer -Force
} else {
    Update-ProgressNotification -Step 10 -Total 10 -Label 'Complete.' -Done -RebootNote 'No reboot needed.'
    Write-Log "" 'DarkGray'
    Write-Log "No reboot-requiring changes were made this run -- not restarting." 'DarkGray'
}
