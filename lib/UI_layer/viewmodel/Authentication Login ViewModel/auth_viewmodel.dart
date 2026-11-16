import 'package:flutter/foundation.dart';

import '../../../Data_layer/repository/User Repository/user.dart';

class AuthenticationViewModel extends ChangeNotifier {
  final UserRepository _userRepository;

  AuthenticationViewModel(this._userRepository);

  bool _isLoading = false;
  String? _errorMessage;
  UserModel? _currentUser;
  String? _pendingVerificationEmail;

  bool get isLoading => _isLoading;

  String? get errorMessage => _errorMessage;

  UserModel? get currentUser => _currentUser;

  String? get pendingVerificationEmail =>
      _pendingVerificationEmail;

  // =========================
  // LOGIN
  // =========================

  Future<bool> login({
    required String email,
    required String password,
  }) async {
    _clearErrorWithoutNotify();

    final trimmedEmail = _canonicalizeEmail(email);

    if (trimmedEmail.isEmpty || password.isEmpty) {
      _errorMessage =
      'Please complete all required fields.';
      notifyListeners();
      return false;
    }

    if (!_isValidEmail(trimmedEmail)) {
      _errorMessage = 'Invalid email or password.';
      notifyListeners();
      return false;
    }

    _setLoading(true);

    try {
      final user = await _userRepository.login(
        email: trimmedEmail,
        password: password,
      );

      if (user == null) {
        _errorMessage = 'Invalid email or password.';
        return false;
      }

      _currentUser = user;
      _errorMessage = null;

      return true;
    } catch (_) {
      _errorMessage =
      'Unable to process your login request. Please try again.';
      return false;
    } finally {
      _setLoading(false);
    }
  }

  // =========================
  // REGISTER
  // =========================

  // =========================
// REGISTER
// =========================

  Future<bool> register({
    required String fullName,
    required String email,
    required DateTime? dateOfBirth,
    required String password,
    required String confirmPassword,
  }) async {
    _clearErrorWithoutNotify();

    final trimmedEmail = _canonicalizeEmail(email);

    // =========================================
    // VALIDATION
    // =========================================

    final validationError =
    validateRegistration(
      fullName: fullName,
      email: trimmedEmail,
      dateOfBirth: dateOfBirth,
      password: password,
      confirmPassword: confirmPassword,
    );

    if (validationError != null) {
      _errorMessage =
          validationError;

      notifyListeners();

      return false;
    }

    _setLoading(true);

    try {
      // =========================================
      // CHECK WHETHER EMAIL ALREADY EXISTS
      // =========================================

      final exists =
      await _userRepository
          .checkEmailExists(
        email: trimmedEmail,
      );

      debugPrint(
        'REGISTER EMAIL EXISTS: $exists',
      );

      if (exists) {
        _errorMessage =
        'This email address is already registered.';

        return false;
      }

      // =========================================
      // EMAIL NOT REGISTERED
      // CONTINUE REGISTRATION
      // =========================================

      await _userRepository.register(
        fullName:
        fullName.trim(),
        email:
        trimmedEmail,
        dateOfBirth:
        dateOfBirth!,
        password:
        password,
      );

      _pendingVerificationEmail =
          trimmedEmail;

      return true;
    } catch (error) {
      debugPrint(
        'REGISTER ERROR: $error',
      );

      _errorMessage =
      'Unable to register this account. Please try again.';

      return false;
    } finally {
      _setLoading(false);
    }
  }

  // =========================
  // REGISTER VALIDATION
  // =========================

  String? validateRegistration({
    required String fullName,
    required String email,
    required DateTime? dateOfBirth,
    required String password,
    required String confirmPassword,
  }) {
    if (fullName.trim().isEmpty ||
        email.trim().isEmpty ||
        dateOfBirth == null ||
        password.isEmpty ||
        confirmPassword.isEmpty) {
      return 'Please complete all required fields.';
    }

    if (!_isValidEmail(email)) {
      return 'Please enter a valid email address.';
    }

    final today = DateTime.now();

    final todayOnly = DateTime(
      today.year,
      today.month,
      today.day,
    );

    if (dateOfBirth.isAfter(todayOnly)) {
      return 'Date of birth cannot be in the future.';
    }

    if (!_isStrongPassword(password)) {
      return 'Password must contain at least 8 characters, including uppercase, lowercase, number and special character.';
    }

    if (password != confirmPassword) {
      return 'Passwords do not match.';
    }

    return null;
  }

