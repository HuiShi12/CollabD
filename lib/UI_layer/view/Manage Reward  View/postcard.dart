import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import '../../../main.dart';
import '../../../Data_layer/repository/Reward Repository/reward_models.dart';
import '../../viewmodel/Manage Reward  ViewModel/reward_viewmodel.dart';
import '../../viewmodel/Manage Reward  ViewModel/postcard_editor_viewmodel.dart';
import 'postcard_canvas.dart';
import 'reward_image.dart';

class PostcardEditor extends StatefulWidget {
  final DigitalPostcard? existing;
  const PostcardEditor({super.key, this.existing});
  @override
  State<PostcardEditor> createState() => _PostcardEditorState();
}

class _PostcardEditorState extends State<PostcardEditor> {
  late final PostcardEditorViewModel vm;
  int _tab = 0;
  bool _allowPop = false;
  // Save/Share capture the postcard straight off this screen's own already-
  // laid-out canvas instead of pushing a separate confirmation route just to
  // get a renderable boundary — see _saveDirectly / _shareDirectly.
  final _captureKey = GlobalKey();
  @override
  void initState() {
    super.initState();
    final reward = context.read<RewardViewModel>();
    vm = PostcardEditorViewModel(
      repository: reward.rewardRepository,
      touristId: reward.touristId,
      existing: widget.existing,
    );
    vm.loadResources();
  }

  @override
  void dispose() {
    vm.dispose();
    super.dispose();
  }

