import 'package:flutter/material.dart';
import '../../../../main.dart';


/// Shared shell for every auth screen: the branded hero gradient, the logo +
/// title, and a single surface card that holds the form.
class AuthScaffold extends StatelessWidget {
  const AuthScaffold({
    super.key,
    required this.title,
    required this.child,
    this.subtitle,
    this.onBack,
    this.showHeader = true,
    this.centerContent = true,
    this.contentPadding,
    this.cardPadding,
  });

  final String title;
  final String? subtitle;
  final Widget child;
  final VoidCallback? onBack;
  final bool showHeader;

  /// Keep the existing vertically-centered auth layout by default.
  /// Screens such as OTP can opt into a top-aligned layout.
  final bool centerContent;

  /// Optional per-screen spacing so Login/Register keep their existing layout.
  final EdgeInsetsGeometry? contentPadding;
  final EdgeInsetsGeometry? cardPadding;

  @override
  Widget build(BuildContext context) {
    final appColors = context.appColors;

    return Scaffold(
      body: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: appColors.heroGradient,
          ),
        ),
        child: SafeArea(
          child: Align(
            alignment: centerContent
                ? Alignment.center
                : Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: SingleChildScrollView(
                padding: contentPadding ??
                    const EdgeInsets.fromLTRB(
                      AppSpacing.xl,
                      AppSpacing.xxl,
                      AppSpacing.xl,
                      AppSpacing.xxl,
                    ),
                child: Column(
                  children: [
                    if (onBack != null)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: AppBackButton(
                          onTap: onBack,
                          color: appColors.onHero,
                        ),
                      ),
                    if (showHeader) ...[
                      Container(
                        width: 72,
                        height: 72,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: appColors.brandGradient,
                          ),
                          borderRadius: AppRadius.brLg,
                          boxShadow: [
                            BoxShadow(
                              color: context.colors.primary.withValues(alpha: 0.4),
                              blurRadius: 24,
                              offset: const Offset(0, 8),
                            ),
                          ],
                        ),
                        child: const Text('🗺️', style: TextStyle(fontSize: 34)),
                      ),
                      AppSpacing.gapLg,
                      Text(
                        title,
                        textAlign: TextAlign.center,
                        style: context.text.headlineMedium?.copyWith(
                          color: appColors.onHero,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      if (subtitle != null) ...[
                        AppSpacing.gapXs,
                        Text(
                          subtitle!,
                          textAlign: TextAlign.center,
                          style: context.text.bodyMedium?.copyWith(
                            color: appColors.heroMuted,
                          ),
                        ),
                      ],
                      AppSpacing.gapXxl,
                    ] else
                      AppSpacing.gapLg,
                    Container(
                      width: double.infinity,
                      padding: cardPadding ??
                          const EdgeInsets.all(AppSpacing.xl),
                      decoration: BoxDecoration(
                        color: context.colors.surface,
                        borderRadius: AppRadius.brXl,
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(
                              alpha: context.isDark ? 0.35 : 0.12,
                            ),
                            blurRadius: 40,
                            offset: const Offset(0, 16),
                          ),
                        ],
                      ),
                      child: child,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
