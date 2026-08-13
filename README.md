# LSP-Claw Quick Start

This quick start is for running LSP-Claw with the Mako Server Developer
Edition. See the [detailed instructions](Instructions.md) for other setups, including using [Xedge standalone](https://realtimelogic.com/products/xedge/), configuration options, lab management, backups, transfers, and tutorials.

![LSP-Claw](www/LSP-Claw-Icon.png "LSP-Claw")

## Start Device Interfaces with Light Dashboard

For device-management applications, use
[Light-Dashboard](https://github.com/RealTimeLogic/LSP-Examples/tree/master/Light-Dashboard).

## What You Need

- An AI agent with [MCP support](Instructions.md#what-mcp-means-here), such as Codex, installed on your computer.
- The [Mako Server Developer Edition](https://makoserver.net/documentation/developer-package/#makozip). Running Mako as a service is preferred. The [download page](https://makoserver.net/download/overview/) includes a prompt you can give your AI agent to guide you through downloading, installing, and running it as a service.

## Connect LSP-Claw

1. Install and start Mako using the Developer Edition instructions. You may
   optionally initialize the MCP authentication token on the first start:

   ```text
   mako -token your-mcp-bearer-token
   ```

   See the [command-line token instructions](Instructions.md#command-line-mcp-token).
2. Open [http://localhost/lsp-claw/](http://localhost/lsp-claw/). If you set an
   MCP token, use it to sign in. To access the LSP-Examples repository through
   LSP-Claw, enter a GitHub token and click **Save tokens**.
3. Add an MCP server named `lsp_claw` to your AI agent using this URL:

   ```text
   http://localhost/lsp-claw/mcp.lsp
   ```

4. Restart the agent or open a new session so it discovers LSP-Claw. See
   [Configure Your AI Agent](Instructions.md#configure-your-ai-agent) if you
   need agent-specific configuration details.

## Getting Started

The Mako Server Developer Edition is the easiest way to get started because it
includes LSP-Claw and the required Mako resources in one ready-to-run package.
This avoids manually installing and configuring the application.

[![Mako Server Developer Edition](https://makoserver.net/images/MakoZipDeveloperEdition.png)](https://makoserver.net/documentation/developer-package/)

## First Prompts

Prime the agent before asking it to build anything:

```text
Use LSP-Claw for this session. Check the runtime and lab status, list the
available labs, and tell me what you found. Do not change anything yet. Work
only through LSP-Claw; if its tools are unavailable, stop and tell me.
```

Build a device management interface:

```text
Use LSP-Claw to build a device management interface using
Light-Dashboard/custom. Check the runtime and lab, then ask what device, pages,
live data, commands, and visual style I need. Build and test the interface and
give me its URL.
```

## Detailed Documentation

Continue with the
[complete LSP-Claw installation and usage guide](Instructions.md) for AI-agent
configuration, additional prompts, alternative installations, lab management,
backups, transfers, and tutorials.
