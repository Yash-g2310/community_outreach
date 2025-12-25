import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import '../../config/api_endpoints.dart';
import '../../services/logger_service.dart';
import '../../services/error_service.dart';

class PreviousRidesPage extends StatefulWidget {
  final String jwtToken;
  final bool isDriver; // Required (Must be provided by caller)

  const PreviousRidesPage({
    super.key,
    required this.jwtToken,
    required this.isDriver,
  });

  @override
  State<PreviousRidesPage> createState() => _PreviousRidesPageState();
}

class _PreviousRidesPageState extends State<PreviousRidesPage> {
  List<Map<String, dynamic>> previousRides = [];
  bool isLoading = true;
  late bool isDriver; // true = driver, false = passenger
  final ErrorService _errorService = ErrorService();

  @override
  void initState() {
    super.initState();
    isDriver = widget.isDriver;
    _fetchPreviousRides();
  }

  Future<void> _fetchPreviousRides() async {
    final endpoint = widget.isDriver
        ? DriverEndpoints.history
        : PassengerEndpoints.history;

    try {
      final res = await http.get(
        Uri.parse(endpoint),
        headers: {
          'Authorization': 'Bearer ${widget.jwtToken}',
          'Content-Type': 'application/json',
        },
      );

      if (res.statusCode == 200) {
        final data = json.decode(res.body);
        setState(() {
          isDriver = widget.isDriver;
          previousRides = List<Map<String, dynamic>>.from(data['rides'] ?? []);
          isLoading = false;
        });
      } else {
        final lastError = '${res.statusCode} ${res.body}';
        Logger.error(
          'PreviousRides: $endpoint -> $lastError',
          tag: 'PreviousRides',
        );
        setState(() => isLoading = false);
        if (mounted) {
          _errorService.showError(
            context,
            'Failed to load previous rides: $lastError',
          );
        }
      }
    } catch (e) {
      Logger.error(
        'PreviousRides: exception: $e',
        tag: 'PreviousRides',
      );
      setState(() => isLoading = false);
      if (mounted) {
        _errorService.showError(context, 'Failed to load previous rides: $e');
      }
    }
  }

  void _showRideDetailsDialog(Map<String, dynamic> ride) {
    showDialog(
      context: context,
      builder: (context) {
        String? formatTime(dynamic t) =>
            (t == null || t == "") ? '-' : t.toString();

        bool isCancelled = ride['cancelled_at'] != null;

        return AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          title: const Text(
            'Ride Details',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _infoRow('Pickup Address', ride['pickup_address']),
                _infoRow('Dropoff Address', ride['dropoff_address']),
                _infoRow('Requested At', formatTime(ride['requested_at'])),
                _infoRow('Accepted At', formatTime(ride['accepted_at'])),
                _infoRow('Started At', formatTime(ride['started_at'])),
                _infoRow('Completed At', formatTime(ride['completed_at'])),
                _infoRow('Cancelled At', formatTime(ride['cancelled_at'])),
                if (isCancelled && ride['cancellation_reason'] != "")
                  _infoRow('Cancellation Reason', ride['cancellation_reason']),
                const SizedBox(height: 8),
                // Show other party info depending on detected role
                if (isDriver == true) ...[
                  _infoRow('Passenger', ride['passenger']?['username'] ?? '-'),
                  _infoRow(
                    'Passenger Phone',
                    ride['passenger']?['phone_number'] ?? '-',
                  ),
                ] else ...[
                  _infoRow('Driver', ride['driver']?['username'] ?? '-'),
                  _infoRow(
                    'Driver Phone',
                    ride['driver']?['phone_number'] ?? '-',
                  ),
                  _infoRow('Vehicle', ride['driver']?['vehicle_number'] ?? '-'),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close', style: TextStyle(color: Colors.blue)),
            ),
          ],
        );
      },
    );
  }

  Widget _infoRow(String title, dynamic value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 3,
            child: Text(
              '$title:',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          Expanded(
            flex: 5,
            child: Text(
              value?.toString() ?? '-',
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Previous Rides'),
        backgroundColor: Colors.teal,
      ),
      body: isLoading
          ? const Center(child: CircularProgressIndicator())
          : previousRides.isEmpty
          ? const Center(child: Text('No previous rides found'))
          : ListView.builder(
              itemCount: previousRides.length,
              itemBuilder: (context, index) {
                final ride = previousRides[index];
                return GestureDetector(
                  onTap: () => _showRideDetailsDialog(ride),
                  child: Card(
                    margin: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(15),
                    ),
                    elevation: 4,
                    child: ListTile(
                      leading: const Icon(Icons.local_taxi, color: Colors.teal),
                      title: Text(
                        'Pickup: ${ride['pickup_address'] ?? '-'}',
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      subtitle: Text(() {
                        final status = ride['status'] ?? '-';
                        final requested = ride['requested_at'] ?? '';
                        if (isDriver == true) {
                          final passenger =
                              ride['passenger']?['username'] ?? '-';
                          return 'Status: $status\nPassenger: $passenger\nRequested: $requested';
                        } else {
                          final driver = ride['driver']?['username'] ?? '-';
                          final vehicle =
                              ride['driver']?['vehicle_number'] ?? '-';
                          return 'Status: $status\nDriver: $driver ($vehicle)\nRequested: $requested';
                        }
                      }(), maxLines: 3),
                      trailing: const Icon(
                        Icons.arrow_forward_ios_rounded,
                        size: 18,
                      ),
                    ),
                  ),
                );
              },
            ),
    );
  }
}
