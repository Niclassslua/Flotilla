# Antigravity

| | |
| --- | --- |
| Binary | `agy` (`AgentCatalog.antigravity`) |
| Last verified | hook payloads **2026-09-11** (models `gemini-3.8-flash-medium`; CLI version not recorded). Installed 2026-10-06: **1.3.0**, not yet re-verified |
| Primary sources | live probes; captured payloads in `FlotillaUnitTests/ProviderFixtures/antigravity/`; [`Antigravity/FORMAT.md`](../../Packages/TranscriptKit/Sources/TranscriptKit/Codecs/Antigravity/FORMAT.md) |
| Code | `HookConfigurationWriter.configureAntigravityHooks`, `HookEventReceiver` (`.antigravity`), `TerminalScreenHeuristic` (permission picker), `AntigravityCompanionAdapter`, `AntigravityWorkspaceTrust`, `ProcessAgentConversationOwnershipChecker`, `ExperimentalAntigravitySessionProvider`, `AntigravityTranscriptCodec` |

Antigravity is the most screen-dependent provider. Its hooks report tool
calls, questions and turn end, but **tool and file approval dialogs are
invisible to every hook it exposes**, so permission waits come only from the
screen. The companion combines three sources: hook payloads (what was asked),
the `--log-file` (whether it is still open), and the screen (which keys
answer it).

## Launch & configuration

| What | How | Evidence |
| --- | --- | --- |
| Hooks | `flotilla-status` group in shared `<cwd>/.agents/hooks.json`: `PreToolUse` and `PostToolUse` (matcher `*`), `Stop`, `PostInvocation`, each running `<support>/hooks/flotilla-antigravity.sh <EventName>` with `timeout: 10`. The JSON merge is locked in-process plus with `lockf` on `<support>/hooks/shared-config.lock`, fails closed on unfamiliar JSON, and keeps other keys | **Verified** (events arrive) |
| Wrapper | writes `{"event":"<argv1>","payload":<stdin>}`. The payload had no event name of its own when this was built. For `PreToolUse` it **must** print `{"decision":"allow"}` or agy may wait for a decision. For `PostInvocation` it prints and consumes `<event file>.queue` (prompts the phone sent mid-turn, as `injectSteps`) | **Verified** |
| Workspace trust | before launch, `AntigravityWorkspaceTrust.ensureTrusted` adds the raw, standardized and symlink-resolved cwd to `trustedWorkspaces` in `~/.gemini/antigravity-cli/settings.json` (or `$JETSKI_APP_DATA_DIR/settings.json`), 0600, `lockf` on `.flotilla-trust.lock`. Throws if `trustedWorkspaces` is not an array | code; prompt text below **Verified** earlier |
| Ownership guard | resuming a conversation that `ps -axo command=` shows running elsewhere is refused (`conversationAlreadyActive`), unless Flotilla's own tmux session holds it | code |
| Companion log | `--log-file <support>/companion-runtimes/<id>.agy.log` | code |
| Session identity | **discovered**; resume `--conversation <id>` | code |
| Model / effort | `--model <slug>`; effort is baked into the slug (`gemini-3.7-flash-high`), not passed as a flag | code |
| Plan mode | `--mode plan`, fresh sessions only | code |
| Initial prompt | `--prompt-interactive <text>` | code |

The trust prompt it suppresses:

```text
Accessing workspace:
<path>
Do you trust the contents of this project?
Antigravity CLI requires permission to read, edit, and execute files here.
> Yes, I trust this folder
  No, exit
```

## Status: hooks

Payload (2026-09-11): `artifactDirectoryPath`, `conversationId`, `modelName`,
`transcriptPath`, `workspacePaths[]`; tool events add `stepIdx` and
`toolCall.{name,args}` (`args` include `toolAction`/`toolSummary`
strings); `PostToolUse` adds `error`; `Stop` has `fullyIdle`,
`executionNum`, `terminationReason` (e.g. `NO_TOOL_CALL`), `error`.

