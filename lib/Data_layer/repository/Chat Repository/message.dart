// lib/Data_layer/models/chat/message.dart

class Message {
  // ---------- Fields ----------
  final String text;
  final bool isUser; // true = user sent, false = AI sent
  final DateTime timestamp;
  final String? messageType; // 'user', 'ai', 'system', 'area_change', 'error'

  // ---------- Constructor ----------
  Message({
    required this.text,
    required this.isUser,
    DateTime? timestamp,
    this.messageType,
  }) : timestamp = timestamp ?? DateTime.now();

  // ---------- Factory Constructors ----------

  /// Creates a system message (e.g., area detection, info)
  factory Message.system(String text) {
    return Message(
      text: text,
      isUser: false,
      messageType: 'system',
    );
  }

  /// Creates an area change notification (M7)
  factory Message.areaChange(String newArea) {
    return Message(
      text: 'Your current area has changed to $newArea. '
          'Subsequent answers will use this area.',
      isUser: false,
      messageType: 'area_change',
    );
  }

  /// Creates a welcome message when area is first detected (M1)
  factory Message.areaDetected(String area) {
    return Message(
      text: 'Your current area has been detected as $area.',
      isUser: false,
      messageType: 'system',
    );
  }

  /// Creates an error message (M6, M8, M9, M10)
  factory Message.error(String text) {
    return Message(
      text: text,
      isUser: false,
      messageType: 'error',
    );
  }

  // ---------- Copy With (for immutability) ----------
  Message copyWith({
    String? text,
    bool? isUser,
    DateTime? timestamp,
    String? messageType,
  }) {
    return Message(
      text: text ?? this.text,
      isUser: isUser ?? this.isUser,
      timestamp: timestamp ?? this.timestamp,
      messageType: messageType ?? this.messageType,
    );
  }

  // ---------- Optional: toString for debugging ----------
  @override
  String toString() {
    return 'Message(text: $text, isUser: $isUser, timestamp: $timestamp, type: $messageType)';
  }
}