  // =========================
  // VERIFY OTP
  // =========================

  Future<bool> verifyOtp({
    required String email,
    required String otp,
  }) async {
    _clearErrorWithoutNotify();

    if (!RegExp(r'^\d{8}$')
        .hasMatch(otp.trim())) {
      _errorMessage =
      'Please enter a valid 8-digit OTP.';
      notifyListeners();
      return false;
    }

    _setLoading(true);

    try {
      await _userRepository.verifyOtp(
        email: _canonicalizeEmail(email),
        otp: otp.trim(),
      );

      _pendingVerificationEmail = null;

      return true;
    } catch (_) {
      _errorMessage =
      'Incorrect OTP. Please try again.';
      return false;
    } finally {
      _setLoading(false);
    }
  }

  // =========================
  // RESEND OTP
  // =========================

  Future<bool> resendOtp({
    required String email,
  }) async {
    _clearErrorWithoutNotify();

    _setLoading(true);

    try {
      await _userRepository.resendOtp(
        email: _canonicalizeEmail(email),
      );

      return true;
    } catch (_) {
      _errorMessage =
      'Unable to resend OTP. Please try again.';
      return false;
    } finally {
      _setLoading(false);
    }
  }

  // =========================
  // FORGOT PASSWORD
  // =========================

  // =========================
// FORGOT PASSWORD
// =========================

  Future<bool> sendPasswordResetEmail({
    required String email,
  }) async {
    _clearErrorWithoutNotify();

    final trimmedEmail = _canonicalizeEmail(email);

    // Empty email
    if (trimmedEmail.isEmpty) {
      _errorMessage =
      'Please enter your email address.';

      notifyListeners();

      return false;
    }

    // Invalid email format
    if (!_isValidEmail(trimmedEmail)) {
      _errorMessage =
      'Please enter a valid email address.';

      notifyListeners();

      return false;
    }

    _setLoading(true);

    try {
      debugPrint(
        'FORGOT PASSWORD EMAIL: $trimmedEmail',
      );

      // =========================================
      // CHECK WHETHER ACCOUNT EXISTS
      // =========================================

      final exists =
      await _userRepository.checkEmailExists(
        email: trimmedEmail,
      );

      debugPrint(
        'EMAIL EXISTS RESULT: $exists',
      );

      // =========================================
      // EMAIL DOES NOT EXIST
      // =========================================

      if (!exists) {
        _errorMessage =
        'This email address is not registered.';

        return false;
      }

      // =========================================
      // EMAIL EXISTS
      // SEND RESET EMAIL
      // =========================================

      debugPrint(
        'EMAIL EXISTS - SENDING RESET EMAIL',
      );

      await _userRepository.sendPasswordResetEmail(
        email: trimmedEmail,
      );

      debugPrint(
        'RESET EMAIL SENT SUCCESSFULLY',
      );

      return true;
    } catch (error) {
      // IMPORTANT:
      // Do not say "email doesn't exist"
      // when the server itself failed.

      debugPrint(
        'FORGOT PASSWORD ERROR: $error',
      );

      _errorMessage =
      'Unable to verify this email address. Please try again.';

      return false;
    } finally {
      _setLoading(false);
    }
  }

  // =========================
  // RESET PASSWORD
  // =========================

  Future<bool> resetPassword({
    required String newPassword,
    required String confirmPassword,
  }) async {
    _clearErrorWithoutNotify();

    if (newPassword.isEmpty ||
        confirmPassword.isEmpty) {
      _errorMessage =
      'Please complete all required fields.';
      notifyListeners();
      return false;
    }

    if (!_isStrongPassword(newPassword)) {
      _errorMessage =
      'Password must contain at least 8 characters, including uppercase, lowercase, number and special character.';
      notifyListeners();
      return false;
    }

    if (newPassword != confirmPassword) {
      _errorMessage =
      'Passwords do not match.';
      notifyListeners();
      return false;
    }

    _setLoading(true);

    try {
      await _userRepository.resetPassword(
        newPassword: newPassword,
      );

      return true;
    } catch (error) {
      debugPrint('RESET PASSWORD ERROR: $error');

      if (error.toString().contains('PASSWORD_TOO_SIMILAR')) {
        _errorMessage =
        'New password is too similar to your previous password. '
            'Please choose a different password.';
        return false;
      }

      _errorMessage =
      'Unable to update password. Please try again.';
      return false;
    } finally {
      _setLoading(false);
    }
  }

