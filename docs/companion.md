# Flotilla Companion — Remote Control

The iOS companion (`FlotillaCompanion`) is a remote control for a running
Flotilla on the Mac: the Mac keeps the real terminal and stays authoritative;
the phone observes sessions, prompts and stops them, creates, restarts, hands
off and deletes them, reads diffs, commits and files, and answers Claude Code
permission, question and plan dialogs.

Product decisions live in `Ideas/mobile-companion/spec.md` (local, not
tracked); this document describes what is built and every assumption made
while building it.

## Architecture

```
iPhone (FlotillaCompanion)                         Mac (Flotilla)
┌─────────────────────────────┐                   ┌───────────────────────────────────┐
│ Views ─ CompanionStore      │                   │ Settings ▸ iPhone Companion        │
│           │                 │                   │   (pair, devices, addresses)       │
│  RemoteCompanionDataSource  │                   │                                   │
│   └ MacConnection (per Mac) │  TCP, E2EE frames │ CompanionHost                      │
│       └ CompanionClient ────┼──────────────────►│   ├ CompanionServer (CompanionKit) │
│  PairedMacStore + Keychain  │  LAN / Tailscale  │   ├ Bonjour _flotilla-comp._tcp    │
│  LANBrowser (Bonjour)       │                   │   ├ CompanionSnapshotBuilder ◄ AppStore
│  PairMacView + diagnosis    │                   │   ├ CompanionTranscriptReader      │
└─────────────────────────────┘                   │   ├ CompanionCommandRouter ► AppStore / GitService
                                                  │   └ ClaudePermissionBridge ◄ hook shim
                                                  └───────────────────────────────────┘
```

`CompanionKit` (local package, macOS + iOS) holds everything both ends must
agree on: the wire models, the pairing payload, the handshake, the encrypted
frame channel, and the Network.framework transport. It is tested on its own
(`swift test` in `Packages/CompanionKit`), including an in-process
server ↔ client round trip over loopback.

The prototype's `MockCompanionDataSource` stays: the **FlotillaCompanion Demo**
scheme (`make run-companion-demo`) launches the app with `-demo` on the
fixture fleet and scenarios, for UI work without a Mac.

## Building, running, testing

| Command | What it does |
|---|---|
| `make run-companion` | The real app in a simulator; pair from Flotilla ▸ Settings ▸ iPhone Companion |
| `make run-companion-demo [SCENARIO=…]` | The demo fleet, no Mac needed |
| `make test-companion` | `CompanionKit` package tests plus the iOS unit tests (including real loopback pairing) |
| `make test` | Mac unit tests, including `CompanionHostTests` (snapshot mapping, Claude hook decisions, the hook shell command against a live socket, file-access and pairing-secret rules) |

### Running on an iPhone

1. Create `Config/CompanionSigning.local.xcconfig` (gitignored) with your team:
   `DEVELOPMENT_TEAM = <TEAM ID>`. Find the ID in Xcode ▸ Settings ▸ Accounts, or
   in the `OU=` field of `security find-certificate -c "Apple Development" -p | openssl x509 -noout -subject`.
   Don't set the team in Xcode's Signing tab: `make` regenerates the project
   with XcodeGen and discards it.
2. Connect the iPhone (iOS 26 or later, Developer Mode on) and run
   `make run-companion-device`, or pick the phone in Xcode and press Run.
3. With a free Personal Team, trust the developer once on the phone under
   Settings ▸ General ▸ VPN & Device Management; the profile expires after 7 days.

End-to-end in the simulator (DEBUG): launch Flotilla with
`FLOTILLA_COMPANION_PAIRING_FILE=/tmp/pair.txt` (enables the link and writes a
fresh pairing link there), then launch the companion with
`-pairingLink "$(cat /tmp/pair.txt)"`.

## Pairing

1. On the Mac: *Settings ▸ iPhone Companion ▸ Pair iPhone…* shows a QR code
   and a copyable pairing link, valid for 5 minutes and usable once.
2. The link is `flotilla://pair?p=<base64url JSON>` carrying: protocol
   version, the Mac's id, name and Ed25519 public key, a 32-byte one-time
   secret, its expiry, the port, and every address the Mac can be reached at —
   Bonjour name, LAN IPv4 addresses, Tailscale addresses (100.64.0.0/10 and
   `fd7a:115c:a1e0::/48`) and, when the `tailscale` CLI is installed, the
   MagicDNS name.
