import 'package:ayma_flutter/services/voice_transport.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('audioOutputRouteKind', () {
    test('maps platform audio-output labels to route kinds', () {
      expect(audioOutputRouteKind('Speakerphone'), 'speaker');
      expect(audioOutputRouteKind('Earpiece'), 'earpiece');
      expect(audioOutputRouteKind('Phone Receiver'), 'earpiece');
      expect(audioOutputRouteKind('Bluetooth'), 'bluetooth');
      expect(audioOutputRouteKind('Pixel Buds (Bluetooth)'), 'bluetooth');
      expect(audioOutputRouteKind('Wired Headset'), 'wired');
      expect(audioOutputRouteKind('USB Headphones'), 'wired');
    });

    test('missing or unrecognised labels fall back honestly', () {
      expect(audioOutputRouteKind(null), 'unknown');
      expect(audioOutputRouteKind(''), 'unknown');
      expect(audioOutputRouteKind('HDMI Output'), 'other');
    });
  });
}
