import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wo/data/wo_session.dart';
import 'package:wo/theme/wo_theme.dart';
import 'package:wo/theme/wo_tokens.dart';
import 'package:wo/widgets/async_view.dart';
import 'support/cinema_fixtures.dart';
import 'dart:async';
import 'package:wo/features/home/home_page.dart';
import 'package:wo/features/auth/login_page.dart';
import 'package:wo/features/onboarding/onboarding_page.dart';
import 'package:wo/features/join/join_landing_page.dart';
import 'package:wo/features/join/create_family_page.dart';
import 'package:wo/features/join/join_by_code_page.dart';
import 'package:wo/features/profile/profile_page.dart';
import 'package:wo/features/profile/settings_page.dart';
import 'package:wo/features/profile/appearance_page.dart';
import 'package:wo/features/profile/change_password_page.dart';
import 'package:wo/features/profile/notification_prefs_page.dart';
import 'package:wo/features/marketplace/marketplace_page.dart';
import 'package:wo/features/family/family_manage_page.dart';
import 'package:wo/features/messages/messages_page.dart';
import 'package:wo/features/plugins/accounting/accounting_page.dart';
import 'package:wo/features/plugins/anniversary/anniversary_list_page.dart';
import 'package:wo/features/plugins/chore/chore_list_page.dart';
import 'package:wo/features/plugins/stock/stock_page.dart';
import 'package:wo/features/plugins/recipe/recipe_list_page.dart';
import 'package:wo/features/plugins/memory/memory_list_page.dart';
import 'package:wo/features/plugins/movie/movie_list_page.dart';
import 'package:wo/features/plugins/calendar/calendar_list_page.dart';
import 'package:wo/features/plugins/subscription/subscription_page.dart';
import 'package:wo/features/plugins/plant/plant_list_page.dart';
import 'package:wo/features/plugins/retirement/retirement_page.dart';
import 'package:wo/features/plugins/expiry/expiry_page.dart';
import 'package:wo/features/plugins/pet/pet_list_page.dart';
import 'package:wo/features/plugins/anniversary/anniversary_edit_page.dart';
import 'package:wo/features/plugins/chore/chore_edit_page.dart';
import 'package:wo/features/plugins/calendar/calendar_edit_page.dart';
import 'package:wo/features/plugins/recipe/recipe_edit_page.dart';
import 'package:wo/features/plugins/stock/buy_item_edit_page.dart';
import 'package:wo/features/plugins/stock/stock_item_edit_page.dart';
import 'package:wo/features/plugins/retirement/account_edit_page.dart';
import 'package:wo/features/plugins/retirement/debt_edit_page.dart';
import 'package:wo/features/plugins/retirement/plan_edit_page.dart';
import 'package:wo/features/plugins/memory/memory_edit_page.dart';

