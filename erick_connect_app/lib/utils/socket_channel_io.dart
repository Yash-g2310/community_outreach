import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/io.dart';

WebSocketChannel createPlatformWebSocketImpl(
  Uri uri, {
  Map<String, dynamic>? headers,
}) {
  return IOWebSocketChannel.connect(uri, headers: headers);
}
