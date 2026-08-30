import 'package:flutter/material.dart';

import '../services/wiki_service.dart';
import '../widgets/wiki_narrative_view.dart';

/// The user's own private profile — their story as Ayma has compiled it (§2.1,
/// §2.8 step 9). `public` + `private` pages, `user_edits ?? ai_body`, minus
/// `user_hidden`.
class PrivateWikiScreen extends StatelessWidget {
  const PrivateWikiScreen({super.key, this.wikiService});

  static const path = '/profile/wiki';

  final WikiService? wikiService;

  @override
  Widget build(BuildContext context) {
    final wiki = wikiService ?? WikiService();
    return WikiNarrativeView(
      title: 'Your story',
      load: wiki.readPrivateWiki,
      editService: wiki,
      emptyText: 'Once you and Ayma have talked a little, your story will '
          'start to take shape here.',
    );
  }
}
