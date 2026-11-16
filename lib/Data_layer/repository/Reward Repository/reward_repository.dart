import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import '../../service/Image Service/postcard_image_service.dart';
import 'reward_observer.dart';
import 'dart:async';
import '../../service/Supabase Service/supabase.dart';
import '../../service/Gemini Service/gemini.dart';
import '../../service/Image Service/image.dart';
import 'reward_events.dart';
import 'reward_models.dart';
export 'reward_models.dart';

class ThemeSouvenirImage {
  final String id, theme, imageUrl;
  final bool isAvailable;
  final DateTime createdAt;
  final String? assignedQuestId;
  final DateTime? assignedAt;
  const ThemeSouvenirImage({
    required this.id,
    required this.theme,
    required this.imageUrl,
    required this.isAvailable,
    required this.createdAt,
    this.assignedQuestId,
    this.assignedAt,
  });
  factory ThemeSouvenirImage.fromMap(Map<String, dynamic> m) =>
      ThemeSouvenirImage(
        id: m['id'] as String,
        theme: m['theme'] as String,
        imageUrl: m['image_url'] as String,
        isAvailable: m['is_available'] as bool,
        createdAt: DateTime.parse(m['created_at'] as String),
        assignedQuestId: m['assigned_quest_id'] as String?,
        assignedAt: m['assigned_at'] == null
            ? null
            : DateTime.parse(m['assigned_at'] as String),
      );
  Map<String, dynamic> toMap() => {
    'id': id,
    'theme': theme,
    'image_url': imageUrl,
    'is_available': isAvailable,
    'created_at': createdAt.toIso8601String(),
    'assigned_quest_id': assignedQuestId,
    'assigned_at': assignedAt?.toIso8601String(),
  };
}

/// Marker Skins come in three tracks, each measuring progress differently:
/// - [explorer]: any exploration game at all (Puzzle + Trip Path combined).
/// - [puzzle]: Mystery Place Puzzle completions only.
/// - [theme]: one specific Trip Path theme's completions only — [theme]
///   names which one (e.g. 'Food'), matching RewardRepository.themes.
enum MarkerSkinCategory { explorer, puzzle, theme }

/// One configured Marker Skin design (UC-06 A3). `id` doubles as both the
/// tourist_rewards.source_id for this skin and the
/// explorer_marker_skin_images.design_id key for its cached master image.
/// `color` is a solid fallback shown on the map marker whenever there's no
/// real Gemini-generated image yet (still or always) — so equipping a
/// different skin is visibly different immediately, not only once/if
/// billing is enabled.
class MarkerSkinDesign {
  final String id, name, description;
  final MarkerSkinCategory category;
  final int milestoneTarget;
  final int color;
  final String? theme;
  const MarkerSkinDesign({
    required this.id,
    required this.name,
    required this.description,
    required this.category,
    required this.milestoneTarget,
    required this.color,
    this.theme,
  });
}

/// Reward catalogue and tourist-owned records.
class RewardRepository {
  // Lowered 10 -> 3 by explicit request, matching
  // lowStockThemeImageTargetQuantity's own proactive top-up target — the
  // emergency (catalogue truly empty) and routine (low-stock) replenish
  // paths now refill to the same amount. Also reduces how many sequential
  // Pollinations.ai calls a single empty-catalogue moment can trigger —
  // its free anonymous tier allows only 1 in-flight request per IP, so
  // fewer calls means less exposure to that rate limit on a shared/NAT'd
  // network.
  static const defaultThemeImageTargetQuantity = 3;
  static const themes = ['Food', 'Culture', 'Heritage', 'Nature'];

