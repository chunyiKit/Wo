"""植物天气显式入口源码检查；不执行Dart，不证明UI或平台权限运行正常。"""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]

class LocalPlantWeatherUiContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = (ROOT / 'lib/features/plugins/plant/plant_list_page.dart').read_text()
        cls.card = cls.source.split('class _WeatherCardState ', 1)[1]
        cls.action = cls.card.split('Future<void> _fetchCurrentWeather()', 1)[1].split('@override', 1)[0]

    def test_initialization_and_reload_do_not_request_location(self):
        initial = self.card.split('void didChangeDependencies()', 1)[1].split('// 只有这个按钮', 1)[0]
        self.assertIn('_reload();', initial)
        self.assertIn('session.api.plantWeather(fid)', initial)
        for forbidden in ('weatherForUserAction', 'getCurrentLocation', 'updatePlantSettings', 'WeatherClient'):
            self.assertNotIn(forbidden, initial)

    def test_explicit_button_is_only_typed_weather_call_site(self):
        self.assertEqual(self.source.count('.plants.weatherForUserAction('), 1)
        self.assertIn('await runtime.plants.weatherForUserAction(fid)', self.action)
        self.assertIn('if (!session.api.isLocal) return;', self.action)
        self.assertIn('if (_requesting) return;', self.action)
        self.assertIn("'获取当前位置天气'", self.card)
        self.assertIn(': _fetchCurrentWeather,', self.card)
        self.assertIn('if (local) ...[', self.card)

    def test_late_result_is_guarded_by_widget_family_and_auth(self):
        for guard in ('!mounted', 'epoch != _requestEpoch', '!session.isCurrentAuth(auth)', 'session.currentFamilyId != fid'):
            self.assertIn(guard, self.action)
        self.assertLess(self.action.index('epoch != _requestEpoch'), self.action.index('_future = Future.value(result)'))
        self.assertIn('fid != _familyId', self.card)

    def test_action_does_not_persist_and_removes_coordinates_from_state(self):
        for forbidden in ('updatePlantSettings(', 'setPrivate(', 'store.patch(', 'store.batch(', 'SharedPreferences', 'getCurrentLocation('):
            self.assertNotIn(forbidden, self.action)
        self.assertIn("..remove('latitude')", self.action)
        self.assertIn("..remove('longitude')", self.action)
        self.assertIn('PlantWeather.fromJson(display)', self.action)
        self.assertIn("'仅查询本次天气，不修改默认环境'", self.card)

    def test_legacy_default_location_cannot_persist_a_local_gps_fix(self):
        method = self.source.split('Future<void> _useDeviceLocation()', 1)[1].split('@override', 1)[0]
        self.assertLess(method.index('if (WoScope.api(context).isLocal) return;'), method.index('getCurrentLocation()'))
        self.assertLess(method.index('if (WoScope.api(context).isLocal) return;'), method.index('updatePlantSettings('))
        self.assertIn('if (!local)\n            WoFilledButton.icon(', self.source)

    def test_remote_refresh_and_weather_layout_remain(self):
        self.assertIn('if (!WoScope.api(context).isLocal)\n              WoIconButton(', self.card)
        self.assertIn('onPressed: _reload,', self.card)
        self.assertIn('return _buildWeather(context, w);', self.card)
        self.assertIn("if (w.uvIndex != null) ('紫外线'", self.card)
        self.assertIn('if (w.humidityPct != null)', self.card)
        self.assertIn('if (w.visibilityKm != null)', self.card)

    def test_plant_grid_keeps_silent_refresh(self):
        self.assertIn('Future<void> _refreshSilently()', self.source)
        self.assertIn('_items != null', self.source)
        self.assertNotIn('_future = _fetch()', self.action)

if __name__ == '__main__':
    unittest.main()
