import 'dart:convert';
import 'dart:typed_data';

import 'trip_path_gemini_api.dart';

class GeminiPhotoVerificationDecision {
  final String verdict; // same_place, probably_same, different_place, uncertain
  final double confidence;
  final bool identityConflict;

  // V41 evidence-first AI output. Gemini must explain a SAME verdict using
  // permanent features that are visibly present in BOTH images. These fields
  // let the local fusion layer reject a high-confidence but generic AI guess.
  final List<String> stableMatches;
  final List<String> permanentContradictions;
  final List<String> ignoredTransientObjects;

  // V46 scene-context + primary-anchor contract.
  // environment: indoor / outdoor / mixed / uncertain
  // captureScope: full_place / partial_place / sign_only /
  //               environment_only / unclear
  final String referenceEnvironment;
  final String capturedEnvironment;
  final bool environmentMismatch;
  final List<String> referencePrimaryAnchors;
  final List<String> matchedPrimaryAnchors;
  final List<String> missingPrimaryAnchors;
  final String captureScope;
  final bool storefrontContextVisible;

  final String evidenceScope; // broad_scene, distinctive_partial, tiny_or_generic, unclear
  final double distinctivenessScore;
  final double permanentVisibility;
  final String reason;

  const GeminiPhotoVerificationDecision({
    required this.verdict,
    required this.confidence,
    required this.identityConflict,
    this.stableMatches = const <String>[],
    this.permanentContradictions = const <String>[],
    this.ignoredTransientObjects = const <String>[],
    this.referenceEnvironment = 'uncertain',
    this.capturedEnvironment = 'uncertain',
    this.environmentMismatch = false,
    this.referencePrimaryAnchors = const <String>[],
    this.matchedPrimaryAnchors = const <String>[],
    this.missingPrimaryAnchors = const <String>[],
    this.captureScope = 'unclear',
    this.storefrontContextVisible = false,
    this.evidenceScope = 'unclear',
    this.distinctivenessScore = 0,
    this.permanentVisibility = 0,
    required this.reason,
  });

  bool get hasPermanentContradiction => permanentContradictions.isNotEmpty;

  String get compactEvidenceSummary {
    final stable = stableMatches.isEmpty ? '-' : stableMatches.take(3).join(' | ');
    final contradictions = permanentContradictions.isEmpty
        ? '-'
        : permanentContradictions.take(2).join(' | ');
    final ignored = ignoredTransientObjects.isEmpty
        ? '-'
        : ignoredTransientObjects.take(4).join(', ');
    final anchors = matchedPrimaryAnchors.isEmpty
        ? '-'
        : matchedPrimaryAnchors.take(3).join(' | ');
    return 'stable=[$stable]; contradictions=[$contradictions]; '
        'env=$referenceEnvironment->$capturedEnvironment; '
        'captureScope=$captureScope; anchors=[$anchors]; '
        'storefrontContext=$storefrontContextVisible; '
        'scope=$evidenceScope; distinctiveness=${distinctivenessScore.toStringAsFixed(2)}; '
        'permanentVisibility=${permanentVisibility.toStringAsFixed(2)}; ignored=[$ignored]';
  }
}

/// Gemini's verdict on a single reference-photo candidate that the on-device
/// ML Kit classifier already rejected as borderline (see
/// TripPathReferencePhotoService / _ReferenceSemanticAnalysis.
/// eligibleForAiSecondOpinion). Fails closed — a service error never
/// produces this class; the caller keeps the original ML Kit rejection.
class GeminiReferencePhotoSecondOpinion {
  final bool rejectionIsWrong;

  /// True only when the photo also shows something a tourist could actually
  /// recognise this specific place by (a readable sign/name, a distinctive
  /// facade/entrance, a unique structure) — not just "technically outdoor,
  /// no person". A generic corridor, courtyard or car park is outdoor but
  /// not recognisable, and must not override the local rejection alone.
  final bool recognisable;

  final String reason;

  const GeminiReferencePhotoSecondOpinion({
    required this.rejectionIsWrong,
    required this.recognisable,
    required this.reason,
  });
}

class GeminiPhotoVerificationService {
  final GeminiApi _api;

