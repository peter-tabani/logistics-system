// Shared map widget for the customer experience. Uses the Google Maps SDK
// (google_maps_flutter) when a Maps API key is compiled in, and falls back to
// OpenStreetMap (flutter_map) otherwise — same API either way, so callers
// don't care which is active. Gives an Uber/Bolt-style vector map on Google.

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart' as fmap;
import 'package:google_maps_flutter/google_maps_flutter.dart' as gmaps;
import 'package:latlong2/latlong.dart';

import 'main.dart';

enum StanMarkerKind { pickup, dropoff, collectionPoint, rider }

class StanMarker {
  const StanMarker({required this.id, required this.point, required this.kind});

  final String id;
  final LatLng point;
  final StanMarkerKind kind;

  double get _googleHue => switch (kind) {
        StanMarkerKind.pickup => gmaps.BitmapDescriptor.hueGreen,
        StanMarkerKind.dropoff => gmaps.BitmapDescriptor.hueRed,
        StanMarkerKind.collectionPoint => gmaps.BitmapDescriptor.hueViolet,
        StanMarkerKind.rider => gmaps.BitmapDescriptor.hueAzure,
      };

  Widget get _osmChild => switch (kind) {
        StanMarkerKind.pickup => const Icon(Icons.trip_origin, color: Color(0xFF16A34A), size: 26),
        StanMarkerKind.dropoff => const Icon(Icons.location_on, color: Color(0xFFDC2626), size: 32),
        StanMarkerKind.collectionPoint => const Icon(Icons.hub, color: Color(0xFF6D28D9), size: 24),
        StanMarkerKind.rider => Container(
            decoration: BoxDecoration(
              color: stanDark,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 3),
            ),
            child: const Icon(Icons.local_shipping, color: Colors.white, size: 20),
          ),
      };
}

/// Imperative handle to move/fit the map from the parent.
class StanMapController {
  _StanMapState? _state;
  void _bind(_StanMapState state) => _state = state;
  void _unbind(_StanMapState state) {
    if (_state == state) _state = null;
  }

  /// Center of the current viewport — used by pin pickers.
  LatLng? get center => _state?._center;

  Future<void> moveTo(LatLng target, {double zoom = 15}) async =>
      _state?._moveTo(target, zoom);

  Future<void> fitBounds(
    List<LatLng> points, {
    EdgeInsets padding = const EdgeInsets.all(60),
  }) async =>
      _state?._fitBounds(points, padding);
}

class StanMap extends StatefulWidget {
  const StanMap({
    super.key,
    required this.initialCenter,
    this.initialZoom = 14,
    this.controller,
    this.markers = const [],
    this.polyline,
    this.polylineColor = const Color(0xFF0E2140),
    this.myLocation = false,
    this.interactive = true,
    this.lite = false,
    this.fitPoints,
    this.onCenterChanged,
    this.onTap,
  });

  final LatLng initialCenter;
  final double initialZoom;
  final StanMapController? controller;
  final List<StanMarker> markers;
  final List<LatLng>? polyline;
  final Color polylineColor;
  final bool myLocation;
  final bool interactive;

  /// Lite mode renders a lightweight static Google map — ideal for the small
  /// embedded map previews inside cards (fast, low resource, no live GL).
  final bool lite;

  /// When set (2+ points), the camera fits these on load instead of using
  /// [initialCenter]/[initialZoom]. Used by the route preview + tracking maps.
  final List<LatLng>? fitPoints;
  final ValueChanged<LatLng>? onCenterChanged;
  final VoidCallback? onTap;

  @override
  State<StanMap> createState() => _StanMapState();
}

