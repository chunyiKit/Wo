// dart [-DWO_API_BASE_URL=...] tool/tests/api_config_test.dart valid|invalid
import '../../lib/data/api_config.dart';

void main(List<String> args) {
  final expectedValid = args.single == 'valid';
  var valid = true;
  try {
    ApiConfig.validate();
  } on StateError {
    valid = false;
  }
  if (valid != expectedValid) {
    throw StateError('API 地址配置校验结果与预期不符');
  }
  if (valid && ApiConfig.baseUrl.endsWith('/')) {
    throw StateError('API 根地址不应保留末尾斜杠');
  }
}
