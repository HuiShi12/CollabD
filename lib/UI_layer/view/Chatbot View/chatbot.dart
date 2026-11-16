import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:collab_d/UI_layer/viewmodel/Chatbot ViewModel/chatbot_viewmodel.dart';
import 'package:collab_d/Data_layer/repository/Chat Repository/message.dart';
import '../../../main.dart';


class ChatbotView extends StatefulWidget {
  const ChatbotView({super.key});

  @override
  State<ChatbotView> createState() => _ChatbotViewState();
}

class _ChatbotViewState extends State<ChatbotView> {
  final TextEditingController _controller = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  final List<String> _suggestedQuestions = [
    'What food should I try here?',
    'What attractions are nearby?',
    'Tell me about the culture here.',
    'How can I get around here?',
  ];

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _sendMessage(String text) {
    if (text.trim().isEmpty) return;
    final viewModel = context.read<ChatbotViewModel>();
    viewModel.sendMessage(text);
    _controller.clear();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('AI Assistant'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(40),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.lg,
              vertical: AppSpacing.sm,
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.md,
                    vertical: AppSpacing.xs,
                  ),
                  decoration: BoxDecoration(
                    color: context.colors.surfaceContainerHighest,
                    borderRadius: AppRadius.brLg,
                    border: Border.all(color: context.colors.outlineVariant),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.location_on,
                        size: 16,
                        color: context.appColors.success,
                      ),
                      const SizedBox(width: AppSpacing.xs),
                      Consumer<ChatbotViewModel>(
                        builder: (context, viewModel, child) {
                          return Text(
                            viewModel.isLocationReady
                                ? 'Current Area: ${viewModel.currentArea}'
                                : 'Detecting location…',
                            style: context.text.labelMedium?.copyWith(
                              color: context.colors.onSurfaceVariant,
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      body: Column(
        children: [
          // ---------- Scrollable list (header + messages) ----------
          Expanded(
            child: Consumer<ChatbotViewModel>(
              builder: (context, viewModel, child) {
                if (viewModel.messages.isNotEmpty) {
                  _scrollToBottom();
                }

                return ListView.builder(
                  controller: _scrollController,
                  padding: const EdgeInsets.all(AppSpacing.lg),
                  itemCount: viewModel.messages.length + 1,
                  itemBuilder: (context, index) {
                    if (index == 0) {
                      return _buildHeader(viewModel);
                    }
                    final message = viewModel.messages[index - 1];
                    return _buildMessageBubble(message);
                  },
                );
              },
            ),
          ),

          // ---------- Loading indicator ----------
          Consumer<ChatbotViewModel>(
            builder: (context, viewModel, child) {
              if (!viewModel.isLoading) return const SizedBox.shrink();
              return Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.lg,
                  vertical: AppSpacing.sm,
                ),
                alignment: Alignment.centerLeft,
                child: Row(
                  children: [
                    const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Text(
                      'AI is thinking…',
                      style: context.text.labelMedium?.copyWith(
                        color: context.colors.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              );
            },
          ),

          // ---------- Input bar ----------
          _buildInputBar(),
        ],
      ),
    );
  }

  // ---------- Header: suggested questions + greeting ----------
  Widget _buildHeader(ChatbotViewModel viewModel) {
    final areaName =
        viewModel.isLocationReady ? viewModel.currentArea : 'this area';

    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'SUGGESTED QUESTIONS',
            style: context.text.labelMedium?.copyWith(
              color: context.colors.onSurfaceVariant,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.5,
            ),
          ),
          AppSpacing.gapSm,
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: _suggestedQuestions.map((question) {
              final displayText = question.replaceAll('here', areaName);
              return ActionChip(
                label: Text(displayText),
                onPressed: () => _sendMessage(question),
              );
            }).toList(),
          ),
          AppSpacing.gapLg,
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.lg,
              vertical: AppSpacing.md,
            ),
            decoration: BoxDecoration(
              color: context.colors.surfaceContainerHigh,
              borderRadius: AppRadius.brMd,
              border: Border.all(color: context.colors.outlineVariant),
            ),
            child: Text(
              viewModel.isLocationReady
                  ? "Hi! I'm your Mystery Malaysia AI Assistant. I'm here to "
                        'help you explore $areaName. Ask me about local food, '
                        'attractions, culture, transport, or anything about '
                        'this area!'
                  : "Hi! I'm your Mystery Malaysia AI Assistant. Detecting "
                        'your location…',
              style: context.text.bodyMedium?.copyWith(
                height: 1.5,
                color: context.colors.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ---------- Input bar ----------
  Widget _buildInputBar() {
    return Consumer<ChatbotViewModel>(
      builder: (context, viewModel, child) {
        return Container(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.sm,
          ),
          decoration: BoxDecoration(
            color: context.colors.surface,
            border: Border(
              top: BorderSide(color: context.colors.outlineVariant),
            ),
          ),
          child: SafeArea(
            top: false,
            child: Row(
              children: [
                Expanded(
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
                    decoration: BoxDecoration(
                      color: context.colors.surfaceContainerHighest,
                      borderRadius: AppRadius.brXl,
                      border: Border.all(color: context.colors.outlineVariant),
                    ),
                    child: TextField(
                      controller: _controller,
                      style: context.text.bodyLarge,
                      decoration: InputDecoration(
                        hintText:
                            'Ask about ${viewModel.isLocationReady ? viewModel.currentArea : 'your area'}…',
                        hintStyle: context.text.bodyMedium?.copyWith(
                          color: context.colors.onSurfaceVariant,
                        ),
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        filled: false,
                        contentPadding:
                            const EdgeInsets.symmetric(vertical: 12),
                      ),
                      onSubmitted: (_) => _sendMessage(_controller.text),
                      maxLength: 500,
                      buildCounter: (
                        context, {
                        required currentLength,
                        required isFocused,
                        maxLength,
                      }) =>
                          null,
                    ),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                CircleAvatar(
                  backgroundColor: viewModel.isLoading
                      ? context.colors.surfaceContainerHighest
                      : context.appColors.success,
                  radius: 22,
                  child: IconButton(
                    icon: Icon(
                      Icons.arrow_forward,
                      color: viewModel.isLoading
                          ? context.colors.onSurfaceVariant
                          : context.appColors.onSuccess,
                      size: 20,
                    ),
                    onPressed: viewModel.isLoading
                        ? null
                        : () => _sendMessage(_controller.text),
                    tooltip: 'Send',
                    padding: EdgeInsets.zero,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  // ---------- Message bubble ----------
  Widget _buildMessageBubble(Message message) {
    final isUser = message.isUser;
    final isError = message.messageType == 'error';
    final isSystem = message.messageType == 'system' ||
        message.messageType == 'area_change' ||
        isError;

    if (isSystem) {
      final background = isError
          ? context.colors.errorContainer
          : context.colors.surfaceContainerHigh;
      final foreground = isError
          ? context.colors.onErrorContainer
          : context.colors.onSurfaceVariant;

      return Container(
        margin: const EdgeInsets.symmetric(vertical: 6),
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.sm,
        ),
        decoration: BoxDecoration(
          color: background,
          borderRadius: AppRadius.brSm,
          border: Border.all(color: foreground.withValues(alpha: 0.25)),
        ),
        child: Row(
          children: [
            Icon(
              isError ? Icons.error_outline : Icons.info_outline,
              size: 16,
              color: foreground,
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text(
                message.text,
                style: context.text.labelLarge?.copyWith(
                  color: foreground,
                  fontWeight:
                      isError ? FontWeight.w500 : FontWeight.normal,
                ),
              ),
            ),
          ],
        ),
      );
    }

    final bubbleColor = isUser
        ? context.appColors.success
        : context.colors.surfaceContainerHigh;
    final textColor = isUser
        ? context.appColors.onSuccess
        : context.colors.onSurface;

    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: AppSpacing.sm + 2,
        ),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.75,
        ),
        decoration: BoxDecoration(
          color: bubbleColor,
          borderRadius: BorderRadius.circular(16).copyWith(
            bottomRight: isUser ? const Radius.circular(4) : null,
            bottomLeft: isUser ? null : const Radius.circular(4),
          ),
          border: isUser
              ? null
              : Border.all(
                  color: context.colors.outlineVariant.withValues(alpha: 0.6),
                  width: 1,
                ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildFormattedMessage(
              message.text,
              context.text.bodyLarge?.copyWith(
                    color: textColor,
                    height: 1.4,
                  ) ??
                  TextStyle(color: textColor, height: 1.4),
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              _formatTime(message.timestamp),
              style: context.text.labelSmall?.copyWith(
                color: textColor.withValues(alpha: 0.7),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---------- Lightweight markdown for AI replies ----------
  //
  // Gemini's answers use plain-text markdown (**bold**, "* " / "- " bullet
  // lines) expecting to be rendered, not read as literal asterisks. A full
  // markdown package is overkill for the two things it actually uses, so
  // this renders just those directly instead of adding a new dependency.

  Widget _buildFormattedMessage(String text, TextStyle baseStyle) {
    final lines = text.split('\n');
    final children = <Widget>[];

    for (final line in lines) {
      if (line.trim().isEmpty) {
        children.add(const SizedBox(height: 6));
        continue;
      }

      final trimmed = line.trimLeft();
      final isBullet = trimmed.startsWith('* ') || trimmed.startsWith('- ');
      final numberedMatch = _numberedListPattern.firstMatch(trimmed);

      if (numberedMatch != null) {
        final number = numberedMatch.group(1)!;
        final rest = numberedMatch.group(2)!;
        children.add(
          Padding(
            padding: const EdgeInsets.only(top: 4, bottom: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 20,
                  height: 20,
                  margin: const EdgeInsets.only(right: 8, top: 1),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: baseStyle.color?.withValues(alpha: 0.14),
                    shape: BoxShape.circle,
                  ),
                  child: Text(
                    number,
                    style: baseStyle.copyWith(
                      fontSize: (baseStyle.fontSize ?? 14) - 2,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                Expanded(
                  child: Text.rich(
                    TextSpan(children: _parseInlineBold(rest, baseStyle)),
                  ),
                ),
              ],
            ),
          ),
        );
      } else if (isBullet) {
        children.add(
          Padding(
            padding: const EdgeInsets.only(top: 2, bottom: 2),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('•  ', style: baseStyle),
                Expanded(
                  child: Text.rich(
                    TextSpan(
                      children: _parseInlineBold(
                        trimmed.substring(2),
                        baseStyle,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      } else {
        children.add(
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 1),
            child: Text.rich(
              TextSpan(children: _parseInlineBold(line, baseStyle)),
            ),
          ),
        );
      }
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: children);
  }

  final _boldPattern = RegExp(r'\*\*(.+?)\*\*');
  final _numberedListPattern = RegExp(r'^(\d{1,2})\.\s+(.*)$');

  List<InlineSpan> _parseInlineBold(String text, TextStyle baseStyle) {
    final spans = <InlineSpan>[];
    var cursor = 0;

    for (final match in _boldPattern.allMatches(text)) {
      if (match.start > cursor) {
        spans.add(
          TextSpan(text: text.substring(cursor, match.start), style: baseStyle),
        );
      }
      spans.add(
        TextSpan(
          text: match.group(1),
          style: baseStyle.copyWith(fontWeight: FontWeight.w800),
        ),
      );
      cursor = match.end;
    }

    if (cursor < text.length) {
      spans.add(TextSpan(text: text.substring(cursor), style: baseStyle));
    }

    return spans;
  }

  String _formatTime(DateTime time) {
    final now = DateTime.now();
    final diff = now.difference(time);

    if (diff.inSeconds < 60) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${time.day}/${time.month}/${time.year} '
        '${time.hour.toString().padLeft(2, '0')}:'
        '${time.minute.toString().padLeft(2, '0')}';
  }
}
