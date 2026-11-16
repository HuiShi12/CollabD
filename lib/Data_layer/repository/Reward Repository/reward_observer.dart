import 'reward_models.dart';

/// The Observer-pattern contract for this module: RewardRepository (the
/// subject) holds a set of attached RewardObservers and notifies them
/// after each business operation commits, so a ViewModel finds out about
/// state it didn't directly cause — e.g. a catalogue replenishing in the
/// background, or a different screen's action affecting a reward this
/// ViewModel is also displaying. RewardViewModel implements this.
///
/// The interface lives in the Data layer and only depends on reward_models
/// (also Data layer) — RewardRepository never imports RewardViewModel or
/// anything from UI_layer. That's what keeps this a real dependency
/// inversion rather than the data layer reaching into the UI layer:
/// RewardRepository only knows about a contract it defines itself.
abstract interface class RewardObserver {
  String get touristId;
  void onRewardReady(TouristReward reward);
  void onCatalogueUpdated(String theme, int available);
  void onPostcardSaved(DigitalPostcard postcard);
}
