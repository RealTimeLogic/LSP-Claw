param(
   [string]$Mako = "mako",
   [string]$Python = "python",
   [int]$MakoPort = 18085,
   [int]$MockGitHubPort = 18084
)

$ErrorActionPreference = "Stop"
$repo = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$stage = Join-Path $env:TEMP ("lsp-claw-token-ui-test-" + [guid]::NewGuid().ToString("N"))
$stdout = Join-Path $stage "stdout.log"
$stderr = Join-Path $stage "stderr.log"
$process = $null
$mockProcess = $null
$oldGitHubApi = $env:LSP_CLAW_GITHUB_API
$oldGitHubToken = $env:GITHUB_TOKEN
$oldGhToken = $env:GH_TOKEN
$oldMcpToken = $env:MCP_AUTH_TOKEN

function Assert-True($Condition,[string]$Message) {
   if (-not $Condition) { throw $Message }
}

try {
   New-Item -ItemType Directory -Path $stage | Out-Null
   Copy-Item -LiteralPath (Join-Path $repo "www") -Destination (Join-Path $stage "www") -Recurse
   [IO.File]::WriteAllText((Join-Path $stage "mako.conf"),"port=$MakoPort`r`nsslport=0`r`n",[Text.UTF8Encoding]::new($false))

   $mockStdout = Join-Path $stage "mock-stdout.log"
   $mockStderr = Join-Path $stage "mock-stderr.log"
   $mockProcess = Start-Process -FilePath $Python -ArgumentList @((Join-Path $PSScriptRoot "mock-github-token-server.py"),[string]$MockGitHubPort) -PassThru -WindowStyle Hidden -RedirectStandardOutput $mockStdout -RedirectStandardError $mockStderr
   $mockDeadline = (Get-Date).AddSeconds(10)
   do {
      Start-Sleep -Milliseconds 100
      if ($mockProcess.HasExited) { throw "Mock GitHub server exited.`n$(Get-Content -LiteralPath $mockStderr -Raw)" }
      $mockListener = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object {$_.OwningProcess -eq $mockProcess.Id -and $_.LocalPort -eq $MockGitHubPort}
   } while (-not $mockListener -and (Get-Date) -lt $mockDeadline)
   Assert-True $mockListener "Mock GitHub server did not start"

   $env:LSP_CLAW_GITHUB_API = "http://127.0.0.1:$MockGitHubPort"
   $env:GITHUB_TOKEN = $null
   $env:GH_TOKEN = $null
   $env:MCP_AUTH_TOKEN = $null
   $process = Start-Process -FilePath $Mako -ArgumentList "-llsp-claw::www" -WorkingDirectory $stage -PassThru -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr
   $deadline = (Get-Date).AddSeconds(20)
   do {
      Start-Sleep -Milliseconds 200
      if ($process.HasExited) { throw "Token UI test server exited.`n$(Get-Content -LiteralPath $stderr -Raw)" }
      $listener = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object {$_.OwningProcess -eq $process.Id -and $_.LocalPort -eq $MakoPort}
   } while (-not $listener -and (Get-Date) -lt $deadline)
   Assert-True $listener "Token UI test server did not start"

   $baseUri = "http://127.0.0.1:$MakoPort/lsp-claw/"
   $configUri = $baseUri + "lsp-claw-config.lsp"
   $rootRequest = [Net.HttpWebRequest]::Create($baseUri)
   $rootRequest.AllowAutoRedirect = $false
   $rootResponse = $rootRequest.GetResponse()
   try {
      Assert-True ([int]$rootResponse.StatusCode -eq 302) "Root page did not return HTTP 302; got $([int]$rootResponse.StatusCode)"
      $redirectUri = [Uri]::new([Uri]$baseUri,$rootResponse.Headers["Location"]).AbsoluteUri
      Assert-True ($redirectUri -eq $configUri) "Root page did not redirect to lsp-claw-config.lsp; got '$redirectUri'"
   }
   finally { $rootResponse.Dispose() }
   $invalid = Invoke-WebRequest -UseBasicParsing -Uri $configUri -Method Post -Body @{
      action="save"
      githubToken="invalid-test-token"
      authToken="must-not-be-saved"
   }
   Assert-True ($invalid.Content -match "Token settings were not saved") "Invalid-token save did not show the general error"
   Assert-True ($invalid.Content -match "GitHub rejected this token: Bad credentials") "Invalid-token save did not show the GitHub error"
   Assert-True ($invalid.Content -match 'aria-invalid="true"') "Invalid GitHub field was not marked invalid"
   Assert-True (-not (Test-Path -LiteralPath (Join-Path $stage "LSP-Claw-Keys.bin"))) "Invalid submission persisted token settings"

   $afterInvalid = Invoke-WebRequest -UseBasicParsing -Uri $configUri
   Assert-True ($afterInvalid.Content -match "GitHub token: not set") "Invalid submission changed GitHub token state"
   Assert-True ($afterInvalid.Content -notmatch "<h2>Sign in</h2>") "Invalid submission changed MCP authentication"

   $valid = Invoke-WebRequest -UseBasicParsing -Uri $configUri -Method Post -Body @{
      action="save"
      githubToken="valid-test-token"
      authToken=""
   }
   Assert-True ($valid.Content -match "GitHub token validated for token-ui-test") "Valid token did not show validation success"
   Assert-True ($valid.Content -match "GitHub token: set") "Valid token was not activated"
   Assert-True (Test-Path -LiteralPath (Join-Path $stage "LSP-Claw-Keys.bin")) "Valid token was not persisted"

   $cleared = Invoke-WebRequest -UseBasicParsing -Uri $configUri -Method Post -Body @{
      action="save"
      githubToken=""
      authToken=""
   }
   Assert-True ($cleared.Content -match "Token settings saved") "Blank token settings were not saved"
   Assert-True ($cleared.Content -match "GitHub token: not set") "Blank GitHub token did not clear the setting"

   $labSource = Join-Path $stage "ui-toggle-lab-source"
   $labZip = Join-Path $stage "ui-toggle-lab.zip"
   New-Item -ItemType Directory -Path $labSource | Out-Null
   $labContent = "<h1>UI toggle test</h1>"
   $labBytes = [Text.Encoding]::UTF8.GetBytes($labContent)
   [IO.File]::WriteAllBytes((Join-Path $labSource "index.lsp"),$labBytes)
   $manifest = @{
      format="lsp-claw-lab"
      version=1
      exportedLabName="ui-toggle-lab"
      createdAt=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
      fileCount=1
      uncompressedBytes=$labBytes.Length
      emptyDirectories=@()
   } | ConvertTo-Json -Compress
   [IO.File]::WriteAllText((Join-Path $labSource ".lsp-claw-lab.json"),$manifest,[Text.UTF8Encoding]::new($false))
   Add-Type -AssemblyName System.IO.Compression.FileSystem
   [IO.Compression.ZipFile]::CreateFromDirectory($labSource,$labZip)
   $labApiUri = $baseUri + "lab-api.lsp"
   $prepared = Invoke-RestMethod -Uri $labApiUri -Method Post -Body @{
      action="prepareImport"
      labName="ui-toggle-lab"
      conflictAction="createNew"
      confirmed="false"
   }
   Assert-True $prepared.ok "Browser lab import was not prepared"
   $uploadUri = [Uri]::new([Uri]$baseUri,[string]$prepared.result.uploadPath).AbsoluteUri
   $imported = Invoke-RestMethod -Uri $uploadUri -Method Post -ContentType "application/zip" -InFile $labZip
   Assert-True ($imported.ok -and $imported.result.labName -eq "ui-toggle-lab") "Browser lab import failed"

   $stoppedUi = Invoke-WebRequest -UseBasicParsing -Uri $configUri
   Assert-True ($stoppedUi.Content -match 'class="secondary toggle-lab"[^>]+data-lab-name="ui-toggle-lab"[^>]*>Start lab</button>') "Stopped lab did not show the Start lab button"
   $started = Invoke-RestMethod -Uri $labApiUri -Method Post -Body @{
      action="setRunning"
      labName="ui-toggle-lab"
      running="true"
   }
   Assert-True ($started.ok -and $started.result.running -and $started.result.changed) "Browser lab start failed"
   $startedUi = Invoke-WebRequest -UseBasicParsing -Uri $configUri
   Assert-True ($startedUi.Content -match 'class="secondary toggle-lab stop"[^>]+data-lab-name="ui-toggle-lab"[^>]*>Stop lab</button>') "Running lab did not show the Stop lab button"
   $stopped = Invoke-RestMethod -Uri $labApiUri -Method Post -Body @{
      action="setRunning"
      labName="ui-toggle-lab"
      running="false"
   }
   Assert-True ($stopped.ok -and -not $stopped.result.running -and $stopped.result.changed) "Browser lab stop failed"
   $stoppedAgain = Invoke-RestMethod -Uri $labApiUri -Method Post -Body @{
      action="setRunning"
      labName="ui-toggle-lab"
      running="false"
   }
   Assert-True ($stoppedAgain.ok -and -not $stoppedAgain.result.running -and -not $stoppedAgain.result.changed) "Browser lab stop was not idempotent"

   Write-Output "TOKEN_SETUP_TEST_PASS invalidRejected=true unchanged=true validAccepted=true activated=true clear=true labStartStop=true"
}
finally {
   $env:LSP_CLAW_GITHUB_API = $oldGitHubApi
   $env:GITHUB_TOKEN = $oldGitHubToken
   $env:GH_TOKEN = $oldGhToken
   $env:MCP_AUTH_TOKEN = $oldMcpToken
   if ($process -and -not $process.HasExited) { Stop-Process -Id $process.Id -Force }
   if ($mockProcess -and -not $mockProcess.HasExited) { Stop-Process -Id $mockProcess.Id -Force }
   if (Test-Path -LiteralPath $stage) {
      $resolved = (Resolve-Path -LiteralPath $stage).Path
      $tempRoot = (Resolve-Path -LiteralPath $env:TEMP).Path
      if (-not $resolved.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase)) { throw "Refusing to remove non-temp path $resolved" }
      Remove-Item -LiteralPath $resolved -Recurse -Force
   }
}