  // Explorer thresholds (10/25/50/100/150) are the user's real numbers.
  // Puzzle thresholds are still placeholders (not specified) — a scaled-
  // down 3-tier version of Explorer's progression, capping at Gold per
  // the user's request. Theme thresholds (10 per theme) are the user's
  // real number too.
  static const markerSkinDesigns = [
    // ---------------- Explorer (5 tiers, any game type) ----------------
    MarkerSkinDesign(
      id: 'bronze_explorer',
      name: 'Bronze Explorer',
      description:
          'A circular badge icon of a bronze compass rose with weathered '
          'patina, layered over a faint silhouette of the Malaysian '
          'peninsula, warm amber and copper tones, flat vector emblem style',
      category: MarkerSkinCategory.explorer,
      milestoneTarget: 10,
      color: 0xFFCD7F32,
    ),
    MarkerSkinDesign(
      id: 'silver_explorer',
      name: 'Silver Explorer',
      description:
          'A circular badge icon of a silver hibiscus flower (bunga raya) '
          'in full bloom with polished metallic petals, cool grey and white '
          'highlights, flat vector emblem style',
      category: MarkerSkinCategory.explorer,
      milestoneTarget: 25,
      color: 0xFFC0C0C0,
    ),
    MarkerSkinDesign(
      id: 'gold_explorer',
      name: 'Gold Explorer',
      description:
          'A circular badge icon of the Petronas Twin Towers silhouette in '
          'polished gold, radiating sunburst lines behind it, rich gold and '
          'deep navy colours, flat vector emblem style',
      category: MarkerSkinCategory.explorer,
      milestoneTarget: 50,
      color: 0xFFFFD700,
    ),
    MarkerSkinDesign(
      id: 'platinum_explorer',
      name: 'Platinum Explorer',
      description:
          'A circular badge icon of a platinum hornbill (the state bird of '
          'Sarawak) in flight, sleek metallic white and silver feather '
          'detail, flat vector emblem style',
      category: MarkerSkinCategory.explorer,
      milestoneTarget: 100,
      color: 0xFFE5E4E2,
    ),
    MarkerSkinDesign(
      id: 'legend_explorer',
      name: 'Legend Explorer',
      description:
          'A circular badge icon of a mythic garuda-inspired bird '
          'silhouette wreathed in flame, deep amethyst purple and gold '
          'accents, ornate flat vector emblem style',
      category: MarkerSkinCategory.explorer,
      milestoneTarget: 150,
      color: 0xFF8E44AD,
    ),

    // ---------------- Puzzle (3 tiers, Mystery Place Puzzle only) ------
    // PLACEHOLDER thresholds — not specified; scaled down from Explorer's
    // progression, capped at Gold as requested.
    MarkerSkinDesign(
      id: 'bronze_puzzler',
      name: 'Bronze Puzzler',
      description:
          'A circular badge icon of interlocking bronze jigsaw puzzle '
          'pieces forming a magnifying glass shape, warm copper tones, '
          'flat vector emblem style',
      category: MarkerSkinCategory.puzzle,
      milestoneTarget: 5,
      color: 0xFFCD7F32,
    ),
    MarkerSkinDesign(
      id: 'silver_puzzler',
      name: 'Silver Puzzler',
      description:
          'A circular badge icon of interlocking silver jigsaw puzzle '
          'pieces forming a magnifying glass shape, cool metallic grey '
          'tones, flat vector emblem style',
      category: MarkerSkinCategory.puzzle,
      milestoneTarget: 15,
      color: 0xFFC0C0C0,
    ),
    MarkerSkinDesign(
      id: 'gold_puzzler',
      name: 'Gold Puzzler',
      description:
          'A circular badge icon of interlocking gold jigsaw puzzle pieces '
          'forming a magnifying glass shape, rich gold tones with a subtle '
          'shine, flat vector emblem style',
      category: MarkerSkinCategory.puzzle,
      milestoneTarget: 30,
      color: 0xFFFFD700,
    ),

    // ---------------- Theme (one per Trip Path theme, real: 10 each) --
    MarkerSkinDesign(
      id: 'food_trailblazer',
      name: 'Food Trailblazer',
      description:
          'A circular badge icon of a satay skewer crossed with chopsticks '
          'over a hawker-stall silhouette, warm red and orange tones, flat '
          'vector emblem style',
      category: MarkerSkinCategory.theme,
      milestoneTarget: 10,
      color: 0xFFE8743B,
      theme: 'Food',
    ),
    MarkerSkinDesign(
      id: 'culture_keeper',
      name: 'Culture Keeper',
      description:
          'A circular badge icon of a wau (traditional Malaysian kite) in '
          'flight over batik-pattern waves, rich violet and gold tones, '
          'flat vector emblem style',
      category: MarkerSkinCategory.theme,
      milestoneTarget: 10,
      color: 0xFF7660D6,
      theme: 'Culture',
    ),
    MarkerSkinDesign(
      id: 'heritage_guardian',
      name: 'Heritage Guardian',
      description:
          'A circular badge icon of a heritage shophouse facade framed by '
          'an ornate archway, deep teal and cream tones, flat vector emblem '
          'style',
      category: MarkerSkinCategory.theme,
      milestoneTarget: 10,
      color: 0xFF267568,
      theme: 'Heritage',
    ),
    MarkerSkinDesign(
      id: 'nature_ranger',
      name: 'Nature Ranger',
      description:
          'A circular badge icon of a rafflesia flower in bloom framed by '
          'palm leaves, deep forest green tones, flat vector emblem style',
      category: MarkerSkinCategory.theme,
      milestoneTarget: 10,
      color: 0xFF2E7D32,
      theme: 'Nature',
    ),
  ];

  /// UC-03 A3 — the default marker's own colour, used when no skin is
  /// equipped at all.
  static const defaultMarkerColor = 0xFF0369A1;
  final SupabaseService supabaseService;
  final GeminiService geminiService;
  final ImageService imageService;
  final PostcardImageService postcardImageService;
  RewardRepository({
    required this.supabaseService,
    required this.geminiService,
    required this.imageService,
    PostcardImageService? postcardImageService,
  }) : postcardImageService = postcardImageService ?? PostcardImageService();

