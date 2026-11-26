# Backup, recovery key, restore (M6)

Code: `Core/Backup/` (`RecoveryKey`, `BackupFile`, `ReservedStorage+Recovery.swift`) and `Casita/Backup/` (scheduler, views). Tests: `CasitaTests/Backup/BackupTests.swift`.

## Words belong to spaces, not to the file

Each space is sealed to the recovery sentence it was last given (keys made before 22 Oct 2026 are 12 words; both read the same way). A new key made in any space covers that space and the spaces under it, and nothing else. A new child starts on its parent's sentence. So different spaces can be on different sentences: a backup opens with any of them, and each one reaches only its own spaces.

Why: the file used to hold one recovery public key and one reset seal. A new key made in a child replaced the file's key but re-sealed only the child's subtree, and wrote throwaway seals over every other portable slot, so the top space and everything outside the child could no longer be restored. Turning on the reset switch in a child overwrote the top's reset seal. Settings must look and work the same in every space, so the UI can't stop this. The storage now makes it safe from any space.

## On disk (`CASITA03`)

Plain file header, 4 KiB:

| offset | bytes | field |
|---|---|---|
| 0 | 8 | magic |
| 8 | 32 | device salt (rotates on restore) |
| 40 | 8 | file size |
| 48 | 32 | unused: a throwaway X25519 public key written at create (it was the file's one recovery key) |
| 80 | 32 | portable salt (never rotates) |
| 112 | rest | random padding, rewritten on every unlock attempt |

Then 32 device slots of 64 B (AES-GCM of header key + first header chunk under the Secure Enclave-stretched code), then 32 portable slots of 180 B, then chunks.

Portable slot `n`:

| offset | bytes | field |
|---|---|---|
| 0 | 32 | recovery public key for slot `n`, in plain; a throwaway key when the slot is unused or its space has no words yet |
| 32 | 148 | HPKE seal to that key (info `casita.portable.n`) of code wrap (64) ‖ reset part (36) |

- **Per-slot keys.** `RecoveryKey.privateKey(forSlot:)` is HKDF-SHA256 of the words' entropy with info `recovery.x25519.slot.n`. The key is in plain so that a backup can be sealed while every space is locked (the background task runs locked). One key per slot, not one per set of words, because the same 32 bytes in several slots would show anyone how many spaces share words.
- **Code wrap** (`SpaceHeader.codeWrap`): AES-GCM of header key + first header chunk under PBKDF2(code, portable salt, 600k), no Secure Enclave. Kept in the header so a space can re-seal the slots of the spaces under it without their codes.
- **Reset part**: the header key + first header chunk when that space's reset switch is on, 36 random bytes when off. It sits inside the same seal, so on and off look the same without the words. There is no file-level reset seal.
- **`SpaceHeader.recoveryKeys`**: the per-slot public keys of the space's words, only for the slots the space was given (`givenSlots`: its own, its spare ones, and those it handed to children). `createChild` copies the parent's entries for the granted slots. A space holds no key for any slot outside its share, so someone with a child's code can't match the plain keys of other slots against its words and find its parent or siblings.

What writes which portable slots:

| operation | slots rewritten | plain key |
|---|---|---|
| create | all 32 | fresh throwaway |
| new space | its own | its parent's key for that slot (throwaway if the parent has no words yet) |
| change code | its own (its device slot changes too) | kept |
| reset switch | every slot the space was given | kept, so used and unused slots change the same bytes |
| new recovery key | every slot the space was given | the new words' key for the space and those under it, a fresh throwaway for the rest |
| delete | the deleted spaces' | fresh throwaway |

A space only writes slots in its share, and no space outside its subtree uses those, so nothing outside can make the operation fail, count anything, or change its work. The reset switch and a new key always compute 32 seals, whatever the size of the share. For the top space the share is all 32 slots, as before.

## Backup file (`CASITAB2`)

| offset | bytes | field |
|---|---|---|
| 0 | 8 | magic |
| 8 | 32 × 80 | key seal `n`: HPKE seal (info `casita.backup.n`) of the content key to the plain key of portable slot `n` |
| 2568 | rest | the storage file in 1 MiB segments, AES-GCM under the content key, segment index as nonce and additional data |

The content key is new for every backup. Restoring with some words tries every key seal with that slot's key (no early exit). Any seal that opens gives the whole file; none means no space is sealed to these words (`wrongRecoveryKey`, and no output file). A segment that fails, or a file shorter than its header says, is `corrupt`.

Size depends only on the storage size: `BackupFile.size(forStorageBytes:)`. Two backups of the same storage have equal size and differ in every byte after the magic.

### Why keep an outer layer

A plain copy of the storage plus a small header would be simpler: no key seals, and restore is a copy. One copy of the storage already looks random apart from its plain header. But two plain copies can be compared. The chunks and slots that changed between two backups, or between a backup and the phone, show where spaces are active. Someone who forces one code out of the owner sees that space's own room, so changes outside it prove another space exists. Comparing backups must reveal nothing. With a new content key every time, every byte after the magic changes, so nobody without words can compare backups, as before. The cost is 2.5 KiB of key seals per backup and 32 plain bytes per portable slot.

### What the words give away (accepted)

Words plus a backup or a copy of the phone's file open the outer layer, show which slots are sealed to those words, and let someone guess those spaces' codes offline with PBKDF2. That was true before. What is new: words of one space no longer open the portable slots of spaces on other words. They still decrypt the backup as a whole, so a decrypted backup can be compared with the phone, as before.

## API (actor `ReservedStorage`, extension in `ReservedStorage+Recovery.swift`)

- `RecoveryKey()` / `RecoveryKey(words:)` / `.words` / `.privateKey(forSlot:)` / `.publicKey(forSlot:)`; confirm step: `confirmationIndices()` + `confirms(_:at:)`. Views: `RecoveryKeyView`, `RecoveryKeyConfirmView`.
- `setRecoveryKey(_:from:)`: from any space. Onboarding step 6 calls it from the top space; Settings "New recovery key" from the open space.
- `setResetWithRecoveryKey(_:for:)`: per space, default off. `resetCode(to:with:)` gives a new code to a space whose switch is on and whose slot opens with the words. When several match, it resets the one the others sit under (it reaches them anyway); matches that are not under one another are taken in slot order, which is random per file. Throws `cannotReset` when none matches.
- `setCode(_:for:)`: change a space's code (device slot, `codeWrap`, portable slot). Settings uses it; nothing else writes slots itself.
- `writeBackup(to:)`: needs no open space. `BackupExportButton` wraps it in `fileExporter`.
- `ReservedStorage.restore(backup:recoveryKey:to:stretcher:)`, then `adopt(code:recoveryKey:)` once per space as the user types each code. Device slots start empty under a fresh salt. Only spaces sealed to the given words adopt; spaces on other words stay in the file and can be adopted later with theirs. A parent adopted with its words also opens its children through their keys.
- `BackupScheduler.shared`: `register()` before launch finishes, set `.storage`, `schedule()` after launch and when `BackupStatus.schedule` changes. `BackupStatus.current` for Settings; `BackupStatus.takeNote()` for the one-line note on the next space open.

## Format notes

- `CASITA02` storage files and `CASITABK` backups are refused (`notCasitaFile`, `notBackupFile`). Nothing shipped in them.
- The unused key field at 48..<80 is there only so that `open(at:)` reads the header as before. Drop it, and the `publicKey` init parameter, the next time `open(at:)` changes.

## Not exercised in the simulator

- `BGProcessingTask` and the iCloud Drive container. The app target needs `BGTaskSchedulerPermittedIdentifiers` = `com.hachly.casita.backup`, `UIBackgroundModes` = `processing`, the iCloud Documents entitlement (default container) and `UTExportedTypeDeclarations` for `com.hachly.casita.backup` (`.casitabackup`), in `Support/Info.plist` and `Support/Casita.entitlements`.
- Timing of `adopt` and `resetCode` is not padded to `minimumUnlockDuration`; they only run on restore screens.
