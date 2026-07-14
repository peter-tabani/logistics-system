// Road-following routes via the Google Directions API. Returns the decoded
// polyline (many points hugging the roads) for a set of waypoints, or null on
// any failure so callers can fall back to a straight line. Uses the same
// compiled-in Maps key as the map tiles.

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import 'main.dart';

/// Fetches a driving route that follows the roads through [waypoints]
/// (in order — e.g. pickup → collection point → dropoff). Tries Google
/// Directions first (best quality, matches Google tiles); if that is
/// unavailable or the key rejects the web-service call, falls back to the
/// keyless OSRM router so a real road path still shows. Returns null only if
/// both fail — callers then draw a straight line.
Future<List<LatLng>?> fetchRoadRoute(List<LatLng> waypoints) async {
  if (waypoints.length < 2) return null;

  if (useGoogleMaps) {
    final google = await _googleDirections(waypoints);
    if (google != null && google.length >= 2) return google;
  }

  return _osrmRoute(waypoints);
}

Future<List<LatLng>?> _googleDirections(List<LatLng> waypoints) async {
  final origin = waypoints.first;
  final destination = waypoints.last;
  final via = waypoints.length > 2
      ? waypoints
          .sublist(1, waypoints.length - 1)
          .map((p) => 'via:${p.latitude},${p.longitude}')
          .join('|')
      : '';

  final url = Uri.parse(
    'https://maps.googleapis.com/maps/api/directions/json'
    '?origin=${origin.latitude},${origin.longitude}'
    '&destination=${destination.latitude},${destination.longitude}'
    '${via.isEmpty ? '' : '&waypoints=$via'}'
    '&mode=driving&key=$googleMapsApiKey',
  );

  try {
    final response = await http.get(url).timeout(apiRequestTimeout);
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final routes = data['routes'] as List<dynamic>?;
    if (routes == null || routes.isEmpty) return null;
    final encoded = routes.first['overview_polyline']?['points'] as String?;
    if (encoded == null || encoded.isEmpty) return null;
    return _decodePolyline(encoded);
  } catch (_) {
    return null;
  }
}

// Keyless OSRM fallback — road geometry on OpenStreetMap roads. Coordinates
// are lng,lat and semicolon-separated; geometry is polyline5 encoded.
Future<List<LatLng>?> _osrmRoute(List<LatLng> waypoints) async {
  final coords =
      waypoints.map((p) => '${p.longitude},${p.latitude}').join(';');
  final url = Uri.parse(
    'https://router.project-osrm.org/route/v1/driving/$coords'
    '?overview=full&geometries=polyline',
  );

  try {
    final response = await http.get(url).timeout(apiRequestTimeout);
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final routes = data['routes'] as List<dynamic>?;
    if (routes == null || routes.isEmpty) return null;
    final encoded = routes.first['geometry'] as String?;
    if (encoded == null || encoded.isEmpty) return null;
    return _decodePolyline(encoded);
  } catch (_) {
    return null;
  }
}

/// Decodes an encoded Google polyline into lat/lng points.
List<LatLng> _decodePolyline(String encoded) {
  final points = <LatLng>[];
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

    points.add(LatLng(lat / 1e5, lng / 1e5));
  }

  return points;
}
