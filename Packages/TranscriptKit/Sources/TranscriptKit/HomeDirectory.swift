import Foundation

extension FileManager {
    /// The directory agents write their transcripts under. The codecs only
    /// ever read real agent files on macOS; iOS builds this package for the
    /// shared transcript model, so there it just has to compile.
    @usableFromInline static var agentHomeDirectory: URL {
        #if os(macOS)
        FileManager.default.homeDirectoryForCurrentUser
        #else
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        #endif
    }
}
