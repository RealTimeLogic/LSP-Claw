param(
   [string]$Uri = "http://localhost/mcp.lsp"
)

$ErrorActionPreference = "Stop"
$PSDefaultParameterValues['Invoke-WebRequest:TimeoutSec'] = 30
$script:requestId = 0
$script:headers = @{Accept="application/json, text/event-stream"}
$source = "lspclaw-api-source"
$renamed = "lspclaw-api-renamed"
$transfer = "lspclaw-api-transfer"
$example = "lspclaw-api-example"
$upload = "lspclaw-api-upload"
$backup = "complete-api-test-backup"
$route = "lspclaw-api-route"
$testNames = @($source,$renamed,$transfer,$example,$upload)
$sessionCreated = $false

function Assert-True($Condition,[string]$Message) {
   if (-not $Condition) { throw $Message }
}

function Assert-Equal($Actual,$Expected,[string]$Message) {
   if ($Actual -ne $Expected) { throw "$Message. Expected '$Expected', got '$Actual'" }
}

function Invoke-Mcp([string]$Method,[hashtable]$Params=@{}) {
   $script:requestId++
   $body = @{jsonrpc="2.0";id=$script:requestId;method=$Method;params=$Params} | ConvertTo-Json -Depth 30
   $response = Invoke-WebRequest -UseBasicParsing -Uri $Uri -Method Post -ContentType "application/json" -Headers $script:headers -Body $body
   $decoded = $response.Content | ConvertFrom-Json
   if ($decoded.error) { throw "$Method returned protocol error $($decoded.error.code): $($decoded.error.message)" }
   return $decoded.result
}

function Invoke-Tool([string]$Name,[hashtable]$Arguments=@{}) {
   return (Invoke-Mcp "tools/call" @{name=$Name;arguments=$Arguments}).structuredContent
}

function Read-Resource([string]$ResourceUri) {
   $result = Invoke-Mcp "resources/read" @{uri=$ResourceUri}
   Assert-True ($result.contents.Count -eq 1) "Resource $ResourceUri did not return one content item"
   return [string]$result.contents[0].text
}

function Get-Labs {
   return (Invoke-Tool "listLabs").data
}

function Remove-TestLab([string]$Name) {
   $labs = (Get-Labs).labs
   $found = $labs | Where-Object {$_.name -eq $Name}
   if (-not $found) { return }
   $status = Invoke-Tool "getLabStatus" @{labName=$Name}
   if ($status.ok -and $status.data.running) { $null = Invoke-Tool "stopLab" @{labName=$Name} }
   $deleted = Invoke-Tool "deleteLab" @{labName=$Name;confirmed=$true}
   Assert-True ($deleted.ok -and $deleted.data.deleted) "Cleanup could not delete $Name"
}

