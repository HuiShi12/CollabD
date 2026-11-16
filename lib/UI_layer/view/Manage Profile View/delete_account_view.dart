import 'package:flutter/material.dart';

import '../../../main.dart';
import '../../viewmodel/Manage Profile ViewModel/profile_viewmodel.dart';
import 'widgets/profile_widgets.dart';

class DeleteAccountView extends StatefulWidget {
  final ManageProfileViewModel viewModel;

  const DeleteAccountView({
    super.key,
    required this.viewModel,
  });

  @override
  State<DeleteAccountView> createState() =>
      _DeleteAccountViewState();
}

class _DeleteAccountViewState extends State<DeleteAccountView> {
  bool _deleting = false;
  bool _showError = false;

  Future<void> _deleteAccount() async {
    setState(() {
      _deleting = true;
      _showError = false;
    });

    final success = await widget.viewModel.deleteAccount();

    if (!mounted) return;

    if (success) {
      Navigator.pushNamedAndRemoveUntil(
        context,
        '/login',
        (route) => false,
      );
    } else {
      setState(() {
        _deleting = false;
        _showError = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return ProfilePage(
      title: 'Delete Account',
      canPop: !_deleting,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg,
          AppSpacing.sm,
          AppSpacing.lg,
          AppSpacing.xxl,
        ),
        child: ProfileCard(
          padding: const EdgeInsets.all(AppSpacing.xl),
          child: Column(
            children: [
              const Text('⚠️', style: TextStyle(fontSize: 56)),
              AppSpacing.gapMd,
              Text(
                'Delete Account',
                style: context.text.titleLarge?.copyWith(
                  color: context.colors.error,
                ),
              ),
              AppSpacing.gapSm,
              Text.rich(
                TextSpan(
                  children: [
                    const TextSpan(
                      text:
                          'Are you sure you want to delete your account?\n',
                    ),
                    TextSpan(
                      text: 'This action cannot be undone.\n',
                      style: context.text.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const TextSpan(
                      text:
                          'All your game history, rewards, and data will be permanently lost.',
                    ),
                  ],
                ),
                textAlign: TextAlign.center,
                style: context.text.bodyMedium?.copyWith(
                  color: context.colors.onSurfaceVariant,
                  height: 1.6,
                ),
              ),
              AppSpacing.gapXl,
              if (_showError) ...[
                const ProfileBanner.error(
                  'Account deletion failed. Please try again.',
                ),
                AppSpacing.gapLg,
              ],
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.lg,
                  vertical: 14,
                ),
                decoration: BoxDecoration(
                  color: context.colors.errorContainer,
                  borderRadius: AppRadius.brMd,
                  border: Border.all(
                    color: context.colors.onErrorContainer
                        .withValues(alpha: 0.35),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _warningItem('All game progress will be lost'),
                    _warningItem('All earned rewards will be deleted'),
                    _warningItem('Your profile data will be removed'),
                  ],
                ),
              ),
              AppSpacing.gapXl,
              SizedBox(
                width: double.infinity,
                height: 52,
                child: FilledButton(
                  onPressed: _deleting ? null : _deleteAccount,
                  style: FilledButton.styleFrom(
                    backgroundColor: context.colors.error,
                    foregroundColor: context.colors.onError,
                  ),
                  child: Text(
                    _deleting
                        ? 'Deleting Account...'
                        : 'Delete Account',
                  ),
                ),
              ),
              AppSpacing.gapMd,
              SizedBox(
                width: double.infinity,
                height: 52,
                child: OutlinedButton(
                  onPressed: _deleting
                      ? null
                      : () => Navigator.pop(context),
                  child: const Text('Cancel — Keep My Account'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _warningItem(String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '✕',
            style: context.text.labelMedium?.copyWith(
              color: context.colors.onErrorContainer,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(width: 7),
          Expanded(
            child: Text(
              text,
              style: context.text.bodySmall?.copyWith(
                color: context.colors.onErrorContainer,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
