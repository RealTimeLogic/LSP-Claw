param(
   [string]$Mako = "mako",
   [int]$Port = 18086
)

$ErrorActionPreference = "Stop"
$PSDefaultParameterValues['Invoke-WebRequest:TimeoutSec'] = 15
$repo = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$root = Join-Path $env:TEMP ("lsp-claw-credential-test-" + [guid]::NewGuid().ToString("N"))
$processes = @()
$launchNumber = 0
$oldGitHubToken = $env:GITHUB_TOKEN
$oldGhToken = $env:GH_TOKEN
$oldMcpToken = $env:MCP_AUTH_TOKEN

function Assert-True($Condition,[string]$Message) {
   if (-not $Condition) { throw $Message }
}

function New-Runtime([string]$Name) {
   $path = Join-Path $root $Name
   New-Item -ItemType Directory -Path $path -Force | Out-Null
   Copy-Item -LiteralPath (Join-Path $repo "www") -Destination (Join-Path $path "www") -Recurse
   [IO.File]::WriteAllText((Join-Path $path "mako.conf"),"port=$Port`r`nsslport=0`r`n",[Text.UTF8Encoding]::new($false))
   return $path
}

function Start-TestServer([string]$Runtime,[string[]]$ExtraArgs=@()) {
   $script:launchNumber++
   $stdout = Join-Path $Runtime ("stdout-$($script:launchNumber).log")
   $stderr = Join-Path $Runtime ("stderr-$($script:launchNumber).log")
   $arguments = @("-llsp-claw::www") + $ExtraArgs
   $process = Start-Process -FilePath $Mako -ArgumentList $arguments -WorkingDirectory $Runtime -PassThru -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr
   $script:processes += $process
   $deadline = (Get-Date).AddSeconds(15)
   $log = ""
   $successPattern = '(?m)^Loading www as.*:\s+ok\s*$'
   $failurePattern = '(?m)^Loading www as.*:\s+failed:'
   do {
      Start-Sleep -Milliseconds 100
      $log = (Get-Content -LiteralPath $stdout -Raw -ErrorAction SilentlyContinue) + (Get-Content -LiteralPath $stderr -Raw -ErrorAction SilentlyContinue)
   } until ($log -match $successPattern -or $log -match $failurePattern -or $process.HasExited -or (Get-Date) -gt $deadline)
   return [pscustomobject]@{
      Process=$process
      Runtime=$Runtime
      Log=$log
      Started=($log -match $successPattern) -and -not $process.HasExited
      Origin="http://127.0.0.1:$Port"
      BaseUri="http://127.0.0.1:$Port/lsp-claw/"
      McpUri="http://127.0.0.1:$Port/lsp-claw/mcp.lsp"
   }
}

function Stop-TestServer($Server) {
   if ($Server -and $Server.Process -and -not $Server.Process.HasExited) {
      Stop-Process -Id $Server.Process.Id -Force
      $Server.Process.WaitForExit()
   }
   Start-Sleep -Milliseconds 150
}

function Login-Browser($Server,[string]$Username,[string]$Password) {
   $session = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
   $response = Invoke-WebRequest -UseBasicParsing -Uri ($Server.BaseUri + "lsp-claw-config.lsp") -Method Post -WebSession $session -Body @{
      action="login"
      username=$Username
      password=$Password
   }
   return [pscustomobject]@{Session=$session;Response=$response}
}

function New-InitializeBody {
   return @{
      jsonrpc="2.0"
      id=1
      method="initialize"
      params=@{
         protocolVersion="2025-11-25"
         capabilities=@{}
         clientInfo=@{name="credential-bootstrap-regression";version="1"}
      }
   } | ConvertTo-Json -Depth 10 -Compress
}

