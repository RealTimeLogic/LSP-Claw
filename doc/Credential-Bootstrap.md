# Command-Line Credential Bootstrap

The LSP-Claw command-line bootstrap secures an unattended first Mako startup.
It creates the browser configuration administrator and can set the independent
MCP bearer token before either HTTP surface is finalized.

## Options

LSP-Claw recognizes these entries in `mako.argv` and ignores unrelated Mako
arguments:

```text
-credentials <username:password>
-credentials-file <native-file-path>
-token <bearer-token>
-token-file <native-file-path>
```

Use either the direct or file form for each value, not both. Duplicate options,
missing or empty values, and direct values beginning with `-` fail application
startup. Credentials split at the first colon, so additional colons are part of
the password.

The browser administrator is mandatory whenever any bootstrap option is used
on an empty administrator store. A token-only bootstrap therefore fails.

## Recommended File-Based Startup

Direct command-line secrets may be visible in command history and process
listings. For a service or public VPS, create two operating-system-protected
files and pass absolute native paths:

```text
mako -l::lsp-claw.zip -credentials-file C:\secrets\lsp-claw-credentials.txt -token-file C:\secrets\lsp-claw-token.txt
```

The credentials file contains exactly one `username:password` line. The token
file contains exactly one bearer-token line. Files are limited to 8192 bytes;
an optional UTF-8 BOM and trailing CR/LF are removed, while embedded CR or LF
characters are rejected. Make the files readable only by the account running
Mako.

Native Lua file IO reads these paths. Do not convert Windows paths such as
`C:\secrets\token.txt` to BAS virtual paths such as `/c/secrets/token.txt`.

## One-Time Behavior

The persisted browser administrator store is the one-time guard:

- With no administrator, all supplied values are validated before anything is
  persisted.
- After the first administrator exists, all four bootstrap options are ignored.
- Later command lines cannot replace or rotate the administrator or MCP token.
- An ignored restart emits only the generic `bootstrap ignored` message.

If startup validation fails, the LSP-Claw application does not load and neither
an administrator nor token settings are partially created.

## Storage and Authentication Boundaries

Browser credentials are stored in the TPM-backed JSON-user database
`LSP-Claw-Admin.bin`. GitHub and MCP tokens continue to use the existing
TPM-derived encrypted `LSP-Claw-Keys.bin` file.

The MCP token must be a string containing 16 to 4096 bytes and no NUL, CR, or
LF. The same validator is used by command-line bootstrap and the browser token
form. Bootstrap changes only the existing MCP `authToken` value and preserves
the GitHub token.

The browser username/password and MCP bearer token remain independent:

- The browser administrator creates a normal authenticated browser session for
  the configuration and browser lab-management page.
- `mcp.lsp` accepts only its Bearer token when MCP authentication is enabled.
- A browser session cannot authorize MCP, and a bearer token cannot be used as
  the browser password.
- Logging out invalidates only the browser session.

## Existing Installations

An installation with `LSP-Claw-Keys.bin` but no `LSP-Claw-Admin.bin` remains
eligible for bootstrap. Restart it once with `-credentials` or
`-credentials-file`. Existing GitHub and MCP token values are preserved. Until
this upgrade is completed, the browser page displays administrator-setup
instructions and does not expose settings or browser lab controls.

## Windows Test

Run the repeatable integration harness from the repository root:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests/Test-CredentialBootstrap.ps1
```

It verifies direct and file bootstrap, extra password colons, bearer
enforcement, encrypted persistence, restart immutability, existing-installation
upgrade, invalid input failures, GitHub-token preservation, and separation of
browser and MCP authentication.
