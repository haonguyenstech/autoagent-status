# AutoAgent Status

A macOS **menu bar app** for the `auto-agent-ai` CLI — see your shared Claude Code
credential status at a glance, without ever opening a terminal.

> This repository hosts **release binaries only** (the source lives with the
> maintainer). Releases are consumed by the app's built-in self-updater and by
> the install script pinned in the team Slack.

## Features

- 🔑 **Menu bar status** — icon + live token countdown (`2h 15m`), turns to a
  warning when something is wrong
- 📋 **Status panel** — credential (role, token expiry), today's Claude Code
  token usage (same numbers as the CLI), watcher state, server health
- 🖱 **One-click actions** — Login as Owner / Client, Push, Logout
- 🔔 **Notifications** — watcher stopped, credential wiped, token expired,
  back to normal
- 🔄 **Self-healing** — if the watcher dies, the app logs in again
  automatically with your last role (toggleable)
- ⬆️ **Auto-updates** — the CLI updates itself via npm; the app updates itself
  from this repo's Releases ("Update App" button in the Health section)

## Install

**Recommended — one line** (get the link from the team Slack pin; it contains a
private download token so it is not printed here):

```bash
curl -fsSL <pinned-install-url> | bash
```

**Manual** — download the latest `AutoAgent-Status-x.y.z.zip` from
[Releases](../../releases), unzip, then run:

```bash
bash Install.command
```

> Do **not** double-click the `.app` straight from the zip — macOS Gatekeeper
> will block it ("Apple could not verify…"). The installer removes the
> quarantine flag for you. If you already hit the warning: click *Done*, then
> System Settings → Privacy & Security → *Open Anyway*.

### Requirements

- macOS 13+ (Apple Silicon or Intel — the binary is universal)
- [Node.js](https://nodejs.org) ≥ 18
- The `auto-agent-ai` CLI — the installer sets it up for you. You'll need a
  GitHub Personal Access Token (classic) with the `read:packages` scope and
  access to the `saigontechnology` org packages.

## Updating

Nothing to do. The app checks this repo every 6 hours (or instantly via the
**↻ Refresh** button) and shows an **Update App** button when a new version
exists. Click it — the app replaces itself and restarts.

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
# 1. bump CFBundleShortVersionString in Info.plist
# 2. make sure the right GitHub account is active:
gh auth switch --user haonguyenstech
# 3. build + publish (also refreshes the install gist):
./release.sh
```

**Files that must exist locally (never commit/share):**

| File | Purpose |
|---|---|
| `.update-token` | Fine-grained PAT (Contents: read-only, this repo only) embedded in the app for private-repo downloads |
| `.gist-id` | ID of the secret gist hosting the install one-liner |

**Token renewal (yearly):** fine-grained PATs expire. Before expiry: generate a
new token (same scope), overwrite `.update-token`, bump the version, and run
`./release.sh` — users receive the new token through the app update itself.

## Security model

- This repo is **private**; the app embeds a token that can *only download
  releases from this repo* — nothing else
- The app contains **no credentials or secrets** — the shared Claude Code
  credential lives in each user's macOS Keychain, managed by the CLI
- The install one-liner URL is an unlisted gist; treat the link like a
  team-internal password
