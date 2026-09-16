param([Parameter(ValueFromRemainingArguments = $true)][string[]]$NpmArgs)
$ErrorActionPreference = 'Stop'
# PowerShell consumes a bare `--`, so `npm-local.ps1 run admin -- pair` would reach npm without it.
# Restore it: everything after `run <script>` belongs to the script.
if ($NpmArgs.Count -gt 2 -and $NpmArgs[0] -eq 'run' -and $NpmArgs[2] -ne '--') {
  $NpmArgs = @($NpmArgs[0], $NpmArgs[1], '--') + $NpmArgs[2..($NpmArgs.Count - 1)]
}
$projectRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$runtime = Join-Path $projectRoot '.tools/node-v24.21.0-win-x64'
$previousPath = $env:Path
Push-Location -LiteralPath $projectRoot
try {
  if (Test-Path -LiteralPath (Join-Path $runtime 'node.exe')) {
    $env:Path = "$runtime;$previousPath"
    & (Join-Path $runtime 'node.exe') (Join-Path $runtime 'node_modules/npm/bin/npm-cli.js') @NpmArgs
  } else {
    & npm @NpmArgs
  }
  $resultCode = $LASTEXITCODE
} finally {
  $env:Path = $previousPath
  Pop-Location
}
exit $resultCode
