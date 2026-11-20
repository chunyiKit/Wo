import Flutter
import UIKit
import Photos
import PhotosUI
import UniformTypeIdentifiers
import ImageIO
import AVFoundation
import AVKit
import CryptoKit

/// Native identifiers/bookmarks remain in this device-only registry, never channel maps.
@available(iOS 14.0, *)
final class WoMediaBridge: NSObject, PHPickerViewControllerDelegate, UIDocumentPickerDelegate {
  private static let maxRead = 8 * 1024 * 1024
  private static let maxThumbnail = 96 * 1024
  private static let maxOriginal: Int64 = 20 * 1024 * 1024 * 1024
  private let channel: FlutterMethodChannel
  private let presenter: () -> UIViewController?
  private let worker = DispatchQueue(label: "wo.local.media.io")
  private var pending: FlutterResult?
  private var pendingKind = "photo"
  private var pendingSource = "photos"
  private let manager = FileManager.default
  private var directory: URL?
  private var registry: [String: [String: Any]]?
  private var verifiedSnapshots: [String: String] = [:]

  static func attach(messenger: FlutterBinaryMessenger,
      presenter: @escaping () -> UIViewController?) -> WoMediaBridge {
    return WoMediaBridge(messenger: messenger, presenter: presenter)
  }

  private init(messenger: FlutterBinaryMessenger, presenter: @escaping () -> UIViewController?) {
    self.presenter = presenter
    channel = FlutterMethodChannel(name: "wo.local/media", binaryMessenger: messenger)
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { result(FlutterError(code: "MEDIA_UNAVAILABLE", message: "媒体接口不可用", details: nil)); return }
      self.handle(call, result: result)
    }
  }

  private struct MediaFailure: Error { let reason: String }
  private func fail(_ reason: String) -> MediaFailure { MediaFailure(reason: reason) }
  private func failure(_ error: Error) -> FlutterError {
    let reason = (error as? MediaFailure)?.reason ?? "source_unavailable"
    return FlutterError(code: "MEDIA_UNAVAILABLE", message: "本机媒体不可用", details: reason)
  }
  private func async(_ result: @escaping FlutterResult, block: @escaping () throws -> Any?) {
    worker.async {
      do { let value = try block(); DispatchQueue.main.async { result(value) } }
      catch { let value = self.failure(error); DispatchQueue.main.async { result(value) } }
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    if call.method == "pick" { pick(args, result: result); return }
    guard ["resolve", "prepareOriginal", "openOriginal", "read", "thumbnail", "release"].contains(call.method) else { result(FlutterMethodNotImplemented); return }
    guard let handle = args["handle"] as? String, UUID(uuidString: handle) != nil else {
      result(FlutterError(code: "MEDIA_ARGUMENT", message: "本机媒体引用无效", details: nil)); return
    }
    if call.method == "openOriginal" { openOriginal(handle, result: result); return }
    var offset: UInt64 = 0
    var count = 0
    if call.method == "read" {
      guard let rawOffset = args["offset"] as? NSNumber, let rawCount = args["maxBytes"] as? NSNumber,
          CFGetTypeID(rawOffset) != CFBooleanGetTypeID(), CFGetTypeID(rawCount) != CFBooleanGetTypeID(),
          rawOffset.doubleValue >= 0, rawOffset.doubleValue <= 9007199254740991,
          rawOffset.doubleValue.rounded(.down) == rawOffset.doubleValue,
          rawCount.doubleValue.rounded(.down) == rawCount.doubleValue,
          rawCount.int64Value >= 1, rawCount.int64Value <= Int64(Self.maxRead) else {
        result(FlutterError(code: "MEDIA_ARGUMENT", message: "媒体分块范围无效", details: nil)); return
      }
      offset = rawOffset.uint64Value; count = rawCount.intValue
    }
    async(result) {
      var refs = try self.refs()
      if call.method == "release" {
        refs.removeValue(forKey: handle); try self.save(refs); self.verifiedSnapshots.removeValue(forKey: handle)
        let snapshot = try self.snapshot(handle)
        if self.manager.fileExists(atPath: snapshot.path) { try self.manager.removeItem(at: snapshot) }
        return nil // never remove a user asset, source URL or Photos resource
      }
      guard var ref = refs[handle] else { throw self.fail("source_missing") }
      switch call.method {
      case "resolve": return try self.resolve(handle, ref: ref)
      case "prepareOriginal": return try self.prepareOriginal(handle, ref: &ref)
      case "read": return FlutterStandardTypedData(bytes: try self.read(handle, ref: ref, offset: offset, count: count))
      case "thumbnail": return FlutterStandardTypedData(bytes: try self.thumbnail(ref))
      default: return nil
      }
    }
  }

  private func pick(_ args: [String: Any], result: @escaping FlutterResult) {
    guard let kind = args["kind"] as? String, ["photo", "video"].contains(kind),
        let source = args["source"] as? String, ["photos", "files"].contains(source) else {
      result(FlutterError(code: "MEDIA_ARGUMENT", message: "媒体选择参数无效", details: nil)); return
    }
    guard pending == nil else { result(FlutterError(code: "MEDIA_BUSY", message: "请先完成当前媒体选择", details: nil)); return }
    guard let host = presenter(), host.presentedViewController == nil else { result(failure(fail("source_unavailable"))); return }
    pending = result; pendingKind = kind; pendingSource = source
    if source == "photos" {
      var configuration = PHPickerConfiguration(photoLibrary: .shared())
      configuration.selectionLimit = 1
      configuration.filter = kind == "photo" ? .images : .videos
      configuration.preferredAssetRepresentationMode = .current
      let picker = PHPickerViewController(configuration: configuration)
      picker.delegate = self; host.present(picker, animated: true)
    } else {
      // Open in place: retain a security-scoped bookmark, never import or transcode.
      let picker = UIDocumentPickerViewController(forOpeningContentTypes: [kind == "photo" ? UTType.image : UTType.movie], asCopy: false)
      picker.allowsMultipleSelection = false; picker.delegate = self
      host.present(picker, animated: true)
    }
  }

  func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
    picker.dismiss(animated: true)
    guard let callback = pending else { return }
    pending = nil
    guard let selected = results.first else { callback(nil); return }
    guard let identifier = selected.assetIdentifier else { callback(failure(fail("source_unavailable"))); return }
    let kind = pendingKind
    // PHPicker selection does not grant PHAssetResource access. Ask only after
    // explicit user selection; denial does not trigger item-provider cloud loads.
    PHPhotoLibrary.requestAuthorization(for: .readWrite) { _ in
      self.async(callback) {
        let handle = UUID().uuidString.lowercased()
        let ref: [String: Any] = ["source": "photos", "kind": kind, "assetIdentifier": identifier]
        var refs = try self.refs(); refs[handle] = ref; try self.save(refs)
        return try self.resolve(handle, ref: ref)
      }
    }
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    let callback = pending; pending = nil; callback?(nil)
  }
  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    guard let callback = pending else { return }; pending = nil
    guard let url = urls.first else { callback(nil); return }
    let kind = pendingKind
    async(callback) {
      guard url.startAccessingSecurityScopedResource() else { throw self.fail("permission_denied") }
      defer { url.stopAccessingSecurityScopedResource() }
      // iOS document-provider security scope is retained by a minimal bookmark.
      let bookmark = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
      let handle = UUID().uuidString.lowercased()
      let ref: [String: Any] = ["source": "files", "kind": kind, "bookmark": bookmark]
      var refs = try self.refs(); refs[handle] = ref; try self.save(refs)
      return try self.resolve(handle, ref: ref)
    }
  }

  private func base() throws -> URL {
    if let directory = directory { return directory }
    var root = try manager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("WoMediaDeviceRefs", isDirectory: true)
    try manager.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
    var values = URLResourceValues(); values.isExcludedFromBackup = true
    try root.setResourceValues(values)
    guard try root.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true else { throw fail("privacy_unavailable") }
    directory = root; return root
  }
  private func refs() throws -> [String: [String: Any]] {
    if let registry = registry { return registry }
    let path = try base().appendingPathComponent("device-refs.plist")
    if !manager.fileExists(atPath: path.path) { registry = [:]; return [:] }
    guard let refs = try PropertyListSerialization.propertyList(from: Data(contentsOf: path), options: [], format: nil) as? [String: [String: Any]] else { throw fail("registry_invalid") }
    registry = refs; return refs
  }
  private func save(_ refs: [String: [String: Any]]) throws {
    let bytes = try PropertyListSerialization.data(fromPropertyList: refs, format: .binary, options: 0)
    try bytes.write(to: base().appendingPathComponent("device-refs.plist"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    registry = refs
  }
  private func snapshot(_ handle: String) throws -> URL { try base().appendingPathComponent("original-\(handle).snapshot") }
  private func asset(_ ref: [String: Any]) throws -> PHAsset {
    let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    guard status == .authorized || status == .limited else { throw fail("permission_denied") }
    guard let identifier = ref["assetIdentifier"] as? String,
        let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject else { throw fail("source_missing") }
    let expected: PHAssetMediaType = ref["kind"] as? String == "photo" ? .image : .video
    guard asset.mediaType == expected else { throw fail("unsupported") }
    return asset
  }
  private func resource(_ ref: [String: Any]) throws -> PHAssetResource {
    let asset = try self.asset(ref)
    let type: PHAssetResourceType = asset.mediaType == .image ? .photo : .video
    let candidates = PHAssetResource.assetResources(for: asset).filter { $0.type == type }
    // Do not export an edited rendering, HDR conversion, paired Live Photo or proxy.
    guard candidates.count == 1, let original = candidates.first else { throw fail("source_not_exact") }
    return original
  }
  private func fileURL(_ ref: [String: Any]) throws -> URL {
    guard let bookmark = ref["bookmark"] as? Data else { throw fail("source_missing") }
    var stale = false
    let url = try URL(resolvingBookmarkData: bookmark, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
    guard !stale, url.isFileURL else { throw fail("permission_denied") }
    return url
  }
  private func ensureLocalFile(_ url: URL) throws -> URLResourceValues {
    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey, .fileSizeKey, .contentTypeKey, .contentModificationDateKey])
    guard values.isRegularFile == true else { throw fail("source_unavailable") }
    if values.isUbiquitousItem == true {
      guard values.ubiquitousItemDownloadingStatus == .current || values.ubiquitousItemDownloadingStatus == .downloaded else { throw fail("not_on_device") }
    } else {
      // Arbitrary FileProvider URLs have no public networkAccessAllowed switch.
      // Fail closed instead of opening an unknown provider that may hydrate data.
      let own = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).resolvingSymlinksInPath().path + "/"
      guard url.resolvingSymlinksInPath().path.hasPrefix(own) else { throw fail("source_unavailable") }
    }
    return values
  }

  private func resolve(_ handle: String, ref: [String: Any]) throws -> [String: Any] {
    var out: [String: Any] = ["handle": handle, "kind": ref["kind"] as? String ?? "photo", "contentType": ref["contentType"] as? String ?? "", "size": 0, "sourceExact": false, "missingReason": "not_prepared", "width": 0, "height": 0, "durationMs": 0]
    let file = try snapshot(handle)
    if let expected = ref["snapshotSize"] as? NSNumber, ref["snapshotSHA256"] is String,
        let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0, Int64(size) == expected.int64Value {
      out["size"] = size; out["sourceExact"] = true; out["missingReason"] = NSNull()
      out["width"] = ref["width"] ?? 0; out["height"] = ref["height"] ?? 0; out["durationMs"] = ref["durationMs"] ?? 0
      return out
    }
    do {
      if ref["source"] as? String == "photos" {
        let asset = try self.asset(ref); let resource = try self.resource(ref)
        out["contentType"] = UTType(resource.uniformTypeIdentifier)?.preferredMIMEType ?? ""
        out["width"] = asset.pixelWidth; out["height"] = asset.pixelHeight
        out["durationMs"] = Int64(max(0, asset.duration) * 1000)
        // PHAssetResource has no public byte-size API. No KVC, download or full scan.
      } else {
        let url = try fileURL(ref)
        guard url.startAccessingSecurityScopedResource() else { throw fail("permission_denied") }
        defer { url.stopAccessingSecurityScopedResource() }
        let values = try ensureLocalFile(url)
        out["contentType"] = values.contentType?.preferredMIMEType ?? ""
      }
    } catch { out["missingReason"] = (error as? MediaFailure)?.reason ?? "source_unavailable" }
    return out
  }

  private func prepareOriginal(_ handle: String, ref: inout [String: Any]) throws -> [String: Any] {
    // Invalidate prior proof before any source access: failed reprepare cannot
    // silently back up a previous capture as the new selection state.
    ref.removeValue(forKey: "snapshotSize"); ref.removeValue(forKey: "snapshotSHA256")
    var all = try refs(); all[handle] = ref; try save(all)
    let temporary = try base().appendingPathComponent("partial-\(UUID().uuidString)")
    guard manager.createFile(atPath: temporary.path, contents: nil, attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]) else { throw fail("source_unavailable") }
    defer { try? manager.removeItem(at: temporary) }
    let output = try FileHandle(forWritingTo: temporary)
    var digest = SHA256(); var total: Int64 = 0
    do {
      if ref["source"] as? String == "photos" {
        let asset = try self.asset(ref); let resource = try self.resource(ref)
        let options = PHAssetResourceRequestOptions(); options.isNetworkAccessAllowed = false
        let lock = NSLock(); let done = DispatchSemaphore(value: 0)
        var streamError: Error?
        // Photos supplies bounded chunks; never accumulate an entire original.
        PHAssetResourceManager.default().requestData(for: resource, options: options, dataReceivedHandler: { data in
          lock.lock(); defer { lock.unlock() }
          if streamError != nil { return }
          do {
            guard total <= Self.maxOriginal - Int64(data.count) else { throw self.fail("size_limit") }
            try output.write(contentsOf: data); digest.update(data: data); total += Int64(data.count)
          } catch { streamError = error }
        }, completionHandler: { error in
          lock.lock(); if streamError == nil { streamError = error }; lock.unlock(); done.signal()
        })
        done.wait()
        if let streamError = streamError {
          let native = streamError as NSError
          if native.domain == PHPhotosErrorDomain && native.code == PHPhotosError.Code.networkAccessRequired.rawValue { throw fail("not_on_device") }
          throw streamError
        }
        ref["contentType"] = UTType(resource.uniformTypeIdentifier)?.preferredMIMEType ?? ""
        ref["width"] = asset.pixelWidth; ref["height"] = asset.pixelHeight
        ref["durationMs"] = Int64(max(0, asset.duration) * 1000)
      } else {
        let url = try fileURL(ref)
        guard url.startAccessingSecurityScopedResource() else { throw fail("permission_denied") }
        defer { url.stopAccessingSecurityScopedResource() }
        let before = try ensureLocalFile(url)
        let type = before.contentType
        guard type?.conforms(to: ref["kind"] as? String == "photo" ? .image : .movie) == true else { throw fail("unsupported") }
        let input = try FileHandle(forReadingFrom: url); defer { try? input.close() }
        while let data = try input.read(upToCount: 64 * 1024), !data.isEmpty {
          guard total <= Self.maxOriginal - Int64(data.count) else { throw fail("size_limit") }
          try output.write(contentsOf: data); digest.update(data: data); total += Int64(data.count)
        }
        let after = try ensureLocalFile(url)
        guard before.fileSize == after.fileSize, before.contentModificationDate == after.contentModificationDate, total == Int64(after.fileSize ?? -1) else { throw fail("source_changed") }
        ref["contentType"] = type?.preferredMIMEType ?? ""
      }
      guard total > 0 else { throw fail("source_unavailable") }
      try output.synchronize(); try output.close()
    } catch { try? output.close(); throw error }
    // Same private directory: atomic replacement affects only our own snapshot.
    let target = try snapshot(handle)
    if manager.fileExists(atPath: target.path) { _ = try manager.replaceItemAt(target, withItemAt: temporary) }
    else { try manager.moveItem(at: temporary, to: target) }
    ref["snapshotSize"] = NSNumber(value: total)
    ref["snapshotSHA256"] = digest.finalize().map { String(format: "%02x", $0) }.joined()
    all = try refs(); all[handle] = ref; try save(all)
    return try resolve(handle, ref: ref)
  }

  private func snapshotSignature(_ url: URL, hash: String) throws -> String {
    let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
    return "\(values.fileSize ?? -1):\(values.contentModificationDate?.timeIntervalSince1970 ?? -1):\(hash)"
  }
  private func verifySnapshot(_ handle: String, ref: [String: Any], url: URL) throws {
    guard let expected = ref["snapshotSHA256"] as? String else { throw fail("not_prepared") }
    let signature = try snapshotSignature(url, hash: expected)
    if verifiedSnapshots[handle] == signature { return }
    let input = try FileHandle(forReadingFrom: url); defer { try? input.close() }
    var digest = SHA256()
    while let data = try input.read(upToCount: 64 * 1024), !data.isEmpty { digest.update(data: data) }
    guard digest.finalize().map({ String(format: "%02x", $0) }).joined() == expected else { throw fail("source_changed") }
    verifiedSnapshots[handle] = signature
  }

  private func read(_ handle: String, ref: [String: Any], offset: UInt64, count: Int) throws -> Data {
    guard let expected = ref["snapshotSize"] as? NSNumber, expected.int64Value > 0,
        let hash = ref["snapshotSHA256"] as? String, hash.count == 64 else { throw fail("not_prepared") }
    let url = try snapshot(handle)
    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? -1
    guard Int64(size) == expected.int64Value, offset <= UInt64(size) else { throw fail("source_changed") }
    try verifySnapshot(handle, ref: ref, url: url)
    let input = try FileHandle(forReadingFrom: url); defer { try? input.close() }
    try input.seek(toOffset: offset)
    let bytes = try input.read(upToCount: min(count, size - Int(offset))) ?? Data()
    guard bytes.count == min(count, size - Int(offset)) else { throw fail("source_changed") }
    return bytes
  }

  private func openOriginal(_ handle: String, result: @escaping FlutterResult) {
    worker.async {
      do {
        guard let ref = try self.refs()[handle] else { throw self.fail("source_missing") }
        // Native preview is independent of exact-original backup eligibility.
        // Cached snapshots are local files; Photos requests explicitly forbid network.
        let file = try self.snapshot(handle)
        if ref["snapshotSHA256"] is String, self.manager.fileExists(atPath: file.path) {
          if ref["kind"] as? String == "video" { self.presentVideo(file, result: result) }
          else {
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 2048, kCGImageSourceCreateThumbnailWithTransform: true]
            guard let source = CGImageSourceCreateWithURL(file as CFURL, nil), let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw self.fail("source_unavailable") }
            self.presentImage(UIImage(cgImage: cg), result: result)
          }
        } else if ref["source"] as? String == "photos" {
          let asset = try self.asset(ref)
          if asset.mediaType == .image {
            let options = PHImageRequestOptions(); options.isNetworkAccessAllowed = false; options.isSynchronous = true; options.deliveryMode = .highQualityFormat
            var image: UIImage?
            PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: 2048, height: 2048), contentMode: .aspectFit, options: options) { value, info in
              if info?[PHImageErrorKey] == nil && (info?[PHImageCancelledKey] as? Bool) != true { image = value }
            }
            guard let image = image else { throw self.fail("not_on_device") }
            self.presentImage(image, result: result)
          } else {
            let options = PHVideoRequestOptions(); options.isNetworkAccessAllowed = false; options.version = .original
            PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { value, _, _ in
              guard let local = value as? AVURLAsset, local.url.isFileURL else { DispatchQueue.main.async { result(false) }; return }
              self.presentVideo(local.url, result: result)
            }
          }
        } else {
          // Files preview without a prepared local snapshot is intentionally
          // unsupported; do not let QuickLook hydrate an arbitrary cloud provider.
          DispatchQueue.main.async { result(false) }
        }
      } catch { DispatchQueue.main.async { result(false) } }
    }
  }
  private func presentVideo(_ url: URL, result: @escaping FlutterResult) {
    DispatchQueue.main.async {
      guard url.isFileURL, let host = self.presenter(), host.presentedViewController == nil else { result(false); return }
      let viewer = AVPlayerViewController(); viewer.player = AVPlayer(url: url)
      host.present(viewer, animated: true) { viewer.player?.play() }; result(true)
    }
  }
  private func presentImage(_ image: UIImage, result: @escaping FlutterResult) {
    DispatchQueue.main.async {
      guard let host = self.presenter(), host.presentedViewController == nil else { result(false); return }
      let viewer = UIViewController(); viewer.view.backgroundColor = .black
      let imageView = UIImageView(image: image); imageView.contentMode = .scaleAspectFit; imageView.translatesAutoresizingMaskIntoConstraints = false
      viewer.view.addSubview(imageView)
      NSLayoutConstraint.activate([imageView.leadingAnchor.constraint(equalTo: viewer.view.leadingAnchor), imageView.trailingAnchor.constraint(equalTo: viewer.view.trailingAnchor), imageView.topAnchor.constraint(equalTo: viewer.view.topAnchor), imageView.bottomAnchor.constraint(equalTo: viewer.view.bottomAnchor)])
      // Page-sheet presentation provides system swipe-to-dismiss without an app URI.
      viewer.modalPresentationStyle = .pageSheet; host.present(viewer, animated: true); result(true)
    }
  }

  private func thumbnail(_ ref: [String: Any]) throws -> Data {
    let image: UIImage
    if ref["source"] as? String == "photos" {
      let asset = try self.asset(ref)
      let options = PHImageRequestOptions()
      options.isNetworkAccessAllowed = false; options.isSynchronous = true
      options.resizeMode = .exact; options.deliveryMode = .highQualityFormat
      var selected: UIImage?
      PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: 512, height: 512), contentMode: .aspectFit, options: options) { value, info in
        if (info?[PHImageCancelledKey] as? Bool) != true && info?[PHImageErrorKey] == nil { selected = value }
      }
      guard let selected = selected else { throw fail("not_on_device") }; image = selected
    } else {
      let url = try fileURL(ref)
      guard url.startAccessingSecurityScopedResource() else { throw fail("permission_denied") }
      defer { url.stopAccessingSecurityScopedResource() }
      _ = try ensureLocalFile(url)
      if ref["kind"] as? String == "photo" {
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 512, kCGImageSourceCreateThumbnailWithTransform: true]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw fail("source_unavailable") }
        image = UIImage(cgImage: cg)
      } else {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true; generator.maximumSize = CGSize(width: 512, height: 512)
        image = UIImage(cgImage: try generator.copyCGImage(at: .zero, actualTime: nil))
      }
    }
    let scale = min(1, 512 / max(image.size.width, image.size.height))
    let size = CGSize(width: max(1, image.size.width * scale), height: max(1, image.size.height * scale))
    let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
    // Redraw pixels only: no source EXIF, GPS, filename, XMP or asset properties.
    let clean = UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
    for quality in [CGFloat(0.8), CGFloat(0.65), CGFloat(0.45), CGFloat(0.25), CGFloat(0.1)] {
      if let bytes = clean.jpegData(compressionQuality: quality), bytes.count <= Self.maxThumbnail { return bytes }
    }
    throw fail("thumbnail_limit")
  }
}
