import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_cancellable_tile_provider/flutter_map_cancellable_tile_provider.dart';
import 'package:latlong2/latlong.dart';

import '../../config/api_endpoints.dart';
import '../../core/controllers/ride_location_publisher.dart';
import '../../core/mixins/safe_state_mixin.dart';
import '../../models/ride_id.dart';
import '../../router/app_router.dart';
import '../../services/api_service.dart';
import '../../services/auth_service.dart';
import '../../services/error_service.dart';
import '../../services/logger_service.dart';
import '../../services/websocket_service.dart';
import 'driver_page.dart';

/// Driver's active-ride screen backed by FastAPI lifecycle and live-location events.
class RideTrackingPage extends StatefulWidget {
  const RideTrackingPage({
    super.key,
    required this.rideId,
    required this.pickupAddress,
    required this.dropoffAddress,
    required this.passengerCount,
    this.pickupLatitude,
    this.pickupLongitude,
  });

  final RideId rideId;
  final String pickupAddress;
  final String dropoffAddress;
  final int passengerCount;
  final double? pickupLatitude;
  final double? pickupLongitude;

  @override
  State<RideTrackingPage> createState() => _RideTrackingPageState();
}

class _RideTrackingPageState extends State<RideTrackingPage> with SafeStateMixin {
  final ApiService _apiService = ApiService();
  final AuthService _authService = AuthService();
  final WebSocketService _webSocketService = WebSocketService();
  final ErrorService _errorService = ErrorService();
  final RideLocationPublisher _locationPublisher = RideLocationPublisher(role: 'driver');

  StreamSubscription? _subscription;
  LatLng? _driverLocation;
  LatLng? _riderLocation;
  String _status = 'accepted';
  int _stateVersion = 0;
  int _riderLocationSequence = 0;
  bool _isLoading = true;
  bool _isActionPending = false;
  bool _terminalHandled = false;

  @override
  void initState() {
    super.initState();
    _subscription = _webSocketService.driverMessages.listen(_handleEvent);
    _initialize();
  }

  Future<void> _initialize() async {
    final authState = await _authService.getAuthState();
    if (!authState.isAuthenticated) return;
    await _webSocketService.connectDriver(jwtToken: authState.accessToken);
    await _refreshSnapshot();
    if (!_isTerminal(_status)) {
      await _locationPublisher.start(
        rideId: widget.rideId,
        onLocation: (location) => safeSetState(() => _driverLocation = location),
      );
    }
    safeSetState(() => _isLoading = false);
  }

  Future<void> _refreshSnapshot() async {
    try {
      final response = await _apiService.get(RideEndpoints.snapshot(widget.rideId));
      if (response.statusCode == 200) {
        _applySnapshot(_decode(response.body));
      } else if (mounted) {
        _errorService.handleError(context, null, response: response);
      }
    } catch (error) {
      Logger.error('Unable to load driver ride snapshot', error: error, tag: 'DriverTracking');
    }
  }

  Map<String, dynamic> _decode(String body) => Map<String, dynamic>.from(jsonDecode(body) as Map);

  void _handleEvent(Map<String, dynamic> event) {
    if (!mounted || event['ride_id']?.toString() != widget.rideId) return;
    switch (event['type']?.toString()) {
      case 'ride_snapshot':
        _applySnapshot(event);
        break;
      case 'ride_location_updated':
        _applyPeerLocation(event);
        break;
      case 'ride_state_changed':
        _applyState(
          event['status']?.toString(),
          _asInt(event['state_version']),
          reason: event['reason']?.toString(),
        );
        break;
    }
  }

  void _applySnapshot(Map<dynamic, dynamic> snapshot) {
    _applyState(snapshot['status']?.toString(), _asInt(snapshot['state_version']));
    final peer = snapshot['peer_location'];
    if (peer is Map) _applyPeerLocation(Map<String, dynamic>.from(peer));
  }

  void _applyPeerLocation(Map<dynamic, dynamic> location) {
    if (location['participant']?.toString() != 'rider') return;
    final sequence = _asInt(location['sequence']) ?? 0;
    if (sequence <= _riderLocationSequence) return;
    final latitude = _asDouble(location['latitude']);
    final longitude = _asDouble(location['longitude']);
    if (latitude == null || longitude == null) return;
    safeSetState(() {
      _riderLocationSequence = sequence;
      _riderLocation = LatLng(latitude, longitude);
    });
  }

  void _applyState(String? status, int? version, {String? reason}) {
    if (status == null || status.isEmpty) return;
    if (version != null && version < _stateVersion) return;
    safeSetState(() {
      _status = status;
      if (version != null) _stateVersion = version;
    });
    if (_isTerminal(status)) _handleTerminalState(reason);
  }

