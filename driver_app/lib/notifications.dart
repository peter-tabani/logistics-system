// On-device notifications + an in-app notification list for Stan. No backend:
// notifications are raised locally from app events (e.g. a delivery status
// change seen during the existing polling) and mirrored into a persisted
// in-app list shown in the Notifications screen.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'main.dart' show stanDark;
import 'theme_controller.dart';

class AppNotification {
  AppNotification({
    required this.id,
    required this.title,
    required this.body,
    required this.createdAt,
    this.read = false,
  });

  final int id;
  final String title;
  final String body;
  final String createdAt; // ISO-8601
  bool read;

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'body': body,
        'createdAt': createdAt,
        'read': read,
      };

  static AppNotification fromJson(Map<String, dynamic> json) => AppNotification(
        id: json['id'] as int,
        title: json['title'] as String,
        body: json['body'] as String,
        createdAt: json['createdAt'] as String,
        read: json['read'] as bool? ?? false,
      );
}

class NotificationService {
  NotificationService._();
  static final NotificationService instance = NotificationService._();

  static const _storeKey = 'stan_notifications';
  final _plugin = FlutterLocalNotificationsPlugin();

  /// The in-app notification list, newest first. Widgets can listen for the
  /// bell badge + list updates.
  final ValueNotifier<List<AppNotification>> items = ValueNotifier([]);

  bool _initialized = false;

  int get unreadCount => items.value.where((n) => !n.read).length;

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    const android = AndroidInitializationSettings('stan_launcher_icon');
    await _plugin.initialize(
      settings: const InitializationSettings(android: android),
    );
    await _load();
  }

  /// Requests the OS notification permission (Android 13+). Safe to call more
  /// than once; the system only shows the dialog when it needs to.
  Future<void> requestPermission() async {
    final android = _plugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    await android?.requestNotificationsPermission();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_storeKey) ?? [];
    items.value = raw
        .map((s) => AppNotification.fromJson(jsonDecode(s) as Map<String, dynamic>))
        .toList();
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      _storeKey,
      items.value.map((n) => jsonEncode(n.toJson())).toList(),
    );
  }

  /// Adds an entry to the in-app list and raises a system notification.
  Future<void> push({
    required String title,
    required String body,
    DateTime? now,
  }) async {
    final stamp = now ?? DateTime.now();
    final id = stamp.millisecondsSinceEpoch ~/ 1000;

    final next = [
      AppNotification(
        id: id,
        title: title,
        body: body,
        createdAt: stamp.toIso8601String(),
      ),
      ...items.value,
    ];
    // Keep the list bounded.
    items.value = next.take(50).toList();
    await _persist();

    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        'stan_updates',
        'Stan updates',
        channelDescription: 'Delivery and account updates from Stan',
        importance: Importance.high,
        priority: Priority.high,
      ),
    );
    try {
      await _plugin.show(
        id: id % 100000,
        title: title,
        body: body,
        notificationDetails: details,
      );
    } catch (_) {
      // If notifications are disabled the in-app entry still stands.
    }
  }

  final Map<int, String> _lastStatus = {};
  bool _statusPrimed = false;

  /// Compares the latest delivery statuses against what we last saw and raises
  /// a notification for any that changed. The first call only primes the map
  /// (no notifications) so re-opening the app doesn't replay old updates.
  Future<void> checkDeliveryUpdates(List<Map<String, dynamic>> deliveries) async {
    final primed = _statusPrimed;
    _statusPrimed = true;
    for (final d in deliveries) {
      final id = d['id'];
      if (id is! int) continue;
      final status = (d['status'] as String?) ?? '';
      final prev = _lastStatus[id];
      _lastStatus[id] = status;
      if (!primed || prev == null || prev == status || status.isEmpty) continue;
      final code = d['trackingCode'] as String? ?? 'Your parcel';
      await push(
        title: 'Delivery update',
        body: '$code is now ${status.replaceAll('_', ' ')}.',
      );
    }
  }

  Future<void> markAllRead() async {
    for (final n in items.value) {
      n.read = true;
    }
    items.value = List.of(items.value);
    await _persist();
  }

  Future<void> clearAll() async {
    items.value = [];
    await _persist();
  }
}

// ===========================================================================
// In-app notifications screen
// ===========================================================================

class NotificationsScreen extends StatefulWidget {
  const NotificationsScreen({super.key});

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  @override
  void initState() {
    super.initState();
    // Opening the list clears the unread badge.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      NotificationService.instance.markAllRead();
    });
  }

  String _relative(String iso) {
    final then = DateTime.tryParse(iso);
    if (then == null) return '';
    final diff = DateTime.now().difference(then);
    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }

  @override
  Widget build(BuildContext context) {
    final palette = StanTheme.instance.palette(context);

    return Scaffold(
      backgroundColor: palette.surface,
      appBar: AppBar(
        backgroundColor: palette.appBar,
        foregroundColor: palette.onDark,
        elevation: 0,
        title: const Text('Notifications', style: TextStyle(fontWeight: FontWeight.w900)),
        actions: [
          TextButton(
            onPressed: () => NotificationService.instance.clearAll(),
            child: Text('Clear', style: TextStyle(color: palette.onDark, fontWeight: FontWeight.w800)),
          ),
        ],
      ),
      body: ValueListenableBuilder<List<AppNotification>>(
        valueListenable: NotificationService.instance.items,
        builder: (context, list, _) {
          if (list.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.notifications_none, size: 56, color: palette.muted),
                    const SizedBox(height: 12),
                    Text(
                      'No notifications yet',
                      style: TextStyle(
                        color: palette.textStrong,
                        fontSize: 16,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Delivery updates will appear here.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: palette.muted, fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
              ),
            );
          }

          return ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: list.length,
            separatorBuilder: (_, _) => const SizedBox(height: 10),
            itemBuilder: (context, index) {
              final n = list[index];
              return Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: palette.card,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: palette.border),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 38,
                      height: 38,
                      decoration: BoxDecoration(
                        color: stanDark.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(11),
                      ),
                      child: const Icon(Icons.local_shipping, color: stanDark, size: 19),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            n.title,
                            style: TextStyle(
                              color: palette.textStrong,
                              fontSize: 14.5,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            n.body,
                            style: TextStyle(
                              color: palette.textSoft,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              height: 1.35,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            _relative(n.createdAt),
                            style: TextStyle(
                              color: palette.muted,
                              fontSize: 11.5,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }
}
