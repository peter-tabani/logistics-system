import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' as gmaps;
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

const String configuredApiBaseUrl = String.fromEnvironment('API_BASE_URL');
// Default backend = the always-on Render deployment, so the app works from any
// network out of the box. A build-time --dart-define=API_BASE_URL overrides it,
// and the user can still change it at runtime via login → Server settings.
const String defaultApiBaseUrl =
    configuredApiBaseUrl == '' ? 'https://stan-backend.onrender.com' : configuredApiBaseUrl;
const String apiBaseUrlPrefKey = 'apiBaseUrl';
// Overridable at runtime via the login screen's "Server settings" so a changed
// PC Wi-Fi IP doesn't require a rebuild.
String apiBaseUrl = defaultApiBaseUrl;
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

// ── Liquid-glass design system ──────────────────────────────────────────────
// Performance-first glassmorphism. Real BackdropFilter blur is used only where
// it stays smooth (static backgrounds, small chrome). When the OS requests
// reduced motion — or blur is disallowed over moving content like the live map —
// panels render as near-solid premium surfaces instead. A light-refracting edge
// border plus an ambient top sheen give the "glass pane catching light" look
// even without blur.

bool _forceSolidSurfaces = false; // global kill-switch for the blur path.

bool glassEnabled(BuildContext context) {
  if (_forceSolidSurfaces) return false;
  final mq = MediaQuery.maybeOf(context);
  if (mq == null) return true;
  if (mq.disableAnimations) return false; // respect "remove animations"
  return true;
}

/// Soft shadow for floating "island" glass elements.
const List<BoxShadow> glassShadow = [
  BoxShadow(color: Color(0x33000000), blurRadius: 28, offset: Offset(0, 12)),
];

/// A frosted-glass panel. [allowBlur] should be false over continuously moving
/// content (e.g. a live map) to protect frame rate — it then renders as a
/// near-solid premium surface with the same glass styling.
class GlassPanel extends StatelessWidget {
  const GlassPanel({
    super.key,
    required this.child,
    this.radius = 20,
    this.blurSigma = 16,
    this.padding,
    this.dark = false,
    this.baseColor,
    this.allowBlur = true,
    this.shadow = false,
  });

  final Widget child;
  final double radius;
  final double blurSigma;
  final EdgeInsetsGeometry? padding;
  final bool dark;
  final Color? baseColor;
  final bool allowBlur;
  final bool shadow;

  @override
  Widget build(BuildContext context) {
    final useBlur = allowBlur && glassEnabled(context);
    final base = baseColor ?? (dark ? stanDark : Colors.white);
    // Translucent when blurring so the background shows through; near-solid
    // (premium fallback) when not.
    final fill = useBlur
        ? base.withValues(alpha: dark ? 0.58 : 0.62)
        : base.withValues(alpha: dark ? 1.0 : 1.0);
    final borderRadius = BorderRadius.circular(radius);

    Widget content = DecoratedBox(
      decoration: BoxDecoration(color: fill, borderRadius: borderRadius),
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: borderRadius,
          // Ambient top sheen — light catching the top of the glass.
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Colors.white.withValues(alpha: dark ? 0.10 : 0.30),
              Colors.white.withValues(alpha: 0.0),
            ],
            stops: const [0.0, 0.5],
          ),
          // Light-refracting edge border.
          border: Border.all(
            color: Colors.white.withValues(alpha: dark ? 0.18 : 0.7),
            width: 1,
          ),
        ),
        child: padding == null ? child : Padding(padding: padding!, child: child),
      ),
    );

    if (useBlur) {
      content = BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: blurSigma, sigmaY: blurSigma),
        child: content,
      );
    }

    content = ClipRRect(borderRadius: borderRadius, child: content);

    if (shadow) {
      content = DecoratedBox(
        decoration: BoxDecoration(borderRadius: borderRadius, boxShadow: glassShadow),
        child: content,
      );
    }

    return content;
  }
}

/// Refracting edge + faint top sheen overlaid on an existing (e.g. gradient)
/// surface — used to glassify the navy cards without losing their gradient.
class GlassSheen extends StatelessWidget {
  const GlassSheen({super.key, this.radius = 18});
  final double radius;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(radius),
          border: Border.all(color: Colors.white.withValues(alpha: 0.16), width: 1),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Colors.white.withValues(alpha: 0.12),
              Colors.white.withValues(alpha: 0.0),
            ],
            stops: const [0.0, 0.55],
          ),
        ),
      ),
    );
  }
}

enum DriverWorkflowStep { assignments, routePreview, liveTracking, completed }

String formatDeliveryStatus(String status) {
  return status.replaceAll('_', ' ');
}

// Wake a sleeping (free-tier) cloud backend early so the first real request
// doesn't time out on a cold start. Fire-and-forget; failure is ignored.
Future<void> warmUpBackend() async {
  try {
    await http
        .get(Uri.parse('$apiBaseUrl/health'))
        .timeout(const Duration(seconds: 45));
  } catch (_) {
    // Ignored — this is only a warm-up.
  }
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

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Draw behind the status bar and navigation bar (edge-to-edge), like modern
  // apps. Screens then use SafeArea / insets to position content correctly.
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);

  // Apply a saved backend-URL override (set on the login screen) if present.
  try {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(apiBaseUrlPrefKey);
    if (saved != null && saved.trim().isNotEmpty) {
      apiBaseUrl = saved.trim();
    }
  } catch (_) {
    // Fall back to the compiled default.
  }

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
    // Start waking a sleeping cloud backend while the splash + login show.
    unawaited(warmUpBackend());
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
                'Delivery made easy',
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

  // Lets the driver point the app at the backend without a rebuild — useful
  // when the PC's Wi-Fi IP changes.
  Future<void> _editServerUrl() async {
    final controller = TextEditingController(text: apiBaseUrl);

    final saved = await showDialog<String>(
      context: context,
      builder: (dialogContext) {
        String? testResult;
        bool testOk = false;
        bool testing = false;

        return StatefulBuilder(
          builder: (dialogContext, setDialog) {
            Future<void> testConnection() async {
              final url = controller.text.trim().replaceAll(RegExp(r'/+$'), '');
              if (url.isEmpty) return;
              setDialog(() {
                testing = true;
                testResult = null;
              });
              try {
                final response = await http
                    .get(Uri.parse('$url/health'))
                    .timeout(const Duration(seconds: 6));
                final ok = response.statusCode == 200 &&
                    response.body.contains('"status":"ok"');
                setDialog(() {
                  testOk = ok;
                  testResult = ok
                      ? 'Connected — backend is reachable.'
                      : 'Reached the server but got an unexpected response (${response.statusCode}).';
                });
              } catch (_) {
                setDialog(() {
                  testOk = false;
                  testResult =
                      'No response. Check the IP, that the phone is on the same Wi-Fi, and that the backend is running.';
                });
              } finally {
                setDialog(() => testing = false);
              }
            }

            return AlertDialog(
              title: const Text('Server settings'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Backend address the app connects to. Use your PC\'s Wi-Fi IP, e.g. '
                    'http://192.168.0.100:5000',
                    style: TextStyle(fontSize: 13, color: Color(0xFF64748B)),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: controller,
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    decoration: const InputDecoration(
                      labelText: 'Server URL',
                      hintText: 'http://192.168.0.100:5000',
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      OutlinedButton.icon(
                        onPressed: testing ? null : testConnection,
                        icon: testing
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.wifi_tethering, size: 16),
                        label: Text(testing ? 'Testing…' : 'Test connection'),
                      ),
                    ],
                  ),
                  if (testResult != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      testResult!,
                      style: TextStyle(
                        fontSize: 12.5,
                        height: 1.35,
                        fontWeight: FontWeight.w600,
                        color: testOk
                            ? const Color(0xFF16A34A)
                            : const Color(0xFFDC2626),
                      ),
                    ),
                  ],
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(defaultApiBaseUrl),
                  child: const Text('Reset'),
                ),
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(dialogContext).pop(controller.text.trim()),
                  child: const Text('Save'),
                ),
              ],
            );
          },
        );
      },
    );

    if (saved == null) return;

    final url = saved.trim();
    final prefs = await SharedPreferences.getInstance();
    if (url.isEmpty || url == defaultApiBaseUrl) {
      await prefs.remove(apiBaseUrlPrefKey);
    } else {
      await prefs.setString(apiBaseUrlPrefKey, url);
    }

    if (!mounted) return;
    setState(() => apiBaseUrl = url.isEmpty ? defaultApiBaseUrl : url);
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
          // Longer than usual to tolerate a free-tier cloud cold start (~30-50s).
          .timeout(const Duration(seconds: 45));

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
              phone: user['phone'] as String? ?? '',
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
            'Could not reach the server at $apiBaseUrl.\nCheck the backend is running and update the address under Server settings.';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  String _friendlyServer(String url) {
    try {
      final uri = Uri.parse(url);
      if (uri.host.contains('render.com')) return 'Cloud (Render)';
      if (uri.host == '10.0.2.2') return 'Emulator';
      if (uri.host == 'localhost') return 'This PC';
      return uri.host;
    } catch (_) {
      return url;
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
                        'Delivery\nMade\nEasy',
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
                      GlassPanel(
                        radius: 28,
                        blurSigma: 18,
                        shadow: true,
                        padding: const EdgeInsets.all(20),
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
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                                color: stanDark,
                              ),
                              decoration: InputDecoration(
                                hintText: 'Phone number',
                                prefixIcon: const Icon(Icons.phone_outlined),
                                filled: true,
                                fillColor: stanSurface,
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 18,
                                  vertical: 18,
                                ),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(18),
                                  borderSide: BorderSide.none,
                                ),
                                enabledBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(18),
                                  borderSide: BorderSide.none,
                                ),
                                focusedBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(18),
                                  borderSide: const BorderSide(
                                    color: Color(0xFF12323A),
                                    width: 1.5,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 14),
                            TextField(
                              controller: _passwordController,
                              obscureText: true,
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                                color: stanDark,
                              ),
                              decoration: InputDecoration(
                                hintText: 'Password',
                                prefixIcon: const Icon(Icons.lock_outline),
                                filled: true,
                                fillColor: stanSurface,
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 18,
                                  vertical: 18,
                                ),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(18),
                                  borderSide: BorderSide.none,
                                ),
                                enabledBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(18),
                                  borderSide: BorderSide.none,
                                ),
                                focusedBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(18),
                                  borderSide: const BorderSide(
                                    color: Color(0xFF12323A),
                                    width: 1.5,
                                  ),
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
                        'Test account: 0711111111 / driver123\nServer: ${_friendlyServer(apiBaseUrl)}',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: stanMuted,
                          fontSize: 12,
                          height: 1.5,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Center(
                        child: TextButton.icon(
                          onPressed: _editServerUrl,
                          style: TextButton.styleFrom(foregroundColor: stanMuted),
                          icon: const Icon(Icons.settings_outlined, size: 15),
                          label: const Text(
                            'Server settings',
                            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
                          ),
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
    required this.phone,
  });

  final String fullName;
  final String role;
  final String token;
  final String phone;

  @override
  State<DriverHomeScreen> createState() => _DriverHomeScreenState();
}

