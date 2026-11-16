# Enabling real Google / Gemini data

The app runs **without any keys** — OpenStreetMap tiles, a bundled Wangsa Maju
sample, and the AI Assistant showing an "AI service unavailable" message.
Real device GPS works either way (no key needed). Supply keys at run time to
turn on the real services.

> **Never commit a key.** They are passed with `--dart-define` and are not
> stored in the repo.

## 1. Google Maps key (UC-03 View Map + UC-04 nearby places)

1. Go to <https://console.cloud.google.com/> and create (or pick) a project.
2. **Billing** → link a billing account (a recurring monthly free credit
   applies, but billing must be on or every request returns `403`).
3. **APIs & Services → Library** → enable:
   - **Places API (New)**  — UC-03 nearby hidden places
   - **Places API**  (the legacy one) — UC-04 AI Assistant "what's nearby"
   - **Map Tiles API**  — the map background
4. **APIs & Services → Credentials → Create credentials → API key.** Copy it.
5. (Recommended) **Edit the key → API restrictions →** restrict to those three.
   Leave *Application restrictions* = *None* for a demo.

## 2. Gemini key (UC-04 AI Assistant Chat)

1. Go to <https://aistudio.google.com/apikey> → **Create API key**.
2. Copy it. (Free tier is generous; no billing needed to start.)

## 3. Run with the keys

Android emulator / device:

```bash
flutter run \
  --dart-define=GOOGLE_MAPS_API_KEY=AIza...maps \
  --dart-define=GEMINI_API_KEY=AIza...gemini
```

In **Android Studio**: *Run → Edit Configurations… → main.dart →
Additional run args*:

```
--dart-define=GOOGLE_MAPS_API_KEY=AIza...maps --dart-define=GEMINI_API_KEY=AIza...gemini
```

Web / other targets use the same flags.

### Android only — Maps SDK key

UC-05 Trip Path Quest uses `google_maps_flutter`, whose native map needs the
Maps SDK key in the Android manifest (it can't read `--dart-define`). Add it to
**`android/local.properties`** (gitignored):

```
MAPS_API_KEY=AIza...maps
```

Same key as `GOOGLE_MAPS_API_KEY`, but the Maps key also needs **Maps SDK for
Android** enabled. Without it, only the Trip Path navigation map renders blank —
the rest of the app is unaffected.

## 4. What each part does

| Part | Needs a key? | Source with a key | Source without |
| --- | --- | --- | --- |
| Device location (the arrow) | no | `geolocator` (real GPS, asks permission) | fixed Wangsa Maju point |
| Current-area name (AI chat header) | no | reverse geocode via `geocoding` | "Wangsa Maju" |
| Nearby hidden places (map markers) | Maps key | Places API (New) `searchNearby` | bundled sample list |
| Map tiles (background) | Maps key | Google Map Tiles API | OpenStreetMap |
| AI Assistant answers | Gemini key | Gemini `gemini-2.5-flash` | "AI service unavailable" |
| AI "what's nearby" grounding | Maps key | Places API (legacy) Nearby Search | AI answers without live place data |

The exact attraction coordinate from Places is **never** shown — `MapRepository`
moves each marker to a deterministic ~300–650 m "general area" so the real
location stays hidden until the game reveals it (UC-03 C3 / FR03_6).

## 5. Troubleshooting

| Symptom | Cause |
| --- | --- |
| Still shows "Add a Google Map Tiles API key" + OSM | key not passed, or `Map Tiles API` not enabled |
| Map error "Places API returned 403" | billing not enabled, or key restricted away from Places API (New) |
| Map error "Places API returned 400" | `Places API (New)` not enabled (the legacy "Places API" is a different product) |
| AI Assistant: "AI service or internet connection is currently unavailable" | `GEMINI_API_KEY` not passed, or the key is invalid |
| AI Assistant gives generic answers, never lists real nearby places | legacy **Places API** not enabled on the Maps key |
| Location arrow missing, "Enable location" prompt | emulator has no location set — in the emulator's **⋯ → Location** tab, set a point and click *Set Location* |
