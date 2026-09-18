# LSP-Claw: MCP Server for BAS Derivative Products

LSP-Claw lets an AI agent work with Barracuda App Server (**BAS**) based
tools such as [Mako Server](https://makoserver.net/),
[Xedge](https://realtimelogic.com/products/xedge/), and
[Xedge32](https://realtimelogic.com/downloads/bas/ESP32/?bas=) through an
MCP server. Instead of asking an AI agent, such as Codex, to edit random
local files, you give it access to a controlled lab app where it can
inspect examples, create files, run the lab, and debug server-side
Lua/LSP code.

> **New to LSP-Claw?** Watch the
> [LSP-Claw introduction video](https://youtu.be/z3wQHM6MDC4) for a
> high-level overview of what LSP-Claw is and how it fits into
> AI-assisted Mako/Xedge development.

![LSP-Claw](www/LSP-Claw-Icon.png "LSP-Claw")

LSP-Claw is especially useful for embedded systems. LSP-Claw can remotely
start, stop, and replace the application being tested without restarting
the device, RTOS, or hosting server. A monolithic RTOS device can keep
running its core firmware while the MCP server restarts only the lab app.

## Example Prompt: Designing a Web Device Interface

For device-management applications, use
[Light-Dashboard](https://github.com/RealTimeLogic/LSP-Examples/tree/master/Light-Dashboard/).

```text
Use LSP-Claw to build a device management interface using
Light-Dashboard/custom. Check the runtime and lab, then ask what device, pages,
live data, commands, and visual style I need. Build and test the interface and
give me its URL.
```

## Mako and Xedge LSP-Claw Quick Start

Start with downloading the latest pre-built LSP-Claw: [https://makoserver.net/download/packages/lsp-claw.zip](https://makoserver.net/download/packages/lsp-claw.zip)


#### Using [Mako Server](https://makoserver.net/)

>Alternative to the instructions below: use the **[Mako Server Developer Edition](Mako-Server.md)**

- Start Mako Server: ```mako -llsp-claw::lsp-claw.zip```
- Navigate to http://localhost/lsp-claw/ to configure LSP-Claw
- Configure your AI Agent (MCP endpoint: http://localhost/lsp-claw/mcp.lsp) and start using LSP-Claw

See the [detailed instructions](Instructions.md) for details, including using LSP-Claw and the prompt tutorial. See also [Mako Server Developer Edition](Mako-Server.md).


#### Using [Xedge](https://realtimelogic.com/products/xedge/) and Derivatives such as [Xedge32](https://realtimelogic.com/downloads/bas/ESP32/)

- Navigate to the Xedge UI: http://ip-addr/rtl/
- Click the menu button in the top right corner
- Click App Upload (or Firmware Update & App Upload)
- Drag and drop lsp-claw.zip onto the web UI to upload LSP-Claw
- Navigate to http://ip-addr/lsp-claw/ to configure LSP-Claw
- Configure your AI Agent (MCP endpoint: http://ip-address/lsp-claw/mcp.lsp) and start using LSP-Claw

See the [detailed instructions](Instructions.md) for details, including using LSP-Claw and the prompt tutorial.



















