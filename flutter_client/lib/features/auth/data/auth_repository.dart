import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../../core/network/api_client.dart';
import '../domain/entities/auth_tokens.dart';
import '../domain/entities/auth_user.dart';

class AuthRepository {
  final String baseUrl;
  final FlutterSecureStorage _secureStorage;

  AuthRepository({
    required this.baseUrl,
    FlutterSecureStorage? secureStorage,
  }) : _secureStorage = secureStorage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(
                encryptedSharedPreferences: true,
              ),
              iOptions: IOSOptions(
                accessibility: KeychainAccessibility.first_unlock_this_device,
                synchronizable: false, // CRITICAL: Do NOT sync to iCloud
              ),
            );

  /// Request OTP code
  Future<void> requestOTP(String phoneNumber) async {
    final url = Uri.parse('$baseUrl/api/auth/request_otp');

    final response = await http.post(
      url,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'phone_number': phoneNumber}),
    );

    if (response.statusCode == 200) {
      return;
    } else if (response.statusCode == 429) {
      final body = jsonDecode(response.body);
      throw AuthException('Rate limit exceeded. Retry after ${body['retry_after']} seconds.');
    } else {
      final body = jsonDecode(response.body);
      throw AuthException(body['error'] ?? 'Failed to send OTP');
    }
  }

  /// Verify OTP and register/login
  Future<AuthResult> verifyOTP({
    required String phoneNumber,
    required String otp,
    required String platform,
    required String deviceName,
  }) async {
    final url = Uri.parse('$baseUrl/api/auth/verify_otp');

    final response = await http.post(
      url,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'phone_number': phoneNumber,
        'otp': otp,
        'platform': platform,
        'device_name': deviceName,
      }),
    );

    if (response.statusCode == 200) {
      final body = jsonDecode(response.body);

      final tokens = AuthTokens(
        accessToken: body['access_token'],
        refreshToken: body['refresh_token'],
        expiresIn: body['expires_in'],
      );

      final user = AuthUser(
        userId: body['user_id'],
        deviceId: body['device_id'],
      );

      // Store tokens securely
      await storeTokens(tokens);
      await storeUser(user);

      return AuthResult(user: user, tokens: tokens);
    } else if (response.statusCode == 429) {
      throw AuthException('Too many attempts. Try again later.');
    } else {
      final body = jsonDecode(response.body);
      final error = body['error'] ?? 'Verification failed';

      if (error == 'otp_expired') {
        throw AuthException('OTP code expired. Request a new one.');
      } else if (error == 'invalid_otp') {
        throw AuthException('Invalid OTP code. Please try again.');
      } else {
        throw AuthException(error);
      }
    }
  }

  /// Refresh access token
  Future<AuthTokens> refreshToken(String refreshToken) async {
    final url = Uri.parse('$baseUrl/api/auth/refresh');

    final response = await http.post(
      url,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'refresh_token': refreshToken}),
    );

    if (response.statusCode == 200) {
      final body = jsonDecode(response.body);

      final tokens = AuthTokens(
        accessToken: body['access_token'],
        refreshToken: body['refresh_token'],
        expiresIn: body['expires_in'],
      );

      // Store new tokens
      await storeTokens(tokens);

      return tokens;
    } else {
      throw AuthException('Failed to refresh token. Please login again.');
    }
  }

  /// Logout
  Future<void> logout() async {
    final refreshToken = await getRefreshToken();

    if (refreshToken != null) {
      try {
        final url = Uri.parse('$baseUrl/api/auth/logout');

        await http.delete(
          url,
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'refresh_token': refreshToken}),
        );
      } catch (e) {
        // Continue with local logout even if server logout fails
      }
    }

    // Clear local storage
    await clearTokens();
  }

  /// Store tokens securely
  Future<void> storeTokens(AuthTokens tokens) async {
    await _secureStorage.write(key: 'access_token', value: tokens.accessToken);
    await _secureStorage.write(key: 'refresh_token', value: tokens.refreshToken);
    await _secureStorage.write(key: 'token_expires_at', value: DateTime.now().add(Duration(seconds: tokens.expiresIn)).toIso8601String());
  }

  /// Store user info
  Future<void> storeUser(AuthUser user) async {
    await _secureStorage.write(key: 'user_id', value: user.userId);
    await _secureStorage.write(key: 'device_id', value: user.deviceId);
  }

  /// Get access token
  Future<String?> getAccessToken() async {
    return await _secureStorage.read(key: 'access_token');
  }

  /// Get refresh token
  Future<String?> getRefreshToken() async {
    return await _secureStorage.read(key: 'refresh_token');
  }

  /// Get stored user
  Future<AuthUser?> getStoredUser() async {
    final userId = await _secureStorage.read(key: 'user_id');
    final deviceId = await _secureStorage.read(key: 'device_id');

    if (userId != null && deviceId != null) {
      return AuthUser(userId: userId, deviceId: deviceId);
    }

    return null;
  }

  /// Check if token is expired
  Future<bool> isTokenExpired() async {
    final expiresAtStr = await _secureStorage.read(key: 'token_expires_at');

    if (expiresAtStr == null) return true;

    final expiresAt = DateTime.parse(expiresAtStr);
    return DateTime.now().isAfter(expiresAt);
  }

  /// Clear all stored tokens and user data
  Future<void> clearTokens() async {
    await _secureStorage.delete(key: 'access_token');
    await _secureStorage.delete(key: 'refresh_token');
    await _secureStorage.delete(key: 'token_expires_at');
    await _secureStorage.delete(key: 'user_id');
    await _secureStorage.delete(key: 'device_id');
  }

  /// Auto-refresh if needed
  Future<String?> getValidAccessToken() async {
    final accessToken = await getAccessToken();

    if (accessToken == null) return null;

    final isExpired = await isTokenExpired();

    if (isExpired) {
      final refreshToken = await getRefreshToken();

      if (refreshToken != null) {
        try {
          final newTokens = await this.refreshToken(refreshToken);
          return newTokens.accessToken;
        } catch (e) {
          // Refresh failed, need to re-login
          await clearTokens();
          return null;
        }
      }

      return null;
    }

    return accessToken;
  }
}

class AuthResult {
  final AuthUser user;
  final AuthTokens tokens;

  AuthResult({required this.user, required this.tokens});
}

class AuthException implements Exception {
  final String message;

  AuthException(this.message);

  @override
  String toString() => message;
}
