import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:google_generative_ai/google_generative_ai.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

/// Result of [GeminiApiExternal.screenLandmarkPhoto].
class LandmarkPhotoScreening {
  final bool isEligible;
  final bool hasLandmarkSign;

  const LandmarkPhotoScreening({
    required this.isEligible,
    required this.hasLandmarkSign,
  });
}
/// Gateway to the Gemini API (UC-04 AI Assistant, UC-05 landmark check /
/// clues, UC-06 reward-image descriptions).
///
/// Supply the key at run time and never commit it:
///   flutter run --dart-define=GEMINI_API_KEY=YOUR_KEY
/// Without a key the real calls throw; [GeminiService] catches them and falls
/// back, and [compareLandmarkPhotos] returns `true` so the Puzzle flow keeps
/// working offline.
///
/// Theme Souvenir image generation does NOT use Gemini — gemini-2.5-
/// flash-image needs a billing-enabled Google Cloud project, which this
/// app's free-tier key doesn't have. [generateThemeSouvenirImageUrl] calls
/// Pollinations.ai instead (see [_generateImageBytes]): a free, keyless
/// text-to-image API, chosen so unique per-theme artwork doesn't require
/// anyone to enable billing. Marker Skins don't generate images at all
/// anymore (see RewardRepository.unlockMarkerSkin) — those use a fixed,
/// hand-picked icon per design instead, by explicit request, since the
/// tourist wants something deterministic rather than another AI call.
class GeminiApiExternal {
  int _themeImageGenerationCounter = 0;

  static const String _apiKey = String.fromEnvironment('GEMINI_API_KEY');

  // Operational backup keys — a COMMA-SEPARATED list (dart_defines.json
  // holds several, one per backup Google Cloud project), not a single key.
  // The free tier's daily quota (500 requests) is shared across every
  // feature in this file (chat, appropriateness check, photo verification,
  // clue/description generation), so it's easy to exhaust from normal
  // testing/use alone. When a key fails (quota, rate limit, auth), every
  // call below moves on to the next configured key instead of surfacing an
  // error while only the first is exhausted. Mirrors Trip Path Quest's own
  // GeminiApi, which already does this over raw REST.
  static const String _backupApiKeys =
      String.fromEnvironment('GEMINI_API_KEY_BACKUP');

  static List<String> get _allKeys {
    final keys = <String>[];
    if (_apiKey.trim().isNotEmpty) keys.add(_apiKey.trim());
    for (final raw in _backupApiKeys.split(',')) {
      final key = raw.trim();
      if (key.isNotEmpty && !keys.contains(key)) keys.add(key);
    }
    return keys;
  }

  bool get hasApiKey => _allKeys.isNotEmpty;

  final Map<String, GenerativeModel> _clients = {};

  // A key that just failed (almost always a quota/rate-limit hit — the free
  // tier resets on the order of a minute, not instantly) is very likely to
  // fail again immediately. Without this, every single call re-pays for
  // that same failed round-trip on every already-exhausted key before
  // reaching a working one — this is why photo screening/chat felt "ok
  // sometimes, slow other times": pure luck of which keys happened to be
  // cooling down at that moment. Skipping recently-failed keys for a short
  // window fixes that without changing the actual failover guarantee (a
  // call still always has somewhere to go — see the `fresh.isEmpty`
  // fallback below).
  final Map<String, DateTime> _keyCooldownUntil = {};
  static const _keyCooldown = Duration(seconds: 90);

  GenerativeModel _clientFor(String apiKey) => _clients[apiKey] ??=
      GenerativeModel(
        // Alias — always resolves to the current Flash-Lite model. Lite keeps
        // responses fast (the full Flash alias now points to a slow "thinking"
        // model) and survives Google retiring older versions like gemini-2.5-flash.
        model: 'gemini-flash-lite-latest',
        apiKey: apiKey,
        generationConfig: GenerationConfig(
          temperature: 0.7,
          maxOutputTokens: 800,
          topP: 0.95,
          topK: 64,
        ),
      );

