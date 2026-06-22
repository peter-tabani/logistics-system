import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' as gmaps;
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String configuredApiBaseUrl = String.fromEnvironment('API_BASE_URL');
const String apiBaseUrl = configuredApiBaseUrl == ''
    ? (kIsWeb ? 'http://localhost:5000' : 'http://10.0.2.2:5000')
    : configuredApiBaseUrl;
const Duration apiRequestTimeout = Duration(seconds: 12);
// Google Maps key passed at build time via --dart-define=GOOGLE_MAPS_API_KEY=...
// When empty, the app renders the free OpenStreetMap (flutter_map) layer.
// The native Maps SDK key also lives in android/local.properties (MAPS_API_KEY).
const String googleMapsApiKey = String.fromEnvironment('GOOGLE_MAPS_API_KEY');
const bool useGoogleMaps = googleMapsApiKey != '';
const Color stanDark = Color(0xFF0E2140); // deep navy blue (primary)
const Color stanPanel = Color(0xFF17304F); // lifted navy panel
const Color stanSurface = Color(0xFFEEF2F8); // light app background
const Color stanMuted = Color(0xFF93A4BD); // muted blue-grey on navy
const LatLng defaultMapCenter = LatLng(-1.286389, 36.817223);
const String pendingTrackingEventsKey = 'pendingTrackingEvents';
const double pickupArrivalRadiusMeters = 120;
const double dropoffArrivalRadiusMeters = 150;

enum DriverWorkflowStep { assignments, routePreview, liveTracking, completed }

String formatDeliveryStatus(String status) {
  return status.replaceAll('_', ' ');
}