  // =========================
  // HELPERS
  // =========================

  /// Gmail treats the local part of an address as dot-insensitive —
  /// "example123@gmail.com" and "exam.ple123@gmail.com" both deliver to the
  /// same inbox, no matter where the dots are. Google's own mail servers
  /// collapse this, so a tourist who types a dotted variant while
  /// registering still receives the OTP at their real inbox and the sign-up
  /// appears to succeed — but this app's own database stores whatever exact
  /// string was typed, dots and all. Without normalizing here, that account
  /// becomes reachable only by re-typing that exact same dotted variant,
  /// and every other dot placement (including the address without any dots)
  /// silently fails to log in as "invalid email or password".
  ///
  /// Normalizing to one canonical, dot-free form before every register /
  /// login / OTP / password-reset call means any dot placement the tourist
  /// types for a Gmail address always resolves to the same stored account.
  static String _canonicalizeEmail(String rawEmail) {
    final normalized = rawEmail.trim().toLowerCase();

    final atIndex = normalized.lastIndexOf('@');
    if (atIndex <= 0 || atIndex == normalized.length - 1) {
      return normalized;
    }

    final localPart = normalized.substring(0, atIndex);
    final domain = normalized.substring(atIndex + 1);

    if (domain != 'gmail.com') {
      return normalized;
    }

    return '${localPart.replaceAll('.', '')}@$domain';
  }

  bool _isValidEmail(String email) {
    final value = email.trim().toLowerCase();

    if (value.isEmpty || value.length > 254) {
      return false;
    }

    final parts = value.split('@');
    if (parts.length != 2) {
      return false;
    }

    final localPart = parts[0];
    final domain = parts[1];

    if (localPart.isEmpty || localPart.length > 64) {
      return false;
    }

    if (domain.isEmpty || domain.length > 253) {
      return false;
    }

    // Gmail/Googlemail usernames only allow letters, numbers and dots —
    // reject '-', '_', '+', '&', '=', etc. that other providers permit.
    if (domain == 'gmail.com' || domain == 'googlemail.com') {
      if (!RegExp(r'^[a-z0-9.]+$', caseSensitive: false).hasMatch(localPart)) {
        return false;
      }
      if (localPart.startsWith('.') || localPart.endsWith('.')) {
        return false;
      }
      if (localPart.contains('..')) {
        return false;
      }
      return true;
    }

    if (localPart.startsWith('.') ||
        localPart.endsWith('.') ||
        localPart.contains('..')) {
      return false;
    }

    if (!RegExp(r'^[a-z0-9._+-]+$', caseSensitive: false)
        .hasMatch(localPart)) {
      return false;
    }

    if (!domain.contains('.')) {
      return false;
    }

    if (domain.startsWith('.') ||
        domain.endsWith('.') ||
        domain.contains('..')) {
      return false;
    }

    final domainParts = domain.split('.');
    for (final part in domainParts) {
      if (part.isEmpty || part.length > 63) {
        return false;
      }
      if (part.startsWith('-') || part.endsWith('-')) {
        return false;
      }
      if (!RegExp(r'^[a-z0-9-]+$', caseSensitive: false).hasMatch(part)) {
        return false;
      }
    }

    final tld = domainParts.last;
    if (!RegExp(r'^[a-z]{2,}$', caseSensitive: false).hasMatch(tld)) {
      return false;
    }

    return true;
  }

  bool _isStrongPassword(
      String password,
      ) {
    return password.length >= 8 &&
        RegExp(r'[A-Z]').hasMatch(password) &&
        RegExp(r'[a-z]').hasMatch(password) &&
        RegExp(r'[0-9]').hasMatch(password) &&
        RegExp(r'[^A-Za-z0-9]')
            .hasMatch(password);
  }

  void clearError() {
    _errorMessage = null;
    notifyListeners();
  }

  void _clearErrorWithoutNotify() {
    _errorMessage = null;
  }

  void _setLoading(bool value) {
    _isLoading = value;
    notifyListeners();
  }
}