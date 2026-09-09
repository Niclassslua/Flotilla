#!/bin/bash
#
# Builds the repository the review demo runs against.
#
# The point is a diff worth reviewing: several files, more than one hunk per
# file, every change kind git can report, and — crucially — both committed work
# and uncommitted work, so the review's two scopes show genuinely different
# things rather than the same list twice.
#
# Safe to re-run: it rebuilds the repo from scratch. Comments you left in the
# app live in the demo database, not here, so they survive this.

set -euo pipefail

REPO="${1:-/tmp/flotilla-review-demo/uploader}"
GIT_AUTHOR=(-c user.name="Flotilla Demo" -c user.email="demo@flotilla.local")

rm -rf "$REPO"
mkdir -p "$REPO"
cd "$REPO"

git init -b main --quiet

# ---------------------------------------------------------------- baseline

mkdir -p Sources Tests

cat > Sources/Uploader.swift <<'EOF'
import Foundation

/// Uploads a file to the media service in fixed-size chunks.
struct Uploader {
    let session: URLSession
    let endpoint: URL

    init(session: URLSession = .shared, endpoint: URL) {
        self.session = session
        self.endpoint = endpoint
    }

    func upload(_ file: URL) async throws {
        let chunks = try Chunker(file: file).chunks()
        for chunk in chunks {
            try await send(chunk)
        }
    }

    private func send(_ chunk: Chunk) async throws {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "PUT"
        request.httpBody = chunk.data
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw UploadError.malformedResponse
        }
        guard http.statusCode == 200 else {
            throw UploadError.rejected(status: http.statusCode)
        }
    }

    func cancel() {
        session.invalidateAndCancel()
    }
}

enum UploadError: Error {
    case malformedResponse
    case rejected(status: Int)
}
EOF

cat > Sources/Transport.swift <<'EOF'
import Foundation

/// Thin wrapper over URLSession so tests can substitute a fake.
struct Transport {
    let session: URLSession

    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw UploadError.malformedResponse
        }
        return (data, http)
    }
}
EOF

cat > Sources/LegacyUploader.swift <<'EOF'
import Foundation

/// The synchronous uploader we shipped before async/await. Nothing calls it.
struct LegacyUploader {
    func upload(_ file: URL, completion: @escaping (Error?) -> Void) {
        DispatchQueue.global().async {
            completion(nil)
        }
    }
}
EOF

cat > README.md <<'EOF'
# Uploader

Chunked uploads for the media service.

## Status

Uploads work on a stable connection. They do not survive a flaky one.
EOF

git add .
git "${GIT_AUTHOR[@]}" commit --quiet -m "Chunked uploader"

# ------------------------------------------------------- committed branch work

git checkout -b flotilla/retry-uploader --quiet

# A new file.
cat > Sources/RetryPolicy.swift <<'EOF'
import Foundation

/// Decides whether a failed request is worth trying again, and how long to
/// wait before doing so.
struct RetryPolicy {
    let maxAttempts: Int
    let baseDelay: Duration

    static let `default` = RetryPolicy(maxAttempts: 4, baseDelay: .milliseconds(200))

    func shouldRetry(status: Int, attempt: Int) -> Bool {
        guard attempt < maxAttempts else { return false }
        return true
    }

    func delay(forAttempt attempt: Int) -> Duration {
        baseDelay * (1 << attempt)
    }
}
EOF

# A rename, with edits, so the review shows R plus a real patch.
mkdir -p Sources/Network
git mv Sources/Transport.swift Sources/Network/Transport.swift
cat > Sources/Network/Transport.swift <<'EOF'
import Foundation

/// Thin wrapper over URLSession so tests can substitute a fake.
struct Transport {
    let session: URLSession
    let policy: RetryPolicy

    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw UploadError.malformedResponse
        }
        return (data, http)
    }
}
EOF

# A deletion.
git rm --quiet Sources/LegacyUploader.swift

# Two separate hunks in one file, far enough apart not to fuse.
python3 - <<'PY'
import pathlib
p = pathlib.Path("Sources/Uploader.swift")
s = p.read_text()
s = s.replace(
    """    let session: URLSession
    let endpoint: URL

    init(session: URLSession = .shared, endpoint: URL) {
        self.session = session
        self.endpoint = endpoint
    }""",
    """    let session: URLSession
    let endpoint: URL
    let policy: RetryPolicy

    init(session: URLSession = .shared, endpoint: URL, policy: RetryPolicy = .default) {
        self.session = session
        self.endpoint = endpoint
        self.policy = policy
    }""")
s = s.replace(
    """        guard http.statusCode == 200 else {
            throw UploadError.rejected(status: http.statusCode)
        }""",
    """        guard http.statusCode == 200 else {
            if policy.shouldRetry(status: http.statusCode, attempt: attempt) {
                try await Task.sleep(for: policy.delay(forAttempt: attempt))
                return try await send(chunk, attempt: attempt + 1)
            }
            throw UploadError.rejected(status: http.statusCode)
        }""")
s = s.replace("private func send(_ chunk: Chunk) async throws {",
              "private func send(_ chunk: Chunk, attempt: Int = 0) async throws {")
s = s.replace("            try await send(chunk)", "            try await send(chunk, attempt: 0)")
p.write_text(s)
PY

git add -A
git "${GIT_AUTHOR[@]}" commit --quiet -m "Retry failed chunks with exponential backoff"

# ------------------------------------------------------- uncommitted work

# Left in the working tree so the Uncommitted scope has its own, smaller story.
python3 - <<'PY'
import pathlib
p = pathlib.Path("Sources/Uploader.swift")
s = p.read_text()
s = s.replace("""    func cancel() {
        session.invalidateAndCancel()
    }""",
"""    func cancel() {
        session.invalidateAndCancel()
    }

    /// Retries the whole file rather than a single chunk. Used by the retry
    /// button in the UI.
    func retry(_ file: URL) async throws {
        try await upload(file)
    }""")
p.write_text(s)

r = pathlib.Path("README.md")
r.write_text(r.read_text().replace(
    "Uploads work on a stable connection. They do not survive a flaky one.",
    "Uploads retry on 5xx and timeouts with exponential backoff."))
PY

# An untracked file, which git has no patch for and the review synthesises.
cat > NOTES.md <<'EOF'
Open questions
--------------

- Should a 429 count against maxAttempts, or wait for Retry-After?
- The retry delay is unbounded above; cap it?
EOF

echo "Demo repository ready at $REPO"
echo
git --no-pager log --oneline main..HEAD
echo
git --no-pager status --short
