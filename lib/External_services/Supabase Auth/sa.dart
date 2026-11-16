import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// UC-01/UC-02/UC-07 — real Supabase Auth + `profiles` table.
///
/// Separate from `External_services/Supabase/s.dart`, which is the simulated
/// backend the Puzzle module uses for game sessions and visit proofs.
class SupabaseAuthExternal {
  SupabaseClient get client => Supabase.instance.client;

  // =========================
  // LOGIN
  // =========================

  Future<AuthResponse> signIn({
    required String email,
    required String password,
  }) async {
    return await client.auth.signInWithPassword(
      email: email.trim().toLowerCase(),
      password: password,
    );
  }

  // =========================
  // CURRENT USER
  // =========================

  User? get currentAuthUser => client.auth.currentUser;

  // =========================
  // GET PROFILE
  // =========================

  Future<Map<String, dynamic>?> getProfile(String userId) async {
    return await client.from('profiles').select().eq('id', userId).maybeSingle();
  }

  // =========================
  // UPDATE PROFILE
  // =========================

  Future<Map<String, dynamic>> updateProfile({
    required String userId,
    required String fullName,
    required String email,
    DateTime? dateOfBirth,
  }) async {
    final currentUser = client.auth.currentUser;
    if (currentUser == null) {
      throw Exception('No authenticated user.');
    }

    return await client
        .from('profiles')
        .update({
          'full_name': fullName.trim(),
          'email': email.trim().toLowerCase(),
          'date_of_birth': dateOfBirth?.toIso8601String().split('T').first,
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        })
        .eq('id', userId)
        .select()
        .single();
  }

  // =========================
  // UPDATE AUTH EMAIL
  // =========================

  Future<void> updateAuthEmail({required String newEmail}) async {
    final currentUser = client.auth.currentUser;
    if (currentUser == null) {
      throw Exception('No authenticated user.');
    }

    await client.auth.updateUser(
      UserAttributes(email: newEmail.trim().toLowerCase()),
      emailRedirectTo: kIsWeb
          ? 'http://localhost:3000/?email_change=success'
          : 'mysterymalaysia://email-change/?email_change=success',
    );
  }

  // =========================
  // REGISTER
  // =========================

  Future<AuthResponse> signUp({
    required String fullName,
    required String email,
    required DateTime dateOfBirth,
    required String password,
  }) async {
    return await client.auth.signUp(
      email: email.trim().toLowerCase(),
      password: password,
      data: {
        'full_name': fullName.trim(),
        'date_of_birth': dateOfBirth.toIso8601String().split('T').first,
      },
    );
  }

  // =========================
  // VERIFY SIGNUP OTP
  // =========================

  Future<AuthResponse> verifySignupOtp({
    required String email,
    required String otp,
  }) async {
    return await client.auth.verifyOTP(
      email: email.trim().toLowerCase(),
      token: otp.trim(),
      type: OtpType.email,
    );
  }

  // =========================
  // RESEND SIGNUP OTP
  // =========================

  Future<void> resendSignupOtp({required String email}) async {
    await client.auth.resend(type: OtpType.signup, email: email.trim().toLowerCase());
  }

  // =========================
  // CHECK EMAIL EXISTS (edge function)
  // =========================

  Future<bool> checkEmailExists({required String email}) async {
    final response = await client.functions.invoke(
      'smooth-handler',
      body: {'email': email.trim().toLowerCase()},
    );

    debugPrint('CHECK EMAIL STATUS: ${response.status}');
    debugPrint('CHECK EMAIL RESPONSE: ${response.data}');

    if (response.status != 200) {
      throw Exception('Unable to verify email address.');
    }

    final data = response.data;
    if (data is Map) {
      return data['exists'] == true;
    }
    return false;
  }

  // =========================
  // SEND RESET PASSWORD EMAIL
  // =========================