function Get-McpInitializeStatus($Server,[string]$Token,$BrowserSession=$null) {
   $headers = @{Accept="application/json, text/event-stream"}
   if ($Token) { $headers.Authorization="Bearer $Token" }
   try {
      if ($BrowserSession) {
         $response = Invoke-WebRequest -UseBasicParsing -Uri $Server.McpUri -Method Post -ContentType "application/json" -Headers $headers -WebSession $BrowserSession -Body (New-InitializeBody)
      }
      else {
         $response = Invoke-WebRequest -UseBasicParsing -Uri $Server.McpUri -Method Post -ContentType "application/json" -Headers $headers -Body (New-InitializeBody)
      }
      return [int]$response.StatusCode
   }
   catch {
      if ($_.Exception.Response) { return [int]$_.Exception.Response.StatusCode }
      throw
   }
}

function Assert-McpHandshake($Server,[string]$Token) {
   $headers = @{Accept="application/json, text/event-stream";Authorization="Bearer $Token"}
   $response = Invoke-WebRequest -UseBasicParsing -Uri $Server.McpUri -Method Post -ContentType "application/json" -Headers $headers -Body (New-InitializeBody)
   $message = ConvertFrom-Json $response.Content
   Assert-True ($response.StatusCode -eq 200 -and $message.result.protocolVersion -eq "2025-11-25") "MCP initialize failed with the configured token"
   $sessionId = $response.Headers["MCP-Session-Id"]
   Assert-True $sessionId "MCP initialize did not return a session ID"
   $headers["MCP-Session-Id"]=$sessionId
   $headers["MCP-Protocol-Version"]="2025-11-25"
   $initialized = @{jsonrpc="2.0";method="notifications/initialized"} | ConvertTo-Json -Compress
   $accepted = Invoke-WebRequest -UseBasicParsing -Uri $Server.McpUri -Method Post -ContentType "application/json" -Headers $headers -Body $initialized
   Assert-True ($accepted.StatusCode -eq 202) "MCP initialized notification was not accepted"
   $closed = Invoke-WebRequest -UseBasicParsing -Uri $Server.McpUri -Method Delete -Headers $headers
   Assert-True ($closed.StatusCode -eq 204) "MCP session was not deleted"
}

function Assert-NoPlaintext([string]$Path,[string[]]$Secrets,[string]$Label) {
   Assert-True (Test-Path -LiteralPath $Path) "$Label was not persisted"
   $text = [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($Path))
   foreach ($secret in $Secrets) {
      Assert-True (-not $text.Contains($secret)) "$Label contains a plaintext secret"
   }
}

function Assert-BootstrapFailure([string]$Name,[string[]]$Arguments,[string]$ExpectedMessage) {
   $runtime = New-Runtime $Name
   $server = Start-TestServer $runtime $Arguments
   try {
      Assert-True (-not $server.Started) "$Name unexpectedly started.`n$($server.Log)"
      Assert-True ($server.Log -match [regex]::Escape($ExpectedMessage)) "$Name did not report '$ExpectedMessage'.`n$($server.Log)"
      Assert-True (-not (Test-Path -LiteralPath (Join-Path $runtime "LSP-Claw-Admin.bin"))) "$Name created a partial administrator"
      Assert-True (-not (Test-Path -LiteralPath (Join-Path $runtime "LSP-Claw-Keys.bin"))) "$Name created partial token settings"
   }
   finally { Stop-TestServer $server }
}

