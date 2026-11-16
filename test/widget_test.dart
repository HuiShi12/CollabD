import 'package:collab_d/Data_layer/repository/Map Repository/map.dart';
import 'package:collab_d/Data_layer/service/Location Service/location.dart';
import 'package:collab_d/External_services/Google Maps Platform and Location Services/gm.dart';
import 'package:collab_d/UI_layer/view/Map View/map.dart';
import 'package:collab_d/UI_layer/viewmodel/Map ViewModel/map_viewmodel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

Widget _harness({void Function(BuildContext, MapGameHandoff)? onHandoff}) {
  final location = LocationService(GoogleMapsPlatformExternal());
  return MaterialApp(
    home: ChangeNotifierProvider(
      create: (_) => MapViewModel(
        // Pinned to the bundled sample data's own calibrated 5km, independent
        // of whatever radius MapRepository ships with in production — these
        // widget tests need all 3 sample Heritage Site places in range for
        // the Trip Path availability assertions below.
        mapRepository: MapRepository(location, maxProximityRadiusKm: 5),
        locationService: location,
      ),
      child: MapView(
        bundledMapForTesting: true,
        onGameHandoff: onHandoff,
      ),
    ),
  );
}

void main() {
  testWidgets('View Map shows the area, both buttons and neutral markers only',
      (tester) async {
    await tester.pumpWidget(_harness());
    await tester.pump(); // start loadMap
    await tester.pump(const Duration(seconds: 1)); // resolve mock delays

    expect(find.text('Wangsa Maju, KL'), findsOneWidget);
    expect(find.text('Puzzle'), findsOneWidget);
    expect(find.text('Theme'), findsOneWidget);
    expect(find.byKey(const ValueKey('bundled-map-image')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('proximity-marker-hp_area_01')),
      findsOneWidget,
    );
  });

  testWidgets('tapping a marker reveals only general category + approx distance',
      (tester) async {
    MapGameHandoff? captured;
    await tester.pumpWidget(_harness(onHandoff: (_, h) => captured = h));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    await tester.tap(find.byKey(const ValueKey('proximity-marker-hp_area_01')));
    await tester.pump(); // VM selects
    await tester.pump(); // post-frame opens the sheet
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Heritage Site'), findsOneWidget);
    expect(find.text('Less than 2 km away'), findsOneWidget);
    expect(find.text('Play Puzzle'), findsOneWidget);
    expect(find.text('Start Trip Path'), findsOneWidget); // 3 heritage places
    expect(find.textContaining('GPS'), findsNothing);
    expect(find.textContaining('Jalan'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('marker-mode-puzzle')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(captured, isNotNull);
    expect(captured!.mode, ProximityGameMode.puzzle);
    expect(captured!.entrySource, MapGameEntrySource.proximityGameMarker);
    expect(captured!.marker?.generalCategory, 'Heritage Site');
  });

  testWidgets('Puzzle button hands off a general search', (tester) async {
    MapGameHandoff? captured;
    await tester.pumpWidget(_harness(onHandoff: (_, h) => captured = h));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    await tester.tap(find.byKey(const ValueKey('puzzle-map-chip')));
    await tester.pump();

    expect(captured, isNotNull);
    expect(captured!.entrySource, MapGameEntrySource.puzzleButton);
    expect(captured!.marker, isNull);
  });
}
