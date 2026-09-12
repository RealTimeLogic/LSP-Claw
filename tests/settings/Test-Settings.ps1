param(
   [string]$Mako = "mako"
)

$ErrorActionPreference = "Stop"
$repo = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$stage = Join-Path $env:TEMP ("lsp-claw-settings-test-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $stage -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $repo "www\.preload") -Destination (Join-Path $stage "app-preload.lua")
Copy-Item (Join-Path $PSScriptRoot ".preload") $stage
[IO.File]::WriteAllText((Join-Path $stage "mako.conf"),"home='./'`nhost='127.0.0.1'`nport=0`nsslport=0`n",[Text.UTF8Encoding]::new($false))

try {
   $stdout = Join-Path $stage "stdout.log"
   $stderr = Join-Path $stage "stderr.log"
   $process = Start-Process -FilePath $Mako -ArgumentList "-c mako.conf -l::." -WorkingDirectory $stage -PassThru -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr
   $deadline = (Get-Date).AddSeconds(15)
   $passed = $false
   do {
      Start-Sleep -Milliseconds 100
      if (Test-Path $stdout) { $passed = (Get-Content $stdout -Raw) -match "SETTINGS_TEST_PASS" }
      if ($process.HasExited) { break }
   } while (-not $passed -and (Get-Date) -lt $deadline)
   if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force }
   $output = ((Get-Content $stdout -Raw -ErrorAction SilentlyContinue) + (Get-Content $stderr -Raw -ErrorAction SilentlyContinue)).Trim()
   $passed = $output -match "SETTINGS_TEST_PASS"
   if (-not $passed) { throw "Settings startup tests failed or timed out.`n$output" }
   Write-Output $output
}
finally {
   if (-not ([IO.Path]::GetFullPath($stage)).StartsWith(([IO.Path]::GetFullPath($env:TEMP)).TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)) { throw "Unexpected test directory" }
   Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
}