  Future<void> _handleTerminalState(String? reason) async {
    if (_terminalHandled || !mounted) return;
    _terminalHandled = true;
    await _locationPublisher.dispose();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: Text(_status == 'completed' ? 'Ride Completed' : 'Ride Ended'),
        content: Text(reason?.isNotEmpty == true ? reason! : _terminalMessage(_status)),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: const Text('OK')),
        ],
      ),
    );
    if (mounted) AppRouter.pushReplacement(context, const DriverPage());
  }

  Future<void> _performAction(String action) async {
    if (_isActionPending || _isTerminal(_status)) return;
    String endpoint;
    Map<String, dynamic>? body;
    switch (action) {
      case 'arrive':
        endpoint = RideEndpoints.arrive(widget.rideId);
        break;
      case 'start':
        endpoint = RideEndpoints.start(widget.rideId);
        break;
      case 'complete':
        endpoint = RideEndpoints.complete(widget.rideId);
        break;
      case 'cancel':
        endpoint = RideEndpoints.driverCancel(widget.rideId);
        body = {'reason': 'Cancelled by driver'};
        break;
      default:
        return;
    }

    if (action == 'cancel') {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Cancel ride?'),
          content: const Text('This will end the current ride for the rider.'),
          actions: [
            TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Keep ride')),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Cancel', style: TextStyle(color: Colors.red)),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }

    safeSetState(() => _isActionPending = true);
    try {
      final response = await _apiService.post(endpoint, body: body);
      if (response.statusCode == 200) {
        final data = _decode(response.body);
        _applyState(data['status']?.toString(), _asInt(data['state_version']), reason: body?['reason']?.toString());
      } else if (mounted) {
        _errorService.handleError(context, null, response: response);
      }
    } catch (error) {
      if (mounted) _errorService.handleError(context, error);
    } finally {
      if (mounted) safeSetState(() => _isActionPending = false);
    }
  }

  int? _asInt(dynamic value) => value is num ? value.toInt() : int.tryParse(value?.toString() ?? '');
  double? _asDouble(dynamic value) => value is num ? value.toDouble() : double.tryParse(value?.toString() ?? '');
  bool _isTerminal(String status) => const {
        'completed',
        'cancelled_by_rider',
        'cancelled_by_driver',
        'expired',
      }.contains(status);

  String _terminalMessage(String status) {
    switch (status) {
      case 'completed':
        return 'The ride has been completed.';
      case 'cancelled_by_rider':
        return 'The rider cancelled this ride.';
      case 'cancelled_by_driver':
        return 'This ride was cancelled.';
      default:
        return 'The ride request expired.';
    }
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _locationPublisher.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final center = _driverLocation ?? _riderLocation ?? _pickupLocation;
    return PopScope(
      canPop: _isTerminal(_status),
      child: Scaffold(
        appBar: AppBar(title: const Text('Active Ride'), automaticallyImplyLeading: false),
        body: _isLoading || center == null
            ? const Center(child: CircularProgressIndicator())
            : Column(
                children: [
                  _detailsPanel(),
                  Expanded(child: _map(center)),
                  _actions(),
                ],
              ),
      ),
    );
  }

  LatLng? get _pickupLocation => widget.pickupLatitude != null && widget.pickupLongitude != null
      ? LatLng(widget.pickupLatitude!, widget.pickupLongitude!)
      : null;

  Widget _detailsPanel() => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        color: Colors.blue.shade50,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Status: ${_status.replaceAll('_', ' ')}', style: const TextStyle(fontWeight: FontWeight.bold)),
            Text('Pickup: ${widget.pickupAddress}'),
            Text('Drop-off: ${widget.dropoffAddress}'),
            Text('Passengers: ${widget.passengerCount}'),
          ],
        ),
      );

  Widget _map(LatLng center) => FlutterMap(
        options: MapOptions(initialCenter: center, initialZoom: 15),
        children: [
          TileLayer(
            urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
            userAgentPackageName: 'com.erick.connect',
            tileProvider: kIsWeb ? CancellableNetworkTileProvider() : NetworkTileProvider(),
          ),
          MarkerLayer(
            markers: [
              if (_driverLocation != null)
                Marker(
                  point: _driverLocation!,
                  width: 48,
                  height: 48,
                  child: const Icon(Icons.local_taxi, color: Colors.blue, size: 36),
                ),
              if (_riderLocation != null)
                Marker(
                  point: _riderLocation!,
                  width: 48,
                  height: 48,
                  child: const Icon(Icons.person_pin_circle, color: Colors.green, size: 36),
                ),
              if (_pickupLocation != null)
                Marker(
                  point: _pickupLocation!,
                  width: 40,
                  height: 40,
                  child: const Icon(Icons.location_on, color: Colors.orange, size: 32),
                ),
            ],
          ),
        ],
      );

  Widget _actions() {
    String? primaryAction;
    String primaryLabel;
    switch (_status) {
      case 'accepted':
        primaryAction = 'arrive';
        primaryLabel = 'Mark arrived';
        break;
      case 'arrived':
        primaryAction = 'start';
        primaryLabel = 'Start ride';
        break;
      case 'started':
        primaryAction = 'complete';
        primaryLabel = 'Complete ride';
        break;
      default:
        primaryLabel = 'Ride ended';
    }
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed: _isActionPending || _isTerminal(_status) ? null : () => _performAction('cancel'),
              icon: const Icon(Icons.cancel, color: Colors.red),
              label: const Text('Cancel'),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: ElevatedButton(
              onPressed: _isActionPending || primaryAction == null
                  ? null
                  : () => _performAction(primaryAction!),
              child: Text(_isActionPending ? 'Updating...' : primaryLabel),
            ),
          ),
        ],
      ),
    );
  }
}
