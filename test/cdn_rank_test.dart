import 'package:PiliPlus/models/common/video/cdn_type.dart';
import 'package:PiliPlus/utils/cdn_rank.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  List<String> order(List<CdnSample> samples) =>
      rankCdnSamples(samples).map((e) => e.service.name).toList();

  group('rankSamples', () {
    test('ranks on measured throughput, not TTFB', () {
      // The whole point of the throughput-first rule: cosov is three times
      // faster despite answering slower, and must still win.
      expect(
        order([
          CdnSample(CDNService.ali, mbps: 12, ttfbMs: 30, ok: true),
          CdnSample(CDNService.cosov, mbps: 40, ttfbMs: 180, ok: true),
          CdnSample(CDNService.hw, mbps: 25, ttfbMs: 90, ok: true),
        ]),
        ['cosov', 'hw', 'ali'],
      );
    });

    test('uses TTFB only to break a throughput tie', () {
      expect(
        order([
          CdnSample(CDNService.ali, mbps: 20, ttfbMs: 200, ok: true),
          CdnSample(CDNService.cos, mbps: 20, ttfbMs: 40, ok: true),
        ]),
        ['cos', 'ali'],
      );
    });

    test('a host that timed out mid-read sinks but does not vanish', () {
      final ranked = rankCdnSamples([
        CdnSample(CDNService.ali, mbps: 3, ttfbMs: 500),
        CdnSample(CDNService.cosov, mbps: 40, ttfbMs: 180, ok: true),
      ]);
      expect(ranked.map((e) => e.service.name), ['cosov', 'ali']);
      expect(ranked.length, 2);
    });

    test('outright failures sort last', () {
      expect(
        order([
          CdnSample(CDNService.akamai, error: '不支持(403)'),
          CdnSample(CDNService.ali, mbps: 3, ttfbMs: 500),
          CdnSample(CDNService.cosov, mbps: 40, ok: true),
        ]),
        ['cosov', 'ali', 'akamai'],
      );
    });

    test('empty input does not throw', () {
      expect(rankCdnSamples([]), isEmpty);
    });

    test('does not mutate the caller list', () {
      final input = [
        CdnSample(CDNService.ali, mbps: 3, ok: true),
        CdnSample(CDNService.cosov, mbps: 40, ok: true),
      ];
      rankCdnSamples(input);
      expect(input.first.service, CDNService.ali);
    });
  });

  group('kProbePool', () {
    test('every member has a host to rewrite onto', () {
      for (final service in kProbePool) {
        expect(service.host, isNotNull, reason: service.name);
      }
    });

    test('excludes akamai, which 403s on upos-signed paths', () {
      expect(kProbePool, isNot(contains(CDNService.akamai)));
    });

    test('auto is not a probe target', () {
      expect(kProbePool, isNot(contains(CDNService.auto)));
      expect(CDNService.auto.host, isNull);
    });
  });
}