| Event (variant) | Fields read | Flotilla status | Evidence |
| --- | --- | --- | --- |
| `PreToolUse` (any tool) | `toolCall.name` | `working` | **Verified** — `run_command`, `view_file`, `grep_search`, `replace_file_content`, `write_to_file` |
| `PreToolUse` `ask_question` | `toolCall.name` | `waitingForInput` / `question` | **Verified** — `args.questions[].{question, options[string], is_multi_select}` |
| `PostToolUse` | `toolCall.name` | `working` | **Verified** |
| `PostToolUse` `write_to_file` with `args.ArtifactMetadata.RequestFeedback == true` | args | `waitingForInput` / `planApproval` | **Assumed** from a live plan run; no captured fixture |
| `Stop` `fullyIdle: true` | `fullyIdle` | `readyForReview` | **Verified** |
| `Stop` `fullyIdle: false` | `fullyIdle` | no observation (async work outstanding) | **Verified** |
| `PostInvocation` | — | none (prompt injection only) | code |

## Status: screen

Antigravity relies on the screen for every approval. Two rules apply:

| Rule | Window | Status | Evidence |
| --- | --- | --- | --- |
| `requesting permission for:` **and** a live numbered choice list (≥ 2 options, one with `›`/`❯`/`>` caret) | bottom **24** non-empty lines (long commands repeated across choices push the heading up at narrow widths) | `waitingForInput` / `permission` | **Verified** earlier; no captured fixture |
| Generic markers (`do you want to`, choice list, composer, …) | bottom 8 lines | per [screen-detection.md](screen-detection.md) | code |

## Dialogs

`AntigravityCompanionAdapter`. Which dialogs are open comes from the hook file
plus the log; how to answer them comes from the screen.

| Step | Source | Strings / fields |
| --- | --- | --- |
| Candidate request | event file, last 64 KB | `PreToolUse` lines with `stepIdx`, `conversationId`, `toolCall`; `PostToolUse` `write_to_file` + `RequestFeedback` → plan card (`TargetFile` title, `CodeContent` body) |
| Is it open? | `--log-file` | last line containing `Surfacing` + `step <n>` + (`tool confirmation` or `ask_question`), not followed by `stepIdx=<n>,` + `convID=<conv>`, `AskQuestion response` + `step <n> `, or `Interrupt cleared pending tool confirmation`. Re-checked after 300 ms, since grants can surface and resolve within one tick |
| Permission card | hook args | summary `CommandLine` or `TargetFile`; detail `CodeContent` |
| Question card | hook args | `questions[].question`/`prompt`, `options[]` (strings or `{label\|text, description}`), `header`, `multiple`/`multiSelect` |
| Option keys | screen | regex `^\s*([›❯>])?\s*([1-9])(?:[.)]\|\s+\[[ x]\])\s+(.+)$`, last block starting at `1` |
| Allow / always / deny | screen labels | first option starting `Yes` without "always" / containing "always" + "conversation" but not "persist" / starting `No`. The answer types the option's digit |
| With a note | keys | arrow keys from the highlighted option to the chosen one, `Tab`, bracketed paste, `CR` |
| Question write-in | screen | option containing `write-in`, then the text pasted + `CR`; multi-select ends with `CR` |
| Deny & stop / Stop | keys | `Esc` |
| Plan approve / revise | prompt | sends `[Approved] <title>` or the revision as a prompt |
| Prompt while idle | keys | `Ctrl-A Ctrl-K` (kill the draft), bracketed paste, `CR`, `Ctrl-Y` (yank the draft back). Refused while the screen shows `Write-in...` or `Persist` |
| Prompt while working | file | appended to `<event file>.queue` as `{"injectSteps":[{"userMessage":…}]}`; delivered by `PostInvocation` |
| Retry count | log | last line containing "retry"; its last number |

## Sessions & transcripts