try {
   New-Item -ItemType Directory -Path $root -Force | Out-Null
   $env:GITHUB_TOKEN=$null
   $env:GH_TOKEN=$null
   $env:MCP_AUTH_TOKEN=$null

   # Direct bootstrap, additional password colons, bearer enforcement, encrypted
   # persistence, and browser/MCP authentication separation.
   $runtime = New-Runtime "direct"
   $username = "bootstrap-admin"
   $password = "bootstrap:password:with-colons"
   $token = "command-line-bootstrap-token-0123456789"
   $githubToken = "preserved-github-token"
   $env:GITHUB_TOKEN=$githubToken
   $server = Start-TestServer $runtime @("-credentials","${username}:${password}","-token",$token)
   $env:GITHUB_TOKEN=$null
   Assert-True $server.Started "Direct credential bootstrap did not start.`n$($server.Log)"
   $login = Login-Browser $server $username $password
   Assert-True ($login.Response.Content -match "Token settings") "Direct bootstrap administrator could not log in"
   Assert-True ($login.Response.Content -match [regex]::Escape($githubToken)) "GitHub token did not survive MCP-token bootstrap"
   Assert-McpHandshake $server $token
   Assert-True ((Get-McpInitializeStatus $server "wrong-bootstrap-token-0123456789") -in @(401,403)) "Wrong MCP token was accepted"
   Assert-True ((Get-McpInitializeStatus $server $null) -in @(401,403)) "Missing MCP token was accepted"
   Assert-True ((Get-McpInitializeStatus $server $null $login.Session) -in @(401,403)) "Browser administrator session authorized the MCP endpoint"
   $bearerLogin = Login-Browser $server $username $token
   Assert-True ($bearerLogin.Response.Content -match "Invalid username or password") "MCP bearer token was accepted as the browser password"
   Assert-NoPlaintext (Join-Path $runtime "LSP-Claw-Admin.bin") @($password,$token) "Administrator database"
   Assert-NoPlaintext (Join-Path $runtime "LSP-Claw-Keys.bin") @($password,$token,$githubToken) "Token settings"
   Assert-True (-not $server.Log.Contains($password) -and -not $server.Log.Contains($token)) "Bootstrap secrets appeared in the trace"
   $adminHash = (Get-FileHash -Algorithm SHA256 (Join-Path $runtime "LSP-Claw-Admin.bin")).Hash
   $tokenHash = (Get-FileHash -Algorithm SHA256 (Join-Path $runtime "LSP-Claw-Keys.bin")).Hash
   Stop-TestServer $server

   # One-time guard: replacement command-line values must be ignored.
   $replacementPassword = "replacement-password"
   $replacementToken = "replacement-bootstrap-token-0123456789"
   $server = Start-TestServer $runtime @("-credentials","replacement-admin:${replacementPassword}","-token",$replacementToken)
   Assert-True $server.Started "Restart after direct bootstrap failed.`n$($server.Log)"
   Assert-True ($server.Log -match "LSP-Claw command-line bootstrap ignored: an administrator already exists") "Restart did not emit the generic ignored trace"
   Assert-True ((Get-FileHash -Algorithm SHA256 (Join-Path $runtime "LSP-Claw-Admin.bin")).Hash -eq $adminHash) "Restart changed the browser administrator database"
   Assert-True ((Get-FileHash -Algorithm SHA256 (Join-Path $runtime "LSP-Claw-Keys.bin")).Hash -eq $tokenHash) "Restart changed token settings"
   Assert-True ((Login-Browser $server $username $password).Response.Content -match "Token settings") "Restart replaced the original administrator"

   Stop-TestServer $server
   $server = Start-TestServer $runtime @("-credentials", "ignored", "-credentials", "also-ignored", "-token")
   Assert-True ($server.Log -match "LSP-Claw command-line bootstrap ignored: an administrator already exists") "Malformed replacement options were not ignored after bootstrap"
   Assert-True ((Get-FileHash -Algorithm SHA256 (Join-Path $runtime "LSP-Claw-Admin.bin")).Hash -eq $adminHash) "Malformed replacement options changed the administrator database"
   Assert-True ((Get-FileHash -Algorithm SHA256 (Join-Path $runtime "LSP-Claw-Keys.bin")).Hash -eq $tokenHash) "Malformed replacement options changed token settings"
   Assert-True ((Login-Browser $server "replacement-admin" $replacementPassword).Response.Content -match "Invalid username or password") "Restart accepted replacement credentials"
   Assert-McpHandshake $server $token
   Assert-True ((Get-McpInitializeStatus $server $replacementToken) -in @(401,403)) "Restart accepted the replacement MCP token"
   Stop-TestServer $server

   # Existing token-only installations stay intact and can add the first
   # browser administrator on a later start.
   $legacyRuntime = New-Runtime "legacy-upgrade"
   $legacyToken = "legacy-existing-mcp-token-0123456789"
   $legacyGithub = "legacy-existing-github-token"
   $env:MCP_AUTH_TOKEN=$legacyToken
   $env:GITHUB_TOKEN=$legacyGithub
   $server = Start-TestServer $legacyRuntime
   $env:MCP_AUTH_TOKEN=$null
   $env:GITHUB_TOKEN=$null
   Assert-True $server.Started "Existing token-only installation did not start"
   $setupRequired = Invoke-WebRequest -UseBasicParsing -Uri ($server.BaseUri + "lsp-claw-config.lsp")
   Assert-True ($setupRequired.Content -match "Administrator setup required") "Token-only installation exposed browser settings"
   Assert-McpHandshake $server $legacyToken
   Stop-TestServer $server
   $server = Start-TestServer $legacyRuntime @("-credentials","upgrade-admin:upgrade-password")
   Assert-True $server.Started "Existing installation credential upgrade failed.`n$($server.Log)"
   $upgradeLogin = Login-Browser $server "upgrade-admin" "upgrade-password"
   Assert-True ($upgradeLogin.Response.Content -match [regex]::Escape($legacyGithub)) "Credential upgrade changed the existing GitHub token"
   Assert-McpHandshake $server $legacyToken
   Stop-TestServer $server

   # Invalid inputs must fail before creating either store.
   Assert-BootstrapFailure "short-token" @("-credentials","admin:password","-token","short") "MCP token must contain at least 16 bytes"
   Assert-BootstrapFailure "malformed-credentials" @("-credentials","missing-colon") "credentials must use username:password"
   Assert-BootstrapFailure "missing-value" @("-credentials","-token","valid-bootstrap-token-0123456789") "bootstrap option -credentials requires a value"
   Assert-BootstrapFailure "empty-value" @("-credentials",'""') "bootstrap option -credentials requires a value"
   Assert-BootstrapFailure "token-only" @("-token","token-only-bootstrap-0123456789") "requires -credentials"

   # Duplicate direct options are deliberately minimal: the first value wins.
   $firstRuntime = New-Runtime "first-occurrence"
   $firstToken = "first-bootstrap-token-0123456789"
   $server = Start-TestServer $firstRuntime @("-credentials","first-admin:first-password","-credentials","ignored-admin:ignored-password","-token",$firstToken,"-token","short")
   Assert-True $server.Started "First-occurrence bootstrap failed.`n$($server.Log)"
   Assert-True ((Login-Browser $server "first-admin" "first-password").Response.Content -match "Token settings") "First credentials occurrence did not win"
   Assert-McpHandshake $server $firstToken
   Stop-TestServer $server

   Write-Output "CREDENTIAL_BOOTSTRAP_TEST_PASS direct=true colonPassword=true bearer=true encrypted=true oneTime=true firstWins=true legacyUpgrade=true validation=true separated=true"
}
finally {
   $env:GITHUB_TOKEN=$oldGitHubToken
   $env:GH_TOKEN=$oldGhToken
   $env:MCP_AUTH_TOKEN=$oldMcpToken
   foreach ($process in $processes) {
      if ($process -and -not $process.HasExited) { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue }
   }
   if (Test-Path -LiteralPath $root) {
      $resolved=(Resolve-Path -LiteralPath $root).Path
      $tempRoot=(Resolve-Path -LiteralPath $env:TEMP).Path
      if (-not $resolved.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase)) { throw "Refusing to remove non-temp path $resolved" }
      Remove-Item -LiteralPath $resolved -Recurse -Force
   }
}
