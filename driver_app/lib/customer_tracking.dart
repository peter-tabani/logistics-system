// Full-screen live parcel tracking for customers: map with the route and
// the rider's live position (polled), status timeline, rider card with a
// call button, handover PIN for receivers, payment (pay-now + Paybill hint),
// and cancellation while the booking is still unassigned.

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';

import 'customer_common.dart';
import 'main.dart';
import 'stan_map.dart';
import 'stan_routes.dart';

class CustomerParcelScreen extends StatefulWidget {
  const CustomerParcelScreen({
    super.key,
    required this.token,
    required this.phone,
    required this.deliveryId,
  });

  final String token;
  final String phone;
  final int deliveryId;

  @override
  State<CustomerParcelScreen> createState() => _CustomerParcelScreenState();
}

class _CustomerParcelScreenState extends State<CustomerParcelScreen> {
  final StanMapController _mapController = StanMapController();

  Map<String, dynamic>? _delivery;
  Map<String, dynamic>? _riderLocation;
  Timer? _pollTimer;
  bool _didFitCamera = false;
  bool _isBusy = false;
  String? _errorMessage;

  // Road-following route (pickup -> [collection point] -> dropoff), fetched
  // once from Google Directions. Null until it arrives (straight line shown).
  List<LatLng>? _roadRoute;
  bool _fetchedRoute = false;

  static const _averageSpeedKmh = 22.0;

  @override
  void initState() {
    super.initState();
    _load();
    _pollTimer = Timer.periodic(const Duration(seconds: 12), (_) => _load(silent: true));
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  bool get _isFinished {
    final status = _delivery?['status'] as String?;
    return status == 'delivered' || status == 'cancelled';
  }

  Future<void> _load({bool silent = false}) async {
    try {
      final response = await http
          .get(
            Uri.parse('$apiBaseUrl/customer/deliveries/${widget.deliveryId}'),
            headers: customerAuthHeaders(widget.token),
          )
          .timeout(apiRequestTimeout);

      if (!mounted) return;

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        setState(() {
          _delivery = data['delivery'] as Map<String, dynamic>;
          _riderLocation = data['riderLocation'] as Map<String, dynamic>?;
          _errorMessage = null;
        });
        if (!_didFitCamera) {
          _didFitCamera = true;
          WidgetsBinding.instance.addPostFrameCallback((_) => _fitCamera());
        }
        unawaited(_ensureRoute());
        if (_isFinished) _pollTimer?.cancel();
      } else if (!silent) {
        setState(() => _errorMessage = 'Could not load this parcel.');
      }
    } catch (_) {
      if (!silent && mounted) {
        setState(() => _errorMessage = 'Could not connect. Pull down to retry.');
      }
    }
  }

  // Fetch the road-following route once the parcel's coordinates are known.
  Future<void> _ensureRoute() async {
    if (_fetchedRoute) return;
    final pickup = _pickupPoint;
    final dropoff = _dropoffPoint;
    if (pickup == null || dropoff == null) return;
    _fetchedRoute = true;
    final route = await fetchRoadRoute([pickup, ?_collectionPointLatLng, dropoff]);
    if (!mounted || route == null) return;
    setState(() => _roadRoute = route);
  }

  LatLng? _point(String latKey, String lngKey) {
    final lat = _delivery?[latKey];
    final lng = _delivery?[lngKey];
    if (lat is! num || lng is! num) return null;
    return LatLng(lat.toDouble(), lng.toDouble());
  }

  LatLng? get _pickupPoint => _point('pickupLatitude', 'pickupLongitude');
  LatLng? get _dropoffPoint => _point('dropoffLatitude', 'dropoffLongitude');

  LatLng? get _collectionPointLatLng {
    final cp = _delivery?['collectionPoint'];
    if (cp is! Map<String, dynamic>) return null;
    final lat = cp['latitude'];
    final lng = cp['longitude'];
    if (lat is! num || lng is! num) return null;
    return LatLng(lat.toDouble(), lng.toDouble());
  }

  LatLng? get _riderPoint {
    final lat = _riderLocation?['latitude'];
    final lng = _riderLocation?['longitude'];
    if (lat is! num || lng is! num) return null;
    return LatLng(lat.toDouble(), lng.toDouble());
  }

  double _distanceKm(LatLng a, LatLng b) {
    const earthRadiusKm = 6371.0;
    final dLat = (b.latitude - a.latitude) * pi / 180;
    final dLng = (b.longitude - a.longitude) * pi / 180;
    final lat1 = a.latitude * pi / 180;
    final lat2 = b.latitude * pi / 180;
    final h = sin(dLat / 2) * sin(dLat / 2) +
        cos(lat1) * cos(lat2) * sin(dLng / 2) * sin(dLng / 2);
    return earthRadiusKm * 2 * atan2(sqrt(h), sqrt(1 - h));
  }

