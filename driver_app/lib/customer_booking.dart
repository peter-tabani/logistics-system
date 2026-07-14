// Uber-style parcel booking flow:
//   1. Pin the pickup on the map   2. Pin the dropoff
//   3. Parcel details              4. Review fare + confirm
// Ends on a success screen with the tracking code. Pops with the booked
// delivery map (and whether the user wants to jump straight to tracking).

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import 'customer_common.dart';
import 'main.dart';
import 'stan_map.dart';

class BookParcelFlow extends StatefulWidget {
  const BookParcelFlow({super.key, required this.token});

  final String token;

  @override
  State<BookParcelFlow> createState() => _BookParcelFlowState();
}

class _BookParcelFlowState extends State<BookParcelFlow> {
  int _step = 0;

  final _pickupMapController = StanMapController();
  final _dropoffMapController = StanMapController();
  final _pickupAddressController = TextEditingController();
  final _dropoffAddressController = TextEditingController();
  final _receiverNameController = TextEditingController();
  final _receiverPhoneController = TextEditingController();
  final _notesController = TextEditingController();

  LatLng _pickupInitial = defaultMapCenter;
  LatLng? _pickupPoint;
  LatLng? _dropoffPoint;
  bool _hasLocation = false;

  List<Map<String, dynamic>> _collectionPoints = [];
  int? _selectedCollectionPointId;
  String _payer = 'receiver';
  String? _packageSize = 'small';

  Map<String, dynamic>? _quote;
  bool _isQuoting = false;
  bool _isLocating = false;
  bool _isBooking = false;
  Map<String, dynamic>? _bookedDelivery;
  String? _errorMessage;

  static const _stepTitles = [
    'Where do we pick up?',
    'Where is it going?',
    'Parcel details',
    'Review & confirm',
  ];

  @override
  void initState() {
    super.initState();
    _loadCollectionPoints();
    _centerOnMyLocation(silent: true);
  }

