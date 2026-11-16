import 'dart:convert';

import 'trip_path_gemini_api.dart';

class GeminiServiceException implements Exception {
  final String message;

  const GeminiServiceException(this.message);

  @override
  String toString() => message;
}

class GeminiCheckpointClueInput {
  final String attractionName;
  final String attractionAddress;
  final String generalArea;
  final String placeType;
  final List<String> verifiedFacts;

  const GeminiCheckpointClueInput({
    required this.attractionName,
    required this.attractionAddress,
    required this.generalArea,
    required this.placeType,
    required this.verifiedFacts,
  });
}

class GeminiTwoCheckpointClues {
  final List<String> checkpoint2;
  final List<String> checkpoint3;

  const GeminiTwoCheckpointClues({
    required this.checkpoint2,
    required this.checkpoint3,
  });
}

class GeminiService {
  final GeminiApi geminiApi;

  GeminiService({
    required this.geminiApi,
  });

  // ============================================================
  // SAME REAL-WORLD SITE CHECK (dedup fallback)
  //
  // Used only when the free name/distance heuristic in
  // TripPathAttractionRepository can't confidently tell whether two nearby
  // Google Place entries are sub-entries of the SAME real-world landmark
  // (e.g. an entrance/lookout vs. the landmark itself). A single short
  // text-only call, not vision — cheap relative to reference-photo
  // screening. Fails closed (`false`) on any error so an outage never merges
  // two genuinely distinct places into one.
  // ============================================================

  Future<bool> areSameRealWorldSite({
    required String nameA,
    required String addressA,
    required String nameB,
    required String addressB,
  }) async {
    try {
      final response = await geminiApi.generateText(
        prompt: '''
Are these two Google Places entries the same real-world physical landmark or
venue (e.g. one is an entrance, viewpoint, gate, or sub-area of the other),
rather than two genuinely separate places that merely happen to be nearby?

Place A: "$nameA" ($addressA)
Place B: "$nameB" ($addressB)

Respond with ONLY "yes" or "no".
''',
        maxOutputTokens: 10,
      );
      return response.trim().toLowerCase().startsWith('y');
    } catch (_) {
      return false;
    }
  }

  // ============================================================
  // GENERATE ALL 3 CLUES IN ONE GEMINI REQUEST
  // ============================================================

  Future<List<String>> generateClues({
    required String attractionName,
    required String attractionAddress,
    required String generalArea,
    required String placeType,
    required String theme,
    required List<String> verifiedFacts,
  }) async {
    // ==========================================================
    // BASIC VALIDATION
    // ==========================================================

    if (attractionName.trim().isEmpty) {
      throw const GeminiServiceException(
        'Attraction name is missing.',
      );
    }

    if (generalArea.trim().isEmpty) {
      throw const GeminiServiceException(
        'General area is missing.',
      );
    }

    if (placeType.trim().isEmpty) {
      throw const GeminiServiceException(
        'Place type is missing.',
      );
    }

    if (verifiedFacts.length < 3) {
      throw const GeminiServiceException(
        'At least 3 verified attraction facts are required.',
      );
    }

    final prompt = _buildPrompt(
      generalArea: generalArea,
      placeType: placeType,
      theme: theme,
      verifiedFacts: verifiedFacts,
    );

    try {
      // ========================================================
      // ONE REQUEST ONLY
      //
      // Gemini generates:
      //
      // Clue 1
      // Clue 2
      // Clue 3
      //
      // together.
      // ========================================================

      final response = await geminiApi.generateText(
        prompt: prompt,

        // Short output is enough for 3 clues.
        maxOutputTokens: 180,

        // Force structured JSON response.
        responseJsonSchema: {
          'type': 'object',
          'properties': {
            'clues': {
              'type': 'array',
              'minItems': 3,
              'maxItems': 3,
              'items': {
                'type': 'object',
                'properties': {
                  'type': {
                    'type': 'string',
                  },
                  'text': {
                    'type': 'string',
                  },
                },
                'required': [
                  'type',
                  'text',
                ],
              },
            },
          },
          'required': [
            'clues',
          ],
        },
      );

      // ========================================================
      // PARSE RESPONSE
      // ========================================================

      final clues = _sanitizeClues(
        _parseClues(
          response,
        ),
      );

      // ========================================================
      // LOCAL SAFETY CHECK
      //
      // No additional Gemini API request is made here.
      // ========================================================

      _validateClues(
        clues: clues,
        attractionName: attractionName,
        attractionAddress: attractionAddress,
      );

      return clues;
    } on GeminiApiException catch (error) {
      throw GeminiServiceException(
        'Unable to generate clues: ${error.message}',
      );
    } on GeminiServiceException {
      rethrow;
    } catch (error) {
      throw GeminiServiceException(
        'Unable to generate clues: $error',
      );
    }
  }

