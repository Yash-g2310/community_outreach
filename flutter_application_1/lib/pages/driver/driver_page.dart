import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:async';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:flutter_map_cancellable_tile_provider/flutter_map_cancellable_tile_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../profile/profile_page.dart';
import 'driver_tracking_page.dart';
import '../user/previous_rides.dart';
import '../../config/constants.dart';
import '../../services/auth_service.dart';
import '../../services/websocket_service.dart';
import '../../services/logger_service.dart';
import '../../services/error_service.dart';
import '../../router/app_router.dart';

class DriverPage extends StatefulWidget {
  final String? jwtToken;
  final Map<String, dynamic>? userData;
  final String? sessionId;
  final String? csrfToken;
  final String? refreshToken;

  const DriverPage({
    super.key,
    this.jwtToken,
    this.userData,
    this.sessionId,
    this.csrfToken,
    this.refreshToken,
  });

  @override
  State<DriverPage> createState() => _DriverPageState();
}

class _DriverPageState extends State<DriverPage> {
  bool isActive = true;
  bool isLoading = false;
  String? errorMessage;
  Map<String, dynamic>? driverProfile;
  Timer? _locationUpdateTimer;
  Position? _currentPosition;
  LatLng? _mapPosition; // For displaying on map
  int? _currentRideId;

  // API Configuration uses centralized base URL from constants

  List<Map<String, dynamic>> notifications = [];
  Set<int> _rejectedRideIds = {}; // Local storage for rejected ride IDs
  final WebSocketService _wsService = WebSocketService();
  StreamSubscription? _wsSubscription;
  StreamSubscription<Position>? _positionStreamSubscription;
  final ErrorService _errorService = ErrorService();

  @override
  void initState() {
    super.initState();
    _loadRejectedRides(); // Load rejected rides from local storage
    _loadDriverData();
    _loadCurrentLocation();
  }

  @override
  void dispose() {
    // Cancel WebSocket subscription safely
    try {
      _wsSubscription?.cancel();
      _wsSubscription = null;
    } catch (e) {
      Logger.error(
        'Error cancelling WebSocket subscription',
        error: e,
        tag: 'DriverPage',
      );
    }

    // Ensure server marks driver offline when the app/widget is disposed
    _sendDriverOfflineSilently();

    // Cancel position stream subscription safely
    try {
      _positionStreamSubscription?.cancel();
      _positionStreamSubscription = null;
    } catch (e) {
      print('Error cancelling position stream subscription: $e');
    }

    super.dispose();
  }

