# qtdocs.ps1 — Query Qt official docs (doc.qt.io) via structured browsing + page scraping.
# PowerShell twin of qtdocs.sh (no curl / Git Bash dependency). Works on Windows PowerShell 5.1 and PowerShell 7+.
#
# Usage:
#   qtdocs.ps1 [-Version V] classes
#   qtdocs.ps1 [-Version V] qmltypes
#   qtdocs.ps1 [-Version V] modules
#   qtdocs.ps1 [-Version V] qmlmodules
#   qtdocs.ps1 [-Version V] module <name>
#   qtdocs.ps1 [-Version V] qmlmodule <name>
#   qtdocs.ps1 [-Version V] class <name> [member]
#   qtdocs.ps1 [-Version V] type <name> [member]
#   qtdocs.ps1 [-Version V] fetch <path-or-url>
#
# Output: a single JSON object. Exit codes: 0 ok / 1 usage / 2 no match or ambiguous / 3 network or HTTP error.

param(
    [string]$Version = '',
    [Parameter(Position = 0)][string]$Command,
    [Parameter(Position = 1)][string]$Name,
    [Parameter(Position = 2)][string]$Member
)

$ErrorActionPreference = 'Stop'

# TLS 1.2 for old Windows PowerShell 5.1; harmless on PowerShell 7.
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}

# Manual parsing of -v / -Version (also accept = syntax) placed before positional binding.
$argsList = $args
$i = 0
while ($i -lt $argsList.Count) {
    $a = $argsList[$i]
    if ($a -eq '-v' -or $a -eq '--version') {
        if ($i + 1 -ge $argsList.Count) { throw 'usage: missing value for -v/--version' }
        $Version = $argsList[$i + 1]
        $i += 2
    }
    elseif ($a -like '--version=*') { $Version = $a.Substring('--version='.Length); $i++ }
    elseif ($a -like '-v=*') { $Version = $a.Substring('-v='.Length); $i++ }
    elseif (-not $Command) { $Command = $a; $i++ }
    elseif (-not $Name) { $Name = $a; $i++ }
    elseif (-not $Member) { $Member = $a; $i++ }
    else { throw "usage: unknown argument: $a" }
}

