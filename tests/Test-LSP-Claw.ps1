param(
   [string]$Mako = "mako",
   [int]$Port = 80
)

$ErrorActionPreference = "Stop"
$repo = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$stage = Join-Path $env:TEMP ("lsp-claw-http-test-" + [guid]::NewGuid().ToString("N"))
$stdout = Join-Path $stage "stdout.log"
$stderr = Join-Path $stage "stderr.log"
$script:requestId = 0
$process = $null

New-Item -ItemType Directory -Path $stage -Force | Out-Null
Copy-Item (Join-Path $repo "www") (Join-Path $stage "www") -Recurse

function Invoke-McpRequest {
   param(
      [hashtable]$Headers,
      [string]$Method,
      [hashtable]$Params = @{}
   )
   $script:requestId++
   $body = @{jsonrpc="2.0";id=$script:requestId;method=$Method;params=$Params} | ConvertTo-Json -Depth 20
   $response = Invoke-WebRequest -UseBasicParsing -Uri $script:mcpUri -Method Post -ContentType "application/json" -Headers $Headers -Body $body
   if ($response.StatusCode -ne 200) { throw "$Method returned HTTP $($response.StatusCode)" }
   return ConvertFrom-Json $response.Content
}

function New-McpSession {
   $accept = @{Accept="application/json, text/event-stream"}
   $script:requestId++
   $responseBody = @{jsonrpc="2.0";id=$script:requestId;method="initialize";params=@{protocolVersion="2025-11-25";capabilities=@{};clientInfo=@{name="regression";version="1"}}} | ConvertTo-Json -Depth 10
   $response = Invoke-WebRequest -UseBasicParsing -Uri $script:mcpUri -Method Post -ContentType "application/json" -Headers $accept -Body $responseBody
   if (-not (ConvertFrom-Json $response.Content).result) { throw "initialize failed" }
   $sessionId = $response.Headers["MCP-Session-Id"]
   if (-not $sessionId) { throw "initialize did not return MCP-Session-Id" }
   return @{Accept="application/json, text/event-stream";"MCP-Session-Id"=$sessionId;"MCP-Protocol-Version"="2025-11-25"}
}

function Invoke-Tool {
   param([hashtable]$Headers,[string]$Name,[hashtable]$Arguments=@{})
   $reply = Invoke-McpRequest -Headers $Headers -Method "tools/call" -Params @{name=$Name;arguments=$Arguments}
   if (-not $reply.result) { throw "$Name returned a protocol error: $($reply.error.message)" }
   return $reply.result.structuredContent
}

function Assert-Equal($Actual,$Expected,[string]$Message) {
   if ($Actual -ne $Expected) { throw "$Message. Expected '$Expected', got '$Actual'" }
}

function Close-McpSession([hashtable]$Headers) {
   $delete = Invoke-WebRequest -UseBasicParsing -Uri $script:mcpUri -Method Delete -Headers $Headers
   if ($delete.StatusCode -ne 204) { throw "session DELETE returned $($delete.StatusCode)" }
}

