# Windows Test Harnesses

The LSP-Claw test harnesses are PowerShell scripts for Windows. Run them from
the repository root before packaging a modified checkout:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests/fastmcp/Test-FastMCP.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tests/Test-CredentialBootstrap.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tests/Test-TokenSetup.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tests/lab-management/Test-LabManagement.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tests/lab-archive/Test-LabArchive.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tests/lab-transfer/Test-LabTransfer.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tests/Test-LSP-Claw.ps1
```

The harnesses perform these tests in order:

1. Isolate and test generic FastMCP.
2. Verify command-line browser credentials, MCP-token bootstrap, encrypted
   persistence, one-time behavior, file inputs, upgrade, and auth separation.
3. Verify the browser configuration page, GitHub-token validation, redirects,
   ZIP upload, and browser lab start/stop.
4. Test lab-management behavior in an isolated temporary Mako home.
5. Verify stored ZIP generation and ZipIo decompression independently.
6. Start two independently authenticated servers and verify direct
   destination-pull transfer.
7. Start the complete LSP-Claw application and verify Streamable HTTP, multiple
   labs, routes, browser and MCP archives, timestamps, staged replacement, and
   security boundaries.

## Test a Registered LSP-Claw Server

To test an already running root-mounted LSP-Claw instance through its registered
HTTP MCP endpoint, including tools, resources, prompts, GitHub reads, direct
transfer, runtime URLs, and cleanup, run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests/Test-Registered-LSP-Claw.ps1
```

The live harness defaults to `http://localhost/mcp.lsp` and requires the only
baseline lab to be a stopped, automatically root-routed `lsplab`. Use `-Uri` to
test another registered endpoint.
