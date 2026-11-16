// lib/UI_layer/viewmodel/Chatbot ViewModel/chatbot_viewmodel.dart

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:collab_d/Data_layer/repository/Chat Repository/message.dart';
import 'package:collab_d/Data_layer/service/Location Service/location.dart';
import 'package:collab_d/Data_layer/service/Gemini Service/gemini.dart';

class ChatbotViewModel extends ChangeNotifier {
  // ---------- Dependencies ----------
  final LocationService _locationService;
  final GeminiService _geminiService;

  // ---------- State ----------
  final List<Message> _messages = [];
  String _currentArea = 'Detecting...';
  bool _isLoading = false;
  bool _isLocationReady = false;
  Timer? _areaRefreshTimer;

  // How often to re-resolve the tourist's area name while the chat is open,
  // so walking to a new neighbourhood updates $_currentArea (and the header
  // + Gemini's context) without needing to close and reopen the chatbot.
  // Explicit user choice — trades a bit more GPS/reverse-geocoding traffic
  // for a snappier-feeling update than the initially-proposed 30s.
  static const _areaRefreshInterval = Duration(seconds: 5);

  // Matches GoogleMapsPlatformExternal's _minGameReviewCount/
  // _maxGameReviewCount and Trip Path Quest's own hidden-place review
  // bounds exactly, so the AI Assistant never recommends a place Map/
  // Puzzle/Trip Path themselves would reject as "too over-touristed".
  static const _minQuestReviewCount = 10;
  static const _maxQuestReviewCount = 1000;

  // Google Places types for grocery/retail venues (supermarkets, malls, KK
  // Mart-style convenience stores, ...) — unrelated to any of this app's
  // four quest themes, so never recommended regardless of topic. Covers
  // both the current and the older, still-sometimes-returned legacy type
  // name for a supermarket.
  static const _offThemeRetailTypes = <String>{
    'supermarket',
    'grocery_or_supermarket',
    'grocery_store',
    'convenience_store',
    'department_store',
    'discount_store',
    'wholesaler',
    'warehouse_store',
    'shopping_mall',
  };

  // ---------- Getters ----------
  List<Message> get messages => _messages;
  String get currentArea => _currentArea;
  bool get isLoading => _isLoading;
  bool get isLocationReady => _isLocationReady;

  // ---------- Constructor ----------
  ChatbotViewModel({
    required LocationService locationService,
    required GeminiService geminiService,
  })  : _locationService = locationService,
        _geminiService = geminiService {
    _detectLocation();
    _areaRefreshTimer = Timer.periodic(
      _areaRefreshInterval,
      (_) => _refreshArea(),
    );
  }

  @override
  void dispose() {
    _areaRefreshTimer?.cancel();
    super.dispose();
  }

  // ---------- Location Detection ----------
  Future<void> _detectLocation() async {
    _isLocationReady = false;
    _currentArea = 'Detecting...';
    notifyListeners();

    try {
      String area = await _locationService.getCurrentArea();

      if (area != 'Unknown' && area != 'Detecting...') {
        _currentArea = area;
        _isLocationReady = true;
        notifyListeners();
        _addMessage(Message.areaDetected(area));
      } else {
        _currentArea = 'Unknown';
        _isLocationReady = false;
        notifyListeners();
        _addMessage(Message.error(
          'Location access is required to use the AI Assistant Chat. '
              'Please enable GPS and grant location permission.',
        ));
      }
    } catch (e) {
      debugPrint('❌ Location detection error: $e');
      _currentArea = 'Unknown';
      _isLocationReady = false;
      notifyListeners();
      _addMessage(Message.error(
        'Your current location cannot be detected. '
            'Please check your GPS connection and try again.',
      ));
    }
  }

  // ---------- Periodic Area Refresh ----------
  bool _isRefreshingArea = false;

  // Re-resolves the area name every [_areaRefreshInterval] while the chat is
  // open, so walking somewhere new updates the header/context in real time
  // instead of staying stuck on whatever area was detected when the
  // chatbot first opened. Quiet on failure — unlike _detectLocation, this
  // never posts an error message; it just tries again next tick.
  Future<void> _refreshArea() async {
    // At a 5s interval, a slow GPS fix/reverse-geocode could still be in
    // flight when the next tick fires — skip that tick instead of piling up
    // overlapping calls.
    if (!_isLocationReady || _isRefreshingArea) return;
    _isRefreshingArea = true;
    try {
      final area = await _locationService.getCurrentArea();
      if (area != 'Unknown' && area != 'Detecting...') {
        updateArea(area);
      }
    } catch (_) {
    } finally {
      _isRefreshingArea = false;
    }
  }

