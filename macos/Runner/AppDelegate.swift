import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  private let directoryAccess = ScopedDirectoryAccess()
  private var directoryTerminationObserver: NSObjectProtocol?
  private var directoryPanel: NSOpenPanel?

  override func applicationDidFinishLaunching(_ notification: Notification) {
      directoryTerminationObserver = NotificationCenter.default.addObserver(
        forName: NSApplication.willTerminateNotification, object: nil, queue: .main
      ) { [weak self] _ in self?.directoryAccess.close() }
      let controller: FlutterViewController = mainFlutterWindow?.contentViewController as! FlutterViewController
      let methodChannel = FlutterMethodChannel(name: "venera/method_channel", binaryMessenger: controller.engine.binaryMessenger)

      methodChannel.setMethodCallHandler { (call, result) in
        switch call.method {
        case "getProxy":
            if let proxySettings = CFNetworkCopySystemProxySettings()?.takeUnretainedValue() as NSDictionary? {
                if let httpProxy = proxySettings[kCFNetworkProxiesHTTPProxy] as? String,
                   let httpPort = proxySettings[kCFNetworkProxiesHTTPPort] as? Int {
                    let proxyConfig = "\(httpProxy):\(httpPort)"
                    result(proxyConfig)
                } else if let socksProxy = proxySettings[kCFNetworkProxiesSOCKSProxy] as? String,
                          let socksPort = proxySettings[kCFNetworkProxiesSOCKSPort] as? Int {
                    let proxyConfig = "\(socksProxy):\(socksPort)"
                    result(proxyConfig)
                } else {
                    result("")
                }
            } else {
                result("")
            }
        case "getDirectoryPath":
          self.getDirectoryPath(result: result)
        case "releaseDirectoryAccess", "retainDirectoryAccessForSession":
          guard let token = call.arguments as? String else {
            result(FlutterError(code: "invalid_arguments", message: "Missing directory token", details: nil))
            return
          }
          do {
            if call.method == "releaseDirectoryAccess" { self.directoryAccess.release(token) }
            else { try self.directoryAccess.retainForSession(token) }
            result(nil)
          } catch {
            result(FlutterError(code: "directory_access", message: String(describing: error), details: nil))
          }
        default:
          result(FlutterMethodNotImplemented)
        }
      }

      let clipboardChannel = FlutterMethodChannel(name: "venera/clipboard", binaryMessenger: controller.engine.binaryMessenger)

      clipboardChannel.setMethodCallHandler { (call, result) in
        switch call.method {
        case "writeImageToClipboard":
          guard let arguments = call.arguments as? [String: Any],
            let data = arguments["data"] as? FlutterStandardTypedData else {
            result(FlutterError(code: "INVALID_ARGUMENTS", message: "Invalid arguments", details: nil))
            return
          }

          guard let image = NSImage(data: data.data) else {
            result(FlutterError(code: "INVALID_IMAGE", message: "Could not create image from data", details: nil))
            return
          }

          let pasteboard = NSPasteboard.general
          pasteboard.clearContents()
          pasteboard.writeObjects([image])
          result(true)
        default:
          result(FlutterMethodNotImplemented)
        }
      }
    }

  private func getDirectoryPath(result: @escaping FlutterResult) {
      guard directoryPanel == nil else {
          result(FlutterError(code: "picker_busy", message: "Directory picker is already open", details: nil))
          return
      }
      let panel = NSOpenPanel()
      directoryPanel = panel
      panel.canChooseDirectories = true
      panel.canChooseFiles = false
      panel.allowsMultipleSelection = false
      panel.begin { [weak self] response in
          guard let self = self else {
              result(FlutterError(code: "picker_closed", message: "Directory picker owner closed", details: nil))
              return
          }
          self.directoryPanel = nil
          guard response == .OK, let url = panel.urls.first else { result(nil); return }
          do { result(try self.directoryAccess.acquire(url)) }
          catch { result(FlutterError(code: "directory_access", message: String(describing: error), details: nil)) }
      }
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }
}