function Usage { @'
usage: qtdocs.ps1 [-Version V] classes|qmltypes|modules|qmlmodules|module <name>|qmlmodule <name>|class <name> [member]|type <name> [member]|fetch <path-or-url>
'@ }

if (-not $Command) { Write-Error (Usage); exit 1 }

function Base-For-Version([string]$v) {
    $major = [int]($v -split '\.')[0]
    if ($major -ge 6) { return "https://doc.qt.io/qt-$v" }
    return "https://doc.qt.io/archives/qt-$v"
}

if (-not $Version) { $Version = if ($env:QTDOCS_VERSION) { $env:QTDOCS_VERSION } else { '6.8' } }
$Base = Base-For-Version $Version

function Get-Url([string]$url) {
    try {
        $resp = Invoke-WebRequest -Uri $url -UseBasicParsing
    } catch {
        $code = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
        Write-Error "ERROR: HTTP $code fetching $url"
        exit 3
    }
    if ($resp.StatusCode -ne 200) {
        Write-Error "ERROR: HTTP $($resp.StatusCode) fetching $url"
        exit 3
    }
    # Decode from raw bytes so UTF-8 survives servers that omit charset.
    if ($resp.RawBytes) { return [System.Text.Encoding]::UTF8.GetString($resp.RawBytes) }
    return [string]$resp.Content
}

function Get-Page([string]$path) { return Get-Url "$Base/$path" }

function Decode-Html([string]$s) {
    return [System.Net.WebUtility]::HtmlDecode($s)
}

# Html-To-Md: HTML on stdin -> markdown on stdout (line-oriented, mirrors qtdocs.sh).
function Html-To-Md([string]$html) {
    $out = New-Object System.Collections.Generic.List[string]
    $inpre = $false
    $buf = ''
    $lines = $html -split "`r?`n"
    foreach ($line in $lines) {
        if (-not $inpre -and $line -match '<pre[ >]') {
            $line = $line -replace '<pre[^>]*>', ''
            $inpre = $true; $buf = ''
            if ($line -match '</pre>') {
                $line = $line -replace '</pre>.*$', ''
                $out.Add('```'); $out.Add((Code-Clean $line)); $out.Add('```')
                $inpre = $false
                continue
            }
            if ($line -ne '') { $buf += (Code-Clean $line) + "`n" }
            continue
        }
        if ($inpre) {
            if ($line -match '</pre>') {
                $line = $line -replace '</pre>.*$', ''
                $buf += (Code-Clean $line)
                $buf = $buf.TrimEnd("`n")
                $out.Add('```'); $out.Add($buf); $out.Add('```')
                $inpre = $false
            } else {
                $buf += (Code-Clean $line) + "`n"
            }
            continue
        }
        if ($line -match '<h1') { $out.Add('# ' + (Collapse (Decode-Html (Strip-Tags $line)))); continue }
        if ($line -match '<h2') { $out.Add('## ' + (Collapse (Decode-Html (Strip-Tags $line)))); continue }
        if ($line -match '<h3') { $out.Add('### ' + (Collapse (Decode-Html (Strip-Tags $line)))); continue }
        if ($line -match '<h4') { $out.Add('#### ' + (Collapse (Decode-Html (Strip-Tags $line)))); continue }
        if ($line -match '<li') { $out.Add('- ' + (Collapse (Decode-Html (Strip-Tags $line)))); continue }
        $line = $line -replace '<br[^>]*>', "`n"
        $line = $line -replace '<p[^>]*>', ''
        $line = $line -replace '</p>', "`n`n"
        $line = Strip-Tags $line
        $line = Decode-Html $line
        if ($line -match '[^\s]') { $out.Add((Collapse $line)) }
    }
    return ($out -join "`n")
}

function Strip-Tags([string]$s) {
    return ($s -replace '<[^>]*>', '')
}

function Code-Clean([string]$s) {
    $s = $s -replace '</?span[^>]*>', ''
    $s = $s -replace '</?a[^>]*>', ''
    $s = Strip-Tags $s
    return Decode-Html $s
}

function Collapse([string]$s) {
    $s = $s -replace '[ \t]+', ' '
    return $s.Trim()
}

# list_dd_pairs: returns array of @{Href=;Name=}
function List-DdPairs([string]$html) {
    $res = @()
    $m = [regex]::Matches($html, '<dd><a href="([^"]*)">([^<]*)</a></dd>')
    foreach ($x in $m) { $res += [pscustomobject]@{ Href = $x.Groups[1].Value; Name = $x.Groups[2].Value } }
    return $res
}

# list_module_pairs: returns array of @{Href=;Name=}
function List-ModulePairs([string]$html) {
    $res = @()
    $m = [regex]::Matches($html, '<td class="tblName"[^>]*><p><a href="([^"]*)">([^<]*)</a></p></td>')
    foreach ($x in $m) { $res += [pscustomobject]@{ Href = $x.Groups[1].Value; Name = $x.Groups[2].Value } }
    return $res
}

function Module-DescOf([string]$line) {
    $m = [regex]::Match($line, '<td class="tblDescr"><p>(.*?)</p></td>')
    if (-not $m.Success) { return '' }
    return (Collapse (Decode-Html (Strip-Tags $m.Groups[1].Value)))
}

# resolve_module NAME SUFFIX PAGE KIND -> href
function Resolve-Module([string]$name, [string]$suffix, [string]$page, [string]$kind) {
    $html = Get-Page $page
    $pairs = List-ModulePairs $html
    $norm = ($name.ToLower() -replace '[ _-]', '')
    $cands = New-Object System.Collections.Generic.List[string]
    $cands.Add("qt$norm$suffix")
    if ($norm.StartsWith('qt')) { $cands.Add("$norm$suffix") }
    if ($norm.EndsWith('module')) { $cands.Add("$norm.html") }
    foreach ($c in $cands) {
        if ($pairs | Where-Object { $_.Href -eq $c }) { return $c }
    }
    # fallback: anchor-text exact match (case-insensitive, whitespace collapsed)
    $fold = ($name.ToLower() -replace '\s+', ' ').Trim()
    $matched = @($pairs | Where-Object { ($_.Name.ToLower() -replace '\s+', ' ').Trim() -eq $fold })
    if ($matched.Count -eq 1) { return $matched[0].Href }
    if ($matched.Count -eq 0) { Write-Error "ERROR: ${kind} '$name' not found"; exit 2 }
    Write-Error "ERROR: ambiguous ${kind} '$name':"
    foreach ($m in $matched) { Write-Error "  $($m.Name)`t$($m.Href)" }
    exit 2
}

function Resolve-Class([string]$name, [string]$page, [string]$kind) {
    $html = Get-Page $page
    $pairs = List-DdPairs $html
    $matched = @($pairs | Where-Object { $_.Name -eq $name })
    if ($matched.Count -eq 1) { return $matched[0].Href }
    if ($matched.Count -gt 1) {
        Write-Error "ERROR: ambiguous ${kind} '$name':"
        foreach ($m in $matched) { Write-Error "  $($m.Name)`t$($m.Href)" }
        exit 2
    }
    if ($kind -eq 'class') {
        $lo = $name.ToLower()
        $u = "$Base/$lo.html"
        try { $r = Invoke-WebRequest -Uri $u -UseBasicParsing -Method Head } catch { $r = $null }
        if ($r -and $r.StatusCode -eq 200) { return "$lo.html" }
    }
    Write-Error "ERROR: ${kind} '$name' not found"
    exit 2
}

function Extract-Main([string]$html) {
    $m = [regex]::Match($html, '(?s)<h1 class="title".*?</article>')
    if ($m.Success) { return $m.Value }
    $m = [regex]::Match($html, '(?s)<div class="context mainContent".*?</article>')
    if ($m.Success) { return $m.Value }
    return ''
}

function Get-Title([string]$main) {
    $m = [regex]::Match($main, '<h1 class="title"[^>]*>(.*?)</h1>')
    if (-not $m.Success) { return '' }
    return (Collapse (Decode-Html (Strip-Tags $m.Groups[1].Value)))
}

# ---- subcommands ----------------------------------------------------------

function Cmd-List([string]$page) {
    $html = Get-Page $page
    $pairs = List-DdPairs $html
    $items = @()
    foreach ($p in $pairs) { $items += [pscustomobject]@{ name = $p.Name; href = $p.Href } }
    $o = [pscustomobject]@{ version = $Version; count = $items.Count; items = $items }
    $o | ConvertTo-Json -Compress
}

function Cmd-Modules([string]$page) {
    $html = Get-Page $page
    $items = @()
    foreach ($line in ($html -split "`r?`n")) {
        if ($line -notmatch 'tblName') { continue }
        $m = [regex]::Match($line, '<td class="tblName"[^>]*><p><a href="([^"]*)">([^<]*)</a></p></td>')
        if (-not $m.Success) { continue }
        $items += [pscustomobject]@{ name = $m.Groups[2].Value; href = $m.Groups[1].Value; description = (Module-DescOf $line) }
    }
    $o = [pscustomobject]@{ version = $Version; count = $items.Count; items = $items }
    $o | ConvertTo-Json -Compress
}

function Cmd-Module([string]$name, [bool]$qml) {
    if (-not $name) { Write-Error (Usage); exit 1 }
    if ($qml) {
        $href = Resolve-Module $name '-qmlmodule.html' 'modules-qml.html' 'qmlmodule'
    } else {
        $href = Resolve-Module $name '-module.html' 'modules-cpp.html' 'module'
    }
    $html = Get-Page $href
    if ($qml) {
        $m = [regex]::Matches($html, '(?s)<h2 id="value-types".*?(?=<h2 |\z)|<h2 id="object-types".*?(?=<h2 |\z)')
        $region = ($m | ForEach-Object { $_.Value }) -join "`n"
    } else {
        $m = [regex]::Match($html, '(?s)<h2 id="classes".*?(?=<h2 id="details")')
        $region = if ($m.Success) { $m.Value } else { '' }
    }
    $pairs = List-ModulePairs $region
    $items = @()
    foreach ($p in $pairs) { if ($p.Href) { $items += [pscustomobject]@{ name = $p.Name; href = $p.Href } } }
    if ($qml) {
        $o = [pscustomobject]@{ module = $name; href = $href; count = $items.Count; types = $items }
    } else {
        $o = [pscustomobject]@{ module = $name; href = $href; count = $items.Count; classes = $items }
    }
    $o | ConvertTo-Json -Compress
}

function Cmd-Class([string]$name, [string]$member) {
    if (-not $name) { Write-Error (Usage); exit 1 }
    $href = Resolve-Class $name 'classes.html' 'class'
    $html = Get-Page $href
    $url = "$Base/$href"
    if ($member) {
        # class member: h3 anchor id
        $h3 = [regex]::Matches($html, '(?s)<h3 class="fn"[^>]*>.*?</h3>')
        $exact = @()
        $prefix = @()
        foreach ($h in $h3) {
            if ($h.Value -match "id=`"$([regex]::Escape($member))`"") { $exact += $h.Value }
            elseif ($h.Value -match "id=`"$([regex]::Escape($member))[^`"]*`"") { $prefix += $h.Value }
        }
        if ($exact.Count -eq 1) {
            $mid = $member
            $sigLine = $exact[0]
        } elseif ($exact.Count -gt 1) {
            Write-Error "ERROR: ambiguous member '$member' on $name"; exit 2
        } elseif ($prefix.Count -eq 1) {
            $mid = [regex]::Match($prefix[0], 'id="([^"]*)"').Groups[1].Value
            $sigLine = $prefix[0]
        } elseif ($prefix.Count -gt 1) {
            Write-Error "ERROR: ambiguous member '$member' on $name"; exit 2
        } else {
            Write-Error "ERROR: member '$member' not found on $name (run 'class $name' for the full member list)"; exit 2
        }
        # region: from that h3 element (included) up to the NEXT h3.fn or h2
        $pos = $html.IndexOf($sigLine)
        if ($pos -lt 0) { Write-Error "ERROR: member '$member' not found on $name"; exit 2 }
        $rest = $html.Substring($pos + $sigLine.Length)
        $m = [regex]::Match($rest, '(?s)(?<sec>.*?)(?=<h3 class="fn"|<h2 )')
        $body = if ($m.Success) { $m.Groups['sec'].Value } else { $rest }
        $region = $sigLine + $body
        $sig = Collapse (Decode-Html (Strip-Tags $sigLine))
        $o = [pscustomobject]@{ class = $name; member = $member; signature = $sig; markdown = (Html-To-Md $region); url = $url }
        $o | ConvertTo-Json -Compress
        return
    }
    $main = Extract-Main $html
    $title = Get-Title $main
    $o = [pscustomobject]@{ class = $name; title = $title; url = $url; markdown = (Html-To-Md $main) }
    $o | ConvertTo-Json -Compress
}

function Cmd-Type([string]$name, [string]$member) {
    if (-not $name) { Write-Error (Usage); exit 1 }
    $href = Resolve-Class $name 'qmltypes.html' 'type'
    $html = Get-Page $href
    $url = "$Base/$href"
    if ($member) {
        $found = $null
        foreach ($k in @('prop','method','signal')) {
            if ($html -match [regex]::Escape("<tr class=`"odd`" id=`"$member-$k`" valign=`"top`">")) { $found = "$member-$k"; break }
        }
        if (-not $found) { Write-Error "ERROR: member '$member' not found on $name"; exit 2 }
        $tr = "<tr class=`"odd`" id=`"$found`" valign=`"top`">"
        $pos = $html.IndexOf($tr)
        if ($pos -lt 0) { Write-Error "ERROR: member '$member' not found on $name"; exit 2 }
        $rest = $html.Substring($pos)
        $m = [regex]::Match($rest, '(?s)(?<sec>.*?)(?=<!-- @@@)')
        $region = if ($m.Success) { $m.Groups['sec'].Value } else { $rest }
        # signature from tblQmlPropNode / tblQmlFuncNode cell
        $sm = [regex]::Match($region, '(?s)<td class="tblQml(?:Prop|Func)Node">(?<c>.*?)</td>')
        $sig = if ($sm.Success) { Collapse (Decode-Html (Strip-Tags $sm.Groups['c'].Value)) } else { '' }
        $o = [pscustomobject]@{ type = $name; member = $member; signature = $sig; markdown = (Html-To-Md $region); url = $url }
        $o | ConvertTo-Json -Compress
        return
    }
    $main = Extract-Main $html
    $title = Get-Title $main
    $o = [pscustomobject]@{ type = $name; title = $title; url = $url; markdown = (Html-To-Md $main) }
    $o | ConvertTo-Json -Compress
}

function Cmd-Fetch([string]$arg) {
    if (-not $arg) { Write-Error (Usage); exit 1 }
    if ($arg -match '^https?://') { $url = $arg } else { $url = "$Base/$arg" }
    $html = Get-Url $url
    $main = Extract-Main $html
    $title = Get-Title $main
    $o = [pscustomobject]@{ url = $url; title = $title; markdown = (Html-To-Md $main) }
    $o | ConvertTo-Json -Compress
}

# ---- dispatch -------------------------------------------------------------
switch ($Command) {
    'classes'    { Cmd-List 'classes.html' }
    'qmltypes'   { Cmd-List 'qmltypes.html' }
    'modules'    { Cmd-Modules 'modules-cpp.html' }
    'qmlmodules' { Cmd-Modules 'modules-qml.html' }
    'module'     { Cmd-Module $Name $false }
    'qmlmodule'  { Cmd-Module $Name $true }
    'class'      { Cmd-Class $Name $Member }
    'type'       { Cmd-Type $Name $Member }
    'fetch'      { Cmd-Fetch $Name }
    default      { Write-Error "unknown command: $Command"; exit 1 }
}