try {
   $script:requestId++
   $initialize = @{jsonrpc="2.0";id=$script:requestId;method="initialize";params=@{
      protocolVersion="2025-11-25"
      capabilities=@{}
      clientInfo=@{name="registered-lsp-claw-regression";version="1"}
   }} | ConvertTo-Json -Depth 10
   $initResponse = Invoke-WebRequest -UseBasicParsing -Uri $Uri -Method Post -ContentType "application/json" -Headers $script:headers -Body $initialize
   $initResult = ($initResponse.Content | ConvertFrom-Json).result
   Assert-True $initResult "MCP initialize failed"
   $script:headers["MCP-Session-Id"] = $initResponse.Headers["MCP-Session-Id"]
   Assert-True $script:headers["MCP-Session-Id"] "MCP initialize returned no session ID"
   $script:headers["MCP-Protocol-Version"] = "2025-11-25"
   $sessionCreated = $true

   $expectedTools = @(
      "getRuntimeInfo","readRuntimeTrace","listLabs","selectLab","getLabStatus",
      "createLab","renameLab","deleteLab","setLabBasePath","prepareLabExport",
      "prepareLabImport","prepareLabTransfer","importLabTransfer","startLab","stopLab",
      "getExampleCatalog","readExampleFile","copyExampleToLab","listLabFiles","readLabFile",
      "writeLabFile","clearLab","backupLab","listLabBackups","restoreLab"
   )
   $tools = (Invoke-Mcp "tools/list").tools
   Assert-Equal $tools.Count 25 "Registered tool count"
   foreach ($name in $expectedTools) { Assert-True ($name -in $tools.name) "Missing tool $name" }

   $resources = (Invoke-Mcp "resources/list").resources
   $expectedResources = @("lspclaw://instructions","lspclaw://runtime","lspclaw://lab/status","lspclaw://examples/root")
   Assert-Equal $resources.Count 4 "Registered resource count"
   foreach ($name in $expectedResources) { Assert-True ($name -in $resources.uri) "Missing resource $name" }
   Assert-Equal (Invoke-Mcp "resources/templates/list").resourceTemplates.Count 0 "Resource-template count"

   $prompts = (Invoke-Mcp "prompts/list").prompts
   $expectedPrompts = @("chooseExampleForUserGoal","buildFromExampleWorkflow","makoXedgeRuntimeGuide")
   Assert-Equal $prompts.Count 3 "Registered prompt count"
   foreach ($name in $expectedPrompts) { Assert-True ($name -in $prompts.name) "Missing prompt $name" }

   $runtime = Invoke-Tool "getRuntimeInfo"
   Assert-True $runtime.ok "getRuntimeInfo failed"
   $initial = Get-Labs
   Assert-Equal $initial.labCount 1 "Live test requires the preserved legacy baseline"
   Assert-Equal $initial.labs[0].name "lsplab" "Baseline lab name"
   Assert-Equal $initial.labs[0].basePath "" "Baseline route before test"
   Assert-Equal $initial.labs[0].basePathExplicit $false "Baseline route must be automatic before test"
   Assert-Equal $initial.labs[0].running $false "Baseline must be stopped"
   foreach ($name in $testNames) { Assert-True ($name -notin $initial.labs.name) "Disposable lab already exists: $name" }

   Assert-True ((Read-Resource "lspclaw://instructions").Length -gt 0) "Instructions resource is empty"
   Assert-True ((Read-Resource "lspclaw://runtime").Length -gt 0) "Runtime resource is empty"

   $created = Invoke-Tool "createLab" @{labName=$source;basePath=$source}
   Assert-True ($created.ok -and $created.data.created) "createLab failed"
   Assert-Equal $created.data.routeChanged.labName "lsplab" "Automatic baseline route transition"
   $selected = Invoke-Tool "selectLab" @{labName=$source}
   Assert-Equal $selected.data.activeLabName $source "selectLab result"
   $status = Invoke-Tool "getLabStatus"
   Assert-Equal $status.data.labName $source "getLabStatus selection"
   Assert-Equal $status.data.fileCount 0 "New source lab is not empty"

   $indexContent = '<?lsp trace("LSP_CLAW_COMPLETE_MCP_TEST") response:setcontenttype"text/plain" ?>LSP-Claw complete MCP test OK'
   $null = Invoke-Tool "writeLabFile" @{path="state.txt";content="original-state"}
   $null = Invoke-Tool "writeLabFile" @{path="nested/value.txt";content="nested-value"}
   $null = Invoke-Tool "writeLabFile" @{path="index.lsp";content=$indexContent}
   $listed = Invoke-Tool "listLabFiles" @{includeDirectories=$true}
   Assert-Equal $listed.data.fileCount 3 "Source file count"
   Assert-True ("nested" -in $listed.data.directories) "Nested directory was not listed"
   Assert-Equal (Invoke-Tool "readLabFile" @{path="state.txt"}).data.content "original-state" "Initial file content"

   $overwriteRequired = Invoke-Tool "writeLabFile" @{path="state.txt";content="must-not-write"}
   Assert-Equal $overwriteRequired.code "overwriteRequired" "Overwrite protection"
   $null = Invoke-Tool "writeLabFile" @{path="state.txt";content="before-backup";overwrite=$true;confirmed=$true}
   $missingBackup = Invoke-Tool "backupLab" @{}
   Assert-Equal $missingBackup.code "backupNameRequired" "Backup-name requirement"
   $backedUp = Invoke-Tool "backupLab" @{backupName=$backup;copy=$true}
   Assert-True $backedUp.ok "backupLab failed"
   Assert-True ($backup -in (Invoke-Tool "listLabBackups").data.backups) "Backup not listed"
   $null = Invoke-Tool "writeLabFile" @{path="state.txt";content="after-backup";overwrite=$true;confirmed=$true}
   Assert-Equal (Invoke-Tool "clearLab" @{}).code "clearLabRequiresConfirmation" "Clear confirmation contract"
   Assert-True (Invoke-Tool "clearLab" @{confirmed=$true}).data.cleared "clearLab failed"
   Assert-Equal (Invoke-Tool "listLabFiles").data.fileCount 0 "Lab was not cleared"
   Assert-Equal (Invoke-Tool "restoreLab" @{backupName=$backup}).code "restoreLabRequiresConfirmation" "Restore confirmation contract"
   Assert-True (Invoke-Tool "restoreLab" @{backupName=$backup;confirmed=$true}).ok "restoreLab failed"
   Assert-Equal (Invoke-Tool "readLabFile" @{path="state.txt"}).data.content "before-backup" "Restored content"
   Assert-True ((Read-Resource "lspclaw://lab/status") -match $source) "Lab-status resource did not describe the source lab"

   $export = Invoke-Tool "prepareLabExport" @{labName=$source}
   Assert-True ($export.ok -and $export.data.size -gt 0 -and $export.data.sha256.Length -eq 64) "prepareLabExport metadata"
   Assert-Equal $export.data.compression "none" "Export compression"
   $preparedImport = Invoke-Tool "prepareLabImport" @{labName=$upload;conflictAction="createNew"}
   Assert-True ($preparedImport.ok -and $preparedImport.data.method -eq "POST" -and $preparedImport.data.maxUploadBytes -gt 0) "prepareLabImport metadata"

   $firstTransfer = Invoke-Tool "prepareLabTransfer" @{labName=$source}
   $unconfirmedArgs = @{
      transferUrl=$firstTransfer.data.transferUrl
      transferTicket=$firstTransfer.data.transferTicket
      expectedBytes=[long]$firstTransfer.data.expectedBytes
      digest=$firstTransfer.data.digest
      destinationLabName=$transfer
      conflictAction="createNew"
      confirmed=$false
      confirmedSourceOrigin=""
   }
   $gate = Invoke-Tool "importLabTransfer" $unconfirmedArgs
   Assert-Equal $gate.code "transferSourceRequiresConfirmation" "Transfer confirmation gate"
   $expectedOrigin = ([Uri]$Uri).GetLeftPart([UriPartial]::Authority)
   Assert-Equal $gate.sourceOrigin $expectedOrigin "Canonical transfer origin"
   $freshTransfer = Invoke-Tool "prepareLabTransfer" @{labName=$source}
   $transferArgs = @{
      transferUrl=$freshTransfer.data.transferUrl
      transferTicket=$freshTransfer.data.transferTicket
      expectedBytes=[long]$freshTransfer.data.expectedBytes
      digest=$freshTransfer.data.digest
      destinationLabName=$transfer
      conflictAction="createNew"
      confirmed=$true
      confirmedSourceOrigin=$expectedOrigin
   }
   $imported = Invoke-Tool "importLabTransfer" $transferArgs
   Assert-True ($imported.ok -and $imported.data.imported) "importLabTransfer failed"
   Assert-True (-not $imported.data.warning) "importLabTransfer returned warning: $($imported.data.warning)"
   Assert-Equal (Invoke-Tool "readLabFile" @{path="state.txt"}).data.content "before-backup" "Transferred content"
   $null = Invoke-Tool "selectLab" @{labName=$source}

   $started = Invoke-Tool "startLab" @{labName=$source}
   Assert-True ($started.ok -and $started.data.started) "startLab failed"
   Assert-True ($started.data.labApp.appUrl.EndsWith("/$source/")) "Source application URL"
   Assert-Equal (Invoke-WebRequest -UseBasicParsing $started.data.labApp.appUrl).Content "LSP-Claw complete MCP test OK" "Source HTTP content"
   $trace = Invoke-Tool "readRuntimeTrace"
   Assert-True ($trace.data.trace -match "LSP_CLAW_COMPLETE_MCP_TEST") "Runtime trace marker missing"
   Assert-Equal $trace.data.scope "server-global" "Runtime trace scope"
   $null = Invoke-Tool "readRuntimeTrace"
   Assert-True (Invoke-Tool "stopLab" @{labName=$source}).data.stopped "stopLab failed"
   Assert-True (Invoke-Tool "stopLab" @{labName=$source}).data.alreadyStopped "Repeated stopLab behavior"

   $renamedResult = Invoke-Tool "renameLab" @{labName=$source;newLabName=$renamed;confirmed=$true}
   Assert-Equal $renamedResult.data.newLabName $renamed "renameLab result"
   $routed = Invoke-Tool "setLabBasePath" @{labName=$renamed;basePath=$route;confirmed=$true}
   Assert-Equal $routed.data.basePath $route "setLabBasePath result"
   $restarted = Invoke-Tool "startLab" @{labName=$renamed}
   Assert-True ($restarted.data.labApp.appUrl.EndsWith("/$route/")) "Routed application URL"
   Assert-Equal (Invoke-WebRequest -UseBasicParsing $restarted.data.labApp.appUrl).Content "LSP-Claw complete MCP test OK" "Routed HTTP content"
   $null = Invoke-Tool "stopLab" @{labName=$renamed}

   $catalog = Invoke-Tool "getExampleCatalog" @{}
   Assert-True ($catalog.ok -and $catalog.data.entryCount -gt 0) "getExampleCatalog failed: $($catalog.code) $($catalog.error)"
   $filtered = Invoke-Tool "getExampleCatalog" @{path="AJAX"}
   Assert-Equal $filtered.data.entry.examplePath "AJAX" "Filtered catalog entry"
   Assert-True ((Invoke-Tool "readExampleFile" @{path="README.md"}).data.size -gt 0) "Root example README read"
   Assert-True ((Invoke-Tool "readExampleFile" @{path="AJAX/AGENTS.md"}).data.size -gt 0) "AJAX AGENTS read"
   Assert-True (Invoke-Tool "createLab" @{labName=$example;basePath=$example}).data.created "Example lab creation"
   $copied = Invoke-Tool "copyExampleToLab" @{sourcePath="AJAX/www";conflictAction="abort";labName=$example}
   Assert-True ($copied.ok -and $copied.data.copied) "copyExampleToLab failed: $($copied.code) $($copied.error)"
   Assert-True ((Invoke-Tool "listLabFiles" @{labName=$example}).data.fileCount -gt 0) "Copied example is empty"
   Assert-True ((Invoke-Tool "readLabFile" @{labName=$example;path="index.lsp"}).data.size -gt 0) "Copied example file read"
   Assert-True ((Read-Resource "lspclaw://examples/root").Length -gt 0) "Examples-root resource is empty"

   $choosePrompt = Invoke-Mcp "prompts/get" @{name="chooseExampleForUserGoal";arguments=@{userGoal="Verify a small BAS web application";targetRuntime="auto"}}
   $buildPrompt = Invoke-Mcp "prompts/get" @{name="buildFromExampleWorkflow";arguments=@{examplePath="AJAX/www";userGoal="Verify the copied example"}}
   $runtimePrompt = Invoke-Mcp "prompts/get" @{name="makoXedgeRuntimeGuide";arguments=@{}}
   Assert-True (($choosePrompt | ConvertTo-Json -Depth 20).Length -gt 100) "chooseExampleForUserGoal prompt is empty"
   Assert-True (($buildPrompt | ConvertTo-Json -Depth 20).Length -gt 100) "buildFromExampleWorkflow prompt is empty"
   Assert-True (($runtimePrompt | ConvertTo-Json -Depth 20).Length -gt 100) "makoXedgeRuntimeGuide prompt is empty"

   Remove-TestLab $example
   Remove-TestLab $transfer
   $finalDelete = Invoke-Tool "deleteLab" @{labName=$renamed;confirmed=$true}
   Assert-True ($finalDelete.ok -and $finalDelete.data.deleted) "Final source deletion failed"
   Assert-Equal $finalDelete.data.routeChanged.labName "lsplab" "Automatic baseline route restoration result"
   $final = Get-Labs
   Assert-Equal $final.labCount 1 "Final baseline lab count"
   Assert-Equal $final.labs[0].name "lsplab" "Final baseline name"
   Assert-Equal $final.labs[0].basePath "" "Final baseline root route"
   Assert-Equal $final.labs[0].basePathExplicit $false "Final baseline automatic route"
   Assert-Equal $final.labs[0].running $false "Final baseline running state"
   Assert-True ($upload -notin $final.labs.name) "Prepared upload unexpectedly created a lab"

   Write-Output "REGISTERED_LSP_CLAW_TEST_PASS tools=25 resources=4 prompts=3 templates=0 github=true transfer=true warning=false routeRestore=automatic cleanup=true"
}
finally {
   if ($sessionCreated) {
      foreach ($name in @($example,$transfer,$renamed,$source,$upload)) {
         try { Remove-TestLab $name } catch { Write-Warning "Cleanup failed for $name`: $($_.Exception.Message)" }
      }
      try { Invoke-WebRequest -UseBasicParsing -Uri $Uri -Method Delete -Headers $script:headers | Out-Null } catch {}
   }
}