  Future<void> _leave() async {
    final discard =
        !vm.dirty ||
        await showDialog<bool>(
              context: context,
              builder: (c) => AlertDialog(
                title: const Text('Discard this edit?'),
                content: const Text(
                  'Your unsaved postcard changes will be lost.',
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(c, false),
                    child: const Text('Keep editing'),
                  ),
                  TextButton(
                    onPressed: () => Navigator.pop(c, true),
                    child: const Text('Discard'),
                  ),
                ],
              ),
            ) ==
            true;
    if (!mounted || !discard) return;
    setState(() => _allowPop = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.pop(context);
    });
  }

  Future<void> _text({bool editing = false}) async {
    final element = editing ? vm.selected : null;
    var text = element?.content ?? '';
    final value = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(editing ? 'Edit your message' : 'Add a message'),
        content: TextFormField(
          initialValue: text,
          autofocus: true,
          maxLength: 500,
          maxLines: 4,
          decoration: const InputDecoration(hintText: 'Wish you were here…'),
          onChanged: (value) => text = value,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              if (text.trim().isNotEmpty) Navigator.pop(c, text.trim());
            },
            child: const Text('Done'),
          ),
        ],
      ),
    );
    if (!mounted || value == null) return;
    if (element != null) {
      vm.updateSelected(element.copyWith(content: value));
    } else {
      vm.add(PostcardElementType.text, value);
    }
  }

  Future<void> _editRotationDegrees(PostcardElement e) async {
    var text = (e.rotation * 180 / math.pi).round().toString();
    final value = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Rotate by degrees'),
        content: TextFormField(
          initialValue: text,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(signed: true),
          decoration: const InputDecoration(suffixText: '°'),
          onChanged: (value) => text = value,
          onFieldSubmitted: (value) => Navigator.pop(c, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, text),
            child: const Text('Apply'),
          ),
        ],
      ),
    );
    if (!mounted || value == null) return;
    final degrees = double.tryParse(value.trim());
    if (degrees == null) return;
    // Normalise to (-180, 180] to match the slider's own -π..π range.
    final normalised = ((degrees + 180) % 360 + 360) % 360 - 180;
    vm.updateSelected(e.copyWith(rotation: normalised * math.pi / 180));
  }

  void _adjust() {
    if (vm.selected == null) return;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (c) => AnimatedBuilder(
        animation: vm,
        builder: (c, _) {
          final e = vm.selected;
          if (e == null) return const SizedBox(height: 80);
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'Size & rotation',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
                  ),
                  Row(
                    children: [
                      const SizedBox(width: 64, child: Text('Size')),
                      Expanded(
                        child: Slider(
                          value: e.width.clamp(.08, .95),
                          min: .08,
                          max: .95,
                          onChangeStart: (_) => vm.beginControlEdit(),
                          onChanged: (value) => vm.updateSelected(
                            e.copyWith(
                              width: value,
                              height: (e.height * value / e.width).clamp(
                                .08,
                                .95,
                              ),
                              x: e.x.clamp(value / 2, 1 - value / 2),
                            ),
                            history: false,
                          ),
                        ),
                      ),
                    ],
                  ),
                  Row(
                    children: [
                      const SizedBox(width: 64, child: Text('Rotate')),
                      Expanded(
                        child: Slider(
                          value: e.rotation.clamp(-math.pi, math.pi),
                          min: -math.pi,
                          max: math.pi,
                          onChangeStart: (_) => vm.beginControlEdit(),
                          onChanged: (value) => vm.updateSelected(
                            e.copyWith(rotation: value),
                            history: false,
                          ),
                        ),
                      ),
                      InkWell(
                        onTap: () => _editRotationDegrees(e),
                        borderRadius: BorderRadius.circular(6),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 4,
                            vertical: 6,
                          ),
                          child: SizedBox(
                            width: 40,
                            child: Text(
                              '${(e.rotation * 180 / math.pi).round()}°',
                              textAlign: TextAlign.end,
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                                decoration: TextDecoration.underline,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  Wrap(
                    spacing: 10,
                    children:
                        [
                              0xFFFFF6DD,
                              0xFF173F39,
                              0xFFB75D46,
                              0xFFD5AF65,
                              0xFF7660D6,
                            ]
                            .map(
                              (color) => InkWell(
                                onTap: () =>
                                    vm.updateSelected(e.copyWith(color: color)),
                                child: CircleAvatar(
                                  radius: 18,
                                  backgroundColor: Color(color),
                                  child: e.color == color
                                      ? const Icon(
                                          Icons.check,
                                          size: 18,
                                          color: Colors.black54,
                                        )
                                      : null,
                                ),
                              ),
                            )
                            .toList(),
                  ),
                  if (e.type == PostcardElementType.text)
                    TextButton(
                      onPressed: () =>
                          vm.updateSelected(e.copyWith(bold: !e.bold)),
                      child: Text(
                        e.bold ? 'Use regular text' : 'Use bold text',
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  // Deselecting hides the selection handles the editor draws over the
  // currently-picked element; those must not show up in the exported image.
  // notifyListeners() from select(null) only takes effect on the *next*
  // frame, so this waits for that frame to actually paint before capturing
  // — a plain endOfFrame right after select(null) isn't reliably late
  // enough for a change that was only just scheduled.
  Future<void> _deselectAndWaitForFrame() {
    vm.select(null);
    final rendered = Completer<void>();
    WidgetsBinding.instance.addPostFrameCallback((_) => rendered.complete());
    return rendered.future;
  }

  Future<Uint8List> _render() async {
    await WidgetsBinding.instance.endOfFrame;
    final boundary =
        _captureKey.currentContext?.findRenderObject()
            as RenderRepaintBoundary?;
    if (boundary == null) {
      throw StateError('Postcard is not ready. Please retry.');
    }
    final image = await boundary.toImage(
      pixelRatio: 1200 / boundary.size.width,
    );
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      if (bytes == null) throw StateError('Postcard cannot be rendered.');
      return bytes.buffer.asUint8List();
    } finally {
      image.dispose();
    }
  }

  // Captures straight off this screen's own canvas (see _captureKey) instead
  // of pushing a separate confirmation route just to get a renderable
  // boundary — tapping the toolbar's Save icon should feel instant, not
  // "open a screen, then save from there".
  Future<void> _saveDirectly() async {
    await _deselectAndWaitForFrame();
    if (!mounted) return;
    final saved = await vm.save(_render);
    if (!mounted || !saved) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Digital Postcard saved successfully.')),
    );
    setState(() => _allowPop = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.pop(context);
    });
  }

  // Same reasoning as _saveDirectly — tapping the toolbar's Share icon
  // should feel like "share now", not "open the same screen as Save and
  // then share from there".
  Future<void> _shareDirectly() async {
    await _deselectAndWaitForFrame();
    if (!mounted) return;
    try {
      final bytes = await _render();
      if (!mounted) return;
      await SharePlus.instance.share(
        ShareParams(
          files: [
            XFile.fromData(bytes, mimeType: 'image/png', name: 'postcard.png'),
          ],
          text: 'A little piece of Malaysia — my Digital Postcard!',
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not share the postcard. $e')));
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: vm,
    builder: (context, _) {
      return PopScope(
        canPop: _allowPop || !vm.dirty,
        onPopInvokedWithResult: (didPop, result) {
          if (!didPop) _leave();
        },
        child: Scaffold(
          backgroundColor: context.colors.surface,
          appBar: AppBar(
            backgroundColor: context.colors.surface,
            foregroundColor: context.colors.onSurface,
            actions: [
              IconButton(
                tooltip: 'Undo',
                onPressed: vm.canUndo && !vm.busy ? vm.undo : null,
                icon: const Icon(Icons.undo_rounded, size: 21),
              ),
              IconButton(
                tooltip: 'Redo',
                onPressed: vm.canRedo && !vm.busy ? vm.redo : null,
                icon: const Icon(Icons.redo_rounded, size: 21),
              ),
              const SizedBox(width: 6),
              // Both Save and Share briefly open the confirmation route to
              // capture the canvas, then complete and pop themselves — see
              // _saveDirectly / _shareDirectly.
              IconButton(
                tooltip: 'Save',
                onPressed: vm.busy ? null : _saveDirectly,
                icon: const Icon(Icons.save_outlined, size: 21),
              ),
              IconButton(
                tooltip: 'Share',
                onPressed: vm.busy ? null : _shareDirectly,
                icon: const Icon(Icons.share_outlined, size: 21),
              ),
              const SizedBox(width: 6),
            ],
          ),
          body: SafeArea(
            top: false,
            child: Column(
              children: [
                if (vm.busy)
                  LinearProgressIndicator(
                    color: context.colors.primary,
                    minHeight: 2,
                  ),
                if (vm.errorMessage != null)
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            vm.errorMessage!,
                            maxLines: 3,
                            style: TextStyle(
                              color: context.colors.error,
                              fontSize: 12,
                            ),
                          ),
                        ),
                        IconButton(
                          onPressed: vm.loadResources,
                          icon: const Icon(Icons.refresh),
                        ),
                      ],
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Text(
                    vm.selected == null
                        ? 'YOUR POSTCARD  ·  3:2 LANDSCAPE'
                        : 'DRAG TO MOVE  ·  PINCH TO RESIZE & ROTATE',
                    style: TextStyle(
                      fontSize: 9,
                      letterSpacing: 1.4,
                      color: context.colors.onSurfaceVariant,
                    ),
                  ),
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(18, 4, 18, 14),
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 840),
                        child: PostcardCanvas(
                          design: vm.design,
                          rewards: vm.rewards,
                          editor: vm,
                          captureKey: _captureKey,
                        ),
                      ),
                    ),
                  ),
                ),
                SizedBox(
                  height: 46,
                  child: vm.selected == null
                      ? Center(
                          child: Text(
                            'Tap to add. Long-press a tile to drag it onto your postcard.',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 11,
                              color: context.colors.onSurfaceVariant,
                            ),
                          ),
                        )
                      : _elementToolbar(),
                ),
                Container(
                  decoration: BoxDecoration(
                    color: context.colors.surfaceContainerLow,
                    borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(20),
                    ),
                  ),
                  child: Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                _tabTitle,
                                style: TextStyle(
                                  color: context.colors.onSurface,
                                  fontWeight: FontWeight.w700,
                                  fontSize: 14,
                                ),
                              ),
                            ),
                            if (_tab == 0)
                              Text(
                                'REPLACE LAYOUT',
                                style: TextStyle(
                                  fontSize: 8,
                                  letterSpacing: 1,
                                  color: context.colors.onSurfaceVariant,
                                ),
                              ),
                          ],
                        ),
                      ),
                      SizedBox(height: 126, child: _tray()),
                      _navigation(),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );

  String get _tabTitle => [
    'Choose a starting point',
    'Set the scene',
    'Your earned rewards',
    'Little finishing touches',
    'Say it your way',
  ][_tab];

  // Duplicate + Delete grouped at the end (Canva-style) since those are the
  // two actions reached for most; Edit text / Adjust stay as icons here too
  // rather than gestures — double-tap/long-press on the element itself
  // fought with the existing drag-to-move/pinch-to-resize gesture recogniser
  // for arena priority, which broke plain tap-to-select entirely.
  Widget _elementToolbar() => SingleChildScrollView(
    scrollDirection: Axis.horizontal,
    child: Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (vm.selected?.type == PostcardElementType.text)
          _tool(Icons.edit_outlined, 'Edit text', () => _text(editing: true)),
        _tool(Icons.tune, 'Adjust', _adjust),
        const SizedBox(
          height: 24,
          child: VerticalDivider(width: 20, thickness: 1),
        ),
        _tool(Icons.copy_outlined, 'Duplicate', vm.duplicateSelected),
        _tool(
          Icons.delete_outline,
          'Delete',
          vm.deleteSelected,
          color: const Color(0xFFB3261E),
        ),
        const SizedBox(
          height: 24,
          child: VerticalDivider(width: 20, thickness: 1),
        ),
        _tool(
          Icons.flip_to_front,
          'Forward',
          () => vm.moveLayer(1),
        ),
        _tool(
          Icons.flip_to_back,
          'Backward',
          () => vm.moveLayer(-1),
        ),
      ],
    ),
  );
  Widget _tool(
    IconData icon,
    String label,
    VoidCallback action, {
    Color? color,
  }) => TextButton.icon(
    style: TextButton.styleFrom(
      foregroundColor: color ?? context.colors.onSurface,
      padding: const EdgeInsets.symmetric(horizontal: 10),
    ),
    onPressed: vm.busy ? null : action,
    icon: Icon(icon, size: 17),
    label: Text(label, style: const TextStyle(fontSize: 11)),
  );

  Widget _navigation() {
    const icons = [
      Icons.dashboard_outlined,
      Icons.wallpaper,
      Icons.workspace_premium_outlined,
      Icons.local_florist_outlined,
      Icons.text_fields,
    ];
    const labels = ['Templates', 'Background', 'Rewards', 'Stickers', 'Text'];
    return Row(
      children: List.generate(
        5,
        (i) => Expanded(
          child: InkWell(
            onTap: vm.busy ? null : () => setState(() => _tab = i),
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 10),
              decoration: BoxDecoration(
                border: Border(
                  top: BorderSide(
                    color: i == _tab
                        ? context.colors.primary
                        : context.colors.outlineVariant,
                    width: i == _tab ? 2 : 1,
                  ),
                ),
              ),
              child: Column(
                children: [
                  Icon(
                    icons[i],
                    size: 22,
                    color: i == _tab
                        ? context.colors.primary
                        : context.colors.onSurfaceVariant,
                  ),
                  const SizedBox(height: 3),
                  Text(
                    labels[i],
                    style: TextStyle(
                      fontSize: 9,
                      color: i == _tab
                          ? context.colors.primary
                          : context.colors.onSurfaceVariant,
                      fontWeight: i == _tab
                          ? FontWeight.bold
                          : FontWeight.normal,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _tray() {
    if (_tab == 0) {
      return ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.all(12),
        children: [
          for (final entry in {
            'tropical': 'Tropical escape',
            'sunset': 'Golden hour',
            'heritage': 'Heritage notes',
            'plain': 'Blank Template',
          }.entries)
            _tile(
              entry.value,
              SizedBox(
                width: 120,
                height: 76,
                child: PostcardCanvas(
                  design: PostcardEditorViewModel.templateDesign(entry.key),
                  rewards: const [],
                ),
              ),
              () => vm.useTemplate(entry.key),
            ),
        ],
      );
    }
    if (_tab == 1) {
      return ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.all(12),
        children: [
          _tile(
            'Phone Image',
            SizedBox(
              width: 80,
              height: 72,
              child: Icon(
                Icons.add_photo_alternate_outlined,
                color: context.colors.primary,
                size: 32,
              ),
            ),
            vm.pickPhoneBackground,
          ),
          for (final color in [
            0xFFFFFBEE,
            0xFF173F39,
            0xFFF3C2A2,
            0xFFDDE8E2,
            0xFFC9D6E9,
          ])
            _tile(
              'Colour',
              Container(width: 64, height: 72, color: Color(color)),
              () => vm.useColor(color),
            ),
          for (final reward in vm.rewards)
            _tile(
              reward.title,
              SizedBox(
                width: 80,
                height: 72,
                child: RewardImage(
                  imageUrl: reward.imageUrl,
                  label: reward.title,
                ),
              ),
              () => vm.useRewardBackground(reward),
            ),
        ],
      );
    }
    if (_tab == 2) {
      if (vm.rewards.isEmpty) {
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              'Earn a stamp or claim a theme souvenir to decorate with it.\nYou can still use stickers and text.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: context.colors.onSurfaceVariant,
                fontSize: 12,
              ),
            ),
          ),
        );
      }
      return ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.all(12),
        children: vm.rewards
            .map(
              (r) => _draggable(
                r.title,
                PostcardDragItem(PostcardElementType.reward, r.id),
                SizedBox(
                  width: 84,
                  height: 70,
                  child: FittedBox(
                    child: SizedBox(width: 220, child: RewardVisual(reward: r)),
                  ),
                ),
              ),
            )
            .toList(),
      );
    }
    if (_tab == 3) {
      return ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.all(12),
        children:
            [
                  'flower',
                  'sun',
                  'heart',
                  'star',
                  'leaf',
                  'sparkle',
                  'tape',
                  'ticket',
                ]
                .map(
                  (name) => _draggable(
                    name,
                    PostcardDragItem(PostcardElementType.sticker, name),
                    SizedBox(
                      width: 64,
                      height: 70,
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: StickerVisual(
                          name: name,
                          color: const Color(0xFFB75D46),
                        ),
                      ),
                    ),
                  ),
                )
                .toList(),
      );
    }
    return ListView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.all(12),
      children: [
        _tile(
          'Your message',
          SizedBox(
            width: 105,
            height: 70,
            child: Center(
              child: Text(
                'Aa +',
                style: TextStyle(fontSize: 28, color: context.colors.onSurface),
              ),
            ),
          ),
          _text,
        ),
        for (final text in [
          'Wish you were here',
          'Made of memories',
          'Hello, Malaysia!',
        ])
          _draggable(
            text,
            PostcardDragItem(PostcardElementType.text, text),
            SizedBox(
              width: 120,
              height: 70,
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Text(
                    text,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontFamily: 'serif',
                      fontSize: 17,
                      color: context.colors.onSurface,
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _draggable(String label, PostcardDragItem item, Widget child) =>
      LongPressDraggable<PostcardDragItem>(
        data: item,
        maxSimultaneousDrags: vm.busy ? 0 : 1,
        dragAnchorStrategy: pointerDragAnchorStrategy,
        feedback: Material(
          color: Colors.transparent,
          child: Opacity(
            opacity: .85,
            child: SizedBox(width: 84, height: 84, child: child),
          ),
        ),
        childWhenDragging: Opacity(
          opacity: .3,
          child: _tile(label, child, () {}),
        ),
        child: _tile(label, child, () => vm.add(item.type, item.content)),
      );

  Widget _tile(String label, Widget child, VoidCallback action) => Padding(
    padding: const EdgeInsets.only(right: 10),
    child: InkWell(
      onTap: vm.busy ? null : action,
      borderRadius: BorderRadius.circular(8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(7),
            child: ColoredBox(
              color: context.colors.surfaceContainerHighest,
              child: child,
            ),
          ),
          const SizedBox(height: 6),
          SizedBox(
            width: 120,
            child: Text(
              label,
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 10, color: context.colors.onSurface),
            ),
          ),
        ],
      ),
    ),
  );
}

