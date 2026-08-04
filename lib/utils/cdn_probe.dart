import 'dart:async';
import 'dart:math' show max;

import 'package:PiliPlus/http/browser_ua.dart';
import 'package:PiliPlus/http/constants.dart';
import 'package:PiliPlus/models/common/video/cdn_type.dart';
import 'package:PiliPlus/utils/cdn_rank.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/video_utils.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show kDebugMode, debugPrint;

/// Measures the candidate CDN hosts against a real signed media URL and keeps
/// the ranking that [CDNService.auto] resolves through.
///
/// Ported from bilibili-accelerator's `probeHost` / `rankHosts` / `rotateTarget`.
/// Three of its findings are load-bearing and were arrived at the hard way, so
/// they are preserved here rather than re-derived:
///
///  - Rank on measured throughput, not TTFB. A single RTT sample swings by an
///    order of magnitude and picks the wrong host.
///  - Probe the pool per viewer. Neither "overseas users want the *ov mirrors"
///    nor "always fall back to mainland" holds — Seattle and Tokyo measure
///    completely differently.
///  - A host that times out mid-read is still scored on the bytes it moved, so
///    it sinks to the bottom instead of vanishing from the ranking.
abstract final class CdnProbe {
  /// Matches bilibili-accelerator's PROBE_BYTES. Enough to see steady-state
  /// throughput, small enough to run eight of them on mobile data.
  static const int _probeBytes = 768 * 1024;
  static const Duration _probeTimeout = Duration(seconds: 4);
  static const Duration _cacheTtl = Duration(hours: 6);

  /// Bumped whenever the pool or the scoring changes, so stale rankings from a
  /// previous scheme are never read back.
  static const String _cacheVersion = 'v1';

  static List<CDNService>? _ranked;
  static int _cursor = 0;
  static Future<List<CdnSample>>? _inFlight;

  /// The host [CDNService.auto] currently resolves to, or null before the first
  /// ranking is available.
  static CDNService? get current {
    final ranked = _ranked ??= _readCache();
    if (ranked == null || ranked.isEmpty) return null;
    return ranked[_cursor % ranked.length];
  }

  /// Advance to the next-best host, wrapping. Returns null when there is no
  /// ranking yet, or only one host to choose from.
  static CDNService? rotate() {
    final ranked = _ranked ??= _readCache();
    if (ranked == null || ranked.length < 2) return null;
    _cursor = (_cursor + 1) % ranked.length;
    return ranked[_cursor];
  }

  // --- probing -------------------------------------------------------------

  /// Measure every candidate in parallel against [playUrls] — the signed URL
  /// list of something actually being played, so the probe exercises the real
  /// link rather than a fixed sample video.
  ///
  /// Concurrent calls share one run; the result is ranked, cached and applied.
  static Future<List<CdnSample>> probeAll(
    Iterable<String> playUrls, {
    List<CDNService> pool = kProbePool,
  }) {
    return _inFlight ??= _probeAll(playUrls, pool).whenComplete(() {
      _inFlight = null;
    });
  }

  static Future<List<CdnSample>> _probeAll(
    Iterable<String> playUrls,
    List<CDNService> pool,
  ) async {
    final urls = playUrls.toList();
    if (urls.isEmpty) return const [];

    final dio = Dio(
      BaseOptions(
        connectTimeout: _probeTimeout,
        headers: {
          'user-agent': BrowserUa.pc,
          'referer': HttpString.baseUrl,
        },
      ),
    );
    try {
      final samples = await Future.wait(
        pool.map((service) => _probeOne(dio, service, urls)),
      );
      final ranked = rankCdnSamples(samples);

      // The caller may probe a wider set than auto is allowed to choose from —
      // the settings dialog measures every host so the user can pick by hand.
      // Only curated-pool members ever enter the ranking auto resolves through.
      final selectable = ranked
          .map((e) => e.service)
          .where(kProbePool.contains)
          .toList();
      if (selectable.isNotEmpty) {
        _ranked = selectable;
        _cursor = 0;
        _writeCache(selectable);
      }
      if (kDebugMode) {
        debugPrint(
          '[CdnProbe] ${ranked.map((e) => '${e.service.name}=${e.label}').join(', ')}',
        );
      }
      return ranked;
    } finally {
      dio.close(force: true);
    }
  }

