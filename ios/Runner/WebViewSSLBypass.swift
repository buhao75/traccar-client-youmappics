import Foundation
import WebKit
import ObjectiveC

// Bypasses SSL certificate validation in WKWebView for self-signed certificates.
// Needed when the Control Center server uses a self-signed HTTPS certificate.
// The Dart HttpClient already bypasses via badCertificateCallback; this covers the WebView.
enum WebViewSSLBypass {
    static func install() {
        // webview_flutter_wkwebview 3.25.x (Pigeon codegen refactor): NavigationDelegateImpl
        // webview_flutter_wkwebview older 3.x: FWFNavigationDelegate
        // webview_flutter_wkwebview 2.x: FLTWKNavigationDelegate
        var installed = false
        for className in ["NavigationDelegateImpl", "FWFNavigationDelegate", "FLTWKNavigationDelegate"] {
            guard let cls = NSClassFromString(className) else { continue }
            let sel = NSSelectorFromString("webView:didReceiveAuthenticationChallenge:completionHandler:")
            let block: @convention(block) (
                AnyObject, WKWebView, URLAuthenticationChallenge,
                @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
            ) -> Void = { _, _, challenge, handler in
                guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
                      let trust = challenge.protectionSpace.serverTrust else {
                    handler(.performDefaultHandling, nil)
                    return
                }
                handler(.useCredential, URLCredential(trust: trust))
            }
            let imp = imp_implementationWithBlock(block as AnyObject)
            if let method = class_getInstanceMethod(cls, sel) {
                method_setImplementation(method, imp)
            } else {
                class_addMethod(cls, sel, imp, "v@:@@@")
            }
            installed = true
            break
        }
        // If a future plugin update renames this class again, none of the names above
        // will resolve and self-signed internal servers will silently fail to load in
        // the WebView with no error surfaced anywhere -- exactly what happened here.
        if !installed {
            print("WebViewSSLBypass: no matching navigation delegate class found, SSL bypass NOT installed")
        }
    }
}
