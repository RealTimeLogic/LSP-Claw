param(
   [string]$Mako = "mako",
   [int]$Port = 18086
)

$ErrorActionPreference = "Stop"
$PSDefaultParameterValues['Invoke-WebRequest:TimeoutSec'] = 15
$repo = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$root = Join-Path $env:TEMP ("lsp-claw-token-test-" + [guid]::NewGuid().ToString("N"))
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
   $process = Start-Process -FilePath $Mako -ArgumentList (@("-llsp-claw::www") + $ExtraArgs) -WorkingDirectory $Runtime -PassThru -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr
   $script:processes += $process
   $deadline = (Get-Date).AddSeconds(15)
   $log = ""
   do {
      Start-Sleep -Milliseconds 100
      $log = (Get-Content -LiteralPath $stdout -Raw -ErrorAction SilentlyContinue) + (Get-Content -LiteralPath $stderr -Raw -ErrorAction SilentlyContinue)
   } until ($log -match '(?m)^Loading www as.*:\s+ok\s*$' -or $log -match '(?m)^Loading www as.*:\s+failed:' -or $process.HasExited -or (Get-Date) -gt $deadline)
   return [pscustomobject]@{
      Process=$process
      Log=$log
      Started=($log -match '(?m)^Loading www as.*:\s+ok\s*$') -and -not $process.HasExited
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

function Login-Token($Server,[string]$Token) {
   $session = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
   $response = Invoke-WebRequest -UseBasicParsing -Uri ($Server.BaseUri + "lsp-claw-config.lsp") -Method Post -WebSession $session -Body @{action="login";loginToken=$Token}
   return [pscustomobject]@{Session=$session;Response=$response}
}

function New-InitializeBody {
   return @{
      jsonrpc="2.0"
      id=1
      method="initialize"
      params=@{protocolVersion="2025-11-25";capabilities=@{};clientInfo=@{name="command-line-token-regression";version="1"}}
   } | ConvertTo-Json -Depth 10 -Compress
}

function Get-McpInitializeStatus($Server,[string]$Token,$BrowserSession=$null) {
   $headers = @{Accept="application/json, text/event-stream"}
   if ($Token) { $headers.Authorization="Bearer $Token" }
   try {
      $params = @{UseBasicParsing=$true;Uri=$Server.McpUri;Method="Post";ContentType="application/json";Headers=$headers;Body=(New-InitializeBody)}
      if ($BrowserSession) { $params.WebSession=$BrowserSession }
      return [int](Invoke-WebRequest @params).StatusCode
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
   $headers["MCP-Session-Id"]=$response.Headers["MCP-Session-Id"]
   $headers["MCP-Protocol-Version"]="2025-11-25"
   $initialized = @{jsonrpc="2.0";method="notifications/initialized"} | ConvertTo-Json -Compress
   Assert-True ((Invoke-WebRequest -UseBasicParsing -Uri $Server.McpUri -Method Post -ContentType "application/json" -Headers $headers -Body $initialized).StatusCode -eq 202) "MCP initialized notification failed"
   Assert-True ((Invoke-WebRequest -UseBasicParsing -Uri $Server.McpUri -Method Delete -Headers $headers).StatusCode -eq 204) "MCP session deletion failed"
}

function Assert-TokenFailure([string]$Name,[string[]]$Arguments,[string]$ExpectedMessage) {
   $runtime = New-Runtime $Name
   $server = Start-TestServer $runtime $Arguments
   try {
      Assert-True (-not $server.Started) "$Name unexpectedly started.`n$($server.Log)"
      Assert-True ($server.Log -match [regex]::Escape($ExpectedMessage)) "$Name did not report '$ExpectedMessage'.`n$($server.Log)"
      Assert-True (-not (Test-Path -LiteralPath (Join-Path $runtime "LSP-Claw-Keys.bin"))) "$Name created partial token settings"
   }
   finally { Stop-TestServer $server }
}

try {
   New-Item -ItemType Directory -Path $root -Force | Out-Null
   $env:GITHUB_TOKEN=$null
   $env:GH_TOKEN=$null
   $env:MCP_AUTH_TOKEN=$null

   # -token sets only MCP authentication. GitHub remains blank.
   $runtime = New-Runtime "direct"
   $token = "abcdefghijklmnop"
   $server = Start-TestServer $runtime @("-token",$token)
   Assert-True $server.Started "Command-line token setup did not start.`n$($server.Log)"
   $loginPage = Invoke-WebRequest -UseBasicParsing -Uri ($server.BaseUri + "lsp-claw-config.lsp")
   Assert-True ($loginPage.Content -match "Authentication token") "Configured token did not protect the settings page"
   Assert-True ((Login-Token $server "wrong-command-token").Response.Content -match "Invalid authentication token") "Wrong settings token was accepted"
   $login = Login-Token $server $token
   Assert-True ($login.Response.Content -match 'id="githubToken"[^>]*value=""') "Command-line MCP token populated the GitHub token field"
   Assert-McpHandshake $server $token
   Assert-True ((Get-McpInitializeStatus $server $null) -in @(401,403)) "Missing MCP token was accepted"
   Assert-True ((Get-McpInitializeStatus $server "wrong-command-token") -in @(401,403)) "Wrong MCP token was accepted"
   Assert-True ((Get-McpInitializeStatus $server $null $login.Session) -in @(401,403)) "Browser session authorized the MCP endpoint"
   $keyPath = Join-Path $runtime "LSP-Claw-Keys.bin"
   $keyText = [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($keyPath))
   Assert-True (-not $keyText.Contains($token)) "MCP token was stored in plaintext"
   Assert-True (-not $server.Log.Contains($token)) "MCP token appeared in trace output"
   $keyHash = (Get-FileHash -Algorithm SHA256 $keyPath).Hash
   Stop-TestServer $server

   # Once stored, command-line replacements are ignored without reading them.
   $replacement = "replacement-token-0123456789"
   $server = Start-TestServer $runtime @("-token",$replacement)
   Assert-True $server.Started "Restart with replacement token failed.`n$($server.Log)"
   Assert-True ($server.Log -match "command-line token ignored: an MCP token already exists") "Existing token did not trigger the one-time guard"
   Assert-True ((Get-FileHash -Algorithm SHA256 $keyPath).Hash -eq $keyHash) "Replacement command changed stored tokens"
   Assert-McpHandshake $server $token
   Assert-True ((Get-McpInitializeStatus $server $replacement) -in @(401,403)) "Replacement command token was accepted"
   Stop-TestServer $server

   # Existing GitHub data is preserved when the MCP token is initialized.
   $githubRuntime = New-Runtime "github-preserved"
   $githubToken = "preserved-github-token"
   $mcpToken = "preserved-mcp-token-0123456789"
   $env:GITHUB_TOKEN=$githubToken
   $server = Start-TestServer $githubRuntime @("-token",$mcpToken)
   $env:GITHUB_TOKEN=$null
   Assert-True $server.Started "MCP setup with an existing GitHub token failed"
   Assert-True ((Login-Token $server $mcpToken).Response.Content -match [regex]::Escape($githubToken)) "MCP token setup changed the GitHub token"
   Assert-McpHandshake $server $mcpToken
   Stop-TestServer $server

   Assert-TokenFailure "short-token" @("-token","short") "MCP token must contain at least 16 bytes"
   Assert-TokenFailure "missing-value" @("-token","-unrelated") "option -token requires a value"
   Assert-TokenFailure "empty-value" @("-token",'""') "option -token requires a value"

   # The first direct token wins; later occurrences are not parsed.
   $firstRuntime = New-Runtime "first-occurrence"
   $firstToken = "first-command-token-0123456789"
   $server = Start-TestServer $firstRuntime @("-token",$firstToken,"-token","short")
   Assert-True $server.Started "First-occurrence token setup failed.`n$($server.Log)"
   Assert-McpHandshake $server $firstToken
   Stop-TestServer $server

   Write-Output "COMMAND_LINE_TOKEN_TEST_PASS mcpOnly=true githubBlank=true encrypted=true oneTime=true firstWins=true githubPreserved=true validation=true browserLogin=true separated=true"
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
