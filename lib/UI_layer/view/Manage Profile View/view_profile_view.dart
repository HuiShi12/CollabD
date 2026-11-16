import 'package:flutter/material.dart';

import '../../../main.dart';
import '../../viewmodel/Manage Profile ViewModel/profile_viewmodel.dart';
import 'widgets/profile_widgets.dart';

class ViewProfileView extends StatefulWidget {
  final ManageProfileViewModel viewModel;

  const ViewProfileView({
    super.key,
    required this.viewModel,
  });

  @override
  State<ViewProfileView> createState() => _ViewProfileViewState();
}

class _ViewProfileViewState extends State<ViewProfileView> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.viewModel.loadProfileStatistics();
    });
  }

  String _formatDateOfBirth(DateTime? date) {
    if (date == null) {
      return 'Not set';
    }

    final day = date.day.toString().padLeft(2, '0');
    final month = date.month.toString().padLeft(2, '0');
    final year = date.year.toString();

    return '$day/$month/$year';
  }

  String _statValue(String value) {
    return widget.viewModel.isProfileStatisticsLoading ? 'Loading…' : value;
  }

  @override
  Widget build(BuildContext context) {
    return ProfilePage(
      title: 'View Profile',
      child: ListenableBuilder(
        listenable: widget.viewModel,
        builder: (context, _) {
          final user = widget.viewModel.user;
          if (user == null) {
            return const Center(child: Text('Profile not found.'));
          }

          return SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg,
              AppSpacing.sm,
              AppSpacing.lg,
              AppSpacing.xxl,
            ),
            child: Column(
              children: [
                ProfileAvatar(
                  fullName: user.fullName,
                  avatarUrl: user.avatarUrl,
                  size: 96,
                ),
                AppSpacing.gapMd,
                Text(
                  user.fullName,
                  textAlign: TextAlign.center,
                  style: context.text.titleLarge,
                ),
                AppSpacing.gapXl,
                ProfileCard(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.lg,
                  ),
                  child: Column(
                    children: [
                      _profileRow(
                        context,
                        label: 'Full Name',
                        value: user.fullName,
                      ),
                      const Divider(),
                      _profileRow(
                        context,
                        label: 'Email',
                        value: user.email,
                      ),
                      const Divider(),
                      _profileRow(
                        context,
                        label: 'Date of Birth',
                        value: _formatDateOfBirth(user.dateOfBirth),
                      ),
                      const Divider(),
                      _profileRow(
                        context,
                        label: 'Member Since',
                        value: _statValue(widget.viewModel.memberSince),
                      ),
                      const Divider(),
                      _profileRow(
                        context,
                        label: 'Games Played',
                        value: _statValue('${widget.viewModel.gamesPlayed}'),
                      ),
                      const Divider(),
                      _profileRow(
                        context,
                        label: 'Rewards Earned',
                        value:
                            _statValue('${widget.viewModel.rewardsEarned}'),
                      ),
                    ],
                  ),
                ),
                if (widget.viewModel.profileStatisticsErrorMessage != null) ...[
                  AppSpacing.gapMd,
                  Text(
                    widget.viewModel.profileStatisticsErrorMessage!,
                    style: context.text.bodySmall?.copyWith(
                      color: context.colors.error,
                    ),
                  ),
                ],
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _profileRow(
    BuildContext context, {
    required String label,
    required String value,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: Row(
        children: [
          Expanded(
            flex: 4,
            child: Text(
              label,
              style: context.text.bodyMedium?.copyWith(
                color: context.colors.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.lg),
          Expanded(
            flex: 6,
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: context.text.bodyMedium?.copyWith(
                color: context.colors.onSurface,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
