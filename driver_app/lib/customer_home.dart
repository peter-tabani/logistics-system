// Customer experience for the Stan app: signup, a premium home screen with
// the active parcel and quick actions, parcel history, and profile/account
// management. Booking lives in customer_booking.dart and live tracking in
// customer_tracking.dart — the same app serves riders and customers, routed
// by role at login.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';

import 'customer_booking.dart';
import 'customer_common.dart';
import 'customer_tracking.dart';
import 'main.dart';
import 'notifications.dart';
import 'permissions.dart';
import 'stan_map.dart';
import 'theme_controller.dart';

const String stanSupportPhone = '0700000000';

// ===========================================================================
// Signup
// ===========================================================================

class CustomerSignupScreen extends StatefulWidget {
  const CustomerSignupScreen({super.key});

  @override
  State<CustomerSignupScreen> createState() => _CustomerSignupScreenState();
}

class _CustomerSignupScreenState extends State<CustomerSignupScreen> {
  final _nameController = TextEditingController();
  final _phoneController = TextEditingController();
  final _passwordController = TextEditingController();
  final _emailController = TextEditingController();
  final _birthController = TextEditingController();
  final _residenceController = TextEditingController();

  bool _isLoading = false;
  String? _errorMessage;

  @override
  void dispose() {
    _nameController.dispose();
    _phoneController.dispose();
    _passwordController.dispose();
    _emailController.dispose();
    _birthController.dispose();
    _residenceController.dispose();
    super.dispose();
  }

