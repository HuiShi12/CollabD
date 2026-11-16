import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../../Data_layer/repository/User Repository/trip_path_quest.dart';
import '../../../Data_layer/repository/User Repository/puzzle_game_session.dart';
import '../../../Data_layer/repository/User Repository/user.dart';

class ManageProfileViewModel extends ChangeNotifier {
  final UserRepository _userRepository;

  ManageProfileViewModel(this._userRepository);

  // =========================================================
  // PROFILE STATE
  // =========================================================

  UserModel? _user;
  bool _isLoading = false;
  String? _errorMessage;

  UserModel? get user => _user;
  bool get isLoading => _isLoading;
  String? get errorMessage => _errorMessage;

  // =========================================================
  // PROFILE STATISTICS STATE (UC-07 — View Profile)
  //
  // Member Since   = profiles.created_at
  // Games Played   = completed trip_path_quests + completed game_sessions
  // Rewards Earned = tourist_rewards.status = 'earned'
  // =========================================================

  String _memberSince = '-';
  int _gamesPlayed = 0;
  int _rewardsEarned = 0;
  bool _isProfileStatisticsLoading = false;
  String? _profileStatisticsErrorMessage;

  String get memberSince => _memberSince;
  int get gamesPlayed => _gamesPlayed;
  int get rewardsEarned => _rewardsEarned;
  bool get isProfileStatisticsLoading => _isProfileStatisticsLoading;
  String? get profileStatisticsErrorMessage => _profileStatisticsErrorMessage;

  // =========================================================
  // GAME HISTORY STATE
  // =========================================================

  List<GameHistoryItem> _gameHistory = [];
  List<SavedGameItem> _savedGames = [];
  bool _isGameHistoryLoading = false;
  String? _gameHistoryErrorMessage;
  String? _gameHistoryActionErrorMessage;

  List<GameHistoryItem> get gameHistory => _gameHistory;
  List<SavedGameItem> get savedGames => List.unmodifiable(_savedGames);
  bool get isGameHistoryLoading => _isGameHistoryLoading;
  String? get gameHistoryErrorMessage => _gameHistoryErrorMessage;
  String? get gameHistoryActionErrorMessage =>
      _gameHistoryActionErrorMessage;

  // =========================================================
  // SET LOADING
  // =========================================================

  void _setLoading(bool value) {
    _isLoading = value;
    notifyListeners();
  }

  // =========================================================
  // CLEAR ERROR
  // =========================================================

  void clearError() {
    _errorMessage = null;
    notifyListeners();
  }

  // =========================================================
  // LOAD PROFILE
  // =========================================================

  Future<void> loadProfile() async {
    _setLoading(true);
    _errorMessage = null;

    try {
      _user = await _userRepository.getProfile();

      if (_user == null) {
        _errorMessage = 'Unable to retrieve profile.';
      }
    } catch (error) {
      debugPrint('LOAD PROFILE ERROR: $error');
      _errorMessage = 'Unable to retrieve profile.';
    } finally {
      _setLoading(false);
    }
  }

  // =========================================================
  // UPDATE PROFILE
  //
  // Email is READ-ONLY (UC-07). It is always preserved from the existing
  // authenticated profile — the Edit Profile form does not let the tourist
  // change it.
  // =========================================================

  Future<bool> updateProfile({
    required String fullName,
    required String email,
    DateTime? dateOfBirth,
  }) async {
    _errorMessage = null;

    if (_user == null) {
      _errorMessage = 'No user profile found.';
      notifyListeners();
      return false;
    }

    if (fullName.trim().isEmpty) {
      _errorMessage = 'Please enter your full name.';
      notifyListeners();
      return false;
    }

    if (dateOfBirth != null && dateOfBirth.isAfter(DateTime.now())) {
      _errorMessage = 'Date of birth cannot be in the future.';
      notifyListeners();
      return false;
    }

    _setLoading(true);

    try {
      final updatedUser = _user!.copyWith(
        fullName: fullName.trim(),
        // Email is deliberately preserved.
        email: _user!.email,
        dateOfBirth: dateOfBirth,
      );

      _user = await _userRepository.updateProfile(updatedUser);
      return true;
    } catch (error) {
      debugPrint('UPDATE PROFILE ERROR: $error');
      _errorMessage = 'Unable to update profile.';
      return false;
    } finally {
      _setLoading(false);
    }
  }

