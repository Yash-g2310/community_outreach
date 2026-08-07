import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/html.dart';

WebSocketChannel createPlatformWebSocketImpl(
  Uri uri, {
  Map<String, dynamic>? headers,
  Duration? pingInterval,
}) {
  // Browsers do not expose protocol ping frames to JavaScript. They still
  // respond to server-originated WebSocket pings automatically.
  return HtmlWebSocketChannel.connect(uri.toString());
}
