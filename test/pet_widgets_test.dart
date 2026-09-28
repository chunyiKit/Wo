import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:wo/data/api_client.dart';
import 'package:wo/data/models.dart';
import 'package:wo/data/wo_api.dart';
import 'package:wo/data/wo_session.dart';
import 'package:wo/features/family/family_manage_page.dart';
import 'package:wo/features/family/pet_profile_edit_page.dart';
import 'package:wo/features/home/home_page.dart';
import 'package:wo/features/plugins/pet/pet_list_page.dart';
import 'package:wo/features/plugins/pet/pet_detail_page.dart';
import 'package:wo/features/plugins/pet/pet_record_edit_page.dart';
import 'package:wo/features/plugins/pet/pet_settings_page.dart';
import 'package:wo/navigation/wo_router.dart';
import 'package:wo/navigation/wo_routes.dart';
import 'package:wo/theme/wo_theme.dart';
import 'package:wo/theme/wo_tokens.dart';
import 'package:wo/widgets/pet_avatar.dart';

Map<String, dynamic> _family() => {
      'id': 'f1',
      'name': '我的家',
      'emoji': '🏡',
      'member_count': 2,
      'pet_count': 0,
      'my_role': 'owner',
      'my_unread_count': 0,
    };

Map<String, dynamic> _envelope(Object? data) => {
      'success': true,
      'data': data,
      'error': null,
      'meta': null,
    };

Map<String, dynamic> _type({String id = 't1', String name = '驱虫'}) => {
      'id': id,
      'family_id': 'f1',
      'name': name,
      'emoji': '🛡️',
      'data_kind': 'general',
      'sort_order': 0,
      'archived': false,
    };

Map<String, dynamic> _pet() => {
      'id': 'p1',
      'family_id': 'f1',
      'name': '团子',
      'emoji': '🐈',
      'breed': '英短',
      'photo_url': null,
    };

Map<String, dynamic> _plan() => {
      'id': 'plan1',
      'family_id': 'f1',
      'pet_id': 'p1',
      'record_type_id': 't1',
      'type_name': '驱虫',
      'type_emoji': '🛡️',
      'data_kind': 'general',
      'name': '体内驱虫',
      'recurrence_unit': 'month',
      'recurrence_interval': 3,
      'next_due_date': '2026-08-14',
      'active': true,
      'days_until': 0,
    };

Map<String, dynamic> _dashboard({String? cursor}) => {
      'pet': _pet(),
      'today_plans': [_plan()],
      'upcoming_plans': [],
      'latest_weight': null,
      'weight_trend': [],
      'records': [
        {
          'id': 'r1',
          'family_id': 'f1',
          'pet_id': 'p1',
          'record_type_id': 't1',
          'type_name': '驱虫',
          'type_emoji': '🛡️',
          'data_kind': 'general',
          'name': '上次驱虫',
          'occurred_on': '2026-05-14',
          'creator_name': '主理人',
          'creator_emoji': '👤',
          'attachments': [],
        },
      ],
      'records_cursor': cursor,
    };

Future<WoSession> _session(
  Object? Function(http.Request request) response,
) async {
  final client = MockClient((request) async {
    final data = response(request);
    return http.Response(
      jsonEncode(_envelope(data)),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );
  });
  final session = WoSession(
    api: WoApi(ApiClient(httpClient: client, baseUrl: 'http://test')),
  );
  await session.load();
  return session;
}

Widget _app(WoSession session, Widget home) => WoScope(
      session: session,
      child: MaterialApp(theme: WoTheme.light(), home: home),
    );

