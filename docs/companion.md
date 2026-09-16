# Flotilla Companion — Remote Control

The iOS companion (`FlotillaCompanion`) is a remote control for a running
Flotilla on the Mac: the Mac keeps the real terminal and stays authoritative;
the phone observes sessions, prompts and stops them, creates, restarts, hands
off and deletes them, reads diffs, commits and files, and answers the
approval, question and plan dialogs of all four agents.

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
                                                  │   ├ ClaudePermissionBridge ◄ hook shim
                                                  │   └ CompanionAdapterRegistry
                                                  │       ├ Claude      ► bridge + PTY
                                                  │       ├ Codex       ► app-server peer (ProviderRPC)
                                                  │       ├ OpenCode    ► HTTP + SSE peer
                                                  │       └ Antigravity ► log + key relay
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

### UI prototypes (`-proto`)

Screenshot-review scaffolding for UI ideas not yet shipped, gated behind
`ProtoFlags` (`FlotillaCompanion/App/CompanionApp.swift`, DEBUG-only). Pass
`-proto <name>` once per flag to enable it; repeat for several at once, e.g.
`-scenario streamingClaude -proto pulsingStatusDot -proto diffPills`.

| Name | Feature |
|---|---|
| `approveSwipe` | Fleet row: leading swipe action to allow a pending permission |
| `pulsingStatusDot` | Fleet row: glowing status dot while working |
| `diffPills` | Fleet row: colored +N/−N diff summary (placement depends on `logoStatusBadge`) |
| `elapsedTimer` | Fleet row: live "1m 42s" ticker since the row last updated |
| `logoStatusBadge` | Fleet row: status dot as a corner badge on the provider logo, drops the text status label, moves the diff pill next to the branch |
| `userBubbleAccentTint` | Transcript: accent-tinted user message bubble instead of flat `surfaceElevated` |
| `codeBlockHeader` | Transcript: language badge + Copy button above fenced code, via `MarkdownCodeFence` segment splitting (see note below) |
| `toolChips` | Transcript: collapsed tool group header becomes a scrolling row of what each call touched, instead of just a count |
| `jumpPillCount` | Transcript: the "New output" jump pill shows a live count instead of a bare label |
| `thumbCardActions` | Cards (Permission/Plan/Question): primary action full-width ≥50pt at the bottom, secondary actions quieter, thumb-reachable |

`codeBlockHeader`'s implementation note: `StructuredText`'s per-block style
customization hooks (`.textual.codeBlockStyle(_:)`, `.textual.paragraphStyle(_:)`)
did not take effect in this app despite matching the package's documented
usage exactly — verified by swapping a style's entire body for an unmissable
debug marker, which never rendered. `AssistantMessageRow` works around this
by splitting a message's markdown into prose/code segments itself
(`MarkdownCodeFence`) and rendering each code segment as its own nested
`StructuredText` wrapped in a custom header, rather than depending on the
override API. Worth revisiting if a Textual version bump fixes the
underlying issue.