  @override
  void dispose() {
    _pickupAddressController.dispose();
    _dropoffAddressController.dispose();
    _receiverNameController.dispose();
    _receiverPhoneController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  Future<void> _loadCollectionPoints() async {
    try {
      final response = await http
          .get(
            Uri.parse('$apiBaseUrl/customer/collection-points'),
            headers: customerAuthHeaders(widget.token),
          )
          .timeout(apiRequestTimeout);
      if (!mounted || response.statusCode != 200) return;
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      setState(() {
        _collectionPoints =
            (data['collectionPoints'] as List<dynamic>).cast<Map<String, dynamic>>();
      });
    } catch (_) {
      // Optional for direct bookings.
    }
  }

  Future<void> _centerOnMyLocation({bool silent = false}) async {
    if (!silent) setState(() => _isLocating = true);

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
      final point = LatLng(position.latitude, position.longitude);
      setState(() {
        _pickupInitial = point;
        _hasLocation = true;
      });
      _pickupMapController.moveTo(point, zoom: 16);
    } catch (_) {
      if (!silent && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not read your GPS location.')),
        );
      }
    } finally {
      if (!silent && mounted) setState(() => _isLocating = false);
    }
  }

  void _confirmPickup() {
    if (_pickupAddressController.text.trim().isEmpty) {
      setState(() => _errorMessage = 'Describe the pickup place (building, street…).');
      return;
    }
    _pickupPoint = _pickupMapController.center ?? _pickupInitial;
    setState(() {
      _errorMessage = null;
      _step = 1;
    });
    // Start the dropoff picker where the pickup pin landed.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _dropoffMapController.moveTo(_pickupPoint!, zoom: 14);
    });
  }

  void _confirmDropoff() {
    if (_dropoffAddressController.text.trim().isEmpty) {
      setState(() => _errorMessage = 'Describe the dropoff place (building, street…).');
      return;
    }
    _dropoffPoint = _dropoffMapController.center ?? (_pickupPoint ?? _pickupInitial);
    setState(() {
      _errorMessage = null;
      _step = 2;
    });
  }

  void _confirmDetails() {
    if (_receiverNameController.text.trim().length < 2) {
      setState(() => _errorMessage = 'The receiver\'s name is required.');
      return;
    }
    if (_receiverPhoneController.text.trim().length < 7) {
      setState(() => _errorMessage = 'Enter a valid receiver phone number.');
      return;
    }
    setState(() {
      _errorMessage = null;
      _step = 3;
    });
    _fetchQuote();
  }

  Future<void> _fetchQuote() async {
    final pickup = _pickupPoint;
    final dropoff = _dropoffPoint;
    if (pickup == null || dropoff == null) return;

    setState(() {
      _isQuoting = true;
      _quote = null;
    });

    try {
      final query = <String, String>{
        'pickupLatitude': pickup.latitude.toStringAsFixed(6),
        'pickupLongitude': pickup.longitude.toStringAsFixed(6),
        'dropoffLatitude': dropoff.latitude.toStringAsFixed(6),
        'dropoffLongitude': dropoff.longitude.toStringAsFixed(6),
        if (_selectedCollectionPointId != null)
          'collectionPointId': '$_selectedCollectionPointId',
      };
      final uri =
          Uri.parse('$apiBaseUrl/customer/fare-quote').replace(queryParameters: query);
      final response = await http
          .get(uri, headers: customerAuthHeaders(widget.token))
          .timeout(apiRequestTimeout);

      if (!mounted) return;
      if (response.statusCode == 200) {
        setState(() => _quote = jsonDecode(response.body) as Map<String, dynamic>);
      }
    } catch (_) {
      // Review screen shows a retry button when the quote is missing.
    } finally {
      if (mounted) setState(() => _isQuoting = false);
    }
  }

  Future<void> _book() async {
    final pickup = _pickupPoint;
    final dropoff = _dropoffPoint;
    if (pickup == null || dropoff == null) return;

    setState(() {
      _isBooking = true;
      _errorMessage = null;
    });

    try {
      final response = await http
          .post(
            Uri.parse('$apiBaseUrl/customer/deliveries'),
            headers: {
              ...customerAuthHeaders(widget.token),
              'Content-Type': 'application/json',
            },
            body: jsonEncode({
              'pickupAddress': _pickupAddressController.text.trim(),
              'pickupLatitude': pickup.latitude,
              'pickupLongitude': pickup.longitude,
              'dropoffAddress': _dropoffAddressController.text.trim(),
              'dropoffLatitude': dropoff.latitude,
              'dropoffLongitude': dropoff.longitude,
              'receiverName': _receiverNameController.text.trim(),
              'receiverPhone': _receiverPhoneController.text.trim(),
              'payer': _payer,
              'packageSize': _packageSize,
              'notes': _notesController.text.trim(),
              if (_selectedCollectionPointId != null)
                'collectionPointId': _selectedCollectionPointId,
            }),
          )
          .timeout(apiRequestTimeout);

      final data = jsonDecode(response.body) as Map<String, dynamic>;

      if (!mounted) return;

      if (response.statusCode == 201) {
        setState(() {
          _bookedDelivery = data['delivery'] as Map<String, dynamic>?;
          _step = 4;
        });
      } else {
        setState(() {
          _errorMessage = data['message'] as String? ?? 'Could not book the delivery.';
        });
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => _errorMessage = 'Could not reach the server to book.');
    } finally {
      if (mounted) setState(() => _isBooking = false);
    }
  }

  void _goBack() {
    if (_step == 0 || _step == 4) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _errorMessage = null;
      _step -= 1;
    });
  }

  /* --------------------------------- UI ---------------------------------- */

  InputDecoration _decoration(String label, {IconData? icon}) {
    return InputDecoration(
      labelText: label,
      prefixIcon: icon == null ? null : Icon(icon, size: 20),
      filled: true,
      fillColor: Colors.white,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide.none,
      ),
    );
  }

  Widget _stepHeader() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            for (var i = 0; i < 4; i++) ...[
              Expanded(
                child: Container(
                  height: 5,
                  decoration: BoxDecoration(
                    color: i <= _step ? Colors.white : Colors.white24,
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
              ),
              if (i < 3) const SizedBox(width: 5),
            ],
          ],
        ),
        const SizedBox(height: 12),
        Text(
          'Step ${_step + 1} of 4',
          style: const TextStyle(color: stanMuted, fontSize: 12, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 2),
        Text(
          _stepTitles[_step],
          style: const TextStyle(color: Colors.white, fontSize: 21, fontWeight: FontWeight.w900),
        ),
      ],
    );
  }

  Widget _mapPicker({
    required StanMapController controller,
    required LatLng initialCenter,
    required Color pinColor,
    required TextEditingController addressController,
    required String addressLabel,
    required String confirmLabel,
    required VoidCallback onConfirm,
    bool showLocateMe = false,
  }) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 10),
          child: TextField(
            controller: addressController,
            decoration: _decoration(addressLabel, icon: Icons.edit_location_alt_outlined),
          ),
        ),
        Expanded(
          child: Stack(
            children: [
              ClipRRect(
                borderRadius: const BorderRadius.vertical(top: Radius.circular(26)),
                child: StanMap(
                  controller: controller,
                  initialCenter: initialCenter,
                  initialZoom: 15,
                  myLocation: _hasLocation,
                ),
              ),
              // Fixed centre pin — move the map underneath it.
              IgnorePointer(
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 38),
                    child: Icon(Icons.location_on, size: 46, color: pinColor),
                  ),
                ),
              ),
              IgnorePointer(
                child: Align(
                  alignment: Alignment.topCenter,
                  child: Container(
                    margin: const EdgeInsets.only(top: 12),
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                    decoration: BoxDecoration(
                      color: stanDark.withValues(alpha: 0.85),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: const Text(
                      'Move the map to position the pin',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              ),
              if (showLocateMe)
                Positioned(
                  right: 16,
                  bottom: 96,
                  child: FloatingActionButton.small(
                    heroTag: 'locate-me',
                    backgroundColor: Colors.white,
                    foregroundColor: stanDark,
                    onPressed: _isLocating ? null : () => _centerOnMyLocation(),
                    child: _isLocating
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.my_location),
                  ),
                ),
              Positioned(
                left: 16,
                right: 16,
                bottom: 20,
                child: Column(
                  children: [
                    if (_errorMessage != null) ...[
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFEE2E2),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          _errorMessage!,
                          style: const TextStyle(
                            color: Color(0xFF991B1B),
                            fontWeight: FontWeight.w700,
                            fontSize: 12.5,
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                    ],
                    FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: stanDark,
                        minimumSize: const Size.fromHeight(52),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                      ),
                      onPressed: onConfirm,
                      child: Text(
                        confirmLabel,
                        style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 15),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _detailsStep() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
      children: [
        TextField(
          controller: _receiverNameController,
          decoration: _decoration('Receiver full name', icon: Icons.person_outline),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _receiverPhoneController,
          keyboardType: TextInputType.phone,
          decoration: _decoration('Receiver phone', icon: Icons.phone_outlined),
        ),
        const SizedBox(height: 20),
        const Text(
          'Package size',
          style: TextStyle(color: stanDark, fontWeight: FontWeight.w900, fontSize: 15),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            for (final size in const [
              ('small', Icons.shopping_bag_outlined, 'Small'),
              ('medium', Icons.inventory_2_outlined, 'Medium'),
              ('large', Icons.local_shipping_outlined, 'Large'),
            ]) ...[
              Expanded(
                child: InkWell(
                  borderRadius: BorderRadius.circular(16),
                  onTap: () => setState(() => _packageSize = size.$1),
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    decoration: BoxDecoration(
                      color: _packageSize == size.$1 ? stanDark : Colors.white,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Column(
                      children: [
                        Icon(
                          size.$2,
                          color: _packageSize == size.$1 ? Colors.white : stanDark,
                        ),
                        const SizedBox(height: 6),
                        Text(
                          size.$3,
                          style: TextStyle(
                            color: _packageSize == size.$1 ? Colors.white : stanDark,
                            fontWeight: FontWeight.w800,
                            fontSize: 12.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              if (size.$1 != 'large') const SizedBox(width: 10),
            ],
          ],
        ),
        const SizedBox(height: 20),
        const Text(
          'Routing',
          style: TextStyle(color: stanDark, fontWeight: FontWeight.w900, fontSize: 15),
        ),
        const SizedBox(height: 10),
        DropdownButtonFormField<int?>(
          initialValue: _selectedCollectionPointId,
          decoration: _decoration('Collection point', icon: Icons.hub_outlined),
          items: [
            const DropdownMenuItem<int?>(
              value: null,
              child: Text('Direct — straight to the receiver'),
            ),
            for (final point in _collectionPoints)
              DropdownMenuItem<int?>(
                value: point['id'] as int,
                child: Text('Via ${point['name']}'),
              ),
          ],
          onChanged: (value) => setState(() => _selectedCollectionPointId = value),
        ),
        const SizedBox(height: 20),
        const Text(
          'Who pays?',
          style: TextStyle(color: stanDark, fontWeight: FontWeight.w900, fontSize: 15),
        ),
        const SizedBox(height: 10),
        SegmentedButton<String>(
          style: SegmentedButton.styleFrom(
            backgroundColor: Colors.white,
            selectedBackgroundColor: stanDark,
            selectedForegroundColor: Colors.white,
          ),
          segments: const [
            ButtonSegment(value: 'sender', label: Text('I pay now'), icon: Icon(Icons.smartphone)),
            ButtonSegment(
              value: 'receiver',
              label: Text('Receiver pays'),
              icon: Icon(Icons.person_pin_circle_outlined),
            ),
          ],
          selected: {_payer},
          onSelectionChanged: (selection) => setState(() => _payer = selection.first),
        ),
        const SizedBox(height: 20),
        TextField(
          controller: _notesController,
          maxLines: 2,
          decoration: _decoration('Instructions for the rider (optional)',
              icon: Icons.sticky_note_2_outlined),
        ),
        if (_errorMessage != null) ...[
          const SizedBox(height: 14),
          Text(
            _errorMessage!,
            style: const TextStyle(color: Color(0xFFDC2626), fontWeight: FontWeight.w700),
          ),
        ],
        const SizedBox(height: 20),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: stanDark,
            minimumSize: const Size.fromHeight(52),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          ),
          onPressed: _confirmDetails,
          child: const Text(
            'Review booking',
            style: TextStyle(fontWeight: FontWeight.w900, fontSize: 15),
          ),
        ),
      ],
    );
  }

  Widget _reviewRow(IconData icon, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 19, color: const Color(0xFF64748B)),
          const SizedBox(width: 10),
          SizedBox(
            width: 92,
            child: Text(
              label,
              style: const TextStyle(
                color: Color(0xFF64748B),
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(
                color: stanDark,
                fontSize: 13.5,
                fontWeight: FontWeight.w800,
                height: 1.3,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _reviewStep() {
    final pickup = _pickupPoint!;
    final dropoff = _dropoffPoint!;
    final selectedPoint = _collectionPoints
        .where((point) => point['id'] == _selectedCollectionPointId)
        .toList();
    final cp = selectedPoint.isEmpty ? null : selectedPoint.first;
    final cpLatLng = cp == null
        ? null
        : LatLng((cp['latitude'] as num).toDouble(), (cp['longitude'] as num).toDouble());

    final routePoints = [pickup, ?cpLatLng, dropoff];

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(18),
          child: SizedBox(
            height: 190,
            child: StanMap(
              initialCenter: pickup,
              interactive: false,
              fitPoints: routePoints,
              polyline: routePoints,
              markers: [
                StanMarker(id: 'pickup', point: pickup, kind: StanMarkerKind.pickup),
                if (cpLatLng != null)
                  StanMarker(id: 'cp', point: cpLatLng, kind: StanMarkerKind.collectionPoint),
                StanMarker(id: 'dropoff', point: dropoff, kind: StanMarkerKind.dropoff),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(18),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _reviewRow(Icons.trip_origin, 'Pickup', _pickupAddressController.text.trim()),
              _reviewRow(Icons.location_on_outlined, 'Dropoff', _dropoffAddressController.text.trim()),
              if (cp != null) _reviewRow(Icons.hub_outlined, 'Via', cp['name'] as String),
              _reviewRow(
                Icons.person_outline,
                'Receiver',
                '${_receiverNameController.text.trim()} · ${_receiverPhoneController.text.trim()}',
              ),
              _reviewRow(Icons.inventory_2_outlined, 'Package', packageSizeLabel(_packageSize)),
              _reviewRow(
                Icons.payments_outlined,
                'Payment',
                _payer == 'sender' ? 'You pay now (M-Pesa)' : 'Receiver pays on delivery',
              ),
              if (_notesController.text.trim().isNotEmpty)
                _reviewRow(Icons.sticky_note_2_outlined, 'Notes', _notesController.text.trim()),
            ],
          ),
        ),
        const SizedBox(height: 14),
        Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [stanDark, stanPanel],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(18),
          ),
          child: _isQuoting
              ? const Center(
                  child: SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                  ),
                )
              : _quote == null
                  ? Row(
                      children: [
                        const Expanded(
                          child: Text(
                            'Could not price the trip.',
                            style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
                          ),
                        ),
                        TextButton(
                          onPressed: _fetchQuote,
                          child: const Text(
                            'Retry',
                            style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900),
                          ),
                        ),
                      ],
                    )
                  : Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '${_quote!['distanceKm']} km trip',
                                style: const TextStyle(
                                  color: stanMuted,
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                formatKsh((_quote!['fare'] as num?) ?? 0),
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 26,
                                  fontWeight: FontWeight.w900,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                'Base ${formatKsh((_quote!['baseFare'] as num?) ?? 0)} + '
                                '${formatKsh((_quote!['perKm'] as num?) ?? 0)}/km',
                                style: const TextStyle(
                                  color: stanMuted,
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const Icon(Icons.receipt_long, color: Colors.white38, size: 40),
                      ],
                    ),
        ),
        if (_errorMessage != null) ...[
          const SizedBox(height: 12),
          Text(
            _errorMessage!,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Color(0xFFDC2626), fontWeight: FontWeight.w700),
          ),
        ],
        const SizedBox(height: 18),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: stanDark,
            minimumSize: const Size.fromHeight(54),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          ),
          onPressed: _isBooking || _quote == null ? null : _book,
          child: Text(
            _isBooking ? 'Booking…' : 'Confirm booking',
            style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 15),
          ),
        ),
      ],
    );
  }

  Widget _successStep() {
    final delivery = _bookedDelivery;
    final code = delivery?['trackingCode'] as String? ?? '—';

    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              width: 84,
              height: 84,
              decoration: BoxDecoration(
                color: const Color(0xFF16A34A).withValues(alpha: 0.14),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.check_rounded, color: Color(0xFF16A34A), size: 48),
            ),
          ),
          const SizedBox(height: 20),
          const Text(
            'Booking confirmed',
            textAlign: TextAlign.center,
            style: TextStyle(color: stanDark, fontSize: 23, fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.symmetric(vertical: 14),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              children: [
                const Text(
                  'TRACKING CODE',
                  style: TextStyle(
                    color: Color(0xFF94A3B8),
                    fontSize: 11,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 1,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  code,
                  style: const TextStyle(
                    color: stanDark,
                    fontSize: 22,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 1.5,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Text(
            _payer == 'sender'
                ? 'Dispatch will assign a rider shortly. You can pay from the parcel screen any time.'
                : 'Dispatch will assign a rider shortly. The receiver pays on delivery and holds the handover PIN in their Stan app.',
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Color(0xFF60727A),
              fontWeight: FontWeight.w600,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 26),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: stanDark,
              minimumSize: const Size.fromHeight(52),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            ),
            onPressed: () =>
                Navigator.of(context).pop({'delivery': _bookedDelivery, 'track': true}),
            child: const Text(
              'Track this parcel',
              style: TextStyle(fontWeight: FontWeight.w900, fontSize: 15),
            ),
          ),
          const SizedBox(height: 10),
          OutlinedButton(
            style: OutlinedButton.styleFrom(
              foregroundColor: stanDark,
              minimumSize: const Size.fromHeight(50),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            ),
            onPressed: () =>
                Navigator.of(context).pop({'delivery': _bookedDelivery, 'track': false}),
            child: const Text('Done', style: TextStyle(fontWeight: FontWeight.w800)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final body = switch (_step) {
      0 => _mapPicker(
          controller: _pickupMapController,
          initialCenter: _pickupInitial,
          pinColor: const Color(0xFF16A34A),
          addressController: _pickupAddressController,
          addressLabel: 'Pickup address (building, street…)',
          confirmLabel: 'Confirm pickup',
          onConfirm: _confirmPickup,
          showLocateMe: true,
        ),
      1 => _mapPicker(
          controller: _dropoffMapController,
          initialCenter: _pickupPoint ?? _pickupInitial,
          pinColor: const Color(0xFFDC2626),
          addressController: _dropoffAddressController,
          addressLabel: 'Dropoff address (building, street…)',
          confirmLabel: 'Confirm dropoff',
          onConfirm: _confirmDropoff,
        ),
      2 => _detailsStep(),
      3 => _reviewStep(),
      _ => _successStep(),
    };

    return Scaffold(
      backgroundColor: stanSurface,
      appBar: _step == 4
          ? null
          : AppBar(
              backgroundColor: stanDark,
              foregroundColor: Colors.white,
              elevation: 0,
              leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: _goBack),
              toolbarHeight: 116,
              title: _stepHeader(),
              titleSpacing: 0,
              centerTitle: false,
            ),
      body: SafeArea(top: _step == 4, child: body),
    );
  }
}
