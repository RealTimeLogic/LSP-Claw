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

   $uri = "http://127.0.0.1:$MakoPort/lsp-claw/"
   $invalid = Invoke-WebRequest -UseBasicParsing -Uri $uri -Method Post -Body @{
      action="save"
      githubToken="invalid-test-token"
      authToken="must-not-be-saved"
   }
   Assert-True ($invalid.Content -match "Token settings were not saved") "Invalid-token save did not show the general error"
   Assert-True ($invalid.Content -match "GitHub rejected this token: Bad credentials") "Invalid-token save did not show the GitHub error"
   Assert-True ($invalid.Content -match 'aria-invalid="true"') "Invalid GitHub field was not marked invalid"
   Assert-True (-not (Test-Path -LiteralPath (Join-Path $stage "LSP-Claw-Keys.bin"))) "Invalid submission persisted token settings"

   $afterInvalid = Invoke-WebRequest -UseBasicParsing -Uri $uri
   Assert-True ($afterInvalid.Content -match "GitHub token: not set") "Invalid submission changed GitHub token state"
   Assert-True ($afterInvalid.Content -notmatch "<h2>Sign in</h2>") "Invalid submission changed MCP authentication"

   $valid = Invoke-WebRequest -UseBasicParsing -Uri $uri -Method Post -Body @{
      action="save"
      githubToken="valid-test-token"
      authToken=""
   }
   Assert-True ($valid.Content -match "GitHub token validated for token-ui-test") "Valid token did not show validation success"
   Assert-True ($valid.Content -match "GitHub token: set") "Valid token was not activated"
   Assert-True (Test-Path -LiteralPath (Join-Path $stage "LSP-Claw-Keys.bin")) "Valid token was not persisted"

   $cleared = Invoke-WebRequest -UseBasicParsing -Uri $uri -Method Post -Body @{
      action="save"
      githubToken=""
      authToken=""
   }
   Assert-True ($cleared.Content -match "Token settings saved") "Blank token settings were not saved"
   Assert-True ($cleared.Content -match "GitHub token: not set") "Blank GitHub token did not clear the setting"

   Write-Output "TOKEN_SETUP_TEST_PASS invalidRejected=true unchanged=true validAccepted=true activated=true clear=true"
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
