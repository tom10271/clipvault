# ClipVault

Native macOS menu bar clipboard history for sensitive text. No network, cloud sync, analytics, dependencies, or infrastructure changes.

## Chosen design

Compare two shapes. A SQLite database offers incremental writes but adds journaling and plaintext-index risks. An AES-256-GCM encrypted JSON snapshot keeps content and metadata under one authenticated encryption boundary and supports a bounded personal history. Choose the snapshot.

`ClipboardEntry` contains UUID, text, creation date, optional deletion date, optional name, and saved sensitivity. Old records without the new fields decode as unnamed and visible by default. `VaultSettings` contains auto-lock seconds, history limit, retention days, clipboard-clear seconds, concealed-content exclusion, and excluded application bundle IDs. One main-actor controller owns state. Session state is locked, unlocking, or unlocked with the key and entries. The encrypted store owns atomic persistence. The Secure Enclave owns an access-controlled P-256 key. ECDH and HKDF-SHA256 derive the AES-256 key, and private operations require user presence. A hardware-wrapped key representation, peer public key, and salt live beside the encrypted history. No raw history key or software peer private key for the Secure Enclave agreement is persisted. A separate inbox P-256 private key is stored only inside the encrypted history document; its public key and capture-policy projection form the authenticated public snapshot header.

Text capture runs whenever explicitly enabled, including while history is locked and before authentication after restart. Every copy enters a public-key-encrypted inbox. An authenticated session imports the inbox into history. Locking releases the history key, inbox private key, and decrypted entries, hides sensitive UI, and clears searches and revealed content without changing capture policy. Background capture never resets the inactivity timer. Deliberately copying an item in ClipVault counts as app interaction. Only deliberate user interaction with ClipVault resets it. Sleep, session resignation, and screen lock lock the vault. Expired activity is checked before every sensitive action, as timers can be delayed.

Soft delete moves entries to Trash. Restore returns them to History. Permanent delete confirms and saves a replacement encrypted snapshot before publishing the new state. Hard deletion cannot promise physical erasure from APFS, SSDs, swap, or backups. Deleting an entry also clears the live clipboard if it still matches that entry. Copied history entries have transient/concealed markers and a conditional expiry that never clears newer unrelated clipboard content.

## Scope

New standalone Swift package, native views, encrypted store, authentication adapter, clipboard controller, deterministic tests, app bundle/build script, settings window, and README. No changes to HBX files. macOS 13 or newer with a Secure Enclave and a Mac login password, text only, 1 MiB maximum per entry. Native Mac password fallback rather than another application password. No launch at login or image/file capture in this version.

## Verification

Use temporary directories and a named test pasteboard. Test encryption, corruption rejection, durable delete/restore, failed writes, limits, lock timing, capture exclusion, and clipboard expiry. Build the actual .app, inspect signing and privacy permissions, launch locked, and exercise native views. Real Touch ID and login-password approval require the owner and must be reported separately from simulated tests.

## Verified platform adjustment

The root agent verified that ad-hoc signing cannot access the data-protection Keychain (OSStatus -34018), while Secure Enclave key creation, serialization, and reconstruction work, and unauthenticated private operations are blocked with LocalAuthentication code -1004. This evidence replaces the initial Keychain key-storage proposal with hardware-bound ECDH derivation. There is no weaker key-storage fallback and no cross-Mac recovery.

## Encrypted background capture

CLIPVAULT2 snapshots authenticate their public header as AES-GCM associated data. The header publishes only the inbox public key, capture policy, and imported sequence watermark. Loading still accepts CLIPVAULT1; the first authorized save creates an inbox key and migrates atomically without changing the Secure Enclave key envelope. Capture preferences and filesystem activity metadata are public; copied text and private keys remain encrypted.

Each inbox record uses fresh ephemeral P-256 ECDH, HKDF-SHA256, and AES-256-GCM. Sequence numbers are authenticated and allocated durably before writing ciphertext. The authenticated history snapshot advances its imported watermark before ciphertext cleanup. Retrying import ignores acknowledged sequences, preserving hard deletion even if old ciphertext survives a crash. Capture and history access have separate state owners inside the main-actor controller. There is no history-decryption capability in the locked collector. Explicit pause remains an authenticated setting.

## Saved sensitivity and temporary display

Ordinary values display while history is authenticated. Hide persists sensitivity inside the encrypted entry; names also remain private to the snapshot. The controller owns separate ephemeral reveal deadlines, which expire after 10 seconds and clear on history close or lock. Copy does not reveal a value or change its sensitivity. The UI shows sensitive names and masks values in both visible text and accessibility labels. Search includes names and only currently visible values.

Sensitivity changes atomically update all retained entries with identical text, including Trash, so an explicit Always show choice is not undone by an older hidden duplicate. Names remain per item. A retained matching value supplies name and sensitivity when later copies are imported. This happens only after authorized decryption; the locked collector never learns private metadata. All entry mutation validates and saves before publishing.

A real status-bar button action can start existing native authentication for a configured locked vault. Startup passes no button sender and cannot prompt. The existing controller prevents duplicate authentication; history reopens once after successful icon-initiated authentication. Popover closure clears transient previews without canceling that explicitly requested authentication.
