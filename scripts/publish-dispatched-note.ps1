param(
  [string]$EventPath = $env:GITHUB_EVENT_PATH
)

$ErrorActionPreference = 'Stop'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

if ([string]::IsNullOrWhiteSpace($EventPath) -or -not (Test-Path -LiteralPath $EventPath)) {
  throw 'GitHub event payload file was not found.'
}

$eventJson = [System.IO.File]::ReadAllText(
  [System.IO.Path]::GetFullPath($EventPath),
  [System.Text.Encoding]::UTF8
)
$eventData = $eventJson | ConvertFrom-Json
$payload = $eventData.client_payload

if ($null -eq $payload) {
  throw 'The repository_dispatch event does not contain client_payload.'
}

function Get-RequiredText([string]$Name) {
  $property = $payload.PSObject.Properties[$Name]
  if ($null -eq $property -or $null -eq $property.Value) {
    throw "Missing required client_payload field: $Name"
  }

  $value = [string]$property.Value
  if ([string]::IsNullOrWhiteSpace($value)) {
    throw "client_payload field is empty: $Name"
  }
  return $value.Trim()
}

$title = Get-RequiredText 'title'
$slug = (Get-RequiredText 'slug').ToLowerInvariant()
$section = (Get-RequiredText 'section').ToLowerInvariant()
$markdown = Get-RequiredText 'markdown'

if ($title.Length -gt 160 -or $title -match '[\x00-\x1F]') {
  throw 'Title must be at most 160 characters and contain no control characters.'
}

if ($slug.EndsWith('.md')) {
  $slug = $slug.Substring(0, $slug.Length - 3)
}
if ($slug -notmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$') {
  throw 'Slug must contain only lowercase letters, numbers, and single hyphens.'
}

$allowedSections = @('linux', 'mcu', 'projects', 'notes')
if ($section -notin $allowedSections) {
  throw "Section must be one of: $($allowedSections -join ', ')"
}

$tags = @()
if ($null -ne $payload.PSObject.Properties['tags']) {
  foreach ($tagValue in @($payload.tags)) {
    $tag = ([string]$tagValue).Trim()
    if (-not [string]::IsNullOrWhiteSpace($tag)) {
      if ($tag.Length -gt 40 -or $tag -match '[\x00-\x1F]') {
        throw 'Each tag must be at most 40 characters and contain no control characters.'
      }
      $tags += $tag
    }
  }
}
if ($tags.Count -gt 5) {
  throw 'At most five tags are allowed.'
}

$tempPath = Join-Path ([System.IO.Path]::GetTempPath()) (
  'chatgpt-article-' + [guid]::NewGuid().ToString('N') + '.md'
)

try {
  [System.IO.File]::WriteAllText($tempPath, $markdown, $Utf8NoBom)
  & (Join-Path $PSScriptRoot 'import-note.ps1') `
    -Section $section `
    -Title $title `
    -Slug $slug `
    -Source $tempPath `
    -Tags $tags
} finally {
  if (Test-Path -LiteralPath $tempPath) {
    Remove-Item -LiteralPath $tempPath -Force
  }
}

$articlePath = "$section/$slug.md"
if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_OUTPUT)) {
  Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value "article_path=$articlePath" -Encoding utf8
  Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value "section_index=$section/README.md" -Encoding utf8
}
Write-Host "Prepared article: $articlePath"
