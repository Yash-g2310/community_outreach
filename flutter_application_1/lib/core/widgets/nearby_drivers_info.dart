import 'package:flutter/material.dart';

/// Widget displaying information about nearby drivers
class NearbyDriversInfo extends StatelessWidget {
  final List<Map<String, dynamic>> nearbyDrivers;
  final bool isLoading;

  const NearbyDriversInfo({
    super.key,
    required this.nearbyDrivers,
    this.isLoading = false,
  });

  @override
  Widget build(BuildContext context) {
    if (nearbyDrivers.isEmpty) {
      return const SizedBox.shrink();
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.green[50],
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.green[200]!),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.local_taxi, color: Colors.green, size: 18),
              const SizedBox(width: 6),
              Text(
                '${nearbyDrivers.length} E-Rickshaw${nearbyDrivers.length > 1 ? 's' : ''} Nearby',
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  color: Colors.green,
                  fontSize: 14,
                ),
              ),
              const Spacer(),
              if (isLoading) ...[
                const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.5,
                    valueColor: AlwaysStoppedAnimation<Color>(Colors.green),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 6),
          ...nearbyDrivers
              .take(2)
              .map(
                (driver) => Padding(
                  padding: const EdgeInsets.only(bottom: 3),
                  child: Text(
                    '${driver['username']} (${driver['vehicle_number']})',
                    style: const TextStyle(fontSize: 11),
                  ),
                ),
              )
              .toList(),
          if (nearbyDrivers.length > 2)
            Text(
              'and ${nearbyDrivers.length - 2} more...',
              style: const TextStyle(fontSize: 11, fontStyle: FontStyle.italic),
            ),
        ],
      ),
    );
  }
}