class _DriverHomeScreenState extends State<DriverHomeScreen>
    with WidgetsBindingObserver, TickerProviderStateMixin {
  final MapController _mapController = MapController();
  gmaps.GoogleMapController? _googleMapController;
  int? _routeForDeliveryId;
  List<gmaps.LatLng> _googleRoutePoints = [];
  bool _isFetchingRoute = false;

  // Smooth marker animation: glide between GPS pings + rotate to heading.
  late final AnimationController _markerAnim;
  LatLng? _displayedLatLng;
  LatLng _animFrom = defaultMapCenter;
  LatLng _animTo = defaultMapCenter;
  double _markerBearingDeg = 0;
  gmaps.BitmapDescriptor? _vehicleBitmap;

  Map<String, dynamic>? _profile;
  List<Map<String, dynamic>> _documents = const [];
  List<Map<String, dynamic>> _conversations = const [];

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
    _markerAnim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    )..addListener(() {
        final t = Curves.easeInOut.transform(_markerAnim.value);
        setState(() {
          _displayedLatLng = LatLng(
            _animFrom.latitude + (_animTo.latitude - _animFrom.latitude) * t,
            _animFrom.longitude +
                (_animTo.longitude - _animFrom.longitude) * t,
          );
        });
      });
    unawaited(_loadVehicleBitmap());
    unawaited(_initializeDriverHome());
  }

  Future<void> _initializeDriverHome() async {
    await _loadPendingTrackingEvents();

    if (!mounted) return;

    await _loadDeliveries();
    unawaited(_loadProfile());
    unawaited(_loadConversations());

    if (!mounted) return;

    unawaited(
      _reportTrackingEvent(
        eventType: 'app_opened',
        severity: 'info',
        message: 'Driver opened the tracking app.',
      ),
    );
  }

  Future<void> _loadProfile() async {
    try {
      final results = await Future.wait([
        http.get(
          Uri.parse('$apiBaseUrl/driver/profile'),
          headers: {'Authorization': 'Bearer ${widget.token}'},
        ).timeout(apiRequestTimeout),
        http.get(
          Uri.parse('$apiBaseUrl/driver/documents'),
          headers: {'Authorization': 'Bearer ${widget.token}'},
        ).timeout(apiRequestTimeout),
      ]);

      if (!mounted) return;

      if (results[0].statusCode == 200) {
        final data = jsonDecode(results[0].body) as Map<String, dynamic>;
        setState(() => _profile = (data['profile'] as Map).cast<String, dynamic>());
      }
      if (results[1].statusCode == 200) {
        final data = jsonDecode(results[1].body) as Map<String, dynamic>;
        setState(() {
          _documents = (data['documents'] as List)
              .map((e) => (e as Map).cast<String, dynamic>())
              .toList();
        });
      }
    } catch (_) {
      // Non-fatal: the profile tab falls back to basic info.
    }
  }

  Future<void> _openExternalNavigation(Map<String, dynamic> delivery) async {
    final status = delivery['status'] as String?;
    final target = status == 'assigned'
        ? _pickupPoint(delivery)
        : _dropoffPoint(delivery);

    if (target == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No coordinates available for navigation.')),
        );
      }
      return;
    }

    final url = Uri.parse(
      'https://www.google.com/maps/dir/?api=1'
      '&destination=${target.latitude},${target.longitude}'
      '&travelmode=driving',
    );

    if (await canLaunchUrl(url)) {
      await launchUrl(url, mode: LaunchMode.externalApplication);
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open a maps app.')),
      );
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _trackingTimer?.cancel();
    _markerAnim.dispose();
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

  Future<bool> _updateDeliveryStatus(
    int deliveryId,
    String status, {
    String? pin,
  }) async {
    setState(() {
      _updatingDeliveryId = deliveryId;
      _statusMessage = null;
    });

    var success = false;

    try {
      final body = <String, dynamic>{'status': status};
      if (pin != null) body['pin'] = pin;

      final response = await http
          .patch(
            Uri.parse('$apiBaseUrl/driver/deliveries/$deliveryId/status'),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer ${widget.token}',
            },
            body: jsonEncode(body),
          )
          .timeout(apiRequestTimeout);

      final data = jsonDecode(response.body) as Map<String, dynamic>;

      if (!mounted) return false;

      if (response.statusCode == 200) {
        success = true;
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
      if (!mounted) return false;

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

    return success;
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
        _animateMarkerTo(LatLng(position.latitude, position.longitude));
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
              'Driver arrived near the destination. Collect payment and the handover PIN to complete.',
          deliveryId: deliveryId,
          metadata: {
            'distanceMeters': distanceMeters.round(),
            'radiusMeters': dropoffArrivalRadiusMeters,
          },
        );
        // Completion is no longer automatic: the driver collects payment and
        // the customer's handover PIN via the completion flow.
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
      // Home tab has a navy header behind the status bar (light icons);
      // the other tabs have a light header (dark icons).
      final overlayStyle = _selectedNavIndex == 0
          ? SystemUiOverlayStyle.light
          : SystemUiOverlayStyle.dark;

      return AnnotatedRegion<SystemUiOverlayStyle>(
        value: overlayStyle,
        child: Scaffold(
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
        ),
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

  // Compass bearing (degrees, 0 = north) from point a to b.
  double _bearing(LatLng a, LatLng b) {
    final lat1 = a.latitude * pi / 180;
    final lat2 = b.latitude * pi / 180;
    final dLon = (b.longitude - a.longitude) * pi / 180;
    final y = sin(dLon) * cos(lat2);
    final x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon);
    return (atan2(y, x) * 180 / pi + 360) % 360;
  }

  // Glide the displayed marker from its current spot to a new GPS fix and turn
  // it to face the direction of travel. Visible during live movement.
  void _animateMarkerTo(LatLng target) {
    final from = _displayedLatLng;

    if (from == null) {
      setState(() => _displayedLatLng = target);
      return;
    }

    if (calculateDistanceMeters(from, target) < 1) return;

    _markerBearingDeg = _bearing(from, target);
    _animFrom = from;
    _animTo = target;
    _markerAnim.forward(from: 0);
  }

  // Rasterize a directional vehicle marker once for the Google map.
  Future<void> _loadVehicleBitmap() async {
    if (!useGoogleMaps) return;

    const size = 96.0;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);

    canvas.drawCircle(
      const Offset(size / 2, size / 2),
      size / 2 - 3,
      Paint()..color = stanDark,
    );
    canvas.drawCircle(
      const Offset(size / 2, size / 2),
      size / 2 - 3,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4
        ..color = Colors.white,
    );

    final textPainter = TextPainter(textDirection: TextDirection.ltr);
    textPainter.text = TextSpan(
      text: String.fromCharCode(Icons.navigation.codePoint),
      style: TextStyle(
        fontSize: size * 0.5,
        fontFamily: Icons.navigation.fontFamily,
        package: Icons.navigation.fontPackage,
        color: Colors.white,
      ),
    );
    textPainter.layout();
    textPainter.paint(
      canvas,
      Offset((size - textPainter.width) / 2, (size - textPainter.height) / 2),
    );

    final image = await recorder.endRecording().toImage(
      size.toInt(),
      size.toInt(),
    );
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);

    if (bytes == null || !mounted) return;

    setState(() {
      _vehicleBitmap = gmaps.BitmapDescriptor.bytes(
        bytes.buffer.asUint8List(),
      );
    });
  }

  // Directional vehicle marker for the OpenStreetMap (flutter_map) layer.
  Widget _vehicleMarkerWidget() {
    return Transform.rotate(
      angle: _markerBearingDeg * pi / 180,
      child: Container(
        decoration: BoxDecoration(
          color: stanDark,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 3),
          boxShadow: const [
            BoxShadow(blurRadius: 12, color: Colors.black38, offset: Offset(0, 4)),
          ],
        ),
        child: const Icon(Icons.navigation, color: Colors.white, size: 24),
      ),
    );
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
          rotation: _markerBearingDeg,
          anchor: const Offset(0.5, 0.5),
          flat: true,
          icon: _vehicleBitmap ??
              gmaps.BitmapDescriptor.defaultMarkerWithHue(
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
    final driverDisplay = _displayedLatLng ??
        (_lastPosition == null
            ? null
            : LatLng(_lastPosition!.latitude, _lastPosition!.longitude));
    final driverPoint = driverDisplay == null
        ? null
        : gmaps.LatLng(driverDisplay.latitude, driverDisplay.longitude);

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
                point: _displayedLatLng ?? currentPoint,
                width: 52,
                height: 52,
                child: _vehicleMarkerWidget(),
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
          if (_selectedDelivery != null)
            Material(
              color: Colors.white,
              shape: const CircleBorder(),
              elevation: 8,
              child: IconButton(
                onPressed: () => unawaited(_openExternalNavigation(_selectedDelivery!)),
                icon: const Icon(Icons.navigation_outlined),
                tooltip: 'Navigate in Maps',
              ),
            ),
          if (_selectedDelivery != null) const SizedBox(height: 12),
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
    // No top SafeArea here — the navy hero paints behind the status bar and
    // adds the status-bar inset itself.
    return Column(
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
    );
  }

  Widget _buildHomeHero(List<Map<String, dynamic>> activeDeliveries) {
    final topInset = MediaQuery.of(context).padding.top;

    return SizedBox(
      height: 278 + topInset,
      child: Stack(
        children: [
          Container(
            height: 232 + topInset,
            padding: EdgeInsets.fromLTRB(24, 14 + topInset, 24, 66),
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
                    asset: 'assets/vehicles/bike.png',
                    fallbackIcon: Icons.pedal_bike,
                    label: 'Bike',
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: _buildTransportCard(
                    asset: 'assets/vehicles/truck.png',
                    fallbackIcon: Icons.local_shipping_outlined,
                    label: 'Truck',
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: _buildTransportCard(
                    asset: 'assets/vehicles/car.png',
                    fallbackIcon: Icons.directions_car_outlined,
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
      child: Image.asset(
        'assets/profile/avatar.png',
        fit: BoxFit.cover,
        width: size,
        height: size,
        // Until a profile photo is added, show the default avatar.
        errorBuilder: (_, _, _) => _buildAvatarFallback(size),
      ),
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
                  : 'TRK-${activeDeliveries.first['id'].toString().padLeft(5, '0')}',
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

  Widget _buildTransportCard({
    required String asset,
    required IconData fallbackIcon,
    required String label,
  }) {
    return Container(
      height: 96,
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Expanded(
            child: Image.asset(
              asset,
              fit: BoxFit.contain,
              filterQuality: FilterQuality.high,
              // Until real vehicle images are added, show a clean line icon.
              errorBuilder: (_, _, _) =>
                  Icon(fallbackIcon, color: stanDark, size: 30),
            ),
          ),
          const SizedBox(height: 6),
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
    return 'TRK-${deliveryId.toString().padLeft(5, '0')}';
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
          border: Border.all(color: Colors.white.withValues(alpha: 0.14), width: 1),
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
              width: 60,
              height: 56,
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Image.asset(
                'assets/vehicles/truck.png',
                fit: BoxFit.contain,
                filterQuality: FilterQuality.high,
                errorBuilder: (_, _, _) => const Icon(
                  Icons.local_shipping_outlined,
                  color: stanDark,
                  size: 26,
                ),
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

    // Floating "island" nav. Deliberately a solid premium surface (no live
    // BackdropFilter): this bar sits over scrolling lists on every tab, the
    // exact place live blur risks jank/ANR. The glass identity comes from the
    // rounded island, refracting edge, top sheen and floating shadow.
    return Container(
      color: stanSurface,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
          child: GlassPanel(
            radius: 26,
            allowBlur: false,
            shadow: true,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
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
          ),
        ),
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
        if (index == 2) unawaited(_loadConversations());
        if (index == 3) unawaited(_loadProfile());
      },
      borderRadius: BorderRadius.circular(999),
      child: SizedBox(
        width: 66,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              color: isSelected ? stanDark : const Color(0xFFB4BDC3),
              size: 24,
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
      subtitle: 'Manage your active and completed deliveries.',
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
    return SafeArea(
      bottom: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(24, 22, 24, 14),
            child: Text(
              'Messages',
              style: TextStyle(
                color: stanDark,
                fontSize: 28,
                fontWeight: FontWeight.w900,
                letterSpacing: -0.8,
              ),
            ),
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: _loadConversations,
              child: _conversations.isEmpty
                  ? ListView(
                      children: const [
                        SizedBox(height: 120),
                        Icon(Icons.forum_outlined, size: 44, color: Color(0xFFB4BDC3)),
                        SizedBox(height: 12),
                        Center(
                          child: Text(
                            'No conversations yet',
                            style: TextStyle(color: Color(0xFF64748B), fontWeight: FontWeight.w700),
                          ),
                        ),
                      ],
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      itemCount: _conversations.length,
                      separatorBuilder: (_, _) =>
                          const Divider(height: 1, thickness: 1, color: Color(0xFFEEF2F8)),
                      itemBuilder: (context, index) =>
                          _buildConversationRow(_conversations[index]),
                    ),
            ),
          ),
        ],
      ),
    );
  }

  ({Color color, IconData icon}) _partyStyle(String party) {
    switch (party) {
      case 'dispatch':
        return (color: const Color(0xFF2563EB), icon: Icons.headset_mic_outlined);
      case 'customer':
        return (color: const Color(0xFF16A34A), icon: Icons.person_outline_rounded);
      case 'support':
        return (color: const Color(0xFFF59E0B), icon: Icons.support_agent_outlined);
      default:
        return (color: stanMuted, icon: Icons.chat_bubble_outline_rounded);
    }
  }

  Widget _buildConversationRow(Map<String, dynamic> convo) {
    final party = convo['party'] as String? ?? 'dispatch';
    final style = _partyStyle(party);
    final unread = (convo['unread'] as num?)?.toInt() ?? 0;
    final lastSender = convo['lastSender'] as String?;
    final lastMessage = convo['lastMessage'] as String?;
    final preview = lastMessage == null
        ? 'Start the conversation'
        : '${lastSender == 'driver' ? 'You: ' : ''}$lastMessage';

    return InkWell(
      onTap: () => _openChat(convo),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
        child: Row(
          children: [
            Container(
              width: 50,
              height: 50,
              decoration: BoxDecoration(
                color: style.color.withValues(alpha: 0.14),
                shape: BoxShape.circle,
              ),
              child: Icon(style.icon, color: style.color, size: 24),
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
                          convo['title'] as String? ?? '',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: stanDark,
                            fontSize: 15.5,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      Text(
                        shortTime(convo['lastAt'] as String?),
                        style: TextStyle(
                          color: unread > 0 ? const Color(0xFF16A34A) : stanMuted,
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          preview,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: unread > 0 ? stanDark : const Color(0xFF64748B),
                            fontSize: 13.5,
                            fontWeight: unread > 0 ? FontWeight.w700 : FontWeight.w500,
                          ),
                        ),
                      ),
                      if (unread > 0) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.all(6),
                          constraints: const BoxConstraints(minWidth: 22),
                          decoration: const BoxDecoration(
                            color: Color(0xFF16A34A),
                            shape: BoxShape.circle,
                          ),
                          child: Text(
                            '$unread',
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 11,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _loadConversations() async {
    try {
      final response = await http.get(
        Uri.parse('$apiBaseUrl/driver/conversations'),
        headers: {'Authorization': 'Bearer ${widget.token}'},
      ).timeout(apiRequestTimeout);

      if (!mounted || response.statusCode != 200) return;
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      setState(() {
        _conversations = (data['conversations'] as List)
            .map((e) => (e as Map).cast<String, dynamic>())
            .toList();
      });
    } catch (_) {
      // Non-fatal.
    }
  }

  Future<void> _openChat(Map<String, dynamic> convo) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ChatScreen(
          token: widget.token,
          conversationId: convo['id'] as int,
          title: convo['title'] as String? ?? 'Chat',
          party: convo['party'] as String? ?? 'dispatch',
        ),
      ),
    );
    unawaited(_loadConversations());
  }

  Widget _buildProfilePage(BuildContext context) {
    return SafeArea(
      bottom: false,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 28),
        children: [
          _buildAccountHeader(),
          const SizedBox(height: 24),
          _buildQuickTiles(),
          const SizedBox(height: 16),
          _buildProTierCard(),
          const SizedBox(height: 16),
          _buildDocumentsCard(),
          const SizedBox(height: 16),
          _buildAccountList(),
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

  Widget _buildAccountHeader() {
    final rating = (_profile?['rating'] as num?)?.toDouble() ?? 5.0;
    final tier = _profile?['tier'] as String? ?? 'Bronze';

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.fullName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: stanDark,
                  fontSize: 26,
                  fontWeight: FontWeight.w900,
                  letterSpacing: -0.6,
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF1F5F9),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.star_rounded, color: Color(0xFFFBBF24), size: 15),
                        const SizedBox(width: 4),
                        Text(
                          rating.toStringAsFixed(2),
                          style: const TextStyle(
                            color: stanDark,
                            fontSize: 13,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: stanDark.withValues(alpha: 0.06),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      '$tier · Pro',
                      style: const TextStyle(
                        color: stanDark,
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(width: 16),
        _buildDriverAvatar(60),
      ],
    );
  }

  Widget _buildQuickTiles() {
    return Row(
      children: [
        Expanded(child: _quickTile(Icons.account_balance_wallet_rounded, 'Wallet', _openWallet)),
        const SizedBox(width: 12),
        Expanded(
          child: _quickTile(
            Icons.receipt_long_rounded,
            'Activity',
            () => setState(() => _selectedNavIndex = 1),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(child: _quickTile(Icons.directions_car_rounded, 'Vehicle', _openVehicle)),
      ],
    );
  }

  Widget _quickTile(IconData icon, String label, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 18),
        decoration: BoxDecoration(
          color: const Color(0xFFF1F5F9),
          borderRadius: BorderRadius.circular(18),
        ),
        child: Column(
          children: [
            Icon(icon, color: stanDark, size: 26),
            const SizedBox(height: 10),
            Text(
              label,
              style: const TextStyle(
                color: stanDark,
                fontSize: 13,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildProTierCard() {
    final tier = _profile?['tier'] as String? ?? 'Bronze';
    final completed = (_profile?['completedTrips'] as num?)?.toInt() ?? 0;

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: const LinearGradient(colors: [stanDark, stanPanel]),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white.withValues(alpha: 0.14), width: 1),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'PRO',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.65),
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.2,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  '$tier driver',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '$completed deliveries completed',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.7),
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          Icon(
            Icons.workspace_premium_rounded,
            color: Colors.white.withValues(alpha: 0.9),
            size: 42,
          ),
        ],
      ),
    );
  }

  Widget _buildDocumentsCard() {
    final statusByType = <String, String>{
      for (final doc in _documents)
        doc['docType'] as String: doc['status'] as String? ?? 'missing',
    };
    const order = ['license', 'ntsa', 'psv', 'insurance', 'inspection'];

    final rows = <Widget>[];
    for (var i = 0; i < order.length; i++) {
      final type = order[i];
      rows.add(_buildDocRow(type, statusByType[type] ?? 'missing'));
      if (i < order.length - 1) {
        rows.add(const Divider(height: 1, thickness: 1, color: Color(0xFFF1F5F8)));
      }
    }

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 10),
            child: Row(
              children: [
                Text(
                  'Documents',
                  style: TextStyle(color: stanDark, fontSize: 15, fontWeight: FontWeight.w900),
                ),
                Spacer(),
                Text(
                  'Compliance',
                  style: TextStyle(color: Color(0xFF94A3B8), fontSize: 12, fontWeight: FontWeight.w700),
                ),
              ],
            ),
          ),
          const Divider(height: 1, thickness: 1, color: Color(0xFFF1F5F8)),
          ...rows,
        ],
      ),
    );
  }

  Widget _buildDocRow(String docType, String status) {
    final style = _docStatusStyle(status);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        children: [
          Expanded(
            child: Text(
              _docTitles[docType] ?? docType,
              style: const TextStyle(color: stanDark, fontSize: 14, fontWeight: FontWeight.w700),
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: style.color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              style.label,
              style: TextStyle(
                color: style.color,
                fontSize: 10.5,
                fontWeight: FontWeight.w900,
                letterSpacing: 0.4,
              ),
            ),
          ),
        ],
      ),
    );
  }

  ({Color color, String label}) _docStatusStyle(String status) {
    switch (status) {
      case 'verified':
        return (color: const Color(0xFF16A34A), label: 'VERIFIED');
      case 'pending':
        return (color: const Color(0xFFF59E0B), label: 'PENDING');
      case 'expired':
        return (color: const Color(0xFFDC2626), label: 'EXPIRED');
      default:
        return (color: const Color(0xFF94A3B8), label: 'MISSING');
    }
  }

  Widget _buildAccountList() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Column(
        children: [
          _buildMenuRow(
            Icons.manage_accounts_outlined,
            'Account settings',
            'Phone, email, login details',
            onTap: _openAccount,
          ),
          _buildMenuDivider(),
          _buildMenuRow(
            Icons.logout_rounded,
            'Sign out',
            'Log out of this device',
            onTap: _signOut,
            iconColor: const Color(0xFFDC2626),
          ),
        ],
      ),
    );
  }

  Widget _buildMenuRow(
    IconData icon,
    String title,
    String subtitle, {
    VoidCallback? onTap,
    Color? iconColor,
  }) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
        child: Row(
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: (iconColor ?? stanDark).withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(icon, color: iconColor ?? stanDark, size: 20),
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
      ),
    );
  }

  void _openWallet() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => WalletScreen(token: widget.token, phone: widget.phone),
      ),
    );
  }

  void _openVehicle() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => VehicleScreen(vehicle: _profile?['vehicle'] as Map<String, dynamic>?),
      ),
    );
  }

  Future<void> _openAccount() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => AccountSettingsScreen(
          token: widget.token,
          phone: _profile?['phone'] as String? ?? widget.phone,
          email: _profile?['email'] as String?,
        ),
      ),
    );
    unawaited(_loadProfile());
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

  Widget _buildPaymentSummary(Map<String, dynamic> delivery) {
    final fare = (delivery['fareAmount'] as num?)?.toDouble() ?? 0;
    if (fare <= 0) return const SizedBox.shrink();

    final status = delivery['paymentStatus'] as String? ?? 'pending';
    final method = delivery['paymentMethod'] as String? ?? 'unpaid';
    final paid = status == 'paid';

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: stanSurface,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                paid ? 'Amount paid' : 'Amount due',
                style: const TextStyle(
                  color: Color(0xFF64748B),
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                formatKsh(fare),
                style: const TextStyle(
                  color: stanDark,
                  fontSize: 18,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ],
          ),
          const Spacer(),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: paid ? const Color(0xFFDCFCE7) : const Color(0xFFFEF3C7),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              paid ? 'PAID · ${method.toUpperCase()}' : 'UNPAID',
              style: TextStyle(
                color: paid ? const Color(0xFF166534) : const Color(0xFF92400E),
                fontSize: 10.5,
                fontWeight: FontWeight.w900,
                letterSpacing: 0.4,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // Completion: collect payment (if owed) -> enter handover PIN -> delivered.
  Future<void> _startCompletion(Map<String, dynamic> delivery) async {
    final fare = (delivery['fareAmount'] as num?)?.toDouble() ?? 0;
    final paymentStatus = delivery['paymentStatus'] as String? ?? 'pending';

    if (fare > 0 && paymentStatus != 'paid') {
      final paid = await _showPaymentSheet(delivery);
      if (paid != true || !mounted) return;
    }

    final completed = await _showPinSheet(delivery);
    if (completed == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Delivery completed.')),
      );
    }
  }

  Future<bool> _showPaymentSheet(Map<String, dynamic> delivery) async {
    final deliveryId = delivery['id'] as int;
    final fare = (delivery['fareAmount'] as num?)?.toDouble() ?? 0;
    final phoneController = TextEditingController(text: '0712 345 678');

    final result = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (sheetContext) {
        var busy = false;
        return StatefulBuilder(
          builder: (sheetContext, setSheet) {
            Future<void> payCash() async {
              setSheet(() => busy = true);
              final ok = await _collectCash(deliveryId);
              if (!sheetContext.mounted) return;
              if (ok) {
                Navigator.of(sheetContext).pop(true);
              } else {
                setSheet(() => busy = false);
              }
            }

            Future<void> payMpesa() async {
              final ok = await _collectMpesa(
                deliveryId,
                phoneController.text.trim(),
                fare,
              );
              if (!sheetContext.mounted) return;
              if (ok) Navigator.of(sheetContext).pop(true);
            }

            return Padding(
              padding: EdgeInsets.fromLTRB(
                24, 20, 24, 20 + MediaQuery.of(sheetContext).viewInsets.bottom,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      const Text(
                        'Collect payment',
                        style: TextStyle(color: stanDark, fontSize: 18, fontWeight: FontWeight.w900),
                      ),
                      const SizedBox(width: 8),
                      _demoChip(),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Amount due: ${formatKsh(fare)}',
                    style: const TextStyle(color: Color(0xFF64748B), fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 18),
                  TextField(
                    controller: phoneController,
                    keyboardType: TextInputType.phone,
                    decoration: InputDecoration(
                      labelText: 'Customer M-Pesa number',
                      filled: true,
                      fillColor: stanSurface,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  FilledButton.icon(
                    onPressed: busy ? null : payMpesa,
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF1AAE4F),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    icon: const Icon(Icons.smartphone, size: 18),
                    label: const Text('Send M-Pesa STK push', style: TextStyle(fontWeight: FontWeight.w900)),
                  ),
                  const SizedBox(height: 10),
                  OutlinedButton.icon(
                    onPressed: busy ? null : payCash,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: stanDark,
                      side: const BorderSide(color: Color(0xFFCBD5E1)),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    icon: busy
                        ? const SizedBox(
                            width: 16, height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.payments_outlined, size: 18),
                    label: const Text('Cash received', style: TextStyle(fontWeight: FontWeight.w900)),
                  ),
                ],
              ),
            );
          },
        );
      },
    );

    return result ?? false;
  }

  Widget _demoChip() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: const Color(0xFFFEF3C7),
        borderRadius: BorderRadius.circular(6),
      ),
      child: const Text(
        'DEMO',
        style: TextStyle(
          color: Color(0xFF92400E),
          fontSize: 10,
          fontWeight: FontWeight.w900,
          letterSpacing: 0.5,
        ),
      ),
    );
  }

  Future<bool> _collectCash(int deliveryId) async {
    try {
      final response = await http.post(
        Uri.parse('$apiBaseUrl/driver/deliveries/$deliveryId/collect-payment'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ${widget.token}',
        },
        body: jsonEncode({'method': 'cash'}),
      ).timeout(apiRequestTimeout);

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      if (response.statusCode == 200) {
        await _loadDeliveries();
        return true;
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(data['message'] as String? ?? 'Could not record cash.')),
        );
      }
      return false;
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not reach the server.')),
        );
      }
      return false;
    }
  }

  Future<bool> _collectMpesa(int deliveryId, String phone, double fare) async {
    // 1. Initiate the (simulated) STK push.
    try {
      final response = await http.post(
        Uri.parse('$apiBaseUrl/driver/deliveries/$deliveryId/collect-payment'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ${widget.token}',
        },
        body: jsonEncode({'method': 'mpesa', 'customerPhone': phone}),
      ).timeout(apiRequestTimeout);
      if (response.statusCode != 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(data['message'] as String? ?? 'Could not start M-Pesa.')),
          );
        }
        return false;
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not reach the server.')),
        );
      }
      return false;
    }

    if (!mounted) return false;

    // 2. Show the STK dialog; its submit confirms the (simulated) result.
    final result = await showStkPush(
      context,
      title: 'M-Pesa payment',
      phone: phone,
      amountText: formatKsh(fare),
      pendingNote: 'Ask the customer to enter their M-Pesa PIN on their phone.',
      submit: () async {
        final response = await http.post(
          Uri.parse('$apiBaseUrl/driver/deliveries/$deliveryId/mpesa-result'),
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer ${widget.token}',
          },
          body: jsonEncode({'success': true}),
        ).timeout(apiRequestTimeout);
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        if (response.statusCode == 200 && data['paymentStatus'] == 'paid') {
          return StkResult(
            success: true,
            reference: data['reference'] as String?,
            message: 'Payment received from the customer.',
          );
        }
        return StkResult(
          success: false,
          message: data['message'] as String? ?? 'M-Pesa payment failed.',
        );
      },
    );

    if (result != null && result.success) {
      await _loadDeliveries();
      return true;
    }
    return false;
  }

  Future<bool> _showPinSheet(Map<String, dynamic> delivery) async {
    final deliveryId = delivery['id'] as int;
    final demoPin = delivery['deliveryPin'] as String?;
    final pinController = TextEditingController();

    final result = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (sheetContext) {
        var busy = false;
        String? error;
        return StatefulBuilder(
          builder: (sheetContext, setSheet) {
            Future<void> submit() async {
              final pin = pinController.text.trim();
              if (pin.length != 4) {
                setSheet(() => error = 'Enter the 4-digit handover PIN.');
                return;
              }
              setSheet(() {
                busy = true;
                error = null;
              });
              final ok = await _updateDeliveryStatus(deliveryId, 'delivered', pin: pin);
              if (!sheetContext.mounted) return;
              if (ok) {
                Navigator.of(sheetContext).pop(true);
              } else {
                setSheet(() {
                  busy = false;
                  error = _statusMessage ?? 'Incorrect PIN. Try again.';
                });
              }
            }

            return Padding(
              padding: EdgeInsets.fromLTRB(
                24, 20, 24, 20 + MediaQuery.of(sheetContext).viewInsets.bottom,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'Handover PIN',
                    style: TextStyle(color: stanDark, fontSize: 18, fontWeight: FontWeight.w900),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'Ask the customer for their 4-digit code to confirm handover.',
                    style: TextStyle(color: Color(0xFF64748B), fontWeight: FontWeight.w600, height: 1.4),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: pinController,
                    keyboardType: TextInputType.number,
                    maxLength: 4,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w900, letterSpacing: 8),
                    decoration: InputDecoration(
                      counterText: '',
                      hintText: '••••',
                      filled: true,
                      fillColor: stanSurface,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                  if (demoPin != null) ...[
                    const SizedBox(height: 6),
                    Text(
                      'Demo PIN: $demoPin',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Color(0xFF94A3B8),
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                  if (error != null) ...[
                    const SizedBox(height: 10),
                    Text(
                      error!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Color(0xFFDC2626), fontWeight: FontWeight.w700),
                    ),
                  ],
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: busy ? null : submit,
                    child: Text(busy ? 'Confirming…' : 'Complete delivery'),
                  ),
                ],
              ),
            );
          },
        );
      },
    );

    return result ?? false;
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
        const SizedBox(height: 16),
        _buildPaymentSummary(delivery),
        if (_statusMessage != null) ...[
          const SizedBox(height: 16),
          Text(_statusMessage!),
        ],
        const SizedBox(height: 24),
        if (nextStatus != null)
          FilledButton(
            onPressed: isUpdating
                ? null
                : () {
                    if (isInTransit) {
                      unawaited(_startCompletion(delivery));
                    } else {
                      unawaited(_updateDeliveryStatus(deliveryId, nextStatus));
                    }
                  },
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

// ===========================================================================
// Shared helpers + DEMO M-Pesa STK-push simulation
// ===========================================================================

String formatKsh(num amount) {
  final whole = amount.round().abs();
  final digits = whole.toString();
  final buffer = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buffer.write(',');
    buffer.write(digits[i]);
  }
  return '${amount < 0 ? '-' : ''}Ksh $buffer';
}

