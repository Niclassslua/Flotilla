import Foundation

public struct PTYSize: Equatable, Sendable {
    public var cols: Int
    public var rows: Int

    public init(cols: Int, rows: Int) {
        self.cols = cols
        self.rows = rows
    }
}

public enum PTYProcessError: Error, Equatable {
    case failedToOpenPTY
    case alreadyRunning
}

/// Read-only view onto a running process's output. HooksKit is only ever
/// handed this narrower protocol — never `PTYProcessProtocol` — so it has
/// no way to write input or terminate the process, even by accident.
public protocol SessionOutputObserving: AnyObject, Sendable {
    var id: UUID { get }
    var outputStream: AsyncStream<Data> { get }
    var isRunning: Bool { get }
}

public protocol PTYProcessProtocol: SessionOutputObserving {
    var terminationHandler: ((Int32) -> Void)? { get set }

    func start(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        workingDirectory: URL,
        initialSize: PTYSize
    ) throws

    func send(input: Data)
    func resize(_ size: PTYSize)
    func terminate()
}

/// Factory boundary used by the application lifecycle. Production injects
/// `SystemPTYProcessFactory`; automation injects an explicit mock factory.
public protocol PTYProcessCreating: Sendable {
    func makeProcess() -> any PTYProcessProtocol
}

public struct SystemPTYProcessFactory: PTYProcessCreating {
    public init() {}

    public func makeProcess() -> any PTYProcessProtocol {
        SystemPTYProcess()
    }
}

public struct MockPTYProcessFactory: PTYProcessCreating {
    private let echoesInput: Bool

    public init(echoesInput: Bool = true) {
        self.echoesInput = echoesInput
    }

    public func makeProcess() -> any PTYProcessProtocol {
        let process = MockPTYProcess()
        process.echoInputToOutput = echoesInput
        return process
    }
}
