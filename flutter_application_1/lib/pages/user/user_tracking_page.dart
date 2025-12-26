import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_map_cancellable_tile_provider/flutter_map_cancellable_tile_provider.dart';
import 'package:latlong2/latlong.dart';
import 'user_page.dart'; // for navigation back to user page
import '../../config/api_endpoints.dart';
import '../../services/websocket_service.dart';
import '../../services/auth_service.dart';
import '../../services/logger_service.dart';
import '../../services/error_service.dart';
import '../../services/api_service.dart';
import '../../services/location_service.dart';
import '../../router/app_router.dart';
import '../../core/mixins/safe_state_mixin.dart';

class UserTrackingPage extends StatefulWidget {
  const UserTrackingPage({super.key});

  @override
  State<UserTrackingPage> createState() => _UserTrackingPageState();
}

class _UserTrackingPageState extends State<UserTrackingPage>
    with SafeStateMixin {
  LatLng? _userPosition;
  LatLng? _driverPosition;

  String _status = "Loading...";
  String _username = "-";
  String _phoneNumber = "-";
  String _vehicleNumber = "-";
  int? _currentRideId;

  final WebSocketService _wsService = WebSocketService();
  StreamSubscription? _wsSubscription;
  final Set<String> _processedRideEvents = <String>{};
  final ErrorService _errorService = ErrorService();
  final ApiService _apiService = ApiService();
  final AuthService _authService = AuthService();

  @override
  void initState() {
    super.initState();

    // Ensure WebSocket is connected (it should already be from user_page)
    _connectPassengerSocket();

    // Subscribe to passenger messages from WebSocket service
    _wsSubscription = _wsService.passengerMessages.listen((data) {
      if (!mounted) return;
      _handleWebSocketMessage(data);
    });

    _setupTracking();
  }

  Future<void> _connectPassengerSocket() async {
    final authState = await _authService.getAuthState();
    if (authState.isAuthenticated) {
      _wsService.connectPassenger(
        jwtToken: authState.accessToken,
        sessionId: null, // Not needed - WebSocket handles auth via token
        csrfToken: null, // Not needed - WebSocket handles auth via token
      );
    }
  }

  @override
  void dispose() {
    _sendStopTracking();
    // Cancel local subscription only - WebSocket service persists
    try {
      _wsSubscription?.cancel();
      _wsSubscription = null;
    } catch (e) {
      Logger.error(
        'Error cancelling tracking subscription',
        error: e,
        tag: 'UserTracking',
      );
    }
    super.dispose();
  }

  Future<void> _setupTracking() async {
    await _getCurrentLocation();
    await _getCurrentRideInfo(); // Get ride ID and initial driver info
    if (_currentRideId != null) {
      _sendStartTracking();
    }
  }

  Future<void> _getCurrentLocation() async {
    try {
      final locationService = LocationService();
      final location = await locationService.getCurrentLocation();

      if (location == null || !mounted) return;

      safeSetState(() {
        _userPosition = location;
      });
    } catch (e) {
      Logger.error(
        'Error getting user location',
        error: e,
        tag: 'UserTracking',
      );
    }
  }

  // ============================================================
  // Get current ride info (ID + initial driver data)
  // ============================================================
  Future<void> _getCurrentRideInfo() async {
    try {
      final response = await _apiService.get(PassengerEndpoints.current);

      if (response.statusCode == 200) {
        final data = json.decode(response.body);

        if (data['has_active_ride'] == true &&
            data['driver_assigned'] == true) {
          final ride = data['ride'];
          final driver = ride['driver'];

          safeSetState(() {
            final id = ride['id'];
            _currentRideId = id is int
                ? id
                : (id != null ? int.tryParse(id.toString()) : null);
            _status = ride['status'] ?? "N/A";
            _username = driver['username'] ?? "N/A";
            _phoneNumber = driver['phone_number'] ?? "N/A";
            _vehicleNumber = driver['vehicle_number'] ?? "N/A";

            final lat = double.tryParse(driver['current_latitude'] ?? "");
            final lng = double.tryParse(driver['current_longitude'] ?? "");
            if (lat != null && lng != null) {
              _driverPosition = LatLng(lat, lng);
            }
          });

          Logger.debug(
            'Ride ID: $_currentRideId, Driver: $_username',
            tag: 'UserTracking',
          );
        }
      }
    } catch (e) {
      Logger.error('Error getting ride info', error: e, tag: 'UserTracking');
    }
  }

  // Send start_tracking message to join ride group
  void _sendStartTracking() {
    if (_currentRideId != null) {
      _wsService.sendPassengerMessage({
        'type': 'start_tracking',
        'ride_id': _currentRideId,
      });
      Logger.websocket(
        'Sent start_tracking for ride $_currentRideId',
        tag: 'UserTracking',
      );
    }
  }

  // Send stop_tracking message to leave ride group (optional, e.g. on dispose)
  void _sendStopTracking() {
    if (_currentRideId != null) {
      _wsService.sendPassengerMessage({
        'type': 'stop_tracking',
        'ride_id': _currentRideId,
      });
      Logger.websocket(
        'Sent stop_tracking for ride $_currentRideId',
        tag: 'UserTracking',
      );
    }
  }

  // ============================================================
  // Get current ride ID for cancellation
  // ============================================================
  Future<int?> _getCurrentRideId() async {
    try {
      final response = await _apiService.get(PassengerEndpoints.current);

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final bool hasActiveRide = data['has_active_ride'] ?? false;

        if (hasActiveRide) {
          final rideData = data['ride'] ?? {};
          final id = rideData['id'];
          if (id is int) return id;
          if (id != null) return int.tryParse(id.toString());
          return null;
        }
      }
      return null;
    } catch (e) {
      Logger.error(
        'Error getting current ride ID',
        error: e,
        tag: 'UserTracking',
      );
      return null;
    }
  }

  // Handle incoming WebSocket messages for ride tracking
  void _handleWebSocketMessage(Map<String, dynamic> data) {
    if (!mounted) return;
    try {
      final eventType = data['type'] as String?;
      if (eventType == null) return;

      // Deduplicate events that may be delivered twice (user_<id> and ride_<id>)
      if (eventType != 'driver_track_location') {
        final rideIdKey = data['ride_id']?.toString() ?? _currentRideId ?? '';
        final dedupeKey = '${eventType}_$rideIdKey';

        if (_processedRideEvents.contains(dedupeKey)) return;
        _processedRideEvents.add(dedupeKey);
      }

      Logger.websocket(
        'Tracking WS message event: $eventType',
        tag: 'UserTracking',
      );

      switch (eventType) {
        case 'driver_track_location':
          // update driver position on map
          double? lat;
          double? lng;
          final latRaw = data['latitude'];
          final lngRaw = data['longitude'];
          if (latRaw is num) {
            lat = latRaw.toDouble();
          } else {
            lat = double.tryParse('$latRaw');
          }
          if (lngRaw is num) {
            lng = lngRaw.toDouble();
          } else {
            lng = double.tryParse('$lngRaw');
          }

          if (lat != null && lng != null) {
            safeSetState(() {
              _driverPosition = LatLng(lat!, lng!);
            });
          }
          break;

        case 'ride_cancelled':
          safeSetState(() {
            _status = 'cancelled';
          });

          final cancelMsg = data['message'] ?? 'Ride cancelled by driver';

          // Show popup dialog instead of snackbar
          showDialog(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Text('Ride Cancelled'),
              content: Text(cancelMsg),
              actions: [
                TextButton(
                  onPressed: () async {
                    Navigator.of(ctx).pop(); // close dialog

                    // Stop tracking and cancel subscription safely
                    try {
                      _sendStopTracking();
                    } catch (_) {}

                    try {
                      await _wsSubscription?.cancel();
                    } catch (e) {
                      Logger.error(
                        'Error cancelling tracking subscription on ride_cancelled',
                        error: e,
                        tag: 'UserTracking',
                      );
                    }
                    if (!mounted) return;
                    // Navigate back to main UserMapScreen
                    AppRouter.pushReplacement(
                      context,
                      const UserMapScreen(),
                    );
                  },
                  child: const Text('OK'),
                ),
              ],
            ),
          );

          break;

        case 'ride_completed':
          safeSetState(() {
            _status = 'completed';
          });

          // Show a modal dialog so the passenger notices completion
          if (!mounted) return;
          showDialog(
            context: context,
            barrierDismissible: true,
            builder: (ctx) => AlertDialog(
              title: const Text('Ride Completed'),
              content: Text(data['message'] ?? 'Your ride has been completed.'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('OK'),
                ),
              ],
            ),
          ).then((_) async {
            if (!mounted) return;

            // Stop tracking and cancel local subscription before navigating
            try {
              _sendStopTracking();
            } catch (_) {}

            try {
              await _wsSubscription?.cancel();
            } catch (e) {
              Logger.error(
                'Error cancelling tracking subscription on ride_completed',
                error: e,
                tag: 'UserTracking',
              );
            }
            if (!mounted) return;
            // Navigate back to main UserMapScreen so user lands on the map
            AppRouter.pushReplacement(
              context,
              const UserMapScreen(),
            );
          });
          break;
        // ignore other events
      }
    } catch (e) {
      Logger.error(
        'Error decoding tracking WS message: $e | raw=$data',
        tag: 'UserTracking',
      );
    }
  }

  // ============================================================
  // Cancel current ride
  // ============================================================
  Future<bool> _cancelRide() async {
    try {
      // First get the current ride ID
      final rideId = await _getCurrentRideId();

      if (rideId == null) {
        Logger.warning('No active ride found to cancel', tag: 'UserTracking');
        return false;
      }

      Logger.info('Attempting to cancel ride $rideId...', tag: 'UserTracking');

      final response = await _apiService.post(
        PassengerEndpoints.cancel(rideId),
        body: {},
      );

      Logger.network(
        'Cancel response status: ${response.statusCode}',
        tag: 'UserTracking',
      );
      Logger.debug(
        'Cancel response body: ${response.body}',
        tag: 'UserTracking',
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        Logger.info(
          'Ride cancelled successfully: ${data['message'] ?? 'No message'}',
          tag: 'UserTracking',
        );
        return true;
      } else {
        Logger.error(
          'Failed to cancel ride: ${response.body}',
          tag: 'UserTracking',
        );
        return false;
      }
    } catch (e) {
      Logger.error('Error cancelling ride', error: e, tag: 'UserTracking');
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('User Tracking'),
        backgroundColor: Colors.blueAccent,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () {
            Logger.debug(
              'Navigating back from tracking to user page',
              tag: 'UserTracking',
            );

            // Cancel local subscription only - WebSocket service persists
            _wsSubscription?.cancel();

            // Navigate back to UserMapScreen with proper parameters
            AppRouter.pushReplacement(
              context,
              const UserMapScreen(),
            );
          },
        ),
      ),
      body: _userPosition == null
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                // ----------- RIDE DETAILS HEADER ------------
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.blue[50],
                    border: Border(
                      bottom: BorderSide(color: Colors.blue[200]!),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Header row
                      Row(
                        children: [
                          const Icon(Icons.local_taxi, color: Colors.blue),
                          const SizedBox(width: 8),
                          const Text(
                            'Ride Details',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              color: Colors.blue,
                            ),
                          ),
                          const Spacer(),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: _status == 'completed'
                                  ? Colors.green
                                  : _status == 'cancelled' ||
                                        _status == 'no_drivers'
                                  ? Colors.red
                                  : _status == 'pending'
                                  ? Colors.orange
                                  : Colors.blue,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Text(
                              _status.toUpperCase(),
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                                fontSize: 12,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          const Icon(Icons.person, size: 16),
                          const SizedBox(width: 8),
                          Expanded(child: Text('Driver: $_username')),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          const Icon(Icons.phone, size: 16),
                          const SizedBox(width: 8),
                          Expanded(child: Text('Phone: $_phoneNumber')),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          const Icon(Icons.directions_car, size: 16),
                          const SizedBox(width: 8),
                          Expanded(child: Text('Vehicle: $_vehicleNumber')),
                        ],
                      ),
                      const SizedBox(height: 16),
                      // Cancel button
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed:
                              (_status == 'completed' || _status == 'cancelled')
                              ? null
                              : () async {
                                  Logger.info(
                                    'User cancelled ride from tracking page',
                                    tag: 'UserTracking',
                                  );

                                  // Show confirmation dialog first
                                  final bool?
                                  shouldCancel = await showDialog<bool>(
                                    context: context,
                                    builder: (BuildContext context) {
                                      return AlertDialog(
                                        title: const Text('Cancel Ride?'),
                                        content: const Text(
                                          'Are you sure you want to cancel this ride? The driver has already been assigned.',
                                        ),
                                        actions: [
                                          TextButton(
                                            onPressed: () =>
                                                AppRouter.pop(context, false),
                                            child: const Text('No, Keep Ride'),
                                          ),
                                          TextButton(
                                            onPressed: () =>
                                                AppRouter.pop(context, true),
                                            child: const Text(
                                              'Yes, Cancel',
                                              style: TextStyle(
                                                color: Colors.red,
                                              ),
                                            ),
                                          ),
                                        ],
                                      );
                                    },
                                  );

                                  if (!context.mounted) return;

                                  if (shouldCancel != true) return;

                                  // Show loading indicator
                                  showDialog(
                                    context: context,
                                    barrierDismissible: false,
                                    builder: (BuildContext context) {
                                      return const AlertDialog(
                                        content: Row(
                                          children: [
                                            CircularProgressIndicator(),
                                            SizedBox(width: 20),
                                            Text('Cancelling ride...'),
                                          ],
                                        ),
                                      );
                                    },
                                  );

                                  // Attempt to cancel the ride
                                  final success = await _cancelRide();

                                  if (!context.mounted) return;

                                  // Close loading dialog
                                  AppRouter.pop(context);

                                  if (success) {
                                    _errorService.showSuccess(
                                      context,
                                      'Ride cancelled successfully',
                                    );

                                    // Cancel local listener and navigate back to UserMapScreen
                                    _wsSubscription?.cancel();

                                    AppRouter.pushReplacement(
                                      context,
                                      const UserMapScreen(),
                                    );
                                  } else {
                                    _errorService.showError(
                                      context,
                                      'Failed to cancel ride. Please try again.',
                                    );
                                  }
                                },
                          icon: Icon(
                            Icons.cancel,
                            color:
                                (_status == 'completed' ||
                                    _status == 'cancelled')
                                ? Colors.grey
                                : Colors.red,
                          ),
                          label: Text(
                            (_status == 'completed')
                                ? 'Ride Completed'
                                : (_status == 'cancelled')
                                ? 'Ride Cancelled'
                                : 'Cancel Ride',
                            style: TextStyle(
                              color:
                                  (_status == 'completed' ||
                                      _status == 'cancelled')
                                  ? Colors.grey
                                  : Colors.red,
                            ),
                          ),
                          style: OutlinedButton.styleFrom(
                            side: BorderSide(
                              color:
                                  (_status == 'completed' ||
                                      _status == 'cancelled')
                                  ? Colors.grey
                                  : Colors.red,
                              width: 1.5,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                            padding: const EdgeInsets.symmetric(vertical: 12),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

                // ------------------- MAP SECTION -------------------
                Expanded(
                  flex: 1,
                  child: FlutterMap(
                    options: MapOptions(
                      initialCenter: _userPosition!,
                      initialZoom: 14,
                    ),
                    children: [
                      TileLayer(
                        urlTemplate:
                            'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                        userAgentPackageName: 'com.example.erick_app',
                        tileProvider: kIsWeb
                            ? CancellableNetworkTileProvider()
                            : NetworkTileProvider(),
                      ),
                      MarkerLayer(
                        markers: [
                          Marker(
                            point: _userPosition!,
                            width: 80,
                            height: 80,
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: const [
                                Icon(
                                  Icons.person_pin_circle,
                                  color: Colors.green,
                                  size: 35,
                                ),
                                Text(
                                  "You",
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 10,
                                    color: Colors.green,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          if (_driverPosition != null)
                            Marker(
                              point: _driverPosition!,
                              width: 80,
                              height: 80,
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: const [
                                  Icon(
                                    Icons.local_taxi,
                                    color: Colors.blue,
                                    size: 35,
                                  ),
                                  Text(
                                    "Driver",
                                    style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 10,
                                      color: Colors.blue,
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
              ],
            ),
    );
  }
}