  Future<void> sendPasswordResetEmail({required String email}) async {
    await client.auth.resetPasswordForEmail(
      email.trim().toLowerCase(),
      redirectTo: kIsWeb ? 'http://localhost:3000/' : 'mysterymalaysia://reset-password/',
    );
  }

  // =========================
  // UPDATE PASSWORD
  //
  // Calls the 'secure-password-update' edge function instead of updating via
  // the client SDK directly, so the server can reject a new password that's
  // too similar to a previous one (surfaced as `Exception('PASSWORD_TOO_SIMILAR')`).
  // =========================

  Future<void> updatePassword({required String newPassword}) async {
    final currentUser = client.auth.currentUser;
    final currentSession = client.auth.currentSession;

    if (currentUser == null || currentSession == null) {
      throw Exception('No password recovery session found.');
    }

    try {
      final response = await client.functions.invoke(
        'secure-password-update',
        body: {'newPassword': newPassword},
        headers: {'Authorization': 'Bearer ${currentSession.accessToken}'},
      );

      final data = response.data;

      if (data is Map) {
        if (data['code']?.toString() == 'PASSWORD_TOO_SIMILAR') {
          throw Exception('PASSWORD_TOO_SIMILAR');
        }

        if (data['success'] == true && response.status == 200) {
          return;
        }

        throw Exception(
          data['error']?.toString() ?? 'Unable to update password.',
        );
      }

      if (response.status != 200) {
        throw Exception('Unable to update password.');
      }
    } catch (error) {
      if (error.toString().contains('PASSWORD_TOO_SIMILAR')) {
        throw Exception('PASSWORD_TOO_SIMILAR');
      }
      rethrow;
    }
  }

  // =========================
  // CHANGE PASSWORD (UC-07 — from Edit Profile)
  // =========================
  //
  // Re-authenticates with the current password first, then updates it. Throws
  // `Exception('INVALID_CURRENT_PASSWORD')` when the current password is wrong,
  // or `Exception('PASSWORD_TOO_SIMILAR')` when the new password is identical
  // (case-insensitive) to the current one or rejected by updatePassword's
  // server-side similarity check.

  Future<void> changePassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    final currentUser = client.auth.currentUser;
    final email = currentUser?.email;

    if (currentUser == null || email == null || email.isEmpty) {
      throw Exception('No authenticated user.');
    }

    try {
      final response = await client.auth.signInWithPassword(
        email: email,
        password: currentPassword,
      );
      if (response.user == null) {
        throw Exception('INVALID_CURRENT_PASSWORD');
      }
    } on AuthException {
      throw Exception('INVALID_CURRENT_PASSWORD');
    }

    if (currentPassword.trim().toLowerCase() ==
        newPassword.trim().toLowerCase()) {
      throw Exception('PASSWORD_TOO_SIMILAR');
    }