  // Observer pattern (subject side): RewardRepository is the subject,
  // RewardViewModel instances are the observers. A ViewModel attaches
  // itself here (see RewardViewModel's constructor) so that after this
  // repository finishes a business operation — often asynchronous work
  // triggered from a screen the observer isn't even watching — it can
  // notify every attached observer, not just whichever caller happened to
  // be waiting on the returned Future. Multiple observers can be attached
  // at once (e.g. two screens both showing reward state), which a plain
  // return value could never reach.
  final _observers = <RewardObserver>{};
  void attachObserver(RewardObserver observer) =>
      _observers.add(observer);
  void detachObserver(RewardObserver observer) =>
      _observers.remove(observer);

  void _notifyObservers(TouristReward reward) {
    for (final observer in _observers.toList()) {
      if (observer.touristId == reward.touristId) {
        observer.onRewardReady(reward);
      }
    }
  }

  /// Low-stock top-up for a theme's souvenir catalogue — separate from
  /// [getAvailableThemeSouvenirImage]'s own reactive replenish (which only
  /// fires once the catalogue is fully empty, refilling to
  /// [defaultThemeImageTargetQuantity]). This one runs proactively — called
  /// right after an image is assigned — so the catalogue rarely actually
  /// hits zero in the first place.
  static const lowStockThemeImageTargetQuantity = 3;

  Future<void> checkAndReplenishThemeCatalogue({
    required String theme,
    int targetQuantity = lowStockThemeImageTargetQuantity,
  }) async {
    final remaining = await getAvailableThemeImageCount(theme: theme);
    if (remaining < targetQuantity) {
      await replenishThemeSouvenirImages(
        theme: theme,
        targetQuantity: targetQuantity,
      );
    }
  }

  final _listeners = <void Function(RewardEvent)>[];
  void addListener(void Function(RewardEvent) listener) =>
      _listeners.add(listener);
  void removeListener(void Function(RewardEvent) listener) =>
      _listeners.remove(listener);
  void _notify(RewardEventType type, [dynamic data]) {
    for (final listener in List<void Function(RewardEvent)>.of(_listeners)) {
      listener(RewardEvent(type: type, data: data));
    }
  }

  // Serialize related writes. Failed requests release the queue for safe retries.
  final _queues = <String, Future<void>>{};
  Future<T> _serial<T>(String key, Future<T> Function() action) async {
    final previous = _queues[key] ?? Future<void>.value();
    final gate = Completer<void>();
    _queues[key] = gate.future;
    await previous;
    try {
      return await action();
    } finally {
      gate.complete();
      if (identical(_queues[key], gate.future)) _queues.remove(key);
    }
  }

  String _theme(String theme) {
    for (final configured in themes) {
      if (configured.toLowerCase() == theme.trim().toLowerCase()) {
        return configured;
      }
    }
    throw ArgumentError('Choose a configured theme: ${themes.join(", ")}.');
  }

  Future<int> getAvailableThemeImageCount({required String theme}) =>
      supabaseService.getAvailableThemeSouvenirImageCount(theme: _theme(theme));

  Future<ThemeSouvenirImage> getAvailableThemeSouvenirImage({
    required String theme,
    String? questId,
    int targetQuantity = defaultThemeImageTargetQuantity,
  }) {
    final selected = _theme(theme);
    return _serial('catalogue:$selected', () async {
      if (questId != null) {
        final all = await supabaseService.getThemeSouvenirImages(
          theme: selected,
        );
        for (final item in all) {
          if (item['assigned_quest_id'] == questId) {
            return ThemeSouvenirImage.fromMap(item);
          }
        }
      }
      var available = await supabaseService.getAvailableThemeSouvenirImages(
        theme: selected,
      );
      if (available.isEmpty) {
        await _replenish(selected, targetQuantity);
        available = await supabaseService.getAvailableThemeSouvenirImages(
          theme: selected,
        );
      }
      if (available.isEmpty) {
        throw StateError('No Theme Souvenir Image is available. Please retry.');
      }
      final chosen = Map<String, dynamic>.of(available.first);
      await supabaseService.markThemeSouvenirImageUnavailable(
        imageId: chosen['id'] as String,
        questId: questId,
      );
      chosen.addAll({
        'is_available': false,
        'assigned_quest_id': questId,
        'assigned_at': DateTime.now().toIso8601String(),
      });

      // Best-effort, non-blocking — the tourist already has their image
      // above; this just tops the catalogue back up in the background so
      // the NEXT tourist to finish this theme doesn't hit an empty
      // catalogue and pay for a synchronous generation themselves.
      unawaited(
        checkAndReplenishThemeCatalogue(theme: selected).catchError((_) {}),
      );

      return ThemeSouvenirImage.fromMap(chosen);
    });
  }