| What | Where / how | Evidence |
| --- | --- | --- |
| Conversation index | `~/.gemini/antigravity-cli/conversation_summaries.db`: `conversation_summaries(conversation_id, title, workspace_uris JSON, last_modified_time)` | code |
| Per-conversation dir | `~/.gemini/antigravity-cli/brain/<id>/`; display log `.system_generated/logs/transcript.jsonl` (`transcript_full.jsonl` also seen in hook payloads) | **Verified** (paths in payloads) |
| Discovery | newest brain folders (≥ launch − 60 s), title from the `USER Objective:` line (agy's own generated title, nil until written) or the DB, cwd from the DB or the log (`" -> /path"`, `"Cwd":`). A folder without a cwd matches only Flotilla's general session | code |
| Fallback discovery | `AntigravityTranscriptCodec.discoverSession` (brain dir by creation date) | code |
| Transcript codec | `~/.gemini/antigravity-cli/conversations/<id>.db`, table `steps`, unencrypted protobuf with no published schema. Read decodes user/assistant/tool/system steps; handoff writes one synthetic user step. Full details in `FORMAT.md` | **Verified** by probe (see `FORMAT.md`) |

## Models & effort

| Query | Parsed as | Evidence |
| --- | --- | --- |
| `agy models` | one model per line, `<slug> <display name…>`; skips `usage`, `available`, `name`, `agy…`, `#`, `-` lines | code |
| `agy --help` | the `--effort … (low\|medium\|high)` line, for the level set | code |
| Grouping | `ModelCatalog.groupAntigravityModels`: one picker row per family; effort picks the `-low/-medium/-high` slug | code |

## Fixtures

`FlotillaUnitTests/ProviderFixtures/antigravity/`: `PreToolUse`
(`run_command`, `ask_question`), `PostToolUse` (`view_file`, `write_to_file`
without feedback), `Stop` (`fullyIdle` true/false). Missing: plan
`RequestFeedback`, the permission-picker screen, the trust prompt, log
excerpts with `Surfacing`.

## Update checklist

1. Hooks still load from `.agents/hooks.json` under a custom top-level key;
   `PreToolUse` still requires a decision on stdout.
2. Payload: `toolCall.name`/`args`, `stepIdx`, `conversationId`,
   `fullyIdle`. Does the payload now name its own event? If so, the wrapper's
   `argv` workaround can go.
3. Still no hook for tool approvals? (If one appeared, it would replace the
   screen and log heuristics.)
4. Permission picker: heading `Requesting permission for:`, numbered options,
   labels `Yes` / `…always…conversation…` / `…persist…` / `No`, and the
   `Write-in...` option.
5. `--log-file` still logs `Surfacing … step <n> … tool confirmation`,
   `stepIdx=<n>, … convID=…`, `AskQuestion response`,
   `Interrupt cleared pending tool confirmation`. These strings are the
   companion's source of truth for dialog lifetime and the most fragile
   contract on this page.
6. `settings.json` `trustedWorkspaces` key and the trust prompt.
7. `conversation_summaries.db` columns; `brain/` layout; the `conversations/<id>.db`
   protobuf (re-run the `FORMAT.md` probes).
8. `agy models` and `agy --help` formats.

## Open items

- **Mismatch:** real `ask_question` payloads mark multi-select with
  `is_multi_select`, but `AntigravityCompanionAdapter` reads `multiple` /
  `multiSelect`. Multi-select questions therefore reach the phone as
  single-select.
- The wrapper comment says Antigravity's payload has no event name. The
  2026-09-11 payloads indeed have none; re-check on 1.3.0.
- See [codex-cli.md](codex-cli.md) → Open items: Codex 0.155.0 was observed
  running this project's `.agents/hooks.json` wrapper, including the
  `PreToolUse` `{"decision":"allow"}` reply.
- Plan feedback (`RequestFeedback`) and the permission picker have no
  captured fixtures.
