# AutoAgent Status

A macOS **menu bar app** for the `auto-agent-ai` CLI — see your shared Claude Code
credential status at a glance, without ever opening a terminal.

## Features

- 🔑 **Menu bar status** — icon + live token countdown (`2h 15m`), turns to a
  warning when something is wrong
- 📋 **Status panel** — credential (role, token expiry), today's Claude Code
  token usage (same numbers as the CLI), watcher state, server health
- 🖱 **One-click actions** — Client Login / Logout
- 🔐 **Microsoft sign-in** — opens your browser for OAuth and shows the sign-in
  link (with Open / Copy) as a fallback if the browser doesn't pop up
- 🔔 **Notifications** — watcher stopped, credential wiped, token expired,
  sign-in required, back to normal
- 🔄 **Self-healing** — if the watcher dies, the app logs in again
  automatically with your last role (toggleable)
- ⬆️ **Auto-updates** — the app updates itself from this repo's Releases
  ("Update App" button), and offers to update the CLI when a new npm version
  ships (including the CLI's "update required" hard-block)

## Install

**One line.** Open Terminal and run:

```bash
curl -fsSL https://raw.githubusercontent.com/haonguyenstech/autoagent-status/main/install.sh | bash
```

It downloads the latest release, removes the Gatekeeper quarantine flag, and
launches the app. Run it again any time to update.

**Manual** — download the latest `AutoAgent-Status-x.y.z.zip` from
[Releases](../../releases), unzip, then run:

```bash
bash Install.command
```

> Do **not** double-click the `.app` straight from the zip — macOS Gatekeeper
> will block it ("Apple could not verify…"). The installer (or the one-liner)
> removes the quarantine flag for you. If you already hit the warning: click
> *Done*, then System Settings → Privacy & Security → *Open Anyway*.

### Requirements

- macOS 13+ (Apple Silicon or Intel — the binary is universal)
- [Node.js](https://nodejs.org) ≥ 18 (for the CLI)
- The `auto-agent-ai` CLI:
  ```bash
  npm install -g @saigontechnology/auto-agent
  ```
  The CLI is a **saigontechnology org package** — you need org access and a
  GitHub token with the `read:packages` scope to install it. (The app itself
  is public; only the CLI is org-gated.)

## Updating

Nothing to do. The app checks this repo's Releases every 6 hours (or instantly
via the **↻ Refresh** button) and shows an **Update App** button when a new
version exists. Click it — the app replaces itself and restarts. Or re-run the
install one-liner above.

## Uninstall

Quit the app (power button in the panel footer), then delete
`~/Applications/AutoAgent Status.app`. To also remove the credential sync:
`auto-agent-ai logout && npm uninstall -g @saigontechnology/auto-agent`.

---

## For the maintainer

Source lives at `~/auto-agent-status` on the maintainer's machine
(Swift, single file, built with `swiftc` — no Xcode project).

**Release a new version:**

```bash
# 1. bump CFBundleShortVersionString (and CFBundleVersion) in Info.plist
# 2. make sure the right GitHub account is active:
gh auth switch --user haonguyenstech
# 3. build + publish the release:
./release.sh
```

`release.sh` builds the universal binary, packages `dist/AutoAgent-Status-<ver>.zip`,
and creates the GitHub Release. New users install via the public one-liner
(`install.sh` in this repo); existing apps self-update from Releases.

This repo is **public** and the app embeds **no secrets** — the shared Claude
Code credential lives in each user's macOS Keychain, managed by the CLI.
