#!/usr/bin/env python3
"""Digest upstream changelog + snapshot delta after a documented version.

Usage: provider-notes.py [--full] <versions.json> <provider-key> <after-version>
"""
from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
import sys
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

# Lines that usually matter for Flotilla's provider integration.
RELEVANT = re.compile(
    r"(?i)\b("
    r"hook|permission|approval|trust|dialog|status|screen|transcript|"
    r"session(?:id|[- ]?id)?|resume|osc\s*7501|companion|app-server|"
    r"json-rpc|plugin|stop\b|notification|ask.?user|plan mode"
    r")\b"
)


def normalize_version(raw: str) -> str:
    m = re.search(r"[0-9]+(?:[.][0-9A-Za-z+-]+)+", raw or "")
    if not m:
        return ""
    return re.sub(r"[^A-Za-z0-9._+-]+", "-", m.group(0)).strip("-")


def version_cmp(a: str, b: str) -> int:
    if a == b:
        return 0
    proc = subprocess.run(
        ["bash", "-c", 'printf "%s\\n%s\\n" "$1" "$2" | sort -V | head -n 1', "_", a, b],
        capture_output=True,
        text=True,
        check=False,
    )
    first = (proc.stdout or "").strip()
    return -1 if first == a else 1


def newer_than(candidate: str, after: str) -> bool:
    return bool(candidate) and version_cmp(after, candidate) < 0


def is_prerelease(tag_or_ver: str) -> bool:
    return bool(re.search(r"(?i)(^|[.-])(alpha|beta|rc)([.-]|$)", tag_or_ver or ""))


