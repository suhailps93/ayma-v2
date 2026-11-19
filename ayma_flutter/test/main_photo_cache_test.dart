import 'package:ayma_flutter/services/main_photo_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    MainPhotoCache.instance.reset();
    SharedPreferences.setMockInitialValues({});
  });

  test('save then load returns the thumb, keyed per uid', () async {
    await MainPhotoCache.instance.save('a', 'https://x/a__thumb_400.jpg');
    await MainPhotoCache.instance.save('b', 'https://x/b__thumb_400.jpg');

    // A fresh process (cleared memory) still reads the persisted value.
    MainPhotoCache.instance.reset();
    await MainPhotoCache.instance.load('a');
    expect(MainPhotoCache.instance.thumbFor('a'), 'https://x/a__thumb_400.jpg');

    await MainPhotoCache.instance.load('b');
    expect(MainPhotoCache.instance.thumbFor('b'), 'https://x/b__thumb_400.jpg');
  });

  test('a uid with nothing loaded reads null (no cross-user leak)', () async {
    await MainPhotoCache.instance.save('a', 'https://x/a.jpg');
    // 'c' was never saved — never returns another user's thumb.
    await MainPhotoCache.instance.load('c');
    expect(MainPhotoCache.instance.thumbFor('c'), isNull);
  });

  test('saving null/empty clears the entry (photo removed)', () async {
    await MainPhotoCache.instance.save('a', 'https://x/a.jpg');
    await MainPhotoCache.instance.save('a', null);
    MainPhotoCache.instance.reset();
    await MainPhotoCache.instance.load('a');
    expect(MainPhotoCache.instance.thumbFor('a'), isNull);

    await MainPhotoCache.instance.save('a', 'https://x/a.jpg');
    await MainPhotoCache.instance.save('a', '');
    MainPhotoCache.instance.reset();
    await MainPhotoCache.instance.load('a');
    expect(MainPhotoCache.instance.thumbFor('a'), isNull);
  });

  test('an empty uid folds to a single "default" bucket', () async {
    await MainPhotoCache.instance.save('', 'https://x/default.jpg');
    MainPhotoCache.instance.reset();
    await MainPhotoCache.instance.load('');
    expect(MainPhotoCache.instance.thumbFor(''), 'https://x/default.jpg');
  });
}