  // =========================================================
  // UPLOAD PROFILE IMAGE
  // =========================================================

  Future<bool> uploadProfileImage({
    required Uint8List bytes,
    required String fileExtension,
    String? contentType,
  }) async {
    _errorMessage = null;
    _setLoading(true);

    try {
      final avatarUrl = await _userRepository.uploadProfileImage(
        bytes: bytes,
        fileExtension: fileExtension,
        contentType: contentType,
      );

      if (_user != null) {
        _user = _user!.copyWith(avatarUrl: avatarUrl);
      }
      return true;
    } catch (error) {
      debugPrint('UPLOAD PROFILE IMAGE ERROR: $error');
      _errorMessage =
      'Unable to update profile picture. Please try again.';
      return false;
    } finally {
      _setLoading(false);
    }
  }

  // =========================================================
  // REMOVE PROFILE IMAGE
  // =========================================================

  Future<bool> removeProfileImage() async {
    _errorMessage = null;
    _setLoading(true);

    try {
      await _userRepository.removeProfileImage();

      // Reload the profile because avatar_url is now NULL in Supabase.
      _user = await _userRepository.getProfile();
      return true;
    } catch (error) {
      debugPrint('REMOVE PROFILE IMAGE ERROR: $error');
      _errorMessage =
      'Unable to remove profile picture. Please try again.';
      return false;
    } finally {
      _setLoading(false);
    }
  }

  // =========================================================
  // LOAD PROFILE STATISTICS
  // =========================================================

  Future<void> loadProfileStatistics() async {
    _isProfileStatisticsLoading = true;
    _profileStatisticsErrorMessage = null;
    notifyListeners();

    try {
      final data = await _userRepository.getProfileStatistics();

      final createdAtValue = data['created_at'];
      if (createdAtValue == null) {
        _memberSince = '-';
      } else {
        final parsedDate = DateTime.tryParse(createdAtValue.toString());
        _memberSince = parsedDate == null
            ? '-'
            : _formatMemberSince(parsedDate.toLocal());
      }

      _gamesPlayed = _convertToInt(data['games_played']);
      _rewardsEarned = _convertToInt(data['rewards_earned']);
    } catch (error) {
      debugPrint('LOAD PROFILE STATISTICS ERROR: $error');
      _memberSince = '-';
      _gamesPlayed = 0;
      _rewardsEarned = 0;
      _profileStatisticsErrorMessage =
      'Unable to load profile statistics.';
    } finally {
      _isProfileStatisticsLoading = false;
      notifyListeners();
    }
  }

  String _formatMemberSince(DateTime date) {
    const months = [
      'January',
      'February',
      'March',
      'April',
      'May',
      'June',
      'July',
      'August',
      'September',
      'October',
      'November',
      'December',
    ];

    return '${date.day} ${months[date.month - 1]} ${date.year}';
  }

  int _convertToInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  // =========================================================
  // LOAD GAME HISTORY
  // =========================================================