String shortDate(String? iso) {
  final date = iso == null ? null : DateTime.tryParse(iso)?.toLocal();
  if (date == null) return '';
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  final hour = date.hour % 12 == 0 ? 12 : date.hour % 12;
  final minute = date.minute.toString().padLeft(2, '0');
  final period = date.hour < 12 ? 'AM' : 'PM';
  return '${months[date.month - 1]} ${date.day}, $hour:$minute $period';
}

// Relative time for chat lists / bubbles: now, 5m, h:mm AM, or MMM d.
String shortTime(String? iso) {
  final date = iso == null ? null : DateTime.tryParse(iso)?.toLocal();
  if (date == null) return '';
  final now = DateTime.now();
  final diff = now.difference(date);
  if (diff.inMinutes < 1) return 'now';
  if (diff.inMinutes < 60) return '${diff.inMinutes}m';

  final sameDay = now.year == date.year && now.month == date.month && now.day == date.day;
  if (sameDay) {
    final hour = date.hour % 12 == 0 ? 12 : date.hour % 12;
    final minute = date.minute.toString().padLeft(2, '0');
    return '$hour:$minute ${date.hour < 12 ? 'AM' : 'PM'}';
  }
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  return '${months[date.month - 1]} ${date.day}';
}

class StkResult {
  const StkResult({required this.success, this.reference, required this.message});

