param(
   [string]$Mako = "mako",
   [int]$Port = 80
)

$ErrorActionPreference = "Stop"
$PSDefaultParameterValues['Invoke-WebRequest:TimeoutSec'] = 15
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$repo = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$stage = Join-Path $env:TEMP ("lsp-claw-http-test-" + [guid]::NewGuid().ToString("N"))
$stdout = Join-Path $stage "stdout.log"
$stderr = Join-Path $stage "stderr.log"
$script:requestId = 0
$script:testToken = "lsp-claw-regression-token"
$previousAuthToken = $env:MCP_AUTH_TOKEN
$env:MCP_AUTH_TOKEN = $script:testToken
$process = $null

New-Item -ItemType Directory -Path $stage -Force | Out-Null
Copy-Item (Join-Path $repo "www") (Join-Path $stage "www") -Recurse
$staleImportStage = Join-Path $stage "LSPClawImport-stage-stale"
New-Item -ItemType Directory -Path $staleImportStage | Out-Null
[IO.File]::WriteAllText((Join-Path $staleImportStage "partial.txt"),"discard")

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
   $accept = @{Accept="application/json, text/event-stream";Authorization="Bearer $script:testToken"}
   $script:requestId++
   $responseBody = @{jsonrpc="2.0";id=$script:requestId;method="initialize";params=@{protocolVersion="2025-11-25";capabilities=@{};clientInfo=@{name="regression";version="1"}}} | ConvertTo-Json -Depth 10
   $response = Invoke-WebRequest -UseBasicParsing -Uri $script:mcpUri -Method Post -ContentType "application/json" -Headers $accept -Body $responseBody
   if (-not (ConvertFrom-Json $response.Content).result) { throw "initialize failed" }
   $sessionId = $response.Headers["MCP-Session-Id"]
   if (-not $sessionId) { throw "initialize did not return MCP-Session-Id" }
   return @{Accept="application/json, text/event-stream";Authorization="Bearer $script:testToken";"MCP-Session-Id"=$sessionId;"MCP-Protocol-Version"="2025-11-25"}
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

function New-CompressedZip([string]$Source,[string]$Destination) {
   $input = [IO.File]::OpenRead($Source)
   $output = [IO.File]::Open($Destination,[IO.FileMode]::CreateNew)
   try {
      $sourceZip = [IO.Compression.ZipArchive]::new($input,[IO.Compression.ZipArchiveMode]::Read,$true)
      $targetZip = [IO.Compression.ZipArchive]::new($output,[IO.Compression.ZipArchiveMode]::Create,$true)
      try {
         foreach ($entry in $sourceZip.Entries) {
            if ($entry.FullName.EndsWith("/")) { $null = $targetZip.CreateEntry($entry.FullName); continue }
            $target = $targetZip.CreateEntry($entry.FullName,[IO.Compression.CompressionLevel]::Optimal)
            $reader = $entry.Open()
            $writer = $target.Open()
            try { $reader.CopyTo($writer) } finally { $writer.Dispose(); $reader.Dispose() }
         }
      }
      finally { $targetZip.Dispose(); $sourceZip.Dispose() }
   }
   finally { $output.Dispose(); $input.Dispose() }
}

function New-SyntheticLabZip([string]$Destination,[object[]]$Entries,[int]$ManifestFileCount,[long]$ManifestBytes) {
   $output = [IO.File]::Open($Destination,[IO.FileMode]::CreateNew)
   try {
      $archive = [IO.Compression.ZipArchive]::new($output,[IO.Compression.ZipArchiveMode]::Create,$false)
      try {
         foreach ($item in $Entries) {
            $entry = $archive.CreateEntry($item.Name,[IO.Compression.CompressionLevel]::Optimal)
            $writer = [IO.StreamWriter]::new($entry.Open(),[Text.UTF8Encoding]::new($false))
            try { $writer.Write([string]$item.Content) } finally { $writer.Dispose() }
         }
         $manifest = @{format="lsp-claw-lab";version=1;exportedLabName="synthetic";fileCount=$ManifestFileCount;uncompressedBytes=$ManifestBytes;emptyDirectories=@()} | ConvertTo-Json -Compress
         $manifestEntry = $archive.CreateEntry(".lsp-claw-lab.json",[IO.Compression.CompressionLevel]::Optimal)
         $manifestWriter = [IO.StreamWriter]::new($manifestEntry.Open(),[Text.UTF8Encoding]::new($false))
         try { $manifestWriter.Write($manifest) } finally { $manifestWriter.Dispose() }
      }
      finally { $archive.Dispose() }
   }
   finally { $output.Dispose() }
}