  Future<void> replenishThemeSouvenirImages({
    required String theme,
    int targetQuantity = defaultThemeImageTargetQuantity,
  }) {
    final selected = _theme(theme);
    return _serial(
      'catalogue:$selected',
      () => _replenish(selected, targetQuantity),
    );
  }

  Future<void> _replenish(String theme, int target) async {
    if (target <= 0) throw ArgumentError('Catalogue target must be positive.');
    var count = await getAvailableThemeImageCount(theme: theme);
    try {
      while (count < target) {
        final url = await geminiService.generateThemeSouvenirImageUrl(
          theme: theme,
        );
        final uri = Uri.tryParse(url);
        if (uri == null ||
            !['mock', 'http', 'https'].contains(uri.scheme) ||
            uri.host.isEmpty) {
          throw StateError('The generated reward image is invalid.');
        }
        await supabaseService.insertThemeSouvenirImage(
          data: {
            'theme': theme,
            'image_url': url,
            'is_available': true,
            'created_at': DateTime.now().toIso8601String(),
            'assigned_quest_id': null,
            'assigned_at': null,
          },
        );
        count = await getAvailableThemeImageCount(theme: theme);
      }
    } catch (e) {
      throw StateError(
        'Catalogue replenishment failed ($count/$target available). Existing images retained. $e',
      );
    }
    for (final observer in _observers.toList()) {
      observer.onCatalogueUpdated(theme, count);
    }
    _notify(RewardEventType.themeCatalogueReplenished, {
      'theme': theme,
      'available': count,
    });
  }

  Future<List<TouristReward>> getRewardsForTourist(String touristId) async =>
      (await supabaseService.getRewardsForTourist(
        touristId,
      )).map(TouristReward.fromMap).toList();

  Future<TouristReward> getRewardById({
    required String touristId,
    required String rewardId,
  }) async => TouristReward.fromMap(
    await supabaseService.getRewardById(touristId, rewardId),
  );

  Future<TouristReward> generateDigitalTravelStamp({
    required String touristId,
    required String completionId,
    required String hiddenPlaceId,
    required String hiddenPlaceName,
    required String township,
    required String verifiedPhotoUrl,
    required DateTime completionDate,
    required bool visitVerified,
  }) => _serial('stamp:$touristId:$completionId', () async {
    if (!visitVerified ||
        [
          touristId,
          completionId,
          hiddenPlaceId,
          hiddenPlaceName,
          township,
        ].any((v) => v.trim().isEmpty)) {
      throw StateError(
        'Digital Travel Stamp source information is incomplete or unverified.',
      );
    }
    final existing = await supabaseService.findReward(
      touristId,
      RewardType.digitalTravelStamp.name,
      completionId,
    );
    if (existing != null) {
      final reward = TouristReward.fromMap(existing);
      _notifyObservers(reward);
      return reward;
    }
    final frameUrl = await _randomStampFrameUrl();
    final representation = await imageService.composeDigitalTravelStamp(
      verifiedPhotoUrl: verifiedPhotoUrl,
      hiddenPlaceName: hiddenPlaceName,
      township: township,
      completionDate: completionDate,
      frameUrl: frameUrl,
    );
    final reward = TouristReward(
      id: 'stamp:${Uri.encodeComponent(touristId)}:${Uri.encodeComponent(completionId)}',
      touristId: touristId,
      sourceId: completionId,
      imageUrl: representation,
      type: RewardType.digitalTravelStamp,
      status: RewardStatus.earned,
      completedAt: completionDate,
      earnedAt: completionDate,
      hiddenPlaceId: hiddenPlaceId,
      hiddenPlaceName: hiddenPlaceName,
      township: township,
      verifiedPhotoUrl: verifiedPhotoUrl,
    );
    final saved = TouristReward.fromMap(
      await supabaseService.insertReward(reward.toMap()),
    );
    _notifyObservers(saved);
    _notify(RewardEventType.digitalTravelStampGenerated, saved);
    return saved;
  });