  /// Tries every configured key in order (primary, then each backup) until
  /// one succeeds. A quota/rate-limit hit on one key is the common case, but
  /// this doesn't try to distinguish that from other failures — a wasted
  /// call on a genuinely bad request is cheap compared to an avoidable
  /// outage while only the first key is exhausted. Keys that failed
  /// recently are tried last (see [_keyCooldownUntil]), so a call doesn't
  /// keep re-paying for the same known-bad keys' round-trips.
  Future<GenerateContentResponse> _generateWithFailover(
    Iterable<Content> content,
  ) async {
    final allKeys = _allKeys;
    if (allKeys.isEmpty) {
      throw Exception('GEMINI_API_KEY is not configured.');
    }

    final now = DateTime.now();
    final fresh = allKeys
        .where(
          (k) => !(_keyCooldownUntil[k]?.isAfter(now) ?? false),
        )
        .toList();
    // If every key is currently cooling down, still try them all — a
    // stale cooldown must never turn into a hard failure.
    final keys = fresh.isNotEmpty ? fresh : allKeys;

    for (var i = 0; i < keys.length; i++) {
      try {
        final response = await _clientFor(keys[i])
            .generateContent(content)
            .timeout(const Duration(seconds: 20));
        _keyCooldownUntil.remove(keys[i]);
        return response;
      } catch (e) {
        _keyCooldownUntil[keys[i]] = now.add(_keyCooldown);
        if (i == keys.length - 1) rethrow;
        debugPrint(
          '[gemini] key ${i + 1}/${keys.length} failed ($e) — '
          'trying next key',
        );
      }
    }

    // Unreachable — the loop above always returns or rethrows on the last
    // key — but required so every path returns a value.
    throw Exception('Gemini request failed on all configured keys.');
  }

  // ---------- Core: Generate Text ----------
  Future<String> generateText(String prompt) async {
    if (!hasApiKey) {
      throw Exception('GEMINI_API_KEY is not configured.');
    }
    try {
      final response = await _generateWithFailover([Content.text(prompt)]);
      return response.text?.trim() ?? 'No response generated.';
    } catch (e) {
      throw Exception('Failed to generate response: $e');
    }
  }

  // ---------- UC-04: Chat with AI (Strict Accuracy) ----------
  Future<String> chatWithAI({
    required String question,
    required String currentArea,
    String additionalContext = '',
  }) async {
    final prompt = '''
You are a strict and honest tourism assistant for Malaysia.
Location: $currentArea

${additionalContext.isNotEmpty ? 'REAL DATA from Google Places API:\n$additionalContext' : ''}

RULES:
1. ${additionalContext.isNotEmpty ? 'Use the REAL DATA above to answer accurately. If the user asks for something not listed, say it is not in the list.' : 'If you don\'t have specific information, say "I don\'t have specific information about that in $currentArea."'}
2. NEVER invent names, addresses, phone numbers, or operating hours.
3. Keep responses under 150 words.
4. DO NOT include any meta-commentary, word count checks, formatting instructions, or internal reasoning in your response. Just give the answer directly.
5. Format the response as a clean, readable list if applicable.
6. The app-provided Location is authoritative. A statement about a future,
   planned, hypothetical, or third-party trip does not change it. Never provide
   recommendations for another area or country until the app-provided Location
   itself changes there.

Question: $question
Your response:
''';
    return await generateText(prompt);
  }

  // ---------- UC-04: Inappropriate Content Check ----------
  Future<bool> isAppropriate(String question) async {
    try {
      final prompt = '''
Is this question appropriate for a tourism assistant?
Question: $question
Respond with ONLY "yes" or "no".
''';
      final response = await generateText(prompt);
      return response.trim().toLowerCase() == 'yes';
    } catch (e) {
      const banned = [
        'hack', 'illegal', 'drugs', 'violence', 'crime', 'exploit',
        'kill', 'terror', 'weapon', 'porn', 'sex', 'gambling'
      ];
      return !banned.any((word) => question.toLowerCase().contains(word));
    }
  }