  GeminiPhotoVerificationService({GeminiApi? api})
      : _api = api ??
            GeminiApi(
              apiKey: const String.fromEnvironment('GEMINI_API_KEY'),
              backupApiKey:
                  const String.fromEnvironment('GEMINI_API_KEY_BACKUP'),
            );

  Future<GeminiPhotoVerificationDecision> compare({
    required Uint8List reference,
    required Uint8List captured,
    required String themeId,
    required String referenceKind,
    required String expectedPlaceName,
  }) async {
    final kind = referenceKind.trim().toLowerCase();
    final theme = themeId.trim().toLowerCase();
    final storefront = const {
      'storefront_exterior',
      'food_stall_or_kiosk',
    }.contains(kind);

    final identityLine = storefront && expectedPlaceName.trim().isNotEmpty
        ? 'Expected storefront identity: "${expectedPlaceName.trim()}". Use this ONLY as a contradiction check when readable business identity is visibly different. Never use the provided name as proof that the images match.'
        : 'No checkpoint name or address is provided. Do not identify the place from world knowledge, memory, famous-landmark recognition, metadata, or guessed location. Compare only what is visibly present in the two images.';

    final themeRules = _themeRules(
      theme: theme,
      kind: kind,
      storefront: storefront,
    );

    final prompt = '''
You are a conservative visual verifier deciding whether two photos show the SAME PHYSICAL PLACE.
Image 1 is the trusted checkpoint REFERENCE. Image 2 is the USER CAPTURE.
Theme: $themeId. Reference kind: $referenceKind.
$identityLine

IMPORTANT METHOD:
1. Inspect the two images independently and region-by-region.
2. Mentally ignore TRANSIENT objects before comparing the place: people, cars, motorcycles, buses, bicycles, movable tables/chairs, temporary stalls, temporary banners, shadows, screen glare, decorative festival items and momentary lighting.
3. Compare PERMANENT or slow-changing physical evidence that is visible in BOTH images.
4. A stable match must describe a specific relationship or distinctive feature, not a generic category such as "both have trees", "both are tall buildings", "both have windows", "both are roads", or "both are red".
5. Record a permanent contradiction only when a fixed structure/identity/spatial relationship is genuinely incompatible. Do NOT treat crop, perspective, camera height, zoom, day/night, weather, vegetation movement, people or vehicles as contradictions.

V46 ENVIRONMENT + PRIMARY-ANCHOR CONTRACT:
- FIRST classify Image 1 and Image 2 independently as indoor, outdoor, mixed, or uncertain.
- If the trusted reference is clearly OUTDOOR/exterior but the user photo is clearly INDOOR, that is a strong place-context contradiction. The reverse is also true.
- Identify 2-4 PRIMARY ANCHORS from the REFERENCE: the most place-specific permanent things a genuine visitor should reproduce. Prefer connected anchors rather than generic categories.
- For a storefront, primary anchors should prioritize readable business identity/signboard POSITION, entrance position, awning/canopy shape, facade divisions, pillars/windows as a layout, and fixed neighbouring structure.
- A matching logo/sign alone is NOT proof of the same storefront. A photo showing only a sign/logo with little surrounding facade must use capture_scope=sign_only and may NOT be same_place.
- A photo showing only generic surroundings/environment while omitting the target storefront/landmark must use capture_scope=environment_only and may NOT be same_place.
- A valid storefront same_place needs BOTH: at least two matched primary anchors AND enough storefront context to show that those anchors belong to the same physical facade.
- For non-storefront landmarks/nature, a partial view is allowed when multiple connected distinctive primary anchors are visible.
- Never invent an anchor that is not visibly present in the reference.

$themeRules

DECISION RULES:
- same_place: at least TWO distinctive permanent matches support the same physical place and no strong permanent contradiction is visible. The overlapping view may be partial if the visible part is uniquely structured. For storefronts, capture_scope must be full_place or partial_place, storefront_context_visible must be true, and at least TWO reference primary anchors must be matched.
- probably_same: at least TWO non-generic permanent same-place matches are visible, but occlusion, blur, extreme crop, viewpoint or insufficient visible permanent area prevents a safe match. A correct sign-only storefront photo is normally probably_same/uncertain and must be retaken wider, never same_place. If you cannot name two permanent matches, use uncertain instead.
- different_place: a strong permanent contradiction, clearly conflicting storefront identity, or incompatible fixed spatial layout is visible.
- uncertain: evidence is too generic, tiny, mixed or absent.
- Never choose same_place merely because the scene category/style is similar.
- Never use a person, vehicle, colour alone, one tree, one sign fragment, one repeated window, generic greenery, generic shop lots, sky or water alone as sufficient evidence.
- If transient objects cover much of the image, list them under ignored_transient_objects and judge only the permanent portions that remain visible.

SCORING FIELDS:
- distinctiveness_score: 0..1. How uniquely the listed stable matches identify the same physical place. Generic similarities must score low.
- permanent_visibility: 0..1. How much useful permanent scene evidence is visible across the two images after ignoring transient objects.
- evidence_scope:
  * broad_scene = several permanent regions/spatial relationships agree.
  * distinctive_partial = crop is partial but contains multiple distinctive connected fixed features.
  * tiny_or_generic = only a tiny crop or generic repeated pattern is available.
  * unclear = image quality/occlusion prevents a reliable scope judgement.

Return JSON only. Keep each evidence phrase short and visual.
''';

    final raw = await _api.generateVisionText(
      prompt: prompt,
      images: [reference, captured],
      mimeTypes: [_mime(reference), _mime(captured)],
      responseJsonSchema: {
        'type': 'object',
        'properties': {
          'verdict': {
            'type': 'string',
            'enum': [
              'same_place',
              'probably_same',
              'different_place',
              'uncertain'
            ]
          },
          'confidence': {'type': 'number', 'minimum': 0, 'maximum': 1},
          'identity_conflict': {'type': 'boolean'},
          'stable_matches': {
            'type': 'array',
            'items': {'type': 'string'}
          },
          'permanent_contradictions': {
            'type': 'array',
            'items': {'type': 'string'}
          },
          'ignored_transient_objects': {
            'type': 'array',
            'items': {'type': 'string'}
          },
          'reference_environment': {
            'type': 'string',
            'enum': ['indoor', 'outdoor', 'mixed', 'uncertain']
          },
          'captured_environment': {
            'type': 'string',
            'enum': ['indoor', 'outdoor', 'mixed', 'uncertain']
          },
          'environment_mismatch': {'type': 'boolean'},
          'reference_primary_anchors': {
            'type': 'array',
            'items': {'type': 'string'}
          },
          'matched_primary_anchors': {
            'type': 'array',
            'items': {'type': 'string'}
          },
          'missing_primary_anchors': {
            'type': 'array',
            'items': {'type': 'string'}
          },
          'capture_scope': {
            'type': 'string',
            'enum': [
              'full_place',
              'partial_place',
              'sign_only',
              'environment_only',
              'unclear'
            ]
          },
          'storefront_context_visible': {'type': 'boolean'},
          'evidence_scope': {
            'type': 'string',
            'enum': [
              'broad_scene',
              'distinctive_partial',
              'tiny_or_generic',
              'unclear'
            ]
          },
          'distinctiveness_score': {
            'type': 'number',
            'minimum': 0,
            'maximum': 1
          },
          'permanent_visibility': {
            'type': 'number',
            'minimum': 0,
            'maximum': 1
          },
          'reason': {'type': 'string'}
        },
        'required': [
          'verdict',
          'confidence',
          'identity_conflict',
          'stable_matches',
          'permanent_contradictions',
          'ignored_transient_objects',
          'reference_environment',
          'captured_environment',
          'environment_mismatch',
          'reference_primary_anchors',
          'matched_primary_anchors',
          'missing_primary_anchors',
          'capture_scope',
          'storefront_context_visible',
          'evidence_scope',
          'distinctiveness_score',
          'permanent_visibility',
          'reason'
        ]
      },
      maxOutputTokens: 760,
    );

    final data = jsonDecode(raw) as Map<String, dynamic>;
    final stableMatches = _stringList(data['stable_matches'], max: 5);
    final permanentContradictions =
        _stringList(data['permanent_contradictions'], max: 4);
    final ignoredTransientObjects =
        _stringList(data['ignored_transient_objects'], max: 6);
    final referencePrimaryAnchors =
        _stringList(data['reference_primary_anchors'], max: 4);
    final matchedPrimaryAnchors =
        _stringList(data['matched_primary_anchors'], max: 4);
    final missingPrimaryAnchors =
        _stringList(data['missing_primary_anchors'], max: 4);

    var verdict = (data['verdict'] as String? ?? 'uncertain').trim();
    const allowedVerdicts = {
      'same_place',
      'probably_same',
      'different_place',
      'uncertain',
    };
    if (!allowedVerdicts.contains(verdict)) verdict = 'uncertain';

    var scope = (data['evidence_scope'] as String? ?? 'unclear').trim();
    const allowedScopes = {
      'broad_scene',
      'distinctive_partial',
      'tiny_or_generic',
      'unclear',
    };
    if (!allowedScopes.contains(scope)) scope = 'unclear';

    String environmentValue(dynamic value) {
      final env = (value as String? ?? 'uncertain').trim();
      const allowed = {'indoor', 'outdoor', 'mixed', 'uncertain'};
      return allowed.contains(env) ? env : 'uncertain';
    }

    var captureScope = (data['capture_scope'] as String? ?? 'unclear').trim();
    const allowedCaptureScopes = {
      'full_place',
      'partial_place',
      'sign_only',
      'environment_only',
      'unclear',
    };
    if (!allowedCaptureScopes.contains(captureScope)) {
      captureScope = 'unclear';
    }

    return GeminiPhotoVerificationDecision(
      verdict: verdict,
      confidence:
          ((data['confidence'] as num?)?.toDouble() ?? 0).clamp(0.0, 1.0),
      identityConflict: data['identity_conflict'] == true,
      stableMatches: stableMatches,
      permanentContradictions: permanentContradictions,
      ignoredTransientObjects: ignoredTransientObjects,
      referenceEnvironment: environmentValue(data['reference_environment']),
      capturedEnvironment: environmentValue(data['captured_environment']),
      environmentMismatch: data['environment_mismatch'] == true,
      referencePrimaryAnchors: referencePrimaryAnchors,
      matchedPrimaryAnchors: matchedPrimaryAnchors,
      missingPrimaryAnchors: missingPrimaryAnchors,
      captureScope: captureScope,
      storefrontContextVisible: data['storefront_context_visible'] == true,
      evidenceScope: scope,
      distinctivenessScore:
          ((data['distinctiveness_score'] as num?)?.toDouble() ?? 0)
              .clamp(0.0, 1.0),
      permanentVisibility:
          ((data['permanent_visibility'] as num?)?.toDouble() ?? 0)
              .clamp(0.0, 1.0),
      reason: (data['reason'] as String? ?? '').trim(),
    );
  }

