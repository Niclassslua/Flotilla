import XCTest
@testable import Flotilla

final class MonacoLanguageMappingTests: XCTestCase {

    func testSwiftLanguageMapping() {
        let url = URL(fileURLWithPath: "/path/to/File.swift")
        XCTAssertEqual(MonacoLanguage.from(url: url), .swift)
    }

    func testTypeScriptAndJavaScriptLanguageMapping() {
        XCTAssertEqual(MonacoLanguage.from(url: URL(fileURLWithPath: "/src/app.ts")), .typescript)
        XCTAssertEqual(MonacoLanguage.from(url: URL(fileURLWithPath: "/src/app.tsx")), .typescript)
        XCTAssertEqual(MonacoLanguage.from(url: URL(fileURLWithPath: "/src/index.js")), .javascript)
        XCTAssertEqual(MonacoLanguage.from(url: URL(fileURLWithPath: "/src/index.jsx")), .javascript)
    }

    func testPythonRustGoLanguageMapping() {
        XCTAssertEqual(MonacoLanguage.from(url: URL(fileURLWithPath: "/main.py")), .python)
        XCTAssertEqual(MonacoLanguage.from(url: URL(fileURLWithPath: "/main.rs")), .rust)
        XCTAssertEqual(MonacoLanguage.from(url: URL(fileURLWithPath: "/main.go")), .go)
    }

    func testConfigAndMarkupLanguageMapping() {
        XCTAssertEqual(MonacoLanguage.from(url: URL(fileURLWithPath: "/config.json")), .json)
        XCTAssertEqual(MonacoLanguage.from(url: URL(fileURLWithPath: "/config.yaml")), .yaml)
        XCTAssertEqual(MonacoLanguage.from(url: URL(fileURLWithPath: "/config.yml")), .yaml)
        XCTAssertEqual(MonacoLanguage.from(url: URL(fileURLWithPath: "/README.md")), .markdown)
        XCTAssertEqual(MonacoLanguage.from(url: URL(fileURLWithPath: "/index.html")), .html)
        XCTAssertEqual(MonacoLanguage.from(url: URL(fileURLWithPath: "/styles.css")), .css)
        XCTAssertEqual(MonacoLanguage.from(url: URL(fileURLWithPath: "/styles.scss")), .scss)
        XCTAssertEqual(MonacoLanguage.from(url: URL(fileURLWithPath: "/script.sh")), .shell)
        XCTAssertEqual(MonacoLanguage.from(url: URL(fileURLWithPath: "/query.sql")), .sql)
        XCTAssertEqual(MonacoLanguage.from(url: URL(fileURLWithPath: "/Dockerfile")), .dockerfile)
        XCTAssertEqual(MonacoLanguage.from(url: URL(fileURLWithPath: "/Info.plist")), .xml)
    }

    func testFallbackToPlaintext() {
        XCTAssertEqual(MonacoLanguage.from(url: URL(fileURLWithPath: "/notes.unknown")), .plaintext)
        XCTAssertEqual(MonacoLanguage.from(url: URL(fileURLWithPath: "/LICENSE")), .plaintext)
    }
}
