import SwiftUI
import WebKit
import DesignSystem

public enum MonacoLanguage: String, Sendable {
    case typescript, javascript, swift, python, rust, go, json, yaml, markdown, html, css, scss, shell = "shell", sql, dockerfile, xml, plaintext

    public static func from(url: URL) -> MonacoLanguage {
        let ext = url.pathExtension.lowercased()
        let name = url.lastPathComponent.lowercased()

        switch (ext, name) {
        case ("swift", _): return .swift
        case ("ts", _), ("tsx", _), ("mts", _), ("cts", _): return .typescript
        case ("js", _), ("jsx", _), ("mjs", _), ("cjs", _): return .javascript
        case ("py", _), ("pyw", _), ("pyi", _): return .python
        case ("rs", _), ("rlib", _): return .rust
        case ("go", _): return .go
        case ("json", _), ("jsonc", _), ("json5", _): return .json
        case ("yaml", _), ("yml", _): return .yaml
        case ("md", _), ("markdown", _), ("mdx", _): return .markdown
        case ("html", _), ("htm", _), ("xhtml", _): return .html
        case ("css", _), ("less", _): return .css
        case ("scss", _), ("sass", _): return .scss
        case ("sh", _), ("bash", _), ("zsh", _), ("fish", _): return .shell
        case ("sql", _): return .sql
        case ("dockerfile", _), (_, "dockerfile"): return .dockerfile
        case ("xml", _), ("plist", _), ("svg", _): return .xml
        case (_, let n) where n.hasPrefix("dockerfile."): return .dockerfile
        default: return .plaintext
        }
    }
}

/// WKWebView-backed Monaco Editor host view with dark theme matching FlotillaPalette,
/// bidirectional synchronization, and ⌘S save bridge.
struct MonacoHostView: NSViewRepresentable {
    @Binding var content: String
    let language: MonacoLanguage
    let fileURL: URL?
    let onSave: (String) -> Void
    let onContentChange: ((String) -> Void)?

    init(
        content: Binding<String>,
        language: MonacoLanguage,
        fileURL: URL? = nil,
        onSave: @escaping (String) -> Void,
        onContentChange: ((String) -> Void)? = nil
    ) {
        self._content = content
        self.language = language
        self.fileURL = fileURL
        self.onSave = onSave
        self.onContentChange = onContentChange
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let userContentController = WKUserContentController()
        userContentController.add(context.coordinator, name: "monacoBridge")
        config.userContentController = userContentController

        // Enable file access and web inspector in debug
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        #if DEBUG
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        #endif

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        context.coordinator.webView = webView

        let html = Self.hostHTML()
        webView.loadHTMLString(html, baseURL: nil)

        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self

        if context.coordinator.lastLoadedURL != fileURL {
            context.coordinator.lastLoadedURL = fileURL
            context.coordinator.setContentInEditor(content, language: language, fileURL: fileURL)
        }
    }

    final class Coordinator: NSObject, WKScriptMessageHandler {
        var parent: MonacoHostView
        weak var webView: WKWebView?
        var lastLoadedURL: URL?
        var isEditorReady = false
        var currentDocumentID: String = UUID().uuidString

        init(_ parent: MonacoHostView) {
            self.parent = parent
            self.currentDocumentID = parent.fileURL?.absoluteString ?? UUID().uuidString
        }

        func setContentInEditor(_ content: String, language: MonacoLanguage, fileURL: URL?) {
            guard isEditorReady, let webView else { return }
            let docID = fileURL?.absoluteString ?? currentDocumentID
            currentDocumentID = docID
            webView.callAsyncJavaScript(
                "window.setEditorContent(content, language, docId)",
                arguments: [
                    "content": content,
                    "language": language.rawValue,
                    "docId": docID
                ],
                in: nil,
                in: .page,
                completionHandler: nil
            )
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let dict = message.body as? [String: Any],
                  let type = dict["type"] as? String else { return }

            if type == "ready" {
                isEditorReady = true
                setContentInEditor(parent.content, language: parent.language, fileURL: parent.fileURL)
                return
            }

            // Bind change/save messages to the intended file/document ID
            guard let docID = dict["documentId"] as? String, docID == currentDocumentID else { return }

            if type == "change", let newContent = dict["content"] as? String {
                Task { @MainActor in
                    self.parent.content = newContent
                    self.parent.onContentChange?(newContent)
                }
            } else if type == "save", let newContent = dict["content"] as? String {
                Task { @MainActor in
                    self.parent.content = newContent
                    self.parent.onSave(newContent)
                }
            }
        }
    }

