param(
   [string]$Mako = "mako",
   [int]$Port = 80
)

$ErrorActionPreference = "Stop"
$repo = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$stdout = Join-Path $env:TEMP "lsp-claw-regression-stdout.log"
$stderr = Join-Path $env:TEMP "lsp-claw-regression-stderr.log"
Remove-Item $stdout,$stderr -ErrorAction SilentlyContinue
$process = Start-Process -FilePath $Mako -ArgumentList "-llsp-claw::www" -WorkingDirectory $repo -PassThru -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr
try {
   $deadline = (Get-Date).AddSeconds(15)
   do {
      Start-Sleep -Milliseconds 200
      $log = (Get-Content $stdout -Raw -ErrorAction SilentlyContinue) + (Get-Content $stderr -Raw -ErrorAction SilentlyContinue)
   } until ($log -match "Loading www as.*ok" -or $process.HasExited -or (Get-Date) -gt $deadline)
   if ($process.HasExited -or $log -notmatch "Loading www as.*ok") { throw "LSP-Claw did not start.`n$log" }

   $uri = "http://127.0.0.1:$Port/lsp-claw/mcp.lsp"
   $accept = @{ Accept="application/json, text/event-stream" }
   $initialize = @{jsonrpc="2.0";id=1;method="initialize";params=@{protocolVersion="2025-11-25";capabilities=@{};clientInfo=@{name="regression";version="1"}}} | ConvertTo-Json -Depth 10
   $response = Invoke-WebRequest -UseBasicParsing -Uri $uri -Method Post -ContentType "application/json" -Headers $accept -Body $initialize
   if ($response.StatusCode -ne 200) { throw "initialize returned $($response.StatusCode)" }
   $sessionId = $response.Headers["MCP-Session-Id"]
   if (-not $sessionId) { throw "initialize did not return MCP-Session-Id" }

   $headers = @{Accept="application/json, text/event-stream";"MCP-Session-Id"=$sessionId;"MCP-Protocol-Version"="2025-11-25"}
   $toolsRequest = @{jsonrpc="2.0";id=2;method="tools/list";params=@{}} | ConvertTo-Json
   $toolsResponse = Invoke-WebRequest -UseBasicParsing -Uri $uri -Method Post -ContentType "application/json" -Headers $headers -Body $toolsRequest
   $tools = (ConvertFrom-Json $toolsResponse.Content).result.tools
   if ($tools.Count -lt 1 -or "getRuntimeInfo" -notin $tools.name) { throw "Expected LSP-Claw tools were not listed" }

   $missingBackupRequest = @{jsonrpc="2.0";id=3;method="tools/call";params=@{name="backupLab";arguments=@{}}} | ConvertTo-Json -Depth 8
   $missingBackupResponse = Invoke-WebRequest -UseBasicParsing -Uri $uri -Method Post -ContentType "application/json" -Headers $headers -Body $missingBackupRequest
   $missingBackup = (ConvertFrom-Json $missingBackupResponse.Content).result
   if (-not $missingBackup.isError -or $missingBackup.structuredContent.code -ne "backupNameRequired" -or -not $missingBackup.structuredContent.requiresUserInput) {
      throw "backupLab did not require a user-provided backup name"
   }

   $callRequest = @{jsonrpc="2.0";id=4;method="tools/call";params=@{name="getRuntimeInfo";arguments=@{}}} | ConvertTo-Json -Depth 8
   $callResponse = Invoke-WebRequest -UseBasicParsing -Uri $uri -Method Post -ContentType "application/json" -Headers $headers -Body $callRequest
   $call = (ConvertFrom-Json $callResponse.Content).result
   if ($call.isError -or $call.structuredContent.runtime.runtime -ne "Mako") { throw "getRuntimeInfo failed or returned the wrong runtime" }
   $expectedOrigin = if ($Port -eq 80) { "^http://127\.0\.0\.1/" } else { "^http://127\.0\.0\.1:$Port/" }
   if ($call.structuredContent.runtime.configuration.setupPage.url -notmatch $expectedOrigin) { throw "Origin-aware setup URL is missing" }

   $delete = Invoke-WebRequest -UseBasicParsing -Uri $uri -Method Delete -Headers $headers
   if ($delete.StatusCode -ne 204) { throw "session DELETE returned $($delete.StatusCode)" }
   Write-Output "LSP_CLAW_TEST_PASS tools=$($tools.Count) runtime=Mako backupNameRequired=true sessionDeleted=true"
}
finally {
   if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force }
}
