// Customer experience for the Stan app: signup, booking a delivery (direct or
// via a collection point), and tracking parcels the customer sends/receives.
// The same app serves riders and customers — the login screen routes by role.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import 'main.dart';

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
                  'Book pickups, route through collection points, and track your parcel live.',
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
// Customer home (Book / My Parcels / Profile)
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
  List<Map<String, dynamic>> _collectionPoints = [];
  bool _isLoadingDeliveries = false;
  String? _statusMessage;

  // Booking form
  final _pickupAddressController = TextEditingController(text: 'Nairobi CBD');
  final _pickupLatController = TextEditingController(text: '-1.286389');
  final _pickupLngController = TextEditingController(text: '36.817223');
  final _dropoffAddressController = TextEditingController();
  final _dropoffLatController = TextEditingController(text: '-1.264100');
  final _dropoffLngController = TextEditingController(text: '36.802800');
  final _receiverNameController = TextEditingController();
  final _receiverPhoneController = TextEditingController();
  int? _selectedCollectionPointId;
  String _payer = 'receiver';
  Map<String, dynamic>? _quote;
  bool _isBooking = false;
  bool _isQuoting = false;
  bool _isLocating = false;

  Map<String, String> get _authHeaders => {
        'Authorization': 'Bearer ${widget.token}',
      };

  @override
  void initState() {
    super.initState();
    _loadCollectionPoints();
    _loadDeliveries();
  }

  @override
  void dispose() {
    _pickupAddressController.dispose();
    _pickupLatController.dispose();
    _pickupLngController.dispose();
    _dropoffAddressController.dispose();
    _dropoffLatController.dispose();
    _dropoffLngController.dispose();
    _receiverNameController.dispose();
    _receiverPhoneController.dispose();
    super.dispose();
  }

  Future<void> _loadCollectionPoints() async {
    try {
      final response = await http
          .get(
            Uri.parse('$apiBaseUrl/customer/collection-points'),
            headers: _authHeaders,
          )
          .timeout(apiRequestTimeout);

      if (!mounted || response.statusCode != 200) return;

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      setState(() {
        _collectionPoints = (data['collectionPoints'] as List<dynamic>)
            .cast<Map<String, dynamic>>();
      });
    } catch (_) {
      // Collection points are optional for direct bookings; ignore failures.
    }
  }

  Future<void> _loadDeliveries() async {
    setState(() {
      _isLoadingDeliveries = true;
    });

    try {
      final response = await http
          .get(
            Uri.parse('$apiBaseUrl/customer/deliveries'),
            headers: _authHeaders,
          )
          .timeout(apiRequestTimeout);

      if (!mounted) return;

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        setState(() {
          _deliveries =
              (data['deliveries'] as List<dynamic>).cast<Map<String, dynamic>>();
          _statusMessage = null;
        });
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

  Future<void> _useMyLocation() async {
    setState(() => _isLocating = true);

    try {
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        throw Exception('denied');
      }

      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
      );

      if (!mounted) return;
      setState(() {
        _pickupLatController.text = position.latitude.toStringAsFixed(6);
        _pickupLngController.text = position.longitude.toStringAsFixed(6);
        _quote = null;
      });
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not read your GPS location.')),
      );
    } finally {
      if (mounted) setState(() => _isLocating = false);
    }
  }

  Future<void> _getQuote() async {
    setState(() {
      _isQuoting = true;
      _quote = null;
    });

    try {
      final query = <String, String>{
        'pickupLatitude': _pickupLatController.text.trim(),
        'pickupLongitude': _pickupLngController.text.trim(),
        'dropoffLatitude': _dropoffLatController.text.trim(),
        'dropoffLongitude': _dropoffLngController.text.trim(),
        if (_selectedCollectionPointId != null)
          'collectionPointId': '$_selectedCollectionPointId',
      };
      final uri = Uri.parse('$apiBaseUrl/customer/fare-quote')
          .replace(queryParameters: query);

      final response =
          await http.get(uri, headers: _authHeaders).timeout(apiRequestTimeout);
      final data = jsonDecode(response.body) as Map<String, dynamic>;

      if (!mounted) return;

      if (response.statusCode == 200) {
        setState(() => _quote = data);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(data['message'] as String? ?? 'Could not price the trip.'),
          ),
        );
      }
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not fetch a fare estimate.')),
      );
    } finally {
      if (mounted) setState(() => _isQuoting = false);
    }
  }

  Future<void> _book() async {
    setState(() => _isBooking = true);

    try {
      final response = await http
          .post(
            Uri.parse('$apiBaseUrl/customer/deliveries'),
            headers: {..._authHeaders, 'Content-Type': 'application/json'},
            body: jsonEncode({
              'pickupAddress': _pickupAddressController.text.trim(),
              'pickupLatitude': double.tryParse(_pickupLatController.text.trim()),
              'pickupLongitude': double.tryParse(_pickupLngController.text.trim()),
              'dropoffAddress': _dropoffAddressController.text.trim(),
              'dropoffLatitude': double.tryParse(_dropoffLatController.text.trim()),
              'dropoffLongitude': double.tryParse(_dropoffLngController.text.trim()),
              'receiverName': _receiverNameController.text.trim(),
              'receiverPhone': _receiverPhoneController.text.trim(),
              'payer': _payer,
              if (_selectedCollectionPointId != null)
                'collectionPointId': _selectedCollectionPointId,
            }),
          )
          .timeout(apiRequestTimeout);

      final data = jsonDecode(response.body) as Map<String, dynamic>;

      if (!mounted) return;

      if (response.statusCode == 201) {
        final delivery = data['delivery'] as Map<String, dynamic>?;
        final code = delivery?['trackingCode'] as String? ?? '—';
        final fare = (delivery?['fareAmount'] as num?) ?? 0;

        _dropoffAddressController.clear();
        _receiverNameController.clear();
        _receiverPhoneController.clear();
        setState(() => _quote = null);
        await _loadDeliveries();

        if (!mounted) return;
        await showDialog<void>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('Booking confirmed'),
            content: Text(
              'Tracking code: $code\n'
              'Fare: ${formatKsh(fare)}\n\n'
              '${_payer == 'sender' ? 'You chose to pay as the sender.' : 'The receiver pays on delivery.'}\n'
              'The receiver will see the handover PIN in their Stan app.',
            ),
            actions: [
              FilledButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('Done'),
              ),
            ],
          ),
        );
        if (mounted) setState(() => _tab = 1);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(data['message'] as String? ?? 'Could not book the delivery.'),
          ),
        );
      }
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not reach the server to book.')),
      );
    } finally {
      if (mounted) setState(() => _isBooking = false);
    }
  }

  /* ------------------------------ Detail sheet --------------------------- */

  List<({String label, bool done})> _timeline(Map<String, dynamic> delivery) {
    final via = delivery['viaCollectionPoint'] == true;
    final status = delivery['status'] as String? ?? 'pending';
    final leg = (delivery['currentLeg'] as num?)?.toInt() ?? 1;

    int reached;
    List<String> labels;

    if (via) {
      labels = [
        'Booked',
        'Rider assigned',
        'Picked up',
        'At collection point',
        'Out for delivery',
        'Delivered',
      ];
      reached = switch (status) {
        'pending' => 0,
        'assigned' => leg == 1 ? 1 : 4,
        'picked_up' || 'in_transit' => leg == 1 ? 2 : 4,
        'at_collection_point' => 3,
        'delivered' => 5,
        _ => 0,
      };
    } else {
      labels = ['Booked', 'Rider assigned', 'Picked up', 'In transit', 'Delivered'];
      reached = switch (status) {
        'pending' => 0,
        'assigned' => 1,
        'picked_up' => 2,
        'in_transit' => 3,
        'delivered' => 4,
        _ => 0,
      };
    }

    return [
      for (var i = 0; i < labels.length; i++) (label: labels[i], done: i <= reached),
    ];
  }

  Future<void> _openDetail(Map<String, dynamic> summary) async {
    final deliveryId = summary['id'] as int;

    Map<String, dynamic> delivery = summary;
    Map<String, dynamic>? riderLocation;

    try {
      final response = await http
          .get(
            Uri.parse('$apiBaseUrl/customer/deliveries/$deliveryId'),
            headers: _authHeaders,
          )
          .timeout(apiRequestTimeout);
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        delivery = data['delivery'] as Map<String, dynamic>;
        riderLocation = data['riderLocation'] as Map<String, dynamic>?;
      }
    } catch (_) {
      // Fall back to the summary we already have.
    }

    if (!mounted) return;

    final steps = _timeline(delivery);
    final isReceiver = delivery['role'] == 'receiver';
    final pin = delivery['deliveryPin'] as String?;
    final riderPoint = riderLocation == null
        ? null
        : LatLng(
            (riderLocation['latitude'] as num).toDouble(),
            (riderLocation['longitude'] as num).toDouble(),
          );

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (sheetContext) {
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.72,
          maxChildSize: 0.92,
          builder: (sheetContext, scrollController) {
            return ListView(
              controller: scrollController,
              padding: const EdgeInsets.fromLTRB(24, 18, 24, 32),
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        delivery['trackingCode'] as String? ?? 'Parcel',
                        style: const TextStyle(
                          color: stanDark,
                          fontSize: 19,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                    _statusChip(delivery['status'] as String? ?? 'pending'),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  '${delivery['pickupAddress']} → ${delivery['dropoffAddress']}',
                  style: const TextStyle(color: Color(0xFF60727A), fontWeight: FontWeight.w600),
                ),
                if (delivery['viaCollectionPoint'] == true) ...[
                  const SizedBox(height: 4),
                  Text(
                    'Via ${delivery['collectionPointName'] ?? 'collection point'} · leg ${delivery['currentLeg']} of 2',
                    style: const TextStyle(color: Color(0xFF60727A), fontWeight: FontWeight.w600),
                  ),
                ],
                const SizedBox(height: 18),
                if (isReceiver && pin != null) ...[
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: stanDark,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Column(
                      children: [
                        const Text(
                          'HANDOVER PIN — give this to the rider',
                          style: TextStyle(
                            color: Colors.white70,
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.6,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          pin,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 30,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 10,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 18),
                ],
                const Text(
                  'Progress',
                  style: TextStyle(color: stanDark, fontWeight: FontWeight.w900, fontSize: 15),
                ),
                const SizedBox(height: 10),
                for (final step in steps)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 5),
                    child: Row(
                      children: [
                        Icon(
                          step.done ? Icons.check_circle : Icons.radio_button_unchecked,
                          size: 20,
                          color: step.done ? const Color(0xFF16A34A) : const Color(0xFFCBD5E1),
                        ),
                        const SizedBox(width: 10),
                        Text(
                          step.label,
                          style: TextStyle(
                            color: step.done ? stanDark : const Color(0xFF94A3B8),
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: stanSurface,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Row(
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Fare · ${delivery['payer'] == 'sender' ? 'sender pays' : 'receiver pays on delivery'}',
                            style: const TextStyle(
                              color: Color(0xFF64748B),
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            formatKsh((delivery['fareAmount'] as num?) ?? 0),
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
                          color: delivery['paymentStatus'] == 'paid'
                              ? const Color(0xFFDCFCE7)
                              : const Color(0xFFFEF3C7),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          delivery['paymentStatus'] == 'paid'
                              ? 'PAID · ${(delivery['paymentMethod'] as String? ?? '').toUpperCase()}'
                              : 'UNPAID',
                          style: TextStyle(
                            color: delivery['paymentStatus'] == 'paid'
                                ? const Color(0xFF166534)
                                : const Color(0xFF92400E),
                            fontSize: 10.5,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                if (riderPoint != null) ...[
                  const SizedBox(height: 16),
                  Text(
                    'Rider position · ${delivery['riderName'] ?? 'rider'}',
                    style: const TextStyle(
                      color: stanDark,
                      fontWeight: FontWeight.w900,
                      fontSize: 15,
                    ),
                  ),
                  const SizedBox(height: 10),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: SizedBox(
                      height: 190,
                      child: FlutterMap(
                        options: MapOptions(
                          initialCenter: riderPoint,
                          initialZoom: 13,
                          interactionOptions: const InteractionOptions(
                            flags: InteractiveFlag.none,
                          ),
                        ),
                        children: [
                          TileLayer(
                            urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                            userAgentPackageName: 'com.stan.driver_app',
                          ),
                          MarkerLayer(
                            markers: [
                              Marker(
                                point: riderPoint,
                                width: 40,
                                height: 40,
                                child: const Icon(
                                  Icons.local_shipping,
                                  color: stanDark,
                                  size: 30,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ],
            );
          },
        );
      },
    );
  }

  /* --------------------------------- UI ----------------------------------- */

  Widget _statusChip(String status) {
    final palette = switch (status) {
      'delivered' => (const Color(0xFF166534), const Color(0xFFDCFCE7)),
      'pending' => (const Color(0xFF475569), const Color(0xFFE2E8F0)),
      'at_collection_point' => (const Color(0xFF6D28D9), const Color(0xFFEDE9FE)),
      _ => (const Color(0xFF92400E), const Color(0xFFFEF3C7)),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: palette.$2,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        formatDeliveryStatus(status),
        style: TextStyle(color: palette.$1, fontSize: 11, fontWeight: FontWeight.w900),
      ),
    );
  }

  InputDecoration _fieldDecoration(String label) {
    return InputDecoration(
      labelText: label,
      filled: true,
      fillColor: Colors.white,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide.none,
      ),
    );
  }

  Widget _buildBookTab() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 28),
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
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Hello, ${widget.fullName.split(' ').first}',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 4),
              const Text(
                'Book a pickup and we will move your parcel across Nairobi.',
                style: TextStyle(color: Color(0xFFB9C6DB), fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        const Text(
          'Pickup',
          style: TextStyle(color: stanDark, fontWeight: FontWeight.w900, fontSize: 15),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _pickupAddressController,
          decoration: _fieldDecoration('Pickup address'),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _pickupLatController,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                  signed: true,
                ),
                decoration: _fieldDecoration('Latitude'),
                onChanged: (_) => setState(() => _quote = null),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: TextField(
                controller: _pickupLngController,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                  signed: true,
                ),
                decoration: _fieldDecoration('Longitude'),
                onChanged: (_) => setState(() => _quote = null),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: _isLocating ? null : _useMyLocation,
            icon: _isLocating
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.my_location, size: 18),
            label: const Text('Use my current location'),
          ),
        ),
        const SizedBox(height: 12),
        const Text(
          'Dropoff',
          style: TextStyle(color: stanDark, fontWeight: FontWeight.w900, fontSize: 15),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _dropoffAddressController,
          decoration: _fieldDecoration('Dropoff address'),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _dropoffLatController,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                  signed: true,
                ),
                decoration: _fieldDecoration('Latitude'),
                onChanged: (_) => setState(() => _quote = null),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: TextField(
                controller: _dropoffLngController,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                  signed: true,
                ),
                decoration: _fieldDecoration('Longitude'),
                onChanged: (_) => setState(() => _quote = null),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        const Text(
          'Receiver',
          style: TextStyle(color: stanDark, fontWeight: FontWeight.w900, fontSize: 15),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _receiverNameController,
          decoration: _fieldDecoration('Receiver full name'),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _receiverPhoneController,
          keyboardType: TextInputType.phone,
          decoration: _fieldDecoration('Receiver phone'),
        ),
        const SizedBox(height: 16),
        const Text(
          'Routing & payment',
          style: TextStyle(color: stanDark, fontWeight: FontWeight.w900, fontSize: 15),
        ),
        const SizedBox(height: 10),
        DropdownButtonFormField<int?>(
          initialValue: _selectedCollectionPointId,
          decoration: _fieldDecoration('Collection point'),
          items: [
            const DropdownMenuItem<int?>(
              value: null,
              child: Text('Direct — rider goes straight to receiver'),
            ),
            for (final point in _collectionPoints)
              DropdownMenuItem<int?>(
                value: point['id'] as int,
                child: Text('Via ${point['name']}'),
              ),
          ],
          onChanged: (value) => setState(() {
            _selectedCollectionPointId = value;
            _quote = null;
          }),
        ),
        const SizedBox(height: 12),
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: 'sender', label: Text('I pay'), icon: Icon(Icons.person)),
            ButtonSegment(
              value: 'receiver',
              label: Text('Receiver pays on delivery'),
              icon: Icon(Icons.person_pin_circle_outlined),
            ),
          ],
          selected: {_payer},
          onSelectionChanged: (selection) => setState(() => _payer = selection.first),
        ),
        const SizedBox(height: 16),
        if (_quote != null)
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(
              children: [
                const Icon(Icons.route, color: stanDark),
                const SizedBox(width: 10),
                Text(
                  '${_quote!['distanceKm']} km · ${formatKsh((_quote!['fare'] as num?) ?? 0)}',
                  style: const TextStyle(
                    color: stanDark,
                    fontWeight: FontWeight.w900,
                    fontSize: 16,
                  ),
                ),
              ],
            ),
          ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: _isQuoting ? null : _getQuote,
                child: Text(_isQuoting ? 'Pricing…' : 'Fare estimate'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton(
                style: FilledButton.styleFrom(backgroundColor: stanDark),
                onPressed: _isBooking ? null : _book,
                child: Text(_isBooking ? 'Booking…' : 'Book pickup'),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildParcelsTab() {
    return RefreshIndicator(
      onRefresh: _loadDeliveries,
      child: _deliveries.isEmpty
          ? ListView(
              padding: const EdgeInsets.all(24),
              children: [
                const SizedBox(height: 60),
                Icon(Icons.inventory_2_outlined, size: 56, color: stanMuted),
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
          : ListView.separated(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 28),
              itemCount: _deliveries.length,
              separatorBuilder: (_, _) => const SizedBox(height: 12),
              itemBuilder: (context, index) {
                final delivery = _deliveries[index];
                final isReceiver = delivery['role'] == 'receiver';

                return InkWell(
                  borderRadius: BorderRadius.circular(18),
                  onTap: () => _openDetail(delivery),
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
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: isReceiver
                                    ? const Color(0xFFDBEAFE)
                                    : const Color(0xFFE2E8F0),
                                borderRadius: BorderRadius.circular(7),
                              ),
                              child: Text(
                                isReceiver ? 'RECEIVING' : 'SENDING',
                                style: TextStyle(
                                  color: isReceiver
                                      ? const Color(0xFF1D4ED8)
                                      : const Color(0xFF475569),
                                  fontSize: 10,
                                  fontWeight: FontWeight.w900,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                delivery['trackingCode'] as String? ?? '',
                                style: const TextStyle(
                                  color: stanDark,
                                  fontWeight: FontWeight.w900,
                                ),
                              ),
                            ),
                            _statusChip(delivery['status'] as String? ?? 'pending'),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Text(
                          '${delivery['pickupAddress']} → ${delivery['dropoffAddress']}',
                          style: const TextStyle(
                            color: Color(0xFF60727A),
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          '${formatKsh((delivery['fareAmount'] as num?) ?? 0)}'
                          '${delivery['viaCollectionPoint'] == true ? ' · via ${delivery['collectionPointName'] ?? 'collection point'}' : ''}',
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
              },
            ),
    );
  }

  Widget _buildProfileTab() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 28),
      children: [
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(
            children: [
              CircleAvatar(
                radius: 26,
                backgroundColor: stanDark,
                child: Text(
                  widget.fullName.isNotEmpty ? widget.fullName[0].toUpperCase() : 'C',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w900,
                    fontSize: 20,
                  ),
                ),
              ),
              const SizedBox(width: 14),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.fullName,
                    style: const TextStyle(
                      color: stanDark,
                      fontWeight: FontWeight.w900,
                      fontSize: 17,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${widget.phone} · Customer',
                    style: const TextStyle(
                      color: Color(0xFF60727A),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        OutlinedButton.icon(
          onPressed: () {
            Navigator.of(context).pushAndRemoveUntil(
              MaterialPageRoute(builder: (_) => const LoginScreen()),
              (route) => false,
            );
          },
          icon: const Icon(Icons.logout),
          label: const Text('Sign out'),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final pages = [_buildBookTab(), _buildParcelsTab(), _buildProfileTab()];

    return Scaffold(
      backgroundColor: stanSurface,
      appBar: AppBar(
        backgroundColor: stanDark,
        foregroundColor: Colors.white,
        title: const Text('Stan', style: TextStyle(fontWeight: FontWeight.w900)),
        actions: [
          IconButton(
            onPressed: _loadDeliveries,
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
          ),
        ],
      ),
      body: pages[_tab],
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (index) {
          setState(() => _tab = index);
          if (index == 1) _loadDeliveries();
        },
        destinations: const [
          NavigationDestination(icon: Icon(Icons.add_box_outlined), label: 'Book'),
          NavigationDestination(icon: Icon(Icons.inventory_2_outlined), label: 'My Parcels'),
          NavigationDestination(icon: Icon(Icons.person_outline), label: 'Profile'),
        ],
      ),
    );
  }
}
