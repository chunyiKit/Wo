import 'dart:convert';

import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';
import 'wo_api.dart';

/// 「回忆」列表的本地缓存：内容走 SharedPreferences，封面图走 flutter_cache_manager
/// 磁盘缓存。目标是「从主页点进回忆秒开」——
///
/// 1. 启动 splash 转圈期间（[warmOnLaunch]）+ 主页加载（[prefetch]）后台预取：进页面前就把
///    前 [_keep] 条内容存好、并把这些条目的**全部照片**预热进磁盘缓存；
/// 2. 进回忆页时先吃缓存（[peek] 同步命中即首帧渲染，未命中再 [load] 读盘），不等网络、
///    不显骨架，网络回来再静默替换并 [save] 回写。
///
/// 杀进程重进后内存缓存清空，[warmOnLaunch] 会用磁盘上已存的内容缓存「按已有引用补图」，
/// 离线也能恢复媒体预热。
///
/// 缓存只存前 [_keep] 条（覆盖首屏足够），留言不入缓存（详情页会自己拉），体积可控。
class MemoryCache {
  MemoryCache._();

  /// 缓存条数：覆盖首屏即可，既够「秒开」又不至于撑大 prefs。
  static const int _keep = 5;
  static const String _prefix = 'wo.memory.cache.';

  /// 进程内热缓存：同一次启动内重复进出回忆无需读盘，真正同步秒开。按家庭分桶。
  static final Map<String, List<Memory>> _mem = {};

  /// 本次启动已预取过的家庭，避免主页每次重建都重复后台拉取。
  static final Set<String> _prefetched = {};

  /// 同步读取进程内缓存（首帧 build 用，命中即可立即渲染）。
  static List<Memory>? peek(String familyId) => _mem[familyId];

  /// 读取缓存：优先进程内，未命中再读盘（冷启动后第一次）。
  static Future<List<Memory>?> load(String familyId) async {
    final hot = _mem[familyId];
    if (hot != null) return hot;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('$_prefix$familyId');
      if (raw == null || raw.isEmpty) return null;
      final list = (jsonDecode(raw) as List)
          .map((e) => Memory.fromJson(e as Map<String, dynamic>))
          .toList();
      _mem[familyId] = list;
      return list;
    } catch (_) {
      // 缓存损坏 / 模型版本不兼容：当作没有，走网络。
      return null;
    }
  }

  /// 写入缓存（取前 [_keep] 条）：更新进程内 + 落盘。
  static Future<void> save(String familyId, List<Memory> all) async {
    final keep = all.length > _keep ? all.sublist(0, _keep) : all;
    _mem[familyId] = keep;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = jsonEncode(keep.map((m) => m.toJson()).toList());
      await prefs.setString('$_prefix$familyId', raw);
    } catch (_) {
      // 落盘失败不致命，进程内缓存仍生效。
    }
  }

  /// 预热前 [_keep] 条的**全部照片**进磁盘缓存（带鉴权头），best-effort、不阻塞主流程。
  ///
  /// 视频在列表里是占位图标、不走网络，无需预热，这里只收照片。用 [getSingleFile]
  /// 而非 downloadFile：命中缓存直接返回、缺失才下载，幂等不会重复拉，因此可多次安全调用
  /// （splash 与主页都会触发）。限并发分批，避免一次几十张图打满带宽。
  static Future<void> prewarmImages(WoApi api, List<Memory> all) async {
    final headers = api.imageHeaders;
    final cm = DefaultCacheManager();
    final keep = all.length > _keep ? all.sublist(0, _keep) : all;

    final urls = <String>[];
    for (final m in keep) {
      for (final media in m.media) {
        if (media.isVideo) continue;
        urls.add(api.memoryMediaUrl(media));
      }
    }
    if (urls.isEmpty) return;

    const concurrency = 5;
    for (var i = 0; i < urls.length; i += concurrency) {
      final end = i + concurrency;
      final batch = urls.sublist(i, end < urls.length ? end : urls.length);
      await Future.wait(
        batch.map((u) async {
          try {
            await cm.getSingleFile(u, headers: headers);
          } catch (_) {
            // 单张失败忽略，继续预热其余。
          }
        }),
      );
    }
  }

  /// 用磁盘上已有的内容缓存把媒体重新预热进图片缓存——进程被杀后内存缓存没了，
  /// 启动时靠这一步「按已有引用补图」，离线也能用（不发列表请求）。
  static Future<void> warmFromDisk(WoApi api, String familyId) async {
    final cached = await load(familyId);
    if (cached == null || cached.isEmpty) return;
    await prewarmImages(api, cached);
  }

  /// 启动（splash 转圈期间）后台预热：先吃磁盘已有内容立即补图（离线可用、最快），
  /// 再走网络预取刷新内容 + 预热新图。未装回忆 / 无家庭则跳过。
  static Future<void> warmOnLaunch(
    WoApi api,
    String? familyId,
    List<InstalledPlugin> installed,
  ) async {
    if (familyId == null) return;
    if (!installed.any((p) => p.pluginId == 'memory')) return;
    await warmFromDisk(api, familyId);
    await prefetch(api, familyId);
  }

  /// 主页后台预取：拉**首页**（覆盖缓存的前 [_keep] 条即够）→ 存内容 → 预热照片。
  /// 每次启动每个家庭只做一次。时间线分页后，缓存只关心首屏，故只取首页不翻全量。
  static Future<void> prefetch(WoApi api, String familyId) async {
    if (_prefetched.contains(familyId)) return;
    _prefetched.add(familyId);
    try {
      final page = await api.memories(familyId, limit: _keep);
      await save(familyId, page.items);
      await prewarmImages(api, page.items);
    } catch (_) {
      _prefetched.remove(familyId); // 失败允许下次再试。
    }
  }

  /// 登出时清空内容缓存与进程内状态（图片磁盘缓存归「清理缓存」页统一管理）。
  static Future<void> clearAll() async {
    _mem.clear();
    _prefetched.clear();
    try {
      final prefs = await SharedPreferences.getInstance();
      final keys = prefs.getKeys().where((k) => k.startsWith(_prefix)).toList();
      for (final k in keys) {
        await prefs.remove(k);
      }
    } catch (_) {
      // 清理失败忽略。
    }
  }
}