  // ============================================================
  // GENERATE CP2 + CP3 IN ONE GEMINI REQUEST
  // ============================================================

  Future<GeminiTwoCheckpointClues>
  generateCluesForTwoCheckpoints({
    required String theme,
    required GeminiCheckpointClueInput checkpoint2,
    required GeminiCheckpointClueInput checkpoint3,
  }) async {
    _validateCheckpointInput(
      checkpoint2,
      label: 'Checkpoint 2',
    );

    _validateCheckpointInput(
      checkpoint3,
      label: 'Checkpoint 3',
    );

    final prompt = _buildTwoCheckpointPrompt(
      theme: theme,
      checkpoint2: checkpoint2,
      checkpoint3: checkpoint3,
    );

    try {
      final response = await geminiApi.generateText(
        prompt: prompt,
        maxOutputTokens: 360,
        responseJsonSchema: {
          'type': 'object',
          'properties': {
            'checkpoint2': {
              'type': 'object',
              'properties': {
                'clues': {
                  'type': 'array',
                  'minItems': 3,
                  'maxItems': 3,
                  'items': {
                    'type': 'object',
                    'properties': {
                      'type': {
                        'type': 'string',
                      },
                      'text': {
                        'type': 'string',
                      },
                    },
                    'required': [
                      'type',
                      'text',
                    ],
                  },
                },
              },
              'required': [
                'clues',
              ],
            },
            'checkpoint3': {
              'type': 'object',
              'properties': {
                'clues': {
                  'type': 'array',
                  'minItems': 3,
                  'maxItems': 3,
                  'items': {
                    'type': 'object',
                    'properties': {
                      'type': {
                        'type': 'string',
                      },
                      'text': {
                        'type': 'string',
                      },
                    },
                    'required': [
                      'type',
                      'text',
                    ],
                  },
                },
              },
              'required': [
                'clues',
              ],
            },
          },
          'required': [
            'checkpoint2',
            'checkpoint3',
          ],
        },
      );

      final parsedResult = _parseTwoCheckpointClues(
        response,
      );

      final result = GeminiTwoCheckpointClues(
        checkpoint2: List.unmodifiable(_sanitizeClues(parsedResult.checkpoint2)),
        checkpoint3: List.unmodifiable(_sanitizeClues(parsedResult.checkpoint3)),
      );

      _validateClues(
        clues: result.checkpoint2,
        attractionName:
        checkpoint2.attractionName,
        attractionAddress:
        checkpoint2.attractionAddress,
      );

      _validateClues(
        clues: result.checkpoint3,
        attractionName:
        checkpoint3.attractionName,
        attractionAddress:
        checkpoint3.attractionAddress,
      );

      return result;
    } on GeminiApiException catch (error) {
      throw GeminiServiceException(
        'Unable to generate checkpoint 2 and 3 clues: ${error.message}',
      );
    } on GeminiServiceException {
      rethrow;
    } catch (error) {
      throw GeminiServiceException(
        'Unable to generate checkpoint 2 and 3 clues: $error',
      );
    }
  }

