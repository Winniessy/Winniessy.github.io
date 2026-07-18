param(
  [ValidateSet('linux', 'mcu', 'projects', 'notes')]
  [string]$Section = 'notes',

  [Parameter(Mandatory = $true)]
  [string]$Title,

  [string]$Slug,
  [string]$Source,
  [string[]]$Tags = @()
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Write-Utf8File($Path, $Content) {
  $full = [System.IO.Path]::GetFullPath($Path)
  [System.IO.File]::WriteAllText($full, $Content, $Utf8NoBom)
}

function Read-Utf8File($Path) {
  $full = [System.IO.Path]::GetFullPath($Path)
  return [System.IO.File]::ReadAllText($full, [System.Text.Encoding]::UTF8)
}

function New-Slug($Text) {
  $value = $Text.ToLowerInvariant() -replace '[^a-z0-9]+', '-'
  $value = $value.Trim('-')
  if ([string]::IsNullOrWhiteSpace($value)) {
    $value = Get-Date -Format 'yyyyMMdd-HHmmss'
  }
  return $value
}

function Get-SectionLabel($Section) {
  switch ($Section) {
    'linux' { return 'Linux' }
    'mcu' { return 'MCU' }
    'projects' { return 'Project' }
    default { return 'Note' }
  }
}

function Ensure-LatestBlock($ReadmePath) {
  $readme = Read-Utf8File $ReadmePath
  if ($readme -notmatch '<!-- AUTO_NOTES_START -->') {
    $block = "## Latest Imports`n`n<!-- AUTO_NOTES_START -->`n<!-- AUTO_NOTES_END -->`n`n"
    if ($readme -match '(?m)^## ') {
      $readme = $readme.TrimEnd() + "`n`n" + $block
    } else {
      $readme = $readme.TrimEnd() + "`n`n" + $block
    }
    Write-Utf8File $ReadmePath $readme
  }
}

function Add-ToSidebar($SidebarPath, $Section, $Title, $RelativePath) {
  $sidebar = Read-Utf8File $SidebarPath
  $entry = "  - [$Title](/$RelativePath)"
  if ($sidebar.Contains($entry)) { return }

  $homeLinkPattern = "\(/$Section/\)"
  $lines = New-Object System.Collections.Generic.List[string]
  $lines.AddRange(($sidebar -split "`r?`n"))

  $homeIndex = -1
  for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match $homeLinkPattern) {
      $homeIndex = $i
      break
    }
  }

  if ($homeIndex -lt 0) {
    if ($lines.Count -gt 0 -and $lines[$lines.Count - 1].Trim() -ne '') { $lines.Add('') }
    $lines.Add("- $Section")
    $lines.Add($entry)
  } else {
    $insertAt = $homeIndex + 1
    while ($insertAt -lt $lines.Count -and $lines[$insertAt].StartsWith('  - ')) {
      $insertAt++
    }
    $lines.Insert($insertAt, $entry)
  }

  Write-Utf8File $SidebarPath (($lines -join "`n").TrimEnd() + "`n")
}

function Add-ToLatest($ReadmePath, $Section, $Title, $RelativePath) {
  Ensure-LatestBlock $ReadmePath
  $readme = Read-Utf8File $ReadmePath
  $date = Get-Date -Format 'yyyy-MM-dd'
  $label = Get-SectionLabel $Section
  $entry = "- [$Title]($RelativePath) - $label - $date"
  if ($readme.Contains($entry)) { return }

  $pattern = '(?s)(<!-- AUTO_NOTES_START -->\s*)(.*?)(\s*<!-- AUTO_NOTES_END -->)'
  $readme = [regex]::Replace($readme, $pattern, {
    param($m)
    $existing = $m.Groups[2].Value.Trim()
    if ([string]::IsNullOrWhiteSpace($existing)) {
      return $m.Groups[1].Value + $entry + "`n" + $m.Groups[3].Value
    }
    return $m.Groups[1].Value + $entry + "`n" + $existing + "`n" + $m.Groups[3].Value
  })

  Write-Utf8File $ReadmePath $readme
}

