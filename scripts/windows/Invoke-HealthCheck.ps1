<#
.SYNOPSIS
    Daily health check for the lab domain controller.

.DESCRIPTION
    The Linux side of the lab is covered by health-check.sh on MON01. This is
    the Windows counterpart: it checks the things only the domain controller can
    report on — directory service health, SYSVOL and NETLOGON, DC discovery,
    the event log, and time synchronisation.

    Writes one self-contained HTML report per run.

    Replication checks are deliberately absent: lab.local has a single domain
    controller, so there is nothing to replicate. With a second DC, add
    `repadmin /replsummary` and `dcdiag /test:Replications`.

    Targets Windows PowerShell 5.1, which is what Windows Server 2022 ships.
    No PowerShell 7 syntax: no ternary, no null-coalescing, no -AsHashtable.

.PARAMETER OutputPath
    Directory to write the report into. Created if missing.

.PARAMETER SelfTest
    Run the rendering and summarising logic against known synthetic values and
    assert the output, without touching the live system. Exits non-zero on
    failure. Safe to run on any Windows machine.

.EXAMPLE
    .\Invoke-HealthCheck.ps1 -OutputPath C:\HealthChecks

.EXAMPLE
    .\Invoke-HealthCheck.ps1 -SelfTest
#>
[CmdletBinding()]
param(
    [string]$OutputPath = 'C:\HealthChecks',
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:WarnDiskPercent = 85
$script:CritDiskPercent = 95
$script:WatchedServices = @('NTDS', 'DNS', 'DHCPServer', 'Netlogon')
$script:SharePath       = 'C:\CompanyShare'
$script:ShareName       = 'CompanyShare'

function New-CheckResult {
    param(
        [Parameter(Mandatory)][string]$Category,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('OK', 'WARN', 'FAIL')][string]$Status,
        [string]$Detail = ''
    )
    [pscustomobject]@{
        Category = $Category
        Name     = $Name
        Status   = $Status
        Detail   = $Detail
    }
}

function Invoke-NativeCommand {
    <#
        PowerShell 5.1 turns native stderr output into a terminating error when
        $ErrorActionPreference is 'Stop'. dcdiag, nltest and w32tm all write to
        stderr during entirely normal operation, so run them with 'Continue' and
        judge them by their exit code instead.
    #>
    param([Parameter(Mandatory)][scriptblock]$Command)

    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $Command 2>&1 | Out-String
    } finally {
        $ErrorActionPreference = $previous
    }
}

function Get-CpuCheck {
    $load = (Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average
    if ($load -ge 90)     { $status = 'FAIL' }
    elseif ($load -ge 75) { $status = 'WARN' }
    else                  { $status = 'OK' }
    New-CheckResult -Category 'Performance' -Name 'CPU load' -Status $status `
        -Detail "$([int]$load)% average across all processors"
}

function Get-MemoryCheck {
    $os = Get-CimInstance Win32_OperatingSystem
    $usedPct = [math]::Round(
        ($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / $os.TotalVisibleMemorySize * 100, 1)
    if ($usedPct -ge 90)     { $status = 'FAIL' }
    elseif ($usedPct -ge 80) { $status = 'WARN' }
    else                     { $status = 'OK' }
    New-CheckResult -Category 'Performance' -Name 'Memory usage' -Status $status `
        -Detail "$usedPct% used of $([math]::Round($os.TotalVisibleMemorySize / 1MB, 1)) GB"
}

function Get-DiskChecks {
    foreach ($vol in Get-CimInstance Win32_LogicalDisk -Filter 'DriveType = 3') {
        if (-not $vol.Size) { continue }
        $usedPct = [math]::Round(($vol.Size - $vol.FreeSpace) / $vol.Size * 100, 1)
        if ($usedPct -ge $script:CritDiskPercent)     { $status = 'FAIL' }
        elseif ($usedPct -ge $script:WarnDiskPercent) { $status = 'WARN' }
        else                                          { $status = 'OK' }
        New-CheckResult -Category 'Storage' -Name "Volume $($vol.DeviceID)" -Status $status `
            -Detail ("{0}% used, {1} GB free of {2} GB" -f `
                $usedPct,
                [math]::Round($vol.FreeSpace / 1GB, 2),
                [math]::Round($vol.Size / 1GB, 2))
    }
}

