# Screen detection inventory

Every place Flotilla decides something by reading the text an agent drew in
its terminal, with the exact strings it matches. Screen text is the least
stable contract in the app: no provider promises it, and a redesign or a
reworded hint silently changes what Flotilla sees. When a provider updates its
TUI, grep this page for that provider's strings and re-check each one.

## How screens are read

`SessionScreenReader.readScreen(for:)` returns the live emulator buffer when
the session's terminal is mounted. Otherwise it runs `tmux -L flotilla
capture-pane -p -t flotilla-<session UUID>`, off the main actor with a 2 s
timeout. Every consumer below uses one of these two sources.

| Consumer | Cadence | Window |
| --- | --- | --- |
| `SessionScreenMonitor` → `TerminalScreenHeuristic` (board status) | 900 ms, backing off ×2 to 3.6 s while the screen is unchanged; reclassified only when the text changes | bottom 8 non-empty lines (24 for two rules) |
| `ProcessTmuxGoalDeliverer.waitForPaneToStabilize` (before typing a prompt) | 100 ms, 6 s deadline | whole capture |
| Companion adapters (`Claude`/`Codex`/`Antigravity`/`Cursor` `CompanionAdapter`) | on refresh / before an answer | whole capture, or bottom 60 lines (Cursor) |
| `SessionActivityStore` (Home "last output") | 2 s | whole capture, display only |

## Board status: `TerminalScreenHeuristic`

Checked in this order. The first match wins. Matching is case-insensitive
substring matching on the bottom 8 non-empty lines, unless noted.

| # | Rule | Strings | Result | Providers it was written for |
| --- | --- | --- | --- | --- |
| 1 | last line starts with the tmux dead-pane banner | `[agent exited` (from `remain-on-exit-format` `[Agent exited with status N]`) | `readyForReview`, `suggestsAgentExit` | all (tmux) |
| 2 | permission heading + live choice list, **24-line window** | `requesting permission for:` and ≥ 2 numbered options, one with a `❯`/`>`/`›` caret | `waitingForInput` / `permission` | Antigravity |
| 3 | plan-approval marker | `approval for the plan`, `approve the plan`, `approve this plan`, `plan is ready`, `plan ready for approval`, `proposed plan`, `<proposed_plan>` | `waitingForInput` / `planApproval` | Codex, Claude |
| 4 | permission marker | `do you want to`, `do you trust`, `yes, i trust this folder`, `permission required`, `permission requested`, `requires permission`, `press enter to continue`, `(y/n)`, `[y/n]`, `yes/no`, `allow this`, `approve?` | `waitingForInput` / `permission` | Claude, Codex, Cursor web fetch |
| 5 | question marker | ` unanswered)`, `waiting for your answer`, `answer the question`, `provide your answer`, `question for you` | `waitingForInput` / `question` | Claude `AskUserQuestion` |
| 6 | numbered choice list with caret | `❯ 1. Yes` / `2. No` / `> 1)` …, ≥ 2 options, one with a caret | `waitingForInput` / `question` | Claude, Codex pickers |
| 7 | `SessionStatusHeuristic` | the rule 4 list plus `continue?` | `waitingForInput` (no reason) | generic |
| 8a | interrupt marker | `interrupted · what should claude do instead?`, `interrupted · what should antigravity cli do instead?` | `readyForReview` with **`endsTurn`**: the only screen observation the arbiter lets end a hook-held episode (an interrupt fires no hook) | Claude Code, Antigravity |
| 8 | finished marker | `agent exited`, `pane is dead`, `process finished` | `readyForReview`, `suggestsAgentExit` | all (tmux) |
| 9 | working marker | `esc to interrupt`, `escape to interrupt`, `esc to cancel`, `escape to cancel`, `ctrl+c to interrupt`, `ctrl-c to interrupt`, `ctrl+c to stop` | `working` | Claude (pre-2.1.291), Codex, Cursor (`ctrl+c to stop`) |
| 10 | composer above transcript, 24-line window | a line starting (after `│┃║`) with `❯`, `> ` or `› `, with a non-decoration line above it | `readyForReview` | Claude (`❯`), Codex (`›`) |
| — | nothing matched | | no observation (the status is left alone) | |

Right after rule 1, for Cursor Agent sessions only (`TerminalScreenHeuristic(agent: .cursorAgent)`), `CursorDialog.parse` checks the bottom 60 lines: an approval → `waitingForInput` / `permission`, `Ready to build?` → `planApproval`, a skip-reason/revision prompt → no observation. See `cursor-agent.md`.

The arbiter drops a screen `readyForReview` while the latest hook observation
was `working` or `waitingForInput`; see `../provider-hooks.md` → "Reaching each
status".

### Known misclassifications (fixture-backed)

| Provider | Screen | Should be | Is | Fixture |
| --- | --- | --- | --- | --- |
| Claude Code 2.1.291 | working spinner `✻ Wibbling… (8m 27s · ↓ 23.4k tokens …)` above `❯` | `working` | `readyForReview` (rule 10). No `esc to interrupt` hint any more; in practice the `UserPromptSubmit` hook holds *working* | `claude-code/screens/working-thinking.txt` |
| Cursor Agent 2026.10.01 | idle `→ Add a follow-up` | no observation (by design; `stop` hook reports it) | no observation | `cursor-agent/screens/idle.txt` |

## Prompt delivery: is the composer ready?

`ProcessTmuxGoalDeliverer` waits before `send-keys`. It returns as soon as the
capture contains any of these, or once the pane has been unchanged for three
consecutive 100 ms polls:

| String | Provider |
| --- | --- |
| `❯`, `> ` | Claude Code, generic |
| `cwd:`, `? for help`, `What would you like` | Codex / OpenCode startup UIs (**Assumed** current) |
| `→ Add a follow-up`, `→ Plan, search` | Cursor composer placeholders |
| `→ Tell the agent what to do instead`, `→ Describe how to revise the plan` | Cursor skip-reason and plan-revision prompts |

Text goes in with `send-keys -l`, or `load-buffer` + `paste-buffer -p` for
multiline text. `Enter` follows 250 ms later.

## Companion: dialog guards and answers

| Adapter | Reads | Strings | Purpose |
| --- | --- | --- | --- |
| Claude | whole screen | `Esc to cancel`, `Enter to select`, `Would you like to` | refuse a phone prompt while a terminal dialog is open |
| Codex | whole screen | `Implement this plan?` + `Yes, implement this plan` + `No, stay in Plan mode` + `esc to go back` (all four) | dismiss the TUI's local plan view with `Esc` before approving from the phone |
| Antigravity | whole screen | options regex `^\s*([›❯>])?\s*([1-9])(?:[.)]\|\s+\[[ x]\])\s+(.+)$` (last block from `1`); labels `Yes…`, `…always…conversation…` (not `persist`), `No…`, `…write-in…`; guards `Write-in...`, `Persist` | map an answer to a digit; refuse prompts mid-dialog |
| Antigravity | `--log-file` | `Surfacing`, `step <n>`, `tool confirmation`, `ask_question`, `stepIdx=<n>,`, `convID=<id>`, `AskQuestion response`, `Interrupt cleared pending tool confirmation`, `retry` | whether a request is still open; retry count |
| Cursor | bottom 60 lines, `│┃` trimmed | approval `…?` + `…(y)` + `…(esc or n)` (+ `(tab)`), `$ … in <dir>`, `Web Fetch: <url>`; plan `Ready to build?` + `…(b)` + `Saved to <path>.plan.md`; typing `→ Tell the agent what to do instead`, `→ Describe how to revise the plan`; composer `→ ` with placeholders `Add a follow-up`, `Plan, search, build anything`; working `ctrl+c` on the composer line | recognize dialogs, drafts and the working state; see `cursor-agent.md` |

## Changing a string

1. Capture the new screen as a fixture under
   `FlotillaUnitTests/ProviderFixtures/<provider>/screens/` (see
   [README.md](README.md#capturing-a-new-fixture)).
2. Keep markers in the narrowest window that works. The bottom 8 lines exist
   because transcript text above them will sooner or later quote any phrase,
   including this page's.
3. Prefer a provider's own interactive affordance (a caret, a key hint like
   `(y)`) over prose that the model could also print.
4. Update this table and the provider's page in the same change.
