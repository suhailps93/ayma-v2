// Defensive de-dupe of the "Links" / "Social profiles" sections for reports
// stored before the backend cleaned them (mirrors deep_dive_links.py).
import 'package:ayma_flutter/models/living_report.dart';
import 'package:flutter_test/flutter_test.dart';

ReportBlock _link(String id, String url, {String label = '', String tag = ''}) =>
    ReportBlock.fromMap({
      'block_id': id,
      'type': 'link',
      'url': url,
      'label': label,
      'tag': tag,
    });

ReportSection _links(List<ReportBlock> b) =>
    ReportSection(heading: 'Links', blocks: b);
ReportSection _social(List<ReportBlock> b) =>
    ReportSection(heading: 'Social profiles', blocks: b);

void main() {
  test('normalizedUrlKey strips scheme, www, tracking, slash, host case', () {
    expect(
      normalizedUrlKey('HTTPS://www.Example.com/Post/?utm_source=x&fbclid=1#t'),
      normalizedUrlKey('http://example.com/Post'),
    );
    expect(normalizedUrlKey('example.com/a?b=2&a=1'),
        normalizedUrlKey('https://example.com/a/?a=1&b=2'));
  });

  test('profile pages are social, repos/videos are not', () {
    expect(socialProfilePlatform('https://github.com/suhail'), 'github');
    expect(socialProfilePlatform('https://github.com/suhail/repo'), isNull);
    expect(socialProfilePlatform('https://www.youtube.com/@suhail'), 'youtube');
    expect(socialProfilePlatform('https://youtube.com/watch?v=1'), isNull);
    expect(socialProfilePlatform('https://facebook.com/suhail.ps'), 'facebook');
    expect(socialProfilePlatform('https://example.com/suhail'), isNull);
  });

  test('duplicates across lists collapse; socials first; one per platform', () {
    final out = dedupeLinkSections([
      _links([
        _link('link:1', 'https://github.com/suhail', label: 'GitHub'),
        _link('link:2', 'https://www.youtube.com/@suhail/', label: 'YT'),
        _link('link:3', 'https://facebook.com/suhail.ps', label: 'FB'),
        _link('link:4', 'https://Blog.com/post/?utm_medium=x', label: 'Post'),
        _link('link:5', 'http://www.blog.com/post', label: 'Post again'),
        _link('link:6', 'https://github.com/suhail/repo', label: 'Repo'),
      ]),
      _social([
        _link('social:1', 'https://github.com/suhail',
            label: '@suhail', tag: 'github'),
        _link('social:2', 'https://instagram.com/suhailps93',
            label: '@suhailps93', tag: 'instagram'),
        _link('social:3', 'https://www.instagram.com/suhailps93/?igsh=1',
            label: '@suhailps93', tag: 'instagram'),
        _link('social:4', 'https://x.com/suhailps93',
            label: '@suhailps93', tag: 'x'),
      ]),
    ]);
    expect([for (final s in out) s.heading], ['Social profiles', 'Links']);
    expect([for (final b in out[0].blocks) b.blockId],
        ['social:1', 'social:2', 'social:4']);
    expect([for (final b in out[1].blocks) b.linkLabel], ['Post', 'Repo']);
  });

  test('LivingReport.fromMap applies the de-dupe and keeps other sections', () {
    final r = LivingReport.fromMap({
      'title': 't',
      'sections': [
        {
          'heading': 'Summary',
          'blocks': [
            {'block_id': 's', 'type': 'text', 'text': 'hi'}
          ],
        },
        {
          'heading': 'Links',
          'blocks': [
            {'block_id': 'l', 'type': 'link', 'url': 'https://github.com/a'}
          ],
        },
        {'heading': 'Photos found online', 'blocks': []},
      ],
      'meta': {},
    });
    expect([for (final s in r.sections) s.heading],
        ['Summary', 'Photos found online']);
  });
}
