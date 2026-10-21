#!/usr/bin/env bash
# Compare documented provider baselines to installed (and optional upstream) versions.
# Usage: Scripts/provider-check.sh [--upstream] [--snapshot] [--notes|--notes-full] [--strict] [provider-key|all]
# Exit 0 when the check ran; with --strict, exit 1 on drift. Exit 2 on usage/config errors.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
versions_file="$root/docs/providers/versions.json"
readme="$root/docs/providers/README.md"
check_upstream=0
run_snapshot=0
show_notes=0
notes_full=0
strict=0
requested=all

usage() {
  printf 'Usage: %s [--upstream] [--snapshot] [--notes|--notes-full] [--strict] [provider-key|all]\n' "$(basename "$0")" >&2
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --upstream) check_upstream=1; shift ;;
    --snapshot) run_snapshot=1; shift ;;
    --notes) show_notes=1; shift ;;
    --notes-full) show_notes=1; notes_full=1; shift ;;
    --strict) strict=1; shift ;;
    -h|--help) usage ;;
    -*)
      printf 'Unknown flag: %s\n' "$1" >&2
      usage
      ;;
    *)
      requested="$1"
      shift
      ;;
  esac
done

if [[ ! -f "$versions_file" ]]; then
  printf 'Missing %s\n' "$versions_file" >&2
  exit 2
fi

normalize_version() {
  # Match provider-snapshot.sh: first version-like token, sanitized for paths.
  printf '%s' "$1" | grep -Eo '[0-9]+([.][0-9A-Za-z+-]+)+' | head -n 1 | sed -E 's/[^A-Za-z0-9._+-]+/-/g; s/^-+//; s/-+$//' || true
}

version_cmp() {
  # Prints -1 / 0 / 1 for a < b / equal / a > b. Uses sort -V.
  local a="$1" b="$2"
  if [[ "$a" == "$b" ]]; then
    printf '0'
    return
  fi
  local first
  first="$(printf '%s\n%s\n' "$a" "$b" | sort -V | head -n 1)"
  if [[ "$first" == "$a" ]]; then
    printf -- '-1'
  else
    printf '1'
  fi
}

resolve_binary() {
  local primary="$1"
  shift
  if command -v "$primary" >/dev/null 2>&1; then
    printf '%s' "$primary"
    return 0
  fi
  local alt
  for alt in "$@"; do
    if [[ -n "$alt" ]] && command -v "$alt" >/dev/null 2>&1; then
      printf '%s' "$alt"
      return 0
    fi
  done
  return 1
}

installed_version() {
  local binary="$1"
  local raw
  raw="$("$binary" --version 2>&1 | tail -n 1 || true)"
  normalize_version "$raw"
}

github_latest() {
  local repo="$1"
  local tag
  if ! command -v gh >/dev/null 2>&1; then
    return 1
  fi
  tag="$(gh api "repos/$repo/releases/latest" --jq '.tag_name // empty' 2>/dev/null || true)"
  if [[ -z "$tag" ]]; then
    tag="$(gh api "repos/$repo/tags?per_page=1" --jq '.[0].name // empty' 2>/dev/null || true)"
  fi
  tag="${tag#v}"
  normalize_version "$tag"
}

# Cursor Agent's update service via the installed CLI (same source as `agent update`).
cursor_latest() {
  local binary="$1"
  local raw ver
  raw="$("$binary" --disable-auto-update about --format json 2>/dev/null || true)"
  [[ -z "$raw" ]] && return 1
  ver="$(printf '%s' "$raw" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("latestVersion") or "")' 2>/dev/null || true)"
  [[ -z "$ver" ]] && return 1
  normalize_version "$ver"
}

provider_lines="$(python3 - "$versions_file" "$requested" <<'PY'
import json, sys
path, requested = sys.argv[1], sys.argv[2]
data = json.load(open(path))
keys = {p["key"] for p in data["providers"]}
if requested != "all" and requested not in keys:
    sys.stderr.write(f"Unknown provider: {requested}\n")
    sys.exit(2)
for p in data["providers"]:
    if requested not in ("all", p["key"]):
        continue
    alts = ",".join(p.get("altBinaries") or [])
    upstream = p.get("upstream") or {"kind": "none"}
    print("|".join([
        p["key"],
        p["name"],
        p["binary"],
        alts,
        p["validThrough"],
        p.get("checked", ""),
        p["doc"],
        p.get("notes", ""),
        upstream.get("kind", "none"),
        upstream.get("repo", ""),
    ]))
PY
)"