  Future<void> loadGameHistory() async {
    _isGameHistoryLoading = true;
    _gameHistoryErrorMessage = null;
    notifyListeners();

    try {
      // Fire both requests together, then await — same concurrency as
      // Future.wait without its single-type-parameter constraint (these two
      // return different model list types).
      final tripPathQuestsFuture = _userRepository.getTripPathQuestHistory();
      final puzzleSessionsFuture =
      _userRepository.getPuzzleGameSessionHistory();
      final tripPathQuests = await tripPathQuestsFuture;
      // A broken/new puzzle-history fetch shouldn't take down Trip Path's
      // already-working history — fails open to an empty list instead.
      List<PuzzleGameSessionModel> puzzleSessions;
      try {
        puzzleSessions = await puzzleSessionsFuture;
      } catch (error) {
        debugPrint('LOAD PUZZLE GAME HISTORY ERROR: $error');
        puzzleSessions = const [];
      }

      // Merge both game types into one feed, most recently played first —
      // each item carries its own sort key since GameHistoryItem.date is
      // already a formatted display string, not a DateTime.
      final merged = [
        for (final quest in tripPathQuests)
          (
          item: _mapTripPathQuestToHistory(quest),
          sortKey: quest.completedAt ?? quest.abandonedAt ?? quest.lastPlayedAt,
          ),
        for (final session in puzzleSessions)
          (
          item: _mapPuzzleSessionToHistory(session),
          sortKey: session.completionDate ?? session.updatedAt,
          ),
      ]..sort((a, b) => b.sortKey.compareTo(a.sortKey));

      _gameHistory = [for (final entry in merged) entry.item];

      _savedGames = tripPathQuests
          .where((quest) => quest.status == 'in_progress')
          .map(_mapTripPathQuestToSavedGame)
          .toList();
    } catch (error) {
      debugPrint('LOAD GAME HISTORY ERROR: $error');
      _gameHistory = [];
      _savedGames = [];
      _gameHistoryErrorMessage = 'Unable to load game history.';
    } finally {
      _isGameHistoryLoading = false;
      notifyListeners();
    }
  }

  /// Permanently removes one history row. Supabase RLS plus the repository's
  /// user-id filter ensure a tourist can only delete their own game.
  Future<bool> deleteGameHistoryItem(GameHistoryItem game) async {
    _gameHistoryActionErrorMessage = null;

    if (game.status == 'Completed') {
      _gameHistoryActionErrorMessage =
      'Completed game history cannot be deleted.';
      notifyListeners();
      return false;
    }

    try {
      if (game.type == 'Mystery Puzzle') {
        await _userRepository.deletePuzzleGameSession(game.id);
      } else if (game.type == 'Trip Path Quest') {
        await _userRepository.deleteTripPathQuest(game.id);
      } else {
        throw StateError('Unsupported game history type.');
      }

      _gameHistory = _gameHistory
          .where((item) => !(item.id == game.id && item.type == game.type))
          .toList(growable: false);
      _savedGames = _savedGames
          .where((item) => item.id != game.id)
          .toList(growable: false);
      notifyListeners();
      return true;
    } catch (error) {
      debugPrint('DELETE GAME HISTORY ERROR: $error');
      _gameHistoryActionErrorMessage =
      'Unable to delete this history item. Please try again.';
      notifyListeners();
      return false;
    }
  }

  // =========================================================
  // MAP TRIP PATH QUEST -> GAME HISTORY / SAVED GAME
  // =========================================================

  GameHistoryItem _mapTripPathQuestToHistory(TripPathQuestModel quest) {
    // A quest can finish every checkpoint (and already have its reward
    // granted) while trip_path_quests.status itself never gets flipped to
    // 'completed' — e.g. the network dropping right after the last
    // checkpoint write, before the quest header update lands. Confirmed
    // live: a Theme Souvenir existed for a quest whose row had already been
    // deleted, because it still displayed as "In Progress" here and so
    // wasn't protected by deleteGameHistoryItem's "Completed can't be
    // deleted" guard below, which trusts this same status. Deriving
    // "Completed" from the actual checkpoint count too (not just the raw
    // status column) fixes both the mislabel and the delete hole in one
    // place, without needing to know why the header update was missed.
    final checkpointsActuallyDone = quest.totalCheckpoints > 0 &&
        quest.completedCheckpoints >= quest.totalCheckpoints;

    String status;
    switch (quest.status) {
      case 'completed':
        status = 'Completed';
        break;
      case 'abandoned':
        status = 'Abandoned';
        break;
      default:
        status = checkpointsActuallyDone ? 'Completed' : 'In Progress';
    }

    final relevantDate =
        quest.completedAt ?? quest.abandonedAt ?? quest.lastPlayedAt;

    return GameHistoryItem(
      id: quest.id,
      type: 'Trip Path Quest',
      title: '${quest.themeName} Theme',
      subtitle: '${quest.completedCheckpoints} / '
          '${quest.totalCheckpoints} checkpoints',
      status: status,
      date: _formatGameHistoryDate(relevantDate),
      progress: '${quest.completedCheckpoints}/${quest.totalCheckpoints}',
      placeNames: quest.completedCheckpointNames,
    );
  }