function Add-ToSectionReadme($SectionReadmePath, $Section, $Title, $RelativePath) {
  if (-not (Test-Path -LiteralPath $SectionReadmePath)) { return }

  $readme = Read-Utf8File $SectionReadmePath
  $entry = "- [$Title](/$RelativePath)"
  if ($readme.Contains($entry)) { return }

  $heading = switch ($Section) {
    'projects' { '项目列表' }
    'notes' { '笔记列表' }
    default { '笔记' }
  }

  $lines = New-Object System.Collections.Generic.List[string]
  $lines.AddRange(($readme -split "`r?`n"))
  $headingIndex = -1
  for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i].Trim() -eq "## $heading") {
      $headingIndex = $i
      break
    }
  }

  if ($headingIndex -lt 0) {
    while ($lines.Count -gt 0 -and $lines[$lines.Count - 1].Trim() -eq '') {
      $lines.RemoveAt($lines.Count - 1)
    }
    $lines.Add('')
    $lines.Add("## $heading")
    $lines.Add('')
    $lines.Add($entry)
  } else {
    $insertAt = $headingIndex + 1
    while ($insertAt -lt $lines.Count -and $lines[$insertAt] -notmatch '^##\s+') {
      $insertAt++
    }
    while ($insertAt -gt ($headingIndex + 1) -and $lines[$insertAt - 1].Trim() -eq '') {
      $insertAt--
    }
    $lines.Insert($insertAt, $entry)
    if (($insertAt + 1) -lt $lines.Count -and $lines[$insertAt + 1] -match '^##\s+') {
      $lines.Insert($insertAt + 1, '')
    }
  }

  Write-Utf8File $SectionReadmePath (($lines -join "`n").TrimEnd() + "`n")
}

if (-not $Slug) { $Slug = New-Slug $Title }
if (-not $Slug.EndsWith('.md')) { $Slug = "$Slug.md" }

$targetDir = Join-Path $Root $Section
New-Item -ItemType Directory -Force -Path $targetDir | Out-Null
$targetPath = Join-Path $targetDir $Slug
if (Test-Path -LiteralPath $targetPath) {
  throw "Target file already exists: $targetPath. Please use another -Slug."
}

if ($Source) {
  $sourcePath = Resolve-Path -LiteralPath $Source
  $content = [System.IO.File]::ReadAllText($sourcePath.Path, [System.Text.Encoding]::UTF8)
} else {
  $content = Get-Clipboard -Raw
}

$content = $content.Trim()
if ([string]::IsNullOrWhiteSpace($content)) {
  $content = "## Background`n`nPaste or organize your note here.`n`n## Summary`n`n- "
}

$tagLine = ''
if ($Tags.Count -gt 0) { $tagLine = 'Tags: ' + ($Tags -join ' / ') + "`n" }

if ($content -notmatch '^\s*#\s+') {
  $date = Get-Date -Format 'yyyy-MM-dd'
  $content = "# $Title`n`nDate: $date  `n$tagLine`n$content`n"
}

Write-Utf8File $targetPath $content

$relativePath = "$Section/$Slug" -replace '\\', '/'
Add-ToSidebar (Join-Path $Root '_sidebar.md') $Section $Title $relativePath
Add-ToLatest (Join-Path $Root 'README.md') $Section $Title $relativePath
Add-ToSectionReadme (Join-Path $targetDir 'README.md') $Section $Title $relativePath

Write-Host "Imported: $relativePath"
Write-Host "Updated: _sidebar.md"
Write-Host "Updated: README.md latest imports"
Write-Host "Updated: $Section/README.md"
Write-Host "Next: git add $relativePath _sidebar.md README.md $Section/README.md; git commit -m 'Add note'; git push"
