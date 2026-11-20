# 原生本机媒体引用（源码交付，未原生编译）

本模块只提供本机媒体桥，不执行相册扫描，不使用旧 picker 的重编码输出，不上传原照/原视频，不把平台定位符或原件送进手机同步。此次仅运行 Python 源码契约检查；Flutter、Dart、Android SDK、Xcode、模拟器、真机均未运行，下面行为需要原生验收后才能标为完成。

## 接线与 Dart API

Android：`WoMediaBridge.attach(activity: Activity, messenger: BinaryMessenger): WoMediaBridge`；Activity 强引用，并转发 `onActivityResult(requestCode, resultCode, data): Boolean` 和 `onRequestPermissionsResult(requestCode, permissions, grantResults): Boolean`，已消费才不交 super；销毁时 `detach()`。系统选择器使用 `ACTION_OPEN_DOCUMENT` 和持久只读授权。根模块负责 manifest 的 `ACCESS_MEDIA_LOCATION` 声明，无需新增广泛媒体读权限，也不申请设备实时定位。Android 29 以下无法证明原件，备份 fail closed。

iOS：类为 `@available(iOS 14.0, *)`；AppDelegate 在可用性判断内强引用 `WoMediaBridge.attach(messenger: FlutterBinaryMessenger, presenter: @escaping () -> UIViewController?)`。根模块负责 Swift 文件加入 Runner target、`NSPhotoLibraryUsageDescription` 以及 presenter；不修改其他接线文件。Photos 原资源读取需用户明确授权，PHPicker 本身不等于 PHAssetResource 授权。

`NativeMedia({MethodChannel? channel})` 是可注入的实例 API，channel 为 `wo.local/media`：

| 方法 | 结果与约束 |
| --- | --- |
| `pick(kind: MediaKind.photo/video, source: MediaSource.photos/files)` | `NativeMediaRef?`；取消为 null；不复制原件、不整片载入视频 |
| `resolve(handle)` | 本机状态描述；未准备快照时 `sourceExact=false`、size=0，不伪造 Photos 原件大小 |
| `prepareOriginal(handle)` | 仅显式电脑备份调用；流式写私有 snapshot，完整成功后原子发布、保存 SHA256 与 size，再返回 exact 描述 |
| `read(handle, offset:, maxBytes:)` | 只读已准备且来源保真通过的 snapshot，单块 1…8 MiB；EOF 返回空字节；无 exact 则拒绝 |
| `thumbnail(handle)` | 新 JPEG 像素编码，最长边 512，最多 96 KiB，无源 EXIF/GPS/XMP |
| `openOriginal(handle)` | 仅用户点开时原生本地预览，成功启动返回 true；无法离线/授权读取返回 false；不返回 URI |
| `release(handle)` | 删除此 App 的 registry 引用与私有 snapshot，不删除用户源文件/Photos 资源，不撤销其他记录共享的 URI grant |

`NativeMediaRef` 只允许 `handle/kind/contentType/size/sourceExact/missingReason/width/height/durationMs`。handle 为 UUID，只能进入本机 `device_refs`，不能随同步、备份元数据或日志送出。平台 URI、Photos ID、bookmark 和文件路径均不回传 Dart。缩略图字节可按已有回忆权限同步，原件分块仅供电脑备份；权限范围必须由调用层执行。

## 来源与快照保真

Android 的 registry 和 snapshot 均位于 `noBackupFilesDir`，不使用默认可备份 SharedPreferences。只打开系统包拥有且白名单内的本地 provider；未知、云端或虚拟文档 fail closed。`EXTRA_LOCAL_ONLY` 仅是选择提示，安全判断仍在每次来源访问前执行。Files 的外部存储/媒体文档必须可经 `MediaStore.getMediaUri` 转为媒体 URI，否则不声称 exact。权限拒绝、无法转换、原件读取失败均不可回退脱敏流。Android 29+ 需 `ACCESS_MEDIA_LOCATION` 和 `setRequireOriginal`；Android 31+ 还通过 `getOriginalMediaFormatFileDescriptor` 防 HDR/HEVC 自动转码。来源 FD 在复制前后核对 size/mtime；snapshots 用 64 KiB 缓冲、单件最多 20 GiB，不整片读入内存。