function Get-ServiceChecks {
    foreach ($name in $script:WatchedServices) {
        $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
        if (-not $svc) {
            New-CheckResult -Category 'Services' -Name $name -Status 'FAIL' `
                -Detail 'Service is not installed on this host'
            continue
        }
        if ($svc.Status -eq 'Running') { $status = 'OK' } else { $status = 'FAIL' }
        New-CheckResult -Category 'Services' -Name $name -Status $status `
            -Detail "$($svc.DisplayName): $($svc.Status)"
    }
}

function Get-ServiceRecoveryCheck {
    # INC-001 ended with recovery actions configured on the DNS service so it
    # restarts itself rather than staying down. A setting nobody verifies is a
    # setting that quietly gets lost, so it is checked here.
    $output = Invoke-NativeCommand { sc.exe qfailure DNS }
    if ($output -match 'RESTART') { $status = 'OK' } else { $status = 'WARN' }
    $detail = if ($status -eq 'OK') {
        'DNS service has restart-on-failure recovery configured (set after INC-001).'
    } else {
        'DNS service has no restart-on-failure action. Reconfigure: sc.exe failure DNS reset= 86400 actions= restart/60000/restart/60000/restart/60000'
    }
    New-CheckResult -Category 'Services' -Name 'DNS failure recovery' -Status $status -Detail $detail
}

function Get-DcDiagCheck {
    $output = Invoke-NativeCommand { dcdiag /test:DNS }
    if ($LASTEXITCODE -eq 0 -and $output -notmatch 'failed test') { $status = 'OK' } else { $status = 'FAIL' }
    $summary = (($output -split "`r?`n") | Where-Object { $_ -match 'passed test|failed test' }) -join "`n"
    if (-not $summary) { $summary = 'dcdiag returned no test result lines.' }
    New-CheckResult -Category 'Active Directory' -Name 'dcdiag /test:DNS' -Status $status -Detail $summary
}

function Get-ShareChecks {
    foreach ($share in @('SYSVOL', 'NETLOGON')) {
        $found = Get-SmbShare -Name $share -ErrorAction SilentlyContinue
        if ($found) {
            New-CheckResult -Category 'Active Directory' -Name "$share share" -Status 'OK' `
                -Detail "Shared from $($found.Path)"
        } else {
            New-CheckResult -Category 'Active Directory' -Name "$share share" -Status 'FAIL' `
                -Detail 'Share is not present. Domain logons will fail.'
        }
    }
}

function Get-CompanyShareCheck {
    # The share the backup depends on. Its ACLs were deliberately tightened to
    # IT-Team only, and an accidental reset to Everyone would not otherwise
    # announce itself.
    $share = Get-SmbShare -Name $script:ShareName -ErrorAction SilentlyContinue
    if (-not $share) {
        New-CheckResult -Category 'File services' -Name "$($script:ShareName) share" -Status 'FAIL' `
            -Detail 'Share is missing. Backups from BKP01 will fail.'
        return
    }

    $access = @(Get-SmbShareAccess -Name $script:ShareName -ErrorAction SilentlyContinue)
    $everyone = @($access | Where-Object { $_.AccountName -eq 'Everyone' })

    if ($everyone.Count -gt 0) {
        $status = 'FAIL'
        $detail = 'Everyone is present on the share ACL. This was deliberately removed in favour of LAB\IT-Team; something has reset it.'
    } else {
        $status = 'OK'
        $names = ($access | ForEach-Object { "$($_.AccountName)=$($_.AccessRight)" }) -join '; '
        $detail = "Shared from $($share.Path). Share ACL: $names"
    }
    New-CheckResult -Category 'File services' -Name "$($script:ShareName) share ACL" -Status $status -Detail $detail
}

function Get-DcLocatorCheck {
    $domain = $env:USERDNSDOMAIN
    if (-not $domain) { $domain = 'lab.local' }
    $output = Invoke-NativeCommand { nltest "/dsgetdc:$domain" }
    if ($LASTEXITCODE -eq 0) { $status = 'OK' } else { $status = 'FAIL' }
    New-CheckResult -Category 'Active Directory' -Name 'Domain controller discovery' `
        -Status $status -Detail $output.Trim()
}

function Get-EventLogChecks {
    $since = (Get-Date).AddHours(-24)
    foreach ($log in @('System', 'Application')) {
        $events = @(Get-WinEvent -FilterHashtable @{
            LogName   = $log
            Level     = 1, 2          # Critical and Error
            StartTime = $since
        } -ErrorAction SilentlyContinue)

        if ($events.Count -ge 25)    { $status = 'FAIL' }
        elseif ($events.Count -gt 0) { $status = 'WARN' }
        else                         { $status = 'OK' }

        $top = ($events | Group-Object -Property Id |
                Sort-Object Count -Descending |
                Select-Object -First 5 |
                ForEach-Object { "Event ID $($_.Name) x$($_.Count)" }) -join "`n"
        if (-not $top) { $top = 'No error or critical events in the last 24 hours.' }

        New-CheckResult -Category 'Event log' -Name "$log errors (24h)" -Status $status `
            -Detail "$($events.Count) events`n$top"
    }
}

function Get-TimeSyncCheck {
    # Clock skew beyond the Kerberos tolerance breaks authentication in a way
    # that presents as a permissions problem, so the source is worth reporting
    # even while it is healthy.
    $raw    = Invoke-NativeCommand { w32tm /query /status }
    $lines  = $raw -split "`r?`n"
    $source = ($lines | Where-Object { $_ -match '^\s*Source:' })  -join ''
    $offset = ($lines | Where-Object { $_ -match 'Phase Offset' }) -join ''

    if ($LASTEXITCODE -eq 0 -and $source) { $status = 'OK' } else { $status = 'WARN' }

    $detail = (@($source, $offset) | Where-Object { $_ }) -join "`n"
    if (-not $detail) { $detail = $raw.Trim() }

    New-CheckResult -Category 'Time' -Name 'Time synchronisation' -Status $status -Detail $detail
}

function ConvertTo-HealthReportHtml {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Results,
        [Parameter(Mandatory)][string]$ComputerName,
        [Parameter(Mandatory)][datetime]$GeneratedAt
    )

    $okCount   = @($Results | Where-Object { $_.Status -eq 'OK' }).Count
    $warnCount = @($Results | Where-Object { $_.Status -eq 'WARN' }).Count
    $failCount = @($Results | Where-Object { $_.Status -eq 'FAIL' }).Count

    if ($failCount -gt 0)     { $overall = 'FAIL' }
    elseif ($warnCount -gt 0) { $overall = 'WARN' }
    else                      { $overall = 'OK' }

    $rows = foreach ($r in $Results) {
        # Detail text carries event log messages and raw command output. Encode
        # it: a report that renders whatever a log line happened to contain is
        # an injection waiting to happen.
        $cat    = [System.Net.WebUtility]::HtmlEncode($r.Category)
        $name   = [System.Net.WebUtility]::HtmlEncode($r.Name)
        $detail = [System.Net.WebUtility]::HtmlEncode($r.Detail)
        $cls    = $r.Status.ToLower()
        "<tr class=""$cls""><td>$cat</td><td>$name</td><td><span class=""badge"">$($r.Status)</span></td><td>$detail</td></tr>"
    }

    $stamp = $GeneratedAt.ToString('yyyy-MM-dd HH:mm:ss')

@"
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Health check - $ComputerName - $stamp</title>
<style>
 body{font-family:'Segoe UI',Arial,sans-serif;margin:2rem;color:#1a1a1a;background:#fff}
 h1{font-size:1.4rem;margin:0 0 .25rem}
 .meta{color:#555;font-size:.85rem;margin-bottom:1.5rem}
 .summary{display:flex;gap:1rem;margin-bottom:1.5rem}
 .summary div{padding:.6rem 1rem;border-radius:6px;font-weight:600}
 .s-ok{background:#e6f4ea;color:#1e7e34}
 .s-warn{background:#fff4e5;color:#8a5a00}
 .s-fail{background:#fdecea;color:#b3261e}
 table{border-collapse:collapse;width:100%;font-size:.9rem}
 th,td{text-align:left;padding:.5rem .6rem;border-bottom:1px solid #e4e4e4;vertical-align:top}
 th{background:#f5f5f5}
 td:last-child{white-space:pre-wrap;font-family:Consolas,monospace;font-size:.82rem}
 .badge{padding:.1rem .5rem;border-radius:10px;font-size:.75rem;font-weight:700}
 tr.ok .badge{background:#e6f4ea;color:#1e7e34}
 tr.warn .badge{background:#fff4e5;color:#8a5a00}
 tr.fail .badge{background:#fdecea;color:#b3261e}
 footer{margin-top:1.5rem;color:#555;font-size:.8rem}
</style>
</head>
<body>
<h1>Domain controller health check - $ComputerName</h1>
<div class="meta">Generated $stamp &middot; Overall status: <strong>$overall</strong></div>
<div class="summary">
  <div class="s-ok">OK $okCount</div>
  <div class="s-warn">WARN $warnCount</div>
  <div class="s-fail">FAIL $failCount</div>
</div>
<table>
<thead><tr><th>Category</th><th>Check</th><th>Status</th><th>Detail</th></tr></thead>
<tbody>
$($rows -join "`n")
</tbody>
</table>
<footer>
Replication checks are skipped: lab.local has a single domain controller, so
there is nothing to replicate. With a second DC, add
<code>repadmin /replsummary</code> and <code>dcdiag /test:Replications</code>.
</footer>
</body>
</html>
"@
}

function Invoke-SelfTest {
    # Exercises the rendering and summarising logic against known input. Does
    # not touch the live system, so it is safe to run anywhere.
    $results = @(
        (New-CheckResult -Category 'Storage'       -Name 'Volume C:'     -Status 'OK'   -Detail '41% used'),
        (New-CheckResult -Category 'Services'      -Name 'DNS'           -Status 'FAIL' -Detail 'Stopped & <script>alert(1)</script>'),
        (New-CheckResult -Category 'File services' -Name 'Share ACL'     -Status 'WARN' -Detail 'Everyone present')
    )

    $html = ConvertTo-HealthReportHtml -Results $results `
        -ComputerName 'SELFTEST' -GeneratedAt ([datetime]'2026-01-01T00:00:00')

    $failures = @()
    if ($html -notmatch '<title>')                      { $failures += 'title element missing' }
    if ($html -notmatch 'OK 1')                         { $failures += 'OK count not rendered' }
    if ($html -notmatch 'WARN 1')                       { $failures += 'WARN count not rendered' }
    if ($html -notmatch 'FAIL 1')                       { $failures += 'FAIL count not rendered' }
    if ($html -notmatch 'Overall status: <strong>FAIL') { $failures += 'overall status should be FAIL when any check fails' }
    if ($html -match '<script>alert')                   { $failures += 'detail text was not HTML-encoded' }
    if ($html -notmatch '&lt;script&gt;')               { $failures += 'expected the encoded form of the detail text' }
    if (([regex]::Matches($html, '<tr class=')).Count -ne 3) { $failures += 'expected exactly three result rows' }

    if ($failures.Count -gt 0) {
        Write-Host 'SELF-TEST FAILED' -ForegroundColor Red
        foreach ($f in $failures) { Write-Host "  - $f" -ForegroundColor Red }
        exit 1
    }

    Write-Host 'SELF-TEST PASSED: 8 assertions' -ForegroundColor Green
    exit 0
}

if ($SelfTest) { Invoke-SelfTest }

if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}

$results = @()
$results += Get-CpuCheck
$results += Get-MemoryCheck
$results += Get-DiskChecks
$results += Get-ServiceChecks
$results += Get-ServiceRecoveryCheck
$results += Get-DcDiagCheck
$results += Get-ShareChecks
$results += Get-CompanyShareCheck
$results += Get-DcLocatorCheck
$results += Get-EventLogChecks
$results += Get-TimeSyncCheck

$generatedAt = Get-Date
$reportPath  = Join-Path $OutputPath ("health-check-{0:yyyy-MM-dd-HHmm}.html" -f $generatedAt)

ConvertTo-HealthReportHtml -Results $results -ComputerName $env:COMPUTERNAME -GeneratedAt $generatedAt |
    Set-Content -Path $reportPath -Encoding UTF8

Write-Host "Report written to $reportPath"

$failCount = @($results | Where-Object { $_.Status -eq 'FAIL' }).Count
if ($failCount -gt 0) {
    Write-Host "$failCount check(s) FAILED" -ForegroundColor Red
    exit 1
}
exit 0
