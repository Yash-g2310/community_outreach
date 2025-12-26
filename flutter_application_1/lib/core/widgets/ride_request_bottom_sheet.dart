import 'package:flutter/material.dart';
import '../../router/app_router.dart';

/// Bottom sheet widget for displaying ride request details
class RideRequestBottomSheet extends StatelessWidget {
  final Map<String, dynamic> notification;
  final bool isLoading;
  final VoidCallback onAccept;
  final VoidCallback onReject;

  const RideRequestBottomSheet({
    super.key,
    required this.notification,
    required this.isLoading,
    required this.onAccept,
    required this.onReject,
  });

  Widget _buildDetailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 80,
            child: Text(
              label,
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            "Ride Request",
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 16),

          // Ride details
          _buildDetailRow(
            "Passenger:",
            notification['passenger_name'] ?? 'Unknown',
          ),
          _buildDetailRow("Phone:", notification['passenger_phone'] ?? ''),
          _buildDetailRow("Pickup:", notification['start']),
          _buildDetailRow("Drop-off:", notification['end']),
          _buildDetailRow("Passengers:", "${notification['people']}"),
          _buildDetailRow("Distance:", "${notification['distance']}m away"),

          const SizedBox(height: 24),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              // Accept button
              ElevatedButton.icon(
                onPressed: isLoading
                    ? null
                    : () {
                        AppRouter.pop(context);
                        onAccept();
                      },
                icon: const Icon(Icons.check_circle, color: Colors.white),
                label: const Text("Accept"),
                style: ElevatedButton.styleFrom(backgroundColor: Colors.green),
              ),
              // Reject button
              ElevatedButton.icon(
                onPressed: isLoading
                    ? null
                    : () {
                        AppRouter.pop(context);
                        onReject();
                      },
                icon: const Icon(Icons.cancel, color: Colors.white),
                label: const Text("Decline"),
                style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
              ),
            ],
          ),
          const SizedBox(height: 10),
        ],
      ),
    );
  }

  /// Show the bottom sheet
  static void show(
    BuildContext context, {
    required Map<String, dynamic> notification,
    required bool isLoading,
    required VoidCallback onAccept,
    required VoidCallback onReject,
  }) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => RideRequestBottomSheet(
        notification: notification,
        isLoading: isLoading,
        onAccept: onAccept,
        onReject: onReject,
      ),
    );
  }
}
