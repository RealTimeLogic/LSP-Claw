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

function Invoke-TestPhase {
   param([string]$Phase)

   $stdout = Join-Path $stage ("stdout-" + $Phase + ".log")
   $stderr = Join-Path $stage ("stderr-" + $Phase + ".log")
   $process = Start-Process -FilePath $Mako -ArgumentList "-l::$stage" -WorkingDirectory $stage -PassThru -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr
   $deadline = (Get-Date).AddSeconds(15)
   $expected = "LAB_MANAGEMENT_TEST_PASS\s+phase=" + $Phase
   $passed = $false
   do {
      Start-Sleep -Milliseconds 100
      if (Test-Path $stdout) { $passed = (Get-Content $stdout -Raw) -match $expected }
      if ($process.HasExited) { break }
   } while (-not $passed -and (Get-Date) -lt $deadline)
   if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force }
   $output = ((Get-Content $stdout -Raw -ErrorAction SilentlyContinue) + (Get-Content $stderr -Raw -ErrorAction SilentlyContinue)).Trim()
   if ($output -notmatch $expected) { throw "Lab-management $Phase tests failed or timed out.`n$output" }
   Write-Output $output
}

try {
   Invoke-TestPhase -Phase "initial"
   Invoke-TestPhase -Phase "restart"
}
finally {
   Get-Process -Name ([System.IO.Path]::GetFileNameWithoutExtension($Mako)) -ErrorAction SilentlyContinue |
      Where-Object { $_.MainWindowTitle -like "*$stage*" } |
      Stop-Process -Force -ErrorAction SilentlyContinue
   Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
}
