import 'package:flutter/material.dart';

import '../services/wiki_service.dart';
import '../widgets/wiki_narrative_view.dart';

/// The public profile — what other users see (§2.1, §2.8 step 10). `public`
/// pages only, same `user_edits ?? ai_body` / `user_hidden` rules: a proper
/// subset of the private view, nothing tagged `private` or `ai_only`.
class PublicWikiScreen extends StatelessWidget {
  const PublicWikiScreen({super.key, this.wikiService});

  static const path = '/profile/public';

  final WikiService? wikiService;

  @override
  Widget build(BuildContext context) {
    final wiki = wikiService ?? WikiService();
    return WikiNarrativeView(
      title: 'Your public profile',
      load: wiki.readPublicWiki,
      emptyText: "Nothing here is public yet. As you get comfortable sharing, "
          "parts of your story can become visible to others.",
    );
  }
}