  void _validateCheckpointInput(
      GeminiCheckpointClueInput input, {
        required String label,
      }) {
    if (input.attractionName.trim().isEmpty) {
      throw GeminiServiceException(
        '$label attraction name is missing.',
      );
    }

    if (input.generalArea.trim().isEmpty) {
      throw GeminiServiceException(
        '$label general area is missing.',
      );
    }

    if (input.placeType.trim().isEmpty) {
      throw GeminiServiceException(
        '$label place type is missing.',
      );
    }

    if (input.verifiedFacts.length < 3) {
      throw GeminiServiceException(
        '$label requires at least 3 verified attraction facts.',
      );
    }
  }

  String _buildTwoCheckpointPrompt({
    required String theme,
    required GeminiCheckpointClueInput checkpoint2,
    required GeminiCheckpointClueInput checkpoint3,
  }) {
    String checkpointContext(
        int number,
        GeminiCheckpointClueInput input,
        ) {
      return '''
Checkpoint $number:
- Place type: ${input.placeType}
- General area: ${input.generalArea}
- F1 appearance/physical fact: ${input.verifiedFacts[0].trim()}
- F2 activity/experience fact: ${input.verifiedFacts[1].trim()}
- F3 unique identifying fact: ${input.verifiedFacts[2].trim()}
''';
    }

    return '''
Create clues for Checkpoint 2 and Checkpoint 3 of the Trip Path Quest tourism game.

Theme: $theme

Use ONLY the supplied facts. Do not use outside knowledge, guess, or invent details.
The clues must help a player recognize the real-world place on site.
Never describe Google/Google Places metadata, database classification, business status, rating, review count, or API data.
Never mention the reference-photo pipeline, ML Kit, OCR, ORB, semantic scores, or internal screening.

${checkpointContext(2, checkpoint2)}
${checkpointContext(3, checkpoint3)}

For EACH checkpoint, create exactly 3 progressive clues in this exact order:

1. type = "appearance"
   - Hardest clue.
   - Use the place type and F1 only.
   - Describe what the tourist may physically observe.
   - Do NOT mention the general area.

2. type = "experience"
   - Medium clue.
   - Use F2 as the main idea.
   - Describe what visitors can actually do or experience at the physical place.
   - Mention the general area only when it is a useful neighbourhood/locality, never just a generic city name.

3. type = "identifier"
   - Easiest clue.
   - Use F3 as the main idea.
   - Give one strong, real-world distinguishing characteristic such as visible signage, a stable structure, or a useful locality.
   - Mention the general area only when it meaningfully narrows the search.

For EACH checkpoint:
- Do not repeat the same main idea across its 3 clues.
- Never reveal the attraction name.
- Never reveal a full address or street name.
- Never reveal GPS coordinates.
- Never reveal Google Plus Codes / Open Location Codes such as "6PHM+C3".
- Never provide exact route or turn-by-turn directions.
- Use simple English.
- Write from the player's real-world point of view, not from a database/API point of view.
- Never use phrases such as "Google Places", "classified as", "operational", "rating", "reviews", or "open for business" as clues.
- Never mention "reference photo", "accepted reference", "ML Kit", "OCR", "ORB", or internal screening.
- Use 12 to 24 words per clue.

Return JSON only:
{
  "checkpoint2": {
    "clues": [
      {"type": "appearance", "text": "..."},
      {"type": "experience", "text": "..."},
      {"type": "identifier", "text": "..."}
    ]
  },
  "checkpoint3": {
    "clues": [
      {"type": "appearance", "text": "..."},
      {"type": "experience", "text": "..."},
      {"type": "identifier", "text": "..."}
    ]
  }
}
''';
  }

