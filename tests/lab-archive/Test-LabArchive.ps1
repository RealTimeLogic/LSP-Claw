param(
   [string]$Mako = "mako"
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$repo = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$stage = Join-Path $env:TEMP ("lsp-claw-lab-archive-test-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path (Join-Path $stage ".lua") -Force | Out-Null
Copy-Item (Join-Path $repo "www\.lua\zip_writer.lua") (Join-Path $stage ".lua")
Copy-Item (Join-Path $repo "www\.lua\lab_archive.lua") (Join-Path $stage ".lua")
Copy-Item (Join-Path $PSScriptRoot ".preload") $stage

$compressedPath = Join-Path $stage "compressed.zip"
$file = [IO.File]::Open($compressedPath,[IO.FileMode]::CreateNew)
try {
   $archive = [IO.Compression.ZipArchive]::new($file,[IO.Compression.ZipArchiveMode]::Create,$false)
   try {
      $entry = $archive.CreateEntry("compressed.txt",[IO.Compression.CompressionLevel]::Optimal)
      $writer = [IO.StreamWriter]::new($entry.Open(),[Text.UTF8Encoding]::new($false))
      try { $writer.Write("ZipIo decompresses this content") } finally { $writer.Dispose() }
      $null = $archive.CreateEntry("compressed-empty/")
   }
   finally { $archive.Dispose() }
}
finally { $file.Dispose() }

try {
   $stdout = Join-Path $stage "stdout.log"
   $stderr = Join-Path $stage "stderr.log"
   $process = Start-Process -FilePath $Mako -ArgumentList "-l::$stage" -WorkingDirectory $stage -PassThru -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr
   $deadline = (Get-Date).AddSeconds(15)
   $passed = $false
   do {
      Start-Sleep -Milliseconds 100
      if (Test-Path $stdout) { $passed = (Get-Content $stdout -Raw) -match "LAB_ARCHIVE_TEST_PASS" }
      if ($process.HasExited) { break }
   } while (-not $passed -and (Get-Date) -lt $deadline)
   if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force }
   $output = ((Get-Content $stdout -Raw -ErrorAction SilentlyContinue) + (Get-Content $stderr -Raw -ErrorAction SilentlyContinue)).Trim()
   if ($output -notmatch "LAB_ARCHIVE_TEST_PASS") { throw "Lab archive tests failed or timed out.`n$output" }
   Write-Output $output
}
finally {
   if ($process -and -not $process.HasExited) { Stop-Process -Id $process.Id -Force }
   Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
}