  // ---------- Smart Topic Detection ----------
  Map<String, dynamic> _detectTopic(String question) {
    final lower = question.toLowerCase();

    // Food & Dining
    if (lower.contains('food') || lower.contains('eat') || lower.contains('restaurant') ||
        lower.contains('hawker') || lower.contains('cafe') || lower.contains('dish') ||
        lower.contains('bak kut teh') || lower.contains('nasi lemak') || lower.contains('satay') ||
        lower.contains('laksa') || lower.contains('roti') || lower.contains('cendol') ||
        lower.contains('mamak') || lower.contains('makan')) {
      return {'type': 'food', 'keyword': 'restaurant'};
    }

    // Attractions & Landmarks
    if (lower.contains('attraction') || lower.contains('landmark') || lower.contains('place') ||
        lower.contains('visit') || lower.contains('see') || lower.contains('museum') ||
        lower.contains('park') || lower.contains('garden') || lower.contains('temple') ||
        lower.contains('mosque') || lower.contains('church') || lower.contains('beach') ||
        lower.contains('taman')) {
      return {'type': 'attraction', 'keyword': 'tourist attraction'};
    }

    // Transportation
    if (lower.contains('transport') || lower.contains('bus') || lower.contains('train') ||
        lower.contains('lrt') || lower.contains('ktm') || lower.contains('taxi') ||
        lower.contains('grab') || lower.contains('drive') || lower.contains('station') ||
        lower.contains('terminal') || lower.contains('mrt')) {
      return {'type': 'transport', 'keyword': 'transit station'};
    }

    // Accommodation
    if (lower.contains('hotel') || lower.contains('stay') || lower.contains('homestay') ||
        lower.contains('hostel') || lower.contains('resort') || lower.contains('guesthouse') ||
        lower.contains('airbnb') || lower.contains('accommodation')) {
      return {'type': 'accommodation', 'keyword': 'hotel'};
    }

    // Culture
    if (lower.contains('culture') || lower.contains('custom') || lower.contains('tradition') ||
        lower.contains('festival') || lower.contains('event') || lower.contains('heritage') ||
        lower.contains('history') || lower.contains('local') && lower.contains('practice')) {
      return {'type': 'culture', 'keyword': null}; // Use Gemini knowledge
    }

    // Activities
    if (lower.contains('activity') || lower.contains('do') || lower.contains('fun') ||
        lower.contains('entertain') || lower.contains('night') || lower.contains('market') ||
        lower.contains('shopping') || lower.contains('mall') || lower.contains('hike') ||
        lower.contains('walk') || lower.contains('bike')) {
      return {'type': 'activity', 'keyword': 'point of interest'};
    }

    // Local Services
    if (lower.contains('bank') || lower.contains('clinic') || lower.contains('pharmacy') ||
        lower.contains('hospital') || lower.contains('post') || lower.contains('police') ||
        lower.contains('supermarket') || lower.contains('laundry') || lower.contains('atm') ||
        lower.contains('service') || lower.contains('shop')) {
      return {'type': 'service', 'keyword': 'store'};
    }

    // Default – no topic keyword matched. This is exactly the case where the
    // tourist asked about a specific place by name (e.g. "tell me about
    // Jalan Alor Night Market") rather than a generic category — the name
    // itself usually won't contain any of the keywords checked above. Still
    // give this a real Places search (keyword non-null) instead of skipping
    // straight to "use general knowledge", which is what previously made
    // the assistant answer "I don't have specific information" for a named
    // place it just never looked up.
    return {'type': 'general', 'keyword': 'place'};
  }

