param(
   [string]$Mako = "mako",
   [int]$SourcePort = 18081,
   [int]$DestinationPort = 18082
)

$ErrorActionPreference = "Stop"
$PSDefaultParameterValues['Invoke-WebRequest:TimeoutSec'] = 20
$repo = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$root = Join-Path $env:TEMP ("lsp-claw-transfer-test-" + [guid]::NewGuid().ToString("N"))
$sourceHome = Join-Path $root "source"
$destinationHome = Join-Path $root "destination"
$sourceToken = "source-regression-token"
$destinationToken = "destination-regression-token"
$previousToken = $env:MCP_AUTH_TOKEN
$previousTtl = $env:LSP_CLAW_TRANSFER_TTL_SECONDS
$previousAllowedPorts = $env:LSP_CLAW_TRANSFER_ALLOWED_PORTS
$processes = @()
$script:requestId = 0

function Assert-Equal($Actual,$Expected,[string]$Message) {
   if ($Actual -ne $Expected) { throw "$Message. Expected '$Expected', got '$Actual'" }
}

function Start-LspClaw([string]$WorkDir,[int]$Port,[string]$Token,[string]$Name,[string]$TransferTtl) {
   New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null
   Copy-Item (Join-Path $repo "www") (Join-Path $WorkDir "www") -Recurse
   [IO.File]::WriteAllText((Join-Path $WorkDir "mako.conf"),"port=$Port`r`nsslport=0`r`n")
   $env:MCP_AUTH_TOKEN = $Token
   $env:LSP_CLAW_TRANSFER_TTL_SECONDS = $TransferTtl
   $stdout = Join-Path $WorkDir "stdout.log"
   $stderr = Join-Path $WorkDir "stderr.log"
   $process = Start-Process -FilePath $Mako -ArgumentList "-llsp-claw::www" -WorkingDirectory $WorkDir -PassThru -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr
   $script:processes += $process
   $deadline = (Get-Date).AddSeconds(15)
   do {
      Start-Sleep -Milliseconds 100
      $log = (Get-Content $stdout -Raw -ErrorAction SilentlyContinue) + (Get-Content $stderr -Raw -ErrorAction SilentlyContinue)
   } until ($log -match "Loading www as.*ok" -or $process.HasExited -or (Get-Date) -gt $deadline)
   if ($process.HasExited -or $log -notmatch "Loading www as.*ok") { throw "$Name did not start.`n$log" }
   return @{Name=$Name;Port=$Port;Origin="http://127.0.0.1:$Port";McpUri="http://127.0.0.1:$Port/lsp-claw/mcp.lsp";Token=$Token;WorkDir=$WorkDir}
}

function Invoke-McpRequest($Server,[hashtable]$Headers,[string]$Method,[hashtable]$Params=@{}) {
   $script:requestId++
   $body = @{jsonrpc="2.0";id=$script:requestId;method=$Method;params=$Params} | ConvertTo-Json -Depth 20
   $response = Invoke-WebRequest -UseBasicParsing -Uri $Server.McpUri -Method Post -ContentType "application/json" -Headers $Headers -Body $body
   return ConvertFrom-Json $response.Content
}

function New-McpSession($Server) {
   $headers = @{Accept="application/json, text/event-stream";Authorization="Bearer $($Server.Token)"}
   $script:requestId++
   $body = @{jsonrpc="2.0";id=$script:requestId;method="initialize";params=@{protocolVersion="2025-11-25";capabilities=@{};clientInfo=@{name="transfer-regression";version="1"}}} | ConvertTo-Json -Depth 10
   $response = Invoke-WebRequest -UseBasicParsing -Uri $Server.McpUri -Method Post -ContentType "application/json" -Headers $headers -Body $body
   if (-not (ConvertFrom-Json $response.Content).result) { throw "$($Server.Name) initialize failed" }
   $headers["MCP-Session-Id"] = $response.Headers["MCP-Session-Id"]
   if (-not $headers["MCP-Session-Id"]) { throw "$($Server.Name) initialize returned no session ID" }
   $headers["MCP-Protocol-Version"] = "2025-11-25"
   return $headers
}

function Invoke-Tool($Server,[hashtable]$Headers,[string]$Name,[hashtable]$Arguments=@{}) {
   $reply = Invoke-McpRequest $Server $Headers "tools/call" @{name=$Name;arguments=$Arguments}
   if (-not $reply.result) { throw "$Name returned a protocol error: $($reply.error.message)" }
   return $reply.result.structuredContent
}