void main() {
  final screens = <String, Widget>{
    'HomePage': const HomePage(),
    'LoginPage': const LoginPage(),
    'OnboardingPage': const OnboardingPage(),
    'JoinLandingPage': const JoinLandingPage(),
    'CreateFamilyPage': const CreateFamilyPage(),
    'JoinByCodePage': const JoinByCodePage(),
    'ProfilePage': const ProfilePage(),
    'SettingsPage': const SettingsPage(),
    'AppearancePage': const AppearancePage(),
    'ChangePasswordPage': const ChangePasswordPage(),
    'NotificationPrefsPage': const NotificationPrefsPage(),
    'MarketplacePage': const MarketplacePage(),
    'FamilyManagePage': const FamilyManagePage(),
    'MessagesPage': const MessagesPage(),
    'AccountingPage': const AccountingPage(),
    'AnniversaryListPage': const AnniversaryListPage(),
    'ChoreListPage': const ChoreListPage(),
    'StockPage': const StockPage(),
    'RecipeListPage': const RecipeListPage(),
    'MemoryListPage': const MemoryListPage(),
    'MovieListPage': const MovieListPage(),
    'CalendarListPage': const CalendarListPage(),
    'SubscriptionPage': const SubscriptionPage(),
    'PlantListPage': const PlantListPage(),
    'RetirementPage': const RetirementPage(),
    'ExpiryPage': const ExpiryPage(),
    'PetListPage': const PetListPage(),
    'AnniversaryEditPage': const AnniversaryEditPage(),
    'ChoreEditPage': const ChoreEditPage(),
    'CalendarEditPage': const CalendarEditPage(),
    'RecipeEditPage': const RecipeEditPage(),
    'BuyItemEditPage': const BuyItemEditPage(),
    'StockItemEditPage': const StockItemEditPage(),
    'AccountEditPage': const AccountEditPage(),
    'DebtEditPage': const DebtEditPage(),
    'PlanEditPage': const PlanEditPage(),
    'MemoryEditPage': const MemoryEditPage(),
  };
  for (final dark in [true, false]) {
    for (final entry in screens.entries) {
      testWidgets('${entry.key} ${dark ? '影院' : '暖纸'} 窄屏与大字布局', (tester) async {
        SharedPreferences.setMockInitialValues({});
        tester.view.physicalSize = Size(dark ? 320 : 360, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final session = await cinemaSession();
        await tester.pumpWidget(
          WoScope(
            session: session,
            child: MaterialApp(
              theme: dark ? WoTheme.dark() : WoTheme.light(),
              locale: const Locale('zh', 'CN'),
              supportedLocales: const [Locale('zh', 'CN')],
              localizationsDelegates: const [
                GlobalMaterialLocalizations.delegate,
                GlobalWidgetsLocalizations.delegate,
                GlobalCupertinoLocalizations.delegate,
              ],
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  textScaler: TextScaler.linear(1.3),
                  disableAnimations: true,
                ),
                child: child!,
              ),
              home: entry.value,
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        expect(tester.takeException(), isNull, reason: entry.key);
        expect(
          find.text('加载失败'),
          findsNothing,
          reason: '数据加载必须成功，不能把错误页当成验收通过',
        );
        final scrollables = find.byType(Scrollable);
        if (scrollables.evaluate().isNotEmpty &&
            entry.key != 'OnboardingPage') {
          await tester.drag(scrollables.first, const Offset(0, -450));
          await tester.pump(const Duration(milliseconds: 600));
          expect(tester.takeException(), isNull, reason: '${entry.key} 滚动后');
        }
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 1));
        session.dispose();
      });
    }
  }
  testWidgets('替换 Future 时保留已有列表，失败前不闪空白', (tester) async {
    final next = Completer<List<String>>();
    Widget view(Future<List<String>> future) => MaterialApp(
          theme: WoTheme.dark(),
          home: AsyncView<List<String>>(
            future: future,
            builder: (_, items) => Text(items.join(',')),
          ),
        );
    await tester.pumpWidget(view(Future.value(['旧数据'])));
    await tester.pump();
    await tester.pumpWidget(view(next.future));
    expect(find.text('旧数据'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    next.complete(['新数据']);
    await tester.pump();
    expect(find.text('新数据'), findsOneWidget);
  });
  test('深浅外观正文、次要文案、按钮前景达到正常文字对比度', () {
    double contrast(Color a, Color b) {
      final x = a.computeLuminance(), y = b.computeLuminance();
      return (x > y ? x + .05 : y + .05) / (x > y ? y + .05 : x + .05);
    }

    for (final theme in [WoTheme.dark(), WoTheme.light()]) {
      final wo = theme.extension<WoColors>()!;
      for (final fg in [wo.fg, wo.fgMid, wo.fgDim]) {
        expect(contrast(fg, wo.bg), greaterThanOrEqualTo(4.5));
        expect(contrast(fg, wo.bgElev), greaterThanOrEqualTo(4.5));
      }
      expect(
        contrast(theme.colorScheme.primary, theme.colorScheme.onPrimary),
        greaterThanOrEqualTo(4.5),
      );
    }
  });
}
