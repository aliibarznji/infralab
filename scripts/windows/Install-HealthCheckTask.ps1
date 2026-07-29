<#
.SYNOPSIS
    Register the daily health check as a scheduled task on DC01.

.DESCRIPTION
    Runs Invoke-HealthCheck.ps1 daily as SYSTEM. SYSTEM is used because the
    check reads the event log and queries the directory, both of which need more
    than a standard user, and because a task bound to a named account breaks
    silently the day that account's password changes.

.EXAMPLE
    .\Install-HealthCheckTask.ps1

.EXAMPLE
    .\Install-HealthCheckTask.ps1 -RunAt '05:30'
#>
[CmdletBinding()]
param(
    [string]$ScriptPath = 'C:\Scripts\Invoke-HealthCheck.ps1',
    [string]$OutputPath = 'C:\HealthChecks',
    [string]$TaskName   = 'InfraLab Daily Health Check',
    [string]$RunAt      = '06:00'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path $ScriptPath)) {
    throw "Health check script not found at $ScriptPath. Copy it there first."
}

$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$ScriptPath`" -OutputPath `"$OutputPath`""

$trigger = New-ScheduledTaskTrigger -Daily -At $RunAt

$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest

$settings = New-ScheduledTaskSettingsSet `
    -StartWhenAvailable `
    -DontStopOnIdleEnd `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 30)

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
    -Principal $principal -Settings $settings -Force | Out-Null

Write-Host "Registered '$TaskName' to run daily at $RunAt as SYSTEM."
Write-Host "Run it now with: Start-ScheduledTask -TaskName '$TaskName'"
Write-Host "Check the result: Get-ScheduledTaskInfo -TaskName '$TaskName' | Select-Object LastRunTime, LastTaskResult"
