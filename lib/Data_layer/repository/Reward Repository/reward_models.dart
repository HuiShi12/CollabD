import 'postcard_models.dart';
export 'postcard_models.dart';

enum RewardType { digitalTravelStamp, themeSouvenir, explorerMarkerSkin }

enum RewardStatus { readyToClaim, earned }

class TouristReward {
  final String id, touristId, sourceId, imageUrl;
  final RewardType type;
  final RewardStatus status;
  final DateTime completedAt;
  final DateTime? earnedAt;
  final String? hiddenPlaceId,
      hiddenPlaceName,
      township,
      verifiedPhotoUrl,
      theme;
  final int? completedCheckpoints, totalCheckpoints;
  /// Only meaningful for [RewardType.explorerMarkerSkin] — whether this is
  /// the tourist's currently-equipped map marker (UC-06 A3-1). At most one
  /// skin per tourist should have this true; RewardRepository enforces that
  /// when equipping.
  final bool isEquipped;
  const TouristReward({
    required this.id,
    required this.touristId,
    required this.sourceId,
    required this.imageUrl,
    required this.type,
    required this.status,
    required this.completedAt,
    this.earnedAt,
    this.hiddenPlaceId,
    this.hiddenPlaceName,
    this.township,
    this.verifiedPhotoUrl,
    this.theme,
    this.completedCheckpoints,
    this.totalCheckpoints,
    this.isEquipped = false,
  });
  String get title => switch (type) {
    RewardType.digitalTravelStamp => '${hiddenPlaceName ?? "Travel"} Stamp',
    RewardType.themeSouvenir => '${theme ?? "Theme"} Souvenir',
    // sourceId is the design id (e.g. 'bronze_explorer') — snake_case is
    // titled here as a readable default; MarkerSkinDesign.name in
    // RewardRepository is the source of truth once UI looks it up there.
    RewardType.explorerMarkerSkin => sourceId
        .split('_')
        .map((w) => w.isEmpty ? w : '${w[0].toUpperCase()}${w.substring(1)}')
        .join(' '),
  };
  String get statusLabel =>
      status == RewardStatus.earned ? 'Earned' : 'Ready to claim';
  bool get postcardEligible =>
      status == RewardStatus.earned && type != RewardType.explorerMarkerSkin;
  Map<String, dynamic> toMap() => {
    'id': id,
    'tourist_id': touristId,
    'source_id': sourceId,
    'image_url': imageUrl,
    'type': type.name,
    'status': status.name,
    'completed_at': completedAt.toIso8601String(),
    'earned_at': earnedAt?.toIso8601String(),
    'hidden_place_id': hiddenPlaceId,
    'hidden_place_name': hiddenPlaceName,
    'township': township,
    'verified_photo_url': verifiedPhotoUrl,
    'theme': theme,
    'completed_checkpoints': completedCheckpoints,
    'total_checkpoints': totalCheckpoints,
    'is_equipped': isEquipped,
  };
  factory TouristReward.fromMap(Map<String, dynamic> m) => TouristReward(
    id: m['id'] as String,
    touristId: m['tourist_id'] as String,
    sourceId: m['source_id'] as String,
    imageUrl: m['image_url'] as String,
    type: RewardType.values.byName(m['type'] as String),
    status: RewardStatus.values.byName(m['status'] as String),
    completedAt: DateTime.parse(m['completed_at'] as String),
    earnedAt: m['earned_at'] == null
        ? null
        : DateTime.parse(m['earned_at'] as String),
    hiddenPlaceId: m['hidden_place_id'] as String?,
    hiddenPlaceName: m['hidden_place_name'] as String?,
    township: m['township'] as String?,
    verifiedPhotoUrl: m['verified_photo_url'] as String?,
    theme: m['theme'] as String?,
    completedCheckpoints: m['completed_checkpoints'] as int?,
    totalCheckpoints: m['total_checkpoints'] as int?,
    isEquipped: m['is_equipped'] as bool? ?? false,
  );
}

class DigitalPostcard {
  final PostcardDesign? design;
  final String? previewImage;
  final String id, touristId, backgroundType, message;
  final int backgroundColor;
  final List<String> selectedRewardIds;
  final DateTime createdAt;
  const DigitalPostcard({
    required this.id,
    required this.touristId,
    required this.backgroundType,
    required this.backgroundColor,
    required this.message,
    required this.selectedRewardIds,
    required this.createdAt,
    this.design,
    this.previewImage,
  });
  Map<String, dynamic> toMap() => {
    'id': id,
    'tourist_id': touristId,
    'design': design?.toMap(),
    'preview_image': previewImage,
    'background_type': backgroundType,
    'background_color': backgroundColor,
    'message': message,
    'selected_reward_ids': selectedRewardIds.toList(),
    'created_at': createdAt.toIso8601String(),
  };
  factory DigitalPostcard.fromMap(Map<String, dynamic> m) => DigitalPostcard(
    design: m['design'] == null
        ? null
        : PostcardDesign.fromMap(Map<String, dynamic>.from(m['design'] as Map)),
    previewImage: m['preview_image'] as String?,
    id: m['id'] as String,
    touristId: m['tourist_id'] as String,
    backgroundType: m['background_type'] as String,
    backgroundColor: m['background_color'] as int,
    message: m['message'] as String,
    selectedRewardIds: List<String>.unmodifiable(
      m['selected_reward_ids'] as List,
    ),
    createdAt: DateTime.parse(m['created_at'] as String),
  );
}
