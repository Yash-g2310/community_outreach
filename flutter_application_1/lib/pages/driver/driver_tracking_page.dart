import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_map_cancellable_tile_provider/flutter_map_cancellable_tile_provider.dart';
import 'package:latlong2/latlong.dart';
import 'dart:async';
import 'driver_page.dart';
import '../../config/api_endpoints.dart';
import '../../services/websocket_service.dart';
import '../../services/api_service.dart';
import '../../services/auth_service.dart';
import '../../services/logger_service.dart';
import '../../services/error_service.dart';
import '../../services/location_service.dart';
import '../../router/app_router.dart';
import '../../core/mixins/safe_state_mixin.dart';
import '../../config/app_constants.dart';

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
  });

  @override
  State<RideTrackingPage> createState() => _RideTrackingPageState();
}

class _RideTrackingPageState extends State<RideTrackingPage>
    with SafeStateMixin {
  LatLng? _currentPosition;
  String _rideStatus = 'accepted';
  bool _isLoading = false;
  Timer? _locationTimer;
  final WebSocketService _wsService = WebSocketService();
  StreamSubscription? _wsSubscription;
  final ErrorService _errorService = ErrorService();
  final ApiService _apiService = ApiService();
  final AuthService _authService = AuthService();

  // API Configuration uses centralized base URL from constants

  @override
  void initState() {
    super.initState();

    // Ensure WebSocket is connected (it should already be from driver_page)
    _connectDriverSocket();

    // Subscribe to driver messages from WebSocket service
    _wsSubscription = _wsService.driverMessages.listen((data) {
      if (!mounted) return;
      _handleWebSocketMessage(data);
    });

    _setupTracking();
  }

  Future<void> _connectDriverSocket() async {
    final authState = await _authService.getAuthState();
    if (authState.isAuthenticated) {
      _wsService.connectDriver(jwtToken: authState.accessToken);
    }
  }

  @override
  void dispose() {
    // Cancel location timer safely
    try {
      _locationTimer?.cancel();
      _locationTimer = null;
    } catch (e) {
      Logger.error(
        'Error cancelling location timer',
        error: e,
        tag: 'DriverTracking',
      );
    }

    _sendStopTracking();

    // Cancel WebSocket subscription safely
    try {
      _wsSubscription?.cancel();
      _wsSubscription = null;
    } catch (e) {
      Logger.error(
        'Error cancelling tracking subscription',
        error: e,
        tag: 'DriverTracking',
      );
    }

    super.dispose();
  }

  Future<void> _setupTracking() async {
    await _getCurrentLocation(); // Get initial location
    _startLocationUpdates(); // Start every 10 seconds
    _sendStartTracking(); // Now start listening to WS messages
  }

  Future<void> _getCurrentLocation() async {
    try {
      final locationService = LocationService();
      final location = await locationService.getCurrentLocation();

      if (location == null || !mounted) return;

      safeSetState(() {
        _currentPosition = location;
      });
    } catch (e) {
      Logger.error(
        'Error getting current location',
        error: e,
        tag: 'DriverTracking',
      );
    }
  }

  // Location updates only, ride status handled by WebSocket
  void _startLocationUpdates() {
    _locationTimer = Timer.periodic(TimerConstants.locationUpdateInterval, (
      timer,
    ) {
      _getCurrentLocation();
    });
  }

  // Listen for WebSocket ride tracking events
  void _sendStartTracking() {
    // Send start_tracking via WebSocket service
    try {
      _wsService.sendDriverMessage({
        'type': 'start_tracking',
        'ride_id': widget.rideId,
      });
      Logger.websocket(
        "Driver Tracking Page: Sent start_tracking",
        tag: 'DriverTracking',
      );
    } catch (e) {
      Logger.error(
        "Driver Tracking Page: Error sending start_tracking",
        error: e,
        tag: 'DriverTracking',
      );
    }
  }

  // Send stop_tracking message to leave ride group (optional, e.g. on dispose)
  void _sendStopTracking() {
    try {
      _wsService.sendDriverMessage({
        'type': 'stop_tracking',
        'ride_id': widget.rideId,
      });
      Logger.websocket(
        'Sent stop_tracking for ride ${widget.rideId}',
        tag: 'DriverTracking',
      );
    } catch (e) {
      Logger.error(
        'Error sending stop_tracking',
        error: e,
        tag: 'DriverTracking',
      );
    }
  }

  void _handleWebSocketMessage(Map<String, dynamic> data) {
    if (!mounted) return;
    try {
      final eventType = data['type'] as String?;
      if (eventType == null) return;

      final messenger = ScaffoldMessenger.of(context);

      switch (eventType) {
        case 'ride_cancelled':
          safeSetState(() => _rideStatus = 'cancelled');

          final msg = data['message'] ?? 'Ride cancelled';
          messenger.showSnackBar(
            SnackBar(backgroundColor: Colors.orange, content: Text(msg)),
          );

          Future.delayed(UIConstants.shortDelay, () async {
            if (!mounted) return;
            // For drivers, navigate back to the main DriverPage instead of
            // popping (which can expose a previous auth/login route).
            try {
              _wsService.sendDriverMessage({
                'type': 'stop_tracking',
                'ride_id': widget.rideId,
              });
            } catch (e) {
              Logger.error(
                'Error sending stop_tracking',
                error: e,
                tag: 'DriverTracking',
              );
            }

            if (!mounted) return;

            AppRouter.pushReplacement(
              context,
              const DriverPage(),
            );
          });
          break;

        case 'ride_expired':
          safeSetState(() => _rideStatus = 'expired');

          final msg = data['message'] ?? 'Ride offer expired';
          messenger.showSnackBar(
            SnackBar(backgroundColor: Colors.red, content: Text(msg)),
          );

          Future.delayed(UIConstants.shortDelay, () {
            if (mounted) AppRouter.pop(context);
          });
          break;

        case 'ride_completed':
          safeSetState(() => _rideStatus = 'completed');

          // Stop tracking best-effort
          try {
            _wsService.sendDriverMessage({
              'type': 'stop_tracking',
              'ride_id': widget.rideId,
            });
          } catch (_) {}

          if (!mounted) return;
          AppRouter.pushReplacement(
            context,
            const DriverPage(),
          );
          break;

        default:
          // ignore all unrelated events
          break;
      }
    } catch (e) {
      Logger.error(
        'Error decoding WS message: $e | raw=$data',
        tag: 'DriverTracking',
      );
    }
  }

  Future<void> _completeRide() async {

    safeSetState(() {
      _isLoading = true;
    });

    try {
      final response = await _apiService.post(
        RideHandlingEndpoints.complete(widget.rideId),
      );

      if (!mounted) return;

      if (response.statusCode == 200) {
        safeSetState(() {
          _rideStatus = 'completed';
        });

        _errorService.showSuccess(context, 'Ride completed successfully! ✅');

        // Navigate back to driver page after short delay
        Future.delayed(const Duration(seconds: 2), () async {
          if (!mounted) return;

          // Best-effort: stop tracking
          try {
            _wsService.sendDriverMessage({
              'type': 'stop_tracking',
              'ride_id': widget.rideId,
            });
          } catch (_) {}

          try {
            _wsSubscription?.cancel();
          } catch (_) {}

          Navigator.pushReplacement(
            context,
            MaterialPageRoute(
              builder: (context) => const DriverPage(),
            ),
          );
        });
      } else {
        throw Exception('Failed to complete ride: ${response.statusCode}');
      }
    } catch (e) {
      if (mounted) {
        _errorService.showError(context, 'Error completing ride: $e');
      }
    } finally {
      if (mounted) {
        safeSetState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _cancelRide() async {

    // Ask user for confirmation
    final shouldCancel = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Cancel Ride'),
        content: const Text('Are you sure you want to cancel this ride?'),
        actions: [
          TextButton(
            onPressed: () => AppRouter.pop(context, false),
            child: const Text('No'),
          ),
          TextButton(
            onPressed: () => AppRouter.pop(context, true),
            child: const Text('Yes', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (!mounted) return;

    // If the user chooses "No", stay on the same page
    if (shouldCancel != true) {
      Logger.debug('Ride cancellation aborted by user.', tag: 'DriverTracking');
      return;
    }

    safeSetState(() {
      _isLoading = true;
    });

    try {
      // Correct endpoint (adjusted to match your Django URLs)
      Logger.debug(
        'Sending cancel request to: ${RideHandlingEndpoints.driverCancel(widget.rideId)}',
        tag: 'DriverTracking',
      );

      final response = await _apiService.post(
        RideHandlingEndpoints.driverCancel(widget.rideId),
      );

      // 🧾 Log the raw response for debugging
      Logger.network(
        'Cancel Ride Response Code: ${response.statusCode}',
        tag: 'DriverTracking',
      );
      Logger.debug(
        'Cancel Ride Response Body: ${response.body}',
        tag: 'DriverTracking',
      );

      if (!mounted) return;

      if (response.statusCode == 200) {
        Logger.info('Ride cancelled successfully.', tag: 'DriverTracking');

        safeSetState(() {
          _rideStatus = 'cancelled';
        });

        _errorService.showSuccess(context, 'Ride cancelled successfully');

        // Navigate back to driver page after short delay
        Future.delayed(const Duration(seconds: 2), () async {
          if (!mounted) return;

          // Best-effort: stop tracking
          try {
            _wsService.sendDriverMessage({
              'type': 'stop_tracking',
              'ride_id': widget.rideId,
            });
          } catch (_) {}

          try {
            _wsSubscription?.cancel();
          } catch (_) {}

          Navigator.pushReplacement(
            context,
            MaterialPageRoute(
              builder: (context) => const DriverPage(),
            ),
          );
        });
      } else {
        // Non-success status code — log details
        throw Exception(
          'Failed to cancel ride: ${response.statusCode} | ${response.body}',
        );
      }
    } catch (e) {
      Logger.error('Error cancelling ride', error: e, tag: 'DriverTracking');
      if (mounted) {
        _errorService.showError(context, 'Error cancelling ride: $e');
      }
    } finally {
      if (mounted) {
        safeSetState(() {
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Driver - Ride #${widget.rideId}'),
        backgroundColor: Colors.blue[700],
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
                    color: Colors.blue[50],
                    border: Border(
                      bottom: BorderSide(color: Colors.blue[200]!),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Icons.info_outline,
                            color: Colors.blue[700],
                            size: 20,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            'Ride Details',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              color: Colors.blue[700],
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
                      if (widget.passengerName != null) ...[
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
                        tileProvider: kIsWeb
                            ? CancellableNetworkTileProvider()
                            : NetworkTileProvider(),
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
                                      color: Colors.blue,
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: Text(
                                      'Driver',
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 10,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                  Icon(
                                    Icons.local_taxi,
                                    color: Colors.blue,
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
