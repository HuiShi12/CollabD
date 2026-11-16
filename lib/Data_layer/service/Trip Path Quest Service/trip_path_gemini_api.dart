import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:http/http.dart' as http;

class GeminiApiException implements Exception {
  final String message;
  final int? statusCode;

  const GeminiApiException(this.message, {this.statusCode});

  bool get isRateLimited => statusCode == 429;

  @override
  String toString() => message;
}

class GeminiApi {
  final String apiKey;

  // Optional operational backup key(s), comma-separated for more than one
  // (e.g. "key2,key3,key4").
  // Backup failover: if the primary key is rejected (401/403) OR reaches
  // a 429 rate/quota limit, the request fails over to the next configured
  // backup key in order. This is most useful when each backup key belongs to
  // a separate legitimately configured Google Cloud project; keys sharing a
  // project normally share quota and may all return 429 together.
  final String backupApiKey;

  final http.Client _client;

  // A key that just returned 401/403/429 is very likely to fail again
  // immediately (the free tier's quota resets on the order of a minute, not
  // instantly). Skipping recently-failed keys for a short window avoids
  // re-paying for that same failed round-trip on every call — this is the
  // difference between "always slow" and "usually fast, briefly slow right
  // after a quota hit".
  final Map<String, DateTime> _keyCooldownUntil = {};
  static const _keyCooldown = Duration(seconds: 90);

  GeminiApi({
    required this.apiKey,
    this.backupApiKey = '',
    http.Client? client,
  }) : _client = client ?? http.Client();

  // Better quality than Flash-Lite.
  // We reduce latency using minimal thinking instead.
  static const String _model = 'gemini-3.6-flash';

  Future<String> generateText({
    required String prompt,
    Map<String, dynamic>? responseJsonSchema,
    int maxOutputTokens = 300,
  }) async {
    if (apiKey.trim().isEmpty && backupApiKey.trim().isEmpty) {
      throw const GeminiApiException(
        'Gemini API key is missing.',
      );
    }

    if (prompt.trim().isEmpty) {
      throw const GeminiApiException(
        'Gemini prompt is empty.',
      );
    }

    final uri = Uri.parse(
      'https://generativelanguage.googleapis.com/'
          'v1beta/models/$_model:generateContent',
    );

    final generationConfig = <String, dynamic>{
      'maxOutputTokens': maxOutputTokens,

      // Reduce unnecessary reasoning latency.
      'thinkingConfig': {
        'thinkingLevel': 'minimal',
      },
    };

    // Structured JSON output.
    if (responseJsonSchema != null) {
      generationConfig['responseMimeType'] =
      'application/json';

      generationConfig['responseJsonSchema'] =
          responseJsonSchema;
    }

    try {
      final response = await _postWithResilience(
        uri: uri,
        body: jsonEncode({
          'contents': [
            {
              'role': 'user',
              'parts': [
                {
                  'text': prompt,
                },
              ],
            },
          ],
          'generationConfig': generationConfig,
        }),
      );

      final decoded =
      jsonDecode(response.body) as Map<String, dynamic>;

      final candidates = decoded['candidates'];

      if (candidates is! List ||
          candidates.isEmpty) {
        throw const GeminiApiException(
          'Gemini returned no response.',
        );
      }

      final firstCandidate = candidates.first;

      if (firstCandidate is! Map<String, dynamic>) {
        throw const GeminiApiException(
          'Gemini returned an invalid candidate.',
        );
      }

      final content = firstCandidate['content'];

      if (content is! Map<String, dynamic>) {
        throw const GeminiApiException(
          'Gemini returned invalid content.',
        );
      }

      final parts = content['parts'];

      if (parts is! List ||
          parts.isEmpty) {
        throw const GeminiApiException(
          'Gemini returned an empty response.',
        );
      }

      final buffer = StringBuffer();

      for (final part in parts) {
        if (part is Map<String, dynamic>) {
          final text = part['text'];

          if (text is String &&
              text.trim().isNotEmpty) {
            if (buffer.isNotEmpty) {
              buffer.write('\n');
            }

            buffer.write(text.trim());
          }
        }
      }

      final result =
      buffer.toString().trim();

      if (result.isEmpty) {
        throw const GeminiApiException(
          'Gemini returned an empty text response.',
        );
      }

      return result;
    } on GeminiApiException {
      rethrow;
    } catch (error) {
      throw GeminiApiException(
        'Unable to connect to Gemini: $error',
      );
    }
  }

