// Offscreen render of a board: measures [data-measure] height and writes a PNG. No window is shown.
// usage: swift snap.swift FILE.html WIDTH OUT.png [scale]
import Cocoa
import WebKit

let args = CommandLine.arguments
let file = URL(fileURLWithPath: args[1])
let width = CGFloat(Double(args[2])!)
let out = args[3]
let scale = args.count > 4 ? CGFloat(Double(args[4])!) : 0.5

class D: NSObject, WKNavigationDelegate {
    let web: WKWebView
    init(_ w: WKWebView) { web = w }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            webView.evaluateJavaScript("(()=>{const m=document.querySelector('[data-measure]');return [m?m.offsetHeight:-1, document.documentElement.scrollHeight]})()") { r, _ in
                let a = r as? [Any] ?? []
                print("MEASURE", a.map { "\($0)" }.joined(separator: " "))
                let h = max((a.first as? NSNumber)?.doubleValue ?? 0, (a.count > 1 ? (a[1] as? NSNumber)?.doubleValue : nil) ?? 800)
                webView.frame = NSRect(x: 0, y: 0, width: width, height: CGFloat(h))
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    let cfg = WKSnapshotConfiguration()
                    cfg.rect = NSRect(x: 0, y: 0, width: width, height: CGFloat(h))
                    cfg.snapshotWidth = NSNumber(value: Double(width * scale))
                    webView.takeSnapshot(with: cfg) { img, err in
                        if let img = img, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                           let png = rep.representation(using: .png, properties: [:]) {
                            try? png.write(to: URL(fileURLWithPath: out))
                            print("WROTE", out)
                        } else { print("ERR", err as Any) }
                        exit(0)
                    }
                }
            }
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let conf = WKWebViewConfiguration()
conf.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
let web = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: 800), configuration: conf)
let win = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: width, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
win.contentView = web
let d = D(web)
web.navigationDelegate = d
web.loadFileURL(file, allowingReadAccessTo: file.deletingLastPathComponent())
DispatchQueue.main.asyncAfter(deadline: .now() + 30) { print("TIMEOUT"); exit(1) }
app.run()
