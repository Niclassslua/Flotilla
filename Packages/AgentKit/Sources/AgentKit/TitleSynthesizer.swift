import Foundation

/// Cleans and synthesizes concise, punchy titles from agent prompts or raw descriptions.
public enum TitleSynthesizer {
    public static func synthesize(from rawText: String, maxLength: Int = 48) -> String? {
        let normalized = rawText
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\r", with: "")

        let lines = normalized.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard var clean = lines.first else { return nil }

        // Strip markdown headers, blockquotes, bullets
        while clean.hasPrefix("#") || clean.hasPrefix("*") || clean.hasPrefix("-") || clean.hasPrefix(">") || clean.hasPrefix(" ") {
            clean.removeFirst()
        }
        clean = clean.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }

        // Remove conversational filler prefixes
        let fluffPrefixes = [
            "can you please ", "can you ", "could you please ", "could you ", "please ",
            "i want you to ", "i want to ", "i need you to ", "i need to ", "let's ", "lets ",
            "would you ", "help me ", "help with ", "how to ",
            "hey, ", "hey ", "hello, ", "hello ", "hi, ", "hi "
        ]
        var changed = true
        while changed {
            changed = false
            let lowered = clean.lowercased()
            for prefix in fluffPrefixes {
                if lowered.hasPrefix(prefix) {
                    clean = String(clean.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                    changed = true
                    break
                }
            }
        }

        // Remove conversational filler suffixes
        let fluffSuffixes = [
            " short answer only", " short answer please", " in short", " briefly",
            " as short as possible", " thanks", " thank you", " please", " ty", " asap"
        ]
        changed = true
        while changed {
            changed = false
            let lowered = clean.lowercased()
            for suffix in fluffSuffixes {
                if lowered.hasSuffix(suffix) {
                    clean = String(clean.dropLast(suffix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                    changed = true
                    break
                }
            }
        }

        // Strip trailing punctuation
        while clean.hasSuffix("?") || clean.hasSuffix(".") || clean.hasSuffix("!") || clean.hasSuffix(",") || clean.hasSuffix(":") || clean.hasSuffix(";") {
            clean.removeLast()
        }
        clean = clean.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }

        // If there is an early period or clause separator, take first clause
        if let period = clean.firstIndex(of: "."), clean.distance(from: clean.startIndex, to: period) >= 12 {
            clean = String(clean[..<period])
        }

        // Enforce character length limit cleanly at word boundary
        if clean.count > maxLength {
            let truncated = clean.prefix(maxLength - 3)
            if let lastSpace = truncated.lastIndex(of: " "), clean.distance(from: clean.startIndex, to: lastSpace) >= 15 {
                clean = String(clean[..<lastSpace]) + "..."
            } else {
                clean = String(truncated) + "..."
            }
        }

        // Capitalize first character
        if let first = clean.first {
            clean = String(first).uppercased() + clean.dropFirst()
        }

        return clean.isEmpty ? nil : clean
    }
}