  /// One-time repair for Puzzle sessions that reached game_sessions.status
  /// = 'Completed' without ever getting their Digital Travel Stamp created
  /// — possible before saveVisitVerifiedAndCompleteGame() was fixed to
  /// generate the stamp *before* flipping the session to Completed (a
  /// stamp-generation failure used to leave the session stuck "Completed"
  /// with no stamp and no way to retry). Safe to call on every Rewards page
  /// load: cheap when there's nothing to fix, and generateDigitalTravelStamp
  /// is idempotent per session id, so re-running this against sessions that
  /// already have their stamp is a no-op. Returns how many were (re)created.
  Future<int> backfillMissingDigitalTravelStamps(String touristId) async {
    if (touristId.trim().isEmpty) return 0;

    final sessions = await supabaseService.getCompletedVisitVerifiedGameSessions(
      touristId,
    );
    if (sessions.isEmpty) return 0;

    final existing = await supabaseService.getRewardsForTourist(touristId);
    final existingSessionIds = existing
        .where((r) => r['type'] == RewardType.digitalTravelStamp.name)
        .map((r) => r['source_id'] as String?)
        .whereType<String>()
        .toSet();

    var repaired = 0;
    for (final session in sessions) {
      final sessionId = '${session['id'] ?? ''}';
      if (sessionId.isEmpty || existingSessionIds.contains(sessionId)) {
        continue;
      }

      final photoUrl = session['verified_tourist_photo_url'] as String?;
      final hiddenPlaceId = session['hidden_place_id'] as String?;
      final hiddenPlaceName = session['hidden_place_name'] as String?;
      final township = session['township'] as String?;
      if (photoUrl == null ||
          photoUrl.isEmpty ||
          hiddenPlaceId == null ||
          hiddenPlaceName == null) {
        continue; // Too old/incomplete a row to reconstruct a stamp from.
      }
      final completionDate = session['completion_date'] != null
          ? DateTime.tryParse('${session['completion_date']}') ??
                DateTime.now()
          : DateTime.now();

      try {
        await generateDigitalTravelStamp(
          touristId: touristId,
          completionId: sessionId,
          hiddenPlaceId: hiddenPlaceId,
          hiddenPlaceName: hiddenPlaceName,
          township: township ?? 'Nearby',
          verifiedPhotoUrl: photoUrl,
          completionDate: completionDate,
          visitVerified: true,
        );
        repaired++;
      } catch (_) {
        // Leave this one for the next attempt (e.g. next Rewards page visit).
      }
    }
    return repaired;
  }

  /// Same repair as [backfillMissingDigitalTravelStamps], for Trip Path's
  /// Theme Souvenirs: storeCompletedThemeSouvenir is fired-and-forgotten
  /// right after a quest's final checkpoint is saved (see
  /// TripPathQuestViewModel._completeCheckpoint), so a transient failure
  /// there (network blip, Supabase hiccup) can leave a genuinely completed
  /// quest with no Theme Souvenir reward and no way to retry on its own.
  /// Safe to call on every Rewards page load: cheap when there's nothing to
  /// fix, and storeCompletedThemeSouvenir is idempotent per quest id, so
  /// re-running this against quests that already have their souvenir is a
  /// no-op. Returns how many were (re)created.
  Future<int> backfillMissingThemeSouvenirs(String touristId) async {
    if (touristId.trim().isEmpty) return 0;

    final quests = await supabaseService.getCompletedTripPathQuests(
      touristId,
    );
    if (quests.isEmpty) return 0;

    final existing = await supabaseService.getRewardsForTourist(touristId);
    final existingQuestIds = existing
        .where((r) => r['type'] == RewardType.themeSouvenir.name)
        .map((r) => r['source_id'] as String?)
        .whereType<String>()
        .toSet();

    var repaired = 0;
    for (final quest in quests) {
      final questId = '${quest['id'] ?? ''}'.trim();
      if (questId.isEmpty || existingQuestIds.contains(questId)) {
        continue;
      }

      final theme = '${quest['theme_name'] ?? ''}'.trim();
      final artworkId = '${quest['artwork_id'] ?? ''}'.trim();
      final completedCheckpoints = quest['completed_checkpoints'] as int?;
      final totalCheckpoints = quest['total_checkpoints'] as int?;
      final completedAtRaw = quest['completed_at'] as String?;
      if (theme.isEmpty ||
          artworkId.isEmpty ||
          completedCheckpoints == null ||
          totalCheckpoints == null ||
          completedCheckpoints != totalCheckpoints ||
          completedAtRaw == null) {
        continue; // Too old/incomplete a row to reconstruct a souvenir from.
      }

      try {
        final imageUrl = await supabaseService.getThemeArtworkImageUrl(
          artworkId,
        );
        if (imageUrl == null) continue; // Artwork itself is gone.
        await storeCompletedThemeSouvenir(
          touristId: touristId,
          questId: questId,
          theme: theme,
          imageUrl: imageUrl,
          completedCheckpoints: completedCheckpoints,
          totalCheckpoints: totalCheckpoints,
          completedAt: DateTime.tryParse(completedAtRaw) ?? DateTime.now(),
        );
        repaired++;
      } catch (_) {
        // Leave this one for the next attempt (e.g. next Rewards page visit).
      }
    }
    return repaired;
  }

  final _frameRandom = Random();

