// Rider onboarding: self-registration with the document checklist (driving
// licence, insurance, number plates, certificate of good conduct, national
// ID, phone) and the pending-approval screen shown until an admin approves
// the account on the dashboard.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'main.dart';

class RiderSignupScreen extends StatefulWidget {
  const RiderSignupScreen({super.key});

  @override
  State<RiderSignupScreen> createState() => _RiderSignupScreenState();
}

class _RiderSignupScreenState extends State<RiderSignupScreen> {
  final _nameController = TextEditingController();
  final _phoneController = TextEditingController();
  final _passwordController = TextEditingController();
  final _emailController = TextEditingController();
  final _birthController = TextEditingController();
  final _residenceController = TextEditingController();
  final _plateController = TextEditingController();

  static const _documentFields = [
    (type: 'license', label: 'Driving licence number'),
    (type: 'insurance', label: 'Insurance certificate number'),
    (type: 'good_conduct', label: 'Certificate of Good Conduct number'),
    (type: 'national_id', label: 'National ID number'),
  ];

  final Map<String, TextEditingController> _docNumberControllers = {};
  final Map<String, TextEditingController> _docExpiryControllers = {};

  String _vehicleType = 'Bike';
  bool _isLoading = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    for (final field in _documentFields) {
      _docNumberControllers[field.type] = TextEditingController();
      _docExpiryControllers[field.type] = TextEditingController();
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _phoneController.dispose();
    _passwordController.dispose();
    _emailController.dispose();
    _birthController.dispose();
    _residenceController.dispose();
    _plateController.dispose();
    for (final controller in _docNumberControllers.values) {
      controller.dispose();
    }
    for (final controller in _docExpiryControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _register() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final documents = <String, dynamic>{};
      for (final field in _documentFields) {
        final expiry = _docExpiryControllers[field.type]!.text.trim();
        documents[field.type] = {
          'docNumber': _docNumberControllers[field.type]!.text.trim(),
          if (expiry.isNotEmpty) 'expiryDate': expiry,
        };
      }

      final response = await http
          .post(
            Uri.parse('$apiBaseUrl/auth/register-rider'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'fullName': _nameController.text.trim(),
              'phone': _phoneController.text.trim(),
              'password': _passwordController.text,
              'email': _emailController.text.trim(),
              'placeOfBirth': _birthController.text.trim(),
              'placeOfResidence': _residenceController.text.trim(),
              'vehicleType': _vehicleType,
              'plateNumber': _plateController.text.trim(),
              'documents': documents,
            }),
          )
          .timeout(const Duration(seconds: 45));

      final data = jsonDecode(response.body) as Map<String, dynamic>;

      if (!mounted) return;

      if (response.statusCode == 201) {
        final user = data['user'] as Map<String, dynamic>;
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder: (_) => RiderPendingScreen(
              fullName: user['fullName'] as String,
              approvalStatus: user['approvalStatus'] as String? ?? 'pending',
            ),
          ),
        );
      } else {
        setState(() {
          _errorMessage = data['message'] as String? ?? 'Could not create your rider account.';
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

  InputDecoration _decoration(String label) {
    return InputDecoration(
      labelText: label,
      filled: true,
      fillColor: stanSurface,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide.none,
      ),
    );
  }

  Widget _sectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.only(top: 18, bottom: 10),
      child: Text(
        title,
        style: const TextStyle(color: stanDark, fontSize: 15, fontWeight: FontWeight.w900),
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
        title: const Text('Become a Stan rider', style: TextStyle(fontWeight: FontWeight.w800)),
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
                  'Rider application',
                  style: TextStyle(color: stanDark, fontSize: 20, fontWeight: FontWeight.w900),
                ),
                const SizedBox(height: 6),
                const Text(
                  'Fill in your details and document numbers. An admin reviews and approves your account before you can take deliveries.',
                  style: TextStyle(color: Color(0xFF60727A), fontWeight: FontWeight.w600, height: 1.4),
                ),
                _sectionTitle('Your details'),
                TextField(controller: _nameController, decoration: _decoration('Full name')),
                const SizedBox(height: 10),
                TextField(
                  controller: _phoneController,
                  keyboardType: TextInputType.phone,
                  decoration: _decoration('Phone number'),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _passwordController,
                  obscureText: true,
                  decoration: _decoration('Password (min 6 characters)'),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _emailController,
                  keyboardType: TextInputType.emailAddress,
                  decoration: _decoration('Email (optional)'),
                ),
                const SizedBox(height: 10),
                TextField(controller: _birthController, decoration: _decoration('Place of birth')),
                const SizedBox(height: 10),
                TextField(
                  controller: _residenceController,
                  decoration: _decoration('Place of residence'),
                ),
                _sectionTitle('Vehicle'),
                DropdownButtonFormField<String>(
                  initialValue: _vehicleType,
                  decoration: _decoration('Vehicle type'),
                  items: const [
                    DropdownMenuItem(value: 'Bike', child: Text('Bike')),
                    DropdownMenuItem(value: 'Car', child: Text('Car')),
                    DropdownMenuItem(value: 'Van', child: Text('Van')),
                    DropdownMenuItem(value: 'Truck', child: Text('Truck')),
                  ],
                  onChanged: (value) => setState(() => _vehicleType = value ?? 'Bike'),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _plateController,
                  textCapitalization: TextCapitalization.characters,
                  decoration: _decoration('Number plate (e.g. KDA 001A)'),
                ),
                _sectionTitle('Document checklist'),
                for (final field in _documentFields) ...[
                  TextField(
                    controller: _docNumberControllers[field.type],
                    decoration: _decoration(field.label),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _docExpiryControllers[field.type],
                    keyboardType: TextInputType.datetime,
                    decoration: _decoration('Expiry date YYYY-MM-DD (optional)'),
                  ),
                  const SizedBox(height: 14),
                ],
                const Text(
                  'Document numbers only for now — no photo uploads. Your number plate is added to the checklist automatically.',
                  style: TextStyle(color: Color(0xFF94A3B8), fontSize: 12, fontWeight: FontWeight.w600),
                ),
                if (_errorMessage != null) ...[
                  const SizedBox(height: 14),
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
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                  onPressed: _isLoading ? null : _register,
                  child: _isLoading
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Submit application'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// Shown to riders whose account is still pending (or was rejected). They can
// sign out or re-check their status; work screens stay locked until approval.
class RiderPendingScreen extends StatelessWidget {
  const RiderPendingScreen({
    super.key,
    required this.fullName,
    required this.approvalStatus,
  });

  final String fullName;
  final String approvalStatus;

  @override
  Widget build(BuildContext context) {
    final rejected = approvalStatus == 'rejected';

    return Scaffold(
      backgroundColor: stanDark,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Icon(
                rejected ? Icons.cancel_outlined : Icons.hourglass_top_rounded,
                color: rejected ? const Color(0xFFF87171) : const Color(0xFFFBBF24),
                size: 64,
              ),
              const SizedBox(height: 20),
              Text(
                rejected ? 'Application rejected' : 'Awaiting approval',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.w900),
              ),
              const SizedBox(height: 10),
              Text(
                rejected
                    ? 'Sorry $fullName, your rider application was not approved. Contact Stan support for details.'
                    : 'Thanks $fullName! Your documents are being reviewed by the Stan team. You will be able to take deliveries once an admin approves your account.',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Color(0xFFB9C6DB), fontWeight: FontWeight.w600, height: 1.5),
              ),
              const SizedBox(height: 28),
              OutlinedButton(
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white,
                  side: const BorderSide(color: Colors.white38),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                onPressed: () {
                  Navigator.of(context).pushAndRemoveUntil(
                    MaterialPageRoute(builder: (_) => const LoginScreen()),
                    (route) => false,
                  );
                },
                child: const Text('Back to sign in'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
