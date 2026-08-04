/// Scoring and ranking for CDN probe results.
///
/// Deliberately free of app dependencies — no storage, no network, no Flutter
/// bindings — so it stays unit-testable on its own. The measurement side lives
/// in `cdn_probe.dart`.
library;

import 'package:PiliPlus/models/common/video/cdn_type.dart';

/// One candidate host's measured result.
class CdnSample {
  CdnSample(this.service, {this.mbps, this.ttfbMs, this.ok = false, this.error});

  final CDNService service;

  /// Throughput measured from the first byte, so a slow handshake shows up in
  /// [ttfbMs] instead of dragging the bandwidth figure down.
  final double? mbps;
  final int? ttfbMs;

  /// Whether the full probe budget transferred. A partial transfer still
  /// carries a usable [mbps].
  final bool ok;
  final String? error;

  String get label => mbps == null
      ? (error ?? '失败')
      : '${mbps!.toStringAsFixed(1)} Mbps'
            '${ttfbMs == null ? '' : ' · ${ttfbMs}ms'}'
            '${ok ? '' : '（超时）'}';
}

/// Rank candidates best-first: completed probes, then throughput descending,
/// with TTFB only as a tiebreak.
///
/// Ranking on TTFB was tried first and picked the wrong hosts — a single RTT
/// sample swings by an order of magnitude, while measured throughput does not.
/// A host that timed out mid-read keeps the score for the bytes it did move, so
/// it sinks to the bottom rather than dropping out of the ranking entirely.
List<CdnSample> rankCdnSamples(List<CdnSample> samples) {
  return List<CdnSample>.of(samples)..sort((a, b) {
    if (a.ok != b.ok) return a.ok ? -1 : 1;

    final aMbps = a.mbps, bMbps = b.mbps;
    if (aMbps != null && bMbps != null) {
      if (aMbps != bMbps) return bMbps.compareTo(aMbps);
    } else if (aMbps != null) {
      return -1;
    } else if (bMbps != null) {
      return 1;
    }

    final aTtfb = a.ttfbMs, bTtfb = b.ttfbMs;
    if (aTtfb != null && bTtfb != null) return aTtfb.compareTo(bTtfb);
    if (aTtfb != null) return -1;
    if (bTtfb != null) return 1;
    return 0;
  });
}
