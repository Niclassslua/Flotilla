import Foundation

/// One address a Mac can be reached at.
public struct HostCandidate: Hashable, Codable, Sendable {
    public enum Kind: String, Hashable, Codable, Sendable, CaseIterable {
        /// A LAN IP address.
        case lan
        /// The Mac's Bonjour host name (`studio.local`).
        case bonjour
        /// A tailnet IP address (100.64.0.0/10 or fd7a:115c:a1e0::/48).
        case tailscale
        /// A MagicDNS name (`studio.tail1234.ts.net`).
        case tailscaleDNS

        /// Which network path this candidate belongs to, for error reporting.
        public var path: NetworkPath {
            switch self {
            case .lan, .bonjour: .lan
            case .tailscale, .tailscaleDNS: .tailscale
            }
        }
    }

    public var kind: Kind
    public var host: String
    public var port: UInt16

    public init(kind: Kind, host: String, port: UInt16) {
        self.kind = kind
        self.host = host
        self.port = port
    }
}

public enum NetworkPath: String, Hashable, Codable, Sendable, CaseIterable {
    case lan
    case tailscale

    public var displayName: String {
        switch self {
        case .lan: "Local network"
        case .tailscale: "Tailscale"
        }
    }
}

/// Everything a phone needs to pair with a Mac, carried by the QR code.
public struct PairingPayload: Hashable, Codable, Sendable {
    public var version: Int
    public var macID: String
    public var macName: String
    /// The Mac's Ed25519 public key, raw representation.
    public var macKey: Data
    /// One-time pairing secret, 32 bytes.
    public var secret: Data
    public var expiresAt: Date
    public var candidates: [HostCandidate]

    public init(
        version: Int = CompanionProtocol.version,
        macID: String,
        macName: String,
        macKey: Data,
        secret: Data,
        expiresAt: Date,
        candidates: [HostCandidate]
    ) {
        self.version = version
        self.macID = macID
        self.macName = macName
        self.macKey = macKey
        self.secret = secret
        self.expiresAt = expiresAt
        self.candidates = candidates
    }

    public static let scheme = "flotilla"
    public static let host = "pair"

    public var hasLANCandidate: Bool { candidates.contains { $0.kind.path == .lan } }
    public var hasTailscaleCandidate: Bool { candidates.contains { $0.kind.path == .tailscale } }

    public func isExpired(at date: Date = .now) -> Bool { date >= expiresAt }

    /// `flotilla://pair?p=<base64url JSON>`
    public func link() throws -> String {
        let json = try CompanionJSON.encode(self)
        return "\(Self.scheme)://\(Self.host)?p=\(json.base64URLEncodedString())"
    }

    public enum LinkError: Error, Equatable, Sendable {
        /// Not a Flotilla pairing link at all.
        case notAPairingLink
        /// Looks like one, but the payload is damaged (truncated copy/paste).
        case malformed
        case unsupportedVersion(Int)
    }

    /// Parses a pairing link. Surrounding whitespace is tolerated, since links
    /// are pasted.
    public init(link: String) throws {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == Self.scheme,
              components.host?.lowercased() == Self.host else {
            throw LinkError.notAPairingLink
        }
        guard let encoded = components.queryItems?.first(where: { $0.name == "p" })?.value,
              let data = Data(base64URLEncoded: encoded),
              let payload = try? CompanionJSON.decode(PairingPayload.self, from: data),
              payload.secret.count == 32,
              payload.macKey.count == 32 else {
            throw LinkError.malformed
        }
        guard payload.version == CompanionProtocol.version else {
            throw LinkError.unsupportedVersion(payload.version)
        }
        self = payload
    }
}

extension Data {
    public func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public init?(base64URLEncoded string: String) {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 { base64 += String(repeating: "=", count: 4 - remainder) }
        self.init(base64Encoded: base64)
    }
}