iOS 的 registry、bookmark 和 snapshot 位于私有 Application Support 子目录，设置并回读 `isExcludedFromBackup=true`；文件使用本机保护属性。Photos 使用唯一 `.photo` / `.video` 原资源及 `PHAssetResourceManager.requestData`，`isNetworkAccessAllowed=false`，流式写入；不走 export、AVAssetExportSession 或私有 KVC `fileSize`。云端资源需网络则标 `not_on_device`，不启用下载。HDR 原视频按原资源字节保留。Photos 可能存在不同原资源类型，无法唯一确定则 `source_not_exact`，不猜测。

iOS Files 使用 open-in-place 与安全作用域 bookmark，访问前后配对 start/stop。第三方 FileProvider 没有统一的禁止网络开关，当前保守拒绝无法证明本地的 provider；支持 App 自己沙箱文件与已在本机下载的 iCloud 项，iCloud-only 明确缺件。不能把这份实现称为任意「我的 iPhone」/任意第三方文件服务全覆盖。外部 Files 对缺少可信本地证明的情况返回 `source_unavailable`。不主动调用 iCloud 下载 API；系统选择器由用户操作期间自身发生的下载不在桥内控制。

两端 `prepareOriginal` 先撤销旧 snapshot 的可读证明，失败不会把旧内容当作新捕获成功；原件写完、同步落盘后才替换 App 自己的 snapshot。`read` 从固定 snapshot 按块读取，首次进程读取会流式复核持久摘要，进程内按 size/mtime/摘要签名缓存验证结果。App 私有文件和 registry 是信任边界，不声称抵御本机同 UID 恶意写入或精确保留 mtime 的篡改。snapshot 不参与同步，不自动删除用户原照；取消/失败的临时文件尽力清理，杀进程/断电后的残留清理需原生验证。备份层仍需将全流 SHA 与电脑落盘 SHA 对比。同一 handle 的 prepare→完整 read→摘要/归档必须由调用层串行，不能在上一轮分块读取中再次 prepare 替换该 handle 的 snapshot；原生 worker 只保证单次调用串行，不是跨 channel 调用的会话锁。

预览与备份不同：Android 对可离线读取的可信原 URI 启动 ACTION_VIEW；iOS Photos 的图片/原视频请求始终禁网，或使用已准备 snapshot。iOS Files 未准备 snapshot 的预览暂明确 false，避免 QuickLook 隐式拉云；这不代表原件不存在。原生预览成功只证明启动了查看界面，不证明完成播放或原件可完整备份。

## 必须在设备执行的验收

1. 仅空白/隔离测试包安装；取消选择为 null，拒绝媒体保真/Photos 权限后原件 read 失败，缩略图可用情况如实显示。持久 UUID 重启后仍可 resolve，不把新设备身份或旧 URI 搬到另一台。
2. 导入前独立算一张含 GPS EXIF 照片、HEIC/HDR 照片及 HDR/HEVC 视频 SHA。选择时不复制全视频；显式备份才 prepare；允许原件权限后逐块读到电脑，再独立算 SHA。必须与导入前一致；权限拒绝或来源不可证明时不得标完整。
3. iCloud-only 离线项目、第三方云 provider、已移动/删除源、撤销授权：明确缺件；不自动下载、不回退重编码/脱敏字节。iOS Files 的受支持本地子集和被拒绝的 provider 各记录一例。
4. 备份期间编辑源，snapshot 完成前变动应失败或经独立 SHA 证明确为同一捕获；完成后编辑源不能改变本轮 snapshot。重准备失败后 read 必须 fail closed。摘要损坏、错大小、分块上限/偏移、EOF、低空间、重启、断电残留均需实机。
5. 两机同步只含回忆正文权限允许的数据与小 JPEG；检查无 EXIF、handle、平台 ID、路径、bookmark、原图/视频。release 不改变相册源，另一条共享来源引用不被撤销。
6. 原生预览离线打开图片/视频及关闭、横竖屏、视频 HDR；Files 当前不支持预览的路径显示不可打开。需要真正媒体播放证据，不能用返回 true 替代。

