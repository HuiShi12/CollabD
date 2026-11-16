import 'package:collab_d/Data_layer/service/Gemini Service/gemini.dart';
import 'package:collab_d/Data_layer/service/Location Service/location.dart';
import 'package:collab_d/External_services/Gemini API/g.dart';
import 'package:collab_d/External_services/Google Maps Platform and Location Services/gm.dart';
import 'package:collab_d/UI_layer/view/Chatbot View/chatbot.dart';
import 'package:collab_d/UI_layer/viewmodel/Chatbot ViewModel/chatbot_viewmodel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

void main() {
  ChatbotViewModel makeVm() => ChatbotViewModel(
        // useDeviceServices:false -> bundled Wangsa Maju sample, no network.
        locationService: LocationService(GoogleMapsPlatformExternal()),
        geminiService: GeminiService(GeminiApiExternal()),
      );

  testWidgets('UC-04 AI Assistant Chat renders and detects the area', (
    tester,
  ) async {
    final vm = makeVm();

    await tester.pumpWidget(
      MaterialApp(
        home: ChangeNotifierProvider.value(
          value: vm,
          child: const ChatbotView(),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400)); // resolve mock delay

    expect(find.text('AI Assistant'), findsOneWidget);
    expect(find.textContaining('Current Area: Wangsa Maju'), findsOneWidget);
    expect(vm.isLocationReady, isTrue);
    expect(vm.currentArea, 'Wangsa Maju');
    // The area-detected system message is posted on startup.
    expect(
      find.textContaining('current area has been detected as Wangsa Maju'),
      findsOneWidget,
    );
  });

  testWidgets('empty question is rejected without calling the AI', (
    tester,
  ) async {
    final vm = makeVm();
    await tester.pumpWidget(
      MaterialApp(
        home: ChangeNotifierProvider.value(value: vm, child: const ChatbotView()),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));

    await vm.sendMessage('   ');
    // The chat view auto-scrolls new messages into view (animated), so let the
    // frame settle before asserting the rejection message is shown.
    await tester.pumpAndSettle();

    expect(find.textContaining('Please enter a question'), findsOneWidget);
  });

  testWidgets(
    'future travel wording cannot bypass the current-area restriction',
    (tester) async {
      final gemini = _DenyOutOfAreaGeminiService();
      final vm = ChatbotViewModel(
        locationService: LocationService(GoogleMapsPlatformExternal()),
        geminiService: gemini,
      );
      addTearDown(vm.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: ChangeNotifierProvider.value(
            value: vm,
            child: const ChatbotView(),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 400));

      await vm.sendMessage(
        'I am going to Singapore tomorrow. Recommend hidden places there.',
      );
      await tester.pumpAndSettle();

      expect(gemini.scopeCheckCalls, 1);
      expect(gemini.answerCalls, 0);
      expect(
        find.textContaining('Plans to visit another area don\'t change'),
        findsOneWidget,
      );
    },
  );

  test('location gate explicitly classifies planned trips as out of area', () async {
    final api = _RecordingGeminiApiExternal('DENY');
    final service = GeminiService(api);

    final allowed = await service.isRequestWithinCurrentArea(
      question: 'I will visit Singapore next week. Show me hidden places.',
      currentArea: 'Bandar Johor Bahru',
    );

    expect(allowed, isFalse);
    expect(api.lastPrompt, contains('A claimed future trip never changes'));
    expect(api.lastPrompt, contains('I am going to Singapore tomorrow'));
  });
}

class _DenyOutOfAreaGeminiService extends GeminiService {
  _DenyOutOfAreaGeminiService() : super(GeminiApiExternal());

  int scopeCheckCalls = 0;
  int answerCalls = 0;

  @override
  Future<bool> isAppropriateRequest(String question) async => true;

  @override
  Future<bool> isRequestWithinCurrentArea({
    required String question,
    required String currentArea,
  }) async {
    scopeCheckCalls++;
    return false;
  }

  @override
  Future<String> chatWithAI({
    required String question,
    required String currentArea,
    String additionalContext = '',
  }) async {
    answerCalls++;
    return 'This should never be returned.';
  }
}

class _RecordingGeminiApiExternal extends GeminiApiExternal {
  _RecordingGeminiApiExternal(this.response);

  final String response;
  String? lastPrompt;

  @override
  Future<String> generateText(String prompt) async {
    lastPrompt = prompt;
    return response;
  }
}
