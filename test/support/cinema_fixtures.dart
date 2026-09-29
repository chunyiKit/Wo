import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:wo/data/api_client.dart';
import 'package:wo/data/wo_api.dart';
import 'package:wo/data/wo_session.dart';
import 'package:wo/features/plugins/accounting/expense_categories.dart';

/// 仅测试和本地视觉预览使用，不进入 lib/main.dart 的 release 依赖图。
const cinemaPlugins = <String, (String, String, String)>{
  'anniversary': ('纪念日', '相伴的第 1,077 天', '三周年，还有 18 天'),
  'accounting': ('家庭账本', '¥3,280', '本月预算剩余 ¥1,720'),
  'memory': ('生活碎片', '收藏每一个平凡的今天', '一起去看海 · 12 段回忆'),
  'chore': ('家务活', '今天还有 2 件事', '一起把小家照顾好'),
  'calendar': ('家历', '周末一起去看展', '明天 14:00'),
  'stock': ('囤货铺', '厨房补货清单', '3 件待采买'),
  'recipe': ('小家食谱', '今晚吃什么', '把日子煮成热气腾腾'),
  'movie': ('一起看电影', '周末放映室', '收藏想一起看的故事'),
  'pet': ('宠物日常', '毛孩子的小日子', '照护与健康，认真记录'),
  'subscription': ('订阅管家', '每一份订阅都值得', '按时提醒，不再忘记'),
  'plant': ('植物日记', '和绿意一起生长', '记录小家的每一抹绿'),
  'retirement': ('退休倒计时', '奔向自由的生活', '积累今天，期待明天'),
  'expiry': ('到期管家', '重要的日期', '证件与物品，安心管理'),
  'travel': ('旅行', '下一站，一起出发', '把足迹留在地图上'),
  'chat': ('家聊', '想说的话，留在这里', '和家人聊聊今天'),
};

Map<String, Object?> cinemaPlugin(String id) => {
      'id': id,
      'name': cinemaPlugins[id]!.$1,
      'description_short': cinemaPlugins[id]!.$3,
      'description_long': '记录家庭生活，与重要的人一起分享。',
      'emoji': '✨',
      'category': 'life',
      'color_token': id == 'accounting'
          ? 'money'
          : id == 'anniversary'
              ? 'anniv'
              : id,
      'version': '1.0.0',
      'publisher': '窝',
      'permissions': [],
      'screenshots': [],
    };
Map<String, Object?> cinemaInstalled(String id) => {
      'id': 'installed-$id',
      'family_id': 'cinema-family',
      'plugin_id': id,
      'plugin': cinemaPlugin(id),
      'enabled': true,
      'layout': {'col': 0, 'row': 0, 'cw': id == 'memory' ? 4 : 2, 'ch': 2},
      'preview': {
        'primary': cinemaPlugins[id]!.$2,
        'secondary': cinemaPlugins[id]!.$3,
        'color_token': id,
      },
    };
const cinemaFamily = {
  'id': 'cinema-family',
  'name': '我们的小窝',
  'emoji': '🏡',
  'member_count': 2,
  'pet_count': 0,
  'my_role': 'owner',
};
const cinemaUser = {
  'id': 'cinema-user',
  'username': 'cinema-preview',
  'display_name': '小柚',
  'avatar_emoji': '🌼',
};