  final bool success;
  final String? reference;
  final String message;
}

/// Reusable DEMO M-Pesa STK-push dialog. Shows the "approve on your phone"
/// prompt, waits (simulating PIN entry), then runs [submit] and shows the
/// result. Returns the [StkResult] via Navigator.pop. NOT a real Daraja call.
class StkPushDialog extends StatefulWidget {
  const StkPushDialog({
    super.key,
    required this.title,
    required this.phone,
    required this.amountText,
    required this.pendingNote,
    required this.submit,
  });

  final String title;
  final String phone;
  final String amountText;
  final String pendingNote;
  final Future<StkResult> Function() submit;

  @override
  State<StkPushDialog> createState() => _StkPushDialogState();
}

class _StkPushDialogState extends State<StkPushDialog> {
  bool _processing = true;
  StkResult? _result;

  static const Color _mpesaGreen = Color(0xFF1AAE4F);

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    // Simulate the customer/driver receiving the prompt and entering their PIN.
    await Future.delayed(const Duration(milliseconds: 3500));

    StkResult result;
    try {
      result = await widget.submit();
    } catch (_) {
      result = const StkResult(
        success: false,
        message: 'Could not reach the server. Please try again.',
      );
    }

    if (!mounted) return;
    setState(() {
      _processing = false;
      _result = result;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: _processing ? _buildProcessing() : _buildResult(),
      ),
    );
  }

  Widget _buildDemoChip() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: const Color(0xFFFEF3C7),
        borderRadius: BorderRadius.circular(6),
      ),
      child: const Text(
        'DEMO',
        style: TextStyle(
          color: Color(0xFF92400E),
          fontSize: 10,
          fontWeight: FontWeight.w900,
          letterSpacing: 0.5,
        ),
      ),
    );
  }

  Widget _buildProcessing() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 64,
          height: 64,
          decoration: BoxDecoration(
            color: _mpesaGreen.withValues(alpha: 0.12),
            shape: BoxShape.circle,
          ),
          child: const Icon(Icons.smartphone, color: _mpesaGreen, size: 30),
        ),
        const SizedBox(height: 18),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              widget.title,
              style: const TextStyle(
                color: stanDark,
                fontSize: 17,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(width: 8),
            _buildDemoChip(),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          'STK push sent to ${widget.phone}',
          textAlign: TextAlign.center,
          style: const TextStyle(color: Color(0xFF475569), fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 4),
        Text(
          widget.amountText,
          style: const TextStyle(
            color: stanDark,
            fontSize: 22,
            fontWeight: FontWeight.w900,
          ),
        ),
        const SizedBox(height: 18),
        const SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(strokeWidth: 2.4, color: _mpesaGreen),
        ),
        const SizedBox(height: 14),
        Text(
          widget.pendingNote,
          textAlign: TextAlign.center,
          style: const TextStyle(color: Color(0xFF64748B), fontSize: 13, height: 1.4),
        ),
      ],
    );
  }

  Widget _buildResult() {
    final result = _result!;
    final color = result.success ? _mpesaGreen : const Color(0xFFDC2626);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 64,
          height: 64,
          decoration: BoxDecoration(color: color.withValues(alpha: 0.12), shape: BoxShape.circle),
          child: Icon(
            result.success ? Icons.check_rounded : Icons.close_rounded,
            color: color,
            size: 34,
          ),
        ),
        const SizedBox(height: 16),
        Text(
          result.success ? 'Payment successful' : 'Payment not completed',
          style: const TextStyle(color: stanDark, fontSize: 18, fontWeight: FontWeight.w900),
        ),
        const SizedBox(height: 8),
        Text(
          result.message,
          textAlign: TextAlign.center,
          style: const TextStyle(color: Color(0xFF64748B), height: 1.4),
        ),
        if (result.success && result.reference != null) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: stanSurface,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              'M-Pesa ref: ${result.reference}  ·  DEMO',
              style: const TextStyle(
                color: stanDark,
                fontSize: 12.5,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ],
        const SizedBox(height: 20),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: () => Navigator.of(context).pop(result),
            child: const Text('Done'),
          ),
        ),
      ],
    );
  }
}