  /// Second opinion for a candidate reference photo the on-device ML Kit
  /// classifier rejected in a deliberately narrow borderline confidence band
  /// (never for a confident reject — see eligibleForAiSecondOpinion). Only
  /// called when the local rules genuinely couldn't decide, so this is a
  /// low-volume, best-effort check: any failure (network, quota, parse
  /// error) fails closed as "agree with the rejection" rather than risking
  /// a real indoor photo or a photo with a real person slipping through.
  Future<GeminiReferencePhotoSecondOpinion> reviewRejectedReferenceCandidate({
    required Uint8List photo,
    required String themeId,
    required String rejectionReason,
  }) async {
    final prompt = '''
You are reviewing one candidate photo for a real-world "$themeId" scavenger-hunt checkpoint reference.
An on-device classifier flagged it REJECTED for this reason: "$rejectionReason".
That classifier is sometimes wrong on borderline cases — for example a statue, mannequin, cardboard
cutout or reflection mistaken for a real person, or a shaded/covered but genuinely open-air storefront
mistaken for an indoor scene.

Answer two questions about the photo, each true/false:

1) rejection_is_wrong: is this in fact a genuine OUTDOOR, re-photographable physical place with NO
real visible person (statues, mannequins, cutouts and reflections do not count as a person)?

2) recognisable: could a tourist standing outside this exact place actually match it against this
photo — because a readable sign/business name is visible, or the photo shows a distinctive facade,
entrance, or structure unique to this specific place? A generic corridor, walkway, courtyard,
car park, plain wall, or anything that could belong to countless other buildings is NOT recognisable,
even if it is genuinely outdoor.

Be conservative on both. Only answer true when you are confident. If genuinely unsure, answer false.

Return JSON only.
''';

    final raw = await _api.generateVisionText(
      prompt: prompt,
      images: [photo],
      mimeTypes: [_mime(photo)],
      responseJsonSchema: {
        'type': 'object',
        'properties': {
          'rejection_is_wrong': {'type': 'boolean'},
          'recognisable': {'type': 'boolean'},
          'reason': {'type': 'string'},
        },
        'required': ['rejection_is_wrong', 'recognisable', 'reason'],
      },
      maxOutputTokens: 200,
    );

    final data = jsonDecode(raw) as Map<String, dynamic>;
    return GeminiReferencePhotoSecondOpinion(
      rejectionIsWrong: data['rejection_is_wrong'] == true,
      recognisable: data['recognisable'] == true,
      reason: (data['reason'] as String? ?? '').trim(),
    );
  }