    static func hostHTML() -> String {
        """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="utf-8">
            <style>
                html, body {
                    margin: 0;
                    padding: 0;
                    width: 100%;
                    height: 100%;
                    overflow: hidden;
                    background-color: #0a0a0c;
                }
                #container {
                    width: 100%;
                    height: 100%;
                }
            </style>
            <script src="https://cdnjs.cloudflare.com/ajax/libs/monaco-editor/0.45.0/min/vs/loader.min.js"></script>
        </head>
        <body>
            <div id="container"></div>
            <script>
                window.currentDocumentId = "";
                window.isSettingContent = false;

                window.setEditorContent = function(content, language, docId) {
                    window.currentDocumentId = docId;
                    if (window.editor) {
                        window.isSettingContent = true;
                        window.editor.setValue(content);
                        monaco.editor.setModelLanguage(window.editor.getModel(), language);
                        window.isSettingContent = false;
                    }
                };

                require.config({ paths: { 'vs': 'https://cdnjs.cloudflare.com/ajax/libs/monaco-editor/0.45.0/min/vs' }});
                require(['vs/editor/editor.main'], function() {
                    monaco.editor.defineTheme('flotillaDark', {
                        base: 'vs-dark',
                        inherit: true,
                        rules: [
                            { background: '0a0a0c' },
                            { token: 'keyword', foreground: 'f55c29', fontStyle: 'bold' },
                            { token: 'comment', foreground: '787882', fontStyle: 'italic' },
                            { token: 'string', foreground: '31c7a4' },
                            { token: 'number', foreground: '42b8e6' },
                            { token: 'type', foreground: '42b8e6' }
                        ],
                        colors: {
                            'editor.background': '#0a0a0c',
                            'editor.foreground': '#f0f0f2',
                            'editorLineNumber.foreground': '#50505a',
                            'editorLineNumber.activeForeground': '#a0a0aa',
                            'editor.lineHighlightBackground': '#141418',
                            'editorCursor.foreground': '#f55c29',
                            'editorWhitespace.foreground': '#282830',
                            'editorIndentGuide.background': '#1e1e24',
                            'editorIndentGuide.activeBackground': '#3a3a44'
                        }
                    });

                    window.editor = monaco.editor.create(document.getElementById('container'), {
                        value: '',
                        language: 'plaintext',
                        theme: 'flotillaDark',
                        fontSize: 13,
                        fontFamily: 'SF Mono, Menlo, Monaco, Courier New, monospace',
                        fontLigatures: true,
                        minimap: { enabled: true, scale: 1 },
                        scrollBeyondLastLine: false,
                        automaticLayout: true,
                        renderWhitespace: 'selection',
                        tabSize: 4,
                        lineNumbers: 'on',
                        roundedSelection: true
                    });

                    window.editor.onDidChangeModelContent(function() {
                        if (window.isSettingContent) return;
                        if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.monacoBridge) {
                            window.webkit.messageHandlers.monacoBridge.postMessage({
                                type: 'change',
                                content: window.editor.getValue(),
                                documentId: window.currentDocumentId
                            });
                        }
                    });

                    window.editor.addCommand(monaco.KeyMod.CtrlCmd | monaco.KeyCode.KeyS, function() {
                        if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.monacoBridge) {
                            window.webkit.messageHandlers.monacoBridge.postMessage({
                                type: 'save',
                                content: window.editor.getValue(),
                                documentId: window.currentDocumentId
                            });
                        }
                    });

                    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.monacoBridge) {
                        window.webkit.messageHandlers.monacoBridge.postMessage({
                            type: 'ready'
                        });
                    }
                });
            </script>
        </body>
        </html>
        """
    }
}