double calculateDistanceMeters(LatLng firstPoint, LatLng secondPoint) {
  const earthRadiusMeters = 6371000;
  final firstLatitude = firstPoint.latitude * pi / 180;
  final secondLatitude = secondPoint.latitude * pi / 180;
  final latitudeDelta = (secondPoint.latitude - firstPoint.latitude) * pi / 180;
  final longitudeDelta =
      (secondPoint.longitude - firstPoint.longitude) * pi / 180;

  final a =
      sin(latitudeDelta / 2) * sin(latitudeDelta / 2) +
      cos(firstLatitude) *
          cos(secondLatitude) *
          sin(longitudeDelta / 2) *
          sin(longitudeDelta / 2);
  final c = 2 * atan2(sqrt(a), sqrt(1 - a));

  return earthRadiusMeters * c;
}

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Stan',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: stanDark),
        fontFamily: 'Roboto',
        scaffoldBackgroundColor: stanSurface,
        useMaterial3: true,
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            backgroundColor: stanDark,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 18),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(999),
            ),
          ),
        ),
      ),
      home: const SplashScreen(),
    );
  }
}

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  @override
  void initState() {
    super.initState();
    Timer(const Duration(milliseconds: 1400), () {
      if (!mounted) return;

      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const LoginScreen()),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: stanDark,
      body: SafeArea(
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              StanMark(size: 96),
              SizedBox(height: 22),
              Text(
                'Stan',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 42,
                  fontWeight: FontWeight.w900,
                  letterSpacing: -1.6,
                ),
              ),
              SizedBox(height: 8),
              Text(
                'Shipping made simple',
                style: TextStyle(
                  color: stanMuted,
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class StanMark extends StatelessWidget {
  const StanMark({super.key, this.size = 64});

  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: stanPanel,
        borderRadius: BorderRadius.circular(size * 0.28),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.32),
            blurRadius: size * 0.28,
            offset: Offset(0, size * 0.12),
          ),
        ],
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          Text(
            'S',
            style: TextStyle(
              color: Colors.white,
              fontSize: size * 0.60,
              fontWeight: FontWeight.w900,
              height: 0.92,
              letterSpacing: -size * 0.06,
            ),
          ),
          Positioned(
            left: size * 0.18,
            top: size * 0.24,
            child: Transform.rotate(
              angle: -0.72,
              child: Container(
                width: size * 0.24,
                height: size * 0.07,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
            ),
          ),
          Positioned(
            right: size * 0.18,
            bottom: size * 0.24,
            child: Transform.rotate(
              angle: -0.72,
              child: Container(
                width: size * 0.24,
                height: size * 0.07,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final TextEditingController _phoneController = TextEditingController(
    text: '0711111111',
  );
  final TextEditingController _passwordController = TextEditingController(
    text: 'driver123',
  );

  bool _isLoading = false;
  String? _errorMessage;

  @override
  void dispose() {
    _phoneController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final response = await http
          .post(
            Uri.parse('$apiBaseUrl/auth/login'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'phone': _phoneController.text.trim(),
              'password': _passwordController.text,
            }),
          )
          .timeout(apiRequestTimeout);

      final data = jsonDecode(response.body) as Map<String, dynamic>;

      if (!mounted) return;

      if (response.statusCode == 200) {
        final user = data['user'] as Map<String, dynamic>;

        if (user['role'] != 'driver') {
          setState(() {
            _errorMessage = 'Only driver accounts can use this app.';
          });
          return;
        }

        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder: (_) => DriverHomeScreen(
              fullName: user['fullName'] as String,
              role: user['role'] as String,
              token: data['token'] as String,
            ),
          ),
        );
      } else {
        setState(() {
          _errorMessage =
              data['message'] as String? ?? 'Login failed. Please try again.';
        });
      }
    } catch (error) {
      if (!mounted) return;

      setState(() {
        _errorMessage =
            'Could not connect to the backend. Make sure it is running.';
      });
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
      backgroundColor: stanDark,
      body: SafeArea(
        child: Stack(
          children: [
            Positioned(
              top: -80,
              right: -70,
              child: Container(
                width: 220,
                height: 220,
                decoration: BoxDecoration(
                  color: const Color(0xFF12323A).withValues(alpha: 0.55),
                  shape: BoxShape.circle,
                ),
              ),
            ),
            Positioned(
              bottom: 80,
              left: -90,
              child: Container(
                width: 210,
                height: 210,
                decoration: BoxDecoration(
                  color: const Color(0xFF12323A).withValues(alpha: 0.38),
                  shape: BoxShape.circle,
                ),
              ),
            ),
            Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 420),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Align(
                        alignment: Alignment.centerLeft,
                        child: StanMark(size: 76),
                      ),
                      const SizedBox(height: 34),
                      const Text(
                        'Shipping\nMade\nSimple',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 46,
                          height: 0.98,
                          fontWeight: FontWeight.w400,
                          letterSpacing: -1.8,
                        ),
                      ),
                      const SizedBox(height: 12),
                      const Text(
                        'Deliveries at your fingertips',
                        style: TextStyle(
                          color: stanMuted,
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 34),
                      Container(
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(28),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.24),
                              blurRadius: 34,
                              offset: const Offset(0, 18),
                            ),
                          ],
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            const Text(
                              'Welcome to Stan',
                              style: TextStyle(
                                color: stanDark,
                                fontSize: 22,
                                fontWeight: FontWeight.w900,
                                letterSpacing: -0.5,
                              ),
                            ),
                            const SizedBox(height: 6),
                            const Text(
                              'Sign in to manage your active deliveries.',
                              style: TextStyle(
                                color: Color(0xFF60727A),
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 20),
                            TextField(
                              controller: _phoneController,
                              keyboardType: TextInputType.phone,
                              decoration: InputDecoration(
                                labelText: 'Phone number',
                                prefixIcon: const Icon(Icons.phone_outlined),
                                filled: true,
                                fillColor: stanSurface,
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(18),
                                  borderSide: BorderSide.none,
                                ),
                              ),
                            ),
                            const SizedBox(height: 14),
                            TextField(
                              controller: _passwordController,
                              obscureText: true,
                              decoration: InputDecoration(
                                labelText: 'Password',
                                prefixIcon: const Icon(Icons.lock_outline),
                                filled: true,
                                fillColor: stanSurface,
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(18),
                                  borderSide: BorderSide.none,
                                ),
                              ),
                            ),
                            if (_errorMessage != null) ...[
                              const SizedBox(height: 16),
                              Text(
                                _errorMessage!,
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: Theme.of(context).colorScheme.error,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                            const SizedBox(height: 20),
                            FilledButton(
                              onPressed: _isLoading ? null : _login,
                              child: _isLoading
                                  ? const SizedBox(
                                      width: 20,
                                      height: 20,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Text('Continue'),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 18),
                      Text(
                        'Test account: 0711111111 / driver123\nAPI: $apiBaseUrl',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: stanMuted,
                          fontSize: 12,
                          height: 1.5,
                        ),
                      ),
                    ],
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

class DriverHomeScreen extends StatefulWidget {
  const DriverHomeScreen({
    super.key,
    required this.fullName,
    required this.role,
    required this.token,
  });

  final String fullName;
  final String role;
  final String token;

  @override
  State<DriverHomeScreen> createState() => _DriverHomeScreenState();
}

class _DriverHomeScreenState extends State<DriverHomeScreen>
    with WidgetsBindingObserver {
  final MapController _mapController = MapController();
  gmaps.GoogleMapController? _googleMapController;
  int? _routeForDeliveryId;
  List<gmaps.LatLng> _googleRoutePoints = [];
  bool _isFetchingRoute = false;

  bool _isSendingLocation = false;
  bool _isLoadingDeliveries = false;
  bool _isTracking = false;
  bool _isStartingTracking = false;
  bool _isFlushingTrackingEvents = false;
  Timer? _trackingTimer;
  int? _updatingDeliveryId;
  String? _statusMessage;
  Position? _lastPosition;
  int? _selectedDeliveryId;
  bool _showLocationDetails = false;
  int _selectedNavIndex = 0;
  List<Map<String, dynamic>> _deliveries = [];
  List<Map<String, dynamic>> _pendingTrackingEvents = [];
  final Set<int> _reportedPickupArrivals = {};
  final Set<int> _reportedDropoffArrivals = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_initializeDriverHome());
  }

  Future<void> _initializeDriverHome() async {
    await _loadPendingTrackingEvents();

    if (!mounted) return;

    await _loadDeliveries();

    if (!mounted) return;

    unawaited(
      _reportTrackingEvent(
        eventType: 'app_opened',
        severity: 'info',
        message: 'Driver opened the tracking app.',
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _trackingTimer?.cancel();
    _googleMapController?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(
        _reportTrackingEvent(
          eventType: 'app_resumed',
          severity: 'info',
          message: 'Driver app returned to the foreground.',
          metadata: {'state': state.name},
        ),
      );
      unawaited(_flushPendingTrackingEvents());
      unawaited(_loadDeliveries());
      return;
    }

    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden) {
      final hasActiveDelivery = _activeDeliveries.isNotEmpty;
      unawaited(
        _reportTrackingEvent(
          eventType: 'app_backgrounded',
          severity: hasActiveDelivery ? 'warning' : 'info',
          message: hasActiveDelivery
              ? 'Driver app left the foreground during an active delivery.'
              : 'Driver app left the foreground.',
          metadata: {'state': state.name},
        ),
      );
    }
  }

  List<Map<String, dynamic>> get _activeDeliveries {
    return _deliveries
        .where((delivery) => delivery['status'] != 'delivered')
        .toList();
  }

  Map<String, dynamic>? get _selectedDelivery {
    final selectedDeliveryId = _selectedDeliveryId;

    if (selectedDeliveryId == null) return null;

    for (final delivery in _deliveries) {
      if (delivery['id'] == selectedDeliveryId) return delivery;
    }

    return null;
  }

  Map<String, dynamic>? get _currentTrackingDelivery {
    if (_selectedDelivery != null) return _selectedDelivery;

    final activeDeliveries = _activeDeliveries;

    if (activeDeliveries.isEmpty) return null;

    return activeDeliveries.first;
  }

  int? get _currentDeliveryId {
    if (_selectedDeliveryId != null) return _selectedDeliveryId;

    final activeDeliveries = _activeDeliveries;

    if (activeDeliveries.isEmpty) return null;

    return activeDeliveries.first['id'] as int;
  }

  double? _deliveryNumber(Map<String, dynamic> delivery, String key) {
    final value = delivery[key];

    if (value == null) return null;

    return double.tryParse(value.toString());
  }

  LatLng? _deliveryPoint(
    Map<String, dynamic>? delivery,
    String latitudeKey,
    String longitudeKey,
  ) {
    if (delivery == null) return null;

    final latitude = _deliveryNumber(delivery, latitudeKey);
    final longitude = _deliveryNumber(delivery, longitudeKey);

    if (latitude == null || longitude == null) return null;

    return LatLng(latitude, longitude);
  }

  LatLng? _pickupPoint(Map<String, dynamic>? delivery) {
    return _deliveryPoint(delivery, 'pickupLatitude', 'pickupLongitude');
  }

  LatLng? _dropoffPoint(Map<String, dynamic>? delivery) {
    return _deliveryPoint(delivery, 'dropoffLatitude', 'dropoffLongitude');
  }

  DriverWorkflowStep get _workflowStep {
    final delivery = _selectedDelivery;

    if (delivery == null) return DriverWorkflowStep.assignments;

    switch (delivery['status']) {
      case 'assigned':
        return DriverWorkflowStep.routePreview;
      case 'picked_up':
      case 'in_transit':
        return DriverWorkflowStep.liveTracking;
      case 'delivered':
        return DriverWorkflowStep.completed;
      default:
        return DriverWorkflowStep.assignments;
    }
  }

  Future<void> _loadPendingTrackingEvents() async {
    final preferences = await SharedPreferences.getInstance();
    final savedEvents =
        preferences.getStringList(pendingTrackingEventsKey) ?? [];

    _pendingTrackingEvents = savedEvents
        .map((eventJson) => jsonDecode(eventJson) as Map<String, dynamic>)
        .toList();
  }

  Future<void> _savePendingTrackingEvents() async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setStringList(
      pendingTrackingEventsKey,
      _pendingTrackingEvents.map(jsonEncode).toList(),
    );
  }

  Future<void> _queueTrackingEvent(Map<String, dynamic> event) async {
    _pendingTrackingEvents.add(event);
    await _savePendingTrackingEvents();
  }

  Future<bool> _sendTrackingEventPayload(Map<String, dynamic> payload) async {
    final response = await http
        .post(
          Uri.parse('$apiBaseUrl/driver/tracking-events'),
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer ${widget.token}',
          },
          body: jsonEncode(payload),
        )
        .timeout(apiRequestTimeout);

    return response.statusCode == 201;
  }

  Future<void> _reportTrackingEvent({
    required String eventType,
    required String severity,
    required String message,
    Map<String, dynamic> metadata = const {},
    int? deliveryId,
    bool queueOnFailure = true,
  }) async {
    final payload = {
      'eventType': eventType,
      'severity': severity,
      'message': message,
      'deliveryId': deliveryId ?? _currentDeliveryId,
      'metadata': {
        ...metadata,
        'clientRecordedAt': DateTime.now().toIso8601String(),
      },
    };

    try {
      final didSave = await _sendTrackingEventPayload(payload);

      if (didSave) {
        unawaited(_flushPendingTrackingEvents());
        return;
      }
    } catch (_) {
      // If data is off, preserve the event locally and upload when data returns.
    }

    if (queueOnFailure) {
      await _queueTrackingEvent(payload);
    }
  }

  Future<void> _flushPendingTrackingEvents() async {
    if (_isFlushingTrackingEvents || _pendingTrackingEvents.isEmpty) return;

    _isFlushingTrackingEvents = true;

    try {
      final remainingEvents = <Map<String, dynamic>>[];

      for (final event in _pendingTrackingEvents) {
        try {
          final didSave = await _sendTrackingEventPayload(event);

          if (!didSave) {
            remainingEvents.add(event);
          }
        } catch (_) {
          remainingEvents.add(event);
        }
      }

      _pendingTrackingEvents = remainingEvents;
      await _savePendingTrackingEvents();
    } finally {
      _isFlushingTrackingEvents = false;
    }
  }

  Future<void> _loadDeliveries() async {
    setState(() {
      _isLoadingDeliveries = true;
      _statusMessage = null;
    });

    try {
      final response = await http
          .get(
            Uri.parse('$apiBaseUrl/driver/deliveries'),
            headers: {'Authorization': 'Bearer ${widget.token}'},
          )
          .timeout(apiRequestTimeout);

      final data = jsonDecode(response.body) as Map<String, dynamic>;

      if (!mounted) return;

      if (response.statusCode == 200) {
        final loadedDeliveries = (data['deliveries'] as List<dynamic>)
            .cast<Map<String, dynamic>>();

        setState(() {
          _deliveries = loadedDeliveries;
          if (_selectedDeliveryId != null &&
              !loadedDeliveries.any(
                (delivery) => delivery['id'] == _selectedDeliveryId,
              )) {
            _selectedDeliveryId = null;
          }
        });

        final hasActiveDelivery = loadedDeliveries.any(
          (delivery) => delivery['status'] != 'delivered',
        );

        if (!hasActiveDelivery && _isTracking) {
          _stopTracking();
        }
      } else {
        setState(() {
          _statusMessage =
              data['message'] as String? ?? 'Could not load deliveries.';
        });
      }
    } catch (error) {
      if (!mounted) return;

      setState(() {
        _statusMessage = 'Could not connect to load deliveries.';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isLoadingDeliveries = false;
        });
      }
    }
  }

  String? _nextStatus(String status) {
    switch (status) {
      case 'assigned':
        return 'picked_up';
      case 'picked_up':
        return 'in_transit';
      case 'in_transit':
        return 'delivered';
      default:
        return null;
    }
  }

  Future<void> _updateDeliveryStatus(int deliveryId, String status) async {
    setState(() {
      _updatingDeliveryId = deliveryId;
      _statusMessage = null;
    });

    try {
      final response = await http
          .patch(
            Uri.parse('$apiBaseUrl/driver/deliveries/$deliveryId/status'),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer ${widget.token}',
            },
            body: jsonEncode({'status': status}),
          )
          .timeout(apiRequestTimeout);

      final data = jsonDecode(response.body) as Map<String, dynamic>;

      if (!mounted) return;

      if (response.statusCode == 200) {
        setState(() {
          _statusMessage =
              'Delivery updated to ${formatDeliveryStatus(status)}.';
        });
        unawaited(
          _reportTrackingEvent(
            eventType: 'delivery_status_changed',
            severity: 'info',
            message:
                'Delivery status changed to ${formatDeliveryStatus(status)}.',
            deliveryId: deliveryId,
            metadata: {'status': status},
          ),
        );
        await _loadDeliveries();
      } else {
        setState(() {
          _statusMessage =
              data['message'] as String? ?? 'Could not update delivery.';
        });
      }
    } catch (error) {
      if (!mounted) return;

      setState(() {
        _statusMessage = 'Could not update delivery. Try again.';
      });
    } finally {
      if (mounted) {
        setState(() {
          _updatingDeliveryId = null;
        });
      }
    }
  }

  Future<void> _startTracking() async {
    if (_isTracking || _isStartingTracking) return;

    _isStartingTracking = true;

    try {
      final hasPermission = await _ensureLocationPermission();

      if (!hasPermission || !mounted) return;

      setState(() {
        _isTracking = true;
        _statusMessage = 'Tracking started.';
      });
      unawaited(
        _reportTrackingEvent(
          eventType: 'tracking_started',
          severity: 'info',
          message: 'Live tracking started on the driver phone.',
        ),
      );

      await _sendCurrentLocation();

      if (!mounted || !_isTracking || _trackingTimer != null) return;

      _trackingTimer = Timer.periodic(const Duration(seconds: 15), (_) {
        unawaited(_sendCurrentLocation());
      });
    } finally {
      _isStartingTracking = false;
    }
  }

  void _stopTracking() {
    _trackingTimer?.cancel();
    _trackingTimer = null;

    setState(() {
      _isTracking = false;
      _statusMessage = 'Tracking stopped.';
    });
    unawaited(
      _reportTrackingEvent(
        eventType: 'tracking_stopped',
        severity: _activeDeliveries.isEmpty ? 'info' : 'warning',
        message: _activeDeliveries.isEmpty
            ? 'Live tracking stopped because there is no active delivery.'
            : 'Live tracking stopped while a delivery is still active.',
      ),
    );
  }

  Future<bool> _ensureLocationPermission() async {
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();

    if (!serviceEnabled) {
      setState(() {
        _statusMessage = 'Please turn on location services on this device.';
      });
      unawaited(
        _reportTrackingEvent(
          eventType: 'location_service_off',
          severity: 'critical',
          message: 'Driver location services are turned off.',
        ),
      );
      return false;
    }

    var permission = await Geolocator.checkPermission();

    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }

    if (permission == LocationPermission.denied) {
      setState(() {
        _statusMessage =
            'Location permission is needed to send tracking updates.';
      });
      unawaited(
        _reportTrackingEvent(
          eventType: 'gps_permission_denied',
          severity: 'critical',
          message: 'Driver denied location permission.',
        ),
      );
      return false;
    }

    if (permission == LocationPermission.deniedForever) {
      setState(() {
        _statusMessage =
            'Location permission is permanently denied. Enable it in app settings.';
      });
      unawaited(
        _reportTrackingEvent(
          eventType: 'gps_permission_denied_forever',
          severity: 'critical',
          message: 'Driver permanently denied location permission.',
        ),
      );
      return false;
    }

    return true;
  }

  Future<void> _sendCurrentLocation() async {
    if (_isSendingLocation) return;

    setState(() {
      _isSendingLocation = true;
      _statusMessage = null;
    });

    try {
      final hasPermission = await _ensureLocationPermission();

      if (!hasPermission) return;

      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
        ),
      );

      final response = await http
          .post(
            Uri.parse('$apiBaseUrl/driver/locations'),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer ${widget.token}',
            },
            body: jsonEncode({
              'latitude': position.latitude,
              'longitude': position.longitude,
              'accuracyMeters': position.accuracy,
            }),
          )
          .timeout(apiRequestTimeout);

      if (!mounted) return;

      if (response.statusCode == 201) {
        setState(() {
          _lastPosition = position;
          _statusMessage = _isTracking
              ? 'Tracking active. Last location sent successfully.'
              : 'Location sent successfully.';
        });
        if (_selectedDeliveryId != null) {
          _moveCamera(position.latitude, position.longitude, 15);
        }
        unawaited(_handleArrivalDetection(position));
        unawaited(_flushPendingTrackingEvents());
      } else {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        setState(() {
          _statusMessage =
              data['message'] as String? ?? 'Could not send location.';
        });
        unawaited(
          _reportTrackingEvent(
            eventType: 'location_send_failed',
            severity: 'warning',
            message: 'Driver phone could not upload a location update.',
            metadata: {'statusCode': response.statusCode},
          ),
        );
      }
    } catch (error) {
      if (!mounted) return;

      setState(() {
        _statusMessage = 'Could not get or send location. Try again.';
      });
      unawaited(
        _reportTrackingEvent(
          eventType: 'location_send_failed',
          severity: 'warning',
          message: 'Driver phone could not get or upload location.',
          metadata: {'error': error.toString()},
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isSendingLocation = false;
        });
      }
    }
  }

  Future<void> _handleArrivalDetection(Position position) async {
    final delivery = _currentTrackingDelivery;

    if (delivery == null) return;

    final deliveryId = delivery['id'] as int;
    final status = delivery['status'] as String;
    final currentPoint = LatLng(position.latitude, position.longitude);

    if (status == 'assigned') {
      final pickupPoint = _pickupPoint(delivery);

      if (pickupPoint == null || _reportedPickupArrivals.contains(deliveryId)) {
        return;
      }

      final distanceMeters = calculateDistanceMeters(currentPoint, pickupPoint);

      if (distanceMeters <= pickupArrivalRadiusMeters) {
        _reportedPickupArrivals.add(deliveryId);
        await _reportTrackingEvent(
          eventType: 'arrived_pickup',
          severity: 'info',
          message: 'Driver arrived near the pickup point.',
          deliveryId: deliveryId,
          metadata: {
            'distanceMeters': distanceMeters.round(),
            'radiusMeters': pickupArrivalRadiusMeters,
          },
        );
      }

      return;
    }

    if (status == 'in_transit') {
      final dropoffPoint = _dropoffPoint(delivery);

      if (dropoffPoint == null ||
          _reportedDropoffArrivals.contains(deliveryId)) {
        return;
      }

      final distanceMeters = calculateDistanceMeters(
        currentPoint,
        dropoffPoint,
      );

      if (distanceMeters <= dropoffArrivalRadiusMeters) {
        _reportedDropoffArrivals.add(deliveryId);
        await _reportTrackingEvent(
          eventType: 'arrived_dropoff',
          severity: 'info',
          message:
              'Driver arrived near the destination. Delivery will be completed automatically.',
          deliveryId: deliveryId,
          metadata: {
            'distanceMeters': distanceMeters.round(),
            'radiusMeters': dropoffArrivalRadiusMeters,
          },
        );
        await _updateDeliveryStatus(deliveryId, 'delivered');
      }
    }
  }

  Future<void> _showDriverLocationOnMap() async {
    if (_lastPosition == null) {
      await _sendCurrentLocation();
    } else {
      _moveCamera(_lastPosition!.latitude, _lastPosition!.longitude, 16);
    }

    if (!mounted || _lastPosition == null) return;

    setState(() {
      _showLocationDetails = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final workflowStep = _workflowStep;

    if (workflowStep == DriverWorkflowStep.assignments) {
      return Scaffold(
        backgroundColor: stanSurface,
        body: IndexedStack(
          index: _selectedNavIndex,
          children: [
            _buildAssignmentsPage(context),
            _buildShipmentsPage(context),
            _buildMessagesPage(context),
            _buildProfilePage(context),
          ],
        ),
        bottomNavigationBar: _buildBottomNavigation(),
      );
    }

    return Scaffold(
      backgroundColor: stanDark,
      body: Stack(
        children: [
          _buildMap(),
          _buildMapTopBar(context, workflowStep),
          _buildMapControls(),
          _buildWorkflowSheet(context, workflowStep),
        ],
      ),
    );
  }

  LatLng get _currentMapCenter {
    if (_lastPosition == null) return defaultMapCenter;

    return LatLng(_lastPosition!.latitude, _lastPosition!.longitude);
  }

  Widget _buildMap() {
    return useGoogleMaps ? _buildGoogleMap() : _buildOsmMap();
  }

  void _moveCamera(double latitude, double longitude, double zoom) {
    if (useGoogleMaps) {
      _googleMapController?.animateCamera(
        gmaps.CameraUpdate.newLatLngZoom(
          gmaps.LatLng(latitude, longitude),
          zoom,
        ),
      );
      return;
    }

    _mapController.move(LatLng(latitude, longitude), zoom);
  }

  // Decodes a Google "encoded polyline" string into map points.
  List<gmaps.LatLng> _decodePolyline(String encoded) {
    final points = <gmaps.LatLng>[];
    var index = 0;
    var lat = 0;
    var lng = 0;

    while (index < encoded.length) {
      int shift = 0;
      int result = 0;
      int byte;
      do {
        byte = encoded.codeUnitAt(index++) - 63;
        result |= (byte & 0x1f) << shift;
        shift += 5;
      } while (byte >= 0x20);
      lat += (result & 1) != 0 ? ~(result >> 1) : (result >> 1);

      shift = 0;
      result = 0;
      do {
        byte = encoded.codeUnitAt(index++) - 63;
        result |= (byte & 0x1f) << shift;
        shift += 5;
      } while (byte >= 0x20);
      lng += (result & 1) != 0 ? ~(result >> 1) : (result >> 1);

      points.add(gmaps.LatLng(lat / 1e5, lng / 1e5));
    }

    return points;
  }

  // Fetches a road-following route (pickup -> dropoff) from Google Directions.
  // Cached per delivery so live GPS updates don't re-request it.
  Future<void> _fetchGoogleRoute(Map<String, dynamic> delivery) async {
    if (!useGoogleMaps || _isFetchingRoute) return;

    final pickup = _pickupPoint(delivery);
    final dropoff = _dropoffPoint(delivery);

    if (pickup == null || dropoff == null) return;

    _isFetchingRoute = true;

    try {
      final url = Uri.parse(
        'https://maps.googleapis.com/maps/api/directions/json'
        '?origin=${pickup.latitude},${pickup.longitude}'
        '&destination=${dropoff.latitude},${dropoff.longitude}'
        '&mode=driving&key=$googleMapsApiKey',
      );
      final response = await http.get(url).timeout(apiRequestTimeout);
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final routes = data['routes'] as List<dynamic>?;

      if (routes == null || routes.isEmpty) return;

      final encoded =
          routes.first['overview_polyline']['points'] as String? ?? '';

      if (!mounted || encoded.isEmpty) return;

      setState(() {
        _routeForDeliveryId = delivery['id'] as int;
        _googleRoutePoints = _decodePolyline(encoded);
      });
    } catch (_) {
      // Leave the straight-line fallback in place if Directions fails.
    } finally {
      _isFetchingRoute = false;
    }
  }

  void _ensureGoogleRoute(Map<String, dynamic>? delivery) {
    if (!useGoogleMaps || delivery == null) return;

    final deliveryId = delivery['id'] as int;

    if (_routeForDeliveryId == deliveryId || _isFetchingRoute) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_fetchGoogleRoute(delivery));
    });
  }

  Set<gmaps.Marker> _googleMarkers(
    gmaps.LatLng? driver,
    LatLng? pickup,
    LatLng? dropoff,
  ) {
    final markers = <gmaps.Marker>{};

    if (driver != null) {
      markers.add(
        gmaps.Marker(
          markerId: const gmaps.MarkerId('driver'),
          position: driver,
          icon: gmaps.BitmapDescriptor.defaultMarkerWithHue(
            gmaps.BitmapDescriptor.hueAzure,
          ),
          infoWindow: const gmaps.InfoWindow(title: 'You'),
        ),
      );
    }

    if (pickup != null) {
      markers.add(
        gmaps.Marker(
          markerId: const gmaps.MarkerId('pickup'),
          position: gmaps.LatLng(pickup.latitude, pickup.longitude),
          icon: gmaps.BitmapDescriptor.defaultMarkerWithHue(
            gmaps.BitmapDescriptor.hueGreen,
          ),
          infoWindow: const gmaps.InfoWindow(title: 'Pickup'),
        ),
      );
    }

    if (dropoff != null) {
      markers.add(
        gmaps.Marker(
          markerId: const gmaps.MarkerId('dropoff'),
          position: gmaps.LatLng(dropoff.latitude, dropoff.longitude),
          icon: gmaps.BitmapDescriptor.defaultMarkerWithHue(
            gmaps.BitmapDescriptor.hueRed,
          ),
          infoWindow: const gmaps.InfoWindow(title: 'Dropoff'),
        ),
      );
    }

    return markers;
  }

  Widget _buildGoogleMap() {
    final delivery = _selectedDelivery;
    _ensureGoogleRoute(delivery);

    final pickupPoint = _pickupPoint(delivery);
    final dropoffPoint = _dropoffPoint(delivery);
    final driverPoint = _lastPosition == null
        ? null
        : gmaps.LatLng(_lastPosition!.latitude, _lastPosition!.longitude);

    final polylines = <gmaps.Polyline>{};
    final hasRoute = _googleRoutePoints.isNotEmpty &&
        _routeForDeliveryId == delivery?['id'];

    if (hasRoute) {
      polylines.add(
        gmaps.Polyline(
          polylineId: const gmaps.PolylineId('route'),
          points: _googleRoutePoints,
          color: const Color(0xFFF97316),
          width: 5,
        ),
      );
    } else if (pickupPoint != null && dropoffPoint != null) {
      polylines.add(
        gmaps.Polyline(
          polylineId: const gmaps.PolylineId('route'),
          points: [
            gmaps.LatLng(pickupPoint.latitude, pickupPoint.longitude),
            gmaps.LatLng(dropoffPoint.latitude, dropoffPoint.longitude),
          ],
          color: const Color(0xFFF97316),
          width: 5,
        ),
      );
    }

    final center = driverPoint ??
        (pickupPoint != null
            ? gmaps.LatLng(pickupPoint.latitude, pickupPoint.longitude)
            : gmaps.LatLng(defaultMapCenter.latitude, defaultMapCenter.longitude));

    return gmaps.GoogleMap(
      initialCameraPosition: gmaps.CameraPosition(
        target: center,
        zoom: _lastPosition == null ? 12 : 15,
      ),
      markers: _googleMarkers(driverPoint, pickupPoint, dropoffPoint),
      polylines: polylines,
      myLocationButtonEnabled: false,
      zoomControlsEnabled: false,
      mapToolbarEnabled: false,
      compassEnabled: false,
      onMapCreated: (controller) => _googleMapController = controller,
      onTap: (_) => unawaited(_showDriverLocationOnMap()),
    );
  }

  Widget _buildOsmMap() {
    final currentPoint = _currentMapCenter;
    final delivery = _selectedDelivery;
    final pickupPoint = _pickupPoint(delivery);
    final dropoffPoint = _dropoffPoint(delivery);
    final deliveryStatus = delivery?['status'] as String?;
    final nextTargetPoint = deliveryStatus == 'assigned'
        ? pickupPoint
        : (deliveryStatus == 'picked_up' || deliveryStatus == 'in_transit')
        ? dropoffPoint
        : null;

    return FlutterMap(
      mapController: _mapController,
      options: MapOptions(
        initialCenter: currentPoint,
        initialZoom: _lastPosition == null ? 12 : 15,
        onTap: (_, _) => unawaited(_showDriverLocationOnMap()),
      ),
      children: [
        TileLayer(
          urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
          userAgentPackageName: 'com.example.driver_app',
        ),
        if (_lastPosition != null && nextTargetPoint != null)
          PolylineLayer(
            polylines: [
              Polyline(
                points: [currentPoint, nextTargetPoint],
                color: const Color(0xFF111827),
                strokeWidth: 5,
              ),
            ],
          ),
        MarkerLayer(
          markers: [
            if (_lastPosition != null)
              Marker(
                point: currentPoint,
                width: 52,
                height: 52,
                child: Container(
                  decoration: BoxDecoration(
                    color: const Color(0xFF111827),
                    border: Border.all(color: Colors.white, width: 3),
                    shape: BoxShape.circle,
                    boxShadow: const [
                      BoxShadow(
                        blurRadius: 18,
                        color: Colors.black26,
                        offset: Offset(0, 8),
                      ),
                    ],
                  ),
                  child: const Icon(Icons.local_shipping, color: Colors.white),
                ),
              ),
            if (pickupPoint != null)
              Marker(
                point: pickupPoint,
                width: 48,
                height: 48,
                child: _buildMapPin(
                  icon: Icons.inventory_2,
                  color: const Color(0xFF16A34A),
                ),
              ),
            if (dropoffPoint != null)
              Marker(
                point: dropoffPoint,
                width: 48,
                height: 48,
                child: _buildMapPin(
                  icon: Icons.flag,
                  color: const Color(0xFFDC2626),
                ),
              ),
            if (_lastPosition == null)
              Marker(
                point: currentPoint,
                width: 160,
                height: 44,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(999),
                    boxShadow: const [
                      BoxShadow(
                        blurRadius: 18,
                        color: Colors.black26,
                        offset: Offset(0, 8),
                      ),
                    ],
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.touch_app, size: 18),
                      SizedBox(width: 6),
                      Text(
                        'Tap map for GPS',
                        style: TextStyle(fontWeight: FontWeight.w800),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }

  Widget _buildMapPin({required IconData icon, required Color color}) {
    return Container(
      decoration: BoxDecoration(
        color: color,
        border: Border.all(color: Colors.white, width: 3),
        shape: BoxShape.circle,
        boxShadow: const [
          BoxShadow(
            blurRadius: 18,
            color: Colors.black26,
            offset: Offset(0, 8),
          ),
        ],
      ),
      child: Icon(icon, color: Colors.white, size: 20),
    );
  }

  Widget _buildMapControls() {
    return Positioned(
      top: 104,
      right: 14,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Material(
            color: Colors.white,
            shape: const CircleBorder(),
            elevation: 8,
            child: IconButton(
              onPressed: _isSendingLocation
                  ? null
                  : () => unawaited(_showDriverLocationOnMap()),
              icon: _isSendingLocation
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.my_location),
              tooltip: 'Show my location',
            ),
          ),
          if (_showLocationDetails && _lastPosition != null) ...[
            const SizedBox(height: 12),
            Container(
              width: 230,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(20),
                boxShadow: const [
                  BoxShadow(
                    blurRadius: 24,
                    color: Colors.black26,
                    offset: Offset(0, 10),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.near_me, size: 18),
                      const SizedBox(width: 8),
                      const Expanded(
                        child: Text(
                          'You are here',
                          style: TextStyle(fontWeight: FontWeight.w900),
                        ),
                      ),
                      InkWell(
                        onTap: () {
                          setState(() {
                            _showLocationDetails = false;
                          });
                        },
                        borderRadius: BorderRadius.circular(999),
                        child: const Padding(
                          padding: EdgeInsets.all(4),
                          child: Icon(Icons.close, size: 16),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Lat ${_lastPosition!.latitude.toStringAsFixed(5)}, '
                    'Lng ${_lastPosition!.longitude.toStringAsFixed(5)}',
                    style: const TextStyle(
                      color: Color(0xFF4B5563),
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Accuracy about ${_lastPosition!.accuracy.toStringAsFixed(0)} m',
                    style: const TextStyle(
                      color: Color(0xFF4B5563),
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildMapTopBar(
    BuildContext context,
    DriverWorkflowStep workflowStep,
  ) {
    final canReturnToAssignments =
        _selectedDelivery?['status'] == 'assigned' ||
        workflowStep == DriverWorkflowStep.completed;
    final title = switch (workflowStep) {
      DriverWorkflowStep.routePreview => 'Pickup map',
      DriverWorkflowStep.liveTracking => 'Delivery route',
      DriverWorkflowStep.completed => 'Completed',
      DriverWorkflowStep.assignments => 'Assignments',
    };

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            if (canReturnToAssignments) ...[
              Material(
                color: Colors.white,
                shape: const CircleBorder(),
                elevation: 8,
                child: IconButton(
                  onPressed: () {
                    setState(() {
                      _selectedDeliveryId = null;
                      _showLocationDetails = false;
                    });
                  },
                  icon: const Icon(Icons.arrow_back),
                  tooltip: 'Back to assignments',
                ),
              ),
              const SizedBox(width: 10),
            ],
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(999),
                boxShadow: const [
                  BoxShadow(
                    blurRadius: 20,
                    color: Colors.black26,
                    offset: Offset(0, 8),
                  ),
                ],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    style: const TextStyle(fontWeight: FontWeight.w900),
                  ),
                  const SizedBox(width: 8),
                  _buildLivePill(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildWorkflowSheet(
    BuildContext context,
    DriverWorkflowStep workflowStep,
  ) {
    final initialSheetSize = switch (workflowStep) {
      DriverWorkflowStep.routePreview => 0.36,
      DriverWorkflowStep.liveTracking => 0.30,
      DriverWorkflowStep.completed => 0.30,
      DriverWorkflowStep.assignments => 0.36,
    };

    return DraggableScrollableSheet(
      initialChildSize: initialSheetSize,
      minChildSize: 0.20,
      maxChildSize: 0.68,
      builder: (context, scrollController) {
        return DecoratedBox(
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
            boxShadow: [
              BoxShadow(
                blurRadius: 30,
                color: Colors.black26,
                offset: Offset(0, -8),
              ),
            ],
          ),
          child: RefreshIndicator(
            onRefresh: _loadDeliveries,
            child: ListView(
              controller: scrollController,
              padding: const EdgeInsets.fromLTRB(18, 10, 18, 28),
              children: [
                Center(
                  child: Container(
                    width: 42,
                    height: 5,
                    margin: const EdgeInsets.only(bottom: 16),
                    decoration: BoxDecoration(
                      color: const Color(0xFFE5E7EB),
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                ),
                if (workflowStep == DriverWorkflowStep.routePreview)
                  _buildRoutePreviewStep(context)
                else if (workflowStep == DriverWorkflowStep.liveTracking)
                  _buildLiveTrackingStep(context)
                else
                  _buildCompletedStep(context),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildAssignmentsPage(BuildContext context) {
    final activeDeliveries = _activeDeliveries;

    // Single-screen layout: no vertical scrolling. The In Progress area flexes
    // to absorb remaining height so nothing overflows on smaller devices.
    return SafeArea(
      bottom: false,
      child: Column(
        children: [
          _buildHomeHero(activeDeliveries),
          const SizedBox(height: 14),
          _buildSectionHeader('In Progress', 'See All'),
          const SizedBox(height: 10),
          Expanded(
            child: _isLoadingDeliveries
                ? const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 24),
                    child: Align(
                      alignment: Alignment.topCenter,
                      child: LinearProgressIndicator(),
                    ),
                  )
                : _buildInProgressCarousel(activeDeliveries),
          ),
          const SizedBox(height: 12),
          _buildPromoStrip(),
          const SizedBox(height: 12),
        ],
      ),
    );
  }

  Widget _buildHomeHero(List<Map<String, dynamic>> activeDeliveries) {
    return SizedBox(
      height: 278,
      child: Stack(
        children: [
          Container(
            height: 232,
            padding: const EdgeInsets.fromLTRB(24, 14, 24, 66),
            decoration: const BoxDecoration(
              color: stanDark,
              borderRadius: BorderRadius.vertical(bottom: Radius.circular(24)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    _buildDriverAvatar(46),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Welcome back, ${widget.fullName.split(' ').first}!',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: stanMuted,
                              fontSize: 13,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(height: 2),
                          const Row(
                            children: [
                              Flexible(
                                child: Text(
                                  'Nairobi UTC+3',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 14,
                                    fontWeight: FontWeight.w900,
                                  ),
                                ),
                              ),
                              SizedBox(width: 4),
                              Icon(
                                Icons.keyboard_arrow_down,
                                color: Colors.white,
                                size: 16,
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    _buildNotificationBell(activeDeliveries.length),
                  ],
                ),
                const Spacer(),
                const Text(
                  'Track Your Package',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w900,
                    letterSpacing: -0.2,
                  ),
                ),
                const SizedBox(height: 16),
                _buildTrackingSearch(activeDeliveries),
              ],
            ),
          ),
          Positioned(
            left: 24,
            right: 24,
            bottom: 0,
            child: Row(
              children: [
                Expanded(
                  child: _buildTransportCard(
                    icon: Icons.pedal_bike,
                    label: 'Bike',
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: _buildTransportCard(
                    icon: Icons.local_shipping_outlined,
                    label: 'Truck',
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: _buildTransportCard(
                    icon: Icons.directions_car_outlined,
                    label: 'Car',
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDriverAvatar(double size) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white.withValues(alpha: 0.18), width: 2),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.28),
            blurRadius: 20,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: _buildAvatarFallback(size),
    );
  }

  Widget _buildAvatarFallback(double size) {
    return Container(
      color: const Color(0xFFE7C19E),
      child: Stack(
        alignment: Alignment.center,
        children: [
          Positioned(
            top: size * 0.08,
            child: Container(
              width: size * 0.62,
              height: size * 0.62,
              decoration: const BoxDecoration(
                color: Color(0xFF1D2328),
                shape: BoxShape.circle,
              ),
            ),
          ),
          Positioned(
            top: size * 0.22,
            child: Container(
              width: size * 0.38,
              height: size * 0.38,
              decoration: const BoxDecoration(
                color: Color(0xFFF1C69F),
                shape: BoxShape.circle,
              ),
            ),
          ),
          Positioned(
            bottom: -size * 0.20,
            child: Container(
              width: size * 0.72,
              height: size * 0.54,
              decoration: const BoxDecoration(
                color: Color(0xFF1D2328),
                borderRadius: BorderRadius.vertical(top: Radius.circular(999)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNotificationBell(int count) {
    return Container(
      width: 46,
      height: 46,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.08),
        shape: BoxShape.circle,
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          const Icon(Icons.notifications_none, color: Colors.white, size: 22),
          Positioned(
            right: 11,
            top: 10,
            child: Container(
              width: 9,
              height: 9,
              decoration: BoxDecoration(
                color: count > 0 ? const Color(0xFFEAF264) : stanMuted,
                shape: BoxShape.circle,
                border: Border.all(color: stanDark, width: 1.5),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTrackingSearch(List<Map<String, dynamic>> activeDeliveries) {
    return Container(
      height: 52,
      padding: const EdgeInsets.only(left: 22, right: 6),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              activeDeliveries.isEmpty
                  ? 'Enter Tracking Number'
                  : 'STAN-${activeDeliveries.first['id'].toString().padLeft(5, '0')}',
              style: TextStyle(
                color: activeDeliveries.isEmpty ? const Color(0xFF9AA6AD) : stanDark,
                fontSize: 13,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          Container(
            width: 42,
            height: 42,
            decoration: const BoxDecoration(
              color: stanDark,
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.search, color: Colors.white, size: 21),
          ),
        ],
      ),
    );
  }

  Widget _buildTransportCard({required IconData icon, required String label}) {
    return Container(
      height: 88,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, color: stanDark, size: 26),
          const SizedBox(height: 8),
          Text(
            label,
            style: const TextStyle(
              color: stanDark,
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(String title, String action) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: const TextStyle(
                color: stanDark,
                fontSize: 19,
                fontWeight: FontWeight.w900,
                letterSpacing: -0.4,
              ),
            ),
          ),
          TextButton(
            onPressed: _isLoadingDeliveries ? null : _loadDeliveries,
            style: TextButton.styleFrom(foregroundColor: stanDark),
            child: Text(
              action,
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
          ),
        ],
      ),
    );
  }

  String _trackingCode(int deliveryId) {
    return 'STAN-${deliveryId.toString().padLeft(5, '0')}';
  }

  Widget _buildInProgressCarousel(List<Map<String, dynamic>> activeDeliveries) {
    if (activeDeliveries.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: _buildEmptyTrackingCard(),
      );
    }

    final screenWidth = MediaQuery.of(context).size.width;
    final cardWidth = activeDeliveries.length > 1
        ? screenWidth * 0.86
        : screenWidth - 48;

    return ListView.separated(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      scrollDirection: Axis.horizontal,
      itemCount: activeDeliveries.length,
      separatorBuilder: (_, _) => const SizedBox(width: 16),
      itemBuilder: (context, index) {
        return SizedBox(
          width: cardWidth,
          child: _buildTrackingCard(activeDeliveries[index]),
        );
      },
    );
  }

  Widget _buildTrackingCard(Map<String, dynamic> delivery) {
    final deliveryId = delivery['id'] as int;
    final status = delivery['status'] as String;

    return InkWell(
      onTap: () {
        setState(() {
          _selectedDeliveryId = deliveryId;
        });
        unawaited(_startTracking());
      },
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0xFFE2E8F0)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        delivery['customerName'] as String,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: stanDark,
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.2,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        _trackingCode(deliveryId),
                        style: const TextStyle(
                          color: Color(0xFF64748B),
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.3,
                        ),
                      ),
                    ],
                  ),
                ),
                _buildStatusPill(status),
              ],
            ),
            const SizedBox(height: 16),
            _buildRouteConnector(delivery),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyTrackingCard() {
    return Container(
      height: 150,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Row(
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: stanDark,
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(
              Icons.local_shipping_outlined,
              color: Colors.white,
              size: 26,
            ),
          ),
          const SizedBox(width: 16),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  'No active delivery',
                  style: TextStyle(
                    color: stanDark,
                    fontSize: 16,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                SizedBox(height: 4),
                Text(
                  'Dispatch will assign your next pickup. Pull down to refresh.',
                  style: TextStyle(
                    color: stanMuted,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPromoStrip() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Container(
        padding: const EdgeInsets.fromLTRB(18, 14, 14, 14),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
            colors: [stanDark, stanPanel],
          ),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Today\'s Promo',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.7),
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.4,
                    ),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'Save up to 50% on bulk deliveries',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      height: 1.2,
                      fontWeight: FontWeight.w900,
                      letterSpacing: -0.3,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 14),
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(
                Icons.local_shipping_outlined,
                color: Colors.white,
                size: 26,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBottomNavigation() {
    final items = [
      (Icons.home_rounded, 'Home'),
      (Icons.inventory_2_outlined, 'Shipments'),
      (Icons.chat_bubble_outline_rounded, 'Messages'),
      (Icons.person_outline_rounded, 'Profile'),
    ];

    return Container(
      height: 78,
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 14),
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 24,
            offset: const Offset(0, -8),
          ),
        ],
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          for (var index = 0; index < items.length; index++)
            _buildBottomNavigationItem(
              icon: items[index].$1,
              label: items[index].$2,
              index: index,
            ),
        ],
      ),
    );
  }

  Widget _buildBottomNavigationItem({
    required IconData icon,
    required String label,
    required int index,
  }) {
    final isSelected = _selectedNavIndex == index;

    return InkWell(
      onTap: () {
        setState(() {
          _selectedNavIndex = index;
        });
      },
      borderRadius: BorderRadius.circular(999),
      child: SizedBox(
        width: 66,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              color: isSelected ? stanDark : const Color(0xFFB4BDC3),
              size: 25,
            ),
            const SizedBox(height: 4),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: isSelected ? stanDark : const Color(0xFFB4BDC3),
                fontSize: 10,
                fontWeight: FontWeight.w900,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildShipmentsPage(BuildContext context) {
    final activeDeliveries = _activeDeliveries;
    final completedDeliveries = _deliveries
        .where((delivery) => delivery['status'] == 'delivered')
        .toList();

    return _buildTabPage(
      title: 'Shipments',
      subtitle: 'Manage active and completed Stan packages.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (activeDeliveries.isEmpty)
            _buildEmptyAssignmentsCard()
          else
            ...activeDeliveries.map(_buildAssignmentCard),
          const SizedBox(height: 8),
          Text(
            'Completed (${completedDeliveries.length})',
            style: const TextStyle(
              color: stanDark,
              fontSize: 18,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 12),
          if (completedDeliveries.isEmpty)
            _buildInfoPanel(
              Icons.done_all,
              'No completed deliveries yet',
              'Finished shipments will appear here after proof of delivery.',
            )
          else
            ...completedDeliveries.map(_buildAssignmentCard),
        ],
      ),
    );
  }

  Widget _buildMessagesPage(BuildContext context) {
    final activeDeliveries = _activeDeliveries;
    final hasActive = activeDeliveries.isNotEmpty;
    final activeCustomer = hasActive
        ? activeDeliveries.first['customerName'] as String
        : 'your next pickup';

    return _buildTabPage(
      title: 'Messages',
      subtitle: 'Dispatcher updates and customer notes.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildMessageItem(
            initials: 'OP',
            color: const Color(0xFF2563EB),
            name: 'Stan Dispatch',
            preview: hasActive
                ? 'You\'re assigned to $activeCustomer. Drive safe!'
                : 'No active job right now — stay online for the next one.',
            time: 'now',
            unread: hasActive,
          ),
          _buildMessageItem(
            initials: 'RT',
            color: const Color(0xFF16A34A),
            name: 'Route Assistant',
            preview: 'Live GPS is shared with the owner while a delivery is active.',
            time: '2m',
            unread: false,
          ),
          _buildMessageItem(
            initials: 'CS',
            color: const Color(0xFFF59E0B),
            name: 'Customer Support',
            preview: 'Tap here if a customer is unreachable at the dropoff.',
            time: '1h',
            unread: false,
          ),
          const SizedBox(height: 8),
          _buildInfoPanel(
            Icons.lock_outline_rounded,
            'Two-way chat coming soon',
            'This demo shows where dispatcher, route, and customer messages live. Real-time chat connects in a later phase.',
          ),
        ],
      ),
    );
  }

  Widget _buildMessageItem({
    required String initials,
    required Color color,
    required String name,
    required String preview,
    required String time,
    required bool unread,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Center(
              child: Text(
                initials,
                style: TextStyle(
                  color: color,
                  fontWeight: FontWeight.w900,
                  fontSize: 14,
                ),
              ),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        name,
                        style: const TextStyle(
                          color: stanDark,
                          fontSize: 15,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                    Text(
                      time,
                      style: const TextStyle(
                        color: stanMuted,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  preview,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xFF60727A),
                    fontSize: 13,
                    height: 1.35,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          if (unread) ...[
            const SizedBox(width: 10),
            Container(
              width: 9,
              height: 9,
              margin: const EdgeInsets.only(top: 6),
              decoration: const BoxDecoration(
                color: Color(0xFF2563EB),
                shape: BoxShape.circle,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildProfilePage(BuildContext context) {
    return _buildTabPage(
      title: 'Profile',
      subtitle: 'Driver account, vehicle, and app status.',
      child: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: stanDark,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(
              children: [
                _buildDriverAvatar(66),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.fullName,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 20,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${widget.role.toUpperCase()} • Stan active',
                        style: const TextStyle(
                          color: stanMuted,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: _buildStatTile(
                  '${_activeDeliveries.length}',
                  'Active',
                  Icons.local_shipping_outlined,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _buildStatTile(
                  '${_deliveries.where((d) => d['status'] == 'delivered').length}',
                  'Delivered',
                  Icons.check_circle_outline,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _buildStatTile(
                  _isTracking ? 'On' : 'Off',
                  'GPS',
                  Icons.gps_fixed,
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: const Color(0xFFE2E8F0)),
            ),
            child: Column(
              children: [
                _buildMenuRow(
                  Icons.directions_car_outlined,
                  'Vehicle',
                  'Bike • Car • Truck',
                ),
                _buildMenuDivider(),
                _buildMenuRow(
                  Icons.notifications_none_rounded,
                  'Notifications',
                  'Pickup alerts and route changes',
                ),
                _buildMenuDivider(),
                _buildMenuRow(
                  Icons.location_on_outlined,
                  'Tracking',
                  _isTracking ? 'Live — sharing GPS' : 'Off — open a shipment to start',
                ),
                _buildMenuDivider(),
                _buildMenuRow(
                  Icons.help_outline_rounded,
                  'Help & support',
                  'Contact Stan dispatch',
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          OutlinedButton.icon(
            onPressed: _signOut,
            style: OutlinedButton.styleFrom(
              foregroundColor: const Color(0xFFDC2626),
              side: const BorderSide(color: Color(0xFFF1C7C7)),
              padding: const EdgeInsets.symmetric(vertical: 15),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(999),
              ),
            ),
            icon: const Icon(Icons.logout_rounded, size: 18),
            label: const Text(
              'Sign out',
              style: TextStyle(fontWeight: FontWeight.w900),
            ),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  void _signOut() {
    _stopTrackingTimerOnly();
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const LoginScreen()),
      (route) => false,
    );
  }

  void _stopTrackingTimerOnly() {
    _trackingTimer?.cancel();
    _trackingTimer = null;
  }

  Widget _buildStatTile(String value, String label, IconData icon) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Column(
        children: [
          Icon(icon, color: stanDark, size: 22),
          const SizedBox(height: 8),
          Text(
            value,
            style: const TextStyle(
              color: stanDark,
              fontSize: 20,
              fontWeight: FontWeight.w900,
              letterSpacing: -0.5,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: const TextStyle(
              color: stanMuted,
              fontSize: 11,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMenuRow(IconData icon, String title, String subtitle) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: stanSurface,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(icon, color: stanDark, size: 20),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: stanDark,
                    fontSize: 15,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: stanMuted,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          const Icon(
            Icons.chevron_right_rounded,
            color: Color(0xFFB4BDC3),
          ),
        ],
      ),
    );
  }

  Widget _buildMenuDivider() {
    return const Divider(height: 1, thickness: 1, color: Color(0xFFF1F5F8));
  }

  Widget _buildTabPage({
    required String title,
    required String subtitle,
    required Widget child,
  }) {
    return SafeArea(
      bottom: false,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(24, 22, 24, 110),
        children: [
          Row(
            children: [
              const StanMark(size: 48),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        color: stanDark,
                        fontSize: 28,
                        fontWeight: FontWeight.w900,
                        letterSpacing: -0.8,
                      ),
                    ),
                    Text(
                      subtitle,
                      style: const TextStyle(
                        color: Color(0xFF60727A),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          child,
        ],
      ),
    );
  }

  Widget _buildInfoPanel(IconData icon, String title, String body) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              color: stanSurface,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Icon(icon, color: stanDark),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: stanDark,
                    fontSize: 16,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  body,
                  style: const TextStyle(
                    color: Color(0xFF60727A),
                    height: 1.4,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyAssignmentsCard() {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(26),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Icon(Icons.inventory_2_outlined, size: 40),
          const SizedBox(height: 16),
          const Text(
            'No active shipment assigned',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 8),
          const Text(
            'When dispatch assigns a shipment, it will appear here automatically after refresh.',
            style: TextStyle(color: Color(0xFF6B7280), height: 1.4),
          ),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: _loadDeliveries,
            child: const Text('Refresh assignments'),
          ),
        ],
      ),
    );
  }

  int _statusStep(String status) {
    switch (status) {
      case 'assigned':
        return 1;
      case 'picked_up':
        return 2;
      case 'in_transit':
        return 3;
      case 'delivered':
        return 4;
      default:
        return 0;
    }
  }

  Widget _buildAssignmentCard(Map<String, dynamic> delivery) {
    final deliveryId = delivery['id'] as int;
    final status = delivery['status'] as String;
    final isDelivered = status == 'delivered';

    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      delivery['customerName'] as String,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _trackingCode(deliveryId),
                      style: const TextStyle(
                        color: stanMuted,
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.4,
                      ),
                    ),
                  ],
                ),
              ),
              _buildStatusPill(status),
            ],
          ),
          const SizedBox(height: 18),
          _buildRouteConnector(delivery),
          const SizedBox(height: 18),
          _buildMiniStepper(status),
          const SizedBox(height: 18),
          if (isDelivered)
            _buildDeliveredFooter()
          else
            FilledButton(
              onPressed: () {
                setState(() {
                  _selectedDeliveryId = deliveryId;
                });
                unawaited(_startTracking());
              },
              child: Text(
                status == 'assigned' ? 'Open pickup map' : 'Open live map',
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildDeliveredFooter() {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: const Color(0xFF16A34A).withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(999),
      ),
      child: const Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.check_circle, color: Color(0xFF16A34A), size: 18),
          SizedBox(width: 8),
          Text(
            'Delivered',
            style: TextStyle(
              color: Color(0xFF15803D),
              fontWeight: FontWeight.w900,
              letterSpacing: 0.3,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRouteConnector(Map<String, dynamic> delivery) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Column(
          children: [
            const SizedBox(height: 3),
            _routeDot(const Color(0xFF16A34A)),
            Container(
              width: 2,
              height: 24,
              margin: const EdgeInsets.symmetric(vertical: 2),
              color: const Color(0xFFE2E8F0),
            ),
            _routeDot(const Color(0xFFDC2626)),
          ],
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildRouteEndpoint('Pickup', delivery['pickupAddress'] as String),
              const SizedBox(height: 14),
              _buildRouteEndpoint(
                'Dropoff',
                delivery['dropoffAddress'] as String,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _routeDot(Color color) {
    return Container(
      width: 12,
      height: 12,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.18),
        shape: BoxShape.circle,
      ),
      child: Center(
        child: Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
      ),
    );
  }

  Widget _buildRouteEndpoint(String label, String address) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            color: stanMuted,
            fontSize: 11,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.3,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          address,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: stanDark,
            fontSize: 14.5,
            fontWeight: FontWeight.w800,
          ),
        ),
      ],
    );
  }

  Widget _buildMiniStepper(String status) {
    final step = _statusStep(status);
    const labels = ['Assigned', 'Picked up', 'In transit', 'Delivered'];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            for (var i = 1; i <= 4; i++) ...[
              Expanded(
                child: Container(
                  height: 5,
                  decoration: BoxDecoration(
                    color: i <= step
                        ? stanDark
                        : const Color(0xFFE2E8F0),
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
              ),
              if (i < 4) const SizedBox(width: 5),
            ],
          ],
        ),
        const SizedBox(height: 7),
        Text(
          step >= 1 && step <= 4 ? labels[step - 1] : 'Pending',
          style: const TextStyle(
            color: stanDark,
            fontSize: 12,
            fontWeight: FontWeight.w800,
          ),
        ),
      ],
    );
  }

  Widget _buildRoutePreviewStep(BuildContext context) {
    final delivery = _selectedDelivery;

    if (delivery == null) return const SizedBox.shrink();

    final deliveryId = delivery['id'] as int;
    final isUpdating = _updatingDeliveryId == deliveryId;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildStepLabel('Step 2 of 4'),
        const SizedBox(height: 8),
        Text(
          'Go to pickup',
          style: Theme.of(
            context,
          ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w900),
        ),
        const SizedBox(height: 8),
        const Text(
          'Use the map to get to the pickup point. Transit does not start until you collect the package.',
          style: TextStyle(color: Color(0xFF6B7280), height: 1.4),
        ),
        const SizedBox(height: 20),
        _buildMiniStepper(delivery['status'] as String),
        const SizedBox(height: 20),
        _buildRouteConnector(delivery),
        if (_statusMessage != null) ...[
          const SizedBox(height: 16),
          Text(_statusMessage!),
        ],
        const SizedBox(height: 24),
        FilledButton(
          onPressed: isUpdating
              ? null
              : () => _updateDeliveryStatus(deliveryId, 'picked_up'),
          child: Text(isUpdating ? 'Updating...' : 'Package picked up'),
        ),
        const SizedBox(height: 8),
        TextButton(
          onPressed: () {
            setState(() {
              _selectedDeliveryId = null;
            });
          },
          child: const Text('Back to assignments'),
        ),
      ],
    );
  }

  Widget _buildLiveTrackingStep(BuildContext context) {
    final delivery = _selectedDelivery;

    if (delivery == null) return const SizedBox.shrink();

    final deliveryId = delivery['id'] as int;
    final status = delivery['status'] as String;
    final nextStatus = _nextStatus(status);
    final isUpdating = _updatingDeliveryId == deliveryId;
    final isInTransit = status == 'in_transit';
    final primaryLabel = isInTransit
        ? 'Complete delivery'
        : 'Start delivery route';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildStepLabel(isInTransit ? 'Step 4 of 4' : 'Step 3 of 4'),
        const SizedBox(height: 8),
        Text(
          isInTransit ? 'Delivering package' : 'Package picked up',
          style: Theme.of(
            context,
          ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w900),
        ),
        const SizedBox(height: 8),
        Text(
          isInTransit
              ? 'Follow the map toward the destination. Keep tracking active so the owner sees progress.'
              : 'Start the delivery route only when you are leaving the pickup point with the package.',
          style: const TextStyle(color: Color(0xFF6B7280), height: 1.4),
        ),
        const SizedBox(height: 20),
        Row(
          children: [
            _buildStatusPill(status),
            const SizedBox(width: 8),
            _buildLivePill(),
            const Spacer(),
            _buildDistanceChip(delivery),
          ],
        ),
        const SizedBox(height: 20),
        _buildMiniStepper(status),
        const SizedBox(height: 20),
        _buildRouteConnector(delivery),
        if (_statusMessage != null) ...[
          const SizedBox(height: 16),
          Text(_statusMessage!),
        ],
        const SizedBox(height: 24),
        if (nextStatus != null)
          FilledButton(
            onPressed: isUpdating
                ? null
                : () => _updateDeliveryStatus(deliveryId, nextStatus),
            child: Text(isUpdating ? 'Updating...' : primaryLabel),
          ),
        if (isInTransit) ...[
          const SizedBox(height: 8),
          const Text(
            'Automatic completion is active when destination GPS coordinates are available. You can still complete manually if needed.',
            style: TextStyle(color: Color(0xFF6B7280), fontSize: 12),
          ),
        ],
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: _isSendingLocation ? null : _sendCurrentLocation,
          icon: _isSendingLocation
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.my_location),
          label: Text(_isSendingLocation ? 'Sending...' : 'Send location now'),
        ),
      ],
    );
  }

  Widget _buildCompletedStep(BuildContext context) {
    final delivery = _selectedDelivery;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Center(
          child: Container(
            width: 76,
            height: 76,
            decoration: BoxDecoration(
              color: const Color(0xFF16A34A).withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.check_rounded,
              color: Color(0xFF16A34A),
              size: 42,
            ),
          ),
        ),
        const SizedBox(height: 18),
        Center(
          child: Text(
            'Delivery completed',
            style: Theme.of(
              context,
            ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w900),
          ),
        ),
        const SizedBox(height: 8),
        const Text(
          'The owner can now see this job as delivered. Return to your assignments for the next delivery.',
          textAlign: TextAlign.center,
          style: TextStyle(color: Color(0xFF6B7280), height: 1.4),
        ),
        if (delivery != null) ...[
          const SizedBox(height: 22),
          _buildMiniStepper('delivered'),
          const SizedBox(height: 18),
          _buildRouteConnector(delivery),
        ],
        const SizedBox(height: 24),
        FilledButton(
          onPressed: () {
            setState(() {
              _selectedDeliveryId = null;
            });
          },
          child: const Text('Back to assignments'),
        ),
      ],
    );
  }

  Widget _buildDistanceChip(Map<String, dynamic> delivery) {
    final dropoffPoint = _dropoffPoint(delivery);

    if (_lastPosition == null || dropoffPoint == null) {
      return const SizedBox.shrink();
    }

    final meters = calculateDistanceMeters(
      LatLng(_lastPosition!.latitude, _lastPosition!.longitude),
      dropoffPoint,
    );
    final label = meters >= 1000
        ? '${(meters / 1000).toStringAsFixed(1)} km'
        : '${meters.round()} m';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: stanDark,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.navigation_rounded, color: Colors.white, size: 13),
          const SizedBox(width: 5),
          Text(
            '$label to go',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 11,
              fontWeight: FontWeight.w900,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStepLabel(String text) {
    return Text(
      text.toUpperCase(),
      style: const TextStyle(
        color: Color(0xFF6B7280),
        fontSize: 12,
        fontWeight: FontWeight.w900,
        letterSpacing: 0.6,
      ),
    );
  }

  Widget _buildStatusPill(String status) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: const Color(0xFFF1F5F9),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        formatDeliveryStatus(status).toUpperCase(),
        style: const TextStyle(
          color: Color(0xFF475569),
          fontSize: 10.5,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.6,
        ),
      ),
    );
  }

  Widget _buildLivePill() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: _isTracking ? const Color(0xFFDCFCE7) : const Color(0xFFFEE2E2),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        _isTracking ? 'LIVE' : 'OFF',
        style: TextStyle(
          color: _isTracking
              ? const Color(0xFF166534)
              : const Color(0xFF991B1B),
          fontSize: 11,
          fontWeight: FontWeight.w900,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}
