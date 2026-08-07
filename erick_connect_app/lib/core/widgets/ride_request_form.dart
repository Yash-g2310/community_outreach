import 'package:flutter/material.dart';

/// Reusable form widget for creating ride requests
class RideRequestForm extends StatelessWidget {
  final TextEditingController pickupController;
  final TextEditingController dropController;
  final TextEditingController passengerController;
  final VoidCallback onSubmit;
  final bool isLoading;
  final bool enabled;

  const RideRequestForm({
    super.key,
    required this.pickupController,
    required this.dropController,
    required this.passengerController,
    required this.onSubmit,
    this.isLoading = false,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        TextField(
          controller: pickupController,
          enabled: enabled && !isLoading,
          decoration: const InputDecoration(
            labelText: 'Pickup Location',
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.location_on, color: Colors.green),
            contentPadding: EdgeInsets.symmetric(vertical: 12, horizontal: 12),
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: dropController,
          enabled: enabled && !isLoading,
          decoration: const InputDecoration(
            labelText: 'Drop Location',
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.location_on, color: Colors.red),
            contentPadding: EdgeInsets.symmetric(vertical: 12, horizontal: 12),
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: passengerController,
          enabled: enabled && !isLoading,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: 'Number of Passengers',
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.group, color: Colors.blue),
            contentPadding: EdgeInsets.symmetric(vertical: 12, horizontal: 12),
          ),
        ),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          height: 48,
          child: ElevatedButton.icon(
            onPressed: (enabled && !isLoading) ? onSubmit : null,
            icon: isLoading
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                    ),
                  )
                : const Icon(Icons.notification_important),
            label: Text(
              isLoading ? 'Creating Request...' : 'Alert Nearby E-Rickshaw',
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: isLoading ? Colors.grey : null,
            ),
          ),
        ),
        const SizedBox(height: 16), // Extra padding at bottom
      ],
    );
  }
}
