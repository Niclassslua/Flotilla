# Codex companion verification

Verified on September 14, 2026, using installed **Codex CLI 0.154.0**. These are explicit authenticated compatibility probes, separate from ordinary unit tests. They use real app-server instances, the production `CodexCompanionAdapter` and `ProviderRPC`, disposable conversations and files, and a separate tmux namespace. Existing Flotilla sessions are untouched.

## Results

| Feature | Evidence |
|---|---|
| Async questions: option selection | Real `agentMessage` with `delivery: async` and `questions`; phone-adapter answer reaches the model as user input. |
| Multiple questions and free text | Both answers reach the model in one message, associated with their question prompts. |
| Questions while working | Answer goes through `turn/steer`; async questions do not necessarily end the turn. |
| Questions after completion | Answer starts a new user turn through `turn/start`. |
| Question recovery | Rejoining the server restores the latest unanswered question; a newer user turn prevents old questions resurfacing. Card identity survives connection recovery. |
| Mac answers first | A turn started by another peer clears the question; a late phone answer is ignored. |
| Legacy blocking questions | Real `item/tool/requestUserInput` in Plan mode; option and write-in answers reach the model using native question IDs. |
| Command Allow / Deny | The allowed fixture file exists; the denied fixture file does not. |
| Allow / Deny with a note | The decision applies and the model explicitly responds to the note. |
| Always Allow | `acceptForSession` allows the command and suppresses another approval for the same command. Codex can omit this decision from its advertised TUI choices while still supporting it. |
| Deny and Stop | Command does not execute and the turn ends interrupted. |
| Native file-edit Allow / Deny | Real `item/fileChange/requestApproval`; the approved patch creates its file and the denied patch does not. Cards include the proposed paths and patch from `item/started`. |
| Plan revision | Feedback produces a revised plan; the implementation file is still absent. |
| Plan approval | Starts Default mode and creates the file requested by the revised plan. Any subsequent execution permission remains a separate approval. |
| Mac plan dialog | Live TUI capture establishes “Implement this plan?” before the answer and confirms its removal after the phone starts implementation. |
| Prompt | A phone-adapter prompt reaches the model, which returns the requested marker. |
| Stop | Real `turn/interrupt` ends an active turn with `status: interrupted`. |
| Duplicate approval hooks | Mac regression tests execute the generated Codex hook with `FLOTILLA_CODEX_REMOTE=1` and verify it leaves the approval to the app-server peer. |
| Phone transport | iOS simulator regression test pairs over the encrypted CompanionKit connection, receives a two-step Codex question, sends selection and free text through `CompanionStore`, and observes the card disappear after the Mac snapshot updates. |

## Fixes

The original adapter recognized only the blocking question request. Codex's newer async question is an assistant message carrying structured questions, with no JSON-RPC request to reply to. These messages now produce question cards. Answers use normal user input, retain the card on failed delivery, and track the resulting turn. Explicit stale-turn rejection permits retry as a new turn; timeout or disconnect does not silently send the answer twice.

Connection polling and phone actions share a single refresh task. Reconnection hydrates only the latest turn through `initialTurnsPage` rather than loading the entire conversation. Live model and effort changes are retained for plan approval. Stale completion notifications cannot clear a newer active turn.

Codex's plan confirmation is a TUI-local selection view. Sending `turn/start` alone starts implementation but leaves that view open. When the adapter confirms the exact plan dialog is visible and the turn is idle, it sends Escape **before** starting the phone's approval or revision. It rechecks the card after screen capture so a Mac-started turn does not also start a phone turn. Other terminal dialogs are not dismissed.

File-edit requests carry an item ID, while the proposed paths and patch arrive in `item/started`. Those are joined by thread and item ID, including subagent edits and request replay during resume.

## Running the compatibility lane

Authenticate the installed `codex` CLI and install `tmux`, then run:

```bash
python3 Scripts/verify-codex-companion.py
python3 Scripts/verify-codex-companion.py --blocking --model gpt-5.6-luna
python3 Scripts/verify-codex-companion.py --edits --model gpt-5.6-luna
```

The main probe defaults to `gpt-6-astra`, which the current account's model catalog advertises as supporting async questions. Luna and Sol did not advertise that tool in this catalog; this is a provider/model capability difference. `--model` selects another model. `--remaining` runs only session approval, plans, prompts and Stop, useful without an async-capable model.

The runner prints the CLI version, source hashes and an artifact directory. Artifacts retain RPC events, native transcripts, server logs and TUI plan captures. An isolated provider home temporarily uses the local CLI's existing authentication; its credential copy is removed during cleanup. The runner also cleans up its server and tmux session on failure or cancellation. Test-only model-switch reminders are disabled in that isolated home so they cannot obscure the plan-dialog precondition.

## Limits

- The physical iPhone UI has not been manually exercised in this run. Phone state and encrypted request delivery were verified in iOS simulator tests; native provider behavior was verified against real Mac processes. The computer-use tool did not expose the Simulator app for manual UI interaction.
- Unknown experimental approval methods with a different reply schema deliberately show **Needs your Mac**. The supported native decisions above are command and file-change approvals. MCP elicitations, permission-profile grants, authentication dialogs and TUI-local reminders do not acquire a generic Allow action.
- A model can emit malformed plan markup, such as literal `\n` characters instead of line breaks. Codex then emits a normal assistant message rather than a `plan` item. The phone follows the authoritative server item type. The compatibility probe requires an actual plan item and a visible native confirmation dialog.
- The Mac unit run initially passed 723 tests. A later 727-test run encountered two assertions in one unrelated worktree fallback test; its isolated rerun passed. That test observes a mock's worktree call before asynchronous store updates complete. Final verification results should be read alongside this timing limitation.

Protocol reference: [official Codex App Server documentation](https://learn.chatgpt.com/docs/app-server). Generated schemas from the installed CLI and native RPC events are used to check the version actually being tested.
