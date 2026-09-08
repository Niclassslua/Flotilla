import SessionKit

// Reading and writing coding agents' native conversation transcripts, so a
// live session can move between agents without losing its history.
//
// The move is a transcode, not a summary: the source agent's transcript is
// parsed into CanonicalEntry values and re-emitted in the target's own format,
// so the target resumes what it takes to be its own prior session. No model is
// involved and nothing is paraphrased — the cost is one file read and one
// file write.
//
// - CanonicalEntry — the vendor-neutral hub format.
// - TranscriptReading / TranscriptWriting — the per-agent codecs, split so an
//   agent can be a source without being a destination.
// - ToolCallPairing — the one invariant every provider enforces.
// - TranscriptCodecRegistry — which moves are possible.
//
// The formats these codecs implement are undocumented and change between
// upstream releases. Codecs therefore skip record types they do not recognise
// rather than failing, and never assume a field is present.
public enum TranscriptKitModule {
    public static let name = "TranscriptKit"
}