class _StanMapState extends State<StanMap> {
  gmaps.GoogleMapController? _googleController;
  final fmap.MapController _osmController = fmap.MapController();
  late LatLng _center = widget.initialCenter;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    widget.controller?._bind(this);
    // OSM (flutter_map) renders on the first frame; reveal it right away.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!useGoogleMaps && mounted) setState(() => _ready = true);
    });
  }

  @override
  void didUpdateWidget(StanMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller?._unbind(this);
      widget.controller?._bind(this);
    }
  }

  @override
  void dispose() {
    widget.controller?._unbind(this);
    _googleController?.dispose();
    super.dispose();
  }

  Future<void> _moveTo(LatLng target, double zoom) async {
    _center = target;
    if (useGoogleMaps) {
      await _googleController?.animateCamera(
        gmaps.CameraUpdate.newLatLngZoom(
          gmaps.LatLng(target.latitude, target.longitude),
          zoom,
        ),
      );
    } else {
      _osmController.move(target, zoom);
    }
  }

  Future<void> _fitBounds(List<LatLng> points, EdgeInsets padding) async {
    if (points.length < 2) {
      if (points.length == 1) await _moveTo(points.first, 15);
      return;
    }

    if (useGoogleMaps) {
      var minLat = points.first.latitude, maxLat = points.first.latitude;
      var minLng = points.first.longitude, maxLng = points.first.longitude;
      for (final p in points) {
        minLat = p.latitude < minLat ? p.latitude : minLat;
        maxLat = p.latitude > maxLat ? p.latitude : maxLat;
        minLng = p.longitude < minLng ? p.longitude : minLng;
        maxLng = p.longitude > maxLng ? p.longitude : maxLng;
      }
      final bounds = gmaps.LatLngBounds(
        southwest: gmaps.LatLng(minLat, minLng),
        northeast: gmaps.LatLng(maxLat, maxLng),
      );
      final pad = padding.left < 40 ? 40.0 : padding.left;
      await _googleController?.animateCamera(gmaps.CameraUpdate.newLatLngBounds(bounds, pad));
    } else {
      _osmController.fitCamera(
        fmap.CameraFit.bounds(
          bounds: fmap.LatLngBounds.fromPoints(points),
          padding: padding,
        ),
      );
    }
  }

  void _updateCenter(LatLng value) {
    _center = value;
    widget.onCenterChanged?.call(value);
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(child: useGoogleMaps ? _buildGoogle() : _buildOsm()),
        // Soft loading veil until the map's first frame — hides the blank
        // tile flash so the screen feels instant.
        Positioned.fill(
          child: IgnorePointer(
            ignoring: _ready,
            child: AnimatedOpacity(
              opacity: _ready ? 0 : 1,
              duration: const Duration(milliseconds: 400),
              child: Container(
                color: stanSurface,
                alignment: Alignment.center,
                child: const SizedBox(
                  width: 28,
                  height: 28,
                  child: CircularProgressIndicator(strokeWidth: 2.5, color: stanDark),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildGoogle() {
    final markers = <gmaps.Marker>{
      for (final m in widget.markers)
        gmaps.Marker(
          markerId: gmaps.MarkerId(m.id),
          position: gmaps.LatLng(m.point.latitude, m.point.longitude),
          icon: gmaps.BitmapDescriptor.defaultMarkerWithHue(m._googleHue),
        ),
    };

    final polylines = <gmaps.Polyline>{};
    final line = widget.polyline;
    if (line != null && line.length >= 2) {
      polylines.add(
        gmaps.Polyline(
          polylineId: const gmaps.PolylineId('route'),
          points: [for (final p in line) gmaps.LatLng(p.latitude, p.longitude)],
          color: widget.polylineColor,
          width: 5,
        ),
      );
    }

    return gmaps.GoogleMap(
      initialCameraPosition: gmaps.CameraPosition(
        target: gmaps.LatLng(widget.initialCenter.latitude, widget.initialCenter.longitude),
        zoom: widget.initialZoom,
      ),
      markers: markers,
      polylines: polylines,
      myLocationEnabled: widget.myLocation,
      myLocationButtonEnabled: false,
      zoomControlsEnabled: false,
      mapToolbarEnabled: false,
      compassEnabled: false,
      liteModeEnabled: widget.lite,
      rotateGesturesEnabled: widget.interactive,
      scrollGesturesEnabled: widget.interactive,
      zoomGesturesEnabled: widget.interactive,
      tiltGesturesEnabled: false,
      onMapCreated: (controller) {
        _googleController = controller;
        if (mounted) setState(() => _ready = true);
        final fit = widget.fitPoints;
        if (fit != null && fit.length >= 2) {
          // The map needs a frame to size itself before a bounds fit sticks.
          Future.delayed(const Duration(milliseconds: 300), () {
            _fitBounds(fit, const EdgeInsets.all(60));
          });
        }
      },
      onCameraMove: (position) => _updateCenter(
        LatLng(position.target.latitude, position.target.longitude),
      ),
      onTap: widget.onTap == null ? null : (_) => widget.onTap!(),
    );
  }

  Widget _buildOsm() {
    final line = widget.polyline;

    return fmap.FlutterMap(
      mapController: _osmController,
      options: fmap.MapOptions(
        initialCenter: widget.initialCenter,
        initialZoom: widget.initialZoom,
        interactionOptions: fmap.InteractionOptions(
          flags: widget.interactive ? fmap.InteractiveFlag.all : fmap.InteractiveFlag.none,
        ),
        onTap: widget.onTap == null ? null : (_, _) => widget.onTap!(),
        onPositionChanged: (camera, _) => _updateCenter(camera.center),
      ),
      children: [
        fmap.TileLayer(
          urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
          userAgentPackageName: 'com.example.driver_app',
        ),
        if (line != null && line.length >= 2)
          fmap.PolylineLayer(
            polylines: [
              fmap.Polyline(points: line, color: widget.polylineColor, strokeWidth: 4.5),
            ],
          ),
        if (widget.markers.isNotEmpty)
          fmap.MarkerLayer(
            markers: [
              for (final m in widget.markers)
                fmap.Marker(
                  point: m.point,
                  width: 40,
                  height: 40,
                  child: m._osmChild,
                ),
            ],
          ),
      ],
    );
  }
}