Future<StkResult?> showStkPush(
  BuildContext context, {
  required String title,
  required String phone,
  required String amountText,
  required String pendingNote,
  required Future<StkResult> Function() submit,
}) {
  return showDialog<StkResult>(
    context: context,
    barrierDismissible: false,
    builder: (_) => StkPushDialog(
      title: title,
      phone: phone,
      amountText: amountText,
      pendingNote: pendingNote,
      submit: submit,
    ),
  );
}

// ===========================================================================
// Wallet & earnings
// ===========================================================================

class WalletScreen extends StatefulWidget {
  const WalletScreen({super.key, required this.token, required this.phone});

  final String token;
  final String phone;

  @override
  State<WalletScreen> createState() => _WalletScreenState();
}

class _WalletScreenState extends State<WalletScreen> {
  bool _loading = true;
  String? _error;
  double _balance = 0;
  Map<String, dynamic> _today = const {};
  Map<String, dynamic> _week = const {};
  List<Map<String, dynamic>> _transactions = const [];

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final response = await http.get(
        Uri.parse('$apiBaseUrl/driver/earnings'),
        headers: {'Authorization': 'Bearer ${widget.token}'},
      ).timeout(apiRequestTimeout);

      final data = jsonDecode(response.body) as Map<String, dynamic>;

