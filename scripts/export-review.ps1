# Builds a ZIP of the project for an outside review, without secrets or bulky local folders.
#   .\scripts\export-review.ps1 [-Output <zip>] [-IncludeAudit]
# Content: the documentation pack, the Markdown files at the workspace root and the backend files that Git
# would keep (tracked or not ignored): no .env, .local/, backups/, node_modules/, .tools/, dist/ or .git/.
# The archive is refused if a file looks like a key, a dump, or contains a value of the local .env.
param(
  [string]$Output,
  [switch]$IncludeAudit
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem

$backend = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$workspace = Split-Path -Parent $backend
$pack = 'IOS_AI_PLANNER_DEEP_RESEARCH_2026-09-15'
if (-not $Output) {
  $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
  $Output = Join-Path $workspace "_exports/planner-review-$stamp.zip"
}
$Output = [System.IO.Path]::GetFullPath($Output)
if ($Output.StartsWith($backend, [System.StringComparison]::OrdinalIgnoreCase)) {
  throw 'Choisir un fichier de sortie hors du dossier planner (il serait inclus au prochain export).'
}

# workspace-relative path (forward slashes) -> absolute path
$files = [ordered]@{}
function Add-Tree([string]$relative) {
  $root = Join-Path $workspace $relative
  if (-not (Test-Path -LiteralPath $root)) { return }
  foreach ($item in Get-ChildItem -LiteralPath $root -Recurse -File -Force) {
    $name = $item.FullName.Substring($workspace.Length + 1) -replace '\\', '/'
    $files[$name] = $item.FullName
  }
}
foreach ($item in Get-ChildItem -LiteralPath $workspace -File -Filter '*.md') { $files[$item.Name] = $item.FullName }
Add-Tree $pack
if ($IncludeAudit) { Add-Tree '_audit_work' }
$listed = & git -C $backend ls-files --cached --others --exclude-standard
if ($LASTEXITCODE -ne 0) { throw 'git ls-files a échoué.' }
foreach ($line in $listed) {
  $absolute = Join-Path $backend $line
  if (Test-Path -LiteralPath $absolute -PathType Leaf) { $files["planner/$line"] = $absolute }
}

# Values of the local .env that must never leave the machine (names only are ever printed).
$secrets = @()
$envFile = Join-Path $backend '.env'
if (Test-Path -LiteralPath $envFile) {
  foreach ($line in Get-Content -LiteralPath $envFile) {
    if ($line -notmatch '^\s*([A-Z0-9_]+)\s*=\s*(.+?)\s*$') { continue }
    $key = $Matches[1]
    $value = $Matches[2].Trim('"', "'")
    if ($key -match 'PASSWORD|SECRET|TOKEN|KEY$' -and $value.Length -ge 12) {
      $secrets += , @($key, $value)
    }
  }
  foreach ($line in Get-Content -LiteralPath $envFile) {
    # Passwords embedded in connection strings.
    if ($line -match '://[^:/@\s]+:([^@\s]{8,})@') { $secrets += , @('mot de passe d''URL', $Matches[1]) }
  }
}

$forbiddenNames = @(
  @('fichier .env', '(^|/)\.env($|\.)(?!example$)'),
  @('clé ou certificat', '\.(pem|key|p12|pfx|p8|mobileprovision)$'),
  @('sauvegarde', '\.(dump|sqlite|sqlite3|db)$|-globals\.sql$'),
  @('dossier local', '(^|/)(\.local|backups|node_modules|\.tools|dist|\.git)/')
)
$forbiddenContent = @(
  @('clé privée', '-----BEGIN [A-Z ]*PRIVATE KEY-----'),
  @('clé API', '\bsk-[A-Za-z0-9_-]{24,}'),
  @('dérivation de jeton', 'AUTH_REFRESH_DERIVATION_KEY\s*=\s*[0-9a-fA-F]{64}')
)
$binary = '\.(m4a|mp3|wav|png|jpe?g|gif|webp|ico|pdf|zip|woff2?)$'
$problems = @()
foreach ($name in $files.Keys) {
  foreach ($rule in $forbiddenNames) {
    if ($name -match $rule[1]) { $problems += "$name : $($rule[0])" }
  }
  if ($name -match $binary) { continue }
  $info = Get-Item -LiteralPath $files[$name]
  if ($info.Length -gt 5MB) { $problems += "$name : fichier texte trop gros pour être vérifié"; continue }
  $text = [System.IO.File]::ReadAllText($files[$name])
  foreach ($rule in $forbiddenContent) {
    if ($text -match $rule[1]) { $problems += "$name : $($rule[0])" }
  }
  foreach ($secret in $secrets) {
    if ($text.Contains($secret[1])) { $problems += "$name : valeur de $($secret[0])" }
  }
}
if ($problems.Count -gt 0) {
  Write-Host "Export refusé, fichiers à exclure ou à nettoyer :"
  $problems | Sort-Object -Unique | ForEach-Object { Write-Host "  - $_" }
  exit 1
}

New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Output) | Out-Null
if (Test-Path -LiteralPath $Output) { throw "Le fichier existe déjà : $Output" }
$zip = [System.IO.Compression.ZipFile]::Open($Output, [System.IO.Compression.ZipArchiveMode]::Create)
try {
  foreach ($name in $files.Keys) {
    [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $files[$name], "Tasks/$name", [System.IO.Compression.CompressionLevel]::Optimal) | Out-Null
  }
} finally {
  $zip.Dispose()
}
$size = [math]::Ceiling((Get-Item -LiteralPath $Output).Length / 1KB)
$groups = $files.Keys | Group-Object { ($_ -split '/')[0] } | Sort-Object Name | ForEach-Object { "$($_.Name) ($($_.Count))" }
Write-Host "Export de revue créé : $Output ($size Kio, $($files.Count) fichiers)"
Write-Host "Contenu : $($groups -join ', ')"
Write-Host 'Vérifié : aucun .env, clé, dump ni valeur secrète du .env local.'