void main() {
  testWidgets('宠物记录日历优先响应系统返回，保留未保存内容', (tester) async {
    final session = await _session((request) {
      final path = request.url.path;
      if (path.endsWith('/me/bootstrap')) {
        return {
          'user': {
            'id': 'u1',
            'username': 'owner',
            'display_name': '主理人',
            'avatar_emoji': '👤',
          },
          'current_family': _family(),
          'families': [_family()],
          'installed_plugins': [],
          'unread_count': 0,
        };
      }
      if (path.endsWith('/plugins/pet/record-types')) return [_type()];
      throw StateError('unexpected ${request.url}');
    });
    final router = buildRouter()..go(WoRoutes.home);
    addTearDown(router.dispose);
    await tester.pumpWidget(
      WoScope(
        session: session,
        child: MaterialApp.router(
          theme: WoTheme.light(),
          routerConfig: router,
        ),
      ),
    );
    await tester.pumpAndSettle();
    Navigator.of(tester.element(find.byType(HomePage))).push<void>(
      MaterialPageRoute(
        builder: (_) => const PetRecordEditPage(petId: 'p1'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(WoTextField).first, '未保存的驱虫记录');
    // 收起输入法，让系统返回直接进入路由分发。
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    final originalDate = tester
        .widget<Text>(
          find
              .descendant(
                of: find.widgetWithText(WoListTile, '发生日期'),
                matching: find.byType(Text),
              )
              .last,
        )
        .data;
    await tester.tap(find.text('发生日期'));
    await tester.pumpAndSettle();
    expect(find.byType(DatePickerDialog), findsOneWidget);
    await tester.tap(find.text(originalDate!.endsWith('-01') ? '2' : '1'));
    await tester.pumpAndSettle();
    // Android 预测式返回通过 backgesture 通道分发。
    for (final call in [
      const MethodCall('startBackGesture', {
        'touchOffset': [5.0, 300.0],
        'progress': 0.0,
        'swipeEdge': 0,
      }),
      const MethodCall('commitBackGesture'),
    ]) {
      await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        'flutter/backgesture',
        const StandardMethodCodec().encodeMethodCall(call),
        (_) {},
      );
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(find.byType(DatePickerDialog), findsNothing);
    expect(find.byType(PetRecordEditPage), findsOneWidget);
    expect(find.text('未保存的驱虫记录'), findsOneWidget);
    expect(find.text(originalDate), findsOneWidget);

    // 取消下次日期时不启用计划，也不能退出记录表单。
    await tester.ensureVisible(find.byType(Switch).first);
    await tester.tap(find.byType(Switch).first);
    await tester.pumpAndSettle();
    expect(find.byType(DatePickerDialog), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(DatePickerDialog), findsNothing);
    expect(tester.widget<Switch>(find.byType(Switch).first).value, isFalse);
    expect(find.text('未保存的驱虫记录'), findsOneWidget);

    // 日历关闭后，系统返回恢复为退出记录表单。
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(PetRecordEditPage), findsNothing);
    expect(find.byType(HomePage), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('PetAvatar without photo renders emoji fallback', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: PetAvatar(
          emoji: '🐈',
          size: 64,
          placeholderColor: Colors.pink.shade50,
        ),
      ),
    );
    expect(find.text('🐈'), findsOneWidget);
  });

  testWidgets('pet form previews a selected local photo immediately', (
    tester,
  ) async {
    final session = await _session((request) {
      if (request.url.path.endsWith('/me/bootstrap')) {
        return {
          'user': {
            'id': 'u1',
            'username': 'owner',
            'display_name': '主理人',
            'avatar_emoji': '👤',
          },
          'current_family': _family(),
          'families': [_family()],
          'installed_plugins': [],
          'unread_count': 0,
        };
      }
      throw StateError('unexpected ${request.url}');
    });
    final imageBytes = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
    );
    await tester.pumpWidget(
      _app(session, PetProfileEditPage(imagePicker: () async => imageBytes)),
    );

    final avatar = find.byType(PetAvatar);
    expect(
      find.descendant(of: avatar, matching: find.byType(Image)),
      findsNothing,
    );
    await tester.tap(find.byKey(const ValueKey('pet-photo-picker')));
    await tester.pump();
    expect(
      find.descendant(of: avatar, matching: find.byType(Image)),
      findsOneWidget,
    );
  });

  testWidgets('pet form keeps a full spacing token between adjacent inputs', (
    tester,
  ) async {
    final session = await _session((request) {
      if (request.url.path.endsWith('/me/bootstrap')) {
        return {
          'user': {
            'id': 'u1',
            'username': 'owner',
            'display_name': '主理人',
            'avatar_emoji': '👤',
          },
          'current_family': _family(),
          'families': [_family()],
          'installed_plugins': [],
          'unread_count': 0,
        };
      }
      throw StateError('unexpected ${request.url}');
    });
    await tester.pumpWidget(_app(session, const PetProfileEditPage()));

    final fields = find.byType(WoTextField);
    final nameRect = tester.getRect(fields.at(0));
    final emojiRect = tester.getRect(fields.at(1));
    expect(
      emojiRect.top - nameRect.bottom,
      greaterThanOrEqualTo(WoTokens.space4),
    );
  });

  testWidgets('pet list empty state keeps add entry visible', (tester) async {
    final session = await _session((request) {
      if (request.url.path.endsWith('/me/bootstrap')) {
        return {
          'user': {
            'id': 'u1',
            'username': 'owner',
            'display_name': '主理人',
            'avatar_emoji': '👤',
          },
          'current_family': _family(),
          'families': [_family()],
          'installed_plugins': [],
          'unread_count': 0,
        };
      }
      if (request.url.path.endsWith('/plugins/pet/pets')) return [];
      throw StateError('unexpected ${request.url}');
    });
    await tester.pumpWidget(_app(session, const PetListPage()));
    await tester.pumpAndSettle();
    expect(find.text('先添加一位宠物家人'), findsOneWidget);
    expect(find.text('添加宠物'), findsOneWidget);
  });

  testWidgets('multiple pets fit a compact phone viewport without overflow', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 568));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final session = await _session((request) {
      if (request.url.path.endsWith('/me/bootstrap')) {
        return {
          'user': {
            'id': 'u1',
            'username': 'owner',
            'display_name': '主理人',
            'avatar_emoji': '👤',
          },
          'current_family': _family(),
          'families': [_family()],
          'installed_plugins': [],
          'unread_count': 0,
        };
      }
      if (request.url.path.endsWith('/plugins/pet/pets')) {
        return [
          {'pet': _pet(), 'next_plan': _plan(), 'latest_weight': null},
          {
            'pet': {..._pet(), 'id': 'p2', 'name': '一只名字很长的测试宠物'},
            'next_plan': null,
            'latest_weight': {
              'record_id': 'r2',
              'occurred_on': '2026-08-14',
              'weight_kg': '5.2',
            },
          },
        ];
      }
      throw StateError('unexpected ${request.url}');
    });
    await tester.pumpWidget(_app(session, const PetListPage()));
    await tester.pumpAndSettle();
    expect(find.text('团子'), findsOneWidget);
    expect(find.text('一只名字很长的测试宠物'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'family management separates people and pets and has no pet role',
    (tester) async {
      final session = await _session((request) {
        final path = request.url.path;
        if (path.endsWith('/me/bootstrap')) {
          return {
            'user': {
              'id': 'u1',
              'username': 'owner',
              'display_name': '主理人',
              'avatar_emoji': '👤',
            },
            'current_family': _family(),
            'families': [_family()],
            'installed_plugins': [],
            'unread_count': 0,
          };
        }
        if (path.endsWith('/families/f1')) return _family();
        if (path.endsWith('/families/f1/members')) {
          return [
            {
              'user_id': 'u1',
              'family_id': 'f1',
              'role': 'owner',
              'display_name': '主理人',
              'avatar_emoji': '👤',
              'status': 'active',
            },
            {
              'user_id': 'u2',
              'family_id': 'f1',
              'role': 'member',
              'display_name': '小林',
              'avatar_emoji': '👩',
              'status': 'active',
            },
          ];
        }
        if (path.endsWith('/families/f1/pets')) return [];
        throw StateError('unexpected ${request.url}');
      });
      await tester.pumpWidget(_app(session, const FamilyManagePage()));
      await tester.pumpAndSettle();
      expect(find.text('家人 · 2'), findsOneWidget);
      expect(find.text('宠物 · 0'), findsOneWidget);
      expect(find.text('+ 邀请家人'), findsOneWidget);
      expect(find.text('+ 添加宠物'), findsOneWidget);

      await tester.tap(find.text('小林'));
      await tester.pumpAndSettle();
      expect(find.text('设为管理员'), findsOneWidget);
      expect(find.text('设为孩子'), findsOneWidget);
      expect(find.text('设为宠物'), findsNothing);
    },
  );

  testWidgets(
    'pet detail completes care locally and exposes timeline pagination',
    (tester) async {
      var completed = 0;
      final session = await _session((request) {
        final path = request.url.path;
        if (path.endsWith('/me/bootstrap')) {
          return {
            'user': {
              'id': 'u1',
              'username': 'owner',
              'display_name': '主理人',
              'avatar_emoji': '👤',
            },
            'current_family': _family(),
            'families': [_family()],
            'installed_plugins': [],
            'unread_count': 0,
          };
        }
        if (path.endsWith('/plans/plan1/completions')) {
          completed++;
          return {
            ...(_dashboard()['records'] as List).first as Map<String, dynamic>,
            'id': 'done1',
            'name': '体内驱虫',
          };
        }
        if (path.endsWith('/plugins/pet/pets/p1')) {
          return _dashboard(cursor: 'next');
        }
        if (path.endsWith('/plugins/pet/pets/p1/records')) {
          return [];
        }
        throw StateError('unexpected ${request.url}');
      });
      await tester.pumpWidget(_app(session, const PetDetailPage(petId: 'p1')));
      await tester.pumpAndSettle();
      expect(find.text('今日照护'), findsOneWidget);
      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();
      expect(completed, 1);
      await tester.scrollUntilVisible(
        find.text('加载更多'),
        400,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('健康时间线'), findsOneWidget);
      expect(find.text('加载更多'), findsOneWidget);
    },
  );

  testWidgets('record form reveals flexible next-date cycle controls', (
    tester,
  ) async {
    final session = await _session((request) {
      final path = request.url.path;
      if (path.endsWith('/me/bootstrap')) {
        return {
          'user': {
            'id': 'u1',
            'username': 'owner',
            'display_name': '主理人',
            'avatar_emoji': '👤',
          },
          'current_family': _family(),
          'families': [_family()],
          'installed_plugins': [],
          'unread_count': 0,
        };
      }
      if (path.endsWith('/plugins/pet/record-types')) return [_type()];
      throw StateError('unexpected ${request.url}');
    });
    await tester.pumpWidget(
      _app(session, const PetRecordEditPage(petId: 'p1')),
    );
    await tester.pumpAndSettle();
    expect(find.text('记录名称 *'), findsOneWidget);
    expect(find.text('设置下次日期'), findsOneWidget);
    final recordTypeField = find.byWidgetPredicate(
      (widget) => widget is WoDropdownButtonFormField<String>,
    );
    final recordNameField = find.byType(WoTextField).first;
    expect(
      tester.getTopLeft(recordNameField).dy -
          tester.getBottomLeft(recordTypeField.first).dy,
      greaterThanOrEqualTo(WoTokens.space4),
    );

    await tester.tap(find.byType(Switch).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView).first, const Offset(0, -260));
    await tester.pumpAndSettle();
    expect(find.text('周期'), findsOneWidget);
    expect(find.text('仅一次'), findsOneWidget);
  });

  testWidgets(
    'settings exposes profile, type management, and every cycle unit',
    (tester) async {
      final session = await _session((request) {
        final path = request.url.path;
        if (path.endsWith('/me/bootstrap')) {
          return {
            'user': {
              'id': 'u1',
              'username': 'owner',
              'display_name': '主理人',
              'avatar_emoji': '👤',
            },
            'current_family': _family(),
            'families': [_family()],
            'installed_plugins': [],
            'unread_count': 0,
          };
        }
        if (path.endsWith('/plugins/pet/pets/p1/plans')) return [];
        if (path.endsWith('/plugins/pet/record-types')) return [_type()];
        throw StateError('unexpected ${request.url}');
      });
      await tester.pumpWidget(
        _app(session, PetSettingsPage(pet: Pet.fromJson(_pet()))),
      );
      await tester.pumpAndSettle();
      expect(find.text('记录类型管理'), findsOneWidget);
      await tester.tap(find.text('新建'));
      await tester.pumpAndSettle();
      expect(find.text('仅一次'), findsOneWidget);
      final planFields = find.byType(WoTextFormField);
      final planNameRect = tester.getRect(planFields.at(0));
      final planNoteRect = tester.getRect(planFields.at(1));
      expect(
        planNoteRect.top - planNameRect.bottom,
        greaterThanOrEqualTo(WoTokens.space4),
      );
      await tester.tap(find.text('仅一次').last);
      await tester.pumpAndSettle();
      expect(find.text('每 N 天'), findsOneWidget);
      expect(find.text('每 N 周'), findsOneWidget);
      expect(find.text('每 N 月'), findsOneWidget);
      expect(find.text('每 N 年'), findsOneWidget);
    },
  );

  testWidgets('record type dialog uses the shared form spacing', (
    tester,
  ) async {
    final session = await _session((request) {
      final path = request.url.path;
      if (path.endsWith('/me/bootstrap')) {
        return {
          'user': {
            'id': 'u1',
            'username': 'owner',
            'display_name': '主理人',
            'avatar_emoji': '👤',
          },
          'current_family': _family(),
          'families': [_family()],
          'installed_plugins': [],
          'unread_count': 0,
        };
      }
      if (path.endsWith('/plugins/pet/record-types')) return [_type()];
      throw StateError('unexpected ${request.url}');
    });
    await tester.pumpWidget(_app(session, const PetTypeManagePage()));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();

    final fields = find.byType(WoTextFormField);
    final nameRect = tester.getRect(fields.at(0));
    final emojiRect = tester.getRect(fields.at(1));
    final kindField = find.byWidgetPredicate(
      (widget) => widget is WoDropdownButtonFormField<String>,
    );
    final kindRect = tester.getRect(kindField.first);
    expect(
      emojiRect.top - nameRect.bottom,
      greaterThanOrEqualTo(WoTokens.space4),
    );
    expect(
      kindRect.top - emojiRect.bottom,
      greaterThanOrEqualTo(WoTokens.space4),
    );
  });
}