      if (!mounted) return;

      if (response.statusCode == 200) {
        setState(() {
          _balance = (data['balance'] as num).toDouble();
          _today = (data['today'] as Map).cast<String, dynamic>();
          _week = (data['week'] as Map).cast<String, dynamic>();
          _transactions = (data['transactions'] as List)
              .map((e) => (e as Map).cast<String, dynamic>())
              .toList();
        });
      } else {
        setState(() => _error = data['message'] as String? ?? 'Could not load earnings.');
      }
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not connect to load earnings.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _startCashOut() async {
    if (_balance <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No balance available to cash out.')),
      );
      return;
    }

    final controller = TextEditingController(text: _balance.round().toString());

    final amount = await showModalBottomSheet<double>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (sheetContext) {
        return Padding(
          padding: EdgeInsets.fromLTRB(
            24, 20, 24, 20 + MediaQuery.of(sheetContext).viewInsets.bottom,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Cash out to M-Pesa',
                style: TextStyle(color: stanDark, fontSize: 18, fontWeight: FontWeight.w900),
              ),
              const SizedBox(height: 4),
              Text(
                'Sent to ${widget.phone} · DEMO',
                style: const TextStyle(color: Color(0xFF64748B), fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: controller,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: 'Amount (Ksh)',
                  filled: true,
                  fillColor: stanSurface,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () {
                  final value = double.tryParse(controller.text.trim());
                  if (value == null || value <= 0) return;
                  Navigator.of(sheetContext).pop(value);
                },
                child: const Text('Send to M-Pesa'),
              ),
            ],
          ),
        );
      },
    );

    if (amount == null || !mounted) return;

    final result = await showStkPush(
      context,
      title: 'M-Pesa cash-out',
      phone: widget.phone,
      amountText: formatKsh(amount),
      pendingNote: 'Authorize the withdrawal with your M-Pesa PIN on your phone.',
      submit: () async {
        final response = await http.post(
          Uri.parse('$apiBaseUrl/driver/wallet/cashout'),
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer ${widget.token}',
          },
          body: jsonEncode({'amount': amount}),
        ).timeout(apiRequestTimeout);

        final data = jsonDecode(response.body) as Map<String, dynamic>;
        if (response.statusCode == 200) {
          return StkResult(
            success: true,
            reference: data['reference'] as String?,
            message: '${formatKsh(amount)} sent to your M-Pesa.',
          );
        }
        return StkResult(
          success: false,
          message: data['message'] as String? ?? 'Cash-out failed.',
        );
      },
    );

    if (result != null && result.success && mounted) {
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: stanSurface,
      appBar: AppBar(
        backgroundColor: stanDark,
        foregroundColor: Colors.white,
        elevation: 0,
        title: const Text('Earnings & Wallet', style: TextStyle(fontWeight: FontWeight.w900)),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? _buildError()
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: const EdgeInsets.all(20),
                    children: [
                      _buildBalanceCard(),
                      const SizedBox(height: 18),
                      Row(
                        children: [
                          Expanded(child: _buildPeriodCard('Today', _today)),
                          const SizedBox(width: 12),
                          Expanded(child: _buildPeriodCard('This week', _week)),
                        ],
                      ),
                      const SizedBox(height: 22),
                      const Text(
                        'Recent transactions',
                        style: TextStyle(color: stanDark, fontSize: 16, fontWeight: FontWeight.w900),
                      ),
                      const SizedBox(height: 10),
                      if (_transactions.isEmpty)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 20),
                          child: Text(
                            'No transactions yet.',
                            style: TextStyle(color: Color(0xFF64748B)),
                          ),
                        )
                      else
                        ..._transactions.map(_buildTransactionRow),
                    ],
                  ),
                ),
    );
  }

  Widget _buildError() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton(onPressed: _load, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }

  Widget _buildBalanceCard() {
    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        gradient: const LinearGradient(colors: [stanDark, stanPanel]),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white.withValues(alpha: 0.16), width: 1),
      ),

      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                'Wallet balance',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.7),
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: const Text(
                  'DEMO',
                  style: TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.w900),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            formatKsh(_balance),
            style: const TextStyle(
              color: Colors.white,
              fontSize: 34,
              fontWeight: FontWeight.w900,
              letterSpacing: -0.5,
            ),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _startCashOut,
              style: FilledButton.styleFrom(
                backgroundColor: Colors.white,
                foregroundColor: stanDark,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              icon: const Icon(Icons.account_balance_wallet_outlined, size: 18),
              label: const Text('Cash out to M-Pesa', style: TextStyle(fontWeight: FontWeight.w900)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPeriodCard(String label, Map<String, dynamic> data) {
    final net = (data['net'] as num? ?? 0).toDouble();
    final gross = (data['gross'] as num? ?? 0).toDouble();
    final fee = (data['fee'] as num? ?? 0).toDouble();
    final tips = (data['tips'] as num? ?? 0).toDouble();
    final trips = (data['trips'] as num? ?? 0).toInt();

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(color: Color(0xFF64748B), fontSize: 12, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 6),
          Text(
            formatKsh(net),
            style: const TextStyle(color: stanDark, fontSize: 20, fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 2),
          Text(
            '$trips ${trips == 1 ? 'trip' : 'trips'} · net',
            style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 11, fontWeight: FontWeight.w700),
          ),
          const Divider(height: 18),
          _miniRow('Gross', formatKsh(gross)),
          _miniRow('Service fee', '-${formatKsh(fee)}'),
          _miniRow('Tips', formatKsh(tips)),
        ],
      ),
    );
  }

  Widget _miniRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 12)),
          Text(
            value,
            style: const TextStyle(color: stanDark, fontSize: 12.5, fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }

  Widget _buildTransactionRow(Map<String, dynamic> txn) {
    final type = txn['type'] as String? ?? 'earning';
    final amount = (txn['amount'] as num? ?? 0).toDouble();
    final isCredit = amount >= 0;

    IconData icon;
    Color color;
    switch (type) {
      case 'payout':
        icon = Icons.north_east_rounded;
        color = const Color(0xFFDC2626);
        break;
      case 'tip':
        icon = Icons.volunteer_activism_outlined;
        color = const Color(0xFFF59E0B);
        break;
      default:
        icon = Icons.south_west_rounded;
        color = const Color(0xFF16A34A);
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: color, size: 18),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  type == 'payout'
                      ? 'M-Pesa cash-out'
                      : type == 'tip'
                          ? 'Customer tip'
                          : 'Delivery earning',
                  style: const TextStyle(color: stanDark, fontSize: 14, fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 2),
                Text(
                  shortDate(txn['createdAt'] as String?),
                  style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 12),
                ),
              ],
            ),
          ),
          Text(
            '${isCredit ? '+' : ''}${formatKsh(amount)}',
            style: TextStyle(
              color: isCredit ? const Color(0xFF16A34A) : const Color(0xFFDC2626),
              fontSize: 14,
              fontWeight: FontWeight.w900,
            ),
          ),
        ],
      ),
    );
  }
}

