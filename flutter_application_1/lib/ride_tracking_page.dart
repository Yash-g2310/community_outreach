import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'dart:async';

class RideTrackingPage extends StatefulWidget {
  final int rideId;
  final String pickupAddress;
  final String dropoffAddress;
  final int numberOfPassengers;
  final String? passengerName;
  final String? passengerPhone;
  final String? driverName;
  final String? driverPhone;
  final String? vehicleNumber;
  final double? pickupLat;
  final double? pickupLng;
  final double? dropoffLat;
  final double? dropoffLng;
  final String? accessToken;
  final bool isDriver; // true if current user is driver, false if passenger

  const RideTrackingPage({
    super.key,
    required this.rideId,
    required this.pickupAddress,
    required this.dropoffAddress,
    required this.numberOfPassengers,
    this.passengerName,
    this.passengerPhone,
    this.driverName,
    this.driverPhone,
    this.vehicleNumber,
    this.pickupLat,
    this.pickupLng,
    this.dropoffLat,
    this.dropoffLng,
    this.accessToken,
    required this.isDriver,
  });

  @override
  State<RideTrackingPage> createState() => _RideTrackingPageState();
}

class _RideTrackingPageState extends State<RideTrackingPage> {
  LatLng? _currentPosition;
  String _rideStatus = 'accepted';
  bool _isLoading = false;
  Timer? _locationTimer;

  // API Configuration
  static const String baseUrl = 'http://localhost:8000';

  @override
  void initState() {
    super.initState();
    _initializeTracking();
  }

  @override
  void dispose() {
    _locationTimer?.cancel();
    super.dispose();
  }

  Future<void> _initializeTracking() async {
    await _getCurrentLocation();
    _startLocationUpdates();
  }