  SavedGameItem _mapTripPathQuestToSavedGame(TripPathQuestModel quest) {
    return SavedGameItem(
      id: quest.id,
      type: 'Trip Path Quest',
      themeId: quest.themeId,
      themeName: quest.themeName,
      themeEmoji: '🗺️',
      themeColor: const Color(0xFF0284C7),
      checkpoint: quest.currentCheckpoint,
      artworkProgress: quest.completedCheckpoints,
      date: _formatGameHistoryDate(quest.lastPlayedAt),
    );
  }

  // =========================================================
  // MAP PUZZLE GAME SESSION -> GAME HISTORY
  // =========================================================

  GameHistoryItem _mapPuzzleSessionToHistory(PuzzleGameSessionModel session) {
    // Category only while still in progress — the real place name/address
    // stays hidden until the visit is verified (UC-03 C3 / FR03_6), same
    // rule the Puzzle screens themselves follow. Once completed, the name
    // is no longer a secret worth protecting.
    final title = session.isCompleted &&
        (session.hiddenPlaceName?.isNotEmpty ?? false)
        ? session.hiddenPlaceName!
        : _puzzleCategoryDisplayLabel(session.category);

    final subtitle = session.isCompleted
        ? (session.visitVerified ? 'Visit verified' : 'Puzzle solved')
        : (session.puzzleCompleted ? 'Ready to navigate' : 'Solving puzzle');

    final relevantDate = session.completionDate ?? session.updatedAt;

    return GameHistoryItem(
      id: session.id,
      type: 'Mystery Puzzle',
      title: title,
      subtitle: subtitle,
      status: session.status,
      date: _formatGameHistoryDate(relevantDate),
      // Mystery Puzzle is stage-based, not checkpoint-based. Do not show a
      // misleading numeric value such as 1/2 in Game & Place History.
      progress: null,
    );
  }

  /// Renamed to match Trip Path Quest's theme names ("Food Quest", "Culture
  /// Quest", "Heritage Quest", "Nature Quest") so an in-progress Mystery
  /// Puzzle history row reads as the same kind of thing as a quest, instead
  /// of exposing gm.dart's raw internal category label ("Local Food", "Park
  /// & Garden", "Local Attraction", ...) straight to the tourist. Mirrors
  /// mystery_place_puzzle_game.dart's own _categoryDisplayLabel — duplicated
  /// here rather than shared since PuzzleGameSessionModel only persists the
  /// raw category string, not a clean route-group id to switch on.
  String _puzzleCategoryDisplayLabel(String? category) {
    final c = (category ?? '').toLowerCase();
    if (c.contains('food') || c.contains('restaurant') || c.contains('cafe')) {
      return 'Food Quest';
    }
    if (c.contains('museum') || c.contains('gallery') || c.contains('cultur')) {
      return 'Culture Quest';
    }
    if (c.contains('park') || c.contains('garden') || c.contains('nature')) {
      return 'Nature Quest';
    }
    if (c.contains('heritage')) {
      return 'Heritage Quest';
    }
    return 'Mystery Quest';
  }

  String _formatGameHistoryDate(DateTime date) {
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];

