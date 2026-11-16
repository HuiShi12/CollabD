# collab_d

Mystery Malaysia — tourism exploration game.

## View Map (UC-03)

Uses real device GPS, and — with a `GOOGLE_MAPS_API_KEY` supplied at run time —
real Google Map Tiles + nearby attractions from the Places API (New). Without a
key it falls back to OpenStreetMap tiles and a bundled sample. Setup:
**[GOOGLE_SETUP.md](GOOGLE_SETUP.md)**.

```bash
flutter run --dart-define=GOOGLE_MAPS_API_KEY=YOUR_KEY   # never commit the key
```

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Learn Flutter](https://docs.flutter.dev/get-started/learn-flutter)
- [Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Flutter learning resources](https://docs.flutter.dev/reference/learning-resources)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.
