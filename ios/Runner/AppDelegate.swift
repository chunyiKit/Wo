import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var localPrivacyChannel: FlutterMethodChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let channel = FlutterMethodChannel(
      name: "wo.local/privacy",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    localPrivacyChannel = channel
    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "prepare" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard let self = self else {
        result(FlutterError(code: "LOCAL_PRIVACY", message: "无法确认本机数据备份策略", details: nil))
        return
      }
      do {
        try self.excludePersistentDataFromSystemBackup()
        result(["documents": true, "library": true])
      } catch {
        // 不回传路径或文件内容；失败由 Dart 阻止持久数据初始化。
        result(FlutterError(code: "LOCAL_PRIVACY", message: "本机数据系统备份排除失败", details: nil))
      }
    }
  }

  private func excludePersistentDataFromSystemBackup() throws {
    let manager = FileManager.default
    for searchPath in [FileManager.SearchPathDirectory.documentDirectory, .libraryDirectory] {
      var directory = try manager.url(
        for: searchPath, in: .userDomainMask, appropriateFor: nil, create: true
      )
      var values = URLResourceValues()
      values.isExcludedFromBackup = true
      try directory.setResourceValues(values)
      let checked = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
      guard checked.isExcludedFromBackup == true else {
        throw NSError(domain: "WoLocalPrivacy", code: 1)
      }
    }
  }
}
