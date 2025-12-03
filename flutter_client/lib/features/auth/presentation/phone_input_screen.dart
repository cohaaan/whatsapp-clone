import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'dart:io' show Platform;

import '../data/auth_repository.dart';
import 'otp_verification_screen.dart';

// Providers
final authRepositoryProvider = Provider<AuthRepository>((ref) {
  return AuthRepository(
    baseUrl: const String.fromEnvironment(
      'API_BASE_URL',
      defaultValue: 'http://localhost:4000',
    ),
  );
});

final phoneInputControllerProvider =
    StateNotifierProvider<PhoneInputController, PhoneInputState>((ref) {
  return PhoneInputController(
    authRepository: ref.watch(authRepositoryProvider),
  );
});

// State
class PhoneInputState {
  final bool isLoading;
  final String? error;

  PhoneInputState({
    this.isLoading = false,
    this.error,
  });

  PhoneInputState copyWith({
    bool? isLoading,
    String? error,
  }) {
    return PhoneInputState(
      isLoading: isLoading ?? this.isLoading,
      error: error,
    );
  }
}

// Controller
class PhoneInputController extends StateNotifier<PhoneInputState> {
  final AuthRepository authRepository;

  PhoneInputController({required this.authRepository}) : super(PhoneInputState());

  Future<bool> requestOTP(String phoneNumber) async {
    state = state.copyWith(isLoading: true, error: null);

    try {
      await authRepository.requestOTP(phoneNumber);
      state = state.copyWith(isLoading: false);
      return true;
    } on AuthException catch (e) {
      state = state.copyWith(isLoading: false, error: e.message);
      return false;
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: 'Failed to send OTP. Please check your connection.',
      );
      return false;
    }
  }
}

// Screen
class PhoneInputScreen extends ConsumerStatefulWidget {
  const PhoneInputScreen({Key? key}) : super(key: key);

  @override
  ConsumerState<PhoneInputScreen> createState() => _PhoneInputScreenState();
}

class _PhoneInputScreenState extends ConsumerState<PhoneInputScreen> {
  final _phoneController = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  @override
  void dispose() {
    _phoneController.dispose();
    super.dispose();
  }

  void _onSubmit() async {
    if (!_formKey.currentState!.validate()) return;

    final phoneNumber = _phoneController.text.trim();

    final success = await ref
        .read(phoneInputControllerProvider.notifier)
        .requestOTP(phoneNumber);

    if (success && mounted) {
      // Navigate to OTP verification
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (context) => OTPVerificationScreen(phoneNumber: phoneNumber),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(phoneInputControllerProvider);

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // App logo/name
                const Icon(
                  Icons.chat_bubble,
                  size: 80,
                  color: Colors.blue,
                ),
                const SizedBox(height: 24),

                const Text(
                  'Enter your phone number',
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),

                const Text(
                  'We\'ll send you a verification code',
                  style: TextStyle(
                    fontSize: 16,
                    color: Colors.grey,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 32),

                // Phone input
                TextFormField(
                  controller: _phoneController,
                  keyboardType: TextInputType.phone,
                  decoration: const InputDecoration(
                    labelText: 'Phone number',
                    hintText: '+1 234 567 8900',
                    prefixIcon: Icon(Icons.phone),
                    border: OutlineInputBorder(),
                  ),
                  validator: (value) {
                    if (value == null || value.isEmpty) {
                      return 'Please enter your phone number';
                    }

                    // Basic validation
                    if (!RegExp(r'^\+?\d{10,15}$').hasMatch(value.replaceAll(RegExp(r'\s'), ''))) {
                      return 'Please enter a valid phone number';
                    }

                    return null;
                  },
                  enabled: !state.isLoading,
                ),
                const SizedBox(height: 16),

                // Error message
                if (state.error != null)
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.red.shade50,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      state.error!,
                      style: TextStyle(color: Colors.red.shade700),
                      textAlign: TextAlign.center,
                    ),
                  ),
                const SizedBox(height: 24),

                // Submit button
                ElevatedButton(
                  onPressed: state.isLoading ? null : _onSubmit,
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  child: state.isLoading
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                          ),
                        )
                      : const Text(
                          'Send Code',
                          style: TextStyle(fontSize: 16),
                        ),
                ),
                const SizedBox(height: 16),

                // Privacy notice
                const Text(
                  'By continuing, you agree to our Terms of Service and Privacy Policy',
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.grey,
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
