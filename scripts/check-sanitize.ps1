<#
.SYNOPSIS
  Scan skills/ and scripts/ for secrets and internal identifiers before publishing.
  Run this before every commit to a public remote. Exit 1 on a hit.
#>
[CmdletBinding()]
param([switch]$AllowInternalDomains)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$files = @(
    Get-ChildItem -LiteralPath (Join-Path $repoRoot 'skills') -Recurse -File |
        Where-Object { $_.Extension -in '.md', '.sh', '.ps1', '.mjs', '.py' }
    Get-ChildItem -LiteralPath (Join-Path $repoRoot 'scripts') -File |
        Where-Object { $_.Extension -in '.md', '.sh', '.ps1', '.mjs', '.py' }
) | Sort-Object FullName -Unique

$secretPatterns = @(
    @{ Name = 'Anthropic/OpenAI style key'; Regex = 'sk-[A-Za-z0-9_\-]{16,}' }
    @{ Name = 'GitHub token';              Regex = 'gh[pousr]_[A-Za-z0-9]{20,}' }
    @{ Name = 'GitLab token';              Regex = 'glpat-[A-Za-z0-9_\-]{16,}' }
    @{ Name = 'AWS access key';            Regex = 'AKIA[0-9A-Z]{16}' }
    @{ Name = 'Private key block';         Regex = 'BEGIN [A-Z ]*PRIVATE KEY' }
    @{ Name = 'Slack token';               Regex = 'xox[baprs]-[A-Za-z0-9\-]{10,}' }
    @{ Name = 'Inline password';           Regex = '(?i)(password|passwd|pwd)\s*[:=]\s*\S+' }
    @{ Name = 'Inline api key';            Regex = '(?i)(api[_-]?key|secret|token)\s*[:=]\s*[A-Za-z0-9+/_\-]{12,}' }
    @{ Name = 'Bearer token';              Regex = '(?i)bearer\s+[A-Za-z0-9._\-]{20,}' }
    @{ Name = 'Private IPv4';              Regex = '\b(10\.\d{1,3}|192\.168\.\d{1,3}|172\.(1[6-9]|2\d|3[01])\.\d{1,3})\.\d{1,3}\b' }
    @{ Name = 'Chinese mobile number';     Regex = '(?<!\d)1[3-9]\d{9}(?!\d)' }
    @{ Name = 'Email address';             Regex = '[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}' }
)

# Internal domain suffixes are NOT stored here (this file is public).
# Populate internal-domains.txt (gitignored) with one suffix per line, e.g. "corp.example".
$internalPatterns = @(
    @{ Name = 'Internal IP with port'; Regex = '\b\d{1,3}(\.\d{1,3}){3}:\d{2,5}\b' }
)

$domainFile = Join-Path $repoRoot 'internal-domains.txt'
if (Test-Path -LiteralPath $domainFile) {
    foreach ($suffix in Get-Content -LiteralPath $domainFile -Encoding UTF8) {
        $s = $suffix.Trim()
        if (-not $s -or $s.StartsWith('#')) { continue }
        $internalPatterns += @{
            Name  = "Internal domain $s"
            Regex = '[A-Za-z0-9.\-]+\.' + ([regex]::Escape($s))
        }
    }
}

$hits = 0

# 明显占位符（公开文档里常见的 token 示例）不视为密钥
function Test-Placeholder([string]$Line) {
    return $Line -match 'YOUR_|PLACEHOLDER|placeholder|example\.com|xxx|<[A-Za-z]+>'
}

foreach ($f in $files) {
    $text = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8
    $rel = $f.FullName.Substring($repoRoot.Length).TrimStart('\', '/')

    foreach ($p in $secretPatterns) {
        foreach ($m in [regex]::Matches($text, $p.Regex)) {
            $lineNo = ($text.Substring(0, $m.Index) -split "`n").Count
            $lineText = ($text -split "`n")[$lineNo - 1]
            if (Test-Placeholder $lineText) { continue }
            $hits++
            Write-Host ("SECRET  {0}:{1}  {2}  ->  {3}" -f $rel, $lineNo, $p.Name, $m.Value) -ForegroundColor Red
        }
    }

    foreach ($p in $internalPatterns) {
        foreach ($m in [regex]::Matches($text, $p.Regex)) {
            if ($AllowInternalDomains) { continue }
            $hits++
            $line = ($text.Substring(0, $m.Index) -split "`n").Count
            Write-Host ("INTERNAL {0}:{1}  {2}  ->  {3}" -f $rel, $line, $p.Name, $m.Value) -ForegroundColor Yellow
        }
    }
}

Write-Host ''
if ($hits -eq 0) {
    Write-Host "clean: $($files.Count) file(s), no secrets or internal identifiers" -ForegroundColor Green
    exit 0
}
Write-Host "$hits finding(s) - fix before publishing" -ForegroundColor Red
exit 1