3. On the phone: scan the QR code or paste the link. The phone tries every
   address in parallel (LAN first, Tailscale in the same race) and pairs over
   whichever answers first, showing each path's result.
4. The handshake proves possession of the secret, pins the Mac's key, and
   registers the phone's own Ed25519 key with the Mac. Later connections
   authenticate with that key; no secret is ever reused.

### Handshake (protocol version 1)

All frames are length-prefixed (`UInt32` big-endian, max 8 MiB).

| Step | Frame | Contents |
|---|---|---|
| 1 | `ClientHello` (plaintext JSON) | version, mode (`pair` / `resume`), Mac id, device id + name + Ed25519 key, X25519 ephemeral key, 32-byte nonce, proof |
| 2 | `ServerHello` or `ServerReject` (plaintext JSON) | X25519 ephemeral key, nonce, Mac name, Ed25519 signature over the transcript — or a reject code |
| 3+ | Sealed frames | 8-byte counter + ChaChaPoly ciphertext and tag |

- *Client transcript* = `"flotilla-companion-v1" ‖ macID ‖ deviceID ‖ deviceKey ‖ clientEphemeral ‖ clientNonce`.
- *Proof*: `pair` → HMAC-SHA256(secret, SHA256(client transcript));
  `resume` → Ed25519 signature by the device key over SHA256(client transcript).
- *Server signature*: Ed25519 by the Mac key over
  SHA256(client transcript hash ‖ serverEphemeral ‖ serverNonce).
- *Keys*: X25519 shared secret → HKDF-SHA256 with the combined transcript hash
  as salt, info `c2s` / `s2c`, 32 bytes each.
- *Replay*: each direction's counter starts at 0 and must increase by exactly
  one; any other value closes the connection.
- *Rejects*: `pairingExpired`, `pairingInvalid` (wrong or used secret; five
  failures burn the secret), `unknownDevice`, `revoked`, `versionUnsupported`,
  `wrongMac`.

## Protocol

After the handshake both sides exchange JSON `ClientMessage` / `ServerMessage`
values inside sealed frames.

| Client → Mac | Mac → Client |
|---|---|
| `subscribe(sessionID)` / `unsubscribe` | `fleet(FleetSnapshot)` on connect and whenever the fleet changes |
| `request(id, CompanionRequest)`: `sendPrompt`, `stop`, `answer`, `createSession`, `handoff`, `restart`, `delete`, `diff`, `commits`, `file` | `transcript(sessionID, SessionTranscript)` for the subscribed session, on change |
| `ping` | `response(id, CompanionResponse)` · `pong` |

Pending cards travel inside `FleetSnapshot.pending`, keyed by session.

Snapshots are sent whole rather than as deltas (assumption A7).

## Error surfaces on the phone

| Where | Condition | Shown as |
|---|---|---|
| Pairing, LAN | Local Network permission denied | "Allow Local Network access" with a Settings button |
| Pairing, LAN | No LAN address answered | "Not on the same network as <Mac>" + checks (Wi-Fi, guest network isolation, macOS firewall) |
| Pairing, Tailscale | No Tailscale address in the link | "Tailscale isn't set up on <Mac>" |
| Pairing, Tailscale | Tailscale not active on the iPhone (no tailnet interface) | "Turn on Tailscale on this iPhone" |
| Pairing, Tailscale | Tailnet up on both, address didn't answer | "Tailscale can't reach <Mac>" + checks (same tailnet, ACLs, Mac awake) |
| Pairing | Link malformed / expired / already used / rejected | Specific message; "Show a new code on your Mac" |
| Pairing | Protocol version mismatch | "Update Flotilla on your Mac / this app" |
| Connection | Mac's key differs from the paired one | "This Mac's identity changed" — refuses to connect, offers re-pairing |
| Connection | Device revoked on the Mac | "This iPhone was removed on <Mac>" — offers re-pairing |
| Connection | Unreachable | Cached, read-only fleet with `unreachable · last seen` (spec) |

## Assumptions

Decisions made without asking, recorded so they can be revisited.

1. **Transport is plain TCP with our own framing and E2EE**, not WebSocket or
   TLS. The spec asks for a transport-agnostic, Remodex-style E2EE protocol; a
   WebSocket wrapper adds nothing on a direct connection and can be added for
   a relay later without changing frames.
2. **Default port 48620**, falling back to a system-assigned port if taken.
   The pairing link and Bonjour record carry the real port.
3. **The server listens on all interfaces** while enabled. Tailscale needs no
   special handling on the Mac beyond advertising its tailnet addresses. The
   companion link is **off by default** and enabled in Settings.
