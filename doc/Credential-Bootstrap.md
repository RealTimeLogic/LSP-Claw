# Command-Line Credential Bootstrap

On its first Mako start, LSP-Claw accepts two direct options:

```text
mako -l::lsp-claw.zip -credentials admin:your-password -token your-mcp-bearer-token
```

`-credentials` is required and creates the browser configuration
administrator. `-token` is optional and initializes the independent MCP Bearer
token. Credentials split at the first colon, so the password may contain
additional colons. The MCP token must contain 16 to 4096 bytes and no NUL, CR,
or LF characters.

The first occurrence of each option wins. Missing or empty values, values that
begin with `-`, malformed credentials, and token-only bootstrap fail startup.
Unrelated Mako arguments are ignored.

Bootstrap is one-time. If `LSP-Claw-Admin.bin` already contains an
administrator, both options are ignored and cannot replace the administrator
or MCP token. An older installation with tokens but no administrator remains
eligible; its existing GitHub and MCP tokens are preserved.

Browser credentials are stored through the TPM-backed JSON-user mechanism in
`LSP-Claw-Admin.bin`. GitHub and MCP tokens remain encrypted in
`LSP-Claw-Keys.bin`. Browser sessions do not authorize MCP, and the Bearer token
is not accepted as a browser password.

Direct command-line secrets may be visible in command history and process
listings. File-based secret options are not part of this minimal bootstrap.

Run the focused Windows integration test from the repository root:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests/Test-CredentialBootstrap.ps1
```
