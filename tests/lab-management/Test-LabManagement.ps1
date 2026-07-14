param(
   [string]$Mako = "mako"
)

$ErrorActionPreference = "Stop"
$repo = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$stage = Join-Path $env:TEMP ("lsp-claw-lab-management-test-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path (Join-Path $stage ".lua\fastmcp") -Force | Out-Null
Copy-Item (Join-Path $repo "www\.lua\fastmcp\*.lua") (Join-Path $stage ".lua\fastmcp")
Copy-Item (Join-Path $repo "www\.lua\appmgr.lua") (Join-Path $stage ".lua")
Copy-Item (Join-Path $repo "www\.lua\lspclaw.lua") (Join-Path $stage ".lua")
Copy-Item (Join-Path $PSScriptRoot ".preload") $stage

try {
   $stdout = Join-Path $stage "stdout.log"
   $stderr = Join-Path $stage "stderr.log"
   $process = Start-Process -FilePath $Mako -ArgumentList "-l::$stage" -WorkingDirectory $stage -PassThru -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr
   $deadline = (Get-Date).AddSeconds(15)
   $passed = $false
   do {
      Start-Sleep -Milliseconds 100
      if (Test-Path $stdout) { $passed = (Get-Content $stdout -Raw) -match "LAB_MANAGEMENT_TEST_PASS" }
      if ($process.HasExited) { break }
   } while (-not $passed -and (Get-Date) -lt $deadline)
   if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force }
   $output = ((Get-Content $stdout -Raw -ErrorAction SilentlyContinue) + (Get-Content $stderr -Raw -ErrorAction SilentlyContinue)).Trim()
   $passed = $output -match "LAB_MANAGEMENT_TEST_PASS"
   if (-not $passed) { throw "Lab-management tests failed or timed out.`n$output" }
   Write-Output $output
}
finally {
   if ($process -and -not $process.HasExited) { Stop-Process -Id $process.Id -Force }
   Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
}
