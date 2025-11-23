import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:async';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/status.dart' as ws_status;
import 'package:web_socket_channel/web_socket_channel.dart';
import 'profile.dart';
import 'ride_tracking_page.dart';
import 'previous_rides.dart';
import 'utils/socket_channel_factory.dart';

void main() {
  runApp(const ERickDriverApp());
}

class ERickDriverApp extends StatelessWidget {
  final String? jwtToken;
  final Map<String, dynamic>? userData;

  const ERickDriverApp({super.key, this.jwtToken, this.userData});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: DriverPage(jwtToken: jwtToken, userData: userData),
    );
  }
}

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

  // API Configuration
  static const String baseUrl = 'http://localhost:8000';

  List<Map<String, dynamic>> notifications = [];
  Set<int> _rejectedRideIds = {}; // Local storage for rejected ride IDs
  WebSocketChannel? _driverSocket;
  StreamSubscription? _driverSocketSubscription;
  Timer? _socketReconnectTimer;
  bool _shouldMaintainSocket = true;
  bool _isSocketConnected = false;
  String? _socketStatusMessage;
  int _socketReconnectAttempts = 0;
  int _socketFailureCount = 0;
  DateTime? _lastSocketMessageAt;
  DateTime? _lastRideReceivedAt;
  String? _lastSocketError;

  @override
  void initState() {
    super.initState();
    _loadRejectedRides(); // Load rejected rides from local storage
    _loadDriverData();
    _initializeLocation();
    _initializeDriverSocket();
  }

  @override
  void dispose() {
    _shouldMaintainSocket = false;
    _socketReconnectTimer?.cancel();
    _cancelDriverSocket();
    _locationUpdateTimer?.cancel();
    super.dispose();
  }

  Future<void> _initializeLocation() async {
    try {
      // Check location permission
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          print('Location permissions are denied');
          return;
        }
      }

      if (permission == LocationPermission.deniedForever) {
        print('Location permissions are permanently denied');
        return;
      }

      // Get current location
      await _getCurrentLocation();

      // Location updates will be started after loading driver profile
    } catch (e) {
      print('Error initializing location: $e');
    }
  }

  Future<void> _getCurrentLocation() async {
    try {
      Position position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );
      _currentPosition = position;

      // Update map position
      setState(() {
        _mapPosition = LatLng(position.latitude, position.longitude);
      });

      print('Current location: ${position.latitude}, ${position.longitude}');
    } catch (e) {
      print('Error getting current location: $e');
    }
  }

  void _startLocationUpdates() {
    // Cancel existing timer if any
    _locationUpdateTimer?.cancel();

    _locationUpdateTimer = Timer.periodic(const Duration(seconds: 10), (
      timer,
    ) async {
      await _updateDriverLocation();
    });

    print('Location update timer started');
  }

  void _stopLocationUpdates() {
    _locationUpdateTimer?.cancel();
    _locationUpdateTimer = null;
    print('Location update timer stopped');
  }

  void _logDriver(String message, {String tag = 'Driver'}) {
    if (!kDebugMode) return;
    debugPrint('[$tag] $message');
  }

  void _logSocket(String message) => _logDriver(message, tag: 'DriverSocket');

  String _formatTimestamp(DateTime? timestamp) {
    if (timestamp == null) return 'never';
    final local = timestamp.toLocal();
    final hh = local.hour.toString().padLeft(2, '0');
    final mm = local.minute.toString().padLeft(2, '0');
    final ss = local.second.toString().padLeft(2, '0');
    return '$hh:$mm:$ss';
  }

  bool get _canUseDriverSocket => (widget.sessionId?.isNotEmpty ?? false);

  String get _driverSocketUrl {
    final sanitizedBase = baseUrl.replaceFirst(RegExp(r'^https?://'), '');
    final scheme = baseUrl.startsWith('https') ? 'wss://' : 'ws://';

    final uri = Uri.parse('$scheme$sanitizedBase/ws/app/');

    final queryParams = <String, String>{};

    // mobile app – JWT token
    if (widget.jwtToken?.isNotEmpty ?? false) {
      queryParams['token'] = widget.jwtToken!;
    }

    // chrome testing – sessionid + csrftoken
    if (widget.sessionId?.isNotEmpty ?? false) {
      queryParams['sessionid'] = widget.sessionId!;
    }
    if (widget.csrfToken?.isNotEmpty ?? false) {
      queryParams['csrftoken'] = widget.csrfToken!;
    }

    return uri.replace(queryParameters: queryParams).toString();
  }

  String _buildCookieHeader() {
    final cookies = <String>[];
    if (widget.sessionId != null && widget.sessionId!.isNotEmpty) {
      cookies.add('sessionid=${widget.sessionId}');
    }
    if (widget.csrfToken != null && widget.csrfToken!.isNotEmpty) {
      cookies.add('csrftoken=${widget.csrfToken}');
    }
    return cookies.join('; ');
  }

  void _initializeDriverSocket() {
    if (!_canUseDriverSocket) {
      _socketStatusMessage =
          'Realtime updates unavailable (missing session cookie)';
      _logSocket('Skipping WS init - missing session cookie');
      return;
    }

    _socketStatusMessage = 'Connecting to live ride updates...';
    _logSocket('Initializing driver WebSocket connection');
    _connectDriverSocket();
  }

  void _connectDriverSocket({bool isReconnect = false}) {
    if (!_canUseDriverSocket || !_shouldMaintainSocket) {
      _logSocket(
        'WS connect aborted - allowed=$_canUseDriverSocket maintain=$_shouldMaintainSocket',
      );
      return;
    }

    _socketReconnectTimer?.cancel();

    final cookieHeader = _buildCookieHeader();
    final headers = <String, dynamic>{};
    if (cookieHeader.isNotEmpty) {
      headers['Cookie'] = cookieHeader;
    }

    _logSocket('Connecting to $_driverSocketUrl (retry=$isReconnect)');

    try {
      final channel = createPlatformWebSocket(
        Uri.parse(_driverSocketUrl),
        headers: headers.isEmpty ? null : headers,
      );

      _driverSocketSubscription?.cancel();
      _driverSocketSubscription = channel.stream.listen(
        _handleSocketMessage,
        onError: _handleSocketError,
        onDone: () => _handleSocketClosed(null, null),
        cancelOnError: false,
      );

      _driverSocket = channel;

      _safeSetState(() {
        _isSocketConnected = true;
        _socketStatusMessage = isReconnect
            ? 'Reconnected to live ride updates'
            : 'Connected to live ride updates';
        _socketReconnectAttempts = 0;
        _lastSocketError = null;
      });
      _socketFailureCount = 0;
      _lastSocketMessageAt = DateTime.now();
      _logSocket('WebSocket connection opened (reconnect=$isReconnect)');
    } catch (error) {
      _handleSocketError(error);
    }
  }

  void _handleSocketMessage(dynamic message) {
    try {
      final rawPayload = message is String ? message : message.toString();
      final data = json.decode(rawPayload) as Map<String, dynamic>;
      final eventType = data['type'] as String?;
      _lastSocketMessageAt = DateTime.now();
      _socketStatusMessage = 'Listening for ride updates';
      _lastSocketError = null;
      _logSocket('Message <- ${eventType ?? 'unknown'}');

      if (eventType == null) {
        return;
      }

      switch (eventType) {
        case 'connection_established':
          _safeSetState(() {
            _socketStatusMessage = data['message'] ?? 'Connected';
          });
          break;
        case 'ride_offer':
          final rideData = data['ride_data'];
          final offerId = data['offer_id'];
          if (rideData is Map && offerId != null) {
            _handleRideOffer(Map<String, dynamic>.from(rideData), offerId);
          } else {
            _logSocket('Malformed ride offer payload');
          }
          break;
        case 'new_ride_request':
          final rideData = data['ride'];
          if (rideData is Map) {
            _handleIncomingRide(Map<String, dynamic>.from(rideData));
          } else {
            _logSocket('Malformed ride payload: ${rideData.runtimeType}');
          }
          break;
        case 'ride_cancelled':
        case 'ride_accepted':
        case 'ride_expired':
          _handleRideRemoval(
            data['ride_id'],
            data['message'] ??
                (eventType == 'ride_cancelled'
                    ? 'Ride cancelled by passenger'
                    : eventType == 'ride_expired'
                    ? 'Ride offer timed out'
                    : 'Ride accepted by another driver'),
          );
          break;
        case 'pong':
          break;
        default:
          print('Unhandled WS event: $data');
      }
    } catch (e) {
      print('Error decoding driver WS message: $e | raw=$message');
    }
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
    _lastRideReceivedAt = DateTime.now();
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

  void _handleRideOffer(Map<String, dynamic> rideData, int offerId) {
    final rideId = rideData['id'];
    if (rideId == null) {
      _logSocket('Ride offer missing ID: $rideData');
      return;
    }

    if (_rejectedRideIds.contains(rideId)) {
      _logSocket('Ignoring ride offer $rideId - previously rejected');
      return;
    }

    // Show offer dialog with timer
    _showRideOfferDialog(rideData, offerId);
  }

  void _showRideOfferDialog(Map<String, dynamic> rideData, int offerId) {
    int remainingSeconds = 20;
    Timer? countdownTimer;

    showDialog(
      context: context,
      barrierDismissible: false, // Prevent dismissing by tapping outside
      builder: (BuildContext context) {
        return StatefulBuilder(
          builder: (context, setState) {
            countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
              setState(() {
                remainingSeconds--;
                if (remainingSeconds <= 0) {
                  timer.cancel();
                  Navigator.of(context).pop(); // Close dialog
                  _rejectOffer(offerId, rideData['id']);
                }
              });
            });

            return AlertDialog(
              title: const Text('🚗 New Ride Offer'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Pickup: ${rideData['pickup_address'] ?? 'N/A'}'),
                  Text('Dropoff: ${rideData['dropoff_address'] ?? 'N/A'}'),
                  Text('Passengers: ${rideData['number_of_passengers'] ?? 1}'),
                  const SizedBox(height: 10),
                  Text(
                    'Time remaining: $remainingSeconds seconds',
                    style: TextStyle(
                      color: remainingSeconds <= 5 ? Colors.red : Colors.black,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  LinearProgressIndicator(
                    value: remainingSeconds / 20.0,
                    backgroundColor: Colors.grey[300],
                    valueColor: AlwaysStoppedAnimation<Color>(
                      remainingSeconds <= 5 ? Colors.red : Colors.green,
                    ),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () {
                    countdownTimer?.cancel();
                    Navigator.of(context).pop();
                    _rejectOffer(offerId, rideData['id']);
                  },
                  child: const Text('Reject'),
                ),
                ElevatedButton(
                  onPressed: () {
                    countdownTimer?.cancel();
                    Navigator.of(context).pop();
                    _acceptOffer(offerId, rideData['id']);
                  },
                  child: const Text('Accept'),
                ),
              ],
            );
          },
        );
      },
    ).then((_) {
      countdownTimer?.cancel(); // Ensure timer is cancelled when dialog closes
    });
  }

  Future<void> _acceptOffer(int offerId, int rideId) async {
    if (widget.jwtToken == null) return;

    setState(() {
      isLoading = true;
    });

    try {
      final response = await http.post(
        Uri.parse('$baseUrl/api/rides/handle/$rideId/accept/'),
        headers: {
          'Authorization': 'Bearer ${widget.jwtToken}',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({'offer_id': offerId}), // Include offer_id in request
      );

      if (!mounted) return;

      if (response.statusCode == 200) {
        _showSnackBar(
          'Ride offer accepted successfully! ✅',
          backgroundColor: Colors.green,
        );

        // Navigate to ride tracking page
        final rideData = jsonDecode(response.body);
        if (mounted) {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => RideTrackingPage(
                rideId: rideId,
                pickupAddress: rideData['pickup_address'] ?? 'N/A',
                dropoffAddress: rideData['dropoff_address'] ?? 'N/A',
                numberOfPassengers: rideData['number_of_passengers'] ?? 1,
                passengerName: rideData['passenger']['username'] ?? 'Passenger',
                passengerPhone: rideData['passenger']['phone_number'] ?? 'N/A',
                vehicleNumber: driverProfile?['vehicle_number'] ?? 'N/A',
                isDriver: true,
              ),
            ),
          );
        }
      } else {
        final errorData = jsonDecode(response.body);
        _showSnackBar(
          'Failed to accept offer: ${errorData['message'] ?? 'Unknown error'}',
          backgroundColor: Colors.red,
        );
      }
    } catch (e) {
      _showSnackBar('Error accepting offer: $e', backgroundColor: Colors.red);
    } finally {
      _safeSetState(() {
        isLoading = false;
      });
    }
  }

  Future<void> _rejectOffer(int offerId, int rideId) async {
    if (widget.jwtToken == null) return;

    try {
      final response = await http.post(
        Uri.parse('$baseUrl/api/rides/handle/$rideId/reject/'),
        headers: {
          'Authorization': 'Bearer ${widget.jwtToken}',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({'offer_id': offerId}), // Include offer_id in request
      );

      if (response.statusCode == 200) {
        _showSnackBar(
          'Ride offer rejected',
          backgroundColor: Colors.orange,
        );
      } else {
        final errorData = jsonDecode(response.body);
        _showSnackBar(
          'Failed to reject offer: ${errorData['message'] ?? 'Unknown error'}',
          backgroundColor: Colors.red,
        );
      }
    } catch (e) {
      _showSnackBar('Error rejecting offer: $e', backgroundColor: Colors.red);
    }
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

  void _handleSocketError(dynamic error) {
    _logSocket('Error: $error');
    _driverSocketSubscription?.cancel();
    _driverSocketSubscription = null;
    _driverSocket = null;
    _socketFailureCount += 1;
    _lastSocketError = '$error';

    _safeSetState(() {
      _isSocketConnected = false;
      _socketStatusMessage =
          'Realtime connection lost - retrying (fail=$_socketFailureCount)';
    });

    _scheduleSocketReconnect();
  }

  void _handleSocketClosed(int? code, String? reason) {
    _logSocket('Closed code=$code reason=$reason');
    _driverSocketSubscription?.cancel();
    _driverSocketSubscription = null;
    _driverSocket = null;

    _safeSetState(() {
      _isSocketConnected = false;
      _socketStatusMessage = 'Realtime connection closed';
    });

    _scheduleSocketReconnect();
  }

  void _scheduleSocketReconnect() {
    if (!_shouldMaintainSocket || !_canUseDriverSocket) {
      _logSocket(
        'Reconnect suppressed - shouldMaintain=$_shouldMaintainSocket canUse=$_canUseDriverSocket',
      );
      return;
    }

    _socketReconnectTimer?.cancel();
    _socketReconnectAttempts += 1;
    _logSocket('Scheduling reconnect attempt #$_socketReconnectAttempts');
    _socketReconnectTimer = Timer(const Duration(seconds: 5), () {
      if (!_shouldMaintainSocket) return;
      _connectDriverSocket(isReconnect: true);
    });
  }

  void _manualSocketReconnect() {
    if (!_canUseDriverSocket) return;
    _socketReconnectTimer?.cancel();
    _cancelDriverSocket();
    _logSocket('Manual reconnect triggered by driver');
    _connectDriverSocket(isReconnect: true);
  }

  void _cancelDriverSocket() {
    _driverSocketSubscription?.cancel();
    _driverSocketSubscription = null;
    _driverSocket?.sink.close(ws_status.normalClosure);
    _driverSocket = null;
    _logSocket('Socket resources disposed');
  }

  void _safeSetState(VoidCallback fn) {
    if (!mounted) return;
    setState(fn);
  }

  void _showSnackBar(String message, {Color backgroundColor = Colors.black87}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: backgroundColor),
    );
  }

  Future<void> _updateDriverLocation() async {
    print('=== LOCATION UPDATE STARTED ===');

    // Check if driver is online before sending location updates
    if (!isActive) {
      print('Driver is offline - skipping location update');
      print('=== LOCATION UPDATE SKIPPED ===');
      return;
    }

    // ALWAYS get fresh GPS location before sending update
    print('Getting fresh GPS location...');
    await _getCurrentLocation();

    if (_currentPosition != null) {
      try {
        // Truncate coordinates to 6 decimal places
        double truncatedLatitude = double.parse(
          _currentPosition!.latitude.toStringAsFixed(6),
        );
        double truncatedLongitude = double.parse(
          _currentPosition!.longitude.toStringAsFixed(6),
        );

        print(
          'Sending location update: $truncatedLatitude, $truncatedLongitude',
        );

        // Use the JWT token from widget (same as other API calls)
        String? token = widget.jwtToken;

        if (token != null) {
          print('Token available, making API call...');
          final response = await http.put(
            Uri.parse('$baseUrl/api/rides/driver/location/'),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $token',
            },
            body: json.encode({
              'latitude': truncatedLatitude,
              'longitude': truncatedLongitude,
            }),
          );

          print('API Response: ${response.statusCode}');
          if (response.statusCode == 200) {
            print(
              'Location updated successfully: $truncatedLatitude, $truncatedLongitude',
            );
          } else {
            print('Failed to update location: ${response.statusCode}');
            print('Response: ${response.body}');
          }
        } else {
          print('ERROR: No JWT token available for location update');
        }
      } catch (e) {
        print('Error updating driver location: $e');
      }
    } else {
      print('ERROR: Could not get current position');
    }

    print('=== LOCATION UPDATE FINISHED ===');
  }

  Future<void> _loadDriverData() async {
    if (widget.jwtToken == null) {
      setState(() {
        errorMessage = 'No authentication token found';
      });
      return;
    }

    setState(() {
      isLoading = true;
      errorMessage = null;
    });

    try {
      // Load driver profile first, then nearby rides (need profile for fallback location)
      await _fetchDriverProfile();
      await _fetchNearbyRides();

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

      setState(() {
        _rejectedRideIds = rejectedList
            .map((id) => int.tryParse(id))
            .where((id) => id != null)
            .cast<int>()
            .toSet();
      });

      print(
        'Loaded ${_rejectedRideIds.length} rejected rides from local storage: $_rejectedRideIds',
      );
    } catch (e) {
      print('Error loading rejected rides: $e');
      setState(() {
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
      print('Saved ${_rejectedRideIds.length} rejected rides to local storage');
    } catch (e) {
      print('Error saving rejected rides: $e');
    }
  }

  // Add a ride ID to rejected list
  Future<void> _addRejectedRide(int rideId) async {
    setState(() {
      _rejectedRideIds.add(rideId);
    });
    await _saveRejectedRides();
    print(
      'Added ride $rideId to rejected list. Total rejected: ${_rejectedRideIds.length}',
    );
  }

  Future<void> _fetchDriverProfile() async {
    try {
      final response = await http.get(
        Uri.parse('$baseUrl/api/rides/driver/profile/'),
        headers: {
          'Authorization': 'Bearer ${widget.jwtToken}',
          'Content-Type': 'application/json',
        },
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        setState(() {
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
      print('Driver profile error: $e');
      rethrow;
    }
  }

  Future<void> _fetchNearbyRides() async {
    print('=== FETCH NEARBY RIDES STARTED ===');
    print('Driver Profile available: ${driverProfile != null}');
    print('Current Position available: ${_currentPosition != null}');
    print('isActive: $isActive');

    try {
      // Get current position for the API request
      Position? position = _currentPosition;
      if (position == null) {
        try {
          position = await Geolocator.getCurrentPosition(
            desiredAccuracy: LocationAccuracy.high,
          );
        } catch (e) {
          print('Unable to get current position for nearby rides: $e');
          // Use driver profile location as fallback
          if (driverProfile != null &&
              driverProfile!['current_latitude'] != null &&
              driverProfile!['current_longitude'] != null) {
            final lat = double.tryParse(
              driverProfile!['current_latitude'].toString(),
            );
            final lng = double.tryParse(
              driverProfile!['current_longitude'].toString(),
            );
            if (lat != null && lng != null) {
              print('Using driver profile location: $lat, $lng');
            } else {
              print('No valid location available for nearby rides API');
              setState(() {
                notifications = [];
              });
              return;
            }
          } else {
            print('No location available for nearby rides API');
            setState(() {
              notifications = [];
            });
            return;
          }
        }
      }

      // Prepare request body with location
      final lat =
          position?.latitude ??
          double.tryParse(driverProfile!['current_latitude'].toString());
      final lng =
          position?.longitude ??
          double.tryParse(driverProfile!['current_longitude'].toString());

      // Ensure we have valid coordinates
      if (lat == null || lng == null) {
        print('ERROR: Cannot get valid coordinates - lat: $lat, lng: $lng');
        setState(() {
          notifications = [];
        });
        return;
      }

      // Round to 6 decimal places to match backend expectations
      final requestBody = {
        'latitude': double.parse(lat.toStringAsFixed(6)),
        'longitude': double.parse(lng.toStringAsFixed(6)),
      };

      print('Raw coordinates: lat=$lat, lng=$lng');
      print(
        'Rounded coordinates: lat=${requestBody['latitude']}, lng=${requestBody['longitude']}',
      );

      print(
        'Fetching nearby rides with location: ${requestBody['latitude']}, ${requestBody['longitude']}',
      );
      print('Request body JSON: ${json.encode(requestBody)}');

      final response = await http.post(
        Uri.parse('$baseUrl/api/rides/driver/nearby-rides/'),
        headers: {
          'Authorization': 'Bearer ${widget.jwtToken}',
          'Content-Type': 'application/json',
        },
        body: json.encode(requestBody),
      );

      print('Nearby rides API response: ${response.statusCode}');
      print('Nearby rides API body: ${response.body}');

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final List<dynamic> ridesData = data['rides'] ?? [];

        print('Found ${ridesData.length} nearby rides from API');

        // Filter out rejected rides and map to notification format
        final filteredRides = ridesData
            .where((ride) {
              final rideId = ride['id'] as int;
              final isRejected = _rejectedRideIds.contains(rideId);
              if (isRejected) {
                print('Filtering out rejected ride ID: $rideId');
              }
              return !isRejected;
            })
            .map<Map<String, dynamic>>((ride) {
              final rideMap = Map<String, dynamic>.from(ride as Map);
              return _rideToNotification(rideMap);
            })
            .toList();

        setState(() {
          notifications = filteredRides;
        });

        print(
          'After filtering: ${notifications.length} rides (rejected ${ridesData.length - notifications.length} rides)',
        );
        print('Final notifications state: $notifications');
        print('Current rejected rides: $_rejectedRideIds');
        print('=== NOTIFICATIONS UPDATE COMPLETE ===');
      } else if (response.statusCode == 400) {
        // Driver not available or no location
        print('Driver not available or location issue');
        setState(() {
          notifications = [];
        });
      } else {
        throw Exception('Failed to load nearby rides: ${response.statusCode}');
      }
    } catch (e) {
      print('Nearby rides error: $e');
      // Don't throw here, just set empty notifications
      setState(() {
        notifications = [];
      });
    }
  }

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

  Future<void> _updateDriverStatus(bool active) async {
    if (widget.jwtToken == null) return;

    setState(() {
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
        Uri.parse('$baseUrl/api/rides/driver/status/'),
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
          // Refresh nearby rides when going online
          await _fetchNearbyRides();
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

    setState(() {
      isLoading = true;
    });

    try {
      final response = await http.post(
        Uri.parse('$baseUrl/api/rides/handle/$rideId/accept/'),
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

        // Navigate to ride tracking page
        if (mounted) {
          Navigator.push(
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
                isDriver: true,
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

    setState(() {
      isLoading = true;
    });

    try {
      // Add to local rejected rides list (client-side filtering)
      await _addRejectedRide(rideId);

      if (!mounted) return;

      // Remove the rejected ride from current notifications
      _safeSetState(() {
        notifications.removeWhere((notif) => notif['id'] == rideId);
      });

      _showSnackBar(
        'Ride rejected - hidden from your list! ❌',
        backgroundColor: Colors.orange,
      );

      print('Ride $rideId rejected and hidden locally');
    } catch (e) {
      _showSnackBar('Error rejecting ride: $e', backgroundColor: Colors.red);
    } finally {
      _safeSetState(() {
        isLoading = false;
      });
    }
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('E-Rickshaw Driver'),
        leading: IconButton(
          onPressed: () {
            print('=== NAVIGATION ===');
            print('Logging out from Driver Dashboard');
            print('==================');

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
                    onPressed: () {
                      Navigator.pop(context); // Close dialog
                      // Navigate back to start page and clear all previous routes
                      Navigator.pushNamedAndRemoveUntil(
                        context,
                        '/',
                        (route) => false,
                      );
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
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text(
                        'No access token available. Please login to view previous rides.',
                      ),
                    ),
                  );
                  return;
                }
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) =>
                        PreviousRidesPage(jwtToken: widget.jwtToken!),
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
                              if (_socketStatusMessage != null)
                                Container(
                                  width: double.infinity,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 8,
                                  ),
                                  margin: const EdgeInsets.only(bottom: 12),
                                  decoration: BoxDecoration(
                                    color: _isSocketConnected
                                        ? Colors.green[100]
                                        : Colors.orange[100],
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Row(
                                    children: [
                                      Icon(
                                        _isSocketConnected
                                            ? Icons.wifi
                                            : Icons.wifi_off,
                                        color: _isSocketConnected
                                            ? Colors.green
                                            : Colors.orange,
                                        size: 18,
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: Text(
                                          _socketStatusMessage!,
                                          style: TextStyle(
                                            color: _isSocketConnected
                                                ? Colors.green[900]
                                                : Colors.orange[900],
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ),
                                      if (!_isSocketConnected &&
                                          _canUseDriverSocket)
                                        IconButton(
                                          icon: const Icon(Icons.refresh),
                                          tooltip: 'Reconnect',
                                          onPressed: _manualSocketReconnect,
                                        ),
                                    ],
                                  ),
                                ),
                              if (_lastSocketMessageAt != null)
                                Align(
                                  alignment: Alignment.centerLeft,
                                  child: Padding(
                                    padding: const EdgeInsets.only(bottom: 6),
                                    child: Text(
                                      'Last socket heartbeat: ${_formatTimestamp(_lastSocketMessageAt)}',
                                      style: const TextStyle(
                                        fontSize: 12,
                                        color: Colors.black54,
                                      ),
                                    ),
                                  ),
                                ),
                              if (_lastRideReceivedAt != null)
                                Align(
                                  alignment: Alignment.centerLeft,
                                  child: Padding(
                                    padding: const EdgeInsets.only(bottom: 6),
                                    child: Text(
                                      'Last ride payload: ${_formatTimestamp(_lastRideReceivedAt)}',
                                      style: const TextStyle(
                                        fontSize: 12,
                                        color: Colors.black54,
                                      ),
                                    ),
                                  ),
                                ),
                              if (_socketReconnectAttempts > 0)
                                Align(
                                  alignment: Alignment.centerLeft,
                                  child: Padding(
                                    padding: const EdgeInsets.only(bottom: 6),
                                    child: Text(
                                      'Reconnect attempt #$_socketReconnectAttempts scheduled',
                                      style: const TextStyle(
                                        fontSize: 12,
                                        color: Colors.orange,
                                      ),
                                    ),
                                  ),
                                ),
                              if (_lastSocketError != null)
                                Align(
                                  alignment: Alignment.centerLeft,
                                  child: Padding(
                                    padding: const EdgeInsets.only(bottom: 6),
                                    child: Text(
                                      'Last socket error: $_lastSocketError',
                                      style: const TextStyle(
                                        fontSize: 12,
                                        color: Colors.red,
                                      ),
                                    ),
                                  ),
                                ),
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