  GeminiTwoCheckpointClues
  _parseTwoCheckpointClues(
      String response,
      ) {
    try {
      final cleanedResponse =
      _cleanJsonResponse(response);

      final decoded =
      jsonDecode(cleanedResponse)
      as Map<String, dynamic>;

      final checkpoint2 =
      decoded['checkpoint2'];

      final checkpoint3 =
      decoded['checkpoint3'];

      if (checkpoint2
      is! Map<String, dynamic> ||
          checkpoint3
          is! Map<String, dynamic>) {
        throw const GeminiServiceException(
          'Invalid checkpoint 2/3 Gemini response.',
        );
      }

      final cp2Clues =
      _parseClueData(
        checkpoint2['clues'],
      );

      final cp3Clues =
      _parseClueData(
        checkpoint3['clues'],
      );

      return GeminiTwoCheckpointClues(
        checkpoint2:
        List.unmodifiable(cp2Clues),
        checkpoint3:
        List.unmodifiable(cp3Clues),
      );
    } catch (error) {
      if (error
      is GeminiServiceException) {
        rethrow;
      }

      throw GeminiServiceException(
        'Unable to parse checkpoint 2/3 Gemini response: $error',
      );
    }
  }

  // ============================================================
  // BUILD PROMPT
  //
  // VERIFIED FACT ORDER:
  //
  // F1 = Appearance / physical characteristic
  // F2 = Activity / experience
  // F3 = Unique identifier
  //
  // This makes the three clues serve different purposes.
  // ============================================================

  String _buildPrompt({
    required String generalArea,
    required String placeType,
    required String theme,
    required List<String> verifiedFacts,
  }) {
    final fact1 =
    verifiedFacts[0].trim();

    final fact2 =
    verifiedFacts[1].trim();

    final fact3 =
    verifiedFacts[2].trim();

    return '''
Create exactly 3 progressive clues for the Trip Path Quest tourism game.

Use ONLY the supplied facts. Do not use outside knowledge, guess, or invent details.
The clues must help a player recognize the real-world place on site.
Never describe Google/Google Places metadata, database classification, business status, rating, review count, or API data.
Never mention the reference-photo pipeline, ML Kit, OCR, ORB, semantic scores, or internal screening.

Context:
- Theme: $theme
- Place type: $placeType
- General area: $generalArea
- F1 appearance/physical fact: $fact1
- F2 activity/experience fact: $fact2
- F3 unique identifying fact: $fact3

The three clues MUST have different roles and must be returned in this exact order:

1. type = "appearance"
   - Hardest clue.
   - Use the place type and F1 only.
   - Describe what the tourist may physically observe.
   - Do NOT mention the general area.
   - Do NOT use F2 or F3 as the main idea.

2. type = "experience"
   - Medium clue.
   - Use F2 as the main idea.
   - Describe what visitors can actually do or experience at the physical place.
   - Mention the general area only when it is a useful neighbourhood/locality, never just a generic city name.
   - Do NOT repeat or paraphrase the main appearance idea from clue 1.
   - Do NOT use F1 or F3 as the main idea.

3. type = "identifier"
   - Easiest and strongest clue.
   - Use F3 as the main idea.
   - Give one strong, real-world distinguishing characteristic such as visible signage, a stable structure, or a useful locality.
   - Mention the general area only when it meaningfully narrows the search.
   - Do NOT summarize or combine clues 1 and 2.
   - Do NOT repeat the main appearance or activity idea.

Privacy rules for ALL clues:
- Never reveal the attraction name.
- Never reveal a full address or street name.
- Never reveal GPS coordinates, latitude, or longitude.
- Never reveal Google Plus Codes / Open Location Codes such as "6PHM+C3".
- Never provide exact route, navigation, or turn-by-turn directions.
- Never say "The answer is", "The location is", "Go to", or "You are looking for".

Writing rules:
- Simple English.
- Clear and practical, not poetic or vague.
- Write from the player's real-world point of view, not from a database/API point of view.
- Never use phrases such as "Google Places", "classified as", "operational", "rating", "reviews", or "open for business" as clues.
- Never mention "reference photo", "accepted reference", "ML Kit", "OCR", "ORB", or internal screening.
- 12 to 24 words per clue.
- Each clue must introduce a different main piece of information.
- The clues should become progressively easier.

Return JSON only in this shape:
{
  "clues": [
    {"type": "appearance", "text": "..."},
    {"type": "experience", "text": "..."},
    {"type": "identifier", "text": "..."}
  ]
}
''';
  }