  Future<void> _loadCurrentLocation() async {
    try {
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) throw Exception('Location services are disabled.');
      // Check location permission
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          throw Exception('Location permission denied.');
        }
      }

      if (permission == LocationPermission.deniedForever) {
        throw Exception('Location permissions are permanently denied.');
      }

      Position position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );

      _safeSetState(() {
        _mapPosition = LatLng(position.latitude, position.longitude);
      });

      Logger.debug(
        'Initial Location: ${position.latitude}, ${position.longitude}',
        tag: 'DriverPage',
      );
      // Location updates will be started after loading driver profile
    } catch (e) {
      Logger.error('Error initializing location', error: e, tag: 'DriverPage');
    }
  }

  Future<void> _getCurrentLocation() async {
    try {
      await Geolocator.requestPermission();
      Position position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );
      _currentPosition = position;

      // Update map position
      _safeSetState(() {
        _mapPosition = LatLng(position.latitude, position.longitude);
      });

      Logger.debug(
        'Current location: ${position.latitude}, ${position.longitude}',
        tag: 'DriverPage',
      );

      if (widget.jwtToken != null) {
        _connectDriverSocket();
      }
    } catch (e) {
      Logger.error(
        'Error getting current location',
        error: e,
        tag: 'DriverPage',
      );
    }
  }

  void _startLocationUpdates() {
    // Only start the periodic location loop when driver is marked available.
    if (!isActive) {
      _logDriver('Not starting location updates: driver is offline');
      return;
    }

    // Cancel any existing timer or stream subscription
    _locationUpdateTimer?.cancel();
    _positionStreamSubscription?.cancel();

    // Use Geolocator position stream to reduce battery/network usage.
    // Emit only when device moves more than `distanceFilter` meters.
    final locationSettings = LocationSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 50,
    );

    _positionStreamSubscription =
        Geolocator.getPositionStream(locationSettings: locationSettings).listen(
          (Position position) async {
            if (!isActive) return;
            await _sendLocationToServer(position);
          },
        );

    _logDriver('Location update stream started');
  }

  void _stopLocationUpdates() {
    try {
      _locationUpdateTimer?.cancel();
      _locationUpdateTimer = null;
    } catch (e) {
      Logger.error(
        'Error cancelling location update timer',
        error: e,
        tag: 'DriverPage',
      );
    }

    try {
      _positionStreamSubscription?.cancel();
      _positionStreamSubscription = null;
    } catch (e) {
      Logger.error(
        'Error cancelling position stream subscription',
        error: e,
        tag: 'DriverPage',
      );
    }

    Logger.debug('Location update stream/timer stopped', tag: 'DriverPage');
  }

  void _logDriver(String message, {String tag = 'Driver'}) {
    if (!kDebugMode) return;
    debugPrint('[$tag] $message');
  }

  void _logSocket(String message) => _logDriver(message, tag: 'DriverSocket');

  void _connectDriverSocket() {
    try {
      // Connect using centralized WebSocket service
      _wsService.connectDriver(
        jwtToken: widget.jwtToken,
        sessionId: widget.sessionId,
        csrfToken: widget.csrfToken,
      );

      // Subscribe to driver messages
      _wsSubscription = _wsService.driverMessages.listen((data) {
        if (!mounted) return;
        Logger.websocket("DRIVER WS RAW → $data", tag: 'DriverPage');
        _handleDriverSocketMessage(data);
      });

      _logSocket('Driver WebSocket connected via service');
    } catch (e) {
      Logger.error(
        'Failed to connect driver WebSocket',
        error: e,
        tag: 'DriverPage',
      );
    }
  }

  void _handleDriverSocketMessage(Map<String, dynamic> data) {
    try {
      final eventType = data['type'] as String?;
      _logSocket('Message <- ${eventType ?? 'unknown'}');

      if (eventType == null) {
        return;
      }

      switch (eventType) {
        case 'connection_established':
          _logSocket(
            'Connection established: ${data['message'] ?? 'Connected'}',
          );
          break;

        case 'ride_offer':
          final rideData = data['ride'];
          if (rideData is Map) {
            // Only add incoming rides that are still pending. If the ride was
            // cancelled or already accepted, skip adding it to the driver's list.
            final Map<String, dynamic> rd = Map<String, dynamic>.from(rideData);
            final status = rd['status']?.toString();
            if (status == null || status == 'pending') {
              _handleIncomingRide(rd);
            } else {
              _logSocket(
                'Ignoring incoming ride (status=$status): ${rd['id']}',
              );
            }
          } else {
            _logSocket('Malformed ride payload: ${rideData.runtimeType}');
          }
          break;

        case 'ride_cancelled':
        case 'ride_expired':
          _handleRideRemoval(
            data['ride_id'],
            data['message'] ??
                (eventType == 'ride_cancelled'
                    ? 'Ride cancelled by passenger'
                    : 'Ride offer timed out'),
          );
          // If the cancelled/expired ride matches our current active ride,
          // clear the current ride state so we revert to availability updates.
          try {
            final incoming = data['ride_id'];
            final int? rid = incoming is int
                ? incoming
                : int.tryParse('$incoming');
            if (rid != null &&
                _currentRideId != null &&
                rid == _currentRideId) {
              _logSocket(
                'Active ride $rid ended/cancelled - clearing current ride state',
              );
              _currentRideId = null;
              // restart location updates if driver remains available
              if (isActive) {
                _stopLocationUpdates();
                _startLocationUpdates();
              }
            }
          } catch (_) {}
          break;

        default:
          Logger.warning('Unhandled WS event: $data', tag: 'DriverPage');
      }
    } catch (e) {
      Logger.error(
        'Error decoding driver WS message: $e | raw=$data',
        tag: 'DriverPage',
      );
    }
  }

  // Map a raw ride payload from server into the UI notification shape
  Map<String, dynamic> _rideToNotification(Map<String, dynamic> ride) {
    final passengerData = ride['passenger'];
    String passengerName = 'Unknown';
    String passengerPhone = '';

    if (passengerData is Map) {
      passengerName = passengerData['username']?.toString() ?? 'Unknown';
      passengerPhone = passengerData['phone_number']?.toString() ?? '';
    } else {
      passengerName = ride['passenger_name']?.toString() ?? 'Unknown';
      passengerPhone = ride['passenger_phone']?.toString() ?? '';
    }

    return {
      'id': ride['id'],
      'start': ride['pickup_address'] ?? 'Unknown pickup',
      'end': ride['dropoff_address'] ?? 'Unknown destination',
      'people': ride['number_of_passengers'] ?? ride['passengers'] ?? 1,
      'distance': ride['distance_from_driver'] ?? ride['distance'] ?? 0,
      'passenger_name': passengerName,
      'passenger_phone': passengerPhone,
      'pickup_lat': ride['pickup_latitude'] ?? ride['pickup_lat'],
      'pickup_lng': ride['pickup_longitude'] ?? ride['pickup_lng'],
      'dropoff_lat': ride['dropoff_latitude'] ?? ride['dropoff_lat'],
      'dropoff_lng': ride['dropoff_longitude'] ?? ride['dropoff_lng'],
      'requested_at': ride['requested_at'],
    };
  }

  void _handleIncomingRide(Map<String, dynamic> ridePayload) {
    final rideId = ridePayload['id'];
    if (rideId == null) {
      _logSocket('Incoming ride missing ID: $ridePayload');
      return;
    }

    if (_rejectedRideIds.contains(rideId)) {
      _logSocket('Ignoring ride $rideId - previously rejected');
      return;
    }

    final mappedRide = _rideToNotification(ridePayload);
    _logSocket(
      'Ride $rideId pushed to notifications (total=${notifications.length + 1})',
    );

    _safeSetState(() {
      final updated = List<Map<String, dynamic>>.from(notifications);
      final existingIndex = updated.indexWhere(
        (notif) => notif['id'] == rideId,
      );
      if (existingIndex >= 0) {
        updated[existingIndex] = mappedRide;
      } else {
        updated.insert(0, mappedRide);
      }
      notifications = updated;
    });

    _showSnackBar(
      'New ride request received! 🚗',
      backgroundColor: Colors.green,
    );
  }

  void _handleRideRemoval(dynamic rideIdRaw, String reason) {
    final rideId = rideIdRaw is int ? rideIdRaw : int.tryParse('$rideIdRaw');
    if (rideId == null) {
      _logSocket('Ride removal skipped - invalid id: $rideIdRaw');
      return;
    }

    var removed = false;
    _safeSetState(() {
      final updated = notifications
          .where((notif) => notif['id'] != rideId)
          .toList();
      removed = updated.length != notifications.length;
      notifications = updated;
    });

    if (removed) {
      _showSnackBar(reason, backgroundColor: Colors.orange);
      _logSocket('Ride $rideId removed: $reason');
    }
  }

  void _safeSetState(VoidCallback fn) {
    if (!mounted) return;
    setState(fn);
  }

  void _showSnackBar(String message, {Color backgroundColor = Colors.black87}) {
    if (!mounted) return;
    if (backgroundColor == Colors.green || backgroundColor == Colors.orange) {
      _errorService.showSuccess(context, message);
    } else {
      _errorService.showError(context, message);
    }
  }

  Future<void> _sendLocationToServer(Position position) async {
    // Get current GPS location before updating status
    if (_currentPosition == null) {
      await _getCurrentLocation();
    }
    _safeSetState(() {
      _mapPosition = LatLng(position.latitude, position.longitude);
    });

    try {
      double truncatedLatitude = double.parse(
        position.latitude.toStringAsFixed(6),
      );
      double truncatedLongitude = double.parse(
        position.longitude.toStringAsFixed(6),
      );

      if (_currentRideId != null) {
        Logger.websocket(
          'Sending Tracking Update for ride $_currentRideId: $truncatedLatitude, $truncatedLongitude',
          tag: 'DriverPage',
        );

        _wsService.sendDriverMessage({
          'type': 'tracking_update',
          'ride_id': _currentRideId,
          'latitude': truncatedLatitude,
          'longitude': truncatedLongitude,
        });
      } else if (isActive) {
        Logger.websocket(
          'Sending Updated Location via WS (stream): $truncatedLatitude, $truncatedLongitude',
          tag: 'DriverPage',
        );

        _wsService.sendDriverMessage({
          'type': 'driver_location_update',
          'latitude': truncatedLatitude,
          'longitude': truncatedLongitude,
        });
      }
    } catch (e) {
      Logger.error(
        'Error sending driver location via WebSocket',
        error: e,
        tag: 'DriverPage',
      );
    }
  }

  Future<void> _loadDriverData() async {
    if (widget.jwtToken == null) {
      _safeSetState(() {
        errorMessage = 'No authentication token found';
      });
      return;
    }

    _safeSetState(() {
      isLoading = true;
      errorMessage = null;
    });

    try {
      // Load driver profile first, then nearby rides (need profile for fallback location)
      await _fetchDriverProfile();

      // Start location updates if driver is active
      if (isActive) {
        _startLocationUpdates();
      }
    } catch (e) {
      _safeSetState(() {
        errorMessage = 'Error loading driver data: $e';
      });
    } finally {
      _safeSetState(() {
        isLoading = false;
      });
    }
  }

  // Load rejected ride IDs from local storage
  Future<void> _loadRejectedRides() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final driverId = widget.userData?['id']?.toString() ?? 'unknown';
      final rejectedList =
          prefs.getStringList('rejected_rides_$driverId') ?? [];

      _safeSetState(() {
        _rejectedRideIds = rejectedList
            .map((id) => int.tryParse(id))
            .where((id) => id != null)
            .cast<int>()
            .toSet();
      });

      Logger.debug(
        'Loaded ${_rejectedRideIds.length} rejected rides from local storage: $_rejectedRideIds',
        tag: 'DriverPage',
      );
    } catch (e) {
      Logger.error('Error loading rejected rides', error: e, tag: 'DriverPage');
      _safeSetState(() {
        _rejectedRideIds = {};
      });
    }
  }

  // Save rejected ride IDs to local storage
  Future<void> _saveRejectedRides() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final driverId = widget.userData?['id']?.toString() ?? 'unknown';
      final rejectedList = _rejectedRideIds.map((id) => id.toString()).toList();

      await prefs.setStringList('rejected_rides_$driverId', rejectedList);
      Logger.debug(
        'Saved ${_rejectedRideIds.length} rejected rides to local storage',
        tag: 'DriverPage',
      );
    } catch (e) {
      Logger.error('Error saving rejected rides', error: e, tag: 'DriverPage');
    }
  }

  // Add a ride ID to rejected list
  Future<void> _addRejectedRide(int rideId) async {
    _safeSetState(() {
      _rejectedRideIds.add(rideId);
    });
    await _saveRejectedRides();
    Logger.debug(
      'Added ride $rideId to rejected list. Total rejected: ${_rejectedRideIds.length}',
      tag: 'DriverPage',
    );
  }

  Future<void> _fetchDriverProfile() async {
    try {
      final response = await http.get(
        Uri.parse('$kBaseUrl/api/rides/driver/profile/'),
        headers: {
          'Authorization': 'Bearer ${widget.jwtToken}',
          'Content-Type': 'application/json',
        },
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        _safeSetState(() {
          driverProfile = data;
          // Update isActive based on driver status
          isActive = data['status'] == 'available';
        });
      } else {
        throw Exception(
          'Failed to load driver profile: ${response.statusCode}',
        );
      }
    } catch (e) {
      Logger.error('Driver profile error', error: e, tag: 'DriverPage');
      rethrow;
    }
  }

  Future<void> _updateDriverStatus(bool active) async {
    if (widget.jwtToken == null) return;

    _safeSetState(() {
      isLoading = true;
    });

    try {
      // Get current GPS location before updating status
      if (_currentPosition == null) {
        await _getCurrentLocation();
      }

      // Use current GPS location or fallback to null
      double? latitude = _currentPosition?.latitude;
      double? longitude = _currentPosition?.longitude;

      final response = await http.patch(
        Uri.parse('$kBaseUrl/api/rides/driver/status/'),
        headers: {
          'Authorization': 'Bearer ${widget.jwtToken}',
          'Content-Type': 'application/json',
        },
        body: json.encode({
          'status': active ? 'available' : 'offline',
          if (latitude != null && longitude != null) ...{
            'current_latitude': double.parse(latitude.toStringAsFixed(6)),
            'current_longitude': double.parse(longitude.toStringAsFixed(6)),
          },
        }),
      );

      if (!mounted) return;

      if (response.statusCode == 200) {
        _safeSetState(() {
          isActive = active;
        });

        // Start or stop location updates based on status
        if (active) {
          _startLocationUpdates();
          // No need to fetch nearby rides when going online; ride requests come via WebSocket.
        } else {
          _stopLocationUpdates();
          // Clear notifications when going offline
          _safeSetState(() {
            notifications = [];
          });
        }

        _showSnackBar(
          active ? 'You are now available for rides' : 'You are now offline',
          backgroundColor: active ? Colors.green : Colors.orange,
        );
      } else {
        throw Exception('Failed to update status: ${response.statusCode}');
      }
    } catch (e) {
      _showSnackBar('Error updating status: $e', backgroundColor: Colors.red);
    } finally {
      _safeSetState(() {
        isLoading = false;
      });
    }
  }

  Future<void> _acceptRide(Map<String, dynamic> notification) async {
    if (widget.jwtToken == null) return;

    final rideId = notification['id'] as int;

    _safeSetState(() {
      isLoading = true;
    });

    try {
      final response = await http.post(
        Uri.parse('$kBaseUrl/api/rides/handle/$rideId/accept/'),
        headers: {
          'Authorization': 'Bearer ${widget.jwtToken}',
          'Content-Type': 'application/json',
        },
      );

      if (!mounted) return;

      if (response.statusCode == 200) {
        // Remove the accepted ride from notifications
        _safeSetState(() {
          notifications.removeWhere((notif) => notif['id'] == rideId);
        });

        _showSnackBar(
          'Ride accepted successfully! ✅',
          backgroundColor: Colors.green,
        );

        // Mark current ride id so location updates are sent as tracking_update
        _currentRideId = rideId;

        // Navigate to ride tracking page - WebSocket service persists
        if (mounted) {
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(
              builder: (_) => RideTrackingPage(
                rideId: notification['id'] as int,
                pickupAddress: notification['start'] as String,
                dropoffAddress: notification['end'] as String,
                numberOfPassengers: notification['people'] as int,
                passengerName: notification['passenger_name'] as String?,
                passengerPhone: notification['passenger_phone'] as String?,
                pickupLat: notification['pickup_lat'] != null
                    ? double.tryParse(notification['pickup_lat'].toString())
                    : null,
                pickupLng: notification['pickup_lng'] != null
                    ? double.tryParse(notification['pickup_lng'].toString())
                    : null,
                dropoffLat: notification['dropoff_lat'] != null
                    ? double.tryParse(notification['dropoff_lat'].toString())
                    : null,
                dropoffLng: notification['dropoff_lng'] != null
                    ? double.tryParse(notification['dropoff_lng'].toString())
                    : null,
                accessToken: widget.jwtToken,
              ),
            ),
          );
        }
      } else {
        throw Exception('Failed to accept ride: ${response.statusCode}');
      }
    } catch (e) {
      _showSnackBar('Error accepting ride: $e', backgroundColor: Colors.red);
    } finally {
      _safeSetState(() {
        isLoading = false;
      });
    }
  }

  Future<void> _rejectRide(int rideId) async {
    if (widget.jwtToken == null) return;

    _safeSetState(() {
      isLoading = true;
    });

    try {
      // Call server API to reject the ride offer so backend state is authoritative.
      final response = await http.post(
        Uri.parse('$kBaseUrl/api/rides/handle/$rideId/reject/'),
        headers: {
          'Authorization': 'Bearer ${widget.jwtToken}',
          'Content-Type': 'application/json',
        },
      );

      if (!mounted) return;

      if (response.statusCode == 200) {
        // Persist locally that we rejected this ride (so it won't reappear)
        await _addRejectedRide(rideId);

        // Remove the rejected ride from current notifications
        _safeSetState(() {
          notifications.removeWhere((notif) => notif['id'] == rideId);
        });

        _showSnackBar(
          'Ride rejected - hidden from your list! ❌',
          backgroundColor: Colors.orange,
        );

        Logger.info(
          'Ride $rideId rejected (server acknowledged) and hidden locally',
          tag: 'DriverPage',
        );
      } else {
        throw Exception('Failed to reject ride: ${response.statusCode}');
      }
    } catch (e) {
      _showSnackBar('Error rejecting ride: $e', backgroundColor: Colors.red);
    } finally {
      _safeSetState(() {
        isLoading = false;
      });
    }
  }

  Future<void> _sendDriverOfflineSilently() async {
    if (widget.jwtToken == null) return;

    try {
      await http.patch(
        Uri.parse('$kBaseUrl/api/rides/driver/status/'),
        headers: {
          'Authorization': 'Bearer ${widget.jwtToken}',
          'Content-Type': 'application/json',
        },
        body: json.encode({'status': 'offline'}),
      );
    } catch (e) {
      Logger.error(
        'Error sending offline status on dispose',
        error: e,
        tag: 'DriverPage',
      );
    }
  }

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

              // Ride details with real API data
              _buildDetailRow(
                "Passenger:",
                notif['passenger_name'] ?? 'Unknown',
              ),
              _buildDetailRow("Phone:", notif['passenger_phone'] ?? ''),
              _buildDetailRow("Pickup:", notif['start']),
              _buildDetailRow("Drop-off:", notif['end']),
              _buildDetailRow("Passengers:", "${notif['people']}"),
              _buildDetailRow("Distance:", "${notif['distance']}m away"),

              const SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  // Accept button with real API call
                  ElevatedButton.icon(
                    onPressed: isLoading
                        ? null
                        : () async {
                            Navigator.pop(context);
                            await _acceptRide(notif);
                          },
                    icon: const Icon(Icons.check_circle, color: Colors.white),
                    label: const Text("Accept"),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.green,
                    ),
                  ),
                  ElevatedButton.icon(
                    onPressed: isLoading
                        ? null
                        : () async {
                            Navigator.pop(context);
                            await _rejectRide(notif['id'] as int);
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
      appBar: AppBar(
        title: const Text('E-Rickshaw Driver'),
        leading: IconButton(
          onPressed: () {
            // Show confirmation dialog
            showDialog(
              context: context,
              builder: (context) => AlertDialog(
                title: const Text('Logout'),
                content: const Text('Are you sure you want to logout?'),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Cancel'),
                  ),
                  TextButton(
                    onPressed: () async {
                      Navigator.pop(context); // Close dialog
                      // Clear auth data and navigate to splash
                      await AuthService().clearAuthData();
                      if (context.mounted) {
                        Navigator.pushNamedAndRemoveUntil(
                          context,
                          AppRouter.splash,
                          (route) => false,
                        );
                      }
                    },
                    child: const Text(
                      'Logout',
                      style: TextStyle(color: Colors.red),
                    ),
                  ),
                ],
              ),
            );
          },
          icon: const Icon(Icons.logout, color: Colors.red),
          tooltip: 'Logout',
        ),
        actions: [
          // Profile menu button (Profile | Previous Rides)
          PopupMenuButton<String>(
            icon: const Icon(
              Icons.account_circle,
              size: 28,
              color: Colors.blueGrey,
            ),
            onSelected: (value) {
              if (value == 'profile') {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => ProfilePage(
                      userType: 'Driver',
                      userName: widget.userData?['username'] ?? 'E-Rick Driver',
                      userEmail:
                          widget.userData?['email'] ?? 'driver@erick.com',
                      accessToken: widget.jwtToken,
                    ),
                  ),
                );
              } else if (value == 'rides') {
                if (widget.jwtToken == null || widget.jwtToken!.isEmpty) {
                  _errorService.showError(
                    context,
                    'No access token available. Please login to view previous rides.',
                  );
                  return;
                }
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => PreviousRidesPage(
                      jwtToken: widget.jwtToken!,
                      isDriver: true,
                    ),
                  ),
                );
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(value: 'profile', child: Text('Profile')),
              const PopupMenuItem(
                value: 'rides',
                child: Text('Previous Rides'),
              ),
            ],
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: _mapPosition == null
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                // Map (top half)
                SizedBox(
                  height: MediaQuery.of(context).size.height * 0.5,
                  child: FlutterMap(
                    options: MapOptions(
                      initialCenter: _mapPosition!,
                      initialZoom: 16,
                    ),
                    children: [
                      TileLayer(
                        urlTemplate:
                            'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                        userAgentPackageName: 'com.example.erick_driver',
                        tileProvider: kIsWeb
                            ? CancellableNetworkTileProvider()
                            : NetworkTileProvider(),
                      ),
                      MarkerLayer(
                        markers: [
                          // Driver's current location marker
                          Marker(
                            point: _mapPosition!,
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
                                const Icon(
                                  Icons.local_taxi,
                                  color: Colors.blue,
                                  size: 35,
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),

                // Bottom part (status controls + notifications)
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(16.0),
                    child: Column(
                      children: [
                        // Driver Status Controls
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: isActive ? Colors.green[50] : Colors.red[50],
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: isActive
                                  ? Colors.green[200]!
                                  : Colors.red[200]!,
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
                                    isActive
                                        ? 'Online - Available for rides'
                                        : 'Offline',
                                    style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                      color: isActive
                                          ? Colors.green[800]
                                          : Colors.red[800],
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
                                      onPressed: isLoading
                                          ? null
                                          : () => _updateDriverStatus(true),
                                      icon: Icon(
                                        Icons.circle,
                                        color: isLoading
                                            ? Colors.grey
                                            : Colors.green,
                                        size: 18,
                                      ),
                                      label: Text(
                                        isLoading ? 'Updating...' : 'Go Online',
                                      ),
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: isActive
                                            ? Colors.green[100]
                                            : null,
                                        foregroundColor: isActive
                                            ? Colors.green[800]
                                            : null,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: ElevatedButton.icon(
                                      onPressed: isLoading
                                          ? null
                                          : () => _updateDriverStatus(false),
                                      icon: Icon(
                                        Icons.circle,
                                        color: isLoading
                                            ? Colors.grey
                                            : Colors.red,
                                        size: 18,
                                      ),
                                      label: Text(
                                        isLoading
                                            ? 'Updating...'
                                            : 'Go Offline',
                                      ),
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: !isActive
                                            ? Colors.red[100]
                                            : null,
                                        foregroundColor: !isActive
                                            ? Colors.red[800]
                                            : null,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),

                        const SizedBox(height: 16),

                        // Ride Requests Section
                        Container(
                          width: double.infinity,
                          decoration: BoxDecoration(
                            color: Colors.blue[50],
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: Colors.blue[200]!),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // Header
                              Container(
                                width: double.infinity,
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  color: Colors.blue[700],
                                  borderRadius: const BorderRadius.only(
                                    topLeft: Radius.circular(12),
                                    topRight: Radius.circular(12),
                                  ),
                                ),
                                child: const Text(
                                  'Ride Requests',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                  ),
                                  textAlign: TextAlign.center,
                                ),
                              ),

                              // Content
                              Padding(
                                padding: const EdgeInsets.all(12),
                                child: isLoading
                                    ? const Center(
                                        child: Column(
                                          children: [
                                            CircularProgressIndicator(),
                                            SizedBox(height: 8),
                                            Text('Loading rides...'),
                                          ],
                                        ),
                                      )
                                    : errorMessage != null
                                    ? Center(
                                        child: Column(
                                          children: [
                                            const Icon(
                                              Icons.error,
                                              color: Colors.red,
                                              size: 32,
                                            ),
                                            const SizedBox(height: 8),
                                            Text(
                                              errorMessage!,
                                              textAlign: TextAlign.center,
                                              style: const TextStyle(
                                                color: Colors.red,
                                              ),
                                            ),
                                            const SizedBox(height: 8),
                                            ElevatedButton(
                                              onPressed: _loadDriverData,
                                              child: const Text('Retry'),
                                            ),
                                          ],
                                        ),
                                      )
                                    : isActive
                                    ? notifications.isNotEmpty
                                          ? Column(
                                              children: [
                                                // Requests counter
                                                Container(
                                                  width: double.infinity,
                                                  padding: const EdgeInsets.all(
                                                    8,
                                                  ),
                                                  decoration: BoxDecoration(
                                                    color: Colors.orange[100],
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                          8,
                                                        ),
                                                  ),
                                                  child: Text(
                                                    '${notifications.length} ride request${notifications.length == 1 ? '' : 's'} nearby',
                                                    textAlign: TextAlign.center,
                                                    style: TextStyle(
                                                      fontWeight:
                                                          FontWeight.bold,
                                                      color: Colors.orange[800],
                                                    ),
                                                  ),
                                                ),
                                                const SizedBox(height: 8),
                                                // Requests list
                                                ...notifications.map(
                                                  (notif) => Card(
                                                    margin:
                                                        const EdgeInsets.only(
                                                          bottom: 8,
                                                        ),
                                                    child: ListTile(
                                                      leading: CircleAvatar(
                                                        backgroundColor:
                                                            Colors.blue,
                                                        child: Text(
                                                          '#${notif['id']}',
                                                          style:
                                                              const TextStyle(
                                                                color: Colors
                                                                    .white,
                                                                fontSize: 12,
                                                                fontWeight:
                                                                    FontWeight
                                                                        .bold,
                                                              ),
                                                        ),
                                                      ),
                                                      title: Text(
                                                        notif['passenger_name'] ??
                                                            'Unknown',
                                                        style: const TextStyle(
                                                          fontWeight:
                                                              FontWeight.bold,
                                                        ),
                                                      ),
                                                      subtitle: Column(
                                                        crossAxisAlignment:
                                                            CrossAxisAlignment
                                                                .start,
                                                        children: [
                                                          Text(
                                                            'From: ${notif['start']}',
                                                          ),
                                                          Text(
                                                            'To: ${notif['end']}',
                                                          ),
                                                          Text(
                                                            'Passengers: ${notif['people']} • ${notif['distance']}m away',
                                                          ),
                                                        ],
                                                      ),
                                                      trailing: Container(
                                                        padding:
                                                            const EdgeInsets.symmetric(
                                                              horizontal: 8,
                                                              vertical: 4,
                                                            ),
                                                        decoration: BoxDecoration(
                                                          color: Colors.green,
                                                          borderRadius:
                                                              BorderRadius.circular(
                                                                12,
                                                              ),
                                                        ),
                                                        child: const Text(
                                                          'TAP',
                                                          style: TextStyle(
                                                            color: Colors.white,
                                                            fontSize: 10,
                                                            fontWeight:
                                                                FontWeight.bold,
                                                          ),
                                                        ),
                                                      ),
                                                      onTap: () =>
                                                          _showBottomSheet(
                                                            notif,
                                                          ),
                                                    ),
                                                  ),
                                                ),
                                              ],
                                            )
                                          : Center(
                                              child: Column(
                                                children: [
                                                  const Icon(
                                                    Icons.notifications_off,
                                                    size: 32,
                                                    color: Colors.grey,
                                                  ),
                                                  const SizedBox(height: 8),
                                                  const Text(
                                                    'No ride requests nearby',
                                                    style: TextStyle(
                                                      fontSize: 14,
                                                      fontWeight:
                                                          FontWeight.w500,
                                                    ),
                                                  ),
                                                  const SizedBox(height: 4),
                                                  const Text(
                                                    'Stay online to receive new requests',
                                                    style: TextStyle(
                                                      color: Colors.grey,
                                                      fontSize: 12,
                                                    ),
                                                  ),
                                                  const SizedBox(height: 8),
                                                  ElevatedButton.icon(
                                                    onPressed: _loadDriverData,
                                                    icon: const Icon(
                                                      Icons.refresh,
                                                      size: 16,
                                                    ),
                                                    label: const Text(
                                                      'Refresh',
                                                    ),
                                                    style: ElevatedButton.styleFrom(
                                                      padding:
                                                          const EdgeInsets.symmetric(
                                                            horizontal: 16,
                                                            vertical: 8,
                                                          ),
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            )
                                    : const Center(
                                        child: Column(
                                          children: [
                                            Icon(
                                              Icons.pause_circle,
                                              size: 32,
                                              color: Colors.grey,
                                            ),
                                            SizedBox(height: 8),
                                            Text(
                                              'You are offline',
                                              style: TextStyle(
                                                fontSize: 14,
                                                fontWeight: FontWeight.w500,
                                              ),
                                            ),
                                            SizedBox(height: 4),
                                            Text(
                                              'Go online to receive ride requests',
                                              style: TextStyle(
                                                color: Colors.grey,
                                                fontSize: 12,
                                              ),
                                              textAlign: TextAlign.center,
                                            ),
                                          ],
                                        ),
                                      ),
                              ),
                            ],
                          ),
                        ),

                        const SizedBox(height: 16), // Extra padding at bottom
                      ],
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}