/// Backwards-compatible renderer for postcards saved before the canvas editor.
class PostcardComposition extends StatelessWidget {
  final DigitalPostcard card;
  final List<TouristReward> rewards;
  final GlobalKey? captureKey;
  const PostcardComposition({
    super.key,
    required this.card,
    required this.rewards,
    this.captureKey,
  });
  @override
  Widget build(BuildContext context) => AspectRatio(
    aspectRatio: 1.5,
    child: PostcardCanvas(
      design:
          card.design ??
          PostcardDesign(
            backgroundType: card.backgroundType,
            template: 'plain',
            backgroundColor: card.backgroundColor,
            elements: [
              if (card.message.isNotEmpty)
                PostcardElement(
                  id: 'legacy_text',
                  type: PostcardElementType.text,
                  content: card.message,
                  width: .85,
                  height: .25,
                ),
            ],
          ),
      rewards: rewards,
      captureKey: captureKey,
    ),
  );
}

class SavedPostcardView extends StatefulWidget {
  final DigitalPostcard card;
  final List<TouristReward> rewards;
  const SavedPostcardView({
    super.key,
    required this.card,
    required this.rewards,
  });
  @override
  State<SavedPostcardView> createState() => _SavedPostcardViewState();
}

class _SavedPostcardViewState extends State<SavedPostcardView> {
  // Lets Share capture the postcard straight off this screen's own canvas —
  // same approach as the editor's toolbar Share (see PostcardEditor).
  final _captureKey = GlobalKey();
  bool _sharing = false;

