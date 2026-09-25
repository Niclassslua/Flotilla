import XCTest
@testable import Flotilla

final class MonacoLanguageMappingTests: XCTestCase {

    func testLanguageMappingFromFilename() {
        let cases: [(path: String, language: MonacoLanguage)] = [
            ("/path/to/File.swift", .swift),
            ("/src/app.ts", .typescript),
            ("/src/app.tsx", .typescript),
            ("/src/index.js", .javascript),
            ("/src/index.jsx", .javascript),
            ("/main.py", .python),
            ("/main.rs", .rust),
            ("/main.go", .go),
            ("/config.json", .json),
            ("/config.yaml", .yaml),
            ("/config.yml", .yaml),
            ("/README.md", .markdown),
            ("/index.html", .html),
            ("/styles.css", .css),
            ("/styles.scss", .scss),
            ("/script.sh", .shell),
            ("/query.sql", .sql),
            ("/Dockerfile", .dockerfile),
            ("/Info.plist", .xml),
            ("/notes.unknown", .plaintext),
            ("/LICENSE", .plaintext),
        ]

        for entry in cases {
            XCTAssertEqual(
                MonacoLanguage.from(url: URL(fileURLWithPath: entry.path)),
                entry.language,
                entry.path
            )
        }
    }
}
