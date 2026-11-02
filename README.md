# ae-mcp-installer

One-click Windows installer that connects **Adobe After Effects** to **Claude Desktop** using [Dakkshin/after-effects-mcp](https://github.com/Dakkshin/after-effects-mcp).

## Requirements

- Windows 10 or 11
- Adobe After Effects 2022 or later
- [Claude Desktop](https://claude.ai/download), installed and opened at least once

Node.js and Git are installed automatically if they are missing.

## Usage

1. Click **Code > Download ZIP** on this page
2. Right-click the zip > **Properties** > check **Unblock** > **OK**
3. Extract it and double-click `install.cmd`
4. Click **Yes** whenever Windows asks for administrator rights
5. If asked, close After Effects (save your work first) and Claude Desktop

If Claude Desktop is not installed yet, the installer opens the download page and stops. Install it, open it once, then run `install.cmd` again.

After setup, open After Effects, go to **Window > mcp-bridge-auto.jsx**, and make sure **Auto-run commands** is checked. Then ask Claude Desktop something like:

> Create a 1920x1080 30fps composition with a text layer that says Hello

## What it does

1. Checks for After Effects 2022+ and Claude Desktop
2. Installs Node.js LTS if it is missing or older than v18
3. Installs Git if it is missing (falls back to a zip download)
4. Downloads `after-effects-mcp` to `C:\after-effects-mcp` (updates it if already there)
5. Runs `npm install` and `npm run build`
6. Copies `mcp-bridge-auto.jsx` into the latest After Effects `ScriptUI Panels` folder
7. Enables **Allow Scripts to Write Files and Access Network** in After Effects (waits for After Effects to be closed)
8. Adds the server to `claude_desktop_config.json` without touching your other settings (waits for Claude Desktop to be closed, then reopens it)
9. Runs a health check

## Options

Run from a terminal in the extracted folder:

| Command                             | Description                                                                   |
| ----------------------------------- | ----------------------------------------------------------------------------- |
| `install.cmd -Doctor`               | Check the current setup without changing anything                             |
| `install.cmd -AllVersions`          | Install the panel into every After Effects 2022+ version, not just the latest |
| `install.cmd -SkipPrefs`            | Do not modify After Effects preferences                                       |
| `install.cmd -InstallDir D:\ae-mcp` | Install to a different folder                                                 |

Running `install.cmd` again updates the server to the latest version.

## Troubleshooting

- **Claude Desktop does not show the tools**: fully quit it from the tray icon (closing the window is not enough) and reopen it.
- **Commands do nothing in After Effects**: make sure the bridge panel is open and **Auto-run commands** is checked.
- **Something else**: run `install.cmd -Doctor` and look for red items.

Before the Claude config or After Effects preferences are modified for the first time, the original file is saved next to it as `.bak`.

## Credits

The MCP server itself is [after-effects-mcp](https://github.com/Dakkshin/after-effects-mcp) by Dakkshin. This project only automates its setup.

Not affiliated with Adobe or Anthropic.
