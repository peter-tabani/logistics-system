// Full-screen live map for the rider: their own location (live blue dot) plus
// the pickup/dropoff of any active delivery and the road-following route.
// Opened from the always-on map preview on the home screen.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import 'main.dart';
import 'stan_map.dart';
import 'stan_routes.dart';

class DriverLiveMapScreen extends StatefulWidget {
  const DriverLiveMapScreen({super.key, required this.deliveries});

  /// The rider's current deliveries (used to draw pickup/dropoff + route).
  final List<Map<String, dynamic>> deliveries;

  @override
  State<DriverLiveMapScreen> createState() => _DriverLiveMapScreenState();
}

class _DriverLiveMapScreenState extends State<DriverLiveMapScreen> {
  final StanMapController _controller = StanMapController();
  LatLng _center = defaultMapCenter;
  bool _hasLocation = false;
  List<LatLng>? _route;

  @override
  void initState() {
    super.initState();
    _locate();
    _loadRoute();
  }

  Map<String, dynamic>? get _activeDelivery {
    for (final d in widget.deliveries) {
      if (d['status'] != 'delivered' && d['status'] != 'cancelled') return d;
    }
    return null;
  }

  LatLng? _point(Map<String, dynamic>? d, String latKey, String lngKey) {
    if (d == null) return null;
    final lat = d[latKey];
    final lng = d[lngKey];
    if (lat is! num || lng is! num) return null;
    return LatLng(lat.toDouble(), lng.toDouble());
  }

  Future<void> _locate() async {
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
        _center = point;
        _hasLocation = true;
      });
      _fitOrCenter(point);
    } catch (_) {
      // Falls back to the city center; the live dot appears once GPS is ready.
    }
  }

  Future<void> _loadRoute() async {
    final delivery = _activeDelivery;
    final pickup = _point(delivery, 'pickupLatitude', 'pickupLongitude');
    final dropoff = _point(delivery, 'dropoffLatitude', 'dropoffLongitude');
    if (pickup == null || dropoff == null) return;
    final route = await fetchRoadRoute([pickup, dropoff]);
    if (!mounted || route == null) return;
    setState(() => _route = route);
  }

  void _fitOrCenter(LatLng driver) {
    final delivery = _activeDelivery;
    final pickup = _point(delivery, 'pickupLatitude', 'pickupLongitude');
    final dropoff = _point(delivery, 'dropoffLatitude', 'dropoffLongitude');
    final points = <LatLng>[driver, ?pickup, ?dropoff];
    if (points.length >= 2) {
      _controller.fitBounds(points, padding: const EdgeInsets.fromLTRB(60, 140, 60, 160));
    } else {
      _controller.moveTo(driver, zoom: 15.5);
    }
  }

  @override
  Widget build(BuildContext context) {
    final delivery = _activeDelivery;
    final pickup = _point(delivery, 'pickupLatitude', 'pickupLongitude');
    final dropoff = _point(delivery, 'dropoffLatitude', 'dropoffLongitude');
    final straight = <LatLng>[?pickup, ?dropoff];

    return Scaffold(
      backgroundColor: stanSurface,
      body: Stack(
        children: [
          Positioned.fill(
            child: StanMap(
              controller: _controller,
              initialCenter: _center,
              initialZoom: _hasLocation ? 15.5 : 12,
              myLocation: _hasLocation,
              polyline: _route ?? (straight.length >= 2 ? straight : null),
              markers: [
                if (pickup != null)
                  StanMarker(id: 'pickup', point: pickup, kind: StanMarkerKind.pickup),
                if (dropoff != null)
                  StanMarker(id: 'dropoff', point: dropoff, kind: StanMarkerKind.dropoff),
              ],
            ),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Container(
              padding: EdgeInsets.fromLTRB(
                12, MediaQuery.of(context).padding.top + 8, 12, 14,
              ),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [stanDark.withValues(alpha: 0.9), stanDark.withValues(alpha: 0.0)],
                ),
              ),
              child: Row(
                children: [
                  _circleButton(Icons.arrow_back, () => Navigator.of(context).pop()),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text(
                      'Live map',
                      style: TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w900),
                    ),
                  ),
                  _circleButton(Icons.my_location, () {
                    if (_hasLocation) {
                      _fitOrCenter(_center);
                    } else {
                      _locate();
                    }
                  }),
                ],
              ),
            ),
          ),
          if (delivery != null)
            Positioned(
              left: 16,
              right: 16,
              bottom: 24,
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(18),
                  boxShadow: const [
                    BoxShadow(color: Color(0x22000000), blurRadius: 16, offset: Offset(0, 6)),
                  ],
                ),
                child: Row(
                  children: [
                    const Icon(Icons.local_shipping, color: stanDark),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            delivery['trackingCode'] as String? ?? 'Active delivery',
                            style: const TextStyle(
                              color: stanDark,
                              fontWeight: FontWeight.w900,
                              fontSize: 14.5,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '${delivery['pickupAddress'] ?? ''} → ${delivery['dropoffAddress'] ?? ''}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Color(0xFF64748B),
                              fontWeight: FontWeight.w600,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _circleButton(IconData icon, VoidCallback onTap) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.16),
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
