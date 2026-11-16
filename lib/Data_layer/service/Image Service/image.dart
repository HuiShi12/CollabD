import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart' show BoxFit, paintImage;
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

class ImageService {
  /// Uploads the captured verified-visit photo to the `verified-photos`
  /// Supabase Storage bucket and returns its real public URL — a URL, not
  /// the image bytes, so reward records stay small and RewardImage (which
  /// only renders http(s) URLs) can actually display it.
  Future<String> uploadCapturedPhoto({required File capturedPhoto}) async {
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null) {
      throw StateError('Please sign in before submitting a visit photo.');
    }

    final extension = capturedPhoto.path.contains('.')
        ? capturedPhoto.path.split('.').last.toLowerCase()
        : 'jpg';
    final path =
        '$userId/visit_${DateTime.now().millisecondsSinceEpoch}.$extension';

    final bytes = await capturedPhoto.readAsBytes();
    await Supabase.instance.client.storage
        .from('verified-photos')
        .uploadBinary(
          path,
          bytes,
          fileOptions: const FileOptions(cacheControl: '3600', upsert: false),
        )
        .timeout(
          const Duration(seconds: 20),
          onTimeout: () => throw StateError(
            'Uploading the visit photo timed out. Check your connection and try again.',
          ),
        );

    return Supabase.instance.client.storage
        .from('verified-photos')
        .getPublicUrl(path);
  }

  String getReferenceImageUrl({required String imageUrl}) {
    return imageUrl;
  }

  /// Draws the verified photo inside the chosen frame plus the place/
  /// township/date text, then uploads the result to the `digital-travel-
  /// stamps` Supabase Storage bucket and returns its real public URL — the
  /// composed image itself lives in Storage, not as bytes in the reward
  /// record, so this stays consistent with uploadCapturedPhoto above.
  Future<String> composeDigitalTravelStamp({
    required String verifiedPhotoUrl,
    required String hiddenPlaceName,
    required String township,
    required DateTime completionDate,
    required String frameUrl,
  }) async {
    if (verifiedPhotoUrl.trim().isEmpty) {
      throw StateError('Verified tourist photo is unavailable.');
    }
    if (hiddenPlaceName.trim().isEmpty || township.trim().isEmpty) {
      throw StateError(
        'Digital Travel Stamp source information is incomplete.',
      );
    }
    if (frameUrl.trim().isEmpty) {
      throw StateError('Digital Travel Stamp frame is unavailable.');
    }

    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null) {
      throw StateError('Please sign in before generating a Digital Travel Stamp.');
    }

    final frameImage = await _decodeNetworkImage(frameUrl);
    final photoImage = await _decodeNetworkImage(verifiedPhotoUrl);

    final width = frameImage.width.toDouble();
    final height = frameImage.height.toDouble();

    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(
      recorder,
      ui.Rect.fromLTWH(0, 0, width, height),
    );

    // The frame PNG is a postmark-style circular seal: opaque everywhere
    // except a transparent circular window in the middle. The photo is
    // drawn covering that window's bounding box first, then the frame is
    // drawn on top — its opaque background masks the photo's square
    // corners outside the circle, and the title/caption bands.
    final photoRect = ui.Rect.fromLTWH(
      width * 0.0875,
      height * 0.1545,
      width * 0.825,
      height * 0.6,
    );
    paintImage(
      canvas: canvas,
      rect: photoRect,
      image: photoImage,
      fit: BoxFit.cover,
    );
    canvas.drawImageRect(
      frameImage,
      ui.Rect.fromLTWH(0, 0, width, height),
      ui.Rect.fromLTWH(0, 0, width, height),
      ui.Paint(),
    );

    _drawCenteredText(
      canvas: canvas,
      text: 'MYSTERY MALAYSIA • DIGITAL TRAVEL STAMP',
      fontSize: width * 0.032,
      bold: true,
      centerY: height * 0.0636,
      maxWidth: width * 0.89,
      offsetX: width * 0.055,
    );

    final caption =
        '$hiddenPlaceName\n$township\n${completionDate.day.toString().padLeft(2, "0")}/'
        '${completionDate.month.toString().padLeft(2, "0")}/${completionDate.year}';
    _drawCenteredText(
      canvas: canvas,
      text: caption,
      fontSize: width * 0.04,
      bold: false,
      centerY: height * 0.9136,
      maxWidth: width * 0.89,
      offsetX: width * 0.055,
    );

    final picture = recorder.endRecording();
    final composedImage = await picture.toImage(
      width.round(),
      height.round(),
    );
    final pngData = await composedImage.toByteData(
      format: ui.ImageByteFormat.png,
    );
    frameImage.dispose();
    photoImage.dispose();
    composedImage.dispose();
    if (pngData == null) {
      throw StateError('The Digital Travel Stamp could not be rendered.');
    }

    final path =
        '$userId/stamp_${DateTime.now().millisecondsSinceEpoch}.png';
    await Supabase.instance.client.storage
        .from('digital-travel-stamps')
        .uploadBinary(
          path,
          pngData.buffer.asUint8List(),
          fileOptions: const FileOptions(
            cacheControl: '3600',
            upsert: false,
            contentType: 'image/png',
          ),
        )
        .timeout(
          const Duration(seconds: 20),
          onTimeout: () => throw StateError(
            'Uploading the Digital Travel Stamp timed out. Check your connection and try again.',
          ),
        );

    return Supabase.instance.client.storage
        .from('digital-travel-stamps')
        .getPublicUrl(path);
  }

  void _drawCenteredText({
    required ui.Canvas canvas,
    required String text,
    required double fontSize,
    required bool bold,
    required double centerY,
    required double maxWidth,
    required double offsetX,
  }) {
    final builder = ui.ParagraphBuilder(
      ui.ParagraphStyle(
        textAlign: ui.TextAlign.center,
        fontSize: fontSize,
        fontWeight: bold ? ui.FontWeight.bold : ui.FontWeight.normal,
      ),
    )
      ..pushStyle(ui.TextStyle(color: const ui.Color(0xFF07162D)))
      ..addText(text);
    final paragraph = builder.build()
      ..layout(ui.ParagraphConstraints(width: maxWidth));
    canvas.drawParagraph(
      paragraph,
      ui.Offset(offsetX, centerY - paragraph.height / 2),
    );
  }

  Future<ui.Image> _decodeNetworkImage(String url) async {
    final response = await http
        .get(Uri.parse(url))
        .timeout(
          const Duration(seconds: 15),
          onTimeout: () => throw StateError(
            'Downloading an image for the Digital Travel Stamp timed out.',
          ),
        );
    if (response.statusCode != 200 || response.bodyBytes.isEmpty) {
      throw StateError('Could not download image from $url.');
    }
    final codec = await ui.instantiateImageCodec(response.bodyBytes);
    try {
      final frame = await codec.getNextFrame();
      return frame.image;
    } finally {
      codec.dispose();
    }
  }
}
