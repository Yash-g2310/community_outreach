import 'package:web_socket_channel/web_socket_channel.dart';

WebSocketChannel createPlatformWebSocketImpl(
  Uri uri, {
  Map<String, dynamic>? headers,
}) {
  throw UnsupportedError(
    'WebSocket connections are not supported on this platform.',
  );
}
