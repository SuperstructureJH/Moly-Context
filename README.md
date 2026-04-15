# WeChat Sync MVP

`wechat-sync` is a macOS-only local sync tool that reads the visible WeChat desktop window through the Accessibility API, stores visible chat messages into a local SQLite database, and can keep polling in `watch` mode.

This MVP is designed to avoid full-screen OCR polling. It does **not** need to own your monitor all the time. Instead, it reads the WeChat window's accessible text nodes and continuously reconciles the visible transcript into a local message ledger.

It now supports two ways to run:

- a CLI for debugging and inspection
- a double-clickable macOS `.app` bundle for normal use
- a distributable `.dmg` package for handoff

## What it does

- Detects whether WeChat is running
- Checks Accessibility permission
- Dumps the visible WeChat text tree for debugging
- Syncs the currently visible conversation into SQLite
- Tracks both incoming and outgoing visible messages with de-duplication

## Current limitations

- It only syncs the **currently visible** WeChat conversation window
- It depends on macOS Accessibility, so you must grant permission first
- Sender names inside group chats are not extracted yet
- Non-text content like images, files, stickers, or voice messages are not parsed yet
- The message grouping heuristics may need tuning for your exact WeChat build and window layout

## Build The Desktop App

```bash
cd /Users/dongjianghan/Codex/Moly/wechat-sync-mvp
chmod +x build_app.sh open_app.command
./build_app.sh
```

This creates:

```bash
build/Moly Chat Bridge.app
```

You can then launch it by double-clicking the app in Finder, or from Terminal:

```bash
open "build/Moly Chat Bridge.app"
```

There is also a helper launcher you can double-click:

```bash
/Users/dongjianghan/Codex/Moly/wechat-sync-mvp/open_app.command
```

For more stable macOS Accessibility permissions during testing, install the built app to `/Applications` first:

```bash
/Users/dongjianghan/Codex/Moly/wechat-sync-mvp/install_release.command
```

Then grant Accessibility permission to the `/Applications/Moly Chat Bridge.app` copy, quit it fully, and reopen it from `Applications`.

## Build The DMG

```bash
cd /Users/dongjianghan/Codex/Moly/wechat-sync-mvp
chmod +x build_dmg.sh
./build_dmg.sh
```

This creates a distributable disk image in:

```bash
dist/Moly-Chat-Bridge-0.1.6.dmg
```

The DMG includes:

- `Moly Chat Bridge.app`
- an `Applications` shortcut for drag-and-drop install

If you already have signing identities, you can inject them during build:

```bash
APP_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./build_app.sh
DMG_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./build_dmg.sh
```

Without signing, the DMG is still useful for local testing and internal handoff, but macOS Gatekeeper will show stronger warnings on other machines.

## What The App Does

- opens a native macOS window
- shows Accessibility and WeChat status
- can request permissions and open the correct settings page
- can open WeChat, run one sync, start or stop watch mode
- can auto-open a conversation row when the left chat list appears to change
- lets you reveal the SQLite database in Finder

## First Run In The App

1. Build the app with `./build_app.sh`.
2. Double-click `build/Moly Chat Bridge.app` or install it to `/Applications` first.
3. Click `Setup Permissions`.
4. In System Settings -> Privacy & Security -> Accessibility, enable the app.
5. Open WeChat and open a conversation.
6. Leave `Auto open changed conversation` enabled if you want the app to switch to chats that appear to update.
7. Click `Sync Once` or `Start Watch`.

This auto-open feature is heuristic-based in the current MVP. It looks for changes in the left conversation list, then clicks the changed row and syncs the now-visible transcript.

If you distribute the unsigned DMG to another Mac, the recipient may need to right-click the app and choose `Open` the first time.

## Build The CLI

```bash
cd /Users/dongjianghan/Codex/Moly/wechat-sync-mvp
chmod +x build_local.sh
./build_local.sh
```

That writes the CLI binary to:

```bash
bin/wechat-sync
```

## Commands

### Guided setup

```bash
bin/wechat-sync setup
```

### Permission check

```bash
bin/wechat-sync doctor --prompt --open-settings
```

### Inspect the visible WeChat UI

Use this when you want to see what text nodes the Accessibility tree exposes:

```bash
bin/wechat-sync inspect --depth 10
```

### Sync the visible transcript once

```bash
bin/wechat-sync sync-once --verbose
```

By default the SQLite file is created at:

```bash
~/Library/Application Support/WeChatSyncMVP/wechat_sync.sqlite3
```

You can override it with:

```bash
bin/wechat-sync sync-once --db /tmp/wechat_sync.sqlite3
```

### Continuous watch mode

```bash
bin/wechat-sync watch --interval 5 --verbose
```

This polls the visible WeChat window every 5 seconds and appends newly seen messages into the local database.

## Inspect the database

```bash
sqlite3 ~/Library/Application\ Support/WeChatSyncMVP/wechat_sync.sqlite3 \
  "select conversation_name, sender_label, recipient_label, text, captured_at from messages order by id desc limit 20;"
```

## Suggested next step

Once this is working on your Mac, the next upgrade should be:

1. add notification-triggered sync instead of pure polling
2. add Apple Vision OCR as fallback when a message is not exposed in Accessibility
3. add automated conversation-list traversal for historical backfill
4. codesign and notarize the `.app`, then package it into a `.dmg`
