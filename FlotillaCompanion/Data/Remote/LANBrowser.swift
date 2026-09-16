import Foundation
import Network
import Observation
import CompanionKit

/// Browses the local network for Flotilla Macs over Bonjour.
///
/// Serves two purposes: a fast LAN route to a paired Mac whose IP changed,
/// and the only reliable signal that Local Network access was denied.
@MainActor
@Observable
final class LANBrowser {
    enum Permission: Equatable {
        case unknown
        case granted
        case denied
    }

    struct Discovered: Hashable {
        var name: String
        var macID: String?
        var endpoint: NWEndpoint
    }

    private(set) var permission: Permission = .unknown
    private(set) var discovered: [Discovered] = []

    @ObservationIgnored private var browser: NWBrowser?

    func start() {
        guard browser == nil else { return }
        let parameters = NWParameters()
        parameters.includePeerToPeer = false
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: CompanionServer.bonjourType, domain: nil), using: parameters)
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in self?.apply(state) }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let found = results.compactMap { result -> Discovered? in
                guard case .service(let name, _, _, _) = result.endpoint else { return nil }
                var macID: String?
                if case .bonjour(let txt) = result.metadata { macID = txt["macID"] }
                return Discovered(name: name, macID: macID, endpoint: result.endpoint)
            }
            Task { @MainActor in self?.discovered = found }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func stop() {
        browser?.cancel()
        browser = nil
    }

    func endpoint(forMac macID: String) -> Discovered? {
        discovered.first { $0.macID == macID }
    }

    private func apply(_ state: NWBrowser.State) {
        switch state {
        case .ready:
            if permission != .denied { permission = .granted }
        case .waiting(let error), .failed(let error):
            if Self.isPolicyDenied(error) { permission = .denied }
            if case .failed = state {
                browser?.cancel()
                browser = nil
            }
        default:
            break
        }
    }

    nonisolated static func isPolicyDenied(_ error: NWError) -> Bool {
        if case .dns(let code) = error, code == -65570 { return true }
        return false
    }
}

/// Why pairing or connecting failed, with what the user can do about it.
struct ConnectionDiagnosis: Equatable {
    enum Headline: Equatable {
        case expired
        case alreadyUsed
        case rejected(RejectReason)
        case identityMismatch
        case versionMismatch
        case unreachable
        case localNetworkDenied
        case other(String)
    }

    struct PathReport: Equatable, Identifiable {
        enum Outcome: Equatable {
            /// The link had no address for this path.
            case notOffered
            case succeeded(address: String)
            case failed([String: String])
            /// Other path won before this one finished.
            case notNeeded
        }

        var path: NetworkPath
        var outcome: Outcome
        var id: NetworkPath { path }
    }

    var headline: Headline
    var paths: [PathReport]
    var phoneHasTailnet: Bool
    var localNetworkDenied: Bool

    var title: String {
        switch headline {
        case .expired: "This pairing code expired"
        case .alreadyUsed: "This pairing code was already used"
        case .rejected(.pairingInvalid): "The Mac didn't accept this code"
        case .rejected(.revoked): "This iPhone was removed on the Mac"
        case .rejected(.unknownDevice): "The Mac doesn't know this iPhone"
        case .rejected(.wrongMac): "This code belongs to a different Mac"
        case .rejected: "The Mac refused the connection"
        case .identityMismatch: "This Mac's identity doesn't match"
        case .versionMismatch: "Versions don't match"
        case .unreachable: "Couldn't reach your Mac"
        case .localNetworkDenied: "Local Network access is off"
        case .other: "Pairing didn't work"
        }
    }

    var message: String {
        switch headline {
        case .expired, .alreadyUsed, .rejected(.pairingInvalid):
            "On your Mac, open Flotilla ▸ Settings ▸ iPhone Companion ▸ Pair iPhone to show a new code, then scan it."
        case .rejected(.revoked), .rejected(.unknownDevice):
            "Pair again from Flotilla ▸ Settings ▸ iPhone Companion on the Mac."
        case .rejected(.wrongMac):
            "Scan the code shown on the Mac you want to control."
        case .rejected:
            "Try pairing again with a new code."
        case .identityMismatch:
            "The Mac answered with a different key than the code promised. If you just reset Flotilla's companion settings, show a new code. Otherwise another device may be impersonating your Mac."
        case .versionMismatch:
            "Update Flotilla on your Mac and this app to the latest version, then try again."
        case .unreachable:
            "Neither the local network nor Tailscale reached the Mac. Flotilla must be running on the Mac with iPhone Companion turned on."
        case .localNetworkDenied:
            "Flotilla needs Local Network access to find and reach your Mac on Wi-Fi. Turn it on in Settings ▸ Privacy & Security ▸ Local Network."
        case .other(let detail):
            detail
        }
    }