  // ============================================================
  // VALIDATE GENERATED CLUES
  //
  // These are LOCAL Dart checks.
  //
  // They do NOT make another Gemini request.
  // ============================================================

  void _validateClues({
    required List<String> clues,
    required String attractionName,
    required String attractionAddress,
  }) {
    if (clues.length != 3) {
      throw const GeminiServiceException(
        'Gemini did not generate exactly 3 clues.',
      );
    }

    for (final clue in clues) {
      if (RegExp(r'\b(jalan|jln|lorong|persiaran|lebuh)\b|durable structure|durable public landmark',
          caseSensitive: false).hasMatch(clue)) {
        throw const GeminiServiceException('Clue contains a street name or unsupported generic description.');
      }
      for (final component in attractionAddress.split(',')) {
        if (RegExp(r'\b(road|street|lane|jalan|jln|lorong|persiaran|lebuh)\b',
            caseSensitive: false).hasMatch(component) &&
            _normalizeText(component).isNotEmpty &&
            _normalizeText(clue).contains(_normalizeText(component))) {
          throw const GeminiServiceException('Clue revealed a street address component.');
        }
      }
      if (clue.trim().isEmpty) {
        throw const GeminiServiceException(
          'Gemini generated an empty clue.',
        );
      }

      if (_containsAttractionName(
        clue: clue,
        attractionName:
        attractionName,
      )) {
        throw const GeminiServiceException(
          'Generated clue revealed the attraction name.',
        );
      }

      if (_containsExactAddress(
        clue: clue,
        attractionAddress:
        attractionAddress,
      )) {
        throw const GeminiServiceException(
          'Generated clue revealed the exact address.',
        );
      }

      if (_containsPlusCode(clue)) {
        throw const GeminiServiceException(
          'Generated clue revealed a Google Plus Code / Open Location Code.',
        );
      }

      if (_containsForbiddenMetadataWording(clue)) {
        throw const GeminiServiceException(
          'Generated clue used forbidden Google/database metadata wording.',
        );
      }
    }

    final clue1 =
    _normalizeText(
      clues[0],
    );

    final clue2 =
    _normalizeText(
      clues[1],
    );

    final clue3 =
    _normalizeText(
      clues[2],
    );

    if (clue1 == clue2 ||
        clue1 == clue3 ||
        clue2 == clue3) {
      throw const GeminiServiceException(
        'Gemini generated duplicate clues.',
      );
    }
  }

  // ============================================================
  // PARSE GEMINI JSON
  // ============================================================

  List<String> _parseClues(
      String response,
      ) {
    try {
      final cleanedResponse =
      _cleanJsonResponse(
        response,
      );

      final decoded =
      jsonDecode(
        cleanedResponse,
      ) as Map<String, dynamic>;

      return _parseClueData(
        decoded['clues'],
      );
    } catch (error) {
      if (error
      is GeminiServiceException) {
        rethrow;
      }

      throw GeminiServiceException(
        'Unable to parse Gemini clue response: $error',
      );
    }
  }

  String _cleanJsonResponse(
      String response,
      ) {
    return response
        .trim()
        .replaceAll(
      '```json',
      '',
    )
        .replaceAll(
      '```JSON',
      '',
    )
        .replaceAll(
      '```',
      '',
    )
        .trim();
  }

