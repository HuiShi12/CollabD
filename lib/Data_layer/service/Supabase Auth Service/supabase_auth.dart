import 'dart:typed_data';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../External_services/Supabase Auth/sa.dart';

class SupabaseAuthService {
  final SupabaseAuthExternal supabaseAuthExternal;

  SupabaseAuthService(this.supabaseAuthExternal);

  Future<AuthResponse> signIn({required String email, required String password}) {
    return supabaseAuthExternal.signIn(email: email, password: password);
  }

  User? get currentAuthUser => supabaseAuthExternal.currentAuthUser;

  Future<Map<String, dynamic>?> getProfile(String userId) {
    return supabaseAuthExternal.getProfile(userId);
  }

  Future<Map<String, dynamic>> updateProfile({
    required String userId,
    required String fullName,
    required String email,
    DateTime? dateOfBirth,
  }) {
    return supabaseAuthExternal.updateProfile(
      userId: userId,
      fullName: fullName,
      email: email,
      dateOfBirth: dateOfBirth,
    );
  }

  Future<void> updateAuthEmail({required String newEmail}) {
    return supabaseAuthExternal.updateAuthEmail(newEmail: newEmail);
  }

  Future<AuthResponse> signUp({
    required String fullName,
    required String email,
    required DateTime dateOfBirth,
    required String password,
  }) {
    return supabaseAuthExternal.signUp(
      fullName: fullName,
      email: email,
      dateOfBirth: dateOfBirth,
      password: password,
    );
  }

  Future<AuthResponse> verifySignupOtp({required String email, required String otp}) {
    return supabaseAuthExternal.verifySignupOtp(email: email, otp: otp);
  }

  Future<bool> checkEmailExists({required String email}) {
    return supabaseAuthExternal.checkEmailExists(email: email);
  }

  Future<String> uploadProfileImage({
    required Uint8List bytes,
    required String fileExtension,
    String? contentType,
  }) {
    return supabaseAuthExternal.uploadProfileImage(
      bytes: bytes,
      fileExtension: fileExtension,
      contentType: contentType,
    );
  }

  Future<void> removeProfileImage() => supabaseAuthExternal.removeProfileImage();

  Future<List<Map<String, dynamic>>> getTripPathQuestHistory() {
    return supabaseAuthExternal.getTripPathQuestHistory();
  }

  Future<List<Map<String, dynamic>>> getGameSessionsHistory() {
    return supabaseAuthExternal.getGameSessionsHistory();
  }

  Future<void> deleteTripPathQuest(String questId) {
    return supabaseAuthExternal.deleteTripPathQuest(questId);
  }

  Future<void> deletePuzzleGameSession(String sessionId) {
    return supabaseAuthExternal.deletePuzzleGameSession(sessionId);
  }

  Future<void> resendSignupOtp({required String email}) {
    return supabaseAuthExternal.resendSignupOtp(email: email);
  }

  Future<void> sendPasswordResetEmail({required String email}) {
    return supabaseAuthExternal.sendPasswordResetEmail(email: email);
  }

  Future<void> updatePassword({required String newPassword}) {
    return supabaseAuthExternal.updatePassword(newPassword: newPassword);
  }

  Future<void> changePassword({
    required String currentPassword,
    required String newPassword,
  }) {
    return supabaseAuthExternal.changePassword(
      currentPassword: currentPassword,
      newPassword: newPassword,
    );
  }

  Future<Map<String, dynamic>> getProfileStatistics() {
    return supabaseAuthExternal.getProfileStatistics();
  }

  Future<void> signOut() => supabaseAuthExternal.signOut();

  Future<void> deleteAccount() => supabaseAuthExternal.deleteAccount();
}
