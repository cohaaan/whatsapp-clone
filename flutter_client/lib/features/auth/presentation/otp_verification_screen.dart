import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'dart:io' show Platform;
import 'package:device_info_plus/device_info_plus.dart';

import '../data/auth_repository.dart';
import 'phone_input_screen.dart';

// State
class OTPVerificationState {
  final bool isLoading;
  final String? error;
  final bool isResending;

  OTPVerificationState({
    this.isLoading = false,
    this.error,
    this.isResending = false,
  });

  OTPVerificationState copyWith({
    bool? isLoading,
    String? error,
    bool? isResending,
  }) {
    return OTPVerificationState(
      isLoading: isLoading ?? this.isLoading,
      error: error,
      isResending: isResending ?? this.isResending,
    );
  }
}

// Controller
class OTPVerificationController extends StateNotifier<OTPVerificationState> {
  final AuthRepository authRepository;
  final String phoneNumber;

  OTPVerificationController({
    required this.authRepository,
    required this.phoneNumber,
  }) : super(OTPVerificationState());

  Future<bool> verifyOTP(String otp) async {
    state = state.copyWith(isLoading: true, error: null);

    try {
      // Get device info
      final platform = Platform.isIOS ? 'ios' : 'android';
      final deviceName = await _getDeviceName();

      await authRepository.verifyOTP(
        phoneNumber: phoneNumber,
        otp: otp,
        platform: platform,
        deviceName: deviceName,
      );

      state = state.copyWith(isLoading: false);
      return true;
    } on AuthException catch (e) {
      state = state.copyWith(isLoading: false, error: e.message);
      return false;
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: 'Verification failed. Please try again.',
      );
      return false;
    }
  }

  Future<void> resendOTP() async {
    state = state.copyWith(isResending: true, error: null);

    try {
      await authRepository.requestOTP(phoneNumber);
      state = state.copyWith(isResending: false);
    } on AuthException catch (e) {
      state = state.copyWith(isResending: false, error: e.message);
    } catch (e) {
      state = state.copyWith(
        isResending: false,
        error: 'Failed to resend code.',
      );
    }
  }

  Future<String> _getDeviceName() async {
    final deviceInfo = DeviceInfoPlugin();

    if (Platform.isIOS) {
      final iosInfo = await deviceInfo.iosInfo;
      return '${iosInfo.name} (${iosInfo.model})';
    } else {
      final androidInfo = await deviceInfo.androidInfo;
      return '${androidInfo.manufacturer} ${androidInfo.model}';
    }
  }
}

// Provider
final otpVerificationControllerProvider = StateNotifierProvider.family<
    OTPVerificationController, OTPVerificationState, String>((ref, phoneNumber) {
  return OTPVerificationController(
    authRepository: ref.watch(authRepositoryProvider),
    phoneNumber: phoneNumber,
  );
});

// Screen
class OTPVerificationScreen extends ConsumerStatefulWidget {
  final String phoneNumber;

  const OTPVerificationScreen({
    Key? key,
    required this.phoneNumber,
  }) : super(key: key);

  @override
  ConsumerState<OTPVerificationScreen> createState() =>
      _OTPVerificationScreenState();
}

class _OTPVerificationScreenState extends ConsumerState<OTPVerificationScreen> {
  final _otpController = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  @override
  void dispose() {
    _otpController.dispose();
    super.dispose();
  }

  void _onSubmit() async {
    if (!_formKey.currentState!.validate()) return;

    final otp = _otpController.text.trim();

    final success = await ref
        .read(otpVerificationControllerProvider(widget.phoneNumber).notifier)
        .verifyOTP(otp);

    if (success && mounted) {
      // Navigate to main app (replace entire stack)
      Navigator.of(context).pushReplacementNamed('/home');
    }
  }

  void _onResend() async {
    await ref
        .read(otpVerificationControllerProvider(widget.phoneNumber).notifier)
        .resendOTP();

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('New code sent!')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(otpVerificationControllerProvider(widget.phoneNumber));

    return Scaffold(
      appBar: AppBar(
        title: const Text('Verify Phone'),
        elevation: 0,
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Icon(
                  Icons.message,
                  size: 80,
                  color: Colors.blue,
                ),
                const SizedBox(height: 24),

                const Text(
                  'Enter verification code',
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),

                Text(
                  'We sent a code to ${widget.phoneNumber}',
                  style: const TextStyle(
                    fontSize: 16,
                    color: Colors.grey,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 32),

                // OTP input
                TextFormField(
                  controller: _otpController,
                  keyboardType: TextInputType.number,
                  maxLength: 6,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 24,
                    letterSpacing: 8,
                    fontWeight: FontWeight.bold,
                  ),
                  decoration: const InputDecoration(
                    labelText: 'Verification Code',
                    hintText: '000000',
                    border: OutlineInputBorder(),
                    counterText: '',
                  ),
                  validator: (value) {
                    if (value == null || value.isEmpty) {
                      return 'Please enter the code';
                    }

                    if (value.length != 6) {
                      return 'Code must be 6 digits';
                    }

                    if (!RegExp(r'^\d+$').hasMatch(value)) {
                      return 'Code must contain only numbers';
                    }

                    return null;
                  },
                  enabled: !state.isLoading,
                  autofocus: true,
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

                // Verify button
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
                          'Verify',
                          style: TextStyle(fontSize: 16),
                        ),
                ),
                const SizedBox(height: 16),

                // Resend button
                TextButton(
                  onPressed: state.isResending ? null : _onResend,
                  child: state.isResending
                      ? const SizedBox(
                          height: 16,
                          width: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Didn\'t receive the code? Resend'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