4. **Tailscale is detected, never required.** The Mac reads tailnet addresses
   from its interfaces; the MagicDNS name only if the `tailscale` CLI exists.
   The phone detects an active tailnet by a `utun` interface holding a
   tailnet address — iOS offers no API to ask Tailscale directly.
5. **Keys.** The phone's key is a Keychain item
   (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`). The Mac's key,
   paired devices and revoked devices are 0600 JSON files in
   `Application Support/Flotilla/Companion/` (Ephemeral: `Flotilla Ephemeral`).
   Not the Keychain on the Mac: debug builds are ad-hoc signed, so a Keychain
   ACL would prompt for access after every rebuild.
6. **No push notifications, CloudKit or Live Activity in this build.** They
   need a paid Apple Developer team, APNs/CloudKit entitlements, and a signed
   build this environment cannot produce. The fleet summary copy is ready for
   the Live Activity. The phone updates live while the app is open.
7. **Whole snapshots, not deltas.** Transcripts are capped to the latest 400
   events per session. Simpler and robust to reconnects; revisit if large
   sessions make it slow.
8. **Transcripts come from the agents' own files** through TranscriptKit's
   readers, polled once a second while a phone views the session. OpenCode
   has no reader, so its sessions show status, diff and commits, and a
   "Transcript not available for OpenCode" note. Live token streaming is not
   available from files; messages appear when the agent writes them.
9. **Structured answers (permission / question / plan) are Claude Code only.**
   Claude Code's `PermissionRequest` hook is made blocking through a
   fail-open socket shim (verified in `probe-claude-live-bridge.md`); the
   terminal dialog stays live and first answer wins. Codex, OpenCode and
   Antigravity need their peer-client / relay mechanisms from
   `concept-codex-opencode-antigravity.md`, which change how Flotilla launches
   those agents; until then their waiting sessions show the **Needs the
   terminal** card naming what they wait for.
10. **Stop sends Escape** to the session's terminal, which interrupts all four
    agents' current turn. A pending Claude card is denied with
    `interrupt: true` instead.
11. **Prompts use `AppStore.deliverMessage`**, Flotilla's existing reliable
    tmux submission path. Prompts sent while working show as Queued until the
    transcript contains them.
12. **Creating a session from the phone** uses the Mac's current defaults for
    everything the phone doesn't send (title generation, worktree naming).
    The phone's project list is the Mac's known projects; General sessions use
    the Mac's general directory.
13. **Crash reasons** are not recorded by Flotilla today; the phone shows
    "The agent process exited unexpectedly".
14. **Model catalogs** sent to the phone are AgentKit's static fallback lists,
    not the live CLI discovery (which is slow and runs subprocesses).
15. **Several phones may connect at once**; all receive the same updates, and
    first answer wins across phones and the Mac.
16. **Deployability**: signing comes from `Config/CompanionSigning.xcconfig` —
    automatic, Apple Development — with the team in an untracked local
    xcconfig, so no personal team is checked in. The bundle id, display name,
    icon, Info.plist usage strings (camera, local network, Bonjour services)
    and export compliance (`ITSAppUsesNonExemptEncryption = NO` — CryptoKit
    only, standard algorithms exempt) are set.
17. **Camera scanning needs a device.** The simulator has no camera, so the
    pairing screen also accepts a pasted link; DEBUG builds accept
    `-pairingLink <link>` at launch for automated end-to-end runs.

18. **Handoff from the phone picks only the agent.** `AppStore.handoffSession`
    resets model and effort to the destination's defaults, so the phone's
    handoff sheet offers no model/effort pickers.
19. **The OpenCode subscription field is informational.** Flotilla's Mac
    create flow reads the subscription from its settings, not per session; the
    phone's choice is sent but not applied.
20. **Held Claude requests are retracted by status.** A card disappears when
    the session has been out of `waitingForInput` for more than 3 s (answered
    in the terminal, Esc, turn end). Matching `PostToolUse` by tool input is
    not implemented. Sessions started before the companion was enabled still
    get the bridge — the hook checks for the socket at request time — but
    sessions started before this build use the old observational hook.
21. **Diff line counts without file counts.** Fleet rows and the session header
    use `DiffStatStore`'s line counts (`+12 −4`), which carry no file count; the
    diff viewer fetches the full diff on demand.
22. **Sample data stays.** The prototype's mock is the demo: the
    `FlotillaCompanion Demo` scheme, `make run-companion-demo`, or `-demo`.
    `-scenario <name>` implies it.