    /// Specific advice per path, only for paths worth talking about.
    func advice(for report: PathReport) -> [String] {
        switch (report.path, report.outcome) {
        case (_, .succeeded), (_, .notNeeded):
            return []
        case (.lan, .notOffered):
            return ["The Mac had no local network address when the code was made — is it connected to Wi-Fi or Ethernet?"]
        case (.lan, .failed):
            if localNetworkDenied {
                return ["Local Network access is off for Flotilla on this iPhone."]
            }
            return [
                "Make sure this iPhone is on the same Wi-Fi network as the Mac.",
                "Guest and public networks often block devices from reaching each other.",
                "If the macOS firewall is on, allow incoming connections for Flotilla.",
            ]
        case (.tailscale, .notOffered):
            return ["Tailscale isn't connected on the Mac, so the code has no Tailscale address. Turn Tailscale on there and show a new code to pair from anywhere."]
        case (.tailscale, .failed):
            if !phoneHasTailnet {
                return ["Tailscale isn't connected on this iPhone. Open the Tailscale app and connect, then try again."]
            }
            return [
                "Check that the iPhone and the Mac are signed in to the same tailnet.",
                "Tailscale access controls (ACLs) must allow this iPhone to reach the Mac.",
                "The Mac has to be awake, with Tailscale connected.",
            ]
        }
    }

    /// Builds a diagnosis from a connection failure and the attempt log.
    static func diagnose(
        error: Error,
        attempts: [ConnectTarget: AttemptStatus],
        offeredPaths: Set<NetworkPath>,
        phoneHasTailnet: Bool,
        localNetworkDenied: Bool,
        payloadExpired: Bool = false
    ) -> ConnectionDiagnosis {
        let paths = NetworkPath.allCases.map { path -> PathReport in
            let relevant = attempts.filter { $0.key.path == path }
            if let success = relevant.first(where: { $0.value == .connected }) {
                return PathReport(path: path, outcome: .succeeded(address: success.key.label))
            }
            let failures = relevant.reduce(into: [String: String]()) { result, entry in
                if case .failed(let error) = entry.value { result[entry.key.label] = describe(error) }
            }
            if !failures.isEmpty { return PathReport(path: path, outcome: .failed(failures)) }
            if relevant.isEmpty { return PathReport(path: path, outcome: offeredPaths.contains(path) ? .notNeeded : .notOffered) }
            return PathReport(path: path, outcome: .notNeeded)
        }

        let lanDenied = localNetworkDenied || attempts.values.contains(.failed(.localNetworkDenied))
        let headline: Headline
        if payloadExpired {
            headline = .expired
        } else {
            switch error {
            case let connect as ConnectError:
                switch connect {
                case .handshake(.rejected(.pairingExpired)): headline = .expired
                case .handshake(.rejected(.pairingInvalid)): headline = .alreadyUsed
                case .handshake(.rejected(.versionUnsupported)), .handshake(.versionMismatch): headline = .versionMismatch
                case .handshake(.rejected(let reason)): headline = .rejected(reason)
                case .handshake(.macIdentityMismatch): headline = .identityMismatch
                case .handshake(.malformedFrame): headline = .other("The Mac sent something unexpected. Make sure both apps are up to date.")
                case .unreachable, .noTargets, .transport:
                    let lanOnly = !offeredPaths.contains(.tailscale)
                    headline = lanDenied && lanOnly ? .localNetworkDenied : .unreachable
                }
            case let link as PairingPayload.LinkError:
                switch link {
                case .notAPairingLink: headline = .other("That isn't a Flotilla pairing code.")
                case .malformed: headline = .other("The pairing link is incomplete. Copy it again from the Mac.")
                case .unsupportedVersion: headline = .versionMismatch
                }
            case let action as CompanionActionError:
                headline = .other(action.message)
            default:
                headline = .other(error.localizedDescription)
            }
        }
        return ConnectionDiagnosis(headline: headline, paths: paths, phoneHasTailnet: phoneHasTailnet, localNetworkDenied: lanDenied)
    }

    static func describe(_ error: TransportError) -> String {
        switch error {
        case .timedOut: "timed out"
        case .closed: "connection closed"
        case .localNetworkDenied: "Local Network access denied"
        case .frameTooLarge: "unexpected data"
        case .backpressure: "connection busy"
        case .unreachable(let detail):
            if detail.localizedCaseInsensitiveContains("refused") { "connection refused" }
            else if detail.localizedCaseInsensitiveContains("unreachable") || detail.localizedCaseInsensitiveContains("no route") { "no route to host" }
            else if detail.localizedCaseInsensitiveContains("dns") || detail.localizedCaseInsensitiveContains("resolve") { "name not found" }
            else { "unreachable" }
        }
    }
}