  Future<void> _share() async {
    if (_sharing) return;
    setState(() => _sharing = true);
    try {
      await WidgetsBinding.instance.endOfFrame;
      final boundary =
          _captureKey.currentContext?.findRenderObject()
              as RenderRepaintBoundary?;
      if (boundary == null) {
        throw StateError('Postcard is not ready. Please retry.');
      }
      final image = await boundary.toImage(
        pixelRatio: 1200 / boundary.size.width,
      );
      final Uint8List bytes;
      try {
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        if (data == null) throw StateError('Postcard cannot be rendered.');
        bytes = data.buffer.asUint8List();
      } finally {
        image.dispose();
      }
      if (!mounted) return;
      await SharePlus.instance.share(
        ShareParams(
          files: [
            XFile.fromData(bytes, mimeType: 'image/png', name: 'postcard.png'),
          ],
          text: 'A little piece of Malaysia — my Digital Postcard!',
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not share the postcard. $e')));
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  Future<void> _editDesign() async {
    final rewardVM = context.read<RewardViewModel>();
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ChangeNotifierProvider.value(
          value: rewardVM,
          child: PostcardEditor(existing: widget.card),
        ),
      ),
    );
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final editable = widget.card.design != null;
    return Scaffold(
      backgroundColor: context.colors.surface,
      appBar: AppBar(
        backgroundColor: context.colors.surface,
        foregroundColor: context.colors.onSurface,
        title: const Text('Your Postcard'),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
          child: Column(
            children: [
              Expanded(
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 480),
                    child: Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: context.colors.surfaceContainerLow,
                        borderRadius: BorderRadius.circular(22),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(
                              alpha: context.isDark ? 0.35 : 0.08,
                            ),
                            blurRadius: 16,
                            offset: const Offset(0, 6),
                          ),
                        ],
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(14),
                        child: PostcardComposition(
                          card: widget.card,
                          rewards: widget.rewards,
                          captureKey: _captureKey,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  Expanded(
                    child: SizedBox(
                      height: 50,
                      child: OutlinedButton.icon(
                        onPressed: _sharing ? null : _share,
                        style: OutlinedButton.styleFrom(
                          foregroundColor: context.colors.onSurface,
                          side: BorderSide(color: context.colors.outlineVariant),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                        icon: _sharing
                            ? SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: context.colors.onSurface,
                                ),
                              )
                            : const Icon(Icons.share_outlined, size: 19),
                        label: Text(_sharing ? 'Sharing…' : 'Share'),
                      ),
                    ),
                  ),
                  if (editable) ...[
                    const SizedBox(width: 12),
                    Expanded(
                      child: SizedBox(
                        height: 50,
                        child: FilledButton.icon(
                          onPressed: _editDesign,
                          style: FilledButton.styleFrom(
                            backgroundColor: context.colors.primary,
                            foregroundColor: context.colors.onPrimary,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                          ),
                          icon: const Icon(Icons.edit_outlined, size: 19),
                          label: const Text('Edit design'),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
              if (!editable) ...[
                const SizedBox(height: 10),
                Text(
                  'This postcard was made before the design editor — it can '
                  'be shared but not edited.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: context.colors.onSurfaceVariant,
                    fontSize: 11,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
