# One verified local backup. This script never starts Docker or restores the live database.
[CmdletBinding()]
param([string]$Destination)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$projectRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$stateDirectory = Join-Path $projectRoot '.local/maintenance/backup-daily'
$statePath = Join-Path $stateDirectory 'state.json'
$logPath = Join-Path $stateDirectory 'last-run.log'
$npmScript = Join-Path $PSScriptRoot 'npm-local.ps1'
$startedAt = (Get-Date).ToUniversalTime().ToString('o')
$stage = 'initialization'
$resultCode = 1
$mutexOwned = $false
$mutex = $null
$state = $null

function Set-PrivateDirectory([string]$Path) {
    [System.IO.Directory]::CreateDirectory($Path) | Out-Null
    $owner = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
    # Change only the DACL. Reassigning an existing owner can require an elevation privilege.
    $acl = Get-Acl -LiteralPath $Path
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($existingRule in @($acl.Access)) { $acl.RemoveAccessRuleSpecific($existingRule) }
    foreach ($sid in @($owner, [System.Security.Principal.SecurityIdentifier]::new('S-1-5-18'),
                        [System.Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))) {
        $rule = [System.Security.AccessControl.FileSystemAccessRule]::new(
            $sid, [System.Security.AccessControl.FileSystemRights]::FullControl,
            [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit',
            [System.Security.AccessControl.PropagationFlags]::None,
            [System.Security.AccessControl.AccessControlType]::Allow)
        $acl.AddAccessRule($rule)
    }
    $directoryInfo = [System.IO.DirectoryInfo]::new($Path)
    if ($PSVersionTable.PSEdition -eq 'Core') {
        [System.IO.FileSystemAclExtensions]::SetAccessControl($directoryInfo, $acl)
    } else {
        $directoryInfo.SetAccessControl($acl)
    }
}

function Save-JobState {
    # Same-directory replacement: an interrupted write cannot truncate the previous state.
    $temporary = Join-Path $stateDirectory ('state-' + [guid]::NewGuid().ToString('N') + '.tmp')
    [System.IO.File]::WriteAllText($temporary, ($state | ConvertTo-Json -Depth 3), [System.Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporary -Destination $statePath -Force
}

function Write-JobEvent([string]$Message) {
    # Only fixed operational messages are accepted here. Never persist CLI output or exception text.
    $line = (Get-Date).ToUniversalTime().ToString('o') + ' ' + $Message + [Environment]::NewLine
    [System.IO.File]::AppendAllText($logPath, $line, [System.Text.UTF8Encoding]::new($false))
}

try {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'WINDOWS_REQUIRED' }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $key = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($projectRoot.ToUpperInvariant()))).Replace('-', '') }
    finally { $sha.Dispose() }
    $mutex = [System.Threading.Mutex]::new($false, ('Global\Planner.Backup.' + $key))
    try { $mutexOwned = $mutex.WaitOne(0) }
    catch [System.Threading.AbandonedMutexException] { $mutexOwned = $true }
    if (-not $mutexOwned) {
        Write-Output 'Planner backup: another run is active; no second backup started.'
        $resultCode = 0
    } else {
        Set-PrivateDirectory $stateDirectory
        $previousSuccess = $null
        $previousFile = $null
        if (Test-Path -LiteralPath $statePath -PathType Leaf) {
            try {
                $previous = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
                if ($previous.PSObject.Properties['lastSucceededAt']) { $previousSuccess = $previous.lastSucceededAt }
                if ($previous.PSObject.Properties['lastVerifiedFile']) { $previousFile = $previous.lastVerifiedFile }
            } catch { } # A damaged local status is not evidence of a successful backup.
        }
        $state = [ordered]@{
            schemaVersion = 1; startedAt = $startedAt; finishedAt = $null; outcome = 'running'
            stage = $stage; exitCode = $null; backupFile = $null; backupBytes = $null
            lastSucceededAt = $previousSuccess; lastVerifiedFile = $previousFile
        }
        [System.IO.File]::WriteAllText($logPath, '', [System.Text.UTF8Encoding]::new($false))
        Save-JobState
        Write-JobEvent 'Started.'

        if ([string]::IsNullOrWhiteSpace($Destination)) { $Destination = Join-Path $projectRoot 'backups' }
        elseif (-not [System.IO.Path]::IsPathRooted($Destination)) { $Destination = Join-Path $projectRoot $Destination }
        $backupDirectory = [System.IO.Path]::GetFullPath($Destination)
        [System.IO.Directory]::CreateDirectory($backupDirectory) | Out-Null

        $stage = 'docker'
        $docker = Get-Command docker.exe -ErrorAction SilentlyContinue
        if (-not $docker) {
            $dockerPath = Join-Path $env:ProgramFiles 'Docker/Docker/resources/bin/docker.exe'
            if (-not (Test-Path -LiteralPath $dockerPath -PathType Leaf)) { throw 'DOCKER_UNAVAILABLE' }
        } else { $dockerPath = $docker.Source }
        $previousPath = $env:Path
        Push-Location -LiteralPath $projectRoot
        try {
            $env:Path = (Split-Path -Parent $dockerPath) + ';' + $previousPath
            & $dockerPath compose exec -T postgres pg_isready -U planner_owner -d planner *> $null
            if ($LASTEXITCODE -ne 0) { throw 'DOCKER_OR_POSTGRES_UNAVAILABLE' }
            Write-JobEvent 'PostgreSQL ready.'

            $existing = @{}
            foreach ($file in Get-ChildItem -LiteralPath $backupDirectory -Filter 'planner-*.dump' -File) { $existing[$file.Name] = $true }
            $stage = 'create'
            Write-JobEvent 'Creating dump, globals and checksums.'
            & $npmScript run backup create --dir $backupDirectory *> $null
            if ($LASTEXITCODE -ne 0) { throw 'CREATE_FAILED' }

            $stage = 'select_dump'
            $created = @(Get-ChildItem -LiteralPath $backupDirectory -Filter 'planner-*.dump' -File |
                Where-Object { $_.Name -match '^planner-\d{8}T\d{6}Z\.dump$' -and -not $existing.ContainsKey($_.Name) })
            # Refuse ambiguity if somebody also ran the manual CLI; never verify an arbitrary latest file.
            if ($created.Count -ne 1) { throw 'NEW_DUMP_AMBIGUOUS' }
            $dump = $created[0]
            $globals = Join-Path $backupDirectory ($dump.BaseName + '-globals.sql')
            if ($dump.Length -le 0 -or -not (Test-Path -LiteralPath ($dump.FullName + '.sha256') -PathType Leaf) -or
                -not (Test-Path -LiteralPath $globals -PathType Leaf)) { throw 'NEW_DUMP_INCOMPLETE' }
            $state.backupFile = $dump.Name
            $state.backupBytes = $dump.Length
            $state.stage = 'verify'
            Save-JobState

            $stage = 'verify'
            Write-JobEvent 'Verifying this dump in a temporary database.'
            & $npmScript run backup verify $dump.FullName *> $null
            if ($LASTEXITCODE -ne 0) { throw 'VERIFY_FAILED' }
            $resultCode = 0
            $state.outcome = 'succeeded'
            $state.lastSucceededAt = (Get-Date).ToUniversalTime().ToString('o')
            $state.lastVerifiedFile = $dump.Name
            Write-JobEvent 'Backup and temporary restore verification succeeded.'
            Write-Output 'Planner backup: dump and temporary restore verification succeeded.'
        } finally {
            $env:Path = $previousPath
            Pop-Location
        }
    }
} catch {
    $resultCode = switch ($stage) { 'docker' { 11 }; 'create' { 12 }; 'select_dump' { 13 }; 'verify' { 14 }; default { 15 } }
    if ($state) {
        $state.outcome = 'failed'
        try { Write-JobEvent ('Failed at stage ' + $stage + '; exit code ' + $resultCode + '.') } catch { }
    }
    [Console]::Error.WriteLine('Planner backup failed at stage ' + $stage + ' (code ' + $resultCode + '). Docker must already be running; see the private maintenance status.')
} finally {
    if ($mutexOwned) {
        if ($state) {
            $state.stage = $stage
            $state.finishedAt = (Get-Date).ToUniversalTime().ToString('o')
            $state.exitCode = $resultCode
            try { Save-JobState } catch {
                $resultCode = 15
                [Console]::Error.WriteLine('Planner backup: the private maintenance status could not be saved.')
            }
        }
        $mutex.ReleaseMutex()
    }
    if ($mutex) { $mutex.Dispose() }
}
exit $resultCode
