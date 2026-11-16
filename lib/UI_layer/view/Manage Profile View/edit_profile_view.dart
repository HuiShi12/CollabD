import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../../main.dart';
import '../../viewmodel/Manage Profile ViewModel/profile_viewmodel.dart';
import 'change_password_view.dart';
import 'widgets/profile_widgets.dart';

class EditProfileView extends StatefulWidget {
  final ManageProfileViewModel viewModel;

  const EditProfileView({
    super.key,
    required this.viewModel,
  });

  @override
  State<EditProfileView> createState() => _EditProfileViewState();
}

class _EditProfileViewState extends State<EditProfileView> {
  late final TextEditingController _nameController;
  late final TextEditingController _emailController;
  late final TextEditingController _dobController;

  final ImagePicker _imagePicker = ImagePicker();

  DateTime? _dateOfBirth;

  String? _successMessage;

  // =========================================================
  // INIT
  // =========================================================

  @override
  void initState() {
    super.initState();

    final user = widget.viewModel.user;

    _nameController = TextEditingController(text: user?.fullName ?? '');
    _emailController = TextEditingController(text: user?.email ?? '');

    _dateOfBirth = user?.dateOfBirth;

    _dobController = TextEditingController(
      text: _formatDateForField(_dateOfBirth),
    );
  }

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _dobController.dispose();
    super.dispose();
  }

  // =========================================================
  // PICK PROFILE IMAGE
  // =========================================================

  Future<void> _pickProfileImage(ImageSource source) async {
    try {
      final XFile? image = await _imagePicker.pickImage(
        source: source,
        imageQuality: 80,
        maxWidth: 1200,
      );

      if (image == null) {
        return;
      }

      final bytes = await image.readAsBytes();

      // Get file extension.
      String extension = 'jpg';

      final fileName = image.name.toLowerCase();

      if (fileName.contains('.')) {
        extension = fileName.split('.').last;
      }

      // Only allow formats supported by your Storage bucket.
      if (!['jpg', 'jpeg', 'png', 'webp'].contains(extension)) {
        if (!mounted) {
          return;
        }

        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Please select a JPG, PNG or WebP image.'),
          ),
        );

        return;
      }

      String? contentType;

      if (extension == 'jpg' || extension == 'jpeg') {
        contentType = 'image/jpeg';
      } else if (extension == 'png') {
        contentType = 'image/png';
      } else if (extension == 'webp') {
        contentType = 'image/webp';
      }

      if (!mounted) {
        return;
      }

      final success = await widget.viewModel.uploadProfileImage(
        bytes: bytes,
        fileExtension: extension,
        contentType: contentType,
      );

      if (!mounted) {
        return;
      }

      if (success) {
        setState(() {
          _successMessage = 'Profile picture updated successfully.';
        });
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              widget.viewModel.errorMessage ??
                  'Unable to update profile picture.',
            ),
          ),
        );
      }
    } catch (error) {
      debugPrint('PICK PROFILE IMAGE ERROR: $error');

      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Unable to select profile picture.'),
        ),
      );
    }
  }

  // =========================================================
  // REMOVE PROFILE IMAGE
  // =========================================================

  Future<void> _removeProfileImage() async {
    final success = await widget.viewModel.removeProfileImage();

    if (!mounted) {
      return;
    }

    if (success) {
      setState(() {
        _successMessage = 'Profile picture removed successfully.';
      });
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            widget.viewModel.errorMessage ??
                'Unable to remove profile picture.',
          ),
        ),
      );
    }
  }

  // =========================================================
  // PROFILE IMAGE OPTIONS
  // =========================================================

  void _showProfileImageOptions() {
    final avatarUrl = widget.viewModel.user?.avatarUrl;
    final hasAvatar = avatarUrl != null && avatarUrl.isNotEmpty;

    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (bottomSheetContext) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg,
              0,
              AppSpacing.lg,
              AppSpacing.lg,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Profile Picture',
                  style: bottomSheetContext.text.titleMedium,
                ),
                AppSpacing.gapMd,
                _profileImageOption(
                  bottomSheetContext,
                  icon: Icons.photo_library_outlined,
                  title: 'Choose from Gallery',
                  onTap: () {
                    Navigator.pop(bottomSheetContext);
                    _pickProfileImage(ImageSource.gallery);
                  },
                ),
                _profileImageOption(
                  bottomSheetContext,
                  icon: Icons.camera_alt_outlined,
                  title: 'Take Photo',
                  onTap: () {
                    Navigator.pop(bottomSheetContext);
                    _pickProfileImage(ImageSource.camera);
                  },
                ),
                if (hasAvatar)
                  _profileImageOption(
                    bottomSheetContext,
                    icon: Icons.delete_outline,
                    title: 'Remove Photo',
                    isDanger: true,
                    onTap: () {
                      Navigator.pop(bottomSheetContext);
                      _removeProfileImage();
                    },
                  ),
                AppSpacing.gapSm,
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(bottomSheetContext),
                    child: const Text('Cancel'),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _profileImageOption(
    BuildContext context, {
    required IconData icon,
    required String title,
    required VoidCallback onTap,
    bool isDanger = false,
  }) {
    final color =
        isDanger ? context.colors.error : context.colors.onSurface;
    final iconBackground = isDanger
        ? context.colors.errorContainer
        : context.colors.surfaceContainerHighest;

    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Container(
        width: 42,
        height: 42,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: iconBackground,
          borderRadius: AppRadius.brSm,
        ),
        child: Icon(
          icon,
          color: isDanger ? context.colors.error : context.colors.primary,
        ),
      ),
      title: Text(
        title,
        style: context.text.bodyLarge?.copyWith(
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
      trailing: Icon(
        Icons.chevron_right_rounded,
        color: context.colors.onSurfaceVariant,
      ),
      onTap: onTap,
    );
  }

  // =========================================================
  // AVATAR
  // =========================================================

  Widget _buildAvatar() {
    final avatarUrl = widget.viewModel.user?.avatarUrl;
    final loading = widget.viewModel.isLoading;

    return GestureDetector(
      onTap: loading ? null : _showProfileImageOptions,
      child: ProfileAvatar(
        fullName: _nameController.text,
        avatarUrl: avatarUrl,
        size: 88,
        badge: Container(
          width: 28,
          height: 28,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: context.colors.primary,
            shape: BoxShape.circle,
            border: Border.all(color: context.colors.surface, width: 2.5),
          ),
          child: Icon(
            Icons.edit_rounded,
            color: context.colors.onPrimary,
            size: 14,
          ),
        ),
        overlay: loading
            ? ColoredBox(
                color: Colors.black.withValues(alpha: 0.25),
                child: const Center(
                  child: SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.5,
                      color: Colors.white,
                    ),
                  ),
                ),
              )
            : null,
      ),
    );
  }

  // =========================================================
  // DATE
  // =========================================================

  String _formatDateForField(DateTime? date) {
    if (date == null) {
      return '';
    }

    final year = date.year.toString();
    final month = date.month.toString().padLeft(2, '0');
    final day = date.day.toString().padLeft(2, '0');

    return '$year-$month-$day';
  }

  Future<void> _selectDate() async {
    widget.viewModel.clearError();

    final selectedDate = await showDatePicker(
      context: context,
      initialDate: _dateOfBirth ?? DateTime(2000, 1, 1),
      firstDate: DateTime(1900, 1, 1),
      lastDate: DateTime.now(),
    );

    if (selectedDate == null) {
      return;
    }

    setState(() {
      _dateOfBirth = selectedDate;
      _dobController.text = _formatDateForField(selectedDate);
    });
  }

  // =========================================================
  // SAVE
  // =========================================================

  Future<void> _saveChanges() async {
    widget.viewModel.clearError();

    setState(() {
      _successMessage = null;
    });

    // Email is read-only — the VM preserves the authenticated address.
    final success = await widget.viewModel.updateProfile(
      fullName: _nameController.text,
      email: _emailController.text,
      dateOfBirth: _dateOfBirth,
    );

    if (!mounted) {
      return;
    }

    setState(() {});

    if (success) {
      setState(() {
        _successMessage = 'Profile information updated successfully.';
      });
    }
  }

  // =========================================================
  // CHANGE PASSWORD
  // =========================================================

  Future<void> _openChangePassword() async {
    widget.viewModel.clearError();

    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ChangePasswordView(viewModel: widget.viewModel),
      ),
    );

    if (!mounted) return;
    widget.viewModel.clearError();
    setState(() {});
  }

  void _clearError() {
    if (widget.viewModel.errorMessage != null) {
      widget.viewModel.clearError();
    }

    if (_successMessage != null) {
      setState(() {
        _successMessage = null;
      });
    }
  }

  // =========================================================
  // BUILD
  // =========================================================

  @override
  Widget build(BuildContext context) {
    final loading = widget.viewModel.isLoading;

    return ProfilePage(
      title: 'Edit Profile',
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg,
          AppSpacing.sm,
          AppSpacing.lg,
          AppSpacing.xxl,
        ),
        child: Column(
          children: [
            _buildAvatar(),
            AppSpacing.gapSm,
            GestureDetector(
              onTap: loading ? null : _showProfileImageOptions,
              child: Text(
                'Change Profile Picture',
                style: context.text.labelLarge?.copyWith(
                  color: context.colors.primary,
                ),
              ),
            ),
            AppSpacing.gapXl,
            ProfileCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (widget.viewModel.errorMessage != null) ...[
                    ProfileBanner.error(widget.viewModel.errorMessage!),
                    AppSpacing.gapLg,
                  ],
                  if (_successMessage != null) ...[
                    ProfileBanner.success(_successMessage!),
                    AppSpacing.gapLg,
                  ],
                  _fieldLabel(context, 'Full Name'),
                  AppSpacing.gapXs,
                  TextField(
                    controller: _nameController,
                    textCapitalization: TextCapitalization.words,
                    onChanged: (_) {
                      _clearError();
                      setState(() {});
                    },
                    decoration: const InputDecoration(hintText: 'Your name'),
                  ),
                  AppSpacing.gapLg,
                  Row(
                    children: [
                      _fieldLabel(context, 'Email'),
                      const SizedBox(width: AppSpacing.sm),
                      Text(
                        '· Cannot be changed',
                        style: context.text.bodySmall?.copyWith(
                          color: context.colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                  AppSpacing.gapXs,
                  TextField(
                    controller: _emailController,
                    readOnly: true,
                    enabled: false,
                    decoration: const InputDecoration(),
                  ),
                  AppSpacing.gapLg,
                  _fieldLabel(context, 'Date of Birth'),
                  AppSpacing.gapXs,
                  TextField(
                    controller: _dobController,
                    readOnly: true,
                    onTap: _selectDate,
                    decoration: const InputDecoration(
                      hintText: 'Select date',
                      suffixIcon: Icon(
                        Icons.calendar_today_outlined,
                        size: 20,
                      ),
                    ),
                  ),
                  AppSpacing.gapLg,
                  _fieldLabel(context, 'Security'),
                  AppSpacing.gapXs,
                  _ChangePasswordRow(
                    onTap:
                        widget.viewModel.isLoading ? null : _openChangePassword,
                  ),
                  AppSpacing.gapXl,
                  SizedBox(
                    width: double.infinity,
                    height: 52,
                    child: FilledButton(
                      onPressed: loading ? null : _saveChanges,
                      child: Text(loading ? 'Saving...' : 'Save Changes'),
                    ),
                  ),
                  AppSpacing.gapMd,
                  SizedBox(
                    width: double.infinity,
                    height: 50,
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Cancel'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _fieldLabel(BuildContext context, String text) {
    return Text(
      text,
      style: context.text.labelLarge?.copyWith(
        color: context.colors.onSurface,
      ),
    );
  }
}

/// Tappable "Change Password" row shown inside the Edit Profile form.
class _ChangePasswordRow extends StatelessWidget {
  const _ChangePasswordRow({required this.onTap});

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: context.colors.surfaceContainerHighest,
      borderRadius: AppRadius.brMd,
      child: InkWell(
        borderRadius: AppRadius.brMd,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.lg,
            vertical: 14,
          ),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: context.colors.primaryContainer,
                  borderRadius: AppRadius.brSm,
                ),
                child: Icon(
                  Icons.lock_outline_rounded,
                  color: context.colors.primary,
                  size: 20,
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Change Password',
                      style: context.text.bodyMedium?.copyWith(
                        color: context.colors.onSurface,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Update your account password',
                      style: context.text.bodySmall?.copyWith(
                        color: context.colors.onSurfaceVariant,
                      ),
                    ),
                  ],
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
