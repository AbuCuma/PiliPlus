import 'dart:async';

import 'package:PiliPlus/http/video.dart';
import 'package:PiliPlus/models/common/video/cdn_type.dart';
import 'package:PiliPlus/models/common/video/video_type.dart';
import 'package:PiliPlus/models/video/play/url.dart';
import 'package:PiliPlus/utils/cdn_probe.dart';
import 'package:PiliPlus/utils/cdn_rank.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:PiliPlus/utils/video_utils.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:material_ui/material_ui.dart';

class SelectDialog<T> extends StatelessWidget {
  final T? value;
  final String title;
  final List<(T, String)> values;
  final Widget Function(BuildContext, int)? subtitleBuilder;
  final bool toggleable;

  const SelectDialog({
    super.key,
    this.value,
    required this.values,
    required this.title,
    this.subtitleBuilder,
    this.toggleable = false,
  });

  @override
  Widget build(BuildContext context) {
    final titleMedium = TextTheme.of(context).titleMedium!;
    return AlertDialog(
      clipBehavior: Clip.hardEdge,
      title: Text(title),
      constraints: subtitleBuilder != null
          ? const BoxConstraints.tightFor(width: 320)
          : null,
      contentPadding: const EdgeInsets.symmetric(vertical: 12),
      content: Material(
        type: .transparency,
        child: SingleChildScrollView(
          child: RadioGroup<T>(
            onChanged: (v) => Navigator.of(context).pop(v ?? value),
            groupValue: value,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: List.generate(
                values.length,
                (index) {
                  final item = values[index];
                  return RadioListTile<T>(
                    toggleable: toggleable,
                    dense: true,
                    value: item.$1,
                    title: Text(
                      item.$2,
                      style: titleMedium,
                    ),
                    subtitle: subtitleBuilder?.call(context, index),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class CdnSelectDialog extends StatefulWidget {
  final BaseItem? sample;

  const CdnSelectDialog({
    super.key,
    this.sample,
  });

  @override
  State<CdnSelectDialog> createState() => _CdnSelectDialogState();
}

class _CdnSelectDialogState extends State<CdnSelectDialog> {
  /// Everything worth measuring: the curated auto pool first, then every other
  /// selectable option. That deliberately includes [CDNService.baseUrl] and
  /// [CDNService.backupUrl], which rewrite nothing — measuring them is the only
  /// way to see what bilibili's own assignment is actually worth, and it is the
  /// comparison that justifies rewriting at all.
  ///
  /// Only [kProbePool] members can win the auto ranking; see [CdnProbe.probeAll].
  static final List<CDNService> _testPool = [
    ...kProbePool,
    ...CDNService.values.where(
      (e) => e != CDNService.auto && !kProbePool.contains(e),
    ),
  ];

  final ValueNotifier<Map<CDNService, CdnSample>?> _results = ValueNotifier(null);
  late final bool _cdnSpeedTest;

  @override
  void initState() {
    super.initState();
    _cdnSpeedTest = Pref.cdnSpeedTest;
    if (_cdnSpeedTest) {
      _startSpeedTest();
    }
  }

  @override
  void dispose() {
    _results.dispose();
    super.dispose();
  }

  Future<Iterable<String>> _getSampleUrls() async {
    if (widget.sample case final sample?) return sample.playUrls;
    final result = await VideoHttp.videoUrl(
      cid: 196018899,
      bvid: 'BV1fK4y1t7hj',
      tryLook: false,
      videoType: VideoType.ugc,
    );
    final item = result.dataOrNull?.dash?.video?.first;
    if (item == null) throw Exception('无法获取视频流');
    return item.playUrls;
  }

  Future<void> _startSpeedTest() async {
    try {
      final urls = await _getSampleUrls();
      final samples = await CdnProbe.probeAll(urls, pool: _testPool);
      if (!mounted) return;
      _results.value = {for (final s in samples) s.service: s};
    } catch (e) {
      if (kDebugMode) debugPrint('CDN speed test failed: $e');
      if (mounted) _results.value = const {};
    }
  }

  String _subtitleFor(CDNService service, Map<CDNService, CdnSample>? results) {
    if (service == CDNService.auto) {
      final current = CdnProbe.current;
      return current == null ? '测速后自动选择最快节点' : '当前：${current.name}';
    }
    if (results == null) return '测速中…';
    final sample = results[service];
    if (sample == null) return '---';

    // baseUrl / backupUrl rewrite nothing, so their reading is the "no
    // acceleration" reference every other row should be read against.
    final suffix = switch (service) {
      CDNService.baseUrl => '（B站原始分配）',
      CDNService.backupUrl => '（不改写）',
      _ => sample.service == CdnProbe.current ? ' ✓' : '',
    };
    return '${sample.label}$suffix';
  }

  @override
  Widget build(BuildContext context) {
    return SelectDialog<CDNService>(
      title: 'CDN 设置',
      values: CDNService.values.map((i) => (i, i.desc)).toList(),
      value: VideoUtils.cdnService,
      subtitleBuilder: _cdnSpeedTest
          ? (context, index) {
              final service = CDNService.values[index];
              return ValueListenableBuilder(
                valueListenable: _results,
                builder: (context, results, _) {
                  return Text(
                    _subtitleFor(service, results),
                    style: const TextStyle(fontSize: 13),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  );
                },
              );
            }
          : null,
    );
  }
}