  /// Picks one Digital Travel Stamp frame at random from the hand-seeded
  /// `stamp_frames` table. Frames are never consumed — the same row can be
  /// (and is meant to be) reused across every tourist's stamp.
  Future<String> _randomStampFrameUrl() async {
    final frames = await supabaseService.getStampFrames();
    if (frames.isEmpty) {
      throw StateError('No Digital Travel Stamp frames are configured.');
    }
    final chosen = frames[_frameRandom.nextInt(frames.length)];
    return chosen['image_url'] as String;
  }

  /// Called after Trip Path has stored its final result. No image generation or recolouring.
  Future<TouristReward> storeCompletedThemeSouvenir({
    required String touristId,
    required String questId,
    required String theme,
    required String imageUrl,
    required int completedCheckpoints,
    required int totalCheckpoints,
    required DateTime completedAt,
  }) => _serial('theme-reward:$touristId:$questId', () async {
    if (touristId.trim().isEmpty ||
        questId.trim().isEmpty ||
        imageUrl.trim().isEmpty ||
        totalCheckpoints <= 0 ||
        completedCheckpoints != totalCheckpoints) {
      throw StateError(
        'The quest must have a complete stored image and final progress.',
      );
    }
    final selected = _theme(theme);
    final previous = await supabaseService.findReward(
      touristId,
      RewardType.themeSouvenir.name,
      questId,
    );
    if (previous != null) {
      final reward = TouristReward.fromMap(previous);
      _notifyObservers(reward);
      return reward;
    }
    final reward = TouristReward(
      id: 'theme:${Uri.encodeComponent(touristId)}:${Uri.encodeComponent(questId)}',
      touristId: touristId,
      sourceId: questId,
      imageUrl: imageUrl,
      type: RewardType.themeSouvenir,
      status: RewardStatus.readyToClaim,
      completedAt: completedAt,
      theme: selected,
      completedCheckpoints: completedCheckpoints,
      totalCheckpoints: totalCheckpoints,
    );
    final saved = TouristReward.fromMap(
      await supabaseService.insertReward(reward.toMap()),
    );
    _notifyObservers(saved);
    _notify(RewardEventType.themeSouvenirReady, saved);
    return saved;
  });

  Future<TouristReward> getCompletedThemeSouvenir({
    required String touristId,
    required String questId,
  }) async {
    final data = await supabaseService.findReward(
      touristId,
      RewardType.themeSouvenir.name,
      questId,
    );
    if (data == null) {
      throw StateError('Completed Theme Souvenir cannot be retrieved.');
    }
    return TouristReward.fromMap(data);
  }

  Future<TouristReward> claimThemeSouvenir({
    required String touristId,
    required String rewardId,
  }) => _serial('claim:$rewardId', () async {
    final reward = await getRewardById(
      touristId: touristId,
      rewardId: rewardId,
    );
    if (reward.type != RewardType.themeSouvenir ||
        reward.totalCheckpoints == null ||
        reward.completedCheckpoints != reward.totalCheckpoints) {
      throw StateError('Only a completed Theme Souvenir can be claimed.');
    }
    if (reward.status == RewardStatus.earned) return reward;
    final saved = TouristReward.fromMap(
      await supabaseService.updateRewardStatus(
        touristId,
        rewardId,
        RewardStatus.earned.name,
        DateTime.now(),
      ),
    );
    _notifyObservers(saved);
    _notify(RewardEventType.rewardDataChanged, saved);
    return saved;
  });

  /// UC-06 A3 — unlocks [designId] for [touristId]. The caller (wherever
  /// game-completion progress is actually tracked — outside this
  /// repository's concern) decides *when* a milestone is met and calls
  /// this; RewardRepository only handles what happens once it is: create
  /// the Earned reward record (C5: never award the same design twice —
  /// idempotent, returns the existing record if already owned).
  ///
  /// No image is generated here — by explicit request, Marker Skins use a
  /// fixed, hand-picked icon per design (see marker_skins.dart's
  /// `_designIcon`) instead of an AI-generated one, so unlocking is a plain
  /// database write with no network/AI call and nothing that can fail due
  /// to image-generation quota. `imageUrl` is set to a stable, non-http
  /// sentinel purely so it's still a meaningful, greppable value in the
  /// database; the UI never tries to load it as a real image (see
  /// marker_skins.dart's `_skinThumb`, which always renders the design's
  /// icon for this reward type).
  Future<TouristReward> unlockMarkerSkin({
    required String touristId,
    required String designId,
  }) => _serial('skin:$touristId:$designId', () async {
    final design = markerSkinDesigns.where((d) => d.id == designId);
    if (design.isEmpty) {
      throw ArgumentError('Unknown Explorer Marker Skin design: $designId');
    }
    final existing = await supabaseService.findReward(
      touristId,
      RewardType.explorerMarkerSkin.name,
      designId,
    );
    if (existing != null) {
      final reward = TouristReward.fromMap(existing);
      _notifyObservers(reward);
      return reward;
    }
    final now = DateTime.now();
    final reward = TouristReward(
      id: 'skin:${Uri.encodeComponent(touristId)}:${Uri.encodeComponent(designId)}',
      touristId: touristId,
      sourceId: designId,
      imageUrl: 'icon://$designId',
      type: RewardType.explorerMarkerSkin,
      status: RewardStatus.earned,
      completedAt: now,
      earnedAt: now,
    );
    final saved = TouristReward.fromMap(
      await supabaseService.insertReward(reward.toMap()),
    );
    _notifyObservers(saved);
    _notify(RewardEventType.rewardDataChanged, saved);
    return saved;
  });