  // ---------- Send Message ----------
  Future<void> sendMessage(String question) async {
    // Validate: not empty (C1)
    if (question.trim().isEmpty) {
      _addMessage(Message.error('Please enter a question.'));
      return;
    }
    // Validate: max 500 characters (C2)
    if (question.length > 500) {
      _addMessage(Message.error('Question cannot exceed 500 characters.'));
      return;
    }

    // Check if location is ready
    if (!_isLocationReady) {
      _addMessage(Message.error(
        'Please wait for location detection before asking questions.',
      ));
      return;
    }

    // ✅ ADD USER MESSAGE IMMEDIATELY
    _addMessage(Message(text: question, isUser: true));
    _setLoading(true);

    try {
      // ✅ Check for inappropriate content (A4)
      bool isAppropriate = await _geminiService.isAppropriateRequest(question);
      if (!isAppropriate) {
        _addMessage(Message.error(
          'This request cannot be processed. Please submit an appropriate and supported question.',
        ));
        _setLoading(false);
        return;
      }

      // Enforce the GPS-based geographic boundary before searching Places or
      // asking the answer-generating model. In particular, a future-travel
      // phrase ("I am going to Singapore") must not be treated as though the
      // tourist is already there.
      final isWithinCurrentArea =
          await _geminiService.isRequestWithinCurrentArea(
        question: question,
        currentArea: _currentArea,
      );
      if (!isWithinCurrentArea) {
        _addMessage(Message(
          text: 'I\'m sorry, I can only provide information about '
              '$_currentArea based on your current location. Plans to visit '
              'another area don\'t change this restriction. Please ask again '
              'after your device location updates there.',
          isUser: false,
          messageType: 'ai',
        ));
        _setLoading(false);
        return;
      }

      // ---------- DETECT TOPIC ----------
      var topic = _detectTopic(question);
      String topicType = topic['type'];
      String? keyword = topic['keyword'];

      String additionalContext = '';

      // ---------- SEARCH GOOGLE PLACES (if keyword is available) ----------
      if (keyword != null && _isLocationReady) {
        final position = await _locationService.getCurrentPosition();

        if (position != null) {
          final places = await _locationService.searchNearbyAttractions(
            latitude: position['latitude']!,
            longitude: position['longitude']!,
            radius: 2000, // 2km radius
            keyword: question, // Use the whole question as keyword (Google Places handles it)
            type: null, // Don't restrict type – let Google decide
          );

          // Drop venues Google already marks as shut down — recommending a
          // permanently/temporarily closed place is worse than recommending
          // nothing. Places missing the field (legacy API doesn't always
          // return it) are kept rather than excluded on missing data.
          var operationalPlaces = places.where((place) {
            final status = place['businessStatus'] ?? 'UNKNOWN';
            return status == 'OPERATIONAL' || status == 'UNKNOWN';
          }).toList();

          // Never recommend a retail/grocery venue (supermarket, mall,
          // convenience store, department store, ...) no matter which topic
          // the question fell into — a free-text keyword search with no
          // type restriction ("i wan to buy some grocery") can still
          // legitimately match one, but it's unrelated to this app's four
          // quest themes (food/culture/heritage/nature), so it's dropped
          // from every topic, not just the quest-aligned ones below.
          operationalPlaces = operationalPlaces.where((place) {
            final types = (place['types'] as List?) ?? const [];
            return !types.any(_offThemeRetailTypes.contains);
          }).toList();

          // Rating floor applies to every topic — an unrated or poorly
          // rated place is never worth recommending, regardless of what was
          // asked. Places missing a Google rating are treated as failing
          // this floor rather than assumed acceptable.
          operationalPlaces = operationalPlaces.where((place) {
            final rating = (place['rating'] as num?)?.toDouble() ?? 0;
            return rating >= 4.0;
          }).toList();

          // "food" and "attraction" topics additionally map onto
          // Map/Puzzle/Trip Path's own four quest categories
          // (food/culture/heritage/nature), so results are further
          // restricted to the same classification those screens already
          // use, dropping anything that lands in _categorise()'s generic
          // "attraction" catch-all (gyms, golf courses, ...) and applying
          // the same review-count ceiling (favours discoverable local spots
          // over the most over-touristed landmarks nearby, e.g. Golden
          // Triangle KL, Pavilion). Other topics (transport/accommodation/
          // activity/service) intentionally keep the broader search — none
          // of them are quest categories in the first place.
          if (topicType == 'food') {
            operationalPlaces = operationalPlaces
                .where((place) => place['route_group'] == 'food')
                .toList();
          } else if (topicType == 'attraction') {
            operationalPlaces = operationalPlaces
                .where((place) =>
                    const {'culture', 'heritage', 'nature'}
                        .contains(place['route_group']))
                .toList();
          }

          if (topicType == 'food' || topicType == 'attraction') {
            operationalPlaces = operationalPlaces.where((place) {
              final reviews =
                  (place['userRatingsTotal'] as num?)?.toInt() ?? 0;
              return reviews >= _minQuestReviewCount &&
                  reviews <= _maxQuestReviewCount;
            }).toList();
          }

          if (operationalPlaces.isNotEmpty) {
            additionalContext = 'Nearby places related to "$topicType" in $_currentArea (from Google Places, only operational):\n';
            for (var place in operationalPlaces.take(10)) {
              final name = place['name'] ?? 'Unknown';
              final rating = place['rating'] ?? 'N/A';
              final vicinity = place['vicinity'] ?? '';
              final openNow = place['openNow'];
              final openStatus = openNow == true
                  ? 'Open now'
                  : openNow == false
                      ? 'Closed now'
                      : 'Hours unknown';
              additionalContext += '- $name (Rating: $rating⭐, Location: $vicinity, $openStatus)\n';
            }
            additionalContext += '\nOnly recommend places from this list — they are confirmed operational. Mention if a place is currently closed so the tourist knows to come back later.';
            debugPrint('📋 Additional Context:\n$additionalContext');
          } else {
            // No results – let Gemini use general knowledge
            additionalContext = 'No specific places found for "$topicType" in $_currentArea. Use your general knowledge about Malaysia and $_currentArea to answer helpfully.';
            debugPrint('⚠️ No places found for "$keyword".');
          }
        } else {
          additionalContext = 'Unable to get location. Use general knowledge about $_currentArea to answer.';
          debugPrint('⚠️ Position is null.');
        }
      } else {
        // For topics like "culture" where we don't need Places data
        additionalContext = 'The user is asking about "$topicType" in $_currentArea. Use your general knowledge about Malaysian culture, transportation, and local information to answer helpfully.';
      }

      // ---------- ONE Gemini Call – Handles Everything ----------
      String response = await _geminiService.chatWithAI(
        question: question,
        currentArea: _currentArea,
        additionalContext: additionalContext,
      );

      _addMessage(Message(
        text: response,
        isUser: false,
        messageType: 'ai',
      ));
    } catch (e) {
      debugPrint('❌ Error in sendMessage: $e');
      _addMessage(Message.error(
        'The AI service or internet connection is currently unavailable. Please try again.',
      ));
    } finally {
      _setLoading(false);
    }
  }

