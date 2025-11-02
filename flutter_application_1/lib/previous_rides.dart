import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';

class PreviousRidesPage extends StatefulWidget {
  final String jwtToken;
  const PreviousRidesPage({super.key, required this.jwtToken});

  @override
  State<PreviousRidesPage> createState() => _PreviousRidesPageState();
}

class _PreviousRidesPageState extends State<PreviousRidesPage> {
  List<Map<String, dynamic>> previousRides = [];
  bool isLoading = true;
  bool? isDriver; // true = driver, false = passenger

  @override
  void initState() {
    super.initState();
    _fetchPreviousRides();
  }

  Future<void> _fetchPreviousRides() async {
    // Try common host variants so emulator/device differences are handled
    final hosts = ['http://127.0.0.1:8000', 'http://10.0.2.2:8000', 'http://localhost:8000'];
    bool loaded = false;
    String lastError = '';

    for (final base in hosts) {
      final driverUrl = '$base/api/rides/driver/history';
      final passengerUrl = '$base/api/rides/passenger/history';

      try {
        // Try driver history first
        final resDriver = await http.get(
          Uri.parse(driverUrl),
          headers: {
            'Authorization': 'Bearer ${widget.jwtToken}',
            'Content-Type': 'application/json',
          },
        );
        print('PreviousRides: tried $driverUrl -> ${resDriver.statusCode}');
        if (resDriver.statusCode == 200) {
          final data = json.decode(resDriver.body);
          setState(() {
            isDriver = true;
            previousRides = List<Map<String, dynamic>>.from(data['rides'] ?? []);
            isLoading = false;
          });
          loaded = true;
          break;
        } else {
          lastError = 'driver:${resDriver.statusCode} ${resDriver.body}';
        }

        // Try passenger history
        final resPassenger = await http.get(
          Uri.parse(passengerUrl),
          headers: {
            'Authorization': 'Bearer ${widget.jwtToken}',
            'Content-Type': 'application/json',
          },
        );
        print('PreviousRides: tried $passengerUrl -> ${resPassenger.statusCode}');
        if (resPassenger.statusCode == 200) {
          final data = json.decode(resPassenger.body);
          setState(() {
            isDriver = false;
            previousRides = List<Map<String, dynamic>>.from(data['rides'] ?? []);
            isLoading = false;
          });
          loaded = true;
          break;
        } else {
          lastError = 'passenger:${resPassenger.statusCode} ${resPassenger.body}';
        }
      } catch (e) {
        print('PreviousRides: host $base exception: $e');
        lastError = e.toString();
        // continue to next host
      }
    }

    if (!loaded) {
      print('PreviousRides: all hosts failed. lastError=$lastError');
      setState(() {
        isLoading = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to load previous rides: $lastError')),
        );
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
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: const Text('Ride Details', style: TextStyle(fontWeight: FontWeight.bold)),
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
                  _infoRow('Passenger Phone', ride['passenger']?['phone_number'] ?? '-'),
                ] else ...[
                  _infoRow('Driver', ride['driver']?['username'] ?? '-'),
                  _infoRow('Driver Phone', ride['driver']?['phone_number'] ?? '-'),
                  _infoRow('Vehicle', ride['driver']?['vehicle_number'] ?? '-'),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close', style: TextStyle(color: Colors.blue)),
            )
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
          Expanded(flex: 3, child: Text('$title:', style: const TextStyle(fontWeight: FontWeight.w600))),
          Expanded(flex: 5, child: Text(value?.toString() ?? '-', overflow: TextOverflow.ellipsis)),
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
                        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
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
                          subtitle: Text(
                            () {
                              final status = ride['status'] ?? '-';
                              final requested = ride['requested_at'] ?? '';
                              if (isDriver == true) {
                                final passenger = ride['passenger']?['username'] ?? '-';
                                return 'Status: $status\nPassenger: $passenger\nRequested: $requested';
                              } else {
                                final driver = ride['driver']?['username'] ?? '-';
                                final vehicle = ride['driver']?['vehicle_number'] ?? '-';
                                return 'Status: $status\nDriver: $driver ($vehicle)\nRequested: $requested';
                              }
                            }(),
                            maxLines: 3,
                          ),
                          trailing: const Icon(Icons.arrow_forward_ios_rounded, size: 18),
                        ),
                      ),
                    );
                  },
                ),
    );
  }
}

void main() {
  runApp(const MaterialApp(
    debugShowCheckedModeBanner: false,
    home: PreviousRidesPage(jwtToken: 'dummy_token'),
  ));
}
