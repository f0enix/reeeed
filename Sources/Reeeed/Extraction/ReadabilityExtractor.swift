import Foundation
import WebKit

class ReadabilityExtractor: NSObject, WKUIDelegate, WKNavigationDelegate {
    static let shared = ReadabilityExtractor()

    let webview = WKWebView()

    override init() {
        super.init()
        webview.uiDelegate = self
        webview.navigationDelegate = self
    }

    private func initializeJS() {
        guard readyState == .none else { return }
        Reeeed.logger.info("Initializing...")
        readyState = .initializing
        let js = try! String(contentsOf: Bundle.module.url(forResource: "readability.bundle.min", withExtension: "js")!)
        let html = """
<body>
    <script>\(js)</script>
    <script>alert('ok')</script>
</body>
"""
        webview.loadHTMLString(html, baseURL: nil)
    }

    func warmUp() {
        // do nothing -- the real warmup is done in init
        initializeJS()
    }

    typealias ReadyBlock = () -> Void
    private var pendingReadyBlocks = [ReadyBlock]()

    private enum ReadyState {
        case none
        case initializing
        case ready
    }

    private var readyState = ReadyState.none {
        didSet {
            if readyState == .ready {
                for block in pendingReadyBlocks {
                    block()
                }
                pendingReadyBlocks.removeAll()
            }
        }
    }

    private func waitUntilReady(_ callback: @escaping ReadyBlock) {
        switch readyState {
        case .ready: callback()
        case .none:
            pendingReadyBlocks.append(callback)
            initializeJS()
        case .initializing:
            pendingReadyBlocks.append(callback)
        }
    }

    typealias Callback = (ExtractedContent?) -> Void

    func extract(html: String, url: URL, callback: @escaping Callback) {
        waitUntilReady {
            let script = """
            function resolveImageSrcFromSrcSet(doc) {
                var imgs = Array.from(doc.getElementsByTagName("img"));
                for (img of imgs) {
                    if (img.parentNode.tagName == "PICTURE" && img.src == "") {
                        const pictureElement = img.parentNode;
                        const sourceElement = pictureElement.querySelector('source');
                        if (sourceElement) {
                            const srcSet = sourceElement.getAttribute('srcSet');
                            const firstUrl = srcSet.split(',')[0].trim().split(' ')[0];
                            img.src = firstUrl
                        }
                    }
                }
            }
            var html =  `\(html.asJSString)`;
            var dom = new DOMParser().parseFromString(html, "text/html");
            if (new URL(\(url.absoluteString.asJSString)).host == "medium.com") {
                //medium.com lazy loads images. so we try to extract them and set to the image before reading
                //https://github.com/mozilla/readability/issues/299 
                resolveImageSrcFromSrcSet(dom)
            }
            return await new Readability(dom).parse();
            """

            self.webview.callAsyncJavaScript(script, arguments: [:], in: nil, in: .page) { result in
                switch result {
                case .failure(let err):
                    Reeeed.logger.error("Failed to extract: \(err)")
                    callback(nil)
                case .success(let resultOpt):
                    Reeeed.logger.info("Successfully extracted: \(resultOpt)")
                    let content = self.parse(dict: resultOpt as? [String: Any])
                    callback(content)
                }
            }
        }
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async {
        if message == "ok" {
            DispatchQueue.main.async {
                self.readyState = .ready
                Reeeed.logger.info("Ready")
            }
        }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Reeeed.logger.info("Web process did terminate")
        self.readyState = .none
    }

    private func parse(dict: [String: Any]?) -> ExtractedContent? {
        guard let result = dict else { return nil }
        let content = ExtractedContent(
            content: result["content"] as? String,
            author: result["author"] as? String,
            title: result["title"] as? String,
            excerpt: result["excerpt"] as? String
        )
        return content
    }
}
