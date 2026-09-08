import Foundation

/// Enforces the invariant every provider shares: a tool call must be followed
/// by that call's result, and a result must belong to a call.
///
/// This is not tidying. Anthropic's API rejects a conversation containing a
/// `tool_use` block with no answering `tool_result`, and the rejection arrives
/// as an opaque failure on the receiving agent's *first* turn — long after the
/// move looks like it succeeded.
///
/// The reason this runs on every handoff rather than in some rare corner: a
/// session is usually handed over precisely because its current agent is stuck
/// or slow, which means it is very often sitting mid-tool-call when the move
/// happens. The dangling call is the normal case, not the edge case.
public enum ToolCallPairing {
    /// Stands in for a result that never arrived. Deliberately readable — it
    /// ends up in the receiving agent's context, so it should explain itself
    /// to a model that will try to make sense of it.
    public static let missingResultText =
        "[flotilla: tool result missing — session ended before the tool returned]"

    public struct Outcome: Sendable, Equatable {
        public let entries: [CanonicalEntry]
        /// Calls that ended without a result and were given a placeholder.
        public let synthesizedResults: Int
        /// Results whose call is not in the transcript, and were dropped.
        public let droppedOrphanResults: Int

        public init(entries: [CanonicalEntry], synthesizedResults: Int, droppedOrphanResults: Int) {
            self.entries = entries
            self.synthesizedResults = synthesizedResults
            self.droppedOrphanResults = droppedOrphanResults
        }
    }

    /// Reorders `entries` so every call is immediately followed by its result,
    /// synthesising the missing ones and dropping the orphans.
    ///
    /// Ordering is otherwise preserved: a run of assistant text and tool calls
    /// stays in the order the agent produced it, and the results are gathered
    /// behind that whole run rather than interleaved into it. That matches how
    /// both formats group a turn.
    public static func pair(_ entries: [CanonicalEntry]) -> Outcome {
        guard !entries.isEmpty else {
            return Outcome(entries: [], synthesizedResults: 0, droppedOrphanResults: 0)
        }

        // First occurrence wins: a duplicated result is an artefact of a
        // partially-written transcript, not two answers to one call.
        var firstResultIndex: [String: Int] = [:]
        var knownCallIDs: Set<String> = []
        for (index, entry) in entries.enumerated() {
            switch entry {
            case let .toolResult(toolUseID, _, _, _):
                if firstResultIndex[toolUseID] == nil { firstResultIndex[toolUseID] = index }
            case let .toolUse(id, _, _, _):
                knownCallIDs.insert(id)
            default:
                break
            }
        }

        var output: [CanonicalEntry] = []
        output.reserveCapacity(entries.count)
        var consumed = Set<Int>()
        var synthesized = 0
        var dropped = 0
        var index = 0

        while index < entries.count {
            if consumed.contains(index) {
                index += 1
                continue
            }

            switch entries[index] {
            case .assistantMessage, .toolUse:
                // Take the whole agent turn, then settle its debts.
                var pendingCalls: [(id: String, timestamp: Date)] = []
                turn: while index < entries.count {
                    switch entries[index] {
                    case .assistantMessage:
                        output.append(entries[index])
                    case let .toolUse(id, _, _, timestamp):
                        output.append(entries[index])
                        pendingCalls.append((id, timestamp))
                    default:
                        break turn
                    }
                    consumed.insert(index)
                    index += 1
                }

                for call in pendingCalls {
                    if let resultIndex = firstResultIndex[call.id], !consumed.contains(resultIndex) {
                        output.append(entries[resultIndex])
                        consumed.insert(resultIndex)
                    } else {
                        output.append(
                            .toolResult(
                                toolUseID: call.id,
                                output: missingResultText,
                                isError: true,
                                timestamp: call.timestamp
                            )
                        )
                        synthesized += 1
                    }
                }

            case let .toolResult(toolUseID, _, _, _):
                if knownCallIDs.contains(toolUseID) {
                    // Its call will emit it; leave it for that pass.
                    index += 1
                } else {
                    dropped += 1
                    consumed.insert(index)
                    index += 1
                }

            default:
                output.append(entries[index])
                consumed.insert(index)
                index += 1
            }
        }

        return Outcome(
            entries: output,
            synthesizedResults: synthesized,
            droppedOrphanResults: dropped
        )
    }
}