  // ---------- UC-03/UC-05: Same Real-World Site Check ----------
  /// Used only as a fallback when the free name/distance heuristic in
  /// `dedupeSameSitePlaces` (gm.dart) can't confidently tell whether two
  /// nearby Google Place entries (e.g. "KLCC Photo Point" vs. "Tower 1
  /// Petronas Twin Towers") are sub-entries of the SAME real-world landmark.
  /// A single short text-only call, not vision — cheap relative to the
  /// per-photo vision screening already happening. Fails closed (`false`,
  /// i.e. "treat as different places") on any error so an API hiccup never
  /// merges two genuinely distinct places into one.
  Future<bool> areSameRealWorldSite({
    required String nameA,
    required String addressA,
    required String nameB,
    required String addressB,
  }) async {
    try {
      final prompt = '''
Are these two Google Places entries the same real-world physical landmark or
venue (e.g. one is an entrance, viewpoint, gate, or sub-area of the other),
rather than two genuinely separate places that merely happen to be nearby?

Place A: "$nameA" ($addressA)
Place B: "$nameB" ($addressB)

Respond with ONLY "yes" or "no".
''';
      final response = await generateText(prompt);
      return response.trim().toLowerCase().startsWith('y');
    } catch (e) {
      debugPrint('[gemini] areSameRealWorldSite failed, treating as different: $e');
      return false;
    }
  }

  /// The specific kind of place [screenLandmarkPhoto] should hold a photo to,
  /// per gm.dart's route_group ('food' / 'culture' / 'heritage' / 'nature').
  /// Without this, the prompt only checked "is this generically an outdoor
  /// landmark, no people, no indoor" — which a completely unrelated but
  /// scenic photo (e.g. a tourist's skyline shot of a nearby famous
  /// landmark, attached to a small business's Google listing) passes just as
  /// easily as a real photo of that business. Returns `null` for the
  /// generic "Local Attraction" catch-all, which has no specific look to
  /// hold a photo to.
  String? _categoryPhotoRequirement(String? routeGroup) {
    switch (routeGroup) {
      case 'food':
        return 'a food place\'s exterior — a restaurant, cafe, bakery, food '
            'stall, hawker stall, kiosk, food truck, or similar storefront';
      case 'culture':
        return 'a cultural venue\'s exterior — a museum, art gallery, '
            'cultural center, or similar building';
      case 'heritage':
        return 'a historic/heritage site — a historic building, monument, '
            'temple, mosque, church, or similar structure';
      case 'nature':
        return 'a natural or park setting — a park, garden, trail, or '
            'natural outdoor landscape';
      default:
        return null;
    }
  }

