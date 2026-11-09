import 'package:flutter/material.dart';

import '../services/dm_service.dart';
import '../theme.dart';

/// The in-app card for a report shared into a DM: card image (placeholder
/// when it can't load), title and summary. [onTap] opens the report natively;
/// the external link is never shown.
class SharedReportCard extends StatelessWidget {
  const SharedReportCard({super.key, required this.share, required this.onTap});

  static const double width = 240;

  final DmReportShare share;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final placeholder = Container(
      width: width,
      height: 128,
      color: ac.bgCard,
      alignment: Alignment.center,
      child: Icon(Icons.description_outlined, color: ac.fgMute, size: 32),
    );
    return Material(
      color: ac.bgCard,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          width: width,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (share.cardUrl.isEmpty)
                placeholder
              else
                Image.network(
                  share.cardUrl,
                  width: width,
                  height: 128,
                  fit: BoxFit.cover,
                  loadingBuilder: (ctx, child, progress) =>
                      progress == null ? child : placeholder,
                  errorBuilder: (ctx, _, __) => placeholder,
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      share.title.isEmpty ? 'Shared report' : share.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: AymaType.sans(
                        size: 15,
                        color: ac.fg,
                        weight: FontWeight.w600,
                      ),
                    ),
                    if (share.summary.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        share.summary,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: AymaType.sans(size: 13, color: ac.fgDim),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
