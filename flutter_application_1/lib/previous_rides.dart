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

  @override
  void initState() {
    super.initState();
    _fetchPreviousRides();
  }

  Future<void> _fetchPreviousRides() async {
    const url = 'http://127.0.0.1:8000/api/rides/driver/previous-rides/';
    try {
      final res = await http.get(
        Uri.parse(url),
        headers: {
          'Authorization': 'Bearer ${widget.jwtToken}',
          'Content-Type': 'application/json',
        },
      );

      if (res.statusCode == 200) {
        final data = json.decode(res.body);
        setState(() {
          previousRides = List<Map<String, dynamic>>.from(data['rides'] ?? []);
          isLoading = false;
        });
      } else {
        setState(() {
          isLoading = false;
        });
        throw Exception('Failed to load rides: ${res.statusCode}');
      }
    } catch (e) {
      print('Error fetching rides: $e');
      setState(() {
        isLoading = false;
      });
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
                          subtitle: Text('Dropoff: ${ride['dropoff_address'] ?? '-'}'),
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