  // Where the rider is heading for the customer's parcel right now.
  LatLng? get _riderTarget {
    final delivery = _delivery;
    if (delivery == null) return null;
    final status = delivery['status'] as String?;
    if (status == 'delivered' || status == 'cancelled' || status == 'pending') return null;

    final leg = (delivery['currentLeg'] as num?)?.toInt() ?? 1;
    final via = delivery['viaCollectionPoint'] == true;

    if (status == 'assigned') return leg == 2 ? _collectionPointLatLng : _pickupPoint;
    if (via && leg == 1) return _collectionPointLatLng;
    return _dropoffPoint;
  }

  String? get _etaLabel {
    final rider = _riderPoint;
    final target = _riderTarget;
    if (rider == null || target == null) return null;
    final km = _distanceKm(rider, target);
    final minutes = max(1, (km / _averageSpeedKmh * 60).round());
    return '~$minutes min';
  }

  void _fitCamera() {
    final points = [
      ?_pickupPoint,
      ?_dropoffPoint,
      ?_collectionPointLatLng,
      ?_riderPoint,
    ];
    if (points.length < 2) return;
    _mapController.fitBounds(
      points,
      padding: const EdgeInsets.fromLTRB(48, 110, 48, 330),
    );
  }

  Future<void> _callRider() async {
    final phone = _delivery?['riderPhone'] as String?;
    if (phone == null || phone.isEmpty) return;
    final uri = Uri.parse('tel:$phone');
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
    }
  }

  Future<void> _payNow() async {
    final delivery = _delivery;
    if (delivery == null) return;

    setState(() => _isBusy = true);
    final paid = await customerPayNow(
      context,
      token: widget.token,
      phone: widget.phone,
      delivery: delivery,
    );
    if (!mounted) return;
    setState(() => _isBusy = false);

    if (paid) {
      await _load(silent: true);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Payment received. Thank you!')),
        );
      }
    }
  }

  Future<void> _cancelBooking() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Cancel this booking?'),
        content: const Text(
          'The booking will be cancelled. This is only possible while no rider is assigned.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Keep it'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFB91C1C)),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Cancel booking'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    setState(() => _isBusy = true);
    try {
      final response = await http
          .post(
            Uri.parse('$apiBaseUrl/customer/deliveries/${widget.deliveryId}/cancel'),
            headers: customerAuthHeaders(widget.token),
          )
          .timeout(apiRequestTimeout);
      final data = jsonDecode(response.body) as Map<String, dynamic>;

      if (!mounted) return;

      if (response.statusCode == 200) {
        setState(() => _delivery = data['delivery'] as Map<String, dynamic>? ?? _delivery);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Booking cancelled.')),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(data['message'] as String? ?? 'Could not cancel.')),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not reach the server.')),
        );
      }
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  /* --------------------------------- UI ---------------------------------- */

  Widget _map() {
    final pickup = _pickupPoint;
    final dropoff = _dropoffPoint;
    final cp = _collectionPointLatLng;
    final rider = _riderPoint;

    final routePoints = [?pickup, ?cp, ?dropoff];

    return StanMap(
      controller: _mapController,
      initialCenter: pickup ?? rider ?? defaultMapCenter,
      initialZoom: 13,
      fitPoints: routePoints.length >= 2 ? routePoints : null,
      dark: true,
      polyline: _roadRoute ?? (routePoints.length >= 2 ? routePoints : null),
      polylineColor: const Color(0xFF34D399),
      markers: [
        if (pickup != null)
          StanMarker(id: 'pickup', point: pickup, kind: StanMarkerKind.pickup),
        if (cp != null)
          StanMarker(id: 'cp', point: cp, kind: StanMarkerKind.collectionPoint),
        if (dropoff != null)
          StanMarker(id: 'dropoff', point: dropoff, kind: StanMarkerKind.dropoff),
        if (rider != null)
          StanMarker(id: 'rider', point: rider, kind: StanMarkerKind.rider),
      ],
    );
  }

  Widget _sheetCard({required Widget child, EdgeInsetsGeometry? padding}) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: padding ?? const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        boxShadow: const [
          BoxShadow(color: Color(0x11000000), blurRadius: 12, offset: Offset(0, 4)),
        ],
      ),
      child: child,
    );
  }

  Widget _riderCard(Map<String, dynamic> delivery) {
    final riderName = delivery['riderName'] as String?;
    if (riderName == null) return const SizedBox.shrink();

    final plate = delivery['riderPlate'] as String?;
    final canCall = (delivery['riderPhone'] as String?)?.isNotEmpty == true;

    return _sheetCard(
      child: Row(
        children: [
          CircleAvatar(
            radius: 24,
            backgroundColor: stanDark,
            child: Text(
              riderName[0].toUpperCase(),
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w900,
                fontSize: 18,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  riderName,
                  style: const TextStyle(
                    color: stanDark,
                    fontWeight: FontWeight.w900,
                    fontSize: 15.5,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  plate == null || plate.isEmpty ? 'Your Stan rider' : 'Rider · $plate',
                  style: const TextStyle(
                    color: Color(0xFF64748B),
                    fontWeight: FontWeight.w700,
                    fontSize: 12.5,
                  ),
                ),
              ],
            ),
          ),
          if (_etaLabel != null)
            Container(
              margin: const EdgeInsets.only(right: 8),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: const Color(0xFFDCFCE7),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                _etaLabel!,
                style: const TextStyle(
                  color: Color(0xFF166534),
                  fontWeight: FontWeight.w900,
                  fontSize: 12.5,
                ),
              ),
            ),
          if (canCall)
            Container(
              decoration: const BoxDecoration(color: stanDark, shape: BoxShape.circle),
              child: IconButton(
                onPressed: _callRider,
                icon: const Icon(Icons.call, color: Colors.white, size: 20),
                tooltip: 'Call rider',
              ),
            ),
        ],
      ),
    );
  }

  Widget _pinCard(Map<String, dynamic> delivery) {
    final pin = delivery['deliveryPin'] as String?;
    if (delivery['role'] != 'receiver' || pin == null) return const SizedBox.shrink();

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [stanDark, stanPanel],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        children: [
          const Text(
            'HANDOVER PIN — read this to the rider',
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
              fontSize: 32,
              fontWeight: FontWeight.w900,
              letterSpacing: 12,
            ),
          ),
        ],
      ),
    );
  }

  Widget _paymentCard(Map<String, dynamic> delivery) {
    final fare = (delivery['fareAmount'] as num?) ?? 0;
    if (fare <= 0) return const SizedBox.shrink();

    final paid = delivery['paymentStatus'] == 'paid';
    final canPayNow = delivery['role'] == 'sender' &&
        delivery['payer'] == 'sender' &&
        !paid &&
        delivery['status'] != 'cancelled';

    return _sheetCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    delivery['payer'] == 'sender'
                        ? 'Fare · sender pays'
                        : 'Fare · receiver pays on delivery',
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
                      fontSize: 20,
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
                  paid
                      ? 'PAID · ${(delivery['paymentMethod'] as String? ?? '').toUpperCase()}'
                      : 'UNPAID',
                  style: TextStyle(
                    color: paid ? const Color(0xFF166534) : const Color(0xFF92400E),
                    fontSize: 10.5,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
            ],
          ),
          if (canPayNow) ...[
            const SizedBox(height: 12),
            FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF1AAE4F),
                padding: const EdgeInsets.symmetric(vertical: 13),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              onPressed: _isBusy ? null : _payNow,
              icon: const Icon(Icons.smartphone, size: 18),
              label: const Text(
                'Pay now with M-Pesa',
                style: TextStyle(fontWeight: FontWeight.w900),
              ),
            ),
            if (delivery['trackingCode'] != null) ...[
              const SizedBox(height: 8),
              Text(
                'Or pay via Paybill using account ${delivery['trackingCode']} — it matches automatically.',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Color(0xFF94A3B8),
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }

  Widget _timelineCard(Map<String, dynamic> delivery) {
    if (delivery['status'] == 'cancelled') {
      return _sheetCard(
        child: Row(
          children: [
            const Icon(Icons.cancel_outlined, color: Color(0xFF991B1B)),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'This booking was cancelled${delivery['role'] == 'sender' ? ' by you' : ''}.',
                style: const TextStyle(
                  color: Color(0xFF991B1B),
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ],
        ),
      );
    }

    final steps = customerTimeline(delivery);

    return _sheetCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Progress',
            style: TextStyle(color: stanDark, fontWeight: FontWeight.w900, fontSize: 15),
          ),
          const SizedBox(height: 10),
          for (var i = 0; i < steps.length; i++)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Column(
                  children: [
                    Icon(
                      steps[i].done ? Icons.check_circle : Icons.radio_button_unchecked,
                      size: 20,
                      color: steps[i].done ? const Color(0xFF16A34A) : const Color(0xFFCBD5E1),
                    ),
                    if (i < steps.length - 1)
                      Container(
                        width: 2,
                        height: 18,
                        color: steps[i + 1].done
                            ? const Color(0xFF16A34A)
                            : const Color(0xFFE2E8F0),
                      ),
                  ],
                ),
                const SizedBox(width: 10),
                Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: Text(
                    steps[i].label,
                    style: TextStyle(
                      color: steps[i].done ? stanDark : const Color(0xFF94A3B8),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _detailsCard(Map<String, dynamic> delivery) {
    Widget row(IconData icon, String label, String? value) {
      if (value == null || value.isEmpty) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 18, color: const Color(0xFF64748B)),
            const SizedBox(width: 10),
            SizedBox(
              width: 84,
              child: Text(
                label,
                style: const TextStyle(
                  color: Color(0xFF64748B),
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            Expanded(
              child: Text(
                value,
                style: const TextStyle(
                  color: stanDark,
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  height: 1.3,
                ),
              ),
            ),
          ],
        ),
      );
    }

    final cp = delivery['collectionPoint'] as Map<String, dynamic>?;

    return _sheetCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          row(Icons.trip_origin, 'Pickup', delivery['pickupAddress'] as String?),
          row(Icons.location_on_outlined, 'Dropoff', delivery['dropoffAddress'] as String?),
          if (cp != null)
            row(Icons.hub_outlined, 'Via', '${cp['name']} · leg ${delivery['currentLeg']} of 2'),
          row(
            Icons.person_outline,
            delivery['role'] == 'sender' ? 'Receiver' : 'Sender',
            delivery['role'] == 'sender'
                ? '${delivery['receiverName'] ?? ''} · ${delivery['receiverPhone'] ?? ''}'
                : delivery['senderName'] as String?,
          ),
          row(Icons.inventory_2_outlined, 'Package',
              packageSizeLabel(delivery['packageSize'] as String?)),
          row(Icons.sticky_note_2_outlined, 'Notes', delivery['notes'] as String?),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final delivery = _delivery;

    return Scaffold(
      backgroundColor: stanSurface,
      body: delivery == null
          ? Center(
              child: _errorMessage == null
                  ? const CircularProgressIndicator()
                  : Text(
                      _errorMessage!,
                      style: const TextStyle(color: stanDark, fontWeight: FontWeight.w700),
                    ),
            )
          : Stack(
              children: [
                Positioned.fill(child: _map()),
                // Top chrome over the map.
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: Container(
                    padding: EdgeInsets.fromLTRB(
                      12,
                      MediaQuery.of(context).padding.top + 8,
                      12,
                      14,
                    ),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          stanDark.withValues(alpha: 0.9),
                          stanDark.withValues(alpha: 0.0),
                        ],
                      ),
                    ),
                    child: Row(
                      children: [
                        _roundButton(Icons.arrow_back, () => Navigator.of(context).pop(true)),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            delivery['trackingCode'] as String? ?? 'Parcel',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 17,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ),
                        customerStatusChip(delivery['status'] as String? ?? 'pending'),
                        const SizedBox(width: 8),
                        _roundButton(Icons.my_location, _fitCamera),
                      ],
                    ),
                  ),
                ),
                DraggableScrollableSheet(
                  initialChildSize: 0.42,
                  minChildSize: 0.22,
                  maxChildSize: 0.88,
                  builder: (sheetContext, scrollController) {
                    return Container(
                      decoration: const BoxDecoration(
                        color: stanSurface,
                        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
                        boxShadow: [
                          BoxShadow(color: Color(0x33000000), blurRadius: 18, offset: Offset(0, -4)),
                        ],
                      ),
                      child: ListView(
                        controller: scrollController,
                        padding: const EdgeInsets.fromLTRB(18, 10, 18, 30),
                        children: [
                          Center(
                            child: Container(
                              width: 44,
                              height: 5,
                              margin: const EdgeInsets.only(bottom: 14),
                              decoration: BoxDecoration(
                                color: const Color(0xFFCBD5E1),
                                borderRadius: BorderRadius.circular(999),
                              ),
                            ),
                          ),
                          _riderCard(delivery),
                          _pinCard(delivery),
                          _timelineCard(delivery),
                          _paymentCard(delivery),
                          _detailsCard(delivery),
                          if (delivery['role'] == 'sender' &&
                              delivery['status'] == 'pending') ...[
                            OutlinedButton.icon(
                              style: OutlinedButton.styleFrom(
                                foregroundColor: const Color(0xFFB91C1C),
                                side: const BorderSide(color: Color(0xFFFECACA)),
                                minimumSize: const Size.fromHeight(48),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(14),
                                ),
                              ),
                              onPressed: _isBusy ? null : _cancelBooking,
                              icon: const Icon(Icons.cancel_outlined, size: 18),
                              label: const Text(
                                'Cancel booking',
                                style: TextStyle(fontWeight: FontWeight.w900),
                              ),
                            ),
                          ],
                        ],
                      ),
                    );
                  },
                ),
              ],
            ),
    );
  }

  Widget _roundButton(IconData icon, VoidCallback onTap) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.14),
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white24),
      ),
      child: IconButton(
        onPressed: onTap,
        icon: Icon(icon, color: Colors.white, size: 20),
      ),
    );
  }
}