// ===========================================================================
// Documents
// ===========================================================================

const Map<String, String> _docTitles = {
  'license': 'Driving licence',
  'ntsa': 'NTSA clearance',
  'psv': 'PSV badge',
  'insurance': 'Insurance certificate',
  'inspection': 'Vehicle inspection',
};


// ===========================================================================
// Vehicle
// ===========================================================================

class VehicleScreen extends StatelessWidget {
  const VehicleScreen({super.key, required this.vehicle});

  final Map<String, dynamic>? vehicle;

  @override
  Widget build(BuildContext context) {
    final plate = vehicle?['plateNumber'] as String?;
    final type = vehicle?['vehicleType'] as String?;

    return Scaffold(
      backgroundColor: stanSurface,
      appBar: AppBar(
        backgroundColor: stanDark,
        foregroundColor: Colors.white,
        elevation: 0,
        title: const Text('Vehicle', style: TextStyle(fontWeight: FontWeight.w900)),
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Container(
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
                    color: stanDark.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: const Icon(Icons.local_shipping_outlined, color: stanDark),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        plate ?? 'No vehicle assigned',
                        style: const TextStyle(color: stanDark, fontSize: 18, fontWeight: FontWeight.w900),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        type ?? 'Contact dispatch to assign one',
                        style: const TextStyle(color: Color(0xFF64748B), fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          const Text(
            'Vehicle assignment is managed by dispatch. Contact the office to '
            'change or add a vehicle.',
            style: TextStyle(color: Color(0xFF64748B), height: 1.5),
          ),
        ],
      ),
    );
  }
}

// ===========================================================================
// Account settings
// ===========================================================================

class AccountSettingsScreen extends StatefulWidget {
  const AccountSettingsScreen({
    super.key,
    required this.token,
    required this.phone,
    required this.email,
  });

