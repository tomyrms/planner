# Explicit opt-in only: -WhatIf previews the dedicated task without registering it.
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidatePattern('^(?:[01]\d|2[0-3]):[0-5]\d$')][string]$At = '03:15',
    [string]$Destination,
    [string]$TaskName = 'Planner Daily Backup'
)
$ErrorActionPreference = 'Stop'
$projectRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$job = Join-Path $PSScriptRoot 'backup-daily.ps1'
$powershell = Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
$userId = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$arguments = '-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $job + '"'
if (-not [string]::IsNullOrWhiteSpace($Destination)) {
    if (-not [System.IO.Path]::IsPathRooted($Destination)) { $Destination = Join-Path $projectRoot $Destination }
    $Destination = [System.IO.Path]::GetFullPath($Destination)
    if ($Destination.Contains('"')) { throw 'Invalid destination.' }
    # A trailing backslash would escape the closing quote when Windows builds argv.
    $Destination = $Destination.TrimEnd('\', '/') + '\.'
    $arguments += ' -Destination "' + $Destination + '"'
}
$existing = Get-ScheduledTask -TaskName $TaskName -TaskPath '\' -ErrorAction SilentlyContinue
if ($existing -and -not (@($existing.Actions | Where-Object { $_.Arguments -like ('*"' + $job + '"*') }).Count)) {
    throw 'A different task already uses this name; choose a dedicated TaskName.'
}
$action = New-ScheduledTaskAction -Execute $powershell -Argument $arguments -WorkingDirectory $projectRoot
$daily = New-ScheduledTaskTrigger -Daily -At ([DateTime]::ParseExact($At, 'HH:mm', [Globalization.CultureInfo]::InvariantCulture))
$login = New-ScheduledTaskTrigger -AtLogOn -User $userId
$principal = New-ScheduledTaskPrincipal -UserId $userId -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew `
    -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 15) -ExecutionTimeLimit (New-TimeSpan -Hours 1)
if ($PSCmdlet.ShouldProcess($TaskName, ('Register backup daily at ' + $At + ' and at current-user logon'))) {
    Register-ScheduledTask -TaskName $TaskName -TaskPath '\' -Action $action -Trigger @($daily, $login) `
        -Principal $principal -Settings $settings -Description 'Planner: local dump and verified temporary restore. Docker must be running. No off-machine copy.' -Force | Out-Null
    Write-Output ('Registered ' + $TaskName + '. Runs only while this user is logged in; Docker is not started by this task.')
}
