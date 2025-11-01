import 'package:flutter/material.dart';
import 'profile.dart';
// If you plan to show a map, later add:
// import 'package:google_maps_flutter/google_maps_flutter.dart';

void main() {
  runApp(const ERickDriverApp());
}

class ERickDriverApp extends StatelessWidget {
  const ERickDriverApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: DriverPage(),
    );
  }
}

class DriverPage extends StatefulWidget {
  const DriverPage({super.key});

  @override
  State<DriverPage> createState() => _DriverPageState();
}

class _DriverPageState extends State<DriverPage> {
  bool isActive = true;

  List<Map<String, dynamic>> notifications = [
    {'id': 1, 'start': 'Sector 12, Noida', 'end': 'Atta Market', 'people': 2},
    {'id': 2, 'start': 'Kailash Colony', 'end': 'Lajpat Nagar', 'people': 3},
    {'id': 3, 'start': 'Rajiv Chowk', 'end': 'Connaught Place', 'people': 1},
    {'id': 4, 'start': 'Vaishali', 'end': 'Indirapuram', 'people': 4},
  ];

  void _showBottomSheet(Map<String, dynamic> notif) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
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
              Text("Start Location: ${notif['start']}"),
              Text("End Location: ${notif['end']}"),
              Text("No. of People: ${notif['people']}"),
              const SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  // Accept → navigate to assignment page with data
                  ElevatedButton.icon(
                    onPressed: () {
                      Navigator.pop(context);
                      // TODO: Call your backend accept API first; if success, navigate.
                      // For now, directly navigate to assignment page
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => DriverAssignmentPage(
                            requestId: notif['id'] as int,
                            pickupLabel: notif['start'] as String,
                            dropLabel: notif['end'] as String,
                            pax: notif['people'] as int,
                          ),
                        ),
                      );
                    },
                    icon: const Icon(Icons.check_circle, color: Colors.white),
                    label: const Text("Accept"),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.green,
                    ),
                  ),
                  ElevatedButton.icon(
                    onPressed: () {
                      setState(() {
                        notifications.removeWhere(
                          (element) => element['id'] == notif['id'],
                        );
                      });
                      Navigator.pop(context);
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text("Ride Declined ❌"),
                          duration: Duration(seconds: 2),
                        ),
                      );
                    },
                    icon: const Icon(Icons.cancel, color: Colors.white),
                    label: const Text("Decline"),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.red,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey[300],
      body: SafeArea(
        child: Column(
          children: [
            // Header
            Container(
              color: Colors.cyan,
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  // Logout button
                  IconButton(
                    onPressed: () {
                      print('=== NAVIGATION ===');
                      print('Logging out from Driver Dashboard');
                      print('==================');

                      // Show confirmation dialog
                      showDialog(
                        context: context,
                        builder: (context) => AlertDialog(
                          title: const Text('Logout'),
                          content: const Text(
                            'Are you sure you want to logout?',
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(context),
                              child: const Text('Cancel'),
                            ),
                            TextButton(
                              onPressed: () {
                                Navigator.pop(context); // Close dialog
                                // Navigate back to start page and clear all previous routes
                                Navigator.pushNamedAndRemoveUntil(
                                  context,
                                  '/',
                                  (route) => false,
                                );
                              },
                              child: const Text('Logout'),
                            ),
                          ],
                        ),
                      );
                    },
                    icon: const Icon(Icons.logout, color: Colors.white),
                  ),
                  // Title
                  const Expanded(
                    child: Text(
                      'E Rick Driver',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.black,
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  // Settings/Profile button
                  IconButton(
                    onPressed: () {
                      print('=== NAVIGATION ===');
                      print('Navigating from Driver Dashboard to Profile');
                      print('==================');

                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => const ProfilePage(),
                        ),
                      );
                    },
                    icon: const Icon(Icons.person, color: Colors.white),
                  ),
                ],
              ),
            ),

            // Driver info + photo
            Container(
              color: Colors.black,
              padding: const EdgeInsets.all(16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Expanded(
                    child: Text(
                      'Other details of the driver',
                      style: TextStyle(color: Colors.white, fontSize: 16),
                    ),
                  ),
                  Container(
                    color: Colors.orange,
                    width: 100,
                    height: 80,
                    child: const Center(
                      child: Text(
                        'Photo\nof\ndriver',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.white),
                      ),
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 10),

            // Active / Inactive buttons
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                ElevatedButton.icon(
                  onPressed: () => setState(() => isActive = true),
                  icon: const Icon(Icons.circle, color: Colors.green),
                  label: const Text('Active'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: isActive
                        ? Colors.green[100]
                        : Colors.grey[200],
                  ),
                ),
                const SizedBox(width: 10),
                ElevatedButton.icon(
                  onPressed: () => setState(() => isActive = false),
                  icon: const Icon(Icons.circle, color: Colors.red),
                  label: const Text('Inactive'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: !isActive
                        ? Colors.red[100]
                        : Colors.grey[200],
                  ),
                ),
              ],
            ),

            const SizedBox(height: 10),

            // Notifications Header
            Container(
              width: double.infinity,
              color: Colors.blue[900],
              padding: const EdgeInsets.all(12),
              child: const Text(
                'Notifications',
                style: TextStyle(color: Colors.white, fontSize: 18),
                textAlign: TextAlign.center,
              ),
            ),

            // Scrollable Notifications List
            Expanded(
              child: isActive
                  ? notifications.isNotEmpty
                        ? ListView.builder(
                            itemCount: notifications.length,
                            itemBuilder: (context, index) {
                              final notif = notifications[index];
                              return GestureDetector(
                                onTap: () => _showBottomSheet(notif),
                                child: Card(
                                  margin: const EdgeInsets.symmetric(
                                    horizontal: 16,
                                    vertical: 8,
                                  ),
                                  color: Colors.grey[400],
                                  child: Padding(
                                    padding: const EdgeInsets.all(12.0),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          'Start: ${notif['start']}',
                                          style: const TextStyle(
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                        Text('End: ${notif['end']}'),
                                        Text('People: ${notif['people']}'),
                                      ],
                                    ),
                                  ),
                                ),
                              );
                            },
                          )
                        : const Center(
                            child: Text(
                              'No new notifications',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          )
                  : const Center(
                      child: Text(
                        'Notifications are hidden (Inactive)',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

// NEW SCREEN: shows assignment and will host live map/location
class DriverAssignmentPage extends StatefulWidget {
  final int requestId;
  final String pickupLabel;
  final String dropLabel;
  final int pax;

  const DriverAssignmentPage({
    super.key,
    required this.requestId,
    required this.pickupLabel,
    required this.dropLabel,
    required this.pax,
  });

  @override
  State<DriverAssignmentPage> createState() => _DriverAssignmentPageState();
}

class _DriverAssignmentPageState extends State<DriverAssignmentPage> {
  // TODO: Add GoogleMap controller and live stream subscription here.
  // Example placeholders:
  // GoogleMapController? _mapCtrl;
  // StreamSubscription? _locationSub;

  @override
  void initState() {
    super.initState();
    // TODO: Subscribe to backend stream with widget.requestId to receive rider location updates.
    // Example with Firebase/WS: _locationSub = riderLocationStream(widget.requestId).listen((pos){ setState(...); });
  }

  @override
  void dispose() {
    // _locationSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Assigned Ride')),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header/summary card
          Container(
            color: Colors.blueGrey[50],
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Request #${widget.requestId}',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 6),
                Text('Pickup: ${widget.pickupLabel}'),
                Text('Drop: ${widget.dropLabel}'),
                Text('People: ${widget.pax}'),
              ],
            ),
          ),

          // Map placeholder; replace with GoogleMap later
          Expanded(
            child: Container(
              color: Colors.grey[200],
              alignment: Alignment.center,
              child: const Text(
                'Map goes here (driver + rider live markers)',
                textAlign: TextAlign.center,
              ),
            ),
          ),

          // Actions
          Padding(
            padding: const EdgeInsets.all(12.0),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () {
                      // Arrived → could notify backend
                    },
                    child: const Text('Arrived'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ElevatedButton(
                    onPressed: () {
                      // Start trip → switch to drop routing, notify backend
                    },
                    child: const Text('Start Trip'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ElevatedButton(
                    onPressed: () {
                      // Complete trip → pop back to home
                      Navigator.pop(context);
                    },
                    child: const Text('Complete'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
