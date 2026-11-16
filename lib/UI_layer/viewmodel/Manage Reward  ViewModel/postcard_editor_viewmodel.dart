import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import '../../../Data_layer/repository/Reward Repository/reward_repository.dart';

/// Presentation/editing state only. Repository validates eligibility and saves.
class PostcardEditorViewModel extends ChangeNotifier {
  final RewardRepository repository;
  final String touristId;
  final String? postcardId;
  PostcardDesign design;
  PostcardDesign _saved;
  final _undo = <PostcardDesign>[];
  final _redo = <PostcardDesign>[];
  List<TouristReward> rewards = [];
  String? selectedId, errorMessage;
  bool busy = false, _disposed = false;
  PostcardElement? _gestureStart;
  bool _gestureChanged = false;
  int _counter = 0;

  PostcardEditorViewModel({
    required this.repository,
    required this.touristId,
    DigitalPostcard? existing,
  }) : postcardId = existing?.id,
       design = existing?.design ?? templateDesign('tropical'),
       _saved = existing?.design ?? templateDesign('tropical') {
    _saved = design;
  }

  bool get dirty => !identical(design, _saved);
  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;
  PostcardElement? get selected {
    final matches = design.elements.where((e) => e.id == selectedId);
    return matches.isEmpty ? null : matches.first;
  }

  void _emit() {
    if (!_disposed) notifyListeners();
  }

  Future<void> loadResources() async {
    try {
      rewards = await repository.getPostcardEligibleRewards(touristId);
    } catch (e) {
      errorMessage = 'Rewards could not be loaded. $e';
    }
    _emit();
  }

  void _remember() {
    _undo.add(design);
    if (_undo.length > 40) _undo.removeAt(0);
    _redo.clear();
  }

  void change(PostcardDesign next) {
    if (busy) return;
    _remember();
    design = next;
    errorMessage = null;
    _emit();
  }

  void beginControlEdit() {
    if (!busy) _remember();
  }

  void undo() {
    if (!canUndo || busy) return;
    _redo.add(design);
    design = _undo.removeLast();
    selectedId = null;
    _emit();
  }

  void redo() {
    if (!canRedo || busy) return;
    _undo.add(design);
    design = _redo.removeLast();
    selectedId = null;
    _emit();
  }

  void select(String? id) {
    selectedId = id;
    _emit();
  }

  String _id() =>
      'element_${DateTime.now().microsecondsSinceEpoch}_${++_counter}';
  void add(
    PostcardElementType type,
    String content, {
    double x = .5,
    double y = .5,
  }) {
    if (busy) return;
    final element = PostcardElement(
      id: _id(),
      type: type,
      content: content,
      x: x.clamp(.15, .85),
      y: y.clamp(.15, .85),
      width: type == PostcardElementType.text ? .65 : .26,
      height: type == PostcardElementType.text ? .18 : .36,
      color: design.template == 'tropical' ? 0xFFFFF6DD : 0xFF173F39,
      bold: type == PostcardElementType.text,
    );
    selectedId = element.id;
    change(design.copyWith(elements: [...design.elements, element]));
  }

  void updateSelected(PostcardElement next, {bool history = true}) {
    if (busy) return;
    if (history) _remember();
    design = design.copyWith(
      elements: design.elements.map((e) => e.id == next.id ? next : e).toList(),
    );
    _emit();
  }

  void beginGesture(String id) {
    if (busy) return;
    select(id);
    _gestureStart = selected;
    _gestureChanged = false;
  }

  void transformGesture(double dx, double dy, double scale, double rotation) {
    final start = _gestureStart;
    if (start == null || busy) return;
    if (!_gestureChanged) {
      _remember();
      _gestureChanged = true;
    }
    final width = (start.width * scale).clamp(.08, .95);
    final height = (start.height * scale).clamp(.08, .95);
    updateSelected(
      start.copyWith(
        x: (start.x + dx).clamp(width / 2, 1 - width / 2),
        y: (start.y + dy).clamp(height / 2, 1 - height / 2),
        width: width,
        height: height,
        rotation: (start.rotation + rotation).clamp(-math.pi, math.pi),
      ),
      history: false,
    );
  }

  void endGesture() {
    _gestureStart = null;
  }