  Future<void> _getCurrentLocation() async {
    try {
      Position position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );

      setState(() {
        _currentPosition = LatLng(position.latitude, position.longitude);
      });
    } catch (e) {
      print('Error getting current location: $e');
    }
  }

  void _startLocationUpdates() {
    _locationTimer = Timer.periodic(const Duration(seconds: 10), (timer) {
      _getCurrentLocation();
      // Here you could also fetch ride status updates from backend
    });
  }

  Future<void> _completeRide() async {
    if (widget.accessToken == null) return;

    setState(() {
      _isLoading = true;
    });

    try {
      final response = await http.post(
        Uri.parse('$baseUrl/api/rides/handle/${widget.rideId}/complete/'),
        headers: {
          'Authorization': 'Bearer ${widget.accessToken}',
          'Content-Type': 'application/json',
        },
      );

      if (!mounted) return;

      if (response.statusCode == 200) {
        setState(() {
          _rideStatus = 'completed';
        });

        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Ride completed successfully! ✅'),
            backgroundColor: Colors.green,
          ),
        );

        // Navigate back after a short delay
        Future.delayed(const Duration(seconds: 2), () {
          if (mounted) {
            debugPrint('🟠 Ride completed — returning to previous page...');
            Navigator.pop(context); // ✅ Just go back one page
          }
        });
      } else {
        throw Exception('Failed to complete ride: ${response.statusCode}');
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error completing ride: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _cancelRide() async {
    if (widget.accessToken == null) return;

    // Ask user for confirmation
    final shouldCancel = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Cancel Ride'),
        content: const Text('Are you sure you want to cancel this ride?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('No'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Yes', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (!mounted) return;

    // If the user chooses "No", stay on the same page
    if (shouldCancel != true) {
      debugPrint('❌ Ride cancellation aborted by user.');
      return;
    }

    setState(() {
      _isLoading = true;
    });

    try {
      // ✅ Correct endpoint (adjusted to match your Django URLs)
      final endpoint = widget.isDriver
          ? '/api/rides/handle/${widget.rideId}/driver-cancel/'
          : '/api/rides/handle/${widget.rideId}/passenger-cancel/';

      debugPrint('🛰️ Sending cancel request to: $baseUrl$endpoint');

      final response = await http.post(
        Uri.parse('$baseUrl$endpoint'),
        headers: {
          'Authorization': 'Bearer ${widget.accessToken}',
          'Content-Type': 'application/json',
        },
      );

      // 🧾 Print the raw response for debugging
      debugPrint('🔍 Cancel Ride Response Code: ${response.statusCode}');
      debugPrint('🔍 Cancel Ride Response Body: ${response.body}');

      if (!mounted) return;

      if (response.statusCode == 200) {
        debugPrint('✅ Ride cancelled successfully.');

        setState(() {
          _rideStatus = 'cancelled';
        });

        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Ride cancelled successfully'),
            backgroundColor: Colors.orange,
          ),
        );

        // ⏳ Navigate back to notifications after short delay
        Future.delayed(const Duration(seconds: 2), () {
          if (mounted) {
            debugPrint('🟠 Ride cancelled — returning to previous page...');
            Navigator.pop(context); // ✅ Just go back one page
          }
        });
      } else {
        // ❌ Non-success status code — log details
        throw Exception(
          'Failed to cancel ride: ${response.statusCode} | ${response.body}',
        );
      }
    } catch (e) {
      debugPrint('💥 Error cancelling ride: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error cancelling ride: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.isDriver
              ? 'Driver - Ride #${widget.rideId}'
              : 'Your Ride #${widget.rideId}',
        ),
        backgroundColor: widget.isDriver ? Colors.blue[700] : Colors.green[700],
        automaticallyImplyLeading: false, // This removes the back button
      ),
      body: _currentPosition == null
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                // Ride info header
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: widget.isDriver ? Colors.blue[50] : Colors.green[50],
                    border: Border(
                      bottom: BorderSide(
                        color: widget.isDriver
                            ? Colors.blue[200]!
                            : Colors.green[200]!,
                      ),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Icons.info_outline,
                            color: widget.isDriver
                                ? Colors.blue[700]
                                : Colors.green[700],
                            size: 20,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            'Ride Details',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              color: widget.isDriver
                                  ? Colors.blue[700]
                                  : Colors.green[700],
                            ),
                          ),
                          const Spacer(),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: _rideStatus == 'completed'
                                  ? Colors.green
                                  : _rideStatus == 'cancelled'
                                  ? Colors.red
                                  : Colors.orange,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Text(
                              _rideStatus.toUpperCase(),
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),

                      // Contact info
                      if (widget.isDriver && widget.passengerName != null) ...[
                        Row(
                          children: [
                            const Icon(Icons.person, size: 16),
                            const SizedBox(width: 8),
                            Text('Passenger: ${widget.passengerName}'),
                            if (widget.passengerPhone != null) ...[
                              const SizedBox(width: 16),
                              const Icon(Icons.phone, size: 16),
                              const SizedBox(width: 4),
                              Text(widget.passengerPhone!),
                            ],
                          ],
                        ),
                        const SizedBox(height: 8),
                      ],

                      if (!widget.isDriver && widget.driverName != null) ...[
                        Row(
                          children: [
                            const Icon(Icons.local_taxi, size: 16),
                            const SizedBox(width: 8),
                            Text('Driver: ${widget.driverName}'),
                            if (widget.vehicleNumber != null) ...[
                              const SizedBox(width: 8),
                              Text('(${widget.vehicleNumber})'),
                            ],
                          ],
                        ),
                        if (widget.driverPhone != null) ...[
                          const SizedBox(height: 4),
                          Row(
                            children: [
                              const Icon(Icons.phone, size: 16),
                              const SizedBox(width: 8),
                              Text(widget.driverPhone!),
                            ],
                          ),
                        ],
                        const SizedBox(height: 8),
                      ],

                      // Trip details
                      Row(
                        children: [
                          const Icon(Icons.group, size: 16),
                          const SizedBox(width: 8),
                          Text('Passengers: ${widget.numberOfPassengers}'),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          const Icon(
                            Icons.location_on,
                            color: Colors.green,
                            size: 16,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text('Pickup: ${widget.pickupAddress}'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          const Icon(
                            Icons.location_on,
                            color: Colors.red,
                            size: 16,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text('Drop: ${widget.dropoffAddress}'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),

                // Map
                Expanded(
                  child: FlutterMap(
                    options: MapOptions(
                      initialCenter: _currentPosition!,
                      initialZoom: 15,
                    ),
                    children: [
                      TileLayer(
                        urlTemplate:
                            'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                        userAgentPackageName: 'com.example.erick_app',
                      ),
                      MarkerLayer(
                        markers: [
                          // Current user position
                          if (_currentPosition != null)
                            Marker(
                              point: _currentPosition!,
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
                                      color: widget.isDriver
                                          ? Colors.blue
                                          : Colors.green,
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: Text(
                                      widget.isDriver ? 'Driver' : 'You',
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 10,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                  Icon(
                                    widget.isDriver
                                        ? Icons.local_taxi
                                        : Icons.person_pin_circle,
                                    color: widget.isDriver
                                        ? Colors.blue
                                        : Colors.green,
                                    size: 35,
                                  ),
                                ],
                              ),
                            ),

                          // Pickup location
                          if (widget.pickupLat != null &&
                              widget.pickupLng != null)
                            Marker(
                              point: LatLng(
                                widget.pickupLat!,
                                widget.pickupLng!,
                              ),
                              width: 60,
                              height: 60,
                              child: const Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.location_on,
                                    color: Colors.green,
                                    size: 30,
                                  ),
                                  Text(
                                    'Pickup',
                                    style: TextStyle(
                                      fontSize: 8,
                                      fontWeight: FontWeight.bold,
                                      color: Colors.green,
                                    ),
                                  ),
                                ],
                              ),
                            ),

                          // Dropoff location
                          if (widget.dropoffLat != null &&
                              widget.dropoffLng != null)
                            Marker(
                              point: LatLng(
                                widget.dropoffLat!,
                                widget.dropoffLng!,
                              ),
                              width: 60,
                              height: 60,
                              child: const Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.location_on,
                                    color: Colors.red,
                                    size: 30,
                                  ),
                                  Text(
                                    'Drop',
                                    style: TextStyle(
                                      fontSize: 8,
                                      fontWeight: FontWeight.bold,
                                      color: Colors.red,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),

                // Action buttons
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.grey[50],
                    border: Border(top: BorderSide(color: Colors.grey[300]!)),
                  ),
                  child: Row(
                    children: [
                      // Cancel button
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _isLoading || _rideStatus != 'accepted'
                              ? null
                              : _cancelRide,
                          icon: const Icon(Icons.cancel, color: Colors.red),
                          label: const Text(
                            'Cancel',
                            style: TextStyle(color: Colors.red),
                          ),
                          style: OutlinedButton.styleFrom(
                            side: const BorderSide(color: Colors.red),
                            padding: const EdgeInsets.symmetric(vertical: 12),
                          ),
                        ),
                      ),
                      const SizedBox(width: 16),
                      // Complete button (only for driver)
                      if (widget.isDriver)
                        Expanded(
                          child: ElevatedButton.icon(
                            onPressed: _isLoading || _rideStatus != 'accepted'
                                ? null
                                : _completeRide,
                            icon: _isLoading
                                ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      valueColor: AlwaysStoppedAnimation<Color>(
                                        Colors.white,
                                      ),
                                    ),
                                  )
                                : const Icon(Icons.check_circle),
                            label: Text(
                              _isLoading ? 'Completing...' : 'Complete',
                            ),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.green,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(vertical: 12),
                            ),
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

void main() {
  runApp(
    const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: RideTrackingPage(
        rideId: 1,
        pickupAddress: "Connaught Place, Delhi",
        dropoffAddress: "Noida Sector 62",
        numberOfPassengers: 2,
        passengerName: "Yash",
        passengerPhone: "9876543210",
        driverName: "Apurv",
        driverPhone: "9999999999",
        vehicleNumber: "DL01AB1234",
        pickupLat: 28.6149,
        pickupLng: 77.2090,
        dropoffLat: 28.6200,
        dropoffLng: 77.3700,
        accessToken: "dummy_token",
        isDriver: true,
      ),
    ),
  );
}
