import Foundation
import WebKit
import ObjectiveC

// Bypasses SSL certificate validation in WKWebView for self-signed certificates.
// Needed when the Control Center server uses a self-signed HTTPS certificate.
// The Dart HttpClient already bypasses via badCertificateCallback; this covers the WebView.
//
// Deliberately does NOT target a specific plugin class name by string (that broke silently
// twice already -- webview_flutter_wkwebview's internal navigation-delegate class has been
// renamed across versions, e.g. to NavigationDelegateImpl, and Swift classes without an
// explicit @objc(Name) are typically registered with the ObjC runtime under a module-prefixed
// name anyway, not the bare Swift name, so guessing the exact string is unreliable). Instead,
// this scans every class currently loaded in the process for one that both looks like a
// navigation delegate and actually conforms to WKNavigationDelegate, and swizzles all matches.
enum WebViewSSLBypass {
    static func install() {
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

        var installedCount = 0
        var count: UInt32 = 0
        guard let classList = objc_copyClassList(&count) else {
            print("WebViewSSLBypass: objc_copyClassList failed, SSL bypass NOT installed")
            return
        }
        for i in 0..<Int(count) {
            let cls: AnyClass = classList[i]
            let name = NSStringFromClass(cls)
            guard name.localizedCaseInsensitiveContains("NavigationDelegate") else { continue }
            guard class_conformsToProtocol(cls, WKNavigationDelegate.self) else { continue }
            if let method = class_getInstanceMethod(cls, sel) {
                method_setImplementation(method, imp)
            } else {
                class_addMethod(cls, sel, imp, "v@:@@@")
            }
            print("WebViewSSLBypass: installed on \(name)")
            installedCount += 1
        }
        if installedCount == 0 {
            print("WebViewSSLBypass: no matching navigation delegate class found, SSL bypass NOT installed")
        }
    }
}