  // ---------- UC-05: Landmark Photo Verification ----------
  /// UC-05 — screen a candidate place photo. [isEligible] is `true` only when
  /// the photo shows a genuine, unoccupied OUTDOOR exterior/landmark (no
  /// indoor scenes, no food/item close-ups, no closed/abandoned venues, and
  /// no visible people). When [routeGroup] is given, the photo must also
  /// plausibly look like that specific kind of place (see
  /// [_categoryPhotoRequirement]) — a generic skyline/cityscape/unrelated
  /// landmark photo attached to the wrong listing is rejected even though it
  /// is a perfectly good outdoor photo of *something*. [hasLandmarkSign]
  /// separately reports whether a landmark/entrance sign or plaque is
  /// visible — used as a soft preference for Nature-theme places, never a
  /// rejection reason on its own. Fails open (`isEligible: true`,
  /// `hasLandmarkSign: false`) on any error, when no key is configured, or
  /// for placeholder images.
  Future<LandmarkPhotoScreening> screenLandmarkPhoto(
    String imageUrl, {
    String? routeGroup,
  }) async {
    if (!hasApiKey) {
      debugPrint('[vision] no GEMINI_API_KEY — allowing photo');
      return const LandmarkPhotoScreening(
        isEligible: true,
        hasLandmarkSign: false,
      );
    }
    if (imageUrl.contains('picsum.photos') ||
        imageUrl.contains('placeholder')) {
      return const LandmarkPhotoScreening(
        isEligible: true,
        hasLandmarkSign: false,
      );
    }
    try {
      final image = await http
          .get(Uri.parse(imageUrl))
          .timeout(const Duration(seconds: 12));
      if (image.statusCode != 200 || image.bodyBytes.isEmpty) {
        debugPrint('[vision] photo download failed (${image.statusCode}) — allowing');
        return const LandmarkPhotoScreening(
          isEligible: true,
          hasLandmarkSign: false,
        );
      }
      final contentType = image.headers['content-type'] ?? 'image/jpeg';
      final categoryRequirement = _categoryPhotoRequirement(routeGroup);
      final categoryClause = categoryRequirement == null
          ? ''
          : ' The place this photo is supposed to represent is specifically '
              '$categoryRequirement. If the photo instead shows a general '
              'skyline, cityscape, or a different, unrelated landmark that '
              'does not itself look like $categoryRequirement — even if it '
              'is a perfectly good outdoor photo of something else nearby — '
              'that does NOT count as showing the place itself.';

      final response = await _generateWithFailover([
        Content.multi([
          TextPart(
            'You are screening photos for an outdoor landmark exploration '
            'game where a tourist walks to a place and recognises it from '
            'this photo.\n'
            'Answer two questions about the photo, each "yes" or "no", '
            'separated by a comma, in this exact order:\n'
            '1) ELIGIBLE: answer "yes" ONLY if this photo primarily shows the '
            'OUTDOOR exterior of the place itself — a building facade, '
            'shopfront/stall signage, monument, park, plaza, street, or '
            'landmark — something a tourist could match against the real '
            'place when they arrive, with NO person, human figure, face, or '
            'crowd visible anywhere in the photo.$categoryClause Answer "no" '
            'if it is mainly an INDOOR scene (room, hall, shop interior, '
            'restaurant interior, prayer hall, gallery, office, lobby); OR a '
            'CLOSE-UP of food, drinks, a menu, merchandise, or any other '
            'object/item that does not show the place itself (e.g. a photo '
            'of a burger or dish, even if taken outdoors); OR if the place '
            'looks permanently closed, abandoned, boarded up, demolished, or '
            'under construction; OR if any person, human figure, face, or '
            'crowd is visible anywhere in the photo, even in the '
            'background.\n'
            '2) SIGN: answer "yes" if a landmark, entrance, or place-name '
            'sign, signboard, or plaque is clearly visible and readable '
            'somewhere in the photo, otherwise "no".\n'
            'Reply with EXACTLY two words separated by a comma and nothing '
            'else, e.g. "yes,no".',
          ),
          DataPart(contentType, image.bodyBytes),
        ]),
      ]);
      final answer = (response.text ?? 'yes,no').trim().toLowerCase();
      final tokens = answer.split(',').map((t) => t.trim()).toList();
      final eligible = tokens.isEmpty || !tokens[0].startsWith('n');
      final hasSign = tokens.length > 1 && tokens[1].startsWith('y');
      debugPrint(
        '[vision] "$answer" -> '
        '${eligible ? "ELIGIBLE" : "REJECTED"}'
        '${hasSign ? ", sign visible" : ""}',
      );
      return LandmarkPhotoScreening(
        isEligible: eligible,
        hasLandmarkSign: hasSign,
      );
    } catch (e) {
      debugPrint('[vision] error, allowing photo: $e');
      return const LandmarkPhotoScreening(
        isEligible: true,
        hasLandmarkSign: false,
      );
    }
  }

  Future<bool> compareLandmarkPhotos({
    required String referenceImageUrl,
    required String submittedPhotoUrl,
  }) async {
    // Offline / no-key fallback keeps the Puzzle verification flow working.
    if (!hasApiKey) return true;
    try {
      final prompt = '''
Compare these two landmark photos and determine if they show the same location.
Reference photo: $referenceImageUrl
Submitted photo: $submittedPhotoUrl
Respond with ONLY "true" if they match, or "false" if they don't.
''';
      final response = await generateText(prompt);
      return response.trim().toLowerCase() == 'true';
    } catch (e) {
      return true;
    }
  }

