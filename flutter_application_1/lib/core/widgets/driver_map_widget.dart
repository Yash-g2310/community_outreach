import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_cancellable_tile_provider/flutter_map_cancellable_tile_provider.dart';
import 'package:latlong2/latlong.dart';

/// Reusable map widget for driver page showing driver's current location
class DriverMapWidget extends StatelessWidget {
  final LatLng currentPosition;
  final double height;

  const DriverMapWidget({
    super.key,
    required this.currentPosition,
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
            userAgentPackageName: 'com.example.erick_driver',
            tileProvider: kIsWeb
                ? CancellableNetworkTileProvider()
                : NetworkTileProvider(),
          ),
          MarkerLayer(
            markers: [
              // Driver's current location marker
              Marker(
                point: currentPosition,
                width: 80,
                height: 80,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 4,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.blue,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: const Text(
                        'You',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    const Icon(Icons.local_taxi, color: Colors.blue, size: 35),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
