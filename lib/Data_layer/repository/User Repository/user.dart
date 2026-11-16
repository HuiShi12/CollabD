import 'dart:typed_data';

import '../../service/Supabase Auth Service/supabase_auth.dart';
import 'trip_path_quest.dart';
import 'puzzle_game_session.dart';

class UserModel {
  final String id;
  final String email;
  final String fullName;
  final DateTime? dateOfBirth;
  final String? avatarUrl;

  const UserModel({
    required this.id,
    required this.email,
    required this.fullName,
    this.dateOfBirth,
    this.avatarUrl,
  });

  factory UserModel.fromMap(Map<String, dynamic> map) {
    return UserModel(
      id: map['id'] ?? '',
      email: map['email'] ?? '',
      fullName: map['full_name'] ?? '',
      dateOfBirth: map['date_of_birth'] != null
          ? DateTime.tryParse(map['date_of_birth'].toString())
          : null,
      avatarUrl: map['avatar_url']?.toString(),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'email': email,
      'full_name': fullName,
      'date_of_birth': dateOfBirth?.toIso8601String(),
      'avatar_url': avatarUrl,
    };
  }

  UserModel copyWith({
    String? id,
    String? email,
    String? fullName,
    DateTime? dateOfBirth,
    String? avatarUrl,
  }) {
    return UserModel(
      id: id ?? this.id,
      email: email ?? this.email,
      fullName: fullName ?? this.fullName,
      dateOfBirth: dateOfBirth ?? this.dateOfBirth,
      avatarUrl: avatarUrl ?? this.avatarUrl,
    );
  }
}

class UserRepository {
  final SupabaseAuthService supabaseAuthService;

  UserRepository(this.supabaseAuthService);

  UserModel? _currentUser;

  // =========================
  // LOGIN
  // =========================

  Future<UserModel?> login({
    required String email,
    required String password,
  }) async {
    try {
      final response = await supabaseAuthService.signIn(
        email: email.trim(),
        password: password,
      );

      final authUser = response.user;
      if (authUser == null) {
        return null;
      }

      final profileData = await supabaseAuthService.getProfile(authUser.id);

      if (profileData == null) {
        _currentUser = UserModel(
          id: authUser.id,
          email: authUser.email ?? email,
          fullName: '',
        );
        return _currentUser;
      }

      _currentUser = UserModel.fromMap(profileData);
      return _currentUser;
    } catch (_) {
      return null;
    }
  }

  // =========================
  // REGISTER
  // =========================

  Future<void> register({
    required String fullName,
    required String email,
    required DateTime dateOfBirth,
    required String password,
  }) async {
    final response = await supabaseAuthService.signUp(
      fullName: fullName,
      email: email,
      dateOfBirth: dateOfBirth,
      password: password,
    );

    if (response.user == null) {
      throw Exception('Unable to create user.');
    }
  }

  // =========================
  // CHECK EMAIL EXISTS
  // =========================

  Future<bool> checkEmailExists({required String email}) {
    return supabaseAuthService.checkEmailExists(email: email);
  }

  // =========================
  // VERIFY OTP
  // =========================

  Future<void> verifyOtp({required String email, required String otp}) async {
    final response = await supabaseAuthService.verifySignupOtp(email: email, otp: otp);

    if (response.user == null) {
      throw Exception('Unable to verify OTP.');
    }

    await supabaseAuthService.signOut();
  }

  // =========================
  // RESEND OTP
  // =========================

  Future<void> resendOtp({required String email}) {
    return supabaseAuthService.resendSignupOtp(email: email);
  }

  // =========================
  // PASSWORD RESET EMAIL
  // =========================

  Future<void> sendPasswordResetEmail({required String email}) {
    return supabaseAuthService.sendPasswordResetEmail(email: email);
  }

  // =========================
  // RESET PASSWORD
  // =========================

