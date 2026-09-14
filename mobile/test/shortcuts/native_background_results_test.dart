import 'package:flutter_test/flutter_test.dart';
import 'package:maoguai_signin/shortcuts/native_background_results.dart';

void main() {
  test('native result map accepts one complete redacted result', () {
    final result = NativeBackgroundResult.fromMap({
      'resultId': 'swift-1',
      'credentialInstanceId': 'credential-1',
      'day': '2026-09-14',
      'occurredAt': '2026-09-14T08:05:00+08:00',
      'status': 'done',
      'title': '今日已签到',
      'detail': '已跳过重复提交。',
    });

    expect(result.resultId, 'swift-1');
    expect(result.record.day, '2026-09-14');
    expect(result.record.status.name, 'done');
    expect(result.record.source.name, 'shortcutBackground');
  });

  test('native result map rejects a missing result id', () {
    expect(
      () => NativeBackgroundResult.fromMap({
        'day': '2026-09-14',
        'credentialInstanceId': 'credential-1',
        'occurredAt': '2026-09-14T08:05:00+08:00',
        'status': 'done',
        'title': '今日已签到',
        'detail': '已跳过重复提交。',
      }),
      throwsFormatException,
    );
  });
}
