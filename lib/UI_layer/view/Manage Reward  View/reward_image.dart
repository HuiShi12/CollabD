import 'package:flutter/material.dart';
import '../../../main.dart';
import '../../../Data_layer/repository/Reward Repository/reward_models.dart';

String rewardDate(DateTime date) =>
    '${date.day.toString().padLeft(2, "0")}/${date.month.toString().padLeft(2, "0")}/${date.year}';

class RewardImage extends StatelessWidget {
  final String imageUrl, label;
  final BoxFit fit;
  const RewardImage({
    super.key,
    required this.imageUrl,
    required this.label,
    this.fit = BoxFit.cover,
  });
  @override
  Widget build(BuildContext context) {
    final uri = Uri.tryParse(imageUrl);
    final colors = context.colors;
    final placeholder = Container(
      color: colors.primaryContainer,
      alignment: Alignment.center,
      padding: const EdgeInsets.all(12),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.image_outlined, size: 32, color: colors.onPrimaryContainer),
          const SizedBox(height: 8),
          Text(
            label,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          Text(
            imageUrl.startsWith('mock:')
                ? 'Prototype artwork'
                : 'Image unavailable',
            style: Theme.of(context).textTheme.labelSmall,
          ),
        ],
      ),
    );
    if (uri == null ||
        !['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty) {
      return placeholder;
    }
    return Image.network(
      imageUrl,
      fit: fit,
      errorBuilder: (_, error, stack) => placeholder,
    );
  }
}

class RewardVisual extends StatelessWidget {
  final TouristReward reward;
  const RewardVisual({super.key, required this.reward});
  @override
  Widget build(BuildContext context) {
    // Both reward types now store a real, already-composed image in
    // Supabase Storage (Digital Travel Stamp: photo drawn inside the
    // picked frame, plus place/township/date — see
    // ImageService.composeDigitalTravelStamp) — no widget-drawn overlay
    // needed here any more.
    if (reward.type == RewardType.digitalTravelStamp) {
      // Stamps are portrait (the stamp_frames designs, e.g. 800x1000).
      // BoxFit.contain (not cover) so the whole card is visible instead of
      // being squashed/cropped into a short wide box.
      return ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 420),
        child: AspectRatio(
          aspectRatio: 0.8,
          child: RewardImage(
            imageUrl: reward.imageUrl,
            label: reward.title,
            fit: BoxFit.contain,
          ),
        ),
      );
    }
    return SizedBox(
      height: 170,
      width: double.infinity,
      child: RewardImage(imageUrl: reward.imageUrl, label: reward.title),
    );
  }
}