try {
   $process = Start-Process -FilePath $Mako -ArgumentList "-llsp-claw::www" -WorkingDirectory $stage -PassThru -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr
   $deadline = (Get-Date).AddSeconds(15)
   do {
      Start-Sleep -Milliseconds 200
      $log = (Get-Content $stdout -Raw -ErrorAction SilentlyContinue) + (Get-Content $stderr -Raw -ErrorAction SilentlyContinue)
   } until ($log -match "Loading www as.*ok" -or $process.HasExited -or (Get-Date) -gt $deadline)
   if ($process.HasExited -or $log -notmatch "Loading www as.*ok") { throw "LSP-Claw did not start.`n$log" }

   $origin = if ($Port -eq 80) { "http://127.0.0.1" } else { "http://127.0.0.1:$Port" }
   $script:mcpUri = "$origin/lsp-claw/mcp.lsp"
   $session1 = New-McpSession
   $session2 = New-McpSession
   $session3 = New-McpSession

   $tools = (Invoke-McpRequest -Headers $session1 -Method "tools/list").result.tools
   Assert-Equal $tools.Count 21 "Phase 2 MCP tool count"
   foreach ($required in @("listLabs","selectLab","createLab","renameLab","deleteLab","setLabBasePath")) {
      if ($required -notin $tools.name) { throw "Missing Phase 2 tool $required" }
   }

   $runtime = Invoke-Tool $session1 "getRuntimeInfo"
   Assert-Equal $runtime.runtime.labCount 0 "getRuntimeInfo must not create a lab"
   $emptyLabs = Invoke-Tool $session1 "listLabs"
   Assert-Equal $emptyLabs.data.labCount 0 "fresh server lab count"
   $needsCreation = Invoke-Tool $session1 "listLabFiles"
   Assert-Equal $needsCreation.code "labCreationRequired" "lab-bound tool with no labs"

   $created1 = Invoke-Tool $session1 "createLab" @{labName="lab1"}
   Assert-Equal $created1.data.activeLabName "lab1" "first session selects created lab"
   Assert-Equal $created1.data.basePath "" "first lab defaults to root"

   $created2 = Invoke-Tool $session2 "createLab" @{labName="lab2"}
   Assert-Equal $created2.data.activeLabName "lab2" "second session selects its created lab"
   Assert-Equal $created2.data.basePath "lab2" "second lab gets its name as route"
   Assert-Equal $created2.data.routeChanged.labName "lab1" "first automatic root route changes when second lab is added"
   Assert-Equal $created2.data.routeChanged.newBasePath "lab1" "first lab receives a direct named route"

   $ambiguous = Invoke-Tool $session3 "getLabStatus"
   Assert-Equal $ambiguous.code "labSelectionRequired" "third session must choose between multiple labs"
   Assert-Equal $ambiguous.choices.Count 2 "selection error includes both labs"
   $selected3 = Invoke-Tool $session3 "selectLab" @{labName="lab1"}
   Assert-Equal $selected3.data.activeLabName "lab1" "third session selection"

   $status1 = Invoke-Tool $session1 "getLabStatus"
   $status2 = Invoke-Tool $session2 "getLabStatus"
   Assert-Equal $status1.data.labName "lab1" "session 1 selection remains isolated"
   Assert-Equal $status1.data.basePath "lab1" "session 1 sees changed route"
   Assert-Equal $status2.data.labName "lab2" "session 2 selection remains isolated"

   $null = Invoke-Tool $session1 "writeLabFile" @{path="index.html";content="LAB_ONE"}
   $null = Invoke-Tool $session2 "writeLabFile" @{path="index.html";content="LAB_TWO"}
   $read1 = Invoke-Tool $session1 "readLabFile" @{path="index.html"}
   $read2 = Invoke-Tool $session2 "readLabFile" @{path="index.html"}
   Assert-Equal $read1.data.content "LAB_ONE" "session 1 lab content"
   Assert-Equal $read2.data.content "LAB_TWO" "session 2 lab content"

   $override = Invoke-Tool $session1 "readLabFile" @{labName="lab2";path="index.html"}
   Assert-Equal $override.data.content "LAB_TWO" "explicit lab override"
   $statusAfterOverride = Invoke-Tool $session1 "getLabStatus"
   Assert-Equal $statusAfterOverride.data.labName "lab1" "explicit override does not change session selection"

   $started1 = Invoke-Tool $session1 "startLab"
   $started2 = Invoke-Tool $session2 "startLab"
   Assert-Equal $started1.data.labApp.appUrl "$origin/lab1/" "lab1 absolute app URL"
   Assert-Equal $started2.data.labApp.appUrl "$origin/lab2/" "lab2 absolute app URL"
   if ((Invoke-WebRequest -UseBasicParsing "$origin/lab1/").Content -notmatch "LAB_ONE") { throw "lab1 route served the wrong content" }
   if ((Invoke-WebRequest -UseBasicParsing "$origin/lab2/").Content -notmatch "LAB_TWO") { throw "lab2 route served the wrong content" }

   $trace = Invoke-Tool $session1 "readRuntimeTrace"
   Assert-Equal $trace.data.scope "server-global" "trace scope"
   Assert-Equal $trace.data.labAttributionReliable $false "trace attribution limitation"

   $missingBackup = Invoke-Tool $session1 "backupLab"
   Assert-Equal $missingBackup.code "backupNameRequired" "backup name remains required"
   Assert-Equal $missingBackup.labName "lab1" "backup prompt identifies selected lab"

   $null = Invoke-Tool $session1 "stopLab"
   $null = Invoke-Tool $session2 "stopLab"
   $renamed = Invoke-Tool $session2 "renameLab" @{labName="lab2";newLabName="lab-two";confirmed=$true}
   Assert-Equal $renamed.data.newLabName "lab-two" "rename result"
   Assert-Equal $renamed.data.basePath "lab-two" "automatic route follows rename"
   $renamedStatus = Invoke-Tool $session2 "getLabStatus"
   Assert-Equal $renamedStatus.data.labName "lab-two" "rename updates current session selection"

   $changed = Invoke-Tool $session2 "setLabBasePath" @{labName="lab-two";basePath="custom";confirmed=$true}
   Assert-Equal $changed.data.basePath "custom" "explicit route change"
   $deleted = Invoke-Tool $session2 "deleteLab" @{labName="lab-two";confirmed=$true}
   Assert-Equal $deleted.data.deleted $true "lab deletion"
   $afterDelete = Invoke-Tool $session2 "listLabs"
   Assert-Equal $afterDelete.data.labCount 1 "one lab remains after delete"
   Assert-Equal $afterDelete.data.activeLabName "lab1" "single remaining lab is selected automatically"

   Close-McpSession $session1
   Close-McpSession $session2
   Close-McpSession $session3
   Write-Output "LSP_CLAW_TEST_PASS tools=$($tools.Count) sessions=3 labs=2 routes=true selectionIsolated=true backupNameRequired=true"
}
finally {
   if ($process -and -not $process.HasExited) { Stop-Process -Id $process.Id -Force }
   Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
}