Python 静态检查：`python3 -m unittest discover -s tool/tests -p test_native_media_contract.py -v`。这是契约源码回归，不是 Kotlin/Swift/Dart 编译或运行测试。

官方依据：[Android 媒体位置权限](https://developer.android.com/training/data-storage/shared/media#media-location-permission)、[SAF 持久授权](https://developer.android.com/training/data-storage/shared/documents-files#persist-permissions)、[MediaStore 原格式 FD](https://developer.android.com/reference/android/provider/MediaStore#getOriginalMediaFormatFileDescriptor(android.content.Context,%20android.os.ParcelFileDescriptor))、[Photos 禁止网络](https://developer.apple.com/documentation/photos/phassetresourcerequestoptions/isnetworkaccessallowed)、[原资源分块读取](https://developer.apple.com/documentation/photos/phassetresourcemanager/requestdata(for:options:datareceivedhandler:completionhandler:))、[需要网络的资源错误](https://developer.apple.com/documentation/photos/phphotoserror-swift.struct/code/networkaccessrequired)、[Files open-in-place](https://developer.apple.com/documentation/uikit/uidocumentpickerviewcontroller/init(foropeningcontenttypes:ascopy:))。这些 API 文档支持实现选择，不能替代本项目的原生实测。


## sRGB 缩略图与 JPEG 元数据兼容修复

现代 P3/HDR 图像即使重新编码，也可能被系统 JPEG 编码器自动附带 ICC APP2；同步层严格拒绝 APP1…15/COM 时不能直接提交这个结果。Android 现在把像素绘制到明确 `ColorSpace.Named.SRGB` 的8位 ARGB_8888 bitmap（API26以下为平台默认 sRGB）；iOS 使用明确 `CGColorSpace.sRGB` 的8位 CGContext 并保留 UIImage 的绘制方向。两端先转标准 SDR sRGB，再做新的 JPEG 像素编码，因此移除 ICC 不会仅删除 P3 色彩解释而把 P3 数值误当 sRGB。HDR→SDR 的观感、P3色差、EXIF旋转、透明边缘和真实设备编码行为仍未验证，不能称为色彩验收通过。

私有 `stripThumbnailMetadata` 只接收上述新编码 JPEG，不接收原输入文件/Photos资源/Files字节。解析器完整读取 SOI、段长度、SOS、多 scan、熵流中的 FF00 stuffing/重启标记/TEM、EOI；按长度移除 APP1…15（含 EXIF/XMP/ICC/厂商段）及 COM，保留 APP0/JFIF 与全部编码数据。越界长度、截断熵流、缺 EOI、EOI 后额外字节均 fail closed；最终以清理后的 JPEG 检查96 KiB上限。原件 prepare/read 路径不调用此函数，原图/原视频字节不变。

增加 Python 静态源码契约与独立合成 JPEG 段 oracle，覆盖包含假 EOI 的元数据、APP1…15/COM、两段 scan、FF00、重启/TEM、截断与非法长度。oracle 不是 Kotlin/Swift 执行，也不验证 JPEG 解码或真实 sRGB 色彩；仍未运行 SDK/模拟器/真机。实机需用 P3/HDR/标准sRGB+带GPS照片/视频分别选择，确认缩略图通过同步严格校验、可解码、方向正确、色彩可接受，同时原件导入前SHA与备份SHA仍相同。

## 应用接线与私有暂存源码

Android Activity 和 iOS 隐式Engine注册media/crypto/discovery桥；退后台停止发现。原件不可读取或授权被拒时，手机备份来源保留缩略图并返回缺件，不会用脱敏或转码流补位。

备份暂存仅能请求固定名字的App私有目录：Android noBackupFilesDir/0700，iOS ApplicationSupport/FileProtection.complete/排除备份并读回确认。拒绝符号链接或目录别名。此源码核对不等于实际OS权限、原件字节或平台编译验收。iOS Keychain采用ThisDeviceOnly且不同步；卸载后可能残留不可达旧密钥，当前新UUID引用不会自动继承旧身份，未宣称物理擦除。
