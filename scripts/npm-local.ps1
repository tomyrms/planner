param([Parameter(ValueFromRemainingArguments = $true)][string[]]$NpmArgs)
$ErrorActionPreference = 'Stop'
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
