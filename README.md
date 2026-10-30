# ClipVault

Encrypted clipboard history in your Mac’s menu bar. Keeps listening while history is locked.

**[Download for Apple Silicon](https://github.com/tom10271/clipvault/releases/latest/download/ClipVault-macos-arm64.zip)**

macOS 13+. Ad-hoc signed, not notarized. Unzip and move **ClipVault.app** to Applications.

## Start

1. Open ClipVault → **Create encrypted vault** → authenticate.
2. Choose **Start listening**. Allow clipboard access if macOS asks.
3. Copy text. Click the menu bar icon to unlock and browse.

![Capture while locked, then unlock to browse.](docs/diagrams/capture.svg)

## Everyday controls

| Control | What it does |
| --- | --- |
| **Item name** | Type directly. Return or leaving the field saves it. |
| **Hide** | Marks the value sensitive and remembers your choice. |
| **Show** | Reveals it for 10 seconds with a countdown. |
| **Copy** | Copies the value while leaving it hidden. |
| **Trash**, **Restore** | Removes an item reversibly. |
| **Delete permanently** | Asks for confirmation, then removes it from the current vault. |

Click outside to save the name and dismiss history. Closing history clears temporary reveals.

![Hide, show temporarily, or copy without revealing.](docs/diagrams/sensitive-items.svg)

## Settings

Open **⚙** to adjust auto-lock, clipboard expiry, retention, excluded apps, private-content filtering, or listening. Choose **Save settings** to apply changes.

## Before storing secrets

- The vault is bound to this Mac. Losing the Mac or key files can make history unrecoverable.
- Permanent deletion cannot erase backups or copies held by other apps.
- Encryption protects stored history. The system clipboard remains accessible to other apps.

[Locking, deletion and security details](DESIGN.md) · [Editable diagrams](docs/diagrams)

<details>
<summary>Build from source</summary>

Requires macOS 13+, a Secure Enclave, a Mac login password, and Swift 6 Command Line Tools.

```sh
bash scripts/test.sh
bash scripts/build-app.sh
open dist/ClipVault.app
```

Move the app to Applications.

</details>
