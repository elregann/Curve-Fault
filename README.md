# CurveVault

**A local-first Android file vault and peer-to-peer secret file transfer app, built on the custom Curve256189 elliptic curve.**

> Android launcher label: **Curve Fault** · Package: `curve_fault` · Minimum Android: 7.0 (API 24)
>
> Designed and built by [elregann](https://github.com/elregann) · Curve design: [Curve256189](https://github.com/elregann/Curve256189)

CurveVault exists to answer a simple question: *what does it look like to build a real product around a non-standard elliptic curve?*

Most app tutorials stop at calling a library such as X25519 or P-256. CurveVault instead implements the curve arithmetic, key exchange, signatures, and encoding inside the project, then uses them for tangible security features: locking files in place, protecting a master seed, proving identity, and transferring files directly between two devices without a server.

> [!WARNING]
> CurveVault is an experimental, **unaudited** security project. It is intended for learning, research, and personal use. Do not rely on it as the only protection for irreplaceable or high-risk data.

---

## Table of Contents

- [Project goals](#project-goals)
- [The Curve256189 connection](#the-curve256189-connection)
- [Features](#features)
- [How it works](#how-it-works)
- [Security design](#security-design)
- [Tech stack](#tech-stack)
- [Project structure](#project-structure)
- [Getting started](#getting-started)
- [Permissions](#permissions)
- [Testing](#testing)
- [Known limitations](#known-limitations)
- [Roadmap](#roadmap)
- [Related repositories](#related-repositories)
- [Prior art and references](#prior-art-and-references)
- [License](#license)

---

## Project goals

1. **Implement Curve256189 in a working application.**  
   The elliptic-curve code lives in `lib/crypto/src` and is used directly by the vault, the identity system, and the transfer protocol. The app does not delegate identity or ECDH operations to a generic ECC package.

2. **Keep user data local.**  
   There is no account, no cloud storage, and no project backend. Files stay on the device or move directly to another device over an encrypted WebRTC data channel. The only external services involved in a transfer are public STUN/TURN servers.

3. **Make the security usable.**  
   Encryption is only useful if people can actually use it. CurveVault provides in-place file locking, passphrase and biometric unlock, shareable encrypted containers, QR-based pairing, and resumable transfers that survive the app being backgrounded.

---

## The Curve256189 connection

CurveVault is built around **Curve256189**, a custom curve designed by the same author. Its specification, parameters, and reference implementation live in the companion repository [elregann/Curve256189](https://github.com/elregann/Curve256189); this app carries its own implementation of those primitives in `lib/crypto/src` and uses them directly, rather than importing them as a black-box dependency.

| Parameter | Value |
| --- | --- |
| Field prime | `p = 2^256 − 189` |
| Curve form (Montgomery) | `y² = x³ + Ax² + x` |
| Curve coefficient | `A = 479597` |
| Cofactor | `h = 4` |
| Prime-order subgroup | `n` |
| Public key size | 32 bytes |
| Signature size | 64 bytes (`x(R) ‖ s`) |
| Scalar/seed size | 32 bytes |

Implemented primitives in `lib/crypto/src`:

| Module | Purpose |
| --- | --- |
| `x256189.dart` | X256189 ECDH with cofactor-cleared, RFC 7748-style little-endian keys |
| `xeddsa.dart` | XEdDSA signatures with canonical even-y representatives |
| `elligator.dart` | Elligator 2 encoding/decoding for uniform-looking curve points |
| `batch_verify.dart` | Randomized batch verification of XEdDSA signatures |
| `field.dart`, `montgomery.dart`, `edwards.dart` | Field and curve arithmetic |
| `hkdf.dart` | HKDF-SHA256 key derivation |
| `aesgcm.dart` | Pure-Dart AES-GCM fallback for tests and non-Android platforms |

Bulk file content is intentionally **not** pushed through the curve code. Each file gets a random 32-byte key that encrypts the data with AES-256-GCM; Curve256189 is used for identity, signatures, and wrapping that file key for a recipient. This keeps large files fast while keeping the custom curve central to the security model.

---

## Features

### Vault

- Encrypted catalogue of every locked file, searchable by filters **All / Mine / Received**.
- Per-file actions: open, save a decrypted copy, restore, share, share with an identity, delete.
- Multi-select for bulk restore and delete.
- **Recover Folder**: rebuild the vault index from `.cvlt` files after a reinstall or index loss.
- **Import Shared Files**: import encrypted containers received outside the app.
- Crash-safe lock journal: interrupted operations are finished or rolled back on the next launch.

### Lock files and folders in place

- Lock individual files or an entire folder through Android's Storage Access Framework.
- Folder locks can include subfolders while skipping hidden files and existing `.cvlt` containers.
- The original file is replaced by an encrypted `<random-id>.cvlt` container; the original name and metadata are stored **inside** the encrypted index and container, not in the on-disk filename.
- Free-space checks, chunked processing, progress reporting, and per-file failure summaries.
- Restore decrypts back to the original name and location.

### Identity and offline sharing

- A Curve256189 identity keypair is derived from the master seed.
- Copy the 64-character public key or display it as a QR code.
- **Share with Identity** re-encrypts a vault file for a recipient's public key and shares the resulting `.cvlt` container through the system share sheet.
- The recipient can open the shared container with their identity key — no need for the sender's seed or passphrase.

### Send / Receive Secret File (peer to peer)

- **Send Secret File** is available at the top of the Vault page and from each file's action sheet.
- Choose a QR validity window: **1, 5, 15, or 30 minutes** (default 5).
- The QR is shared through the system share sheet, so it works with WhatsApp or any other messaging app.
- The receiver scans the QR with the camera or selects a QR screenshot from the gallery.
- Files move directly between devices over an encrypted WebRTC data channel. No project server is involved.
- XEdDSA authentication and a proof of possession are verified **before any file bytes are sent**.
- A signed manifest binds the session, both identities, the file size, and the SHA-256 hash of the container.
- Transfers continue while the app is in the background thanks to an Android foreground service and wakelock.
- If the vault auto-locks, the Vault page offers **Resume** after unlock; the active session is not discarded.
- QR expiry applies only to the connection handshake. The file transfer itself is not time-limited.

### Protection and app lock

- Passphrase-protected master seed, encrypted with a PBKDF2-derived key.
- Optional biometric unlock using the device's fingerprint/face sensor.
- Automatic lock after 60 seconds in the background, clearing in-memory keys.
- Change passphrase and export the master seed for backup/restore.
- Full wipe that removes seeds, identity keys, the vault index, and configuration.
- Light and dark retro themes.

---

## How it works

### Key hierarchy

```text
passphrase
    │  PBKDF2-HMAC-SHA256, 60,000 iterations, random salt
    ▼
  KEK ─── AES-256-GCM ───▶ encrypted master seed (Android secure storage)
                                │  32 bytes
                 ┌──────────────┴──────────────┐
                 ▼                             ▼
        HKDF("vault-key")              XEdDSA / X256189
                 ▼                             ▼
             vault key                   identity keypair
                 │                             │
                 ├── encrypts the vault index  ├── signs auth / PoP / manifest
                 └── wraps file keys           └── ECDH for recipient key slots
```

- The **master seed** is random, never derived from the passphrase.
- The **vault key** is derived with HKDF-SHA256 using the `CurveVault-v1` salt and `vault-key` info.
- The **identity keypair** is deterministically derived from the same seed, so restoring the seed restores the identity.
- The **vault index** is encrypted with AES-256-GCM and the `CurveVault-index-v1` associated data.

### Container format (`CFV1`)

```text
magic "CFV1" | version | flags | slotCount | reserved
chunkSize (u32) | plaintextLength (u64)

slot[0..n]:
  type | nonce[12] | ephemeralPublic[32] | wrappedKey[48]

metaNonce[12] | metaLength (u32) | metadata ciphertext + tag

chunk:
  nonce[12] | ciphertextLength (u32) | ciphertext | tag[16]
```

- Data is encrypted in chunks (1 MiB by default, configurable between 1 KiB and 16 MiB).
- Slot 0 wraps the random file key with the local vault key.
- An optional slot 1 wraps the same file key for a Curve256189 recipient using an ephemeral X256189 keypair, HKDF (`share-key`), and AES-256-GCM.
- Metadata such as the original name, MIME type, and relative path is encrypted inside the container.

### Offline share with identity

```text
Sender                                           Recipient
  │ decrypt vault file                              │
  │ generate random file key                        │
  │ wrap key with vault key (slot 0)                │
  │ ECDH with recipient public key (slot 1)         │
  │ write .cvlt                                     │
  │ share via system share sheet  ────────────────▶ │ Import Shared File
  │                                                 │ unwrap key with identity
  │                                                 │ verify + add to vault
```

### Peer-to-peer transfer

The QR code carries connection data only: `cvlt1.` + base64url(gzip(JSON)) with `v`, `t`, `sid`, `from`, `exp`, and `sdp`. ICE candidates are gathered before the QR is generated, so no trickle signaling is required.

```text
Sender                                          Receiver
  │ generate session id, prepare .cvlt             │
  │ create WebRTC offer                            │
  │ ── offer QR ─────────────────────────────────▶ │ scan / gallery image
  │                                                │ verify expiry, sign PoP
  │ ◀────────────────────────────── answer QR ──── │
  │ apply answer                                   │
  │ ══════════ DTLS/SCTP data channels ══════════  │
  │ ── auth (XEdDSA) ────────────────────────────▶ │ verify sender identity
  │ ◀──────────────────────────── pop (XEdDSA) ─── │ prove recipient identity
  │ ── manifest + signature ─────────────────────▶ │ verify, create temp file
  │ ◀─────────────────────────────── accept ────── │
  │ ── 16 KiB chunks ────────────────────────────▶ │ write + count bytes
  │ ── complete ─────────────────────────────────▶ │ verify SHA-256
  │                                                │ write signed sidecar
  │                                                │ commit + import to vault
  │ ◀────────────────────────────── received ───── │
```

- Two ordered data channels: `ctrl` for JSON control messages and `data` for binary chunks.
- Backpressure is handled through `bufferedAmount` high/low watermarks.
- Public STUN servers plus OpenRelay TURN are used for NAT traversal.
- The offer QR is unsigned (so it stays small enough for one QR code); identity is proven by the signed `auth`/`pop` exchange before any bytes are sent.
- The receiver writes a signed sidecar manifest next to the container before acknowledging, so an interrupted import can be completed after the next unlock.

### Received file lifecycle

1. Container and signed sidecar are written to app-private storage.
2. The file is imported into the vault index immediately when the vault is unlocked.
3. If the app locks or is killed first, the next unlock imports pending sidecars.
4. Import re-verifies the manifest signature, recipient key, container size, SHA-256, and decryptability.
5. Duplicate containers are detected by content hash and cleaned up safely.

---

## Security design

### Protections

| Area | Mechanism |
| --- | --- |
| File contents at rest | AES-256-GCM, random per-file key, authenticated chunks |
| Key wrapping | Vault key or Curve256189 ECDH + HKDF + AES-GCM |
| Vault index | AES-256-GCM with domain-separated AAD |
| Master seed | PBKDF2-HMAC-SHA256 (60,000 iterations) + AES-GCM, stored in platform-encrypted storage |
| Identity | XEdDSA signatures over Curve256189 |
| Transfer authenticity | Signed auth, proof of possession, and signed manifest |
| Transfer integrity | SHA-256 of the whole container + size checks + AEAD tags |
| QR input | Strict schema, base64/gzip validation, decompression cap, length caps |
| Logging | No keys, seeds, or SDP contents are logged |

### Threat model

**In scope**

- Someone who obtains a locked `.cvlt` file but not the master seed.
- Tampering with a container, chunk, manifest, or signature.
- A malicious peer trying to answer someone else's offer or send forged data.
- Accidental modification or truncation during a transfer.
- Casual inspection of app storage.

**Out of scope**

- A compromised, rooted, or malware-infected device.
- Keyloggers, screen capture, or a malicious keyboard.
- Weak user passphrases (PBKDF2 is not memory-hard).
- Traffic analysis or denial of service by the network/TURN relay.
- Compromise of the Flutter, Dart, or third-party package supply chain.
- Physical coercion or legal compulsion.

### Deliberate trade-offs

- The offer QR is unsigned to keep it within one QR code. The sender and receiver authenticate each other before the first byte is sent.
- The QR contains SDP, which may include local/public IP candidates. Anyone who can see the QR can see those candidates.
- Transfers do not have a total-duration timeout; only the handshake expires. This avoids killing a legitimate large transfer on a slow link.
- Received files live in app-private storage rather than the user's file manager. They are exported through the normal save/share actions.

---

## Tech stack

| Layer | Technology |
| --- | --- |
| UI | Flutter / Material, custom light and dark retro themes |
| Cryptography | Custom Curve256189 (`lib/crypto/src`), `crypto`, `pointycastle` |
| File encryption | AES-256-GCM (native on Android, pure Dart fallback) |
| Local secrets | `flutter_secure_storage` (EncryptedSharedPreferences) |
| Biometrics | `local_auth` |
| Storage access | Android Storage Access Framework via a `MethodChannel` |
| P2P transport | `flutter_webrtc` data channels |
| QR | `qr_flutter`, `mobile_scanner`, `image_picker` |
| Background work | Android foreground service + `wakelock_plus` |

---

## Project structure

```text
lib/
├── crypto/
│   ├── curve256189.dart          # Public crypto exports
│   └── src/                      # Curve256189, XEdDSA, Elligator, HKDF, AES-GCM
├── models/
│   ├── vault_entry.dart          # Vault metadata and source tracking
│   ├── transfer_manifest.dart    # Signed file manifest
│   └── transfer_session.dart     # Transfer phases and errors
├── pages/
│   ├── setup_page.dart           # Passphrase setup / seed restore
│   ├── unlock_page.dart          # Passphrase and biometric unlock
│   ├── vault_page.dart           # Vault list, actions, filters, resume banner
│   ├── encrypt_page.dart         # Lock files and folders
│   ├── identity_page.dart        # Public key, QR, passphrase, seed, wipe
│   ├── send_secret_page.dart     # P2P sender UI
│   ├── receive_secret_page.dart  # P2P receiver UI
│   └── scan_qr_page.dart         # Camera and gallery QR scanner
├── services/
│   ├── vault_service.dart        # Vault operations, index, import/restore
│   ├── vault_crypto.dart         # CFV1 container and key slots
│   ├── seed_service.dart         # Seed generation, protection, biometrics
│   ├── native_storage.dart       # SAF, share, open, foreground service bridge
│   ├── app_lock.dart             # Background auto-lock policy
│   └── transfer/                 # WebRTC, QR codec, auth, storage, sender/receiver
└── theme/                        # App sizing and theme controller

test/
├── vault_crypto_test.dart
├── vault_crypto_tamper_test.dart
├── vault_recovery_test.dart
├── session_and_crypto_test.dart
├── lock_access_test.dart
├── lock_picker_test.dart
├── unlock_action_tile_test.dart
├── vault_page_test.dart
├── transfer_auth_test.dart
└── transfer_qr_test.dart
```

Android-specific code lives in `android/app/src/main/kotlin/com/CurveFault/curve_fault/`:

- `MainActivity.kt` — SAF, native AES-GCM, share/open, foreground-service bridge.
- `TransferService.kt` — foreground service that keeps a transfer alive in the background.

---

## Getting started

### Requirements

- Flutter with Dart `^3.10.4` (see `pubspec.yaml`).
- Android SDK with **minSdk 24**.
- An Android device or emulator. The complete feature set is Android-only.
- For P2P testing: two devices, ideally on different networks.

### Install and run

```bash
flutter pub get
flutter analyze
flutter test
flutter run
```

### Build

```bash
# Debug build
flutter build apk --debug

# Release build (configure your signing keystore first)
flutter build apk --release
```

### Regenerate launcher icons

```bash
dart run flutter_launcher_icons
```

### First use

1. Create a passphrase (at least 8 characters) or restore an existing 32-byte master seed.
2. Open the **Encrypt** tab and lock a file or folder.
3. Open the **Identity** tab to copy your public key or show its QR code.
4. To share offline, use **Share with Identity** on a vault file and send the `.cvlt` container.
5. To transfer directly, use **Send Secret File** on the Vault page and follow the QR exchange.

> Keep the exported master seed offline and secret. Losing it makes every locked `.cvlt` file unreadable. Anyone who obtains it can open all of your files.

---

## Permissions

| Permission | Why it is needed |
| --- | --- |
| `INTERNET`, `ACCESS_NETWORK_STATE` | WebRTC peer-to-peer transfer |
| `CAMERA` | Scanning transfer QR codes |
| `USE_BIOMETRIC` | Optional biometric unlock |
| `WAKE_LOCK` | Keeping the CPU awake during an active transfer |
| `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_DATA_SYNC` | Keeping a transfer alive when the app is backgrounded |
| `POST_NOTIFICATIONS` | Showing the required foreground-service notification on Android 13+ |

File access uses the Storage Access Framework, so no broad storage permission is requested.

---

## Testing

The project uses `flutter_test` and includes unit and widget tests for:

- Container encryption, decryption, tamper detection, and multi-chunk files.
- Recipient key slots and identity-based opening.
- Vault index recovery and pending-lock journal behavior.
- Seed/session handling and lock access rules.
- QR payload validation, size caps, expiry, and malformed input.
- XEdDSA auth, proof-of-possession, and manifest signature verification.
- Vault page behavior, including received-file handling.

Run everything with:

```bash
flutter analyze
flutter test
```

At the time of writing, the suite contains **114 passing tests**. Tests do not exercise real WebRTC connections; those require two devices.

---

## Known limitations

- **Android only.** The native storage bridge, foreground service, and auto-lock behavior are implemented for Android. The Flutter project still contains an iOS target, but the full feature set is not implemented there.
- **Unaudited cryptography.** The Curve256189 implementation and protocol design have not received a formal security audit.
- **Side-channel resistance is not guaranteed.** Dart `BigInt` arithmetic is not constant-time. This is acceptable for an experimental project but not for a hardened production wallet.
- **No forward secrecy for stored files.** All containers are protected by keys derived from the same master seed. Compromising the seed compromises every locked file.
- **PBKDF2, not Argon2id.** The passphrase KDF is intentionally simple and mobile-friendly, but it is not memory-hard.
- **External network dependency.** P2P transfers rely on public STUN and OpenRelay TURN servers for NAT traversal.
- **Transfer reliability depends on the OS.** Aggressive battery optimization or process death can still interrupt a long transfer.
- **No formal protocol versioning migration yet.** The QR payload, manifest, and container formats are versioned (`cvlt1`, manifest `v1`, `CFV1`), but automatic migration between future versions is not implemented.

---

## Roadmap

Possible next steps, in no particular order:

- Replace PBKDF2 with Argon2id.
- Hardware-backed key wrapping with Android Keystore/StrongBox.
- iOS and desktop support for the vault and transfer flows.
- Animated/multi-frame QR codes for larger connection payloads.
- Audited, constant-time curve implementation.
- Optional local-network transport with automatic fallback.
- More end-to-end tests around transfer interruption and resume.

---

## Related repositories

Both repositories are maintained by the same author:

- [Curve-Fault](https://github.com/elregann/Curve-Fault) — this repository, the Android application.
- [Curve256189](https://github.com/elregann/Curve256189) — the curve design, parameters, and reference implementation that this app embeds and exercises.

The curve code in `lib/crypto/src` is the application's own implementation of that design, not a third-party dependency.

---

## Prior art and references

- RFC 7748 (X25519) for the little-endian key encoding and scalar-clamping conventions.
- XEdDSA and Elligator 2 as designed in the Curve25519/Signal ecosystem.
- The Flutter, Dart, and open-source packages listed in `pubspec.yaml`.

---

## License

Released under the [MIT License](LICENSE).

Copyright (c) 2026 elregann.

MIT is permissive: you may use, modify, and redistribute this software, including commercially, as long as the copyright notice and permission notice are retained. The software is provided **without warranty of any kind** — see [`LICENSE`](LICENSE) for the full text.

---

## Disclaimer

CurveVault is a learning and research project. It is provided **as is**, without warranty of any kind. The author is not responsible for data loss, security incidents, or misuse. If you need production-grade protection, use audited, widely reviewed tools and keep independent backups of anything important.
