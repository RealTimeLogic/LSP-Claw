# Command-Line MCP Token

LSP-Claw optionally accepts one application argument:

```text
mako -l::lsp-claw.zip -token your-mcp-bearer-token
```

`-token` initializes only the MCP bearer token. It never sets or changes the
GitHub token. The value must contain 16 to 4096 bytes and no NUL, CR, or LF
characters. A missing, empty, or option-like value fails application startup.

The first `-token` occurrence wins. After an MCP token is stored, later
command-line values are ignored and cannot replace it. The token uses the same
TPM-derived encrypted `LSP-Claw-Keys.bin` storage and validator as the settings
page.

When no MCP token exists, the browser settings page is open. Once configured,
the token also unlocks that page. A browser session never authorizes the MCP
endpoint; MCP clients must send `Authorization: Bearer <token>`.

Direct command-line secrets may be visible in command history and process
listings.

Run the focused Windows integration test from the repository root:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests/Test-CommandLineToken.ps1
```
