class NavigationService {
  Map<String, dynamic> buildNavigationData({
    required int distanceMeter,
    required String direction,
  }) {
    final bool withinVerificationRange = distanceMeter <= 50;

    return {
      'distance_meter': distanceMeter,
      'direction': direction,
      'within_verification_range': withinVerificationRange,
      'remaining_meter': withinVerificationRange ? 0 : distanceMeter - 50,
      'remaining_message': withinVerificationRange
          ? 'You have arrived at the mystery location.'
          : 'Keep walking — ${distanceMeter - 50}m more to unlock verification.',
    };
  }
}