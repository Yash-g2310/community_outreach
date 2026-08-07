import 'package:web_socket_channel/web_socket_channel.dart';

import 'socket_channel_stub.dart'
    if (dart.library.html) 'socket_channel_html.dart'
    if (dart.library.io) 'socket_channel_io.dart';

WebSocketChannel createPlatformWebSocket(
  Uri uri, {
  Map<String, dynamic>? headers,
}) {
  return createPlatformWebSocketImpl(uri, headers: headers);
}
