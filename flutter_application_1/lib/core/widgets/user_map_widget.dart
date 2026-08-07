import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_cancellable_tile_provider/flutter_map_cancellable_tile_provider.dart';
import 'package:latlong2/latlong.dart';

/// Reusable map widget for user page showing current location and nearby drivers
class UserMapWidget extends StatelessWidget {
  final LatLng currentPosition;
  final List<Map<String, dynamic>> nearbyDrivers;
  final double height;

  const UserMapWidget({
    super.key,
    required this.currentPosition,
    required this.nearbyDrivers,
    this.height = 0.5, // Default to 50% of screen height
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: MediaQuery.of(context).size.height * height,
      child: FlutterMap(
        options: MapOptions(initialCenter: currentPosition, initialZoom: 16),
        children: [
          TileLayer(
            urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
            userAgentPackageName: 'com.example.demo_apk',
            tileProvider: kIsWeb
                ? CancellableNetworkTileProvider()
                : NetworkTileProvider(),
          ),
          MarkerLayer(
            markers: [
              // User's current location marker
              Marker(
                point: currentPosition,
                width: 60,
                height: 60,
                child: const Icon(
                  Icons.location_pin,
                  color: Colors.red,
                  size: 40,
                ),
              ),
              // Nearby-driver pins are anonymous until one accepts the ride.
              ...nearbyDrivers.map((driver) {
                return Marker(
                  point: LatLng(
                    driver['latitude'].toDouble(),
                    driver['longitude'].toDouble(),
                  ),
                  width: 48,
                  height: 48,
                  child: const Icon(
                    Icons.local_taxi,
                    color: Colors.green,
                    size: 30,
                  ),
                );
              }),
            ],
          ),
        ],
      ),
    );
  }
}