  /// UC-06 S1.5-S1.7 — generates one Theme Souvenir Image URL for [theme].
  ///
  /// Theme Souvenir Images are generated using the selected Trip Path Quest
  /// theme ONLY (no township), as Malaysian tourism souvenir artwork
  /// suitable for grayscale / progressive-colour reveal gameplay (UC-05 C6).
  ///
  /// Calls Gemini's image-generation model directly over REST (the
  /// google_generative_ai package pinned here, 0.4.6, predates its
  /// GenerationConfig exposing image response modalities), uploads the
  /// result to the theme-souvenir-images Supabase Storage bucket, and
  /// returns the real public URL. Falls back to the old mock URL on any
  /// failure — RewardRepository already accepts the 'mock' scheme, so a
  /// Gemini/network hiccup degrades to a placeholder instead of blocking
  /// Trip Path catalogue replenishment, matching this file's existing
  /// resilience convention (see compareLandmarkPhotos above).
  ///
  /// Distinct from [generateThemeSouvenirImage] below, which generates a
  /// *text description* for image-gen rather than a URL — different
  /// callers, different purpose, kept side by side deliberately.
  Future<String> generateThemeSouvenirImageUrl({required String theme}) async {
    _themeImageGenerationCounter++;

    final normalizedTheme = theme
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'\s+'), '_');
    final mockFallback = 'mock://theme_souvenir_images/$normalizedTheme/'
        '${DateTime.now().millisecondsSinceEpoch}_$_themeImageGenerationCounter.png';

    try {
      final prompt =
          'A colourful Malaysian tourism souvenir artwork representing the '
          '"$theme" theme. Vibrant, culturally rich, illustrated postcard '
          'style, suitable for a travel-quest reward. No text or watermarks.';
      // This same prompt string is reused for every image of this theme —
      // it only describes the theme, not any one specific artwork — so the
      // seed (not the prompt) is what has to make each call actually
      // produce a different picture. Combined with the counter for
      // uniqueness even if two calls land in the same millisecond (the
      // _replenish() loop can fire several in a row). Masked to a
      // non-negative 31-bit value — Pollinations rejects a negative seed
      // outright (HTTP 400, "expected number to be >=-1"), confirmed live
      // against the real API, so this must never produce one.
      final seed = (DateTime.now().millisecondsSinceEpoch ^
              _themeImageGenerationCounter) &
          0x7FFFFFFF;
      final bytes = await _generateImageBytes(prompt, seed: seed);
      if (bytes == null) return mockFallback;

      final path =
          '$normalizedTheme/${DateTime.now().millisecondsSinceEpoch}_$_themeImageGenerationCounter.png';
      await Supabase.instance.client.storage
          .from('theme-souvenir-images')
          .uploadBinary(
            path,
            bytes,
            fileOptions: const FileOptions(
              cacheControl: '3600',
              upsert: false,
              contentType: 'image/png',
            ),
          );
      // Registers this generated image into the shared theme_artworks pool
      // (by explicit request) so every future tourist can be assigned it
      // too, instead of it being spent on just the one request that
      // triggered generation. Non-fatal on failure — the image this call
      // returns is already uploaded and usable regardless of whether the
      // pool-registration insert succeeds.
      try {
        await Supabase.instance.client.from('theme_artworks').insert({
          'theme_id': normalizedTheme,
          'title': '$theme Souvenir',
          'bucket_name': 'theme-souvenir-images',
          'storage_path': path,
          'is_active': true,
        });
      } catch (_) {
        // Ignored — see comment above.
      }
      return Supabase.instance.client.storage
          .from('theme-souvenir-images')
          .getPublicUrl(path);
    } catch (_) {
      return mockFallback;
    }
  }

  /// Generates an image from [prompt] via Pollinations.ai — a free, keyless
  /// text-to-image API (image.pollinations.ai), used instead of Gemini's
  /// image model since that needs a billing-enabled Google Cloud project.
  /// Returns the decoded bytes, or null on any non-200 response/failure so
  /// callers can fall back to their own mock placeholder.
  ///
  /// [seed] must be caller-supplied rather than derived from [prompt] —
  /// Pollinations is a diffusion model, so the same prompt + same seed
  /// deterministically returns the exact same pixels every time. Every
  /// theme souvenir call reuses the identical theme-only prompt (it never
  /// names a specific artwork), so a prompt-derived seed used to make every
  /// "new" image for a theme come back visually identical — the seed is now
  /// the one thing that actually varies per call.
  // Pollinations' free anonymous tier allows only 1 in-flight request per
  // IP ("Queue full for IP: ...: 1 requests already queued (max: 1)",
  // confirmed live as an HTTP 429). On a shared/carrier-NAT IP this can
  // trip from completely unrelated traffic, not just our own back-to-back
  // calls, so it's worth a couple of short retries before giving up rather
  // than failing on the first transient hit.
  static const _pollinationsRateLimitRetries = 2;
  static const _pollinationsRateLimitBackoff = Duration(seconds: 4);

  Future<Uint8List?> _generateImageBytes(
    String prompt, {
    required int seed,
  }) async {
    final uri = Uri.https('image.pollinations.ai', '/prompt/$prompt', {
      'width': '512',
      'height': '512',
      'nologo': 'true',
      'seed': '$seed',
    });

    for (var attempt = 0; ; attempt++) {
      try {
        final response = await http
            .get(uri)
            .timeout(const Duration(seconds: 30));

        if (response.statusCode == 200 && response.bodyBytes.isNotEmpty) {
          return response.bodyBytes;
        }

        if (response.statusCode == 429 &&
            attempt < _pollinationsRateLimitRetries) {
          await Future<void>.delayed(_pollinationsRateLimitBackoff);
          continue;
        }

        return null;
      } catch (_) {
        return null;
      }
    }
  }

  // ---------- UC-05: Generate Checkpoint Clue ----------
  Future<String> generateClue({
    required String checkpointInfo,
    required String theme,
    String? previousClues,
  }) async {
    final prompt = '''
You are a game master for a tourism exploration game in Malaysia.
Generate a cryptic clue for a tourist to find a hidden attraction.

Checkpoint details: $checkpointInfo
Game theme: $theme
${previousClues != null ? 'Previous clues given: $previousClues' : ''}

Rules:
1. Do NOT reveal the exact name, full address, or GPS coordinates
2. Make it engaging and fun
3. Keep it under 50 words
4. Use local cultural references if possible

Clue:
''';
    return await generateText(prompt);
  }

  // ---------- UC-06: Generate Souvenir Description ----------
  Future<String> generateThemeSouvenirImage({
    required String theme,
    required String description,
  }) async {
    try {
      final prompt = '''
Generate a detailed visual description for a tourism-themed souvenir image for a "Visit Malaysia 2026" exploration game.

Theme: $theme
Description: $description

Provide a vivid, detailed prompt that could be used to generate a beautiful, colorful, and culturally relevant souvenir design.
''';
      return await generateText(prompt);
    } catch (e) {
      return 'https://via.placeholder.com/300x200/4CAF50/FFFFFF?text=Theme+Souvenir';
    }
  }

  // ---------- UC-06: Generate Marker Skin Description ----------
  Future<String> generateExplorerMarkerSkin({
    required String theme,
    required String description,
  }) async {
    try {
      final prompt = '''
Generate a detailed visual description for an explorer marker skin for a "Visit Malaysia 2026" exploration game.

Theme: $theme
Description: $description

Provide a vivid, detailed prompt that could be used to generate a unique, colorful, and culturally relevant marker design that will appear on a map.
''';
      return await generateText(prompt);
    } catch (e) {
      return 'https://via.placeholder.com/100x100/FF6B6B/FFFFFF?text=Marker';
    }
  }

  // ---------- Debug: List Available Models ----------
  Future<void> listAvailableModels() async {
    if (!hasApiKey) return;
    try {
      final response = await http.get(
        Uri.parse(
          'https://generativelanguage.googleapis.com/v1beta/models?key=$_apiKey',
        ),
      );
      if (response.statusCode == 200) {
        final data = json.decode(response.body) as Map<String, dynamic>;
        final models = data['models'] as List;
        for (final model in models) {
          final methods =
              (model['supportedGenerationMethods'] as List?) ?? const [];
          if (methods.contains('generateContent')) {
            // ignore: avoid_print
            print('  available: ${model['name']}');
          }
        }
      }
    } catch (_) {
      // ignore
    }
  }
}