  static Future<CdnSample> _probeOne(
    Dio dio,
    CDNService service,
    List<String> urls,
  ) async {
    final url = VideoUtils.getCdnUrl(urls, defaultCDNService: service);
    final cancelToken = CancelToken();
    final stopwatch = Stopwatch()..start();

    int received = 0;
    int? ttfbMs;
    int? firstByteAt;

    // Throughput is measured from the first byte, so a slow handshake shows up
    // as TTFB instead of dragging the bandwidth figure down.
    double? mbpsSoFar() {
      final since = firstByteAt;
      if (since == null || received == 0) return null;
      // Floored at 1ms: a host quick enough to finish inside the same
      // millisecond is the fastest one, not an unmeasurable one.
      final elapsed = max(stopwatch.elapsedMilliseconds - since, 1);
      return received * 8 / (elapsed * 1000);
    }

    try {
      final response = await dio.get<ResponseBody>(
        url,
        cancelToken: cancelToken,
        options: Options(responseType: ResponseType.stream),
      );
      final stream = response.data?.stream;
      if (stream == null) {
        return CdnSample(service, error: '无响应');
      }

      await for (final chunk in stream.timeout(_probeTimeout)) {
        firstByteAt ??= stopwatch.elapsedMilliseconds;
        ttfbMs ??= firstByteAt;
        received += chunk.length;
        if (received >= _probeBytes ||
            stopwatch.elapsed >= _probeTimeout) {
          break;
        }
      }
      cancelToken.cancel();

      final mbps = mbpsSoFar();
      if (mbps == null) return CdnSample(service, ttfbMs: ttfbMs, error: '无数据');
      return CdnSample(
        service,
        mbps: mbps,
        ttfbMs: ttfbMs,
        ok: received >= _probeBytes,
      );
    } catch (e) {
      cancelToken.cancel();
      // Partial transfers still score — that is what keeps a slow-but-alive
      // host ranked below the good ones instead of dropping out entirely.
      final mbps = mbpsSoFar();
      if (mbps != null) {
        return CdnSample(service, mbps: mbps, ttfbMs: ttfbMs);
      }
      return CdnSample(service, ttfbMs: ttfbMs, error: _describe(e));
    }
  }

  static String _describe(Object e) {
    if (e is DioException) {
      final code = e.response?.statusCode;
      if (code != null && code >= 400 && code < 500) return '不支持($code)';
      return switch (e.type) {
        DioExceptionType.connectionTimeout ||
        DioExceptionType.receiveTimeout => '超时',
        DioExceptionType.cancel => '已取消',
        _ => '失败',
      };
    }
    if (e is TimeoutException) return '超时';
    return '失败';
  }

  // --- cache ---------------------------------------------------------------

  /// Connection type stands in for "which network am I on" — switching between
  /// wifi and cellular invalidates a ranking, which the web version approximated
  /// with timezone + language.
  static String _netKey = 'unknown';

  static Future<void> refreshNetKey() async {
    try {
      final results = await Connectivity().checkConnectivity();
      final next = results.map((e) => e.name).join('+');
      if (next != _netKey) {
        _netKey = next;
        _ranked = null;
        _cursor = 0;
      }
    } catch (_) {
      // Leave the previous key in place; a stale ranking beats no ranking.
    }
  }

  static List<CDNService>? _readCache() {
    final raw = GStorage.setting.get(SettingBoxKey.cdnRank);
    if (raw is! Map) return null;
    if (raw['version'] != _cacheVersion || raw['net'] != _netKey) return null;

    final ts = raw['ts'];
    if (ts is! int ||
        DateTime.now().millisecondsSinceEpoch - ts > _cacheTtl.inMilliseconds) {
      return null;
    }

    final names = raw['hosts'];
    if (names is! List) return null;
    final ranked = <CDNService>[];
    for (final name in names) {
      for (final service in CDNService.values) {
        if (service.name == name && service.host != null) {
          ranked.add(service);
          break;
        }
      }
    }
    return ranked.isEmpty ? null : ranked;
  }

  static void _writeCache(List<CDNService> ranked) {
    GStorage.setting.put(SettingBoxKey.cdnRank, {
      'version': _cacheVersion,
      'net': _netKey,
      'ts': DateTime.now().millisecondsSinceEpoch,
      'hosts': ranked.map((e) => e.name).toList(),
    });
  }
}