function Transfer-Arguments($Descriptor,[string]$Destination,[bool]$Confirmed,[string]$Origin) {
   return @{
      transferUrl=$Descriptor.transferUrl
      transferTicket=$Descriptor.transferTicket
      expectedBytes=[long]$Descriptor.expectedBytes
      digest=$Descriptor.digest
      destinationLabName=$Destination
      conflictAction="createNew"
      confirmed=$Confirmed
      confirmedSourceOrigin=$Origin
   }
}

try {
   $env:LSP_CLAW_TRANSFER_ALLOWED_PORTS = ""
   $source = Start-LspClaw $sourceHome $SourcePort $sourceToken "source" "2"
   $env:LSP_CLAW_TRANSFER_ALLOWED_PORTS = [string]$SourcePort
   $destination = Start-LspClaw $destinationHome $DestinationPort $destinationToken "destination" ""
   [IO.File]::WriteAllText((Join-Path $sourceHome "www\redirect.lsp"),'<?lsp response:sendredirect"transfer.lsp" ?>')
   [IO.File]::WriteAllText((Join-Path $sourceHome "www\partial.lsp"),'<?lsp response:setcontenttype"application/zip" response:setheader("Content-Length","100") response:setheader("X-LSP-Claw-SHA256",string.rep("0",64)) response:write"partial" ?>')
   $sourceSession = New-McpSession $source
   $destinationSession = New-McpSession $destination

   Assert-Equal ((Invoke-McpRequest $source $sourceSession "tools/list").result.tools.Count) 25 "source tool count"
   Assert-Equal ((Invoke-McpRequest $destination $destinationSession "tools/list").result.tools.Count) 25 "destination tool count"

   $null = Invoke-Tool $source $sourceSession "createLab" @{labName="source-lab"}
   $null = Invoke-Tool $source $sourceSession "writeLabFile" @{path="index.html";content="DIRECT_TRANSFER"}
   [IO.File]::WriteAllBytes((Join-Path $sourceHome "source-lab\binary.dat"),[byte[]](0,17,128,255))
   New-Item -ItemType Directory -Path (Join-Path $sourceHome "source-lab\empty-dir") | Out-Null

   $prepared = (Invoke-Tool $source $sourceSession "prepareLabTransfer").data
   Assert-Equal $prepared.sourceOrigin $source.Origin "source origin descriptor"
   if ($prepared.transferUrl -match [regex]::Escape($prepared.transferTicket)) { throw "transfer URL exposed its ticket" }

   $unconfirmed = Invoke-Tool $destination $destinationSession "importLabTransfer" (Transfer-Arguments $prepared "copied-lab" $false "")
   Assert-Equal $unconfirmed.code "transferSourceRequiresConfirmation" "source origin confirmation is required"
   Assert-Equal $unconfirmed.sourceOrigin $source.Origin "confirmation exposes only source origin"
   if (($unconfirmed | ConvertTo-Json -Depth 20) -match [regex]::Escape($prepared.transferTicket)) { throw "destination confirmation response exposed the transfer ticket" }

   try {
      Invoke-WebRequest -UseBasicParsing -Uri $prepared.transferUrl -Headers @{Authorization="Bearer $destinationToken";"X-LSP-Claw-Transfer-Ticket"=$prepared.transferTicket} | Out-Null
      throw "transfer endpoint accepted a persistent bearer credential"
   }
   catch {
      if (-not $_.Exception.Response -or [int]$_.Exception.Response.StatusCode -ne 400) { throw }
   }

   $imported = Invoke-Tool $destination $destinationSession "importLabTransfer" (Transfer-Arguments $prepared "copied-lab" $true $source.Origin)
   Assert-Equal $imported.data.imported $true "direct transfer succeeds"
   if ($imported.data.warning) { throw "direct transfer returned cleanup warning: $($imported.data.warning)" }
   Assert-Equal $imported.data.sourceOrigin $source.Origin "result source origin"
   Assert-Equal ([IO.File]::ReadAllText((Join-Path $destinationHome "copied-lab\index.html"))) "DIRECT_TRANSFER" "transferred text"
   if (([IO.File]::ReadAllBytes((Join-Path $destinationHome "copied-lab\binary.dat")) -join ',') -ne '0,17,128,255') { throw "transferred binary differs" }
   if (-not (Test-Path -PathType Container (Join-Path $destinationHome "copied-lab\empty-dir"))) { throw "transfer lost empty directory" }

   $replay = Invoke-Tool $destination $destinationSession "importLabTransfer" (Transfer-Arguments $prepared "replay-lab" $true $source.Origin)
   Assert-Equal $replay.code "transferExpired" "transfer ticket is single use"
   if (Test-Path (Join-Path $destinationHome "replay-lab")) { throw "replayed transfer created a lab" }

   $digestPrepared = (Invoke-Tool $source $sourceSession "prepareLabTransfer").data
   $badDigestArgs = Transfer-Arguments $digestPrepared "digest-lab" $true $source.Origin
   $badDigestArgs.digest = "sha256:" + ("0" * 64)
   $digestFailure = Invoke-Tool $destination $destinationSession "importLabTransfer" $badDigestArgs
   Assert-Equal $digestFailure.code "transferDigestMismatch" "descriptor digest mismatch"
   if (Test-Path (Join-Path $destinationHome "digest-lab")) { throw "digest failure created a lab" }

   $expiredPrepared = (Invoke-Tool $source $sourceSession "prepareLabTransfer").data
   Start-Sleep -Seconds 3
   $expired = Invoke-Tool $destination $destinationSession "importLabTransfer" (Transfer-Arguments $expiredPrepared "expired-lab" $true $source.Origin)
   Assert-Equal $expired.code "transferExpired" "expired source ticket"

   $invalidUrlArgs = Transfer-Arguments $expiredPrepared "invalid-url-lab" $true $source.Origin
   $invalidUrlArgs.transferUrl = "http://user@127.0.0.1:$SourcePort/lsp-claw/transfer.lsp"
   $invalidUrl = Invoke-Tool $destination $destinationSession "importLabTransfer" $invalidUrlArgs
   Assert-Equal $invalidUrl.code "invalidTransferUrl" "URL user-info is rejected"

   $disallowedPortArgs = Transfer-Arguments $expiredPrepared "disallowed-port-lab" $true "http://127.0.0.1:$($SourcePort + 1)"
   $disallowedPortArgs.transferUrl = "http://127.0.0.1:$($SourcePort + 1)/lsp-claw/transfer.lsp"
   $disallowedPort = Invoke-Tool $destination $destinationSession "importLabTransfer" $disallowedPortArgs
   Assert-Equal $disallowedPort.code "invalidTransferUrl" "destination port allowlist"

   $redirectArgs = Transfer-Arguments $expiredPrepared "redirect-lab" $true $source.Origin
   $redirectArgs.transferUrl = "$($source.Origin)/lsp-claw/redirect.lsp"
   $redirectArgs.transferTicket = "A" * 32
   $redirect = Invoke-Tool $destination $destinationSession "importLabTransfer" $redirectArgs
   Assert-Equal $redirect.code "transferRedirectForbidden" "destination does not follow redirects"
   if (Test-Path (Join-Path $destinationHome "redirect-lab")) { throw "redirect response created a lab" }

   $partialArgs = Transfer-Arguments $expiredPrepared "partial-lab" $true $source.Origin
   $partialArgs.transferUrl = "$($source.Origin)/lsp-claw/partial.lsp"
   $partialArgs.transferTicket = "B" * 32
   $partialArgs.expectedBytes = 100
   $partialArgs.digest = "sha256:" + ("0" * 64)
   $partial = Invoke-Tool $destination $destinationSession "importLabTransfer" $partialArgs
   if ($partial.code -notin @("transferDownloadFailed","transferDigestMismatch")) { throw "interrupted transfer returned unexpected code $($partial.code)" }
   if (Test-Path (Join-Path $destinationHome "partial-lab")) { throw "interrupted response created a lab" }

   Write-Output "LAB_TRANSFER_TEST_PASS servers=2 tokens=different direct=true noCredentialForwarding=true confirmation=true singleUse=true digest=true expiration=true redirects=false interruption=true"
}
finally {
   foreach ($process in $processes) { if ($process -and -not $process.HasExited) { Stop-Process -Id $process.Id -Force } }
   $env:MCP_AUTH_TOKEN = $previousToken
   $env:LSP_CLAW_TRANSFER_TTL_SECONDS = $previousTtl
   $env:LSP_CLAW_TRANSFER_ALLOWED_PORTS = $previousAllowedPorts
   Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
