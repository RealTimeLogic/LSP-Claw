# LSP-Claw Quick Start

This quick start is for running LSP-Claw with the Mako Server Developer
Edition. See the [detailed instructions](Instructions.md) for other setups, including using [Xedge standalone](https://realtimelogic.com/products/xedge/), configuration options, lab management, backups, transfers, and tutorials.

![LSP-Claw](www/LSP-Claw-Icon.png "LSP-Claw")

## What You Need

- An AI agent with [MCP support](Instructions.md#what-mcp-means-here), such as Codex, installed on your computer.
- The [Mako Server Developer Edition](https://makoserver.net/documentation/developer-package/#makozip). Running Mako as a service is preferred. The [download page](https://makoserver.net/download/overview/) includes a prompt you can give your AI agent to guide you through downloading, installing, and running it as a service.

## Connect LSP-Claw

1. Install and start Mako using the Developer Edition instructions.
2. Open [http://localhost/lsp-claw/](http://localhost/lsp-claw/). If you plan to
   access the LSP-Examples repository through LSP-Claw, enter a GitHub token and
   click **Save tokens**.
3. Add an MCP server named `lsp_claw` to your AI agent using this URL:

   ```text
   http://localhost/lsp-claw/mcp.lsp
   ```

4. Restart the agent or open a new session so it discovers LSP-Claw. See
   [Configure Your AI Agent](Instructions.md#configure-your-ai-agent) if you
   need agent-specific configuration details.

## First Prompts

Prime the agent before asking it to build anything:

```text
Use LSP-Claw for this session. Check the runtime and lab status, list the
available labs, and tell me what you found. Do not change anything yet. Work
only through LSP-Claw; if its tools are unavailable, stop and tell me.
```

Find an example to start from:

```text
Use LSP-Claw to show me three beginner-friendly examples from LSP-Examples.
Briefly explain each one and wait for me to choose before copying anything.
```

Or create and test a small application:

```text
Use LSP-Claw to create a new lab named hello-lsp. Create a simple index.lsp
page that displays "Hello from LSP-Claw" and the current server time. Start
the lab, test the page, and give me its URL.
```

For additional prompts, see
[First Useful Prompt](Instructions.md#first-useful-prompt).
