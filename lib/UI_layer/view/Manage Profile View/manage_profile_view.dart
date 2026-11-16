import 'package:flutter/material.dart';

import '../../../main.dart';
import '../../viewmodel/Manage Profile ViewModel/profile_viewmodel.dart';
import 'edit_profile_view.dart';
import 'game_history_view.dart';
import 'view_profile_view.dart';
import 'delete_account_view.dart';
import 'widgets/profile_widgets.dart';

class ManageProfileView extends StatefulWidget {
  final ManageProfileViewModel viewModel;
  final String? successMessage;

  const ManageProfileView({
    super.key,
    required this.viewModel,
    this.successMessage,
  });

  @override
  State<ManageProfileView> createState() => _ManageProfileViewState();
}

class _ManageProfileViewState extends State<ManageProfileView> {
  String? _successMessage;

  @override
  void initState() {
    super.initState();

    _successMessage = widget.successMessage;

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await widget.viewModel.loadProfile();

      // Warm the statistics so View Profile shows real numbers immediately.
      widget.viewModel.loadProfileStatistics();

      if (mounted) {
        setState(() {});
      }
    });
  }

  // =========================================================
  // BACK TO MAP
  // =========================================================

  void _backToMap() {
    if (Navigator.canPop(context)) {
      Navigator.pop(context);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Map module will be connected later.')),
      );
    }
  }

  // =========================================================
  // LOGOUT
  // =========================================================

  Future<void> _showLogoutDialog() async {
    final confirm = await showDialog<bool>(
      context: context,
      barrierDismissible: true,
      builder: (dialogContext) {
        return Dialog(
          insetPadding: const EdgeInsets.symmetric(horizontal: AppSpacing.xl),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 380),
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.xl),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 54,
                    height: 54,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: dialogContext.colors.errorContainer,
                      borderRadius: AppRadius.brMd,
                    ),
                    child: Icon(
                      Icons.logout_rounded,
                      color: dialogContext.colors.error,
                      size: 28,
                    ),
                  ),
                  AppSpacing.gapMd,
                  Text(
                    'Log out of Mystery Malaysia?',
                    textAlign: TextAlign.center,
                    style: dialogContext.text.titleMedium,
                  ),
                  AppSpacing.gapSm,
                  Text(
                    'Are you sure you want to log out of your account?',
                    textAlign: TextAlign.center,
                    style: dialogContext.text.bodyMedium?.copyWith(
                      color: dialogContext.colors.onSurfaceVariant,
                    ),
                  ),
                  AppSpacing.gapXl,
                  SizedBox(
                    width: double.infinity,
                    height: 50,
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(dialogContext, false),
                      child: const Text('Cancel'),
                    ),
                  ),
                  AppSpacing.gapSm,
                  SizedBox(
                    width: double.infinity,
                    height: 50,
                    child: FilledButton(
                      onPressed: () => Navigator.pop(dialogContext, true),
                      style: FilledButton.styleFrom(
                        backgroundColor: dialogContext.colors.error,
                        foregroundColor: dialogContext.colors.onError,
                      ),
                      child: const Text('Log Out'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );

    if (confirm != true) return;

    final success = await widget.viewModel.logout();

    if (!mounted) return;

    if (success) {
      Navigator.pushNamedAndRemoveUntil(context, '/login', (route) => false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = widget.viewModel.user;

    if (widget.viewModel.isLoading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    if (user == null) {
      return const Scaffold(
        body: Center(child: Text('Unable to load profile.')),
      );
    }

    return Scaffold(
      body: SafeArea(
        top: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 430),
            child: Column(
              children: [
                // =============================================
                // HERO HEADER
                // =============================================
                Container(
                  width: double.infinity,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: context.appColors.heroGradient,
                    ),
                  ),
                  child: SafeArea(
                    bottom: false,
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
                              IconButton(
                                onPressed: _backToMap,
                                icon: Icon(
                                  Icons.arrow_back_ios_new_rounded,
                                  color: context.appColors.onHero,
                                  size: 20,
                                ),
                              ),
                              const SizedBox(width: AppSpacing.xxs),
                              Text(
                                'Profile',
                                style: context.text.titleLarge?.copyWith(
                                  color: context.appColors.onHero,
                                ),
                              ),
                            ],
                          ),
                        ),
                        AppSpacing.gapSm,
                        ProfileAvatar(
                          fullName: user.fullName,
                          avatarUrl: user.avatarUrl,
                          showBorder: true,
                        ),
                        AppSpacing.gapMd,
                        Text(
                          user.fullName,
                          style: context.text.titleLarge?.copyWith(
                            color: context.appColors.onHero,
                          ),
                        ),
                        AppSpacing.gapXs,
                        Text(
                          user.email,
                          style: context.text.bodyMedium?.copyWith(
                            color: context.appColors.heroMuted,
                          ),
                        ),
                        AppSpacing.gapXxl,
                      ],
                    ),
                  ),
                ),

                // =============================================
                // BODY
                // =============================================
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(AppSpacing.lg),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (_successMessage != null) ...[
                          ProfileBanner.success(
                            _successMessage!,
                            onDismiss: () =>
                                setState(() => _successMessage = null),
                          ),
                          AppSpacing.gapLg,
                        ],

                        ProfileCard(
                          padding: EdgeInsets.zero,
                          clip: true,
                          child: Column(
                            children: [
                              ProfileMenuTile(
                                emoji: '👤',
                                title: 'View Profile',
                                showDivider: true,
                                onTap: () => Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => ViewProfileView(
                                      viewModel: widget.viewModel,
                                    ),
                                  ),
                                ),
                              ),
                              ProfileMenuTile(
                                emoji: '✏️',
                                title: 'Edit Profile',
                                showDivider: true,
                                onTap: () async {
                                  await Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                      builder: (_) => EditProfileView(
                                        viewModel: widget.viewModel,
                                      ),
                                    ),
                                  );

                                  if (!mounted) return;
                                  await widget.viewModel.loadProfile();
                                  if (!mounted) return;
                                  setState(() {});
                                },
                              ),
                              ProfileMenuTile(
                                emoji: '📋',
                                title: 'Game & Place History',
                                showDivider: true,
                                onTap: () => Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => GameHistoryView(
                                      viewModel: widget.viewModel,
                                    ),
                                  ),
                                ),
                              ),
                              ProfileMenuTile(
                                emoji: '🎨',
                                title: 'Appearance',
                                onTap: () => showAppearanceSheet(context),
                              ),
                            ],
                          ),
                        ),

                        AppSpacing.gapLg,

                        ProfileCard(
                          padding: EdgeInsets.zero,
                          clip: true,
                          child: ProfileMenuTile(
                            emoji: '🗺️',
                            title: 'Back to Map',
                            tone: ProfileTileTone.primary,
                            onTap: _backToMap,
                          ),
                        ),

                        AppSpacing.gapXl,

                        Padding(
                          padding: const EdgeInsets.only(left: AppSpacing.xs),
                          child: Text(
                            'ACCOUNT ACTIONS',
                            style: context.text.labelSmall?.copyWith(
                              color: context.colors.onSurfaceVariant,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.8,
                            ),
                          ),
                        ),

                        AppSpacing.gapSm,

                        ProfileCard(
                          padding: EdgeInsets.zero,
                          clip: true,
                          child: Column(
                            children: [
                              ProfileMenuTile(
                                emoji: '↪️',
                                title: 'Log Out',
                                tone: ProfileTileTone.danger,
                                showDivider: true,
                                onTap: _showLogoutDialog,
                              ),
                              ProfileMenuTile(
                                emoji: '🗑️',
                                title: 'Delete Account',
                                tone: ProfileTileTone.danger,
                                onTap: () => Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => DeleteAccountView(
                                      viewModel: widget.viewModel,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),

                        AppSpacing.gapLg,
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