function Assert-ZipUploadRejected([string]$Url,[string]$ZipPath,[string]$Message,[hashtable]$Headers) {
   try {
      $null = Invoke-WebRequest -UseBasicParsing -Uri $Url -Method Post -ContentType "application/zip" -Headers $Headers -InFile $ZipPath
      throw "$Message was accepted"
   }
   catch {
      if (-not $_.Exception.Response -or $_.Exception.Response.StatusCode.value__ -ne 400) { throw }
   }
}

try {
   $process = Start-Process -FilePath $Mako -ArgumentList "-llsp-claw::www" -WorkingDirectory $stage -PassThru -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr
   $deadline = (Get-Date).AddSeconds(15)
   do {
      Start-Sleep -Milliseconds 200
      $log = (Get-Content $stdout -Raw -ErrorAction SilentlyContinue) + (Get-Content $stderr -Raw -ErrorAction SilentlyContinue)
   } until ($log -match "Loading www as.*ok" -or $process.HasExited -or (Get-Date) -gt $deadline)
   if ($process.HasExited -or $log -notmatch "Loading www as.*ok") { throw "LSP-Claw did not start.`n$log" }
   if (Test-Path $staleImportStage) { throw "stale detached import stage was not recovered" }

   $origin = if ($Port -eq 80) { "http://127.0.0.1" } else { "http://127.0.0.1:$Port" }
   $script:mcpUri = "$origin/lsp-claw/mcp.lsp"
   $archiveHeaders = @{Authorization="Bearer $script:testToken"}
   $rootRequest = [Net.HttpWebRequest]::Create("$origin/lsp-claw/")
   $rootRequest.AllowAutoRedirect = $false
   $rootResponse = $rootRequest.GetResponse()
   try {
      $redirectUri = [Uri]::new([Uri]"$origin/lsp-claw/",$rootResponse.Headers["Location"]).AbsoluteUri
      if ([int]$rootResponse.StatusCode -ne 302 -or $redirectUri -ne "$origin/lsp-claw/lsp-claw-config.lsp") { throw "browser root did not redirect to the canonical configuration page" }
   }
   finally { $rootResponse.Dispose() }
   $setupPage = Invoke-WebRequest -UseBasicParsing -Uri "$origin/lsp-claw/lsp-claw-config.lsp" -SessionVariable BrowserSession
   if ($setupPage.Content -notmatch "Sign in") { throw "token-protected browser page did not require login" }
   $setupPage = Invoke-WebRequest -UseBasicParsing -Uri "$origin/lsp-claw/lsp-claw-config.lsp" -Method Post -WebSession $BrowserSession -Body @{action="login";loginToken=$script:testToken}
   if ($setupPage.Content -notmatch "Lab archives" -or $setupPage.Content -notmatch "Upload and import ZIP") { throw "browser lab manager did not render" }
   $session1 = New-McpSession
   $session2 = New-McpSession
   $session3 = New-McpSession

   $tools = (Invoke-McpRequest -Headers $session1 -Method "tools/list").result.tools
   Assert-Equal $tools.Count 25 "Phase 4 MCP tool count"
   foreach ($required in @("listLabs","selectLab","createLab","renameLab","deleteLab","setLabBasePath","prepareLabExport","prepareLabImport","prepareLabTransfer","importLabTransfer")) {
      if ($required -notin $tools.name) { throw "Missing lab-management tool $required" }
   }

   $runtime = Invoke-Tool $session1 "getRuntimeInfo"
   Assert-Equal $runtime.runtime.labCount 0 "getRuntimeInfo must not create a lab"
   Assert-Equal $runtime.runtime.configuration.setupPage.path "/lsp-claw/lsp-claw-config.lsp" "getRuntimeInfo configuration page path"
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
   New-Item -ItemType Directory -Path (Join-Path $stage "lab1\empty-dir") | Out-Null
   [IO.File]::WriteAllBytes((Join-Path $stage "lab1\binary.dat"),[byte[]](0,1,2,127,128,255))
   $knownZipMtime = [DateTime]::new(2024,5,6,7,8,10,[DateTimeKind]::Local)
   [IO.File]::SetLastWriteTime((Join-Path $stage "lab1\binary.dat"),$knownZipMtime)
   [IO.File]::WriteAllText((Join-Path $stage "lab1\.hidden"),"hidden")
   $read1 = Invoke-Tool $session1 "readLabFile" @{path="index.html"}
   $read2 = Invoke-Tool $session2 "readLabFile" @{path="index.html"}
   Assert-Equal $read1.data.content "LAB_ONE" "session 1 lab content"
   Assert-Equal $read2.data.content "LAB_TWO" "session 2 lab content"

   $override = Invoke-Tool $session1 "readLabFile" @{labName="lab2";path="index.html"}
   Assert-Equal $override.data.content "LAB_TWO" "explicit lab override"
   $statusAfterOverride = Invoke-Tool $session1 "getLabStatus"
   Assert-Equal $statusAfterOverride.data.labName "lab1" "explicit override does not change session selection"

   $export = Invoke-Tool $session1 "prepareLabExport"
   Assert-Equal $export.data.compression "none" "server export is stored without compression"
   Assert-Equal $export.data.manifest.emptyDirectories[0] "empty-dir" "empty directory is recorded in manifest"
   $storedZip = Join-Path $stage "lab1-export.zip"
   $unauthorized = $false
   try { $null = Invoke-WebRequest -UseBasicParsing -Uri $export.data.downloadUrl } catch { $unauthorized = $_.Exception.Response.StatusCode.value__ -eq 401 }
   if (-not $unauthorized) { throw "archive download did not enforce authentication" }
   Invoke-WebRequest -UseBasicParsing -Uri $export.data.downloadUrl -Headers $archiveHeaders -OutFile $storedZip
   if (-not (Test-Path $storedZip) -or (Get-Item $storedZip).Length -eq 0) { throw "archive download was empty" }
   if ((Get-FileHash -Algorithm SHA256 $storedZip).Hash.ToLowerInvariant() -ne $export.data.sha256) { throw "archive SHA-256 mismatch" }
   $storedZipFile = [IO.File]::OpenRead($storedZip)
   try {
      $storedArchive = [IO.Compression.ZipArchive]::new($storedZipFile,[IO.Compression.ZipArchiveMode]::Read,$false)
      try {
         foreach ($entry in $storedArchive.Entries) {
            if ($entry.LastWriteTime.Year -lt 2020) { throw "archive entry $($entry.FullName) has an invalid modification date" }
         }
         $binaryEntry = $storedArchive.GetEntry("binary.dat")
         if (-not $binaryEntry -or $binaryEntry.LastWriteTime.LocalDateTime -ne $knownZipMtime) { throw "archive did not preserve the lab file modification date" }
      }
      finally { $storedArchive.Dispose() }
   }
   finally { $storedZipFile.Dispose() }
   $reused = $false
   try { $null = Invoke-WebRequest -UseBasicParsing -Uri $export.data.downloadUrl -Headers $archiveHeaders } catch { $reused = $_.Exception.Response.StatusCode.value__ -eq 404 }
   if (-not $reused) { throw "archive download ticket was reusable" }
   $browserZip = Join-Path $stage "lab1-browser-export.zip"
   $browserExportResponse = Invoke-WebRequest -UseBasicParsing -Uri "$origin/lsp-claw/lab-api.lsp" -Method Post -WebSession $BrowserSession -Body @{action="prepareExport";labName="lab1"}
   $browserExport = (ConvertFrom-Json $browserExportResponse.Content).result
   Invoke-WebRequest -UseBasicParsing -Uri ($origin + $browserExport.downloadPath) -WebSession $BrowserSession -OutFile $browserZip
   if (-not (Test-Path $browserZip) -or (Get-Item $browserZip).Length -eq 0) { throw "browser lab download was empty" }

   $import = Invoke-Tool $session3 "prepareLabImport" @{labName="lab3";conflictAction="createNew"}
   $importReply = Invoke-WebRequest -UseBasicParsing -Uri $import.data.uploadUrl -Method Post -ContentType "application/zip" -Headers $archiveHeaders -InFile $storedZip
   $importResult = (ConvertFrom-Json $importReply.Content).result
   Assert-Equal $importResult.created $true "stored archive creates a new lab"
   Assert-Equal $importResult.fileCount 3 "stored archive file count"
   Assert-Equal ([IO.File]::ReadAllText((Join-Path $stage "lab3\index.html"))) "LAB_ONE" "stored import content"
   if (-not (Test-Path -PathType Container (Join-Path $stage "lab3\empty-dir"))) { throw "stored import lost empty directory" }
   if (-not ([IO.File]::ReadAllBytes((Join-Path $stage "lab3\binary.dat")) -ceq [byte[]](0,1,2,127,128,255))) {
      $actualBinary = [IO.File]::ReadAllBytes((Join-Path $stage "lab3\binary.dat"))
      if (($actualBinary -join ',') -ne '0,1,2,127,128,255') { throw "stored import changed binary content" }
   }
   if (Test-Path (Join-Path $stage "lab3\.lsp-claw-lab.json")) { throw "archive manifest leaked into imported lab" }

   $compressedZip = Join-Path $stage "lab1-compressed.zip"
   New-CompressedZip $storedZip $compressedZip
   $browserPrepare = Invoke-WebRequest -UseBasicParsing -Uri "$origin/lsp-claw/lab-api.lsp" -Method Post -WebSession $BrowserSession -Body @{action="prepareImport";labName="lab4";conflictAction="createNew";confirmed="false"}
   $compressedImport = (ConvertFrom-Json $browserPrepare.Content).result
   $compressedReply = Invoke-WebRequest -UseBasicParsing -Uri ($origin + $compressedImport.uploadPath) -Method Post -ContentType "application/zip" -WebSession $BrowserSession -InFile $compressedZip
   Assert-Equal (ConvertFrom-Json $compressedReply.Content).result.created $true "ZipIo imports compressed archive"
   Assert-Equal ([IO.File]::ReadAllText((Join-Path $stage "lab4\index.html"))) "LAB_ONE" "compressed import content"

   $unsafeZip = Join-Path $stage "unsafe.zip"
   New-SyntheticLabZip $unsafeZip @([pscustomobject]@{Name="../escape.txt";Content="x"}) 1 1
   $unsafeImport = Invoke-Tool $session3 "prepareLabImport" @{labName="lab-unsafe";conflictAction="createNew"}
   Assert-ZipUploadRejected $unsafeImport.data.uploadUrl $unsafeZip "parent-traversal archive" $archiveHeaders
   if (Test-Path (Join-Path $stage "escape.txt")) { throw "unsafe archive escaped staging" }
   if (Test-Path (Join-Path $stage "lab-unsafe")) { throw "failed unsafe import left a lab behind" }

   $mismatchZip = Join-Path $stage "mismatch.zip"
   New-SyntheticLabZip $mismatchZip @([pscustomobject]@{Name="ok.txt";Content="x"}) 2 1
   $mismatchImport = Invoke-Tool $session3 "prepareLabImport" @{labName="lab-mismatch";conflictAction="createNew"}
   Assert-ZipUploadRejected $mismatchImport.data.uploadUrl $mismatchZip "manifest-mismatch archive" $archiveHeaders
   if (Test-Path (Join-Path $stage "lab-mismatch")) { throw "failed manifest import left a lab behind" }

   $duplicateZip = Join-Path $stage "duplicate.zip"
   New-SyntheticLabZip $duplicateZip @([pscustomobject]@{Name="same.txt";Content="a"},[pscustomobject]@{Name="SAME.TXT";Content="b"}) 2 2
   $duplicateImport = Invoke-Tool $session3 "prepareLabImport" @{labName="lab-duplicate";conflictAction="createNew"}
   Assert-ZipUploadRejected $duplicateImport.data.uploadUrl $duplicateZip "case-conflicting archive" $archiveHeaders
   if (Test-Path (Join-Path $stage "lab-duplicate")) { throw "failed duplicate import left a lab behind" }

   $bombContent = "x" * (1024 * 1024)
   $ratioZip = Join-Path $stage "ratio.zip"
   New-SyntheticLabZip $ratioZip @([pscustomobject]@{Name="expanded.txt";Content=$bombContent}) 1 $bombContent.Length
   $ratioImport = Invoke-Tool $session3 "prepareLabImport" @{labName="lab-ratio";conflictAction="createNew"}
   Assert-ZipUploadRejected $ratioImport.data.uploadUrl $ratioZip "excessive-expansion archive" $archiveHeaders
   if (Test-Path (Join-Path $stage "lab-ratio")) { throw "failed expansion-ratio import left a lab behind" }

   $null = Invoke-Tool $session1 "writeLabFile" @{path="index.html";content="CHANGED"}
   $null = Invoke-Tool $session1 "writeLabFile" @{path="stale.txt";content="MUST_BE_REMOVED"}
   $unconfirmed = Invoke-Tool $session1 "prepareLabImport" @{labName="lab1";conflictAction="replace"}
   Assert-Equal $unconfirmed.code "labReplaceRequiresConfirmation" "replacement confirmation"
   $replacement = Invoke-Tool $session1 "prepareLabImport" @{labName="lab1";conflictAction="replace";confirmed=$true}
   $replaceReply = Invoke-WebRequest -UseBasicParsing -Uri $replacement.data.uploadUrl -Method Post -ContentType "application/zip" -Headers $archiveHeaders -InFile $storedZip
   Assert-Equal (ConvertFrom-Json $replaceReply.Content).result.replaced $true "confirmed replacement"
   Assert-Equal (Invoke-Tool $session1 "readLabFile" @{path="index.html"}).data.content "LAB_ONE" "replacement is complete, not merged"
   if (Test-Path (Join-Path $stage "lab1\stale.txt")) { throw "replacement merged stale content" }

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
   Assert-Equal $afterDelete.data.labCount 3 "imported labs remain after deleting renamed lab"
   $null = Invoke-Tool $session3 "deleteLab" @{labName="lab3";confirmed=$true}
   $null = Invoke-Tool $session3 "deleteLab" @{labName="lab4";confirmed=$true}
   $finalLabs = Invoke-Tool $session2 "listLabs"
   Assert-Equal $finalLabs.data.labCount 1 "one lab remains after imported labs are deleted"
   Assert-Equal $finalLabs.data.activeLabName "lab1" "single remaining lab is selected automatically"
   Assert-Equal $finalLabs.data.labs[0].basePath "" "sole automatic lab returns to root"
   Assert-Equal $finalLabs.data.labs[0].basePathExplicit $false "restored root route remains automatic"

   Close-McpSession $session1
   Close-McpSession $session2
   Close-McpSession $session3
   Write-Output "LSP_CLAW_TEST_PASS tools=$($tools.Count) sessions=3 labs=4 routes=true archives=stored+compressed replacement=true security=traversal+duplicate+manifest+ratio"
}
finally {
   if ($process -and -not $process.HasExited) { Stop-Process -Id $process.Id -Force }
   Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
   $env:MCP_AUTH_TOKEN = $previousAuthToken
}