Dropped after the first review pass: `agentAccentBar`/`agentAccentTint`
(illegible against the black background, especially Codex's white) and
`progressBar` (read poorly at row scale).

Remove a row here once its feature ships (drops the flag) or is dropped
(deletes the code).

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

### Handshake (protocol version 2)

All frames are length-prefixed (`UInt32` big-endian, max 8 MiB).

| Step | Frame | Contents |
|---|---|---|
| 1 | `ClientHello` (plaintext JSON) | version, mode (`pair` / `resume`), Mac id, device id + name + Ed25519 key, X25519 ephemeral key, 32-byte nonce, proof |
| 2 | `ServerHello` or `ServerReject` (plaintext JSON) | X25519 ephemeral key, nonce, Mac name, Ed25519 signature over the transcript — or a reject code |
| 3+ | Sealed frames | 8-byte counter + ChaChaPoly ciphertext and tag |

- *Client transcript* = `"flotilla-companion-v2" ‖ macID ‖ deviceID ‖ deviceKey ‖ clientEphemeral ‖ clientNonce`.
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
values inside sealed frames. Version 2 prefixes each plaintext with a one-byte
encoding tag: raw JSON or LZFSE-compressed JSON (with its decoded size). Payloads
over 16 KiB are compressed only when they shrink by at least 10%. Both encoded
and decoded sizes are bounded by the frame limit.

| Client → Mac | Mac → Client |
|---|---|
| `subscribe(sessionID)` / `unsubscribe` / `resyncTranscript(sessionID)` / `resyncFleet` | `fleet(FleetSnapshot)` on connect; `fleetDelta(FleetDelta)` on changes |
| `request(id, CompanionRequest)`: `sendPrompt`, `stop`, `answer`, `createSession`, `handoff`, `restart`, `delete`, `diff`, `commits`, `file` | `transcriptSnapshot` on subscription or resync, then `transcriptDelta` on change |
| `ping` | `transcriptSnapshot(sessionID, revision, SessionTranscript)` on subscription; `transcriptDelta(sessionID, TranscriptDelta)` for overlapping changes; `response(id, CompanionResponse)` · `pong` |

Pending cards travel inside `FleetSnapshot.pending`, keyed by session.

Fleet and transcript snapshots are sent on connection/subscription, followed by
revisioned deltas. Fleet deltas carry changed rows/cards and their new order;
transcript deltas carry appended events, sliding-window eviction and live-field
changes when existing events overlap. A gap or rewritten history requests a new
full snapshot. The phone preserves its cached content during reconnection.

The phone stores paired-Mac records separately from each Mac's fleet and
transcript cache. On launch and each foreground activation, it removes cached
transcripts whose last received update is at least seven days old (including
legacy entries with no receipt time). iPhone Settings can clear transcripts for
one Mac or all Macs after confirmation. Both actions retain paired-Mac records,
fleet summaries, and unsent prompt/plan-revision drafts. A cleared or expired
snapshot replaces any pending debounced cache write so stale transcripts cannot
return from local persistence. Removing a Mac also discards its drafts.

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
7. **Bounded transcripts.** Transcripts are capped to the latest 400 events per
   session. Version 2 sends revisioned fleet and transcript deltas after full
   snapshots; on-demand diffs still use whole responses. Oversized content
   currently shows a recoverable error rather than closing the connection.
8. **Transcripts come from the agents' own files** through TranscriptKit's
   readers. Claude/Codex JSONL append records are parsed incrementally after
   the first read; watched files push updates and a one-second tick also checks
   the focused session. The
   provider adapter adds live text (Codex and OpenCode token deltas, Claude
   `MessageDisplay` lines) and failed turns. OpenCode has no file reader; its
   transcript comes from the server's message API. Antigravity writes steps
   only when they complete, and the phone never mirrors the terminal screen.
9. **Every agent's dialogs have structured answers**, through one
   `CompanionSessionAdapter` per session (`CompanionAdapterRegistry`), and the
   Mac terminal's dialog stays live — first answer wins. The agents differ in
   how Flotilla launches them (`CompanionRuntimeLaunch`, skipped under
   `UI_TESTING` and in unit tests):
   - **Claude Code**: the blocking `PermissionRequest` hook through a
     fail-open socket shim (verified in `probe-claude-live-bridge.md`).
   - **Codex**: a wrapper starts `codex app-server --listen unix://…` beside
     the TUI, which attaches with `--remote`; Flotilla is a second JSON-RPC
     client (experimental API) and answers `requestApproval` and
     `requestUserInput` server requests. Async questions arrive as
     `agentMessage` items carrying `delivery: async` and `questions`; their
     answers are normal user input through `turn/steer` or `turn/start`.
     Rejoining hydrates the latest turn to recover open questions and plans.
     Plan approval starts a default-mode turn after dismissing the recognized
     TUI-local plan confirmation, so its old prompt cannot remain over the
     implementation. File-change cards join their request with the paths and
     patch from the started item. See [Codex verification](codex-companion-verification.md)
     for the live results, repeatable probes and remaining limits.
     The runtime sets `FLOTILLA_CODEX_REMOTE=1`, which makes the
     `PermissionRequest` hook leave approvals to the peer; without the runtime
     that hook forwards to the socket bridge instead (Allow, Deny, notes only).
   - **OpenCode**: launched with `--port` on loopback and a per-launch
     `OPENCODE_SERVER_PASSWORD`; Flotilla reconciles `GET /permission` and
     `GET /question` every second and replies over REST. Autoupdate is off.
   - **Antigravity**: launched with a per-session `--log-file`. `PreToolUse`
     supplies the card content, the log proves the dialog is open (and
     resolved), and the answer is the option key typed into the TUI, chosen by
     label from the open dialog and re-checked against the log just before
     typing. Notes use arrows, `Tab` and a paste.
   Launch descriptors (endpoint, OpenCode password) are 0600 files in
   `companion-runtimes/`, never sent to the phone. A dialog opened before the
   Mac app restarted shows **Needs the terminal** (the hook event file starts
   fresh on reattach). A waiting session without an answerable request shows
   that card too, naming what it waits for.
10. **Stop** is `turn/interrupt` for Codex and `/abort` for OpenCode; Claude
    and Antigravity get Escape in the terminal. A pending Claude card is denied
    with `interrupt: true` instead.
11. **Prompts go through the adapter**: `turn/start` or `turn/steer` for
    Codex, `prompt_async` for OpenCode, a bracketed paste for Claude and
    Antigravity (Antigravity queues mid-turn prompts for `injectSteps`), and
    `AppStore.deliverMessage` for a session without an adapter. Prompts sent while working show as Queued until the
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