    await updatePassword(newPassword: newPassword);
  }

  // =========================
  // PROFILE STATISTICS (UC-07 — View Profile)
  // =========================
  //
  // Member Since  = profiles.created_at
  // Games Played  = completed trip_path_quests + completed game_sessions
  // Rewards Earned = tourist_rewards.status = 'earned'
  //
  // Was `rewards.is_unlocked = true` — that table belonged to an earlier,
  // abandoned reward design and nothing has written to it since the real
  // reward system moved to `tourist_rewards` (RewardRepository), so this
  // stat silently stayed at 0 for every tourist. tourist_rewards may still
  // be empty or locked down for a given account; a failure there is
  // treated as 0 rather than failing the whole statistics block.

  Future<Map<String, dynamic>> getProfileStatistics() async {
    final currentUser = client.auth.currentUser;
    if (currentUser == null) {
      throw Exception('No authenticated user.');
    }
    final userId = currentUser.id;

    final profileData = await client
        .from('profiles')
        .select('created_at')
        .eq('id', userId)
        .single();
    final createdAt = profileData['created_at']?.toString();

    final tripPathData = await client
        .from('trip_path_quests')
        .select('id')
        .eq('user_id', userId)
        .eq('status', 'completed');
    final tripPathCompleted = (tripPathData as List).length;

    var puzzleCompleted = 0;
    try {
      final puzzleData = await client
          .from('game_sessions')
          .select('id')
          .eq('user_id', userId)
          .eq('status', 'Completed');
      puzzleCompleted = (puzzleData as List).length;
    } catch (error) {
      debugPrint('PROFILE STATISTICS game_sessions skipped: $error');
    }

    var rewardsEarned = 0;
    try {
      final rewardData = await client
          .from('tourist_rewards')
          .select('id')
          .eq('tourist_id', userId)
          .eq('status', 'earned');
      rewardsEarned = (rewardData as List).length;
    } catch (error) {
      debugPrint('PROFILE STATISTICS tourist_rewards skipped: $error');
    }

    return {
      'created_at': createdAt,
      'games_played': tripPathCompleted + puzzleCompleted,
      'rewards_earned': rewardsEarned,
    };
  }

  // =========================
  // UPLOAD PROFILE IMAGE (Supabase Storage: profile-images)
  // =========================

  Future<String> uploadProfileImage({
    required Uint8List bytes,
    required String fileExtension,
    String? contentType,
  }) async {
    final currentUser = client.auth.currentUser;
    if (currentUser == null) {
      throw Exception('No authenticated user.');
    }

    final extension = fileExtension.replaceAll('.', '').trim().toLowerCase();
    if (!['jpg', 'jpeg', 'png', 'webp'].contains(extension)) {
      throw Exception('Unsupported image format.');
    }

    final currentProfile = await getProfile(currentUser.id);
    final oldAvatarUrl = currentProfile?['avatar_url']?.toString();

    final filePath =
        '${currentUser.id}/avatar_${DateTime.now().millisecondsSinceEpoch}.$extension';

    await client.storage.from('profile-images').uploadBinary(
          filePath,
          bytes,
          fileOptions: FileOptions(
            cacheControl: '3600',
            upsert: false,
            contentType: contentType,
          ),
        );

    final publicUrl = client.storage.from('profile-images').getPublicUrl(filePath);

    await client.from('profiles').update({
      'avatar_url': publicUrl,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    }).eq('id', currentUser.id);

    if (oldAvatarUrl != null && oldAvatarUrl.isNotEmpty && oldAvatarUrl != publicUrl) {
      final oldPath = _extractProfileImagePath(oldAvatarUrl);
      if (oldPath != null) {
        try {
          await client.storage.from('profile-images').remove([oldPath]);
        } catch (error) {
          debugPrint('OLD AVATAR DELETE ERROR: $error');
        }
      }
    }

    return publicUrl;
  }

  // =========================
  // REMOVE PROFILE IMAGE
  // =========================

  Future<void> removeProfileImage() async {
    final currentUser = client.auth.currentUser;
    if (currentUser == null) {
      throw Exception('No authenticated user.');
    }

    final profile = await getProfile(currentUser.id);
    final avatarUrl = profile?['avatar_url']?.toString();

    if (avatarUrl != null && avatarUrl.isNotEmpty) {
      final filePath = _extractProfileImagePath(avatarUrl);
      if (filePath != null) {
        await client.storage.from('profile-images').remove([filePath]);
      }
    }

    await client.from('profiles').update({
      'avatar_url': null,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    }).eq('id', currentUser.id);
  }

  String? _extractProfileImagePath(String publicUrl) {
    const marker = '/storage/v1/object/public/profile-images/';
    final uri = Uri.tryParse(publicUrl);
    if (uri == null) return null;

    final index = uri.path.indexOf(marker);
    if (index == -1) return null;

    return uri.path.substring(index + marker.length);
  }

  // =========================
  // GET TRIP PATH QUEST HISTORY
  // =========================

  Future<List<Map<String, dynamic>>> getTripPathQuestHistory() async {
    final currentUser = client.auth.currentUser;
    if (currentUser == null) {
      throw Exception('No authenticated user.');
    }

    final data = await client
        .from('trip_path_quests')
        .select()
        .eq('user_id', currentUser.id)
        .order('last_played_at', ascending: false);

    final quests = List<Map<String, dynamic>>.from(data);
    if (quests.isEmpty) return quests;

    // UC-07 — Game & Place History reveals a checkpoint's real place name
    // once it's actually been visited (checkpoint status 'completed'), same
    // privacy rule Mystery Puzzle history already follows: hidden while
    // still a secret, shown once there's nothing left to protect. One
    // batched query for every quest's checkpoints instead of one per quest.
    final questIds = quests.map((q) => q['id'].toString()).toList();
    final checkpointRows = await client
        .from('trip_path_quest_checkpoints')
        .select('quest_id, checkpoint_number, landmark_name, status')
        .inFilter('quest_id', questIds)
        .order('checkpoint_number', ascending: true);

    final checkpointsByQuest = <String, List<Map<String, dynamic>>>{};
    for (final raw in List<Map<String, dynamic>>.from(checkpointRows)) {
      final questId = raw['quest_id']?.toString() ?? '';
      if (questId.isEmpty) continue;
      checkpointsByQuest.putIfAbsent(questId, () => []).add(raw);
    }

    for (final quest in quests) {
      quest['_checkpoints'] =
          checkpointsByQuest[quest['id'].toString()] ?? const [];
    }

    return quests;
  }

  // =========================
  // GET PUZZLE GAME SESSION HISTORY
  // =========================
  //
  // `game_sessions` is written by ProgressRepository (Puzzle module) via
  // External_services/Supabase/s.dart, but read here for UC-07's Game &
  // Place History since both share the same Supabase client/user.

  Future<List<Map<String, dynamic>>> getGameSessionsHistory() async {
    final currentUser = client.auth.currentUser;
    if (currentUser == null) {
      throw Exception('No authenticated user.');
    }

    final data = await client
        .from('game_sessions')
        .select()
        .eq('user_id', currentUser.id)
        .order('updated_at', ascending: false);

    return List<Map<String, dynamic>>.from(data);
  }

  // =========================
  // DELETE ONE GAME HISTORY ITEM
  // =========================

  Future<void> deleteTripPathQuest(String questId) async {
    final currentUser = client.auth.currentUser;
    if (currentUser == null) {
      throw Exception('No authenticated user.');
    }

    final deletedRows = await client
        .from('trip_path_quests')
        .delete()
        .eq('id', questId)
        .eq('user_id', currentUser.id)
        .select('id');

    if ((deletedRows as List).isEmpty) {
      throw StateError('Quest history was not found or could not be deleted.');
    }
  }

  Future<void> deletePuzzleGameSession(String sessionId) async {
    final currentUser = client.auth.currentUser;
    if (currentUser == null) {
      throw Exception('No authenticated user.');
    }

    final deletedRows = await client
        .from('game_sessions')
        .delete()
        .eq('id', sessionId)
        .eq('user_id', currentUser.id)
        .select('id');

    if ((deletedRows as List).isEmpty) {
      throw StateError('Puzzle history was not found or could not be deleted.');
    }
  }

  // =========================
  // LOGOUT
  // =========================

  Future<void> signOut() async {
    await client.auth.signOut();
  }

  // =========================
  // DELETE ACCOUNT
  // =========================

  Future<void> deleteAccount() async {
    final currentUser = client.auth.currentUser;
    if (currentUser == null) {
      throw Exception('No authenticated user.');
    }

    final response = await client.functions.invoke('delete-account');

    if (response.status != 200) {
      final data = response.data;
      var message = 'Unable to delete account.';
      if (data is Map && data['error'] != null) {
        message = data['error'].toString();
      }
      throw Exception(message);
    }

    await client.auth.signOut();
  }
}