  static String _themeRules({
    required String theme,
    required String kind,
    required bool storefront,
  }) {
    if (storefront || theme == 'food') {
      return '''
FOOD / STOREFRONT RULES:
- Prioritize readable business identity when available, but also compare fixed sign POSITION, entrance position, awning/canopy shape, facade divisions, pillars, upper-floor geometry and other permanent storefront structure.
- Treat brand/logo identity as ONE anchor only. Same brand/logo/colour does not prove the same branch.
- A sign-only crop can never be same_place because it does not prove that the sign belongs to the same physical facade/branch.
- Generic environment with no visible storefront-specific anchor can never be same_place, even when the street/building style is similar.
- Ignore customers, staff, parked vehicles, food displays, movable tables/chairs and temporary promotional banners.
- Similar shop-lot architecture or similar colours alone are NOT enough.
- A clearly different readable business/brand identity is a strong contradiction.''';
    }

    if (theme == 'nature' || kind.startsWith('nature_')) {
      return '''
NATURE RULES:
- Compare combinations of stable terrain and spatial layout: ridge/horizon contour, rock formation, waterfall shape, water-land boundary, trail/bridge/viewing barrier, shoreline, slope relationships and distinctive large vegetation layout.
- Ignore hikers, vehicles, temporary tents/signage, moving foliage, water ripples, clouds, seasonal colour and day/night lighting.
- Generic forest, grass, sky, water or one tree alone are NOT distinctive evidence.
- Prefer at least two connected anchors, for example ridge + viewing barrier, waterfall + rock layout, or shoreline + trail/bridge.''';
    }

    if (theme == 'culture' ||
        theme == 'heritage' ||
        kind.contains('landmark') ||
        kind.contains('monument') ||
        kind.contains('building_exterior')) {
      return '''
CULTURE / HERITAGE / LARGE LANDMARK RULES:
- Compare fixed structural relationships: silhouette, tower spacing, bridge/arch position, roofline, columns, facade bands, windows as a layout (not one repeated window), monument geometry and relative placement of major elements.
- A close-up, low-angle, zoomed or partial capture can still be SAME when multiple connected distinctive structures align.
- Ignore crowds, traffic, decorative temporary lighting, temporary festival objects, banners and weather/day-night changes.
- Do not reject solely because the full landmark outline is missing from the user capture.''';
    }

    return '''
GENERAL FIXED-PLACE RULES:
- Compare multiple permanent structural or environmental relationships visible in both images.
- Ignore people, vehicles, temporary objects, weather and lighting changes.
- Generic category similarity is not enough.''';
  }

  static List<String> _stringList(dynamic value, {required int max}) {
    if (value is! List) return const <String>[];
    final result = <String>[];
    for (final item in value) {
      if (item is! String) continue;
      final cleaned = item.trim().replaceAll(RegExp(r'\s+'), ' ');
      if (cleaned.isEmpty) continue;
      if (!result.contains(cleaned)) result.add(cleaned);
      if (result.length >= max) break;
    }
    return result;
  }

  static String _mime(Uint8List b) {
    if (b.length >= 8 &&
        b[0] == 0x89 &&
        b[1] == 0x50 &&
        b[2] == 0x4E &&
        b[3] == 0x47) {
      return 'image/png';
    }
    if (b.length >= 3 &&
        b[0] == 0xFF &&
        b[1] == 0xD8 &&
        b[2] == 0xFF) {
      return 'image/jpeg';
    }
    return 'image/jpeg';
  }
}
