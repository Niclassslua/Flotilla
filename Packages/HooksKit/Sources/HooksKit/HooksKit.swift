import SessionKit
import ProcessKit

// Read-only session status-transition detection (working/idle/waiting/finished)
// and macOS notification dispatch. Deliberately depends only on a narrow
// read-only output protocol from ProcessKit — never send()/terminate() — so
// hooks can never expand agent permissions.