  Future<String> generateVisionText({
    required String prompt,
    required List<Uint8List> images,
    required List<String> mimeTypes,
    Map<String, dynamic>? responseJsonSchema,
    int maxOutputTokens = 400,
  }) async {
    if (apiKey.trim().isEmpty && backupApiKey.trim().isEmpty) {
      throw const GeminiApiException('Gemini API key is missing.');
    }
    if (images.isEmpty || images.length != mimeTypes.length) {
      throw const GeminiApiException('Gemini vision images are invalid.');
    }

    final uri = Uri.parse(
      'https://generativelanguage.googleapis.com/'
          'v1beta/models/$_model:generateContent',
    );
    final generationConfig = <String, dynamic>{
      'maxOutputTokens': maxOutputTokens,
      'thinkingConfig': {'thinkingLevel': 'minimal'},

      // Photo verification is a classification task. A low temperature
      // makes repeated judgements more consistent without changing the model.
      'temperature': 0.1,
    };
    if (responseJsonSchema != null) {
      generationConfig['responseMimeType'] = 'application/json';
      generationConfig['responseJsonSchema'] = responseJsonSchema;
    }
    final parts = <Map<String, dynamic>>[
      {'text': prompt},
    ];
    for (var i = 0; i < images.length; i++) {
      parts.add({
        'inlineData': {
          'mimeType': mimeTypes[i],
          'data': base64Encode(images[i]),
        },
      });
    }
    try {
      final response = await _postWithResilience(
        uri: uri,
        body: jsonEncode({
          'contents': [
            {'role': 'user', 'parts': parts},
          ],
          'generationConfig': generationConfig,
        }),
      );
      final decoded = jsonDecode(response.body) as Map<String, dynamic>;
      final candidates = decoded['candidates'];
      if (candidates is! List || candidates.isEmpty) {
        throw const GeminiApiException('Gemini returned no response.');
      }
      final content = (candidates.first as Map<String, dynamic>)['content'];
      final responseParts = (content as Map<String, dynamic>)['parts'];
      final buffer = StringBuffer();
      if (responseParts is List) {
        for (final part in responseParts) {
          if (part is Map<String, dynamic> && part['text'] is String) {
            if (buffer.isNotEmpty) buffer.write('\n');
            buffer.write((part['text'] as String).trim());
          }
        }
      }
      final result = buffer.toString().trim();
      if (result.isEmpty) {
        throw const GeminiApiException('Gemini returned an empty response.');
      }
      return result;
    } on GeminiApiException {
      rethrow;
    } catch (error) {
      throw GeminiApiException('Unable to connect to Gemini: $error');
    }
  }

  Future<http.Response> _postWithResilience({
    required Uri uri,
    required String body,
  }) async {
    final primary = apiKey.trim();

    // backupApiKey may hold any number of keys, comma-separated (e.g. from
    // separate Google Cloud projects, so a shared-project quota hit doesn't
    // take out every fallback at once). Each one is tried in order after the
    // primary; duplicates and blanks are dropped.
    final backups = backupApiKey
        .split(',')
        .map((k) => k.trim())
        .where((k) => k.isNotEmpty);

    final allKeys = <String>[];
    if (primary.isNotEmpty) allKeys.add(primary);
    for (final backup in backups) {
      if (!allKeys.contains(backup)) allKeys.add(backup);
    }

    if (allKeys.isEmpty) {
      throw const GeminiApiException('Gemini API key is missing.');
    }

    // Try keys that aren't cooling down first (see [_keyCooldownUntil]). If
    // every key happens to be cooling down, still try them all — a stale
    // cooldown must never turn into a hard failure.
    final now = DateTime.now();
    final fresh = allKeys
        .where((k) => !(_keyCooldownUntil[k]?.isAfter(now) ?? false))
        .toList();
    final keys = fresh.isNotEmpty ? fresh : allKeys;

    final random = math.Random();

    for (var keyIndex = 0; keyIndex < keys.length; keyIndex++) {
      final key = keys[keyIndex];
      final hasAnotherKey = keyIndex + 1 < keys.length;

      for (var attempt = 0; attempt < 3; attempt++) {
        try {
          final response = await _client.post(
            uri,
            headers: {
              'Content-Type': 'application/json',
              'x-goog-api-key': key,
            },
            body: body,
          );

          if (response.statusCode >= 200 && response.statusCode < 300) {
            _keyCooldownUntil.remove(key);
            return response;
          }

          // Backup failover:
          // - 401/403: current key is rejected -> try the next configured key.
          // - 429: current key/project is rate/quota limited -> try the
          //   backup once if one is configured. If both keys belong to the
          //   same Google Cloud project, they normally share quota, so the
          //   backup may also return 429.
          if ((response.statusCode == 401 ||
                  response.statusCode == 403 ||
                  response.statusCode == 429) &&
              hasAnotherKey) {
            _keyCooldownUntil[key] = now.add(_keyCooldown);
            break;
          }

          // Retry transient network/server failures on the same key.
          // We intentionally do not spend several retries on a 429 before
          // trying the backup, because that only makes photo verification wait.
          final transient =
              response.statusCode == 408 || response.statusCode >= 500;

          if (transient && attempt < 2) {
            final baseMs = 700 * (1 << attempt);
            final jitterMs = random.nextInt(251);
            await Future<void>.delayed(
              Duration(milliseconds: baseMs + jitterMs),
            );
            continue;
          }

          if (response.statusCode == 429) {
            _keyCooldownUntil[key] = now.add(_keyCooldown);
            throw GeminiApiException(
              hasAnotherKey
                  ? 'Gemini rate limit reached (429). Backup failover was not completed.'
                  : 'Gemini rate limit reached (429) on all configured Gemini keys/projects.',
              statusCode: 429,
            );
          }

          throw GeminiApiException(
            'Gemini API request failed '
                '(${response.statusCode}): ${response.body}',
            statusCode: response.statusCode,
          );
        } on GeminiApiException {
          rethrow;
        } catch (error) {
          if (attempt < 2) {
            final baseMs = 700 * (1 << attempt);
            final jitterMs = random.nextInt(251);
            await Future<void>.delayed(
              Duration(milliseconds: baseMs + jitterMs),
            );
            continue;
          }

          // A transport failure is not a quota signal. If this was the last
          // retry for the current key and another key exists, try the backup.
          if (hasAnotherKey) {
            break;
          }

          throw GeminiApiException(
            'Unable to connect to Gemini: $error',
          );
        }
      }
    }

    throw const GeminiApiException(
      'Gemini API authentication, availability, or quota check failed for all configured keys.',
    );
  }

  void dispose() {
    _client.close();
  }
}
