// First-launch permission requests: notifications + precise location only.
// No SMS / call-log permissions — Stan launches the dialer/SMS app instead,
// which needs no permission and avoids Play Store policy flags.

import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'notifications.dart';

const _promptedKey = 'permissions_prompted_v1';

/// Requests notification + precise-location permission once (first launch).
/// Safe to call from multiple entry points; it only prompts the first time.
Future<void> requestStartupPermissions() async {
  final prefs = await SharedPreferences.getInstance();
  if (prefs.getBool(_promptedKey) == true) return;
  await prefs.setBool(_promptedKey, true);

  // Notifications (Android 13+ POST_NOTIFICATIONS dialog).
  try {
    await NotificationService.instance.requestPermission();
  } catch (_) {}

  // Precise (fine) location — the manifest declares ACCESS_FINE_LOCATION.
  try {
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
  } catch (_) {}
}