  Future<void> resetPassword({required String newPassword}) {
    return supabaseAuthService.updatePassword(newPassword: newPassword);
  }

  // =========================
  // CHANGE PASSWORD (from Edit Profile)
  // =========================

  Future<void> changePassword({
    required String currentPassword,
    required String newPassword,
  }) {
    return supabaseAuthService.changePassword(
      currentPassword: currentPassword,
      newPassword: newPassword,
    );
  }

  // =========================
  // PROFILE STATISTICS
  // =========================

  Future<Map<String, dynamic>> getProfileStatistics() {
    return supabaseAuthService.getProfileStatistics();
  }

  // =========================
  // GET CURRENT USER
  // =========================

  Future<UserModel?> getCurrentUser() async => _currentUser;

  // =========================
  // GET PROFILE
  // =========================

  Future<UserModel?> getProfile() async {
    final authUser = supabaseAuthService.currentAuthUser;
    if (authUser == null) {
      return null;
    }

    final profileData = await supabaseAuthService.getProfile(authUser.id);
    if (profileData == null) {
      return null;
    }

    _currentUser = UserModel.fromMap(profileData);
    return _currentUser;
  }

  // =========================
  // UPDATE PROFILE
  // =========================

  Future<UserModel> updateProfile(UserModel updatedUser) async {
    final authUser = supabaseAuthService.currentAuthUser;
    if (authUser == null) {
      throw Exception('No authenticated user.');
    }

    final currentEmail = authUser.email?.trim().toLowerCase() ?? '';
    final requestedEmail = updatedUser.email.trim().toLowerCase();

    if (requestedEmail != currentEmail) {
      await supabaseAuthService.updateAuthEmail(newEmail: requestedEmail);
    }

    final data = await supabaseAuthService.updateProfile(
      userId: authUser.id,
      fullName: updatedUser.fullName,
      email: currentEmail,
      dateOfBirth: updatedUser.dateOfBirth,
    );

    _currentUser = UserModel.fromMap(data);
    return _currentUser!;
  }

  // =========================
  // UPLOAD PROFILE IMAGE
  // =========================

  Future<String> uploadProfileImage({
    required Uint8List bytes,
    required String fileExtension,
    String? contentType,
  }) {
    return supabaseAuthService.uploadProfileImage(
      bytes: bytes,
      fileExtension: fileExtension,
      contentType: contentType,
    );
  }

  // =========================
  // REMOVE PROFILE IMAGE
  // =========================

  Future<void> removeProfileImage() {
    return supabaseAuthService.removeProfileImage();
  }

  // =========================
  // GET TRIP PATH QUEST HISTORY
  // =========================

  Future<List<TripPathQuestModel>> getTripPathQuestHistory() async {
    final data = await supabaseAuthService.getTripPathQuestHistory();
    return data.map((item) => TripPathQuestModel.fromMap(item)).toList();
  }

  // =========================
  // GET PUZZLE GAME SESSION HISTORY
  // =========================

  Future<List<PuzzleGameSessionModel>> getPuzzleGameSessionHistory() async {
    final data = await supabaseAuthService.getGameSessionsHistory();
    return data.map((item) => PuzzleGameSessionModel.fromMap(item)).toList();
  }

  // =========================
  // DELETE GAME HISTORY
  // =========================

  Future<void> deleteTripPathQuest(String questId) {
    return supabaseAuthService.deleteTripPathQuest(questId);
  }

  Future<void> deletePuzzleGameSession(String sessionId) {
    return supabaseAuthService.deletePuzzleGameSession(sessionId);
  }

  // =========================
  // LOGOUT
  // =========================

  Future<void> logout() async {
    await supabaseAuthService.signOut();
    _currentUser = null;
  }

  // =========================
  // DELETE ACCOUNT
  // =========================

  Future<void> deleteAccount() async {
    await supabaseAuthService.deleteAccount();
    _currentUser = null;
  }
}
