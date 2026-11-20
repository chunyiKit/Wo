typedef LocalResult = ({dynamic data, Map<String, dynamic>? meta});

abstract interface class LocalBackend {
  String get mediaBaseUrl;
  Map<String, String> get mediaHeaders;
  Future<LocalResult> request(String method, String path, {
    Object? body, Map<String, dynamic>? query,
    List<(List<int>, String)>? files, Map<String, String>? fields,
  });
}
