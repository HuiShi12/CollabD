import 'dart:convert';

import 'package:http/http.dart' as http;

/// A live Google Map Tiles session.
class GoogleMapTileSession {
  const GoogleMapTileSession({
    required this.token,
    required this.tileWidth,
    required this.tileHeight,
  });

  final String token;
  final int tileWidth;
  final int tileHeight;
}

class GoogleMapTilesException implements Exception {
  const GoogleMapTilesException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// UC-03 C1 – Google Maps Service gateway for the interactive game map.
///
/// A session token is created at run time and placed in the 2D tile URL. When
/// no key is configured the map falls back to OpenStreetMap so the module stays
/// usable during development. No tile caching or prefetching is performed.
class MapTilesService {
  const MapTilesService();

  static const _tileApiKey = String.fromEnvironment('GOOGLE_MAPS_TILE_API_KEY');
  static const _sharedMapsApiKey = String.fromEnvironment('GOOGLE_MAPS_API_KEY');

  String get apiKey => _tileApiKey.isNotEmpty ? _tileApiKey : _sharedMapsApiKey;

  bool get hasApiKey => apiKey.isNotEmpty;

  /// Creates a tile session. When [dark] is set the session is styled with the
  /// standard Google "night mode" styler array, so the 2D tiles come back dark
  /// to match the app's dark theme. A session token is bound to the style it was
  /// created with, so callers must create a fresh session when the theme flips.
  Future<GoogleMapTileSession> createSession({bool dark = false}) async {
    if (!hasApiKey) {
      throw const GoogleMapTilesException(
        'A Google Map Tiles API key has not been configured.',
      );
    }

    final response = await http.post(
      Uri.https('tile.googleapis.com', '/v1/createSession', {'key': apiKey}),
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({
        'mapType': 'roadmap',
        'language': 'en-US',
        'region': 'MY',
        if (dark) 'styles': _darkStyles,
      }),
    );

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw GoogleMapTilesException(
        'Google Map Tiles session failed (${response.statusCode}).',
      );
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final token = body['session'] as String?;
    if (token == null || token.isEmpty) {
      throw const GoogleMapTilesException(
        'Google Map Tiles returned an invalid session.',
      );
    }

    return GoogleMapTileSession(
      token: token,
      tileWidth: (body['tileWidth'] as num?)?.toInt() ?? 256,
      tileHeight: (body['tileHeight'] as num?)?.toInt() ?? 256,
    );
  }

  String tileUrlTemplate(GoogleMapTileSession session) {
    final encodedSession = Uri.encodeQueryComponent(session.token);
    final encodedKey = Uri.encodeQueryComponent(apiKey);
    return 'https://tile.googleapis.com/v1/2dtiles/{z}/{x}/{y}'
        '?session=$encodedSession&key=$encodedKey';
  }

  Future<String?> getViewportCopyright({
    required GoogleMapTileSession session,
    required int zoom,
    required double north,
    required double south,
    required double east,
    required double west,
  }) async {
    final response = await http.get(
      Uri.https('tile.googleapis.com', '/tile/v1/viewport', {
        'session': session.token,
        'key': apiKey,
        'zoom': '$zoom',
        'north': '$north',
        'south': '$south',
        'east': '$east',
        'west': '$west',
      }),
    );

    if (response.statusCode < 200 || response.statusCode >= 300) {
      return null;
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return body['copyright'] as String?;
  }

  /// Google's standard "Night mode" styler array (same schema the classic Maps
  /// styling wizard produces), passed to `createSession` for dark tiles.
  static const List<Map<String, dynamic>> _darkStyles = [
    {
      'elementType': 'geometry',
      'stylers': [
        {'color': '#242f3e'},
      ],
    },
    {
      'elementType': 'labels.text.fill',
      'stylers': [
        {'color': '#746855'},
      ],
    },
    {
      'elementType': 'labels.text.stroke',
      'stylers': [
        {'color': '#242f3e'},
      ],
    },
    {
      'featureType': 'administrative.locality',
      'elementType': 'labels.text.fill',
      'stylers': [
        {'color': '#d59563'},
      ],
    },
    {
      'featureType': 'poi',
      'elementType': 'labels.text.fill',
      'stylers': [
        {'color': '#d59563'},
      ],
    },
    {
      'featureType': 'poi.park',
      'elementType': 'geometry',
      'stylers': [
        {'color': '#263c3f'},
      ],
    },
    {
      'featureType': 'poi.park',
      'elementType': 'labels.text.fill',
      'stylers': [
        {'color': '#6b9a76'},
      ],
    },
    {
      'featureType': 'road',
      'elementType': 'geometry',
      'stylers': [
        {'color': '#38414e'},
      ],
    },
    {
      'featureType': 'road',
      'elementType': 'geometry.stroke',
      'stylers': [
        {'color': '#212a37'},
      ],
    },
    {
      'featureType': 'road',
      'elementType': 'labels.text.fill',
      'stylers': [
        {'color': '#9ca5b3'},
      ],
    },
    {
      'featureType': 'road.highway',
      'elementType': 'geometry',
      'stylers': [
        {'color': '#746855'},
      ],
    },
    {
      'featureType': 'road.highway',
      'elementType': 'geometry.stroke',
      'stylers': [
        {'color': '#1f2835'},
      ],
    },
    {
      'featureType': 'road.highway',
      'elementType': 'labels.text.fill',
      'stylers': [
        {'color': '#f3d19c'},
      ],
    },
    {
      'featureType': 'transit',
      'elementType': 'geometry',
      'stylers': [
        {'color': '#2f3948'},
      ],
    },
    {
      'featureType': 'transit.station',
      'elementType': 'labels.text.fill',
      'stylers': [
        {'color': '#d59563'},
      ],
    },
    {
      'featureType': 'water',
      'elementType': 'geometry',
      'stylers': [
        {'color': '#17263c'},
      ],
    },
    {
      'featureType': 'water',
      'elementType': 'labels.text.fill',
      'stylers': [
        {'color': '#515c6d'},
      ],
    },
    {
      'featureType': 'water',
      'elementType': 'labels.text.stroke',
      'stylers': [
        {'color': '#17263c'},
      ],
    },
  ];
}
