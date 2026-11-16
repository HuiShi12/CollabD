enum PostcardElementType { text, sticker, reward }

/// Coordinates are relative to the postcard, never device pixels.
class PostcardElement {
  final String id, content;
  final PostcardElementType type;
  final double x, y, width, height, rotation;
  final int color;
  final bool bold;
  const PostcardElement({
    required this.id,
    required this.type,
    required this.content,
    this.x = .5,
    this.y = .5,
    this.width = .35,
    this.height = .3,
    this.rotation = 0,
    this.color = 0xFF173F39,
    this.bold = false,
  });
  PostcardElement copyWith({
    String? id,
    String? content,
    double? x,
    double? y,
    double? width,
    double? height,
    double? rotation,
    int? color,
    bool? bold,
  }) => PostcardElement(
    id: id ?? this.id,
    type: type,
    content: content ?? this.content,
    x: x ?? this.x,
    y: y ?? this.y,
    width: width ?? this.width,
    height: height ?? this.height,
    rotation: rotation ?? this.rotation,
    color: color ?? this.color,
    bold: bold ?? this.bold,
  );
  Map<String, dynamic> toMap() => {
    'id': id,
    'type': type.name,
    'content': content,
    'x': x,
    'y': y,
    'width': width,
    'height': height,
    'rotation': rotation,
    'color': color,
    'bold': bold,
  };
  factory PostcardElement.fromMap(Map<String, dynamic> m) => PostcardElement(
    id: m['id'] as String,
    type: PostcardElementType.values.byName(m['type'] as String),
    content: m['content'] as String,
    x: (m['x'] as num).toDouble(),
    y: (m['y'] as num).toDouble(),
    width: (m['width'] as num).toDouble(),
    height: (m['height'] as num).toDouble(),
    rotation: (m['rotation'] as num).toDouble(),
    color: m['color'] as int,
    bold: m['bold'] as bool? ?? false,
  );
}

/// A full editable composition. Background bytes are encoded in the existing mock DB.
class PostcardDesign {
  final String backgroundType, template;
  final String? backgroundImage, backgroundRewardId;
  final int backgroundColor;
  final List<PostcardElement> elements;
  const PostcardDesign({
    this.backgroundType = 'Template',
    this.template = 'tropical',
    this.backgroundColor = 0xFF153F3A,
    this.backgroundImage,
    this.backgroundRewardId,
    this.elements = const [],
  });
  List<String> get rewardIds => {
    ?backgroundRewardId,
    ...elements
        .where((e) => e.type == PostcardElementType.reward)
        .map((e) => e.content),
  }.toList();
  PostcardDesign copyWith({
    String? backgroundType,
    String? template,
    int? backgroundColor,
    String? backgroundImage,
    String? backgroundRewardId,
    bool clearImage = false,
    List<PostcardElement>? elements,
  }) => PostcardDesign(
    backgroundType: backgroundType ?? this.backgroundType,
    template: template ?? this.template,
    backgroundColor: backgroundColor ?? this.backgroundColor,
    backgroundImage: clearImage
        ? null
        : backgroundImage ?? this.backgroundImage,
    backgroundRewardId: clearImage
        ? null
        : backgroundRewardId ?? this.backgroundRewardId,
    elements: List.unmodifiable(elements ?? this.elements),
  );
  Map<String, dynamic> toMap() => {
    'background_type': backgroundType,
    'template': template,
    'background_color': backgroundColor,
    'background_image': backgroundImage,
    'background_reward_id': backgroundRewardId,
    'elements': elements.map((e) => e.toMap()).toList(),
  };
  factory PostcardDesign.fromMap(Map<String, dynamic> m) => PostcardDesign(
    backgroundType: m['background_type'] as String,
    template: m['template'] as String,
    backgroundColor: m['background_color'] as int,
    backgroundImage: m['background_image'] as String?,
    backgroundRewardId: m['background_reward_id'] as String?,
    elements: List.unmodifiable(
      (m['elements'] as List).map(
        (e) => PostcardElement.fromMap(Map<String, dynamic>.from(e as Map)),
      ),
    ),
  );
}
