import Foundation
import WebKit

public protocol Logger {
    func info(_ string: String)
    func error(_ string: String)
}

struct PrintLogger: Logger {
    func info(_ string: String) {
        print("[Reeeed] ℹ️ \(string)")
    }
    func error(_ string: String) {
        print("[Reeeed] 🚨 \(string)")
    }
}

public enum Reeeed {
    public static var logger: Logger = PrintLogger()

    public static func warmup(extractor: Extractor = .mercury) {
        switch extractor {
        case .mercury:
            MercuryExtractor.shared.warmUp()
        case .readability:
            ReadabilityExtractor.shared.warmUp()
        }
    }

    public static func extractArticleContent(url: URL, html: String, extractor: Extractor = .mercury) async throws -> ExtractedContent {
        return try await withCheckedThrowingContinuation({ continuation in
            DispatchQueue.main.async {
                switch extractor {
                case .mercury:
                    MercuryExtractor.shared.extract(html: html, url: url) { contentOpt in
                        if let content = contentOpt {
                            continuation.resume(returning: content)
                        } else {
                            continuation.resume(throwing: ExtractionError.FailedToExtract)
                        }
                    }
                case .readability:
                    ReadabilityExtractor.shared.extract(html: html, url: url) { contentOpt in
                        if let content = contentOpt {
                            continuation.resume(returning: content)
                        } else {
                            continuation.resume(throwing: ExtractionError.FailedToExtract)
                        }
                    }
                }
            }
        })
    }

    public struct FetchAndExtractionResult {
        public var metadata: SiteMetadata?
        public var extracted: ExtractedContent
        public var styledHTML: String
        public var baseURL: URL

        public var title: String? {
            extracted.title?.nilIfEmpty ?? metadata?.title?.nilIfEmpty
        }
    }

    @MainActor
    public static func fetchAndExtractContent(fromURL url: URL, theme: ReaderTheme = .init(), extractor: Extractor = .mercury, useWebView: Bool = false) async throws -> FetchAndExtractionResult {
        Reeeed.warmup(extractor: extractor)
        var htmlString: String?
        if useWebView {
            htmlString = try await WebViewManager().extractHTMLFromURL(url)
        } else {
           let (data, response) = try await URLSession.shared.data(from: url)
           htmlString = String(data: data, encoding: .utf8)
        }
         guard let html = htmlString else {
             throw ExtractionError.DataIsNotString
         }
       
        let baseURL = URL(string:"\(url.scheme!)://\(url.host!)")!
        let content = try await Reeeed.extractArticleContent(url: baseURL, html: html, extractor: extractor)
        guard let extractedHTML = content.content else {
            throw ExtractionError.MissingExtractionData
        }
        let extractedMetadata = try? await SiteMetadata.extractMetadata(fromHTML: html, baseURL: baseURL)
        let styledHTML = Reeeed.wrapHTMLInReaderStyling(html: extractedHTML, title: content.title ?? extractedMetadata?.title ?? "", baseURL: baseURL, author: content.author, heroImage: extractedMetadata?.heroImage, includeExitReaderButton: true, theme: theme, date: content.datePublished)
        return .init(metadata: extractedMetadata, extracted: content, styledHTML: styledHTML, baseURL: baseURL)
    }
}


private final class WebViewManager: NSObject, WKNavigationDelegate {
    
    private var webView: WKWebView!
    private var continuation: CheckedContinuation<String, Error>?

    override init() {
        super.init()
        webView = WKWebView()
        webView.navigationDelegate = self
    }
    
    @MainActor
    func extractHTMLFromURL(_ url: URL) async throws -> String {
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let request = URLRequest(url: url)
            webView.load(request)
        }
    }

    // MARK: - WKNavigationDelegate
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            webView.evaluateJavaScript("document.documentElement.outerHTML.toString()") { [weak self] result, error in
                if let error = error {
                    self?.continuation?.resume(throwing: error)
                    self?.continuation = nil
                    return
                }
                
                if let html = result as? String {
                    self?.continuation?.resume(returning: html)
                    self?.continuation = nil
                }
            }
        }
    }
    
    // Called when the navigation fails with an error
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }
    
    // Handle content load failure (network issues, etc.)
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }
    
    // Return the webview instance to add to a view hierarchy
    func getWebView() -> WKWebView {
        return webView
    }
}


