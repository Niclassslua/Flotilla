#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
out_root="$root/docs/providers/snapshots"
requested="${1:-all}"

run_cli() {
  if command -v rtk >/dev/null 2>&1; then
    rtk "$@"
  else
    "$@"
  fi
}

snapshot_provider() {
  local key="$1" binary="$2" version_args="$3" help_args="$4"
  local version raw_version destination
  if ! command -v "$binary" >/dev/null 2>&1; then
    printf 'Skipping %s: %s is not installed\n' "$key" "$binary" >&2
    return 0
  fi
  # Intentional word splitting: CLI arguments are declared as fixed strings above.
  raw_version="$(run_cli "$binary" $version_args 2>&1 | tail -n 1 || true)"
  version="$(printf '%s' "$raw_version" | grep -Eo '[0-9]+(\.[0-9A-Za-z+-]+)+' | head -n 1 | sed -E 's/[^A-Za-z0-9._+-]+/-/g; s/^-+//; s/-+$//')"
  if [[ -z "$version" ]]; then
    printf 'Could not read %s version\n' "$binary" >&2
    return 1
  fi
  destination="$out_root/$key/$version"
  mkdir -p "$destination"
  printf '%s\n' "$raw_version" > "$destination/version.txt"
  # Keep failed help output for investigation, but don't fail the whole sweep.
  run_cli "$binary" $help_args > "$destination/help.txt" 2>&1 || true
  case "$key" in
    claude-code) printf '%s\n' SessionStart UserPromptSubmit PreToolUse PermissionRequest PostToolUse PostToolUseFailure PermissionDenied Notification Stop StopFailure PreCompact PostCompact SubagentStart SubagentStop SessionEnd MessageDisplay > "$destination/hook-events.txt" ;;
    codex-cli)
      printf '%s\n' PreToolUse PermissionRequest PostToolUse Stop UserPromptSubmit SessionStart Interrupt PreCompact PostCompact SubagentStart SubagentStop SessionEnd > "$destination/hook-events.txt"
      mkdir -p "$destination/app-server-schema"
      run_cli "$binary" app-server generate-json-schema --out "$destination/app-server-schema" > "$destination/schema-generation.txt" 2>&1 || true
      ;;
    antigravity) printf '%s\n' PreInvocation PreToolUse PostToolUse Stop > "$destination/hook-events.txt" ;;
    opencode)
      printf '%s\n' tool.execute.before tool.execute.after session.status session.idle session.error session.created permission.asked permission.replied question.asked question.replied question.rejected session.compacted > "$destination/hook-events.txt"
      snapshot_opencode_doc "$destination"
      ;;
    cursor-agent) printf '%s\n' beforeSubmitPrompt preToolUse beforeShellExecution beforeMCPExecution postToolUse postToolUseFailure afterShellExecution afterFileEdit afterAgentThought afterAgentResponse subagentStart preCompact sessionEnd stop > "$destination/hook-events.txt" ;;
  esac
  printf 'Captured %s %s\n' "$key" "$version"
}

snapshot_opencode_doc() {
  local destination="$1" port pid attempt log_file
  port="${OPENCODE_DOC_PORT:-43821}"
  log_file="${TMPDIR:-/tmp}/flotilla-opencode-server-$port.log"
  run_cli opencode serve --hostname 127.0.0.1 --port "$port" > "$log_file" 2>&1 &
  pid=$!
  trap 'kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true' RETURN
  for attempt in {1..30}; do
    if curl --fail --silent "http://127.0.0.1:$port/doc" -o "$destination/openapi.json"; then
      break
    fi
    sleep 1
  done
  if [[ ! -s "$destination/openapi.json" ]]; then
    printf 'OpenCode /doc snapshot unavailable; see %s\n' "$log_file" >&2
  fi
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  trap - RETURN
}

case "$requested" in
  all|claude-code) snapshot_provider claude-code claude '--version' '--help' ;;
esac
case "$requested" in
  all|codex-cli) snapshot_provider codex-cli codex '--version' '--help' ;;
esac
case "$requested" in
  all|antigravity) snapshot_provider antigravity agy '--version' '--help' ;;
esac
case "$requested" in
  all|opencode) snapshot_provider opencode opencode '--version' '--help' ;;
esac
case "$requested" in
  all|cursor-agent)
    if command -v agent >/dev/null 2>&1; then
      snapshot_provider cursor-agent agent '--version' '--help'
    else
      snapshot_provider cursor-agent cursor-agent '--version' '--help'
    fi
    ;;
  *)
    case "$requested" in claude-code|codex-cli|antigravity|opencode) ;; *) printf 'Unknown provider: %s\n' "$requested" >&2; exit 2 ;; esac
    ;;
esac
