import 'package:flutter/material.dart';

/// Widget for driver status controls (Online/Offline toggle)
class DriverStatusControls extends StatelessWidget {
  final bool isActive;
  final bool isLoading;
  final VoidCallback onGoOnline;
  final VoidCallback onGoOffline;

  const DriverStatusControls({
    super.key,
    required this.isActive,
    required this.isLoading,
    required this.onGoOnline,
    required this.onGoOffline,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isActive ? Colors.green[50] : Colors.red[50],
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isActive ? Colors.green[200]! : Colors.red[200]!,
        ),
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.circle,
                color: isActive ? Colors.green : Colors.red,
                size: 16,
              ),
              const SizedBox(width: 8),
              Text(
                isActive ? 'Online - Available for rides' : 'Offline',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: isActive ? Colors.green[800] : Colors.red[800],
                  fontSize: 16,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: isLoading ? null : onGoOnline,
                  icon: Icon(
                    Icons.circle,
                    color: isLoading ? Colors.grey : Colors.green,
                    size: 18,
                  ),
                  label: Text(isLoading ? 'Updating...' : 'Go Online'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: isActive ? Colors.green[100] : null,
                    foregroundColor: isActive ? Colors.green[800] : null,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: isLoading ? null : onGoOffline,
                  icon: Icon(
                    Icons.circle,
                    color: isLoading ? Colors.grey : Colors.red,
                    size: 18,
                  ),
                  label: Text(isLoading ? 'Updating...' : 'Go Offline'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: !isActive ? Colors.red[100] : null,
                    foregroundColor: !isActive ? Colors.red[800] : null,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