Object? cinemaResponse(http.Request request) {
  final path = request.url.path;
  if (path.endsWith('/me/bootstrap')) {
    return {
      'user': cinemaUser,
      'current_family': cinemaFamily,
      'families': [cinemaFamily],
      'installed_plugins': cinemaPlugins.keys.map(cinemaInstalled).toList(),
      'unread_count': 2,
    };
  }
  if (path.endsWith('/app/version')) return null;
  if (path.endsWith('/me')) {
    return {'user': cinemaUser, 'current_family': cinemaFamily, 'stats': {}};
  }
  if (path.endsWith('/families/cinema-family')) return cinemaFamily;
  if (path.endsWith('/members')) {
    return [
      {
        'user_id': 'cinema-user',
        'display_name': '小柚',
        'avatar_emoji': '🌼',
        'role': 'owner',
      },
      {
        'user_id': 'cinema-partner',
        'display_name': '阿哲',
        'avatar_emoji': '🌊',
        'role': 'adult',
      },
    ];
  }
  if (path.endsWith('/notifications')) {
    return [
      {
        'id': 'n1',
        'title': '给生活留一点仪式感',
        'body': '三周年纪念日还有 18 天。',
        'icon_emoji': '💫',
        'is_read': false,
        'created_at': DateTime.now().toIso8601String(),
      },
      {
        'id': 'n2',
        'title': '冰箱该补货了',
        'body': '采买清单里还有 3 件物品。',
        'icon_emoji': '🛒',
        'is_read': false,
        'created_at': DateTime.now().toIso8601String(),
      },
    ];
  }
  if (path.endsWith('/plugins') && !path.contains('/families/')) {
    return cinemaPlugins.keys.map(cinemaPlugin).toList();
  }
  if (path.endsWith('/plugins')) {
    return cinemaPlugins.keys.map(cinemaInstalled).toList();
  }
  if (RegExp(r'/plugins/[^/]+$').hasMatch(path) &&
      !path.contains('/families/')) {
    return cinemaPlugin(path.split('/').last);
  }
  if (path.endsWith('/accounting/categories')) {
    return [
      for (final category in expenseCategories)
        {
          'code': category.code,
          'label': category.label,
          'emoji': category.emoji,
        },
    ];
  }
  if (path.endsWith('/summary')) {
    return {
      'month_total': 3280,
      'budget': 5000,
      'remaining': 1720,
      'budgeted_total': 3280,
      'excluded_total': 0,
    };
  }
  if (path.endsWith('/budget')) return {'amount': 5000};
  if (path.endsWith('/transactions')) {
    return [
      {
        'id': 't1',
        'amount': 186,
        'category': 'dining',
        'note': '周末一起吃火锅',
        'creator_name': '小柚',
        'creator_emoji': '🌼',
        'created_at': DateTime.now().toIso8601String(),
      },
      {
        'id': 't2',
        'amount': 89,
        'category': 'shopping',
        'note': '给小家买一束花',
        'creator_name': '阿哲',
        'creator_emoji': '🌊',
        'created_at': DateTime.now().toIso8601String(),
      },
    ];
  }
  if (path.endsWith('/dates')) {
    return [
      {
        'id': 'a1',
        'name': '我们的三周年',
        'event_date': '2023-09-23',
        'days_until': 18,
        'emoji': '💞',
      },
      {
        'id': 'a2',
        'name': '第一次一起去看海',
        'event_date': '2024-10-12',
        'days_until': 37,
        'emoji': '🌊',
      },
    ];
  }
  if (path.endsWith('/dashboard') ||
      path.endsWith('/plan') ||
      path.endsWith('/settings') ||
      path.endsWith('/weather')) {
    return <String, Object?>{};
  }
  if (path.endsWith('/notification-preferences')) {
    return {'enabled': true, 'sources': []};
  }
  const listEnds = [
    '/chores',
    '/items',
    '/buys',
    '/recipes',
    '/tags',
    '/memories',
    '/movies',
    '/genres',
    '/subscriptions',
    '/plants',
    '/accounts',
    '/debts',
    '/ledger',
    '/pets',
    '/record-types',
    '/trips',
    '/ai-models',
    '/messages',
  ];
  if (listEnds.any(path.endsWith)) return [];
  throw StateError('未提供视觉测试响应: ${request.method} $path');
}

Future<WoSession> cinemaSession() async {
  final client = MockClient(
    (request) async => http.Response(
      jsonEncode({
        'success': true,
        'data': cinemaResponse(request),
        'error': null,
        'meta': {'total': 0},
      }),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    ),
  );
  final session = WoSession(
    api: WoApi(ApiClient(httpClient: client, baseUrl: 'http://cinema.test')),
  );
  await session.load();
  return session;
}