    final localDate = date.toLocal();
    return '${localDate.day} '
        '${months[localDate.month - 1]} '
        '${localDate.year}';
  }

  // =========================================================
  // CHANGE PASSWORD (UC-07 — from Edit Profile)
  // =========================================================

  Future<bool> changePassword({
    required String currentPassword,
    required String newPassword,
    required String confirmPassword,
  }) async {
    _errorMessage = null;

    if (currentPassword.isEmpty ||
        newPassword.isEmpty ||
        confirmPassword.isEmpty) {
      _errorMessage = 'Please complete all required fields.';
      notifyListeners();
      return false;
    }

    if (!_isStrongPassword(newPassword)) {
      _errorMessage =
      'Password must contain at least 8 characters, including uppercase, '
          'lowercase, number and special character.';
      notifyListeners();
      return false;
    }

    if (newPassword != confirmPassword) {
      _errorMessage = 'Passwords do not match.';
      notifyListeners();
      return false;
    }

    if (currentPassword.trim().toLowerCase() ==
        newPassword.trim().toLowerCase()) {
      _errorMessage =
      'New password is too similar to your current password. '
          'Please choose a different password.';
      notifyListeners();
      return false;
    }

    _setLoading(true);

    try {
      await _userRepository.changePassword(
        currentPassword: currentPassword,
        newPassword: newPassword,
      );
      return true;
    } catch (error) {
      debugPrint('CHANGE PASSWORD ERROR: $error');

      final errorText = error.toString();
      if (errorText.contains('INVALID_CURRENT_PASSWORD')) {
        _errorMessage = 'Current password is incorrect.';
      } else if (errorText.contains('PASSWORD_TOO_SIMILAR')) {
        _errorMessage =
        'New password is too similar to your previous password. '
            'Please choose a different password.';
      } else {
        _errorMessage = 'Unable to change password. Please try again.';
      }
      return false;
    } finally {
      _setLoading(false);
    }
  }

  bool _isStrongPassword(String password) {
    return password.length >= 8 &&
        RegExp(r'[A-Z]').hasMatch(password) &&
        RegExp(r'[a-z]').hasMatch(password) &&
        RegExp(r'[0-9]').hasMatch(password) &&
        RegExp(r'[^A-Za-z0-9]').hasMatch(password);
  }

  // =========================================================
  // LOGOUT
  // =========================================================

  Future<bool> logout() async {
    _errorMessage = null;
    _setLoading(true);

    try {
      await _userRepository.logout();
      _clearLocalData();
      return true;
    } catch (error) {
      debugPrint('LOGOUT ERROR: $error');
      _errorMessage = 'Unable to logout.';
      return false;
    } finally {
      _setLoading(false);
    }
  }

  // =========================================================
  // DELETE ACCOUNT
  // =========================================================

  Future<bool> deleteAccount() async {
    _errorMessage = null;
    _setLoading(true);

    try {
      await _userRepository.deleteAccount();
      _clearLocalData();
      return true;
    } catch (error) {
      debugPrint('DELETE ACCOUNT ERROR: $error');
      _errorMessage = 'Unable to delete account.';
      return false;
    } finally {
      _setLoading(false);
    }
  }

  void _clearLocalData() {
    _user = null;
    _gameHistory = [];
    _savedGames = [];
    _memberSince = '-';
    _gamesPlayed = 0;
    _rewardsEarned = 0;
    _profileStatisticsErrorMessage = null;
    _gameHistoryErrorMessage = null;
  }
}

// ===========================================================
// GAME HISTORY MODEL
// ===========================================================

class GameHistoryItem {
  final String id;
  final String type;
  final String title;
  final String subtitle;
  final String status;
  final String date;
  final String? progress;

  /// Real place names for checkpoints actually visited so far — empty when
  /// nothing has been completed yet (never shown in that case). Only
  /// populated for Trip Path Quest; Mystery Puzzle already reveals its one
  /// place name via [title] once completed.
  final List<String> placeNames;

  const GameHistoryItem({
    required this.id,
    required this.type,
    required this.title,
    required this.subtitle,
    required this.status,
    required this.date,
    this.progress,
    this.placeNames = const <String>[],
  });
}

// ===========================================================
// SAVED GAME MODEL
// ===========================================================

class SavedGameItem {
  final String id;
  final String type;
  final String themeId;
  final String themeName;
  final String themeEmoji;
  final Color themeColor;
  final int checkpoint;
  final int artworkProgress;
  final String date;

  const SavedGameItem({
    required this.id,
    required this.type,
    required this.themeId,
    required this.themeName,
    required this.themeEmoji,
    required this.themeColor,
    required this.checkpoint,
    required this.artworkProgress,
    required this.date,
  });
}
