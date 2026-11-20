import Foundation
import Flutter
import CryptoKit
import Security
import Darwin

/// NSD 只给地址提示；成员/家庭身份必须由应用协议另行验证。
final class WoLocalBridge: NSObject, FlutterStreamHandler, NetServiceBrowserDelegate, NetServiceDelegate {
    private static let maxBytes = 8 * 1024 * 1024
    private static let serviceType = "_wo-sync._tcp."
    private let cryptoChannel: FlutterMethodChannel
    private let discoveryChannel: FlutterMethodChannel
    private let eventChannel: FlutterEventChannel
    private let cryptoQueue = OperationQueue()
    private let keychainService = (Bundle.main.bundleIdentifier ?? "wo") + ".wo.local.registry.v1"
    private var eventSink: FlutterEventSink?
    private var published: NetService?
    private var browser: NetServiceBrowser?
    private var services: [String: NetService] = [:]
    private var resolved: [String: [String: Any]] = [:]
    private var ownId: String?
    private var closed = false

    init(messenger: FlutterBinaryMessenger) {
        cryptoChannel = FlutterMethodChannel(name: "wo.local/crypto", binaryMessenger: messenger)
        discoveryChannel = FlutterMethodChannel(name: "wo.local/discovery", binaryMessenger: messenger)
        eventChannel = FlutterEventChannel(name: "wo.local/discovery/events", binaryMessenger: messenger)
        super.init()
        cryptoQueue.maxConcurrentOperationCount = 1
        cryptoQueue.qualityOfService = .userInitiated
        cryptoChannel.setMethodCallHandler { [weak self] call, result in
            guard let self = self, !self.closed else {
                result(FlutterError(code: "closed", message: "Local bridge is closed", details: nil)); return
            }
            guard self.cryptoQueue.operationCount < 8 else {
                result(FlutterError(code: "busy", message: "Local crypto queue is full", details: nil)); return
            }
            self.cryptoQueue.addOperation { [weak self] in
                guard let self = self else { return }
                let value: Any?
                do { value = try self.cryptoCall(call) }
                catch BridgeError.argument {
                    value = FlutterError(code: "invalid_argument", message: "Invalid crypto input", details: nil)
                } catch {
                    value = FlutterError(code: "crypto_failed", message: "Local crypto operation failed", details: nil)
                }
                DispatchQueue.main.async { result(value) }
            }
        }
        discoveryChannel.setMethodCallHandler { [weak self] call, result in
            guard let self = self else { return }
            do {
                switch call.method {
                case "start":
                    guard !self.closed, let args = call.arguments as? [String: Any],
                          let id = args["serviceName"] as? String, Self.opaque(id),
                          let port = try? self.integer(args, "port"), (1...65535).contains(port) else {
                        throw BridgeError.argument
                    }
                    self.start(id: id, port: port)
                    result(nil)
                case "stop": self.stop(); result(nil)
                default: result(FlutterMethodNotImplemented)
                }
            } catch {
                result(FlutterError(code: "invalid_argument", message: "Invalid discovery input", details: nil))
            }
        }
        eventChannel.setStreamHandler(self)
    }