  void deleteSelected() {
    if (selected == null) return;
    change(
      design.copyWith(
        elements: design.elements.where((e) => e.id != selectedId).toList(),
      ),
    );
    selectedId = null;
    _emit();
  }

  void duplicateSelected() {
    final e = selected;
    if (e == null) return;
    final duplicate = e.copyWith(
      id: _id(),
      x: (e.x + .04).clamp(.1, .9),
      y: (e.y + .04).clamp(.1, .9),
    );
    selectedId = duplicate.id;
    change(design.copyWith(elements: [...design.elements, duplicate]));
  }

  void moveLayer(int direction) {
    final list = design.elements.toList();
    final index = list.indexWhere((e) => e.id == selectedId);
    if (index < 0) return;
    final next = (index + direction).clamp(0, list.length - 1);
    final e = list.removeAt(index);
    list.insert(next, e);
    change(design.copyWith(elements: list));
  }

  void useTemplate(String template) {
    selectedId = null;
    change(templateDesign(template));
  }

  void useColor(int color) => change(
    design.copyWith(
      backgroundType: 'Blank Canvas',
      template: 'plain',
      backgroundColor: color,
      clearImage: true,
    ),
  );
  void useRewardBackground(TouristReward reward) => change(
    design
        .copyWith(
          backgroundType: 'Reward Image',
          template: 'plain',
          clearImage: true,
        )
        .copyWith(backgroundRewardId: reward.id),
  );

  Future<void> pickPhoneBackground() async {
    if (busy) return;
    busy = true;
    errorMessage = null;
    _emit();
    try {
      final data = await repository.pickPostcardBackground();
      if (_disposed) return;
      if (data != null) {
        _remember();
        design = design
            .copyWith(
              backgroundType: 'Phone Image',
              template: 'plain',
              clearImage: true,
            )
            .copyWith(backgroundImage: data);
      }
    } catch (e) {
      errorMessage =
          'Unable to open the photo. Try another image or background. $e';
    } finally {
      busy = false;
      _emit();
    }
  }

  Future<bool> save(Future<Uint8List> Function() render) async {
    if (busy) return false;
    busy = true;
    errorMessage = null;
    _emit();
    try {
      await repository.savePostcardDesign(
        touristId: touristId,
        design: design,
        postcardId: postcardId,
        render: render,
      );
      _saved = design;
      return true;
    } catch (e) {
      errorMessage = 'Postcard was not saved. Your design is still here. $e';
      return false;
    } finally {
      busy = false;
      _emit();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  /// Template placement is presentation state; all elements remain editable.
  static PostcardDesign templateDesign(String name) {
    if (name == 'plain') {
      return const PostcardDesign(
        backgroundType: 'Blank Canvas',
        template: 'plain',
        backgroundColor: 0xFFFFFBEE,
      );
    }
    final dark = name == 'tropical';
    return PostcardDesign(
      template: name,
      backgroundColor: dark
          ? 0xFF173F39
          : name == 'sunset'
          ? 0xFFF3C2A2
          : 0xFFFFF3D5,
      elements: [
        PostcardElement(
          id: 'template_overline',
          type: PostcardElementType.text,
          content: 'A LITTLE PIECE OF',
          x: .5,
          y: .21,
          width: .65,
          height: .06,
          color: dark ? 0xFFE8DFB2 : 0xFF584132,
        ),
        PostcardElement(
          id: 'template_title',
          type: PostcardElementType.text,
          content: 'MALAYSIA',
          x: .5,
          y: .37,
          width: .79,
          height: .22,
          bold: true,
          color: dark ? 0xFFFFF6DD : 0xFF773D36,
        ),
        PostcardElement(
          id: 'template_note',
          type: PostcardElementType.text,
          content: 'Little moments. Lasting memories.',
          x: .5,
          y: .56,
          width: .72,
          height: .08,
          color: dark ? 0xFFF0E4C2 : 0xFF584132,
        ),
        PostcardElement(
          id: 'template_flower',
          type: PostcardElementType.sticker,
          content: 'flower',
          x: .84,
          y: .8,
          width: .15,
          height: .22,
          color: dark ? 0xFFF2BD99 : 0xFFAC5545,
        ),
      ],
    );
  }
}
