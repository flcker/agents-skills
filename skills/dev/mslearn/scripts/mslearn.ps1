# mslearn.ps1 — Query Microsoft Learn official docs via the public MCP HTTP endpoint.
# PowerShell twin of mslearn.sh (no curl / Git Bash dependency). Works on Windows PowerShell 5.1 and PowerShell 7+.
#
# Usage:
#   mslearn.ps1 search "<query>"            # semantic search over official docs
#   mslearn.ps1 code "<query>" [language]   # search official code samples (cpp csharp python ...)
#   mslearn.ps1 fetch "<learn-url>"         # fetch a full doc page as markdown
#
# Output: raw JSON from the MCP tool call (SSE framing already stripped).
# For search/code, the payload lives at result.content[0].text as an escaped JSON string.

param(
    [Parameter(Position = 0)][ValidateSet('search', 'code', 'fetch')][string]$Command,
    [Parameter(Position = 1)][string]$Query,
    [Parameter(Position = 2)][string]$Language
)

$ErrorActionPreference = 'Stop'
$Endpoint = 'https://learn.microsoft.com/api/mcp'

if (-not $Command -or -not $Query) {
    throw 'usage: mslearn.ps1 search|code|fetch <query-or-url> [language]'
}

# TLS 1.2 for old Windows PowerShell 5.1; harmless on PowerShell 7.
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}

$accept = @{ Accept = 'application/json, text/event-stream' }

# Step 1: MCP initialize handshake. The session id comes back in a response header.
$initBody = @{
    jsonrpc = '2.0'; id = 1
    method  = 'initialize'
    params  = @{
        protocolVersion = '2025-03-26'
        capabilities    = @{}
        clientInfo      = @{ name = 'claude-mslearn-skill'; version = '1.0' }
    }
} | ConvertTo-Json -Depth 5 -Compress

$init = Invoke-WebRequest -Uri $Endpoint -Method Post -ContentType 'application/json' -Headers $accept -Body $initBody -UseBasicParsing
$sessionId = $init.Headers['mcp-session-id']
if (-not $sessionId) { throw 'initialize failed: no mcp-session-id header (endpoint unreachable or API changed?)' }
if ($sessionId -is [array]) { $sessionId = $sessionId[0] }

# Build the tool call arguments.
$arguments = @{ query = $Query }
switch ($Command) {
    'code'   { $tool = 'microsoft_code_sample_search'; if ($Language) { $arguments.language = $Language } }
    'fetch'  { $tool = 'microsoft_docs_fetch'; $arguments = @{ url = $Query } }
    default  { $tool = 'microsoft_docs_search' }
}

$callBody = @{
    jsonrpc = '2.0'; id = 2
    method  = 'tools/call'
    params  = @{ name = $tool; arguments = $arguments }
} | ConvertTo-Json -Depth 5 -Compress

# Step 2: call the tool, then strip the SSE framing.
$resp = Invoke-WebRequest -Uri $Endpoint -Method Post -ContentType 'application/json' -Headers (@{ 'mcp-session-id' = $sessionId } + $accept) -Body $callBody -UseBasicParsing

# Decode from raw bytes so UTF-8 content survives servers that omit a charset on text/event-stream.
$content = if ($resp.RawBytes) { [System.Text.Encoding]::UTF8.GetString($resp.RawBytes) } else { $resp.Content }
($content -split "`r?`n") | Where-Object { $_ -like 'data: *' } | ForEach-Object { $_.Substring(6) }