printf '%-14s %-22s %-22s %-22s %s\n' 'PROVIDER' 'DOCUMENTED' 'INSTALLED' 'UPSTREAM' 'STATUS'
printf '%-14s %-22s %-22s %-22s %s\n' '--------' '----------' '---------' '--------' '------'

drifted=''
missing=''
readme_warn=0

while IFS='|' read -r key name binary alts_csv valid checked doc notes up_kind up_repo; do
  [[ -z "$key" ]] && continue

  installed='—'
  upstream='—'
  status='ok'
  binary_used=''

  # Word-split alt binaries on commas.
  old_ifs=$IFS
  IFS=','
  # shellcheck disable=SC2086
  set -- $alts_csv
  IFS=$old_ifs

  if binary_used="$(resolve_binary "$binary" "$@")"; then
    ver="$(installed_version "$binary_used" || true)"
    if [[ -z "$ver" ]]; then
      installed='?'
      status='unreadable'
    else
      installed="$ver"
      cmp="$(version_cmp "$valid" "$ver")"
      if [[ "$cmp" == '-1' ]]; then
        status='NEWER INSTALLED'
        drifted="$drifted $key"
      elif [[ "$cmp" == '1' ]]; then
        status='behind docs'
      fi
    fi
  else
    installed='(not installed)'
    missing="$missing $key"
    status='skipped'
  fi

  if [[ "$check_upstream" -eq 1 ]]; then
    up_ver=''
    case "$up_kind" in
      github)
        if [[ -n "$up_repo" ]]; then
          up_ver="$(github_latest "$up_repo" || true)"
        fi
        ;;
      cursor-about)
        if [[ -n "${binary_used:-}" ]]; then
          up_ver="$(cursor_latest "$binary_used" || true)"
        fi
        ;;
      none|"")
        upstream='(manual)'
        ;;
    esac

    if [[ "$up_kind" == 'github' || "$up_kind" == 'cursor-about' ]]; then
      if [[ -z "$up_ver" ]]; then
        upstream='?'
        if [[ "$status" == 'ok' ]]; then
          status='upstream?'
        fi
      else
        upstream="$up_ver"
        up_cmp="$(version_cmp "$valid" "$up_ver")"
        if [[ "$up_cmp" == '-1' ]]; then
          case "$status" in
            ok|skipped|behind\ docs) status='NEWER UPSTREAM' ;;
          esac
          case " $drifted " in
            *" $key "*) ;;
            *) drifted="$drifted $key" ;;
          esac
        fi
      fi
    fi
  fi

  if ! grep -Fq "$valid" "$readme" 2>/dev/null; then
    readme_warn=1
  fi

  printf '%-14s %-22s %-22s %-22s %s\n' "$key" "$valid" "$installed" "$upstream" "$status"
done <<<"$provider_lines"

if [[ "$readme_warn" -eq 1 ]]; then
  printf '\nWarning: docs/providers/README.md is missing a validThrough value from versions.json — keep them in sync.\n' >&2
fi

drifted="${drifted# }"
missing="${missing# }"

if [[ -z "$drifted" ]]; then
  printf '\nAll checked providers match the documented baseline'
  if [[ "$check_upstream" -eq 1 ]]; then
    printf ' (and queried upstream where available)'
  fi
  printf '.\n'
  if [[ -n "$missing" ]]; then
    printf 'Skipped (not installed): %s\n' "$missing"
  fi
  exit 0
fi

printf '\nDrift detected: %s\n' "$drifted"
if [[ "$show_notes" -eq 0 ]]; then
  printf 'Next: Scripts/provider-snapshot.sh <provider> → checklist in docs/providers/<provider>.md → bump versions.json + README + CHANGES.md\n'
  printf 'Tip: make provider-check ARGS="--upstream --notes" for a digest.\n'
fi

if [[ "$run_snapshot" -eq 1 ]]; then
  printf '\nCapturing snapshots for drifted providers…\n'
  for key in $drifted; do
    "$root/Scripts/provider-snapshot.sh" "$key" || true
  done
fi

if [[ "$show_notes" -eq 1 ]]; then
  notes_flag=()
  if [[ "$notes_full" -eq 1 ]]; then
    notes_flag=(--full)
  fi
  for key in $drifted; do
    after="$(
      python3 - "$versions_file" "$key" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
print(next(p["validThrough"] for p in data["providers"] if p["key"] == sys.argv[2]))
PY
    )"
    python3 "$root/Scripts/provider-notes.py" "${notes_flag[@]}" "$versions_file" "$key" "$after" || true
  done
  printf '\nRe-verify: snapshot → docs/providers/<provider>.md checklist → bump versions.json + README + CHANGES.md\n'
fi

if [[ "$strict" -eq 1 ]]; then
  exit 1
fi
exit 0
