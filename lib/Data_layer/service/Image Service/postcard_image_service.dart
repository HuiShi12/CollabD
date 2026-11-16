import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:image_picker/image_picker.dart';

/// Gallery access is used only by the postcard feature. Games still use camera.
class PostcardImageService {
  final ImagePicker picker;
  PostcardImageService({ImagePicker? picker})
    : picker = picker ?? ImagePicker();
  Future<String?> pickBackground() async {
    final file = await picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 1600,
      maxHeight: 1600,
      imageQuality: 85,
    );
    if (file == null) return null;
    if (await file.length() > 12 * 1024 * 1024) {
      throw StateError('Choose an image smaller than 12 MB.');
    }
    return normalize(await file.readAsBytes());
  }

  Future<String> normalize(Uint8List bytes) async {
    if (bytes.isEmpty || bytes.length > 12 * 1024 * 1024) {
      throw StateError('Choose a valid image smaller than 12 MB.');
    }
    final codec = await ui.instantiateImageCodec(bytes, targetWidth: 1200);
    try {
      final frame = await codec.getNextFrame();
      try {
        final png = await frame.image.toByteData(
          format: ui.ImageByteFormat.png,
        );
        if (png == null) throw StateError('This image cannot be read.');
        return 'data:image/png;base64,${base64Encode(png.buffer.asUint8List())}';
      } finally {
        frame.image.dispose();
      }
    } finally {
      codec.dispose();
    }
  }

  Future<String> encodePreview(Uint8List png) async {
    if (png.isEmpty || png.length > 12 * 1024 * 1024) {
      throw StateError('Postcard preview could not be generated.');
    }
    // Decode before saving so corrupt render output never becomes a saved image.
    final codec = await ui.instantiateImageCodec(png);
    try {
      final frame = await codec.getNextFrame();
      frame.image.dispose();
    } finally {
      codec.dispose();
    }
    return 'data:image/png;base64,${base64Encode(png)}';
  }
}
