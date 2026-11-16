/// RewardRepository publishes events; ViewModels subscribe without a constructor cycle.
enum RewardEventType {
  themeCatalogueReplenished,
  digitalTravelStampGenerated,
  themeSouvenirReady,
  rewardDataChanged,
}

class RewardEvent {
  final RewardEventType type;
  final dynamic data;
  RewardEvent({required this.type, this.data});
}