  Future<void> _register() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final response = await http
          .post(
            Uri.parse('$apiBaseUrl/auth/register'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'fullName': _nameController.text.trim(),
              'phone': _phoneController.text.trim(),
              'password': _passwordController.text,
              'email': _emailController.text.trim(),
              'placeOfBirth': _birthController.text.trim(),
              'placeOfResidence': _residenceController.text.trim(),
            }),
          )
          .timeout(const Duration(seconds: 45));

      final data = jsonDecode(response.body) as Map<String, dynamic>;

      if (!mounted) return;

      if (response.statusCode == 201) {
        final user = data['user'] as Map<String, dynamic>;
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder: (_) => CustomerHomeScreen(
              fullName: user['fullName'] as String,
              phone: user['phone'] as String? ?? '',
              token: data['token'] as String,
            ),
          ),
        );
      } else {
        setState(() {
          _errorMessage =
              data['message'] as String? ?? 'Could not create your account.';
        });
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _errorMessage = 'Could not reach the server. Try again shortly.';
      });
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  InputDecoration _fieldDecoration(String hint, IconData icon) {
    return InputDecoration(
      hintText: hint,
      prefixIcon: Icon(icon),
      filled: true,
      fillColor: stanSurface,
      contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide.none,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: stanDark,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        elevation: 0,
        title: const Text(
          'Create customer account',
          style: TextStyle(fontWeight: FontWeight.w800),
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Container(
            padding: const EdgeInsets.all(22),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(26),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Send parcels with Stan',
                  style: TextStyle(
                    color: stanDark,
                    fontSize: 20,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 6),
                const Text(
                  'Book pickups on the map, route through collection points, and track your parcel live.',
                  style: TextStyle(color: Color(0xFF60727A), fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 18),
                TextField(
                  controller: _nameController,
                  decoration: _fieldDecoration('Full name', Icons.person_outline),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _phoneController,
                  keyboardType: TextInputType.phone,
                  decoration: _fieldDecoration('Phone number', Icons.phone_outlined),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _passwordController,
                  obscureText: true,
                  decoration: _fieldDecoration('Password (min 6 characters)', Icons.lock_outline),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _emailController,
                  keyboardType: TextInputType.emailAddress,
                  decoration: _fieldDecoration('Email (optional)', Icons.alternate_email),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _birthController,
                  decoration: _fieldDecoration('Place of birth', Icons.location_city_outlined),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _residenceController,
                  decoration: _fieldDecoration('Place of residence', Icons.home_outlined),
                ),
                if (_errorMessage != null) ...[
                  const SizedBox(height: 14),
                  Text(
                    _errorMessage!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Color(0xFFDC2626),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
                const SizedBox(height: 18),
                FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: stanDark,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                  onPressed: _isLoading ? null : _register,
                  child: _isLoading
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Create account'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ===========================================================================
// Customer home (Home / My Parcels / Profile)
// ===========================================================================

class CustomerHomeScreen extends StatefulWidget {
  const CustomerHomeScreen({
    super.key,
    required this.fullName,
    required this.phone,
    required this.token,
  });

  final String fullName;
  final String phone;
  final String token;

  @override
  State<CustomerHomeScreen> createState() => _CustomerHomeScreenState();
}

class _CustomerHomeScreenState extends State<CustomerHomeScreen> {
  int _tab = 0;

  List<Map<String, dynamic>> _deliveries = [];
  bool _isLoadingDeliveries = false;
  String? _statusMessage;
  late String _phone = widget.phone;

  final StanMapController _homeMapController = StanMapController();
  LatLng _homeCenter = defaultMapCenter;
  bool _hasLocation = false;

  @override
  void initState() {
    super.initState();
    _loadDeliveries();
    _locateHome();
    unawaited(requestStartupPermissions());
  }

  // Center the home map on the customer's live location (Uber/Bolt style).
  Future<void> _locateHome() async {
    try {
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        return;
      }
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
      );
      if (!mounted) return;
      final point = LatLng(position.latitude, position.longitude);
      setState(() {
        _homeCenter = point;
        _hasLocation = true;
      });
      _homeMapController.moveTo(point, zoom: 15.5);
    } catch (_) {
      // Falls back to the default city center; map still shows.
    }
  }

  Future<void> _loadDeliveries() async {
    setState(() => _isLoadingDeliveries = true);

    try {
      final response = await http
          .get(
            Uri.parse('$apiBaseUrl/customer/deliveries'),
            headers: customerAuthHeaders(widget.token),
          )
          .timeout(apiRequestTimeout);

      if (!mounted) return;

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final loaded =
            (data['deliveries'] as List<dynamic>).cast<Map<String, dynamic>>();
        setState(() {
          _deliveries = loaded;
          _statusMessage = null;
        });
        unawaited(NotificationService.instance.checkDeliveryUpdates(loaded));
      } else {
        setState(() => _statusMessage = 'Could not load your parcels.');
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => _statusMessage = 'Could not connect to load your parcels.');
    } finally {
      if (mounted) setState(() => _isLoadingDeliveries = false);
    }
  }

  List<Map<String, dynamic>> get _activeDeliveries => _deliveries
      .where((d) => d['status'] != 'delivered' && d['status'] != 'cancelled')
      .toList();

  List<Map<String, dynamic>> get _pastDeliveries => _deliveries
      .where((d) => d['status'] == 'delivered' || d['status'] == 'cancelled')
      .toList();

  Future<void> _openBookingFlow() async {
    final result = await Navigator.of(context).push<Map<String, dynamic>>(
      MaterialPageRoute(builder: (_) => BookParcelFlow(token: widget.token)),
    );

    await _loadDeliveries();

    if (!mounted || result == null) return;

    final delivery = result['delivery'] as Map<String, dynamic>?;
    if (result['track'] == true && delivery != null) {
      await _openParcel(delivery['id'] as int);
    } else {
      setState(() => _tab = 1);
    }
  }

  Future<void> _openParcel(int deliveryId) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => CustomerParcelScreen(
          token: widget.token,
          phone: _phone,
          deliveryId: deliveryId,
        ),
      ),
    );
    await _loadDeliveries();
  }

  Future<void> _callSupport() async {
    final uri = Uri.parse('tel:$stanSupportPhone');
    if (await canLaunchUrl(uri)) await launchUrl(uri);
  }

  /* ------------------------------- Home tab ------------------------------ */

  String get _greeting {
    final hour = DateTime.now().hour;
    if (hour < 12) return 'Good morning';
    if (hour < 17) return 'Good afternoon';
    return 'Good evening';
  }

  // Floating greeting bar over the map (Uber/Bolt style).
  Widget _buildHomeTopBar() {
    return Padding(
      padding: EdgeInsets.fromLTRB(16, MediaQuery.of(context).padding.top + 12, 16, 0),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(18),
          boxShadow: const [
            BoxShadow(color: Color(0x22000000), blurRadius: 14, offset: Offset(0, 4)),
          ],
        ),
        child: Row(
          children: [
            CircleAvatar(
              radius: 18,
              backgroundColor: stanDark,
              child: Text(
                widget.fullName.isNotEmpty ? widget.fullName[0].toUpperCase() : 'C',
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w900,
                  fontSize: 15,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '$_greeting,',
                    style: const TextStyle(
                      color: Color(0xFF64748B),
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Text(
                    widget.fullName.split(' ').first,
                    style: const TextStyle(
                      color: stanDark,
                      fontSize: 16,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ],
              ),
            ),
            if (_isLoadingDeliveries) ...[
              const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2, color: stanDark),
              ),
              const SizedBox(width: 8),
            ],
            _buildCustomerBell(),
          ],
        ),
      ),
    );
  }

  Widget _buildCustomerBell() {
    return GestureDetector(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const NotificationsScreen()),
      ),
      child: ValueListenableBuilder<List<AppNotification>>(
        valueListenable: NotificationService.instance.items,
        builder: (context, _, _) {
          final unread = NotificationService.instance.unreadCount;
          return Stack(
            clipBehavior: Clip.none,
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: const BoxDecoration(color: stanSurface, shape: BoxShape.circle),
                child: const Icon(Icons.notifications_none, color: stanDark, size: 20),
              ),
              if (unread > 0)
                Positioned(
                  right: -1,
                  top: -1,
                  child: Container(
                    constraints: const BoxConstraints(minWidth: 16, minHeight: 16),
                    padding: const EdgeInsets.all(2),
                    decoration: BoxDecoration(
                      color: const Color(0xFFDC2626),
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 1.5),
                    ),
                    child: Text(
                      unread > 9 ? '9+' : '$unread',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 9,
                        fontWeight: FontWeight.w900,
                        height: 1.1,
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildActiveParcelCard(Map<String, dynamic> delivery) {
    final progress = customerProgress(delivery);

    return InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: () => _openParcel(delivery['id'] as int),
      child: Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [stanPanel, stanDark],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.inventory_2, color: Colors.white70, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    delivery['trackingCode'] as String? ?? 'Parcel',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w900,
                      fontSize: 15.5,
                      letterSpacing: 0.5,
                    ),
                  ),
                ),
                customerStatusChip(delivery['status'] as String? ?? 'pending'),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              '${delivery['pickupAddress']} → ${delivery['dropoffAddress']}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: stanMuted,
                fontWeight: FontWeight.w700,
                fontSize: 12.5,
              ),
            ),
            const SizedBox(height: 14),
            ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: LinearProgressIndicator(
                value: progress,
                minHeight: 7,
                backgroundColor: Colors.white.withValues(alpha: 0.15),
                valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF34D399)),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                if (delivery['riderName'] != null) ...[
                  const Icon(Icons.sports_motorsports, color: Colors.white54, size: 15),
                  const SizedBox(width: 5),
                  Text(
                    delivery['riderName'] as String,
                    style: const TextStyle(
                      color: Colors.white70,
                      fontWeight: FontWeight.w800,
                      fontSize: 12,
                    ),
                  ),
                ],
                const Spacer(),
                const Text(
                  'Live track',
                  style: TextStyle(
                    color: Color(0xFF34D399),
                    fontWeight: FontWeight.w900,
                    fontSize: 13,
                  ),
                ),
                const Icon(Icons.chevron_right, color: Color(0xFF34D399), size: 20),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _quickAction(IconData icon, String label, String caption, VoidCallback onTap) {
    return Expanded(
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(18),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(9),
                decoration: BoxDecoration(
                  color: stanSurface,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, color: stanDark, size: 21),
              ),
              const SizedBox(height: 10),
              Text(
                label,
                style: const TextStyle(
                  color: stanDark,
                  fontWeight: FontWeight.w900,
                  fontSize: 13.5,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                caption,
                style: const TextStyle(
                  color: Color(0xFF94A3B8),
                  fontWeight: FontWeight.w600,
                  fontSize: 11,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHomeTab() {
    final active = _activeDeliveries;
    final recent = _deliveries.take(4).toList();

    // Overlay the active parcel's route on the always-on home map.
    final markers = <StanMarker>[];
    List<LatLng>? routeLine;
    if (active.isNotEmpty) {
      final d = active.first;
      final pLat = d['pickupLatitude'];
      final pLng = d['pickupLongitude'];
      final dLat = d['dropoffLatitude'];
      final dLng = d['dropoffLongitude'];
      if (pLat is num && pLng is num) {
        markers.add(StanMarker(
          id: 'home-pickup',
          point: LatLng(pLat.toDouble(), pLng.toDouble()),
          kind: StanMarkerKind.pickup,
        ));
      }
      if (dLat is num && dLng is num) {
        markers.add(StanMarker(
          id: 'home-dropoff',
          point: LatLng(dLat.toDouble(), dLng.toDouble()),
          kind: StanMarkerKind.dropoff,
        ));
      }
      if (markers.length == 2) routeLine = [markers.first.point, markers.last.point];
    }

    final screenHeight = MediaQuery.of(context).size.height;

    return Stack(
      children: [
        // Persistent full-screen map — always visible behind the sheet.
        Positioned.fill(
          child: StanMap(
            controller: _homeMapController,
            initialCenter: _homeCenter,
            initialZoom: _hasLocation ? 15.5 : 12,
            // Only enable the live-location layer once permission is granted,
            // so the native map never hits a permission-timing exception.
            myLocation: _hasLocation,
            markers: markers,
            polyline: routeLine,
          ),
        ),
        Align(alignment: Alignment.topCenter, child: _buildHomeTopBar()),
        Positioned(
          right: 16,
          bottom: screenHeight * 0.46,
          child: FloatingActionButton.small(
            heroTag: 'home-locate',
            backgroundColor: Colors.white,
            foregroundColor: stanDark,
            onPressed: _locateHome,
            child: const Icon(Icons.my_location),
          ),
        ),
        DraggableScrollableSheet(
          initialChildSize: 0.44,
          minChildSize: 0.28,
          maxChildSize: 0.9,
          builder: (sheetContext, scrollController) {
            return Container(
              decoration: const BoxDecoration(
                color: stanSurface,
                borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
                boxShadow: [
                  BoxShadow(color: Color(0x33000000), blurRadius: 20, offset: Offset(0, -4)),
                ],
              ),
              child: ListView(
                controller: scrollController,
                padding: const EdgeInsets.fromLTRB(18, 10, 18, 24),
                children: [
                  Center(
                    child: Container(
                      width: 44,
                      height: 5,
                      margin: const EdgeInsets.only(bottom: 16),
                      decoration: BoxDecoration(
                        color: const Color(0xFFCBD5E1),
                        borderRadius: BorderRadius.circular(999),
                      ),
                    ),
                  ),
                  // Uber-style "where to?" bar — the primary action.
                  InkWell(
                    borderRadius: BorderRadius.circular(16),
                    onTap: _openBookingFlow,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                      decoration: BoxDecoration(
                        color: stanDark,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: const Row(
                        children: [
                          Icon(Icons.search, color: Colors.white),
                          SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              'Send a parcel — where to?',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 15.5,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                          Icon(Icons.arrow_forward_rounded, color: Colors.white),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  if (active.isNotEmpty) ...[
                    const Text(
                      'In progress',
                      style: TextStyle(color: stanDark, fontWeight: FontWeight.w900, fontSize: 16),
                    ),
                    const SizedBox(height: 10),
                    _buildActiveParcelCard(active.first),
                    if (active.length > 1) ...[
                      const SizedBox(height: 8),
                      TextButton(
                        onPressed: () => setState(() => _tab = 1),
                        child: Text(
                          '+${active.length - 1} more active parcel${active.length > 2 ? 's' : ''}',
                          style: const TextStyle(fontWeight: FontWeight.w800),
                        ),
                      ),
                    ],
                    const SizedBox(height: 16),
                  ],
                  Row(
                    children: [
                      _quickAction(
                        Icons.add_box_outlined,
                        'Send a parcel',
                        'Book a pickup on the map',
                        _openBookingFlow,
                      ),
                      const SizedBox(width: 12),
                      _quickAction(
                        Icons.support_agent,
                        'Support',
                        'Call the Stan team',
                        _callSupport,
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  if (recent.isNotEmpty) ...[
                    Row(
                      children: [
                        const Text(
                          'Recent activity',
                          style: TextStyle(color: stanDark, fontWeight: FontWeight.w900, fontSize: 16),
                        ),
                        const Spacer(),
                        TextButton(
                          onPressed: () => setState(() => _tab = 1),
                          child: const Text('See all', style: TextStyle(fontWeight: FontWeight.w800)),
                        ),
                      ],
                    ),
                    for (final delivery in recent) ...[
                      _buildParcelCard(delivery, compact: true),
                      const SizedBox(height: 10),
                    ],
                  ] else if (!_isLoadingDeliveries) ...[
                    const SizedBox(height: 4),
                    Container(
                      padding: const EdgeInsets.all(18),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(18),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.inventory_2_outlined, color: stanMuted, size: 34),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Text(
                              _statusMessage ??
                                  'No parcels yet. Tap "Send a parcel" to book your first pickup.',
                              style: const TextStyle(
                                color: Color(0xFF60727A),
                                fontWeight: FontWeight.w700,
                                height: 1.4,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            );
          },
        ),
      ],
    );
  }

  /* ------------------------------ Parcels tab ---------------------------- */

  Widget _buildParcelCard(Map<String, dynamic> delivery, {bool compact = false}) {
    final isReceiver = delivery['role'] == 'receiver';
    final progress = customerProgress(delivery);
    final status = delivery['status'] as String? ?? 'pending';
    final isActive = status != 'delivered' && status != 'cancelled';

    return InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: () => _openParcel(delivery['id'] as int),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(18),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: isReceiver ? const Color(0xFFDBEAFE) : const Color(0xFFE2E8F0),
                    borderRadius: BorderRadius.circular(7),
                  ),
                  child: Text(
                    isReceiver ? 'RECEIVING' : 'SENDING',
                    style: TextStyle(
                      color: isReceiver ? const Color(0xFF1D4ED8) : const Color(0xFF475569),
                      fontSize: 10,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    delivery['trackingCode'] as String? ?? '',
                    style: const TextStyle(color: stanDark, fontWeight: FontWeight.w900),
                  ),
                ),
                customerStatusChip(status),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              '${delivery['pickupAddress']} → ${delivery['dropoffAddress']}',
              maxLines: compact ? 1 : 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Color(0xFF60727A), fontWeight: FontWeight.w600),
            ),
            if (isActive) ...[
              const SizedBox(height: 10),
              ClipRRect(
                borderRadius: BorderRadius.circular(999),
                child: LinearProgressIndicator(
                  value: progress,
                  minHeight: 5,
                  backgroundColor: stanSurface,
                  valueColor: const AlwaysStoppedAnimation<Color>(stanDark),
                ),
              ),
            ],
            const SizedBox(height: 8),
            Row(
              children: [
                Text(
                  formatKsh((delivery['fareAmount'] as num?) ?? 0),
                  style: const TextStyle(
                    color: stanDark,
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                if (delivery['viaCollectionPoint'] == true) ...[
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'via ${delivery['collectionPointName'] ?? 'collection point'}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Color(0xFF94A3B8),
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ] else
                  const Spacer(),
                const Icon(Icons.chevron_right, color: Color(0xFFCBD5E1), size: 20),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildParcelsTab() {
    final active = _activeDeliveries;
    final past = _pastDeliveries;

    return RefreshIndicator(
      onRefresh: _loadDeliveries,
      child: _deliveries.isEmpty
          ? ListView(
              padding: const EdgeInsets.all(24),
              children: [
                SizedBox(height: MediaQuery.of(context).padding.top + 40),
                const Icon(Icons.inventory_2_outlined, size: 56, color: stanMuted),
                const SizedBox(height: 12),
                Center(
                  child: Text(
                    _isLoadingDeliveries
                        ? 'Loading your parcels…'
                        : (_statusMessage ?? 'No parcels yet. Book your first pickup!'),
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Color(0xFF60727A),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            )
          : ListView(
              padding: EdgeInsets.fromLTRB(
                20,
                MediaQuery.of(context).padding.top + 18,
                20,
                28,
              ),
              children: [
                const Text(
                  'My Parcels',
                  style: TextStyle(color: stanDark, fontSize: 22, fontWeight: FontWeight.w900),
                ),
                const SizedBox(height: 16),
                if (active.isNotEmpty) ...[
                  const Text(
                    'Active',
                    style: TextStyle(color: Color(0xFF64748B), fontWeight: FontWeight.w900, fontSize: 13),
                  ),
                  const SizedBox(height: 10),
                  for (final delivery in active) ...[
                    _buildParcelCard(delivery),
                    const SizedBox(height: 12),
                  ],
                ],
                if (past.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  const Text(
                    'History',
                    style: TextStyle(color: Color(0xFF64748B), fontWeight: FontWeight.w900, fontSize: 13),
                  ),
                  const SizedBox(height: 10),
                  for (final delivery in past) ...[
                    _buildParcelCard(delivery),
                    const SizedBox(height: 12),
                  ],
                ],
              ],
            ),
    );
  }

  /* ------------------------------ Profile tab ---------------------------- */

  Future<void> _editAccount() async {
    final phoneController = TextEditingController(text: _phone);
    final emailController = TextEditingController();

    final saved = await showModalBottomSheet<bool>(
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
              setSheet(() {
                busy = true;
                error = null;
              });
              try {
                final response = await http
                    .patch(
                      Uri.parse('$apiBaseUrl/customer/account'),
                      headers: {
                        ...customerAuthHeaders(widget.token),
                        'Content-Type': 'application/json',
                      },
                      body: jsonEncode({
                        'phone': phoneController.text.trim(),
                        if (emailController.text.trim().isNotEmpty)
                          'email': emailController.text.trim(),
                      }),
                    )
                    .timeout(apiRequestTimeout);
                final data = jsonDecode(response.body) as Map<String, dynamic>;
                if (!sheetContext.mounted) return;
                if (response.statusCode == 200) {
                  Navigator.of(sheetContext).pop(true);
                } else {
                  setSheet(() {
                    busy = false;
                    error = data['message'] as String? ?? 'Could not update your account.';
                  });
                }
              } catch (_) {
                if (!sheetContext.mounted) return;
                setSheet(() {
                  busy = false;
                  error = 'Could not reach the server.';
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
                    'Edit account',
                    style: TextStyle(color: stanDark, fontSize: 18, fontWeight: FontWeight.w900),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: phoneController,
                    keyboardType: TextInputType.phone,
                    decoration: InputDecoration(
                      labelText: 'Phone number',
                      filled: true,
                      fillColor: stanSurface,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: emailController,
                    keyboardType: TextInputType.emailAddress,
                    decoration: InputDecoration(
                      labelText: 'Email (optional)',
                      filled: true,
                      fillColor: stanSurface,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                  if (error != null) ...[
                    const SizedBox(height: 10),
                    Text(
                      error!,
                      style: const TextStyle(color: Color(0xFFDC2626), fontWeight: FontWeight.w700),
                    ),
                  ],
                  const SizedBox(height: 16),
                  FilledButton(
                    style: FilledButton.styleFrom(backgroundColor: stanDark),
                    onPressed: busy ? null : submit,
                    child: Text(busy ? 'Saving…' : 'Save changes'),
                  ),
                ],
              ),
            );
          },
        );
      },
    );

    if (saved == true && mounted) {
      setState(() => _phone = phoneController.text.trim());
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Account updated.')),
      );
    }
  }

  Widget _profileTile(IconData icon, String title, String caption, VoidCallback onTap) {
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(9),
              decoration: BoxDecoration(
                color: stanSurface,
                borderRadius: BorderRadius.circular(11),
              ),
              child: Icon(icon, color: stanDark, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      color: stanDark,
                      fontWeight: FontWeight.w900,
                      fontSize: 14,
                    ),
                  ),
                  Text(
                    caption,
                    style: const TextStyle(
                      color: Color(0xFF94A3B8),
                      fontWeight: FontWeight.w600,
                      fontSize: 11.5,
                    ),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, color: Color(0xFFCBD5E1)),
          ],
        ),
      ),
    );
  }

  Widget _buildProfileTab() {
    final delivered =
        _deliveries.where((delivery) => delivery['status'] == 'delivered').length;

    return ListView(
      padding: EdgeInsets.fromLTRB(20, MediaQuery.of(context).padding.top + 18, 20, 28),
      children: [
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [stanDark, stanPanel],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(22),
          ),
          child: Row(
            children: [
              CircleAvatar(
                radius: 28,
                backgroundColor: Colors.white,
                child: Text(
                  widget.fullName.isNotEmpty ? widget.fullName[0].toUpperCase() : 'C',
                  style: const TextStyle(
                    color: stanDark,
                    fontWeight: FontWeight.w900,
                    fontSize: 22,
                  ),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.fullName,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w900,
                        fontSize: 18,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _phone,
                      style: const TextStyle(
                        color: stanMuted,
                        fontWeight: FontWeight.w700,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
              Column(
                children: [
                  Text(
                    '$delivered',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w900,
                      fontSize: 20,
                    ),
                  ),
                  const Text(
                    'delivered',
                    style: TextStyle(color: stanMuted, fontSize: 11, fontWeight: FontWeight.w700),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(9),
                decoration: BoxDecoration(
                  color: stanSurface,
                  borderRadius: BorderRadius.circular(11),
                ),
                child: const Icon(Icons.brightness_6_outlined, color: stanDark, size: 20),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Text(
                  'Appearance',
                  style: TextStyle(
                    color: stanDark,
                    fontWeight: FontWeight.w900,
                    fontSize: 14,
                  ),
                ),
              ),
              const ThemeModeToggle(),
            ],
          ),
        ),
        _profileTile(
          Icons.manage_accounts_outlined,
          'Edit account',
          'Update your phone number and email',
          _editAccount,
        ),
        _profileTile(
          Icons.support_agent,
          'Support',
          'Call the Stan team',
          _callSupport,
        ),
        _profileTile(
          Icons.info_outline,
          'About Stan',
          'Premium parcel logistics for Nairobi',
          () => showAboutDialog(
            context: context,
            applicationName: 'Stan',
            applicationVersion: 'Customer app',
            children: const [
              Text('Book pickups, route through collection points, and track parcels live.'),
            ],
          ),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(
            foregroundColor: const Color(0xFFB91C1C),
            side: const BorderSide(color: Color(0xFFFECACA)),
            minimumSize: const Size.fromHeight(48),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          ),
          onPressed: () {
            Navigator.of(context).pushAndRemoveUntil(
              MaterialPageRoute(builder: (_) => const LoginScreen()),
              (route) => false,
            );
          },
          icon: const Icon(Icons.logout, size: 18),
          label: const Text('Sign out', style: TextStyle(fontWeight: FontWeight.w900)),
        ),
      ],
    );
  }

  /* --------------------------------- Shell ------------------------------- */

  @override
  Widget build(BuildContext context) {
    final pages = [_buildHomeTab(), _buildParcelsTab(), _buildProfileTab()];

    return Scaffold(
      backgroundColor: stanSurface,
      body: pages[_tab],
      bottomNavigationBar: NavigationBarTheme(
        data: NavigationBarThemeData(
          backgroundColor: Colors.white,
          indicatorColor: stanDark.withValues(alpha: 0.12),
          labelTextStyle: WidgetStateProperty.resolveWith(
            (states) => TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w800,
              color: states.contains(WidgetState.selected)
                  ? stanDark
                  : const Color(0xFF94A3B8),
            ),
          ),
        ),
        child: NavigationBar(
          selectedIndex: _tab,
          onDestinationSelected: (index) {
            setState(() => _tab = index);
            if (index != 2) _loadDeliveries();
          },
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.home_outlined),
              selectedIcon: Icon(Icons.home, color: stanDark),
              label: 'Home',
            ),
            NavigationDestination(
              icon: Icon(Icons.inventory_2_outlined),
              selectedIcon: Icon(Icons.inventory_2, color: stanDark),
              label: 'My Parcels',
            ),
            NavigationDestination(
              icon: Icon(Icons.person_outline),
              selectedIcon: Icon(Icons.person, color: stanDark),
              label: 'Profile',
            ),
          ],
        ),
      ),
    );
  }
}
