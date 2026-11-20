import Flutter
import UIKit
import MobileCoreServices
import ImageIO
import Darwin

/// Ordinary, explicitly selected send copies. Never accepts memory/owned handles.
final class WoAttachmentBridge: NSObject, UIDocumentPickerDelegate {
  private static let limit = 20 * 1024 * 1024, chunk = 256 * 1024
  private static let purposes: Set<String> = ["chat_image_copy", "chat_file_copy", "pet_image_copy", "pet_file_copy"]
  private static let videoExtensions: Set<String> = ["mp4","m4v","mov","qt","avi","webm","mkv","3gp","3g2","ts","mts","m2ts","mpg","mpeg","mpe","wmv","flv","vob","ogv","mxf"]
  private static let imageExtensions: Set<String> = ["jpg","jpeg","png","gif","webp","heic","heif","avif","bmp","tif","tiff","ico","svg","psd","jxl","jp2"]
  private struct Failure: Error { let reason: String }
  private func fail(_ reason: String) -> Failure { Failure(reason: reason) }
  private final class Entry {
    let token: String, file: URL, name: String, mime: String, size: Int, purpose: String, expires: TimeInterval
    var claimed = false
    init(token: String, file: URL, name: String, mime: String, size: Int, purpose: String) {
      self.token=token; self.file=file; self.name=name; self.mime=mime; self.size=size; self.purpose=purpose
      self.expires=ProcessInfo.processInfo.systemUptime + 15 * 60
    }
    var metadata: [String: Any] { ["token":token,"displayName":name,"contentType":mime,"size":size,"purpose":purpose,"kind":purpose.hasSuffix("image_copy") ? "image" : "file"] }
  }
  private let channel: FlutterMethodChannel
  private let presenter: () -> UIViewController?
  private let worker=DispatchQueue(label:"wo.local.attachments.io")
  private let manager=FileManager.default
  private let lifecycle=NSLock()
  private var isClosed=false
  private var closed: Bool { lifecycle.lock(); defer { lifecycle.unlock() }; return isClosed }
  private var pending: FlutterResult?, pendingPurpose=""
  private var entries: [String: Entry]=[:] // worker only, intentionally not persisted
  static func attach(messenger: FlutterBinaryMessenger, presenter: @escaping () -> UIViewController?) -> WoAttachmentBridge {
    WoAttachmentBridge(messenger:messenger,presenter:presenter)
  }
  private init(messenger: FlutterBinaryMessenger, presenter: @escaping () -> UIViewController?) {
    self.presenter=presenter; channel=FlutterMethodChannel(name:"wo.local/attachments",binaryMessenger:messenger)
    super.init()
    channel.setMethodCallHandler { [weak self] call,result in
      guard let self=self else { result(FlutterError(code:"ATTACHMENT_UNAVAILABLE",message:"附件选择不可用",details:"closed")); return }
      self.handle(call,result:result)
    }
    worker.async { // An old process has no usable selection token; remove its copies.
      guard let root=try? self.root(),let files=try? self.manager.contentsOfDirectory(at:root,includingPropertiesForKeys:[.isRegularFileKey,.isSymbolicLinkKey]) else { return }
      for file in files where file.lastPathComponent.range(of:"^[a-f0-9-]{36}\\.(copy|partial)$",options:.regularExpression) != nil {
        if let values=try? file.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey]),values.isRegularFile==true,values.isSymbolicLink != true { try? self.manager.removeItem(at:file) }
      }
    }
  }
  private func error(_ error: Error) -> FlutterError {
    FlutterError(code:"ATTACHMENT_UNAVAILABLE",message:"普通附件副本不可用",details:(error as? Failure)?.reason ?? "copy_unavailable")
  }
  private func async(_ result: @escaping FlutterResult, _ action: @escaping () throws -> Any?) {
    worker.async { do { guard !self.closed else { throw self.fail("closed") }; let value=try action(); DispatchQueue.main.async { result(value) } }
      catch { let value=self.error(error); DispatchQueue.main.async { result(value) } } }
  }
  private func root() throws -> URL {
    let parent=try manager.url(for:.applicationSupportDirectory,in:.userDomainMask,appropriateFor:nil,create:true).resolvingSymlinksInPath()
    var root=parent.appendingPathComponent("WoOrdinaryAttachments",isDirectory:true)
    if manager.fileExists(atPath:root.path) {
      let values=try root.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey])
      guard values.isDirectory==true,values.isSymbolicLink != true else { throw fail("private_directory_unavailable") }
    } else { try manager.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700,.protectionKey:FileProtectionType.complete]) }
    guard root.resolvingSymlinksInPath().path==root.path else { throw fail("private_directory_unavailable") }
    try manager.setAttributes([.posixPermissions:0o700,.protectionKey:FileProtectionType.complete],ofItemAtPath:root.path)
    var flags=URLResourceValues(); flags.isExcludedFromBackup=true; try root.setResourceValues(flags)
    guard try root.resourceValues(forKeys:[.isExcludedFromBackupKey]).isExcludedFromBackup==true else { throw fail("private_directory_unavailable") }
    return root
  }
  private func expire() { for (token,entry) in entries where ProcessInfo.processInfo.systemUptime>=entry.expires { entries.removeValue(forKey:token); try? manager.removeItem(at:entry.file) } }
  private func token(_ args:[String:Any]) throws -> String {
    guard let token=args["token"] as? String,let uuid=UUID(uuidString:token),uuid.uuidString.lowercased()==token else { throw fail("invalid_token") }; return token
  }
  private func number(_ value: Any?) throws -> Int {
    guard let n=value as? NSNumber,CFGetTypeID(n) != CFBooleanGetTypeID(),n.doubleValue>=0,n.doubleValue<=Double(Self.limit),n.doubleValue.rounded(.down)==n.doubleValue else { throw fail("invalid_range") }; return n.intValue
  }
  private func handle(_ call:FlutterMethodCall,result:@escaping FlutterResult) {
    guard !closed else { result(error(fail("closed"))); return }
    let args=call.arguments as? [String:Any] ?? [:]
    if call.method=="pick" {
      guard let purpose=args["purpose"] as? String,Self.purposes.contains(purpose) else { result(error(fail("invalid_purpose"))); return }
      guard pending==nil else { result(error(fail("busy"))); return }
      guard let host=presenter(),host.presentedViewController==nil else { result(error(fail("unsupported"))); return }
      pending=result; pendingPurpose=purpose
      // Explicit ordinary copy, iOS 13 open-in-place. Not an original-media API.
      let picker=UIDocumentPickerViewController(documentTypes:[purpose.hasSuffix("image_copy") ? kUTTypeImage as String : kUTTypeData as String],in:.open)
      picker.allowsMultipleSelection=false; picker.delegate=self; host.present(picker,animated:true); return
    }
    guard ["claim","read","release"].contains(call.method) else { result(FlutterMethodNotImplemented); return }
    async(result) {
      self.expire(); let token=try self.token(args)
      if call.method=="release" { if let entry=self.entries.removeValue(forKey:token) { try? self.manager.removeItem(at:entry.file) }; return nil }
      guard let entry=self.entries[token] else { throw self.fail("token_expired") }
      if call.method=="claim" {
        guard !entry.claimed,args["purpose"] as? String==entry.purpose else { throw self.fail("claim_rejected") }
        entry.claimed=true; return entry.metadata
      }
      guard entry.claimed else { throw self.fail("claim_required") }
      let offset=try self.number(args["offset"]),count=try self.number(args["maxBytes"])
      guard offset<=entry.size,count>=1,count<=Self.chunk else { throw self.fail("invalid_range") }
      let root=try self.root(),values=try entry.file.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey])
      guard entry.file.deletingLastPathComponent().path==root.path,values.isRegularFile==true,values.isSymbolicLink != true,values.fileSize==entry.size else { throw self.fail("copy_unavailable") }
      let input=try AttachmentFile(entry.file); defer { try? input.close() }; try input.seek(UInt64(offset))
      let size=min(count,entry.size-offset),bytes=try input.read(upToCount:size)
      guard bytes.count==size else { throw self.fail("copy_unavailable") }
      return FlutterStandardTypedData(bytes:bytes)
    }
  }
  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { let callback=pending; pending=nil; callback?(nil) }
  func documentPicker(_ controller: UIDocumentPickerViewController,didPickDocumentsAt urls:[URL]) {
    guard let callback=pending else { return }; pending=nil
    guard urls.count==1,let url=urls.first,url.isFileURL else { callback(error(fail("unsupported"))); return }
    let purpose=pendingPurpose; async(callback) { try self.copySelection(url,purpose:purpose) }
  }
  private func safeName(_ input:String) -> String {
    let leaf=input.replacingOccurrences(of:"\\",with:"/").components(separatedBy:"/").last ?? "attachment.bin"
    let clean=String(leaf.unicodeScalars.map { scalar -> Character in
      let n=scalar.value
      let allowed=(n>=65 && n<=90) || (n>=97 && n<=122) || (n>=48 && n<=57) || "._ -".unicodeScalars.contains(scalar)
      return allowed ? Character(String(scalar)) : "_"
    }).trimmingCharacters(in:.whitespacesAndNewlines).drop(while:{$0=="."})
    return clean.isEmpty ? "attachment.bin" : String(clean.prefix(100))
  }
  private func mime(_ identifier:String) -> String {
    guard let value=UTTypeCopyPreferredTagWithClass(identifier as CFString,kUTTagClassMIMEType)?.takeRetainedValue() else { return "application/octet-stream" }
    let type=(value as String).lowercased()
    return type.range(of:"^[a-z0-9!#$&^_.+-]+/[a-z0-9!#$&^_.+-]+$",options:.regularExpression) != nil && type.count<=100 ? type : "application/octet-stream"
  }
  private func copySelection(_ url:URL,purpose:String) throws -> [String:Any] {
    expire(); guard entries.count<4 else { throw fail("selection_limit") }
    let access=url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
    let own=URL(fileURLWithPath:NSHomeDirectory(),isDirectory:true).resolvingSymlinksInPath().path+"/"
    guard access || url.resolvingSymlinksInPath().path.hasPrefix(own) else { throw fail("permission_denied") }
    let before=try url.resourceValues(forKeys:[.isRegularFileKey,.fileSizeKey,.contentModificationDateKey,.typeIdentifierKey])
    guard before.isRegularFile==true else { throw fail("unsupported") }
    if let size=before.fileSize,size<1 || size>Self.limit { throw fail("size_limit") }
    var display=safeName(url.lastPathComponent),type=mime(before.typeIdentifier ?? "")
    let ext=(display as NSString).pathExtension.lowercased()
    if type.hasPrefix("video/") || Self.videoExtensions.contains(ext) { throw fail("video_unsupported") }
    let token=UUID().uuidString.lowercased(),root=try self.root()
    guard entries[token]==nil else { throw fail("token_collision") }
    let partial=root.appendingPathComponent(token+".partial"),target=root.appendingPathComponent(token+".copy")
    var partialOwned=false,targetOwned=false
    defer { if partialOwned { try? manager.removeItem(at:partial) } }
    do {
      let input=try AttachmentFile(url); defer { try? input.close() }
      let output=try AttachmentFile(partial,creating:true); partialOwned=true; defer { try? output.close() }
      try manager.setAttributes([.protectionKey:FileProtectionType.complete,.posixPermissions:0o600],ofItemAtPath:partial.path)
      var total=0
      while true {
        guard !closed else { throw fail("closed") }; let bytes=try input.read(upToCount:64*1024); if bytes.isEmpty { break }
        total+=bytes.count; guard total<=Self.limit else { throw fail("size_limit") }; try output.write(bytes)
      }
      guard total>0 else { throw fail("empty_file") }; try output.synchronize(); try output.close()
      let after=try url.resourceValues(forKeys:[.fileSizeKey,.contentModificationDateKey])
      guard before.fileSize==after.fileSize,before.contentModificationDate==after.contentModificationDate,(after.fileSize.map { $0==total } ?? true) else { throw fail("source_changed") }
      let headerFile=try AttachmentFile(partial); let header=try headerFile.read(upToCount:min(total,512)); try headerFile.close()
      if videoMagic(header) { throw fail("video_unsupported") }
      if purpose.hasSuffix("image_copy") {
        let bytes=try imageCopy(partial); guard !bytes.isEmpty,bytes.count<=Self.limit else { throw fail("size_limit") }
        let image=try AttachmentFile(target,creating:true); targetOwned=true; defer { try? image.close() }
        try manager.setAttributes([.protectionKey:FileProtectionType.complete,.posixPermissions:0o600],ofItemAtPath:target.path)
        try image.write(bytes); try image.synchronize(); try image.close()
        display=safeName((display as NSString).deletingPathExtension+".jpg"); type="image/jpeg"
      } else {
        let decoded=CGImageSourceCreateWithURL(partial as CFURL,nil)
        if type.hasPrefix("image/") || Self.imageExtensions.contains(ext) || decoded != nil || imageMagic(header) { throw fail("image_requires_copy") }
        // Same private filesystem: atomic no-overwrite publication of our copy.
        // The user source is never hard-linked or modified.
        guard Darwin.link(partial.path,target.path)==0 else { throw fail("copy_unavailable") }
        targetOwned=true; try manager.removeItem(at:partial); partialOwned=false
      }
      guard !closed else { throw fail("closed") }
      let size=try target.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0
      guard size>0,size<=Self.limit else { throw fail("size_limit") }
      let entry=Entry(token:token,file:target,name:display,mime:type,size:size,purpose:purpose); entries[token]=entry; return entry.metadata
    } catch { if targetOwned { try? manager.removeItem(at:target) }; throw error }
  }
  private func videoMagic(_ data:Data) -> Bool {
    let b=[UInt8](data)
    func at(_ n:Int,_ s:String)->Bool { let p=Array(s.utf8); return b.count>=n+p.count && Array(b[n..<n+p.count])==p }
    if at(4,"ftyp") { let brand=b.count>=12 ? String(bytes:b[8..<12],encoding:.ascii) ?? "" : ""; return !["heic","heix","hevc","hevx","mif1","msf1","avif","avis"].contains(brand) }
    if b.starts(with:[0x30,0x26,0xb2,0x75,0x8e,0x66,0xcf,0x11,0xa6,0xd9,0,0xaa,0,0x62,0xce,0x6c]) || b.starts(with:[6,14,43,52]) || b.count>376 && [0,188,376].allSatisfy({b[$0]==0x47}) || b.count>388 && [4,196,388].allSatisfy({b[$0]==0x47}) { return true }
    return at(0,"FLV") || at(0,"OggS") || at(0,"RIFF") && at(8,"AVI ") || b.starts(with:[0x1a,0x45,0xdf,0xa3]) || b.starts(with:[0,0,1,0xba]) || b.starts(with:[0,0,1,0xb3])
  }
  private func imageMagic(_ data:Data) -> Bool {
    let b=[UInt8](data),s=String(data:data,encoding:.isoLatin1) ?? "",text=(String(data:data,encoding:.utf8) ?? "").trimmingCharacters(in:.whitespacesAndNewlines).lowercased()
    if b.starts(with:[0,0,1,0]) || b.starts(with:[0,0,2,0]) || b.starts(with:[0xff,0x4f,0xff,0x51]) || b.starts(with:[0xff,0x0a]) { return true }
    if b.count>2,b[0]==0x50,(0x31...0x37).contains(b[1]),[9,10,13,32].contains(b[2]) { return true }
    return b.starts(with:[0xff,0xd8]) || b.starts(with:[0x89,0x50,0x4e,0x47]) || s.hasPrefix("GIF8") || s.hasPrefix("BM") || s.hasPrefix("II") || s.hasPrefix("MM") || s.hasPrefix("8BPS") || s.hasPrefix("RIFF") && s.dropFirst(8).hasPrefix("WEBP") || s.dropFirst(4).hasPrefix("ftyp") || text.hasPrefix("<svg") || text.hasPrefix("<?xml") && text.contains("<svg")
  }
  private func imageCopy(_ file:URL) throws -> Data {
    guard let source=CGImageSourceCreateWithURL(file as CFURL,nil),CGImageSourceGetCount(source)>0 else { throw fail("image_invalid") }
    guard let properties=CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],
      let width=properties[kCGImagePropertyPixelWidth] as? NSNumber,let height=properties[kCGImagePropertyPixelHeight] as? NSNumber,
      width.int64Value>0,height.int64Value>0,width.int64Value<=40000,height.int64Value<=40000,width.int64Value*height.int64Value<=100_000_000 else { throw fail("image_invalid") }
    let options:[CFString:Any]=[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceCreateThumbnailWithTransform:true,kCGImageSourceThumbnailMaxPixelSize:1600,kCGImageSourceShouldCacheImmediately:true]
    guard let cg=CGImageSourceCreateThumbnailAtIndex(source,0,options as CFDictionary),cg.width>0,cg.height>0,cg.width<=1600,cg.height<=1600,
      let srgb=CGColorSpace(name:CGColorSpace.sRGB),let context=CGContext(data:nil,width:cg.width,height:cg.height,bitsPerComponent:8,bytesPerRow:cg.width*4,space:srgb,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue|CGBitmapInfo.byteOrder32Big.rawValue) else { throw fail("image_invalid") }
    context.setFillColor(red:0,green:0,blue:0,alpha:1); context.fill(CGRect(x:0,y:0,width:CGFloat(cg.width),height:CGFloat(cg.height)))
    context.draw(cg,in:CGRect(x:0,y:0,width:CGFloat(cg.width),height:CGFloat(cg.height)))
    guard let converted=context.makeImage(),let jpeg=UIImage(cgImage:converted).jpegData(compressionQuality:0.88) else { throw fail("image_invalid") }
    // A newly encoded sRGB send copy only; never strip metadata from source bytes.
    return try stripAttachmentMetadata(jpeg)
  }
  private func stripAttachmentMetadata(_ encoded: Data) throws -> Data {
    let bytes = [UInt8](encoded)
    guard bytes.count >= 4, bytes[0] == 0xff, bytes[1] == 0xd8 else { throw fail("image_invalid") }
    var output = Data(bytes[0..<2])
    var position = 2
    var inScan = false
    var sawScan = false
    while position < bytes.count {
      if inScan {
        let entropyStart = position
        var foundMarker = false
        while position < bytes.count {
          if bytes[position] != 0xff { position += 1; continue }
          let markerStart = position
          var next = position + 1
          while next < bytes.count && bytes[next] == 0xff { next += 1 }
          guard next < bytes.count else { throw fail("image_invalid") }
          let marker = bytes[next]
          if marker == 0x00 || marker == 0x01 || (0xd0...0xd7).contains(marker) { position = next + 1; continue }
          output.append(contentsOf: bytes[entropyStart..<markerStart])
          position = markerStart; inScan = false; foundMarker = true
          break
        }
        guard foundMarker else { throw fail("image_invalid") }
        continue
      }
      let markerStart = position
      guard bytes[position] == 0xff else { throw fail("image_invalid") }
      while position < bytes.count && bytes[position] == 0xff { position += 1 }
      guard position < bytes.count else { throw fail("image_invalid") }
      let marker = bytes[position]; position += 1
      if marker == 0xd9 {
        guard sawScan, position == bytes.count else { throw fail("image_invalid") }
        output.append(contentsOf: bytes[markerStart..<position]); return output
      }
      guard marker != 0x00, marker != 0xd8, !(0xd0...0xd7).contains(marker) else { throw fail("image_invalid") }
      if marker == 0x01 { output.append(contentsOf: bytes[markerStart..<position]); continue }
      guard bytes.count - position >= 2 else { throw fail("image_invalid") }
      let length = (Int(bytes[position]) << 8) | Int(bytes[position + 1])
      guard length >= 2, length <= bytes.count - position else { throw fail("image_invalid") }
      let end = position + length
      // Fresh encoder output only: remove all APP0..15 and COM.
      if !(0xe0...0xef).contains(marker) && marker != 0xfe { output.append(contentsOf: bytes[markerStart..<end]) }
      position = end
      if marker == 0xda { inScan = true; sawScan = true }
    }
    throw fail("image_invalid")
  }
  private final class AttachmentFile {
    private var descriptor: Int32 = -1
    private static func ioError() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    init(_ url: URL, creating: Bool = false) throws {
      guard url.isFileURL else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL)) }
      descriptor = Darwin.open(url.path, (creating ? O_WRONLY | O_CREAT | O_EXCL : O_RDONLY) | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, mode_t(0o600))
      guard descriptor >= 0 else { throw Self.ioError() }
      var metadata = stat()
      guard Darwin.fstat(descriptor, &metadata) == 0 else {
        let error = Self.ioError(); Darwin.close(descriptor); descriptor = -1; throw error
      }
      guard (metadata.st_mode & S_IFMT) == S_IFREG else {
        Darwin.close(descriptor); descriptor = -1
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL))
      }
    }
    deinit { if descriptor >= 0 { Darwin.close(descriptor) } }
    func read(upToCount count: Int) throws -> Data {
      guard count >= 0, count <= 8 * 1024 * 1024 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL)) }
      if count == 0 { return Data() }
      var bytes = Data(count: count), received = 0
      try bytes.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
        while received < count {
          let next = Darwin.read(descriptor, raw.baseAddress!.advanced(by: received), count - received)
          if next < 0 && errno == EINTR { continue }
          guard next >= 0 else { throw Self.ioError() }
          if next == 0 { break }
          received += next
        }
      }
      bytes.count = received; return bytes
    }
    func write(_ data: Data) throws {
      try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
        var offset = 0
        while offset < raw.count {
          let written = Darwin.write(descriptor, raw.baseAddress!.advanced(by: offset), raw.count - offset)
          if written < 0 && errno == EINTR { continue }
          guard written > 0 else { throw Self.ioError() }
          offset += written
        }
      }
    }
    func seek(_ offset: UInt64) throws {
      guard offset <= UInt64(Int64.max), Darwin.lseek(descriptor, off_t(offset), SEEK_SET) >= 0 else { throw Self.ioError() }
    }
    func synchronize() throws {
      var result: Int32
      repeat { result = Darwin.fsync(descriptor) } while result < 0 && errno == EINTR
      guard result == 0 else { throw Self.ioError() }
    }
    func close() throws {
      if descriptor < 0 { return }
      let old = descriptor; descriptor = -1
      guard Darwin.close(old) == 0 else { throw Self.ioError() }
    }
  }
  func close() {
    lifecycle.lock(); if isClosed { lifecycle.unlock(); return }; isClosed=true; lifecycle.unlock(); channel.setMethodCallHandler(nil)
    let callback=pending; pending=nil; callback?(error(fail("closed")))
    worker.async { for entry in self.entries.values { try? self.manager.removeItem(at:entry.file) }; self.entries.removeAll() }
  }
}
