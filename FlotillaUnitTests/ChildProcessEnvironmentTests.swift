import XCTest
@testable import Flotilla

final class ChildProcessEnvironmentTests: XCTestCase {
    private let contaminatedEnvironment = [
        "PATH": "/usr/bin:/bin",
        "HOME": "/tmp/test-home",
        "FLOTILLA_SELF_REPORT_PATH": "/tmp/self-report.json",
        "DYLD_INSERT_LIBRARIES": "/Applications/Xcode.app/libViewDebuggerSupport.dylib",
        "DYLD_LIBRARY_PATH": "/Applications/Xcode.app/Products",
        "__XPC_DYLD_FRAMEWORK_PATH": "/Applications/Xcode.app/Frameworks",
        "__XCODE_BUILT_PRODUCTS_DIR_PATHS": "/tmp/build-products",
        "SWIFTUI_VIEW_DEBUG": "1",
        "GPUTOOLS_CAPTURE_ENABLED": "1",
        "METAL_LOAD_INTERPOSER": "1",
        "MTL_DEBUG_LAYER": "1",
        "DYMTL_TOOLS_DYLIB_PATH": "/Applications/Xcode.app/MetalTools",
        "XCInjectBundleInto": "com.niclassslua.flotilla",
        "XCTestConfigurationFilePath": "/tmp/test.xctestconfiguration",
        "XPC_SERVICE_NAME": "application.com.niclassslua.flotilla",
        "__CFBundleIdentifier": "com.niclassslua.flotilla",
    ]

    func testSanitizedEnvironmentRemovesDevelopmentInstrumentation() {
        let sanitized = ChildProcessEnvironment.sanitized(contaminatedEnvironment)

        XCTAssertEqual(sanitized["PATH"], "/usr/bin:/bin")
        XCTAssertEqual(sanitized["HOME"], "/tmp/test-home")
        XCTAssertEqual(sanitized["FLOTILLA_SELF_REPORT_PATH"], "/tmp/self-report.json")
        for key in contaminatedEnvironment.keys where key != "PATH"
            && key != "HOME"
            && key != "FLOTILLA_SELF_REPORT_PATH" {
            XCTAssertNil(sanitized[key], "Expected \(key) to be removed")
        }
    }

    func testTmuxWrapperDoesNotEncodeInstrumentationInArgumentsOrEnvironment() {
        let launch = TmuxSessionWrapping.wrap(
            agentExecutable: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: [],
            environment: contaminatedEnvironment,
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            sessionID: UUID(),
            tmuxExecutable: URL(fileURLWithPath: "/usr/bin/tmux")
        )

        XCTAssertTrue(launch.arguments.contains("PATH=/usr/bin:/bin"))
        XCTAssertTrue(launch.arguments.contains("FLOTILLA_SELF_REPORT_PATH=/tmp/self-report.json"))
        XCTAssertTrue(
            zip(launch.arguments, launch.arguments.dropFirst()).contains { pair in
                pair.0 == "-u" && pair.1 == "DYLD_INSERT_LIBRARIES"
            }
        )
        XCTAssertEqual(launch.environment["PATH"], "/usr/bin:/bin")
        XCTAssertEqual(launch.environment["TERM"], "xterm-256color")
        for key in contaminatedEnvironment.keys where key != "PATH"
            && key != "HOME"
            && key != "FLOTILLA_SELF_REPORT_PATH" {
            XCTAssertNil(launch.environment[key], "Expected \(key) to be removed")
            XCTAssertFalse(
                launch.arguments.contains(where: { $0.hasPrefix("\(key)=") }),
                "Expected \(key) not to be encoded as a tmux -e argument"
            )
        }
    }

    func testDirectLaunchFallbackIsAlsoSanitized() {
        let launch = TmuxSessionWrapping.wrap(
            agentExecutable: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: [],
            environment: contaminatedEnvironment,
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            sessionID: UUID(),
            tmuxExecutable: nil
        )

        XCTAssertEqual(launch.environment["PATH"], "/usr/bin:/bin")
        XCTAssertNil(launch.environment["DYLD_INSERT_LIBRARIES"])
        XCTAssertNil(launch.environment["SWIFTUI_VIEW_DEBUG"])
        XCTAssertNil(launch.environment["GPUTOOLS_CAPTURE_ENABLED"])
    }
}
