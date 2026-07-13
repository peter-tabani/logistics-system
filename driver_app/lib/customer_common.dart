// Shared helpers for the customer experience: status styling, the delivery
// progress timeline, and the sender pay-now (M-Pesa STK) flow.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'main.dart';

Map<String, String> customerAuthHeaders(String token) => {
      'Authorization': 'Bearer $token',
    };

(Color fg, Color bg) customerStatusPalette(String status) {
  return switch (status) {
    'delivered' => (const Color(0xFF166534), const Color(0xFFDCFCE7)),
    'pending' => (const Color(0xFF475569), const Color(0xFFE2E8F0)),
    'cancelled' => (const Color(0xFF991B1B), const Color(0xFFFEE2E2)),
    'at_collection_point' => (const Color(0xFF6D28D9), const Color(0xFFEDE9FE)),
    _ => (const Color(0xFF92400E), const Color(0xFFFEF3C7)),
  };
}

Widget customerStatusChip(String status) {
  final palette = customerStatusPalette(status);

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

String packageSizeLabel(String? size) {
  return switch (size) {
    'small' => 'Small (fits a bag)',
    'medium' => 'Medium (shoe box)',
    'large' => 'Large (needs a boot)',
    _ => 'Not specified',
  };
}

/// Progress steps for a parcel, leg-aware for collection-point routing.
List<({String label, bool done})> customerTimeline(Map<String, dynamic> delivery) {
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

/// 0..1 progress for progress bars. Cancelled parcels report 0.
double customerProgress(Map<String, dynamic> delivery) {
  if (delivery['status'] == 'cancelled') return 0;
  final steps = customerTimeline(delivery);
  final done = steps.where((step) => step.done).length;
  return steps.isEmpty ? 0 : done / steps.length;
}

/// Sender pays via M-Pesa STK push. Real Daraja when the owner has
/// configured credentials; otherwise the simulated DEMO prompt. Returns true
/// when the payment settled.
Future<bool> customerPayNow(
  BuildContext context, {
  required String token,
  required String phone,
  required Map<String, dynamic> delivery,
}) async {
  final deliveryId = delivery['id'] as int;

  Map<String, dynamic> initData;
  try {
    final response = await http
        .post(
          Uri.parse('$apiBaseUrl/customer/deliveries/$deliveryId/pay'),
          headers: {...customerAuthHeaders(token), 'Content-Type': 'application/json'},
          body: jsonEncode(<String, dynamic>{}),
        )
        .timeout(apiRequestTimeout);
    initData = jsonDecode(response.body) as Map<String, dynamic>;
    if (response.statusCode != 200) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(initData['message'] as String? ?? 'Could not start the payment.'),
          ),
        );
      }
      return false;
    }
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not reach the server.')),
      );
    }
    return false;
  }

  if (!context.mounted) return false;

  final simulated = initData['simulated'] != false;

  final result = await showStkPush(
    context,
    title: 'Pay for delivery',
    phone: phone,
    amountText: formatKsh((delivery['fareAmount'] as num?) ?? 0),
    pendingNote: simulated
        ? 'Approve the M-Pesa prompt (DEMO simulation).'
        : 'Enter your M-Pesa PIN on your phone.',
    submit: () async {
      if (simulated) {
        final response = await http
            .post(
              Uri.parse('$apiBaseUrl/customer/deliveries/$deliveryId/pay/simulate-result'),
              headers: {...customerAuthHeaders(token), 'Content-Type': 'application/json'},
              body: jsonEncode({'success': true}),
            )
            .timeout(apiRequestTimeout);
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        if (response.statusCode == 200 && data['paymentStatus'] == 'paid') {
          return StkResult(
            success: true,
            reference: data['reference'] as String?,
            message: 'Payment received. Thank you!',
          );
        }
        return StkResult(
          success: false,
          message: data['message'] as String? ?? 'Payment failed.',
        );
      }

      return pollPaymentStatus(
        url: '$apiBaseUrl/customer/deliveries/$deliveryId/payment-status',
        token: token,
      );
    },
  );

  return result != null && result.success;
}