  List<String> _parseClueData(
      dynamic clueData,
      ) {
    if (clueData is! List) {
      throw const GeminiServiceException(
        'Invalid Gemini clue response.',
      );
    }

    if (clueData.length != 3) {
      throw const GeminiServiceException(
        'Gemini must return exactly 3 clues.',
      );
    }

    const expectedTypes = [
      'appearance',
      'experience',
      'identifier',
    ];

    final clues = <String>[];

    for (
    var index = 0;
    index < clueData.length;
    index++
    ) {
      final item =
      clueData[index];

      if (item
      is! Map<String, dynamic>) {
        throw const GeminiServiceException(
          'Invalid Gemini clue item.',
        );
      }

      final type =
          item['type']
              ?.toString()
              .trim()
              .toLowerCase() ??
              '';

      final clueText =
          item['text']
              ?.toString()
              .trim() ??
              '';

      if (type !=
          expectedTypes[index]) {
        throw GeminiServiceException(
          'Gemini returned the wrong clue type at position ${index + 1}.',
        );
      }

      if (clueText.isEmpty) {
        throw const GeminiServiceException(
          'Gemini generated an empty clue.',
        );
      }

      clues.add(
        clueText,
      );
    }

    return clues;
  }

  // ============================================================
  // CHECK WHETHER ATTRACTION NAME WAS REVEALED
  // ============================================================

  bool _containsAttractionName({
    required String clue,
    required String attractionName,
  }) {
    final normalizedClue =
    _normalizeText(
      clue,
    );

    final normalizedName =
    _normalizeText(
      attractionName,
    );

    if (normalizedName.isEmpty) {
      return false;
    }

    return normalizedClue.contains(
      normalizedName,
    );
  }

  // ============================================================
  // CHECK WHETHER FULL ADDRESS WAS REVEALED
  // ============================================================

  bool _containsExactAddress({
    required String clue,
    required String attractionAddress,
  }) {
    final normalizedAddress =
    _normalizeText(
      attractionAddress,
    );

    if (normalizedAddress.isEmpty) {
      return false;
    }

    final normalizedClue =
    _normalizeText(
      clue,
    );

    return normalizedClue.contains(
      normalizedAddress,
    );
  }

  List<String> _sanitizeClues(List<String> clues) {
    return clues
        .map(_stripPlusCodes)
        .map((clue) => clue.replaceAll(RegExp(r'\s{2,}'), ' ').trim())
        .toList(growable: false);
  }

  String _stripPlusCodes(String value) {
    return value.replaceAll(
      RegExp(
        r'\b[23456789CFGHJMPQRVWX]{4,8}\+[23456789CFGHJMPQRVWX]{2,3}\b',
        caseSensitive: false,
      ),
      '',
    );
  }

  bool _containsPlusCode(String value) {
    return RegExp(
      r'\b[23456789CFGHJMPQRVWX]{4,8}\+[23456789CFGHJMPQRVWX]{2,3}\b',
      caseSensitive: false,
    ).hasMatch(value);
  }

  bool _containsForbiddenMetadataWording(
    String clue,
  ) {
    final normalized = _normalizeText(clue);

    const forbiddenPhrases = <String>[
      'google places',
      'classified as',
      'classifies as',
      'classified primarily',
      'operational place',
      'business status',
      'user reviews',
      'review count',
      'rating of',
      'star rating',
      'no reviews',
      'zero reviews',
      '0 reviews',
      'unrated',
      'currently open for business',
      'api data',
      'reference photo',
      'accepted reference',
      'ml kit',
      'semantic score',
      'internal screening',
      'orb',
    ];

    return forbiddenPhrases.any(
      normalized.contains,
    );
  }

  // ============================================================
  // NORMALIZE TEXT
  // ============================================================

  String _normalizeText(
      String value,
      ) {
    return value
        .toLowerCase()
        .replaceAll(
      RegExp(
        r'[^a-z0-9]+',
      ),
      ' ',
    )
        .trim();
  }
}