  final String token;
  final String phone;
  final String? email;

  @override
  State<AccountSettingsScreen> createState() => _AccountSettingsScreenState();
}

class _AccountSettingsScreenState extends State<AccountSettingsScreen> {
  late final TextEditingController _phone =
      TextEditingController(text: widget.phone);
  late final TextEditingController _email =
      TextEditingController(text: widget.email ?? '');
  bool _saving = false;
  String? _message;

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _message = null;
    });
    try {
      final response = await http.patch(
        Uri.parse('$apiBaseUrl/driver/account'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ${widget.token}',
        },
        body: jsonEncode({'phone': _phone.text.trim(), 'email': _email.text.trim()}),
      ).timeout(apiRequestTimeout);

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      if (!mounted) return;
      setState(() => _message = data['message'] as String? ?? 'Saved.');
    } catch (_) {
      if (mounted) setState(() => _message = 'Could not reach the server.');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: stanSurface,
      appBar: AppBar(
        backgroundColor: stanDark,
        foregroundColor: Colors.white,
        elevation: 0,
        title: const Text('Account settings', style: TextStyle(fontWeight: FontWeight.w900)),
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          _field('Phone number', _phone, TextInputType.phone),
          const SizedBox(height: 14),
          _field('Email', _email, TextInputType.emailAddress),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: _saving ? null : _save,
            child: Text(_saving ? 'Saving…' : 'Save changes'),
          ),
          if (_message != null) ...[
            const SizedBox(height: 14),
            Text(
              _message!,
              textAlign: TextAlign.center,
              style: const TextStyle(color: stanDark, fontWeight: FontWeight.w700),
            ),
          ],
        ],
      ),
    );
  }

  Widget _field(String label, TextEditingController controller, TextInputType type) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(color: stanDark, fontWeight: FontWeight.w800)),
        const SizedBox(height: 6),
        TextField(
          controller: controller,
          keyboardType: type,
          decoration: InputDecoration(
            filled: true,
            fillColor: Colors.white,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
            ),
          ),
        ),
      ],
    );
  }
}

// ===========================================================================
// Chat thread (WhatsApp-style)
// ===========================================================================

class ChatScreen extends StatefulWidget {
  const ChatScreen({
    super.key,
    required this.token,
    required this.conversationId,
    required this.title,
    required this.party,
  });

  final String token;
  final int conversationId;
  final String title;
  final String party;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();
  List<Map<String, dynamic>> _messages = const [];
  bool _loading = true;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final response = await http.get(
        Uri.parse('$apiBaseUrl/driver/conversations/${widget.conversationId}/messages'),
        headers: {'Authorization': 'Bearer ${widget.token}'},
      ).timeout(apiRequestTimeout);

      if (!mounted || response.statusCode != 200) return;
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      setState(() {
        _messages = (data['messages'] as List)
            .map((e) => (e as Map).cast<String, dynamic>())
            .toList();
      });
      _scrollToBottom();
    } catch (_) {
      // leave empty
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _send() async {
    final body = _input.text.trim();
    if (body.isEmpty || _sending) return;

    setState(() => _sending = true);
    _input.clear();

    try {
      final response = await http.post(
        Uri.parse('$apiBaseUrl/driver/conversations/${widget.conversationId}/messages'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ${widget.token}',
        },
        body: jsonEncode({'body': body}),
      ).timeout(apiRequestTimeout);

      if (!mounted) return;
      if (response.statusCode == 201) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final newMessages = (data['messages'] as List)
            .map((e) => (e as Map).cast<String, dynamic>())
            .toList();
        setState(() => _messages = [..._messages, ...newMessages]);
        _scrollToBottom();
      } else {
        _input.text = body;
      }
    } catch (_) {
      _input.text = body;
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not send. Check your connection.')),
        );
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFEDF1F7),
      appBar: AppBar(
        backgroundColor: stanDark,
        foregroundColor: Colors.white,
        elevation: 0,
        titleSpacing: 0,
        title: Row(
          children: [
            CircleAvatar(
              radius: 16,
              backgroundColor: Colors.white.withValues(alpha: 0.16),
              child: Text(
                widget.title.isNotEmpty ? widget.title[0].toUpperCase() : '?',
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 14),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                widget.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16),
              ),
            ),
          ],
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _messages.isEmpty
                    ? const Center(
                        child: Text(
                          'No messages yet. Say hello 👋',
                          style: TextStyle(color: Color(0xFF64748B)),
                        ),
                      )
                    : ListView.builder(
                        controller: _scroll,
                        padding: const EdgeInsets.fromLTRB(14, 16, 14, 16),
                        itemCount: _messages.length,
                        itemBuilder: (context, index) => _buildBubble(_messages[index]),
                      ),
          ),
          _buildComposer(),
        ],
      ),
    );
  }

  Widget _buildBubble(Map<String, dynamic> msg) {
    final isDriver = msg['sender'] == 'driver';
    return Align(
      alignment: isDriver ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.76),
        decoration: BoxDecoration(
          color: isDriver ? stanDark : Colors.white,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(16),
            topRight: const Radius.circular(16),
            bottomLeft: Radius.circular(isDriver ? 16 : 4),
            bottomRight: Radius.circular(isDriver ? 4 : 16),
          ),
          border: isDriver ? null : Border.all(color: const Color(0xFFE2E8F0)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              msg['body'] as String? ?? '',
              style: TextStyle(
                color: isDriver ? Colors.white : stanDark,
                fontSize: 14.5,
                height: 1.3,
              ),
            ),
            const SizedBox(height: 3),
            Text(
              shortTime(msg['createdAt'] as String?),
              style: TextStyle(
                color: isDriver ? Colors.white.withValues(alpha: 0.6) : const Color(0xFF94A3B8),
                fontSize: 10.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildComposer() {
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        decoration: const BoxDecoration(
          color: Colors.white,
          border: Border(top: BorderSide(color: Color(0xFFE2E8F0))),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: TextField(
                controller: _input,
                minLines: 1,
                maxLines: 4,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                  hintText: 'Message',
                  filled: true,
                  fillColor: const Color(0xFFF1F5F9),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                    borderSide: BorderSide.none,
                  ),
                ),
                onSubmitted: (_) => unawaited(_send()),
              ),
            ),
            const SizedBox(width: 8),
            Material(
              color: stanDark,
              shape: const CircleBorder(),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: _sending ? null : () => unawaited(_send()),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: _sending
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                        )
                      : const Icon(Icons.send_rounded, color: Colors.white, size: 20),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