    private enum BridgeError: Error { case argument, operation }
    private static func opaque(_ value: String) -> Bool {
        guard let range = value.range(of: "^[A-Za-z0-9_-]{16,48}$", options: .regularExpression) else { return false }
        return range.lowerBound == value.startIndex && range.upperBound == value.endIndex
    }
    private func integer(_ args: [String: Any], _ name: String) throws -> Int {
        guard let number = args[name] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              !["f", "d"].contains(String(cString: number.objCType)),
              let value = Int(number.stringValue) else { throw BridgeError.argument }
        return value
    }
    private func bytes(_ args: [String: Any], _ name: String,
                       min: Int = 0, max: Int = WoLocalBridge.maxBytes) throws -> Data {
        guard let value = args[name] as? FlutterStandardTypedData,
              value.data.count >= min, value.data.count <= max else { throw BridgeError.argument }
        return value.data
    }
    private func handle(_ args: [String: Any]) throws -> String {
        guard let h = args["handle"] as? String,
              let range = h.range(of: "^[A-Za-z0-9_.-]{1,100}$", options: .regularExpression),
              range.lowerBound == h.startIndex, range.upperBound == h.endIndex else {
            throw BridgeError.argument
        }
        return h
    }
    private func typed(_ data: Data) -> FlutterStandardTypedData { FlutterStandardTypedData(bytes: data) }
    private func cryptoCall(_ call: FlutterMethodCall) throws -> Any? {
        guard let args = call.arguments as? [String: Any] else { throw BridgeError.argument }
        switch call.method {
        case "privateDirectory":
            guard let name = args["name"] as? String,
              name.range(of: "^[a-z0-9_-]{1,40}$", options: .regularExpression)?.upperBound == name.endIndex else { throw BridgeError.argument }
            let manager = FileManager.default
            let base = try manager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).resolvingSymlinksInPath()
            var directory = base.appendingPathComponent("wo-private-" + name, isDirectory: true)
            if manager.fileExists(atPath: directory.path) {
                let current = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard current.isDirectory == true, current.isSymbolicLink != true else { throw BridgeError.operation }
            } else {
                try manager.createDirectory(at: directory, withIntermediateDirectories: false,
                  attributes: [.posixPermissions: 0o700, .protectionKey: FileProtectionType.complete])
            }
            guard directory.resolvingSymlinksInPath().path == directory.path else { throw BridgeError.operation }
            try manager.setAttributes([.posixPermissions: 0o700, .protectionKey: FileProtectionType.complete], ofItemAtPath: directory.path)
            var flags = URLResourceValues(); flags.isExcludedFromBackup = true
            try directory.setResourceValues(flags)
            guard try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true else { throw BridgeError.operation }
            return directory.path
        case "random":
            let count = try integer(args, "count")
            guard (1...64).contains(count) else { throw BridgeError.argument }
            var data = Data(count: count)
            let status = data.withUnsafeMutableBytes { raw in
                SecRandomCopyBytes(kSecRandomDefault, count, raw.baseAddress!)
            }
            guard status == errSecSuccess else { throw BridgeError.operation }
            return typed(data)
        case "hash": return typed(Data(SHA256.hash(data: try bytes(args, "bytes"))))
        case "hmac":
            let key = try bytes(args, "key", min: 1, max: 4096)
            return typed(Data(HMAC<SHA256>.authenticationCode(for: try bytes(args, "data"), using: SymmetricKey(data: key))))
        case "seal", "open":
            let key = SymmetricKey(data: try bytes(args, "key", min: 32, max: 32))
            let nonce = try AES.GCM.Nonce(data: bytes(args, "nonce", min: 12, max: 12))
            let aad = try bytes(args, "aad", max: 65536)
            if call.method == "seal" {
                let box = try AES.GCM.seal(bytes(args, "plaintext"), using: key, nonce: nonce, authenticating: aad)
                return typed(box.ciphertext + box.tag) // ciphertext || tag16; 不含 nonce。
            }
            let input = try bytes(args, "ciphertext", min: 16, max: Self.maxBytes + 16)
            let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: input.dropLast(16), tag: input.suffix(16))
            return typed(try AES.GCM.open(box, using: key, authenticating: aad))
        case "putSecret":
            try putSecret(try handle(args), data: try bytes(args, "bytes", max: 4096)); return nil
        case "getSecret":
            guard let value = try getSecret(try handle(args)) else { return nil }
            return typed(value)
        case "deleteSecret":
            let status = SecItemDelete(query(try handle(args)) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw BridgeError.operation }
            return nil
        default: return FlutterMethodNotImplemented
        }
    }
    private func query(_ handle: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: keychainService,
         kSecAttrAccount as String: handle,
         kSecAttrSynchronizable as String: false]
    }
    private func putSecret(_ handle: String, data: Data) throws {
        let q = query(handle)
        let attrs: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(q as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            var insert = q
            insert.merge(attrs) { _, new in new }
            guard SecItemAdd(insert as CFDictionary, nil) == errSecSuccess else { throw BridgeError.operation }
        } else if status != errSecSuccess { throw BridgeError.operation }
    }
    private func getSecret(_ handle: String) throws -> Data? {
        var q = query(handle)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, data.count <= 4096 else {
            throw BridgeError.operation
        }
        return data
    }

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        eventSink = events
        return nil
    }
    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        eventSink = nil
        stop()
        return nil
    }
    private func fail() {
        eventSink?(FlutterError(code: "discovery_failed", message: "Local network discovery unavailable", details: nil))
        stop()
    }
    private func start(id: String, port: Int) {
        stop()
        ownId = id
        // 只发布现有应用服务器端口；此桥不创建第二个监听器或传输正文。
        let service = NetService(domain: "local.", type: Self.serviceType, name: id, port: Int32(port))
        service.includesPeerToPeer = false
        service.delegate = self
        published = service
        service.publish(options: .noAutoRename)
        let search = NetServiceBrowser()
        search.includesPeerToPeer = false
        search.delegate = self
        browser = search
        search.searchForServices(ofType: Self.serviceType, inDomain: "local.")
    }
    func netServiceDidPublish(_ sender: NetService) {
        if sender === published && sender.name != ownId { fail() }
    }
    func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        if sender === published { fail() }
    }
    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        if browser === self.browser { fail() }
    }
    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        guard browser === self.browser, service.name != ownId, Self.opaque(service.name),
              service.type == Self.serviceType, services.count < 128 else { return }
        if let previous = services[service.name] { previous.delegate = nil; previous.stop() }
        services[service.name] = service
        service.includesPeerToPeer = false
        service.delegate = self
        service.resolve(withTimeout: 5)
    }
    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        guard browser === self.browser, let current = services[service.name] else { return }
        current.delegate = nil
        current.stop()
        services.removeValue(forKey: service.name)
        if var value = resolved.removeValue(forKey: service.name) {
            value["event"] = "lost"
            eventSink?(value)
        }
    }
    func netServiceDidResolveAddress(_ sender: NetService) {
        guard services[sender.name] === sender, ownId != nil, (1...65535).contains(sender.port) else { return }
        // 优先 Wi-Fi IPv4；地址仍只是提示，上层仅接受私有LAN并强制认证。
        let addresses = (sender.addresses ?? []).compactMap { numericAddress($0) }
        let ordered = addresses.filter { !$0.contains(":") } + addresses.filter { $0.contains(":") }
        for address in ordered {
            do {
                let value: [String: Any] = ["event": "found", "deviceId": sender.name,
                    "address": address, "port": sender.port]
                resolved[sender.name] = value
                eventSink?(value)
                return
            }
        }
    }
    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        // 单个不可信广告解析失败不停止整个浏览器，也不泄漏其 TXT 内容。
        if services[sender.name] === sender { sender.stop() }
    }
    private func numericAddress(_ data: Data) -> String? {
        guard data.count >= MemoryLayout<sockaddr>.size else { return nil }
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> String? in
            guard let base = raw.baseAddress else { return nil }
            let address = base.assumingMemoryBound(to: sockaddr.self)
            let family = Int32(address.pointee.sa_family)
            let required: Int
            if family == AF_INET { required = MemoryLayout<sockaddr_in>.size }
            else if family == AF_INET6 { required = MemoryLayout<sockaddr_in6>.size }
            else { return nil }
            guard data.count >= required else { return nil }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let capacity = socklen_t(host.count)
            guard getnameinfo(address, socklen_t(required), &host, capacity, nil, 0, NI_NUMERICHOST) == 0 else {
                return nil
            }
            return String(cString: host)
        }
    }
    func stop() {
        ownId = nil
        published?.delegate = nil; published?.stop(); published = nil
        browser?.delegate = nil; browser?.stop(); browser = nil
        for service in services.values { service.delegate = nil; service.stop() }
        services.removeAll(); resolved.removeAll()
    }
    /// 必须在主线程调用，并由宿主持有本对象直至 Flutter engine 关闭。
    func close() {
        closed = true
        stop()
        eventSink = nil
        cryptoChannel.setMethodCallHandler(nil)
        discoveryChannel.setMethodCallHandler(nil)
        eventChannel.setStreamHandler(nil)
        cryptoQueue.cancelAllOperations()
    }
}
