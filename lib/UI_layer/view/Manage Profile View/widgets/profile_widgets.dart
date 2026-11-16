import 'package:flutter/material.dart';
import '../../../../main.dart';


/// Standard shell for the profile sub-screens: a constrained column with a
/// simple back header (optional trailing action) sitting above scrollable
/// [child] content. Colours come from the active theme so every screen tracks
/// light / dark automatically.
class ProfilePage extends StatelessWidget {
  const ProfilePage({
    super.key,
    required this.title,
    required this.child,
    this.trailing,
    this.onBack,
    this.canPop = true,
  });

  final String title;
  final Widget child;
  final Widget? trailing;
  final VoidCallback? onBack;

  /// Set false while a destructive action is running to lock the back button.
  final bool canPop;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 430),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.md,
                    AppSpacing.md,
                    AppSpacing.lg,
                    0,
                  ),
                  child: Row(
                    children: [
                      if (canPop)
                        AppBackButton(onTap: onBack)
                      else
                        const SizedBox(width: AppSpacing.sm),
                      const SizedBox(width: AppSpacing.xxs),
                      Expanded(
                        child: Text(
                          title,
                          style: context.text.titleLarge,
                        ),
                      ),
                      ?trailing,
                    ],
                  ),
                ),
                AppSpacing.gapSm,
                Expanded(child: child),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Rounded surface card used for every grouped section on the profile screens.
class ProfileCard extends StatelessWidget {
  const ProfileCard({
    super.key,
    required this.child,
    this.padding = AppSpacing.card,
    this.clip = false,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;

  /// Clip children to the rounded corners (needed when the card holds its own
  /// tappable rows or a gradient header).
  final bool clip;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: padding,
      clipBehavior: clip ? Clip.antiAlias : Clip.none,
      decoration: BoxDecoration(
        color: context.colors.surfaceContainerHigh,
        borderRadius: AppRadius.brLg,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: context.isDark ? 0.32 : 0.06),
            blurRadius: 12,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: child,
    );
  }
}

enum ProfileBannerKind { success, error }

/// Inline success / error banner shown inside a profile card.
class ProfileBanner extends StatelessWidget {
  const ProfileBanner({
    super.key,
    required this.message,
    required this.kind,
    this.onDismiss,
  });

  const ProfileBanner.success(String message, {Key? key, VoidCallback? onDismiss})
      : this(
          key: key,
          message: message,
          kind: ProfileBannerKind.success,
          onDismiss: onDismiss,
        );

  const ProfileBanner.error(String message, {Key? key, VoidCallback? onDismiss})
      : this(
          key: key,
          message: message,
          kind: ProfileBannerKind.error,
          onDismiss: onDismiss,
        );

  final String message;
  final ProfileBannerKind kind;
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    final isSuccess = kind == ProfileBannerKind.success;
    final background = isSuccess
        ? context.appColors.successSurface
        : context.colors.errorContainer;
    final foreground = isSuccess
        ? context.appColors.success
        : context.colors.onErrorContainer;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: 14,
      ),
      decoration: BoxDecoration(
        color: background,
        borderRadius: AppRadius.brMd,
        border: Border.all(color: foreground.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            isSuccess
                ? Icons.check_circle_outline
                : Icons.error_outline_rounded,
            color: foreground,
            size: 20,
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              message,
              style: context.text.bodyMedium?.copyWith(
                color: foreground,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (onDismiss != null) ...[
            const SizedBox(width: AppSpacing.sm),
            InkWell(
              onTap: onDismiss,
              child: Icon(Icons.close_rounded, color: foreground, size: 18),
            ),
          ],
        ],
      ),
    );
  }
}

/// Gradient circular avatar with a network image and an initials fallback.
class ProfileAvatar extends StatelessWidget {
  const ProfileAvatar({
    super.key,
    required this.fullName,
    this.avatarUrl,
    this.size = 80,
    this.showBorder = false,
    this.overlay,
    this.badge,
  });

  final String fullName;
  final String? avatarUrl;
  final double size;
  final bool showBorder;

  /// Painted on top of the avatar (e.g. a loading spinner).
  final Widget? overlay;

  /// Small widget pinned to the bottom-right (e.g. an edit pencil).
  final Widget? badge;

  static String initialsOf(String name) {
    final words =
        name.trim().split(' ').where((w) => w.isNotEmpty).toList();
    if (words.isEmpty) return 'U';
    if (words.length >= 2) {
      return '${words[0][0]}${words[1][0]}'.toUpperCase();
    }
    final word = words[0];
    return (word.length >= 2 ? word.substring(0, 2) : word).toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final gradient = LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: context.appColors.brandGradient,
    );
    final hasAvatar = avatarUrl != null && avatarUrl!.isNotEmpty;

    final initials = DecoratedBox(
      decoration: BoxDecoration(gradient: gradient),
      child: Center(
        child: Text(
          initialsOf(fullName),
          style: context.text.headlineSmall?.copyWith(
            color: Colors.white,
            fontSize: size * 0.35,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );

    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              gradient: gradient,
              shape: BoxShape.circle,
              border: showBorder
                  ? Border.all(
                      color: context.colors.surface.withValues(alpha: 0.85),
                      width: 3,
                    )
                  : null,
              boxShadow: [
                BoxShadow(
                  color: context.colors.primary.withValues(alpha: 0.30),
                  blurRadius: 24,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: ClipOval(
              child: hasAvatar
                  ? Image.network(
                      avatarUrl!,
                      width: size,
                      height: size,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => initials,
                    )
                  : initials,
            ),
          ),
          if (overlay != null)
            Positioned.fill(
              child: ClipOval(child: overlay!),
            ),
          if (badge != null) Positioned(right: 0, bottom: 0, child: badge!),
        ],
      ),
    );
  }
}

enum ProfileTileTone { normal, primary, danger }

/// A single tappable row inside a [ProfileCard] menu group.
class ProfileMenuTile extends StatelessWidget {
  const ProfileMenuTile({
    super.key,
    required this.emoji,
    required this.title,
    required this.onTap,
    this.tone = ProfileTileTone.normal,
    this.showDivider = false,
  });

  final String emoji;
  final String title;
  final VoidCallback onTap;
  final ProfileTileTone tone;
  final bool showDivider;

  @override
  Widget build(BuildContext context) {
    final (titleColor, iconBackground) = switch (tone) {
      ProfileTileTone.normal => (
          context.colors.onSurface,
          context.colors.surfaceContainerHighest,
        ),
      ProfileTileTone.primary => (
          context.colors.primary,
          context.colors.primaryContainer,
        ),
      ProfileTileTone.danger => (
          context.colors.error,
          context.colors.errorContainer,
        ),
    };

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.lg,
            vertical: AppSpacing.lg,
          ),
          decoration: BoxDecoration(
            border: showDivider
                ? Border(
                    bottom: BorderSide(color: context.colors.outlineVariant),
                  )
                : null,
          ),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: iconBackground,
                  borderRadius: AppRadius.brSm,
                ),
                child: Text(emoji, style: const TextStyle(fontSize: 20)),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  title,
                  style: context.text.bodyLarge?.copyWith(
                    color: titleColor,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Icon(
                Icons.chevron_right_rounded,
                color: context.colors.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Small pill used to tag a game's status in the history list.
class ProfileStatusBadge extends StatelessWidget {
  const ProfileStatusBadge({
    super.key,
    required this.text,
    required this.background,
    required this.foreground,
  });

  final String text;
  final Color background;
  final Color foreground;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        text,
        style: context.text.labelSmall?.copyWith(
          color: foreground,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
