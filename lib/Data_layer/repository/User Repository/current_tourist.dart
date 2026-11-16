import 'package:supabase_flutter/supabase_flutter.dart';

/// The signed-in tourist's real identity, used everywhere a Reward/Puzzle/
/// Trip Path record needs to be tied to an owner.
///
/// Was previously a hardcoded `'tourist_001'` shared by every account — every
/// signed-in user's rewards, stamps and marker skins were reading/writing the
/// exact same rows. [id] now resolves to the real Supabase Auth user id,
/// re-read on every access (never cached) so it always reflects whoever is
/// currently logged in, not whoever was logged in when some object holding
/// this value happened to be constructed.
class CurrentTourist {
  /// Falls back to the old demo id only when nothing is signed in yet (e.g.
  /// a widget building for a brief instant before the auth check completes).
  /// Reachable screens that use this are all behind login, so this fallback
  /// is not expected to be exercised in practice.
  static String get id =>
      Supabase.instance.client.auth.currentUser?.id ?? 'tourist_001';
}