  // ---------- Update Area (Manual override) ----------
  void updateArea(String newArea) {
    if (newArea.trim().isEmpty) return;
    final wasUnknown = _currentArea == 'Unknown' || _currentArea == 'Detecting...';
    // Nothing actually changed — skip the rebuild/notify this would
    // otherwise trigger on every periodic refresh tick.
    if (_currentArea == newArea && !wasUnknown) return;
    final areaChanged = _currentArea != newArea && !wasUnknown;

    _currentArea = newArea;
    _isLocationReady = true;
    notifyListeners();

    if (wasUnknown) {
      _addMessage(Message.areaDetected(newArea));
    } else if (areaChanged) {
      _addMessage(Message.areaChange(newArea));
    }
  }

  // ---------- Clear Messages ----------
  void clearMessages() {
    _messages.clear();
    notifyListeners();
    if (_isLocationReady) {
      _messages.add(Message.areaDetected(_currentArea));
    }
    notifyListeners();
  }

  // ---------- Reset Chat ----------
  void resetChat() {
    _messages.clear();
    _isLoading = false;
    _currentArea = 'Detecting...';
    _isLocationReady = false;
    notifyListeners();
    _detectLocation();
  }

  // ---------- Retry Location ----------
  void retryLocation() {
    _detectLocation();
  }

  // ---------- Private Helpers ----------
  void _addMessage(Message message) {
    _messages.add(message);
    notifyListeners();
  }

  void _setLoading(bool value) {
    _isLoading = value;
    notifyListeners();
  }
}