  /// UC-06 A3-1 — equips an already-Earned skin as the tourist's map
  /// marker, un-equipping whatever they had equipped before (C7).
  ///
  /// Notifies the observer about BOTH the newly-equipped reward and
  /// whichever one it replaced: notifying only the new one left the old
  /// one's stale isEquipped=true sitting in the ViewModel's in-memory
  /// list forever (the database itself was always correct — this was a
  /// client-side sync bug, not two rows really equipped at once).
  Future<TouristReward> equipMarkerSkinReward({
    required String touristId,
    required String rewardId,
  }) => _serial('equip-skin:$touristId', () async {
    final reward = await getRewardById(
      touristId: touristId,
      rewardId: rewardId,
    );
    if (reward.type != RewardType.explorerMarkerSkin ||
        reward.status != RewardStatus.earned) {
      throw StateError('Only an Earned Explorer Marker Skin can be equipped.');
    }
    final previouslyEquipped = await getEquippedMarkerSkin(
      touristId: touristId,
    );
    await supabaseService.setEquippedMarkerSkin(
      touristId: touristId,
      rewardId: rewardId,
    );
    final updated = await getRewardById(
      touristId: touristId,
      rewardId: rewardId,
    );
    if (previouslyEquipped != null && previouslyEquipped.id != updated.id) {
      final nowUnequipped = await getRewardById(
        touristId: touristId,
        rewardId: previouslyEquipped.id,
      );
      _notifyObservers(nowUnequipped);
    }
    _notifyObservers(updated);
    _notify(RewardEventType.rewardDataChanged, updated);
    return updated;
  });

  /// UC-03 A3 — clears whatever is equipped, reverting the map marker to
  /// its original default appearance. A no-op (no error) if nothing was
  /// equipped to begin with.
  Future<void> unequipMarkerSkin({required String touristId}) =>
      _serial('equip-skin:$touristId', () async {
        final previouslyEquipped = await getEquippedMarkerSkin(
          touristId: touristId,
        );
        if (previouslyEquipped == null) return;
        await supabaseService.clearEquippedMarkerSkin(touristId: touristId);
        final nowUnequipped = await getRewardById(
          touristId: touristId,
          rewardId: previouslyEquipped.id,
        );
        _notifyObservers(nowUnequipped);
        _notify(RewardEventType.rewardDataChanged, nowUnequipped);
      });

  /// UC-03 C6 — the skin View Map should render as the tourist's
  /// current-location marker, or null if none is equipped.
  Future<TouristReward?> getEquippedMarkerSkin({
    required String touristId,
  }) async {
    final row = await supabaseService.getEquippedMarkerSkin(touristId);
    return row == null ? null : TouristReward.fromMap(row);
  }

  Future<DigitalPostcard> savePostcard({
    required String touristId,
    required String backgroundType,
    required int backgroundColor,
    required List<String> selectedRewardIds,
    required String message,
  }) async {
    if (touristId.trim().isEmpty ||
        !['Template', 'Blank Canvas'].contains(backgroundType)) {
      throw ArgumentError('Choose a supported postcard background.');
    }
    if (message.length > 500) {
      throw ArgumentError('Use at most 500 characters.');
    }
    for (final id in selectedRewardIds.toSet()) {
      final reward = await getRewardById(touristId: touristId, rewardId: id);
      if (!reward.postcardEligible) {
        throw StateError('Only your Earned rewards can be added.');
      }
    }
    // TODO: export postcard composition as actual image in final implementation.
    final card = DigitalPostcard(
      id: 'postcard_${DateTime.now().microsecondsSinceEpoch}',
      touristId: touristId,
      backgroundType: backgroundType,
      backgroundColor: backgroundColor,
      selectedRewardIds: List.unmodifiable(selectedRewardIds.toSet()),
      message: message,
      createdAt: DateTime.now(),
    );
    await supabaseService.insertPostcard(card.toMap());
    for (final observer in _observers.toList()) {
      if (observer.touristId == touristId) observer.onPostcardSaved(card);
    }
    _notify(RewardEventType.rewardDataChanged);
    return card;
  }

