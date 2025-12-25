import 'dart:core';
import '../config/constants.dart';

/// Build a WebSocket `Uri` from the configured `kBaseUrl`.
///
/// `path` should be the websocket path (e.g. '/ws/app/').
Uri buildWsUri(
  String path, {
  Map<String, String>? queryParams,
  int? overridePort,
}) {
  final parsed = Uri.parse(kBaseUrl);
  final wsScheme = (parsed.scheme == 'https') ? 'wss' : 'ws';

  return Uri(
    scheme: wsScheme,
    host: parsed.host,
    port: overridePort ?? (parsed.hasPort ? parsed.port : null),
    path: path.startsWith('/') ? path : '/$path',
    queryParameters: queryParams,
  );
}
