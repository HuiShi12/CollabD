import 'dart:typed_data';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../../Data_layer/repository/Reward Repository/reward_models.dart';
import '../../viewmodel/Manage Reward  ViewModel/postcard_editor_viewmodel.dart';
import 'reward_image.dart';

class PostcardDragItem {
  final PostcardElementType type;
  final String content;
  const PostcardDragItem(this.type, this.content);
}

/// Editor and saved preview use exactly the same 3:2 composition.
class PostcardCanvas extends StatefulWidget {
  final PostcardDesign design;
  final List<TouristReward> rewards;
  final PostcardEditorViewModel? editor;
  final GlobalKey? captureKey;
  const PostcardCanvas({
    super.key,
    required this.design,
    required this.rewards,
    this.editor,
    this.captureKey,
  });
  @override
  State<PostcardCanvas> createState() => _PostcardCanvasState();
}

class _PostcardCanvasState extends State<PostcardCanvas> {
  final surfaceKey = GlobalKey();
  PostcardDesign get design => widget.design;
  List<TouristReward> get rewards => widget.rewards;
  PostcardEditorViewModel? get editor => widget.editor;
  GlobalKey? get captureKey => widget.captureKey;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final width = math.min(
        box.maxWidth,
        box.maxHeight.isFinite ? box.maxHeight * 1.5 : box.maxWidth,
      );
      final height = width / 1.5;
      return Center(
        child: SizedBox(
          width: width,
          height: height,
          child: DragTarget<PostcardDragItem>(
            onWillAcceptWithDetails: (_) => editor != null,
            onAcceptWithDetails: (details) {
              final render =
                  surfaceKey.currentContext?.findRenderObject() as RenderBox?;
              if (render == null) return;
              final local = render.globalToLocal(details.offset);
              editor?.add(
                details.data.type,
                details.data.content,
                x: local.dx / width,
                y: local.dy / height,
              );
            },
            builder: (context, candidates, rejected) => DecoratedBox(
              decoration: BoxDecoration(
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: .13),
                    blurRadius: 24,
                    offset: const Offset(0, 8),
                  ),
                ],
                border: candidates.isNotEmpty
                    ? Border.all(color: const Color(0xFF7865D8), width: 3)
                    : null,
              ),
              child: RepaintBoundary(
                key: captureKey,
                child: ClipRect(
                  key: surfaceKey,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: editor == null ? null : () => editor!.select(null),
                    child: Stack(
                      children: [
                        Positioned.fill(
                          child: PostcardBackground(
                            design: design,
                            rewards: rewards,
                          ),
                        ),
                        ...design.elements.map(
                          (e) => Positioned(
                            key: ValueKey('canvas-${e.id}'),
                            left: (e.x - e.width / 2) * width,
                            top: (e.y - e.height / 2) * height,
                            width: e.width * width,
                            height: e.height * height,
                            child: _MovableElement(
                              element: e,
                              editor: editor,
                              canvasSize: Size(width, height),
                              rewards: rewards,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}

class _MovableElement extends StatefulWidget {
  final PostcardElement element;
  final PostcardEditorViewModel? editor;
  final Size canvasSize;
  final List<TouristReward> rewards;
  const _MovableElement({
    required this.element,
    required this.editor,
    required this.canvasSize,
    required this.rewards,
  });
  @override
  State<_MovableElement> createState() => _MovableElementState();
}

class _MovableElementState extends State<_MovableElement> {
  Offset _origin = Offset.zero;
  final GlobalKey _boxKey = GlobalKey();
  @override
  Widget build(BuildContext context) {
    final e = widget.element, vm = widget.editor;
    final selected = vm?.selectedId == e.id;
    return Transform.rotate(
      angle: e.rotation,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: vm == null ? null : () => vm.select(e.id),
        onScaleStart: vm == null
            ? null
            : (details) {
                _origin = details.focalPoint;
                vm.beginGesture(e.id);
              },
        onScaleUpdate: vm == null
            ? null
            : (details) {
                final delta = details.focalPoint - _origin;
                vm.transformGesture(
                  delta.dx / widget.canvasSize.width,
                  delta.dy / widget.canvasSize.height,
                  details.scale,
                  details.rotation,
                );
              },
        onScaleEnd: vm == null ? null : (_) => vm.endGesture(),
        child: Stack(
          key: _boxKey,
          clipBehavior: Clip.none,
          fit: StackFit.expand,
          children: [
            Padding(
              padding: const EdgeInsets.all(2),
              child: PostcardElementVisual(element: e, rewards: widget.rewards),
            ),
            if (selected)
              IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: const Color(0xFF7960D9),
                      width: 1.5,
                    ),
                  ),
                ),
              ),
            if (selected)
              Positioned(
                right: -12,
                bottom: -12,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onPanStart: vm == null
                      ? null
                      : (_) => vm.beginGesture(e.id),
                  // Absolute drag, not delta-based: the handle's distance
                  // from the element's centre (in real screen pixels, via
                  // the RenderBox — sidesteps needing to un-rotate the
                  // element's own Transform.rotate by hand) sets size, and
                  // the angle from centre to the finger sets rotation, so
                  // the corner always tracks directly under the touch
                  // point rather than drifting from an accumulated delta.
                  onPanUpdate: vm == null
                      ? null
                      : (details) {
                          final box =
                              _boxKey.currentContext!.findRenderObject()
                                  as RenderBox;
                          final size = box.size;
                          final half = Offset(size.width / 2, size.height / 2);
                          final globalCenter = box.localToGlobal(half);
                          final fromCenter =
                              details.globalPosition - globalCenter;
                          final restAngle = math.atan2(half.dy, half.dx);
                          final halfDiagonal = half.distance;
                          final scale = halfDiagonal == 0
                              ? 1.0
                              : fromCenter.distance / halfDiagonal;
                          final newWidth = (e.width * scale).clamp(.08, .95);
                          final newHeight = (e.height * newWidth / e.width)
                              .clamp(.08, .95);
                          vm.updateSelected(
                            e.copyWith(
                              width: newWidth,
                              height: newHeight,
                              rotation: fromCenter.direction - restAngle,
                            ),
                            history: false,
                          );
                        },
                  onPanEnd: vm == null ? null : (_) => vm.endGesture(),
                  child: Container(
                    width: 24,
                    height: 24,
                    alignment: Alignment.center,
                    color: Colors.transparent,
                    child: Container(
                      width: 9,
                      height: 9,
                      decoration: BoxDecoration(
                        color: Colors.white,
                        border: Border.all(color: const Color(0xFF7960D9)),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class PostcardElementVisual extends StatelessWidget {
  final PostcardElement element;
  final List<TouristReward> rewards;
  const PostcardElementVisual({
    super.key,
    required this.element,
    this.rewards = const [],
  });
  @override
  Widget build(BuildContext context) {
    final e = element;
    if (e.type == PostcardElementType.text) {
      return FittedBox(
        fit: BoxFit.contain,
        child: Text(
          e.content,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: Color(e.color),
            fontSize: 32,
            height: 1.1,
            fontFamily: e.bold ? 'serif' : null,
            fontWeight: e.bold ? FontWeight.w800 : FontWeight.w400,
          ),
        ),
      );
    }
    if (e.type == PostcardElementType.reward) {
      final found = rewards.where((r) => r.id == e.content);
      if (found.isEmpty) {
        return const Center(child: Icon(Icons.broken_image_outlined));
      }
      return FittedBox(
        fit: BoxFit.contain,
        child: SizedBox(width: 220, child: RewardVisual(reward: found.first)),
      );
    }
    return StickerVisual(name: e.content, color: Color(e.color));
  }
}

class StickerVisual extends StatelessWidget {
  final String name;
  final Color color;
  const StickerVisual({
    super.key,
    required this.name,
    this.color = const Color(0xFFDDAB78),
  });
  @override
  Widget build(BuildContext context) {
    if (name == 'tape') {
      return Center(
        child: FractionallySizedBox(
          heightFactor: .38,
          child: Container(color: color.withValues(alpha: .8)),
        ),
      );
    }
    if (name == 'ticket') {
      return FittedBox(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
          decoration: BoxDecoration(
            color: const Color(0xFFFFF3D5),
            border: Border.all(color: color, width: 3),
          ),
          child: Text(
            'MEMORIES\nMALAYSIA',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.w900,
              fontSize: 17,
            ),
          ),
        ),
      );
    }
    final icon = switch (name) {
      'flower' => Icons.local_florist,
      'sun' => Icons.wb_sunny_rounded,
      'heart' => Icons.favorite,
      'star' => Icons.star_rounded,
      'leaf' => Icons.eco,
      _ => Icons.auto_awesome,
    };
    return FittedBox(child: Icon(icon, color: color, size: 80));
  }
}

class PostcardBackground extends StatefulWidget {
  final PostcardDesign design;
  final List<TouristReward> rewards;
  const PostcardBackground({
    super.key,
    required this.design,
    this.rewards = const [],
  });
  @override
  State<PostcardBackground> createState() => _PostcardBackgroundState();
}

class _PostcardBackgroundState extends State<PostcardBackground> {
  Uint8List? _photo;
  PostcardDesign get design => widget.design;
  List<TouristReward> get rewards => widget.rewards;
  @override
  void initState() {
    super.initState();
    _readPhoto();
  }

  @override
  void didUpdateWidget(covariant PostcardBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.design.backgroundImage != design.backgroundImage) {
      _readPhoto();
    }
  }

  void _readPhoto() {
    try {
      final source = design.backgroundImage;
      _photo = source == null ? null : base64Decode(source.split(',').last);
    } catch (_) {
      _photo = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (design.backgroundType == 'Phone Image') {
      if (_photo == null) return const ColoredBox(color: Color(0xFFE9E5DD));
      return Image.memory(
        _photo!,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        errorBuilder: (_, error, stack) =>
            const ColoredBox(color: Color(0xFFE9E5DD)),
      );
    }
    if (design.backgroundType == 'Reward Image') {
      final found = rewards.where((r) => r.id == design.backgroundRewardId);
      if (found.isNotEmpty) {
        return RewardImage(
          imageUrl: found.first.imageUrl,
          label: found.first.title,
        );
      }
    }
    return CustomPaint(
      painter: _BackgroundPainter(
        design.template,
        Color(design.backgroundColor),
      ),
    );
  }
}

class _BackgroundPainter extends CustomPainter {
  final String template;
  final Color color;
  _BackgroundPainter(this.template, this.color);
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = color);
    if (template == 'plain') return;
    canvas.save();
    canvas.scale(size.width / 600, size.height / 400);
    if (template == 'tropical') {
      canvas.drawCircle(
        const Offset(505, 83),
        55,
        Paint()..color = const Color(0xFFB6B778).withValues(alpha: .25),
      );
      _hill(canvas, const Color(0xFF265A4B), 268, 60);
      _hill(canvas, const Color(0xFF39715A), 326, -45);
      _leaf(canvas, const Offset(-5, 250), -.45, const Color(0xFF4E8064));
      _leaf(canvas, const Offset(595, 170), 2.7, const Color(0xFF356C55));
      canvas.drawRect(
        const Rect.fromLTWH(16, 16, 568, 368),
        Paint()
          ..color = const Color(0xFFCFD4A0).withValues(alpha: .5)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );
    } else if (template == 'sunset') {
      canvas.drawCircle(
        const Offset(480, 110),
        82,
        Paint()..color = const Color(0xFFE79669),
      );
      _hill(canvas, const Color(0xFFE7A880), 270, -40);
      _hill(canvas, const Color(0xFFD58569), 328, 35);
      final p = Paint()
        ..color = const Color(0xFFBE6A57)
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke;
      for (var i = 0; i < 4; i++) {
        canvas.drawArc(
          Rect.fromLTWH(27, 40 + i * 8, 80, 30),
          math.pi,
          math.pi,
          false,
          p,
        );
      }
    } else {
      final p = Paint()..color = const Color(0xFFB75D46);
      canvas.drawRect(const Rect.fromLTWH(0, 0, 600, 12), p);
      canvas.drawRect(const Rect.fromLTWH(0, 388, 600, 12), p);
      for (var i = 0; i < 12; i++) {
        final x = i * 54.0;
        canvas.drawCircle(
          Offset(x, 400),
          35,
          Paint()..color = const Color(0xFFDDBA73),
        );
        canvas.drawCircle(
          Offset(x + 27, 0),
          17,
          Paint()..color = const Color(0xFFE7C998),
        );
      }
      _leaf(canvas, const Offset(0, 285), -.5, const Color(0xFF779370));
    }
    canvas.restore();
  }

  void _hill(Canvas c, Color fill, double y, double bend) {
    final path = Path()
      ..moveTo(0, y)
      ..cubicTo(150, y - 60 + bend, 360, y + 90, 600, y - 30)
      ..lineTo(600, 400)
      ..lineTo(0, 400)
      ..close();
    c.drawPath(path, Paint()..color = fill);
  }

  void _leaf(Canvas c, Offset at, double angle, Color fill) {
    c.save();
    c.translate(at.dx, at.dy);
    c.rotate(angle);
    final paint = Paint()..color = fill;
    c.drawLine(Offset.zero, const Offset(140, 0), paint..strokeWidth = 3);
    for (var i = 1; i < 7; i++) {
      final x = i * 18.0;
      final path = Path()
        ..moveTo(x, 0)
        ..quadraticBezierTo(x - 30, -48, x + 12, -62)
        ..quadraticBezierTo(x + 27, -22, x, 0)
        ..quadraticBezierTo(x - 24, 48, x + 16, 55)
        ..quadraticBezierTo(x + 29, 18, x, 0);
      c.drawPath(path, paint..style = PaintingStyle.fill);
    }
    c.restore();
  }

  @override
  bool shouldRepaint(covariant _BackgroundPainter old) =>
      old.template != template || old.color != color;
}