  Future<List<DigitalPostcard>> getPostcards(String touristId) async =>
      (await supabaseService.getPostcards(
        touristId,
      )).map(DigitalPostcard.fromMap).toList();

  Future<void> deletePostcard({
    required String touristId,
    required String postcardId,
  }) async {
    await supabaseService.deletePostcard(
      touristId: touristId,
      postcardId: postcardId,
    );
    _notify(RewardEventType.rewardDataChanged);
  }

  Future<String?> pickPostcardBackground() =>
      postcardImageService.pickBackground();

  Future<List<TouristReward>> getPostcardEligibleRewards(
    String touristId,
  ) async => (await getRewardsForTourist(
    touristId,
  )).where((r) => r.postcardEligible).toList();

  /// All ownership, eligibility and persistence rules remain in the repository.
  Future<DigitalPostcard> savePostcardDesign({
    required String touristId,
    required PostcardDesign design,
    String? postcardId,
    Future<Uint8List> Function()? render,
  }) => _serial('postcard:$touristId', () async {
    await validatePostcardDesign(touristId, design);
    DateTime createdAt = DateTime.now();
    if (postcardId != null) {
      final existing = (await getPostcards(
        touristId,
      )).where((c) => c.id == postcardId);
      if (existing.isEmpty) {
        throw StateError('Postcard not found for this tourist.');
      }
      createdAt = existing.first.createdAt;
    }
    final preview = render == null
        ? null
        : await postcardImageService.encodePreview(await render());
    final card = DigitalPostcard(
      id:
          postcardId ??
          'postcard_${DateTime.now().microsecondsSinceEpoch}',
      touristId: touristId,
      backgroundType: design.backgroundType,
      backgroundColor: design.backgroundColor,
      selectedRewardIds: design.rewardIds,
      message: design.elements
          .where((e) => e.type == PostcardElementType.text)
          .map((e) => e.content)
          .join(' '),
      createdAt: createdAt,
      design: PostcardDesign.fromMap(design.toMap()),
      previewImage: preview,
    );
    await supabaseService.insertPostcard(card.toMap());
    for (final observer in _observers.toList()) {
      if (observer.touristId == touristId) observer.onPostcardSaved(card);
    }
    return card;
  });

  Future<void> validatePostcardDesign(
    String touristId,
    PostcardDesign design,
  ) async {
    if (touristId.trim().isEmpty ||
        ![
          'Template',
          'Blank Canvas',
          'Phone Image',
          'Reward Image',
        ].contains(design.backgroundType)) {
      throw StateError('Choose a valid postcard background.');
    }
    if (![
      'tropical',
      'sunset',
      'heritage',
      'plain',
    ].contains(design.template)) {
      throw StateError('Unknown postcard template.');
    }
    if (design.backgroundType == 'Phone Image') {
      final source = design.backgroundImage ?? '';
      if (!source.startsWith('data:image/png;base64,') ||
          source.length > 20 * 1024 * 1024) {
        throw StateError('Choose a valid phone image.');
      }
      await postcardImageService.encodePreview(
        base64Decode(source.split(',').last),
      );
    }
    if (design.backgroundType == 'Reward Image' &&
        design.backgroundRewardId == null) {
      throw StateError('Choose an Earned reward for this background.');
    }
    if (design.elements.length > 40) {
      throw StateError('Use up to 40 elements per postcard.');
    }
    final ids = <String>{};
    for (final e in design.elements) {
      if (!ids.add(e.id) || e.id.isEmpty) {
        throw StateError('Duplicate or missing element identifier.');
      }
      if ([e.x, e.y, e.width, e.height, e.rotation].any((n) => !n.isFinite) ||
          e.x < 0 ||
          e.x > 1 ||
          e.y < 0 ||
          e.y > 1 ||
          e.width < .04 ||
          e.width > 1 ||
          e.height < .04 ||
          e.height > 1 ||
          e.rotation.abs() > 6.284) {
        throw StateError('An element has an invalid position or size.');
      }
      if (e.type == PostcardElementType.text &&
          (e.content.trim().isEmpty || e.content.length > 500)) {
        throw StateError('Text must contain 1 to 500 characters.');
      }
      if (e.type == PostcardElementType.sticker &&
          ![
            'flower',
            'sun',
            'heart',
            'star',
            'leaf',
            'sparkle',
            'tape',
            'ticket',
          ].contains(e.content)) {
        throw StateError('Unknown decoration.');
      }
    }
    for (final id in design.rewardIds) {
      final reward = await getRewardById(touristId: touristId, rewardId: id);
      if (!reward.postcardEligible) {
        throw StateError('Only your Earned rewards can decorate a postcard.');
      }
    }
  }
}
