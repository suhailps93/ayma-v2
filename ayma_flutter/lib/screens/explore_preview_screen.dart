import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../services/photo_service.dart';
import '../services/profile_service.dart';
import '../theme.dart';
import 'public_wiki_screen.dart';

/// "How others see me" — renders the caller's own Explore card exactly as it
/// appears to another user browsing Explore (§6.4), plus a shortcut into the
/// public profile a viewer lands on when they tap it (§2.1 public tier).
class ExplorePreviewScreen extends StatefulWidget {
  const ExplorePreviewScreen({super.key, this.profileService, this.photoService});

  static const path = '/profile/preview';

  final ProfileService? profileService;
  final PhotoService? photoService;

  @override
  State<ExplorePreviewScreen> createState() => _ExplorePreviewScreenState();
}

class _ExplorePreviewScreenState extends State<ExplorePreviewScreen> {
  late final ProfileService _profiles =
      widget.profileService ?? ProfileService();
  late final PhotoService _photos = widget.photoService ?? PhotoService();

  Future<String?>? _primaryPhoto;

  @override
  void initState() {
    super.initState();
    _primaryPhoto = _loadPrimaryPhoto();
  }

  Future<String?> _loadPrimaryPhoto() async {
    try {
      final grid = await _photos.loadGrid();
      return grid.isEmpty ? null : grid.first.downloadUrl;
    } catch (_) {
      return null;
    }
  }

  int? _age(DateTime? birthdate) {
    if (birthdate == null) return null;
    final now = DateTime.now();
    var age = now.year - birthdate.year;
    if (now.month < birthdate.month ||
        (now.month == birthdate.month && now.day < birthdate.day)) {
      age--;
    }
    return age;
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Scaffold(
      appBar: AppBar(title: const Text('Preview')),
      body: StreamBuilder<ProfileData?>(
        stream: _profiles.watchProfile(),
        builder: (context, snap) {
          final p = snap.data;
          final age = _age(p?.birthdate);
          final name = (p?.name ?? '').trim();
          final location = (p?.location ?? '').trim();
          final subtitle = [
            if (age != null) '$age',
            if (location.isNotEmpty) location,
          ].join(' · ');

          final gaps = <String>[
            if (name.isEmpty) 'a name',
            if (age == null) 'your birthdate',
            if (location.isEmpty) 'your location',
          ];

          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
            children: [
              Text('This is how you appear in Explore.',
                  style:
                      AymaType.sans(size: 14, soft: true, color: ac.fgMute)),
              const SizedBox(height: 16),

              // --- the Explore card, as another user sees it (§6.4) ---
              Container(
                decoration: BoxDecoration(
                  color: ac.bgCard,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: ac.lineSoft, width: 0.5),
                ),
                clipBehavior: Clip.antiAlias,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    FutureBuilder<String?>(
                      future: _primaryPhoto,
                      builder: (context, ps) {
                        final url = ps.data;
                        return AspectRatio(
                          aspectRatio: 4 / 3,
                          child: url == null
                              ? Container(
                                  color: ac.bgElev,
                                  alignment: Alignment.center,
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(Icons.person_outline,
                                          size: 40, color: ac.fgMute),
                                      const SizedBox(height: 6),
                                      Text('No photo yet',
                                          style: AymaType.sans(
                                              size: 12, color: ac.fgMute)),
                                    ],
                                  ),
                                )
                              : Image.network(url, fit: BoxFit.cover,
                                  errorBuilder: (_, __, ___) => Container(
                                        color: ac.bgElev,
                                        child: Icon(Icons.broken_image_outlined,
                                            color: ac.fgMute),
                                      )),
                        );
                      },
                    ),
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(name.isEmpty ? 'Someone' : name,
                                    style: AymaType.serif(
                                        size: 18, color: ac.fg)),
                                if (subtitle.isNotEmpty) ...[
                                  const SizedBox(height: 4),
                                  Text(subtitle,
                                      style: AymaType.sans(
                                          size: 13, color: ac.fgMute)),
                                ],
                              ],
                            ),
                          ),
                          Text('check compatibility',
                              style: AymaType.sans(
                                  size: 12, color: ac.fgMute)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),

              if (gaps.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  'Add ${_join(gaps)} in Profile details so your card is complete.',
                  style: AymaType.sans(size: 13, color: ac.fgMute),
                ),
              ],

              const SizedBox(height: 24),
              Text('When someone taps your card',
                  style: AymaType.mono(size: 11, color: ac.fgMute)),
              const SizedBox(height: 8),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.article_outlined),
                title: Text('Your public profile',
                    style: AymaType.sans(size: 15, color: ac.fg)),
                subtitle: Text('The public parts of your wiki (§2.1)',
                    style: AymaType.sans(
                        size: 12, soft: true, color: ac.fgMute)),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => context.push(PublicWikiScreen.path),
              ),
            ],
          );
        },
      ),
    );
  }

  static String _join(List<String> parts) {
    if (parts.length == 1) return parts.first;
    if (parts.length == 2) return '${parts[0]} and ${parts[1]}';
    return '${parts.sublist(0, parts.length - 1).join(', ')}, and ${parts.last}';
  }
}