def fetch_text(url: str, timeout: float = 20.0) -> str:
    # Cursor's docs CDN is picky; prefer curl when present, plain urllib otherwise.
    if shutil.which("curl"):
        proc = subprocess.run(
            ["curl", "-fsSL", "-A", "Flotilla-provider-check/1.0", url],
            capture_output=True,
            text=True,
            check=False,
            timeout=timeout,
        )
        if proc.returncode == 0 and proc.stdout:
            return proc.stdout
        err = (proc.stderr or "").strip() or f"curl exit {proc.returncode}"
        raise RuntimeError(err)
    req = urllib.request.Request(url, headers={"User-Agent": "Flotilla-provider-check/1.0"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.read().decode("utf-8", errors="replace")
    except urllib.error.HTTPError as exc:
        raise RuntimeError(f"HTTP {exc.code}") from exc


def gh_json(path: str):
    if not shutil.which("gh"):
        raise RuntimeError("gh not installed")
    proc = subprocess.run(
        ["gh", "api", path],
        capture_output=True,
        text=True,
        check=False,
    )
    if proc.returncode != 0:
        raise RuntimeError(proc.stderr.strip() or f"gh api {path} failed")
    return json.loads(proc.stdout)


def slice_markdown_sections(text: str, after: str) -> list[tuple[str, str]]:
    parts = re.split(r"(?m)^(##\s+.+)$", text)
    entries: list[tuple[str, str]] = []
    i = 1
    while i + 1 < len(parts):
        heading, body = parts[i], parts[i + 1]
        i += 2
        ver = normalize_version(heading)
        if not ver:
            continue
        if newer_than(ver, after):
            entries.append((ver, body.strip()))
        elif version_cmp(ver, after) <= 0:
            break
    return entries


def github_release_notes(repo: str, after: str) -> list[tuple[str, str]]:
    data = gh_json(f"repos/{repo}/releases?per_page=50")
    after_is_stable = not is_prerelease(after)
    entries: list[tuple[str, str]] = []
    for rel in data:
        if rel.get("draft"):
            continue
        tag = rel.get("tag_name") or ""
        ver = normalize_version(tag)
        if not newer_than(ver, after):
            continue
        if after_is_stable and (
            rel.get("prerelease") or is_prerelease(tag) or is_prerelease(ver)
        ):
            continue
        body = (rel.get("body") or "").strip() or "_(no release notes)_"
        entries.append((ver, body))
    return entries


def cursor_cli_changelog(after: str) -> list[tuple[str, str]]:
    text = fetch_text("https://cursor.com/docs/cli/changelog.md")
    return slice_markdown_sections(text, after.split("-", 1)[0])


def bullet_lines(body: str) -> list[str]:
    lines = []
    for raw in body.splitlines():
        s = raw.strip()
        if s.startswith(("- ", "* ", "· ")):
            lines.append(re.sub(r"^[-*·]\s+", "", s))
        elif re.match(r"^\*\*[^*].+\*\*", s):  # Cursor **Title.** style
            lines.append(re.sub(r"^\*\*|\*\*$", "", s).strip(" ."))
    return lines


def relevant_hits(entries: list[tuple[str, str]], limit: int = 8) -> list[str]:
    hits: list[str] = []
    for ver, body in entries:
        for line in bullet_lines(body):
            if RELEVANT.search(line):
                short = line if len(line) <= 140 else line[:137].rstrip() + "…"
                hits.append(f"{ver}: {short}")
                if len(hits) >= limit:
                    return hits
                break  # one hit per release is enough in digest mode
    return hits


def format_digest(entries: list[tuple[str, str]], notes_url: str) -> str:
    if not entries:
        return "  Changelog: (none newer than documented)\n"
    newest = entries[0][0]
    oldest = entries[-1][0]
    span = newest if newest == oldest else f"{newest} … {oldest}"
    lines = [f"  Changelog: {span} ({len(entries)} release(s))"]
    if notes_url:
        lines.append(f"  Full notes: {notes_url}")
    hits = relevant_hits(entries)
    if hits:
        lines.append("  Likely relevant:")
        lines.extend(f"    - {h}" for h in hits)
    else:
        lines.append("  Likely relevant: (no hook/permission/status/session hits in skim)")
    return "\n".join(lines) + "\n"


def format_full(entries: list[tuple[str, str]]) -> str:
    if not entries:
        return "  (no changelog entries newer than documented)\n"
    out = []
    for ver, body in entries[:12]:
        if len(body) > 1800:
            body = body[:1800].rstrip() + "\n… (truncated)"
        out.append(f"### {ver}\n{body}\n")
    if len(entries) > 12:
        out.append(f"… {len(entries) - 12} more release(s) omitted\n")
    return "\n".join(out)


def snapshot_versions(base: Path) -> list[str]:
    names = [p.name for p in base.iterdir() if p.is_dir()]
    if not names:
        return []
    proc = subprocess.run(
        ["bash", "-c", "printf '%s\n' \"$@\" | sort -V", "_", *names],
        capture_output=True,
        text=True,
        check=False,
    )
    return [v for v in (proc.stdout or "").splitlines() if v]


def snapshot_diff(key: str, after: str, full: bool) -> str:
    base = ROOT / "docs" / "providers" / "snapshots" / key
    if not base.is_dir():
        return ""
    versions = snapshot_versions(base)
    if not versions:
        return ""

    old = after if (base / after).is_dir() else None
    newer = [v for v in versions if newer_than(v, after)]
    new = newer[-1] if newer else versions[-1]
    if old is None:
        older = [v for v in versions if version_cmp(v, after) <= 0]
        old = older[-1] if older else None
    if old is None or old == new:
        return f"  Snapshot: only {new} on disk (need prior capture to diff).\n"

    summary: list[str] = []
    hunks: list[str] = []
    for name in ("hook-events.txt", "help.txt", "version.txt"):
        a, b = base / old / name, base / new / name
        if not a.exists() and not b.exists():
            continue
        proc = subprocess.run(
            ["diff", "-u", str(a), str(b)],
            capture_output=True,
            text=True,
            check=False,
        )
        if proc.returncode == 0:
            summary.append(f"{name}=same")
            continue
        diff_lines = (proc.stdout or "").splitlines()
        changed = [
            ln
            for ln in diff_lines
            if ln.startswith(("+", "-")) and not ln.startswith(("+++", "---"))
        ]
        summary.append(f"{name}={len(changed)}Δ")
        if full:
            hunks.extend(diff_lines[:40])
    for sub in ("app-server-schema", "openapi.json"):
        a, b = base / old / sub, base / new / sub
        if a.is_dir() and b.is_dir():
            ac = sum(1 for _ in a.rglob("*") if _.is_file())
            bc = sum(1 for _ in b.rglob("*") if _.is_file())
            if ac != bc:
                summary.append(f"{sub}={ac}→{bc}")
        elif a.is_file() and b.is_file() and a.read_bytes() != b.read_bytes():
            summary.append(f"{sub}=changed")

    line = f"  Snapshot: {old} → {new} ({', '.join(summary)})\n"
    if full and hunks:
        line += "".join(f"    {ln}\n" for ln in hunks)
    return line


def changelog_for(provider: dict, after: str) -> list[tuple[str, str]]:
    cfg = provider.get("changelog") or {}
    kind = cfg.get("kind") or "none"
    if kind == "github-markdown":
        repo = cfg.get("repo") or (provider.get("upstream") or {}).get("repo")
        path = cfg.get("path") or "CHANGELOG.md"
        if not repo:
            return []
        return slice_markdown_sections(
            fetch_text(f"https://raw.githubusercontent.com/{repo}/main/{path}"), after
        )
    if kind == "github-releases":
        repo = cfg.get("repo") or (provider.get("upstream") or {}).get("repo")
        if not repo:
            return []
        return github_release_notes(repo, after)
    if kind == "cursor-cli-docs":
        return cursor_cli_changelog(after)
    return []


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--full", action="store_true", help="dump full changelog bodies")
    parser.add_argument("versions_json")
    parser.add_argument("key")
    parser.add_argument("after")
    args = parser.parse_args()

    data = json.loads(Path(args.versions_json).read_text())
    provider = next((p for p in data["providers"] if p["key"] == args.key), None)
    if not provider:
        print(f"Unknown provider: {args.key}", file=sys.stderr)
        return 2

    print(f"\n-------- {args.key} (since {args.after}) --------")
    notes_url = provider.get("notes") or ""
    try:
        entries = changelog_for(provider, args.after)
        if args.full:
            print(format_full(entries), end="")
        else:
            print(format_digest(entries, notes_url), end="")
    except Exception as exc:  # noqa: BLE001
        print(f"  Changelog: unavailable ({exc})")
        if notes_url:
            print(f"  Full notes: {notes_url}")

    print(snapshot_diff(args.key, args.after, args.full), end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
