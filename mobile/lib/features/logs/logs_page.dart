import 'dart:async';

import 'package:flutter/material.dart';

import '../../app_state.dart';
import '../../domain/sign_in_models.dart';
import '../../ui/scenic_page.dart';
import 'history_calendar_page.dart';
import 'calendar_status_icon.dart';
import 'record_calendar_data.dart';
import 'record_detail_page.dart';

class LogsPage extends StatefulWidget {
  const LogsPage({required this.controller, super.key});
  final SignInAppController controller;

  @override
  State<LogsPage> createState() => _LogsPageState();
}

class _LogsPageState extends State<LogsPage> {
  RecordCalendarData? _data;
  int _request = 0;
  String? _error;
  SignInAppController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    controller.addListener(_refresh);
    _refresh();
  }

  @override
  void dispose() {
    controller.removeListener(_refresh);
    super.dispose();
  }

  void _refresh() => unawaited(_load());

  Future<void> _load() async {
    final request = ++_request;
    final state = controller.state;
    final generation = state.plan?.generation;
    setState(() {
      _data = null;
      _error = null;
    });
    if (!state.isLoggedIn || generation == null) return;
    final today = DateUtils.dateOnly(state.now.toLocal());
    final weekStart = DateTime(today.year, today.month, today.day - 6);
    final monthStart = DateTime(today.year, today.month);
    try {
      final data = await RecordCalendarData.load(
        controller.dependencies.repository.forGeneration(generation),
        weekStart.isBefore(monthStart) ? weekStart : monthStart,
        today,
      );
      if (!mounted ||
          request != _request ||
          !controller.state.isLoggedIn ||
          controller.state.plan?.generation != generation) {
        return;
      }
      setState(() => _data = data);
    } catch (_) {
      if (mounted && request == _request) setState(() => _error = '读取统计失败，请重试');
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = controller.state;
    final records =
        state.records.where((r) => r.day == dayKey(state.now)).toList()
          ..sort((a, b) => b.occurredAt.compareTo(a.occurredAt));
    final recent = records.take(5).toList();
    final VoidCallback? openHistory = state.plan == null
        ? null
        : () {
            Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => HistoryCalendarPage(
                  controller: controller,
                  generation: state.plan!.generation,
                  initialDay: state.now,
                ),
              ),
            );
          };
    return ScenicScrollPage(
      showArtwork: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const ScenicPageHeader(title: '签到记录'),
          const SizedBox(height: 18),
          if (_data case final data?) ...[
            _RecordsOverview(data: data, today: state.now.toLocal()),
            const SizedBox(height: 12),
          ] else if (_error != null)
            TextButton(onPressed: _refresh, child: Text(_error!)),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.calendar_month_outlined, size: 22),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '${state.now.month}月${state.now.day}日',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ),
                      Semantics(
                        label: '查看全部历史',
                        button: true,
                        onTap: openHistory,
                        child: ExcludeSemantics(
                          child: TextButton(
                            onPressed: openHistory,
                            child: const Text('查看全部历史'),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  if (recent.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 28),
                      child: Center(child: Text('今天暂无签到记录')),
                    ),
                  ...recent.map(
                    (record) => SignInRecordTile(
                      record: record,
                      onTap: () =>
                          openRecordDetail(context, controller, record),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RecordsOverview extends StatelessWidget {
  const _RecordsOverview({required this.data, required this.today});
  final RecordCalendarData data;
  final DateTime today;

  @override
  Widget build(BuildContext context) {
    final count = data.successCountForMonth(dayKey(today).substring(0, 7));
    final status = data.statusForDay(dayKey(today));
    final todayLabel = switch (status) {
      CalendarDayStatus.success => '今日已签到',
      CalendarDayStatus.problem => '今日失败或待确认',
      CalendarDayStatus.planned => '今日待签到',
      CalendarDayStatus.empty => '今日暂无记录',
    };
    return Column(
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Expanded(
                  child: Semantics(
                    container: true,
                    label: '本月成功次数，$count',
                    child: ExcludeSemantics(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('本月成功次数'),
                          Text(
                            '$count',
                            style: Theme.of(context).textTheme.headlineMedium
                                ?.copyWith(color: const Color(0xFF176FE4)),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                CalendarStatusIcon(status: status, size: 22),
                const SizedBox(width: 8),
                Flexible(child: Text(todayLabel)),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('最近7天', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 12),
                Row(
                  children: List.generate(7, (index) {
                    final day = DateTime(
                      today.year,
                      today.month,
                      today.day - 6 + index,
                    );
                    final dayStatus = data.statusForDay(dayKey(day));
                    return Expanded(
                      child: Semantics(
                        container: true,
                        label:
                            '${day.month}月${day.day}日，${calendarStatusLabel(dayStatus)}',
                        child: ExcludeSemantics(
                          child: Column(
                            children: [
                              Text(
                                '周${['一', '二', '三', '四', '五', '六', '日'][day.weekday - 1]}',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                              const SizedBox(height: 4),
                              Text(
                                '${day.month}/${day.day}',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                              const SizedBox(height: 8),
                              CalendarStatusIcon(status: dayStatus, size: 22),
                            ],
                          ),
                        ),
                      ),
                    );
                  }),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class SignInRecordTile extends StatelessWidget {
  const SignInRecordTile({
    required this.record,
    required this.onTap,
    super.key,
  });
  final SignInRecord record;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final successful =
        record.status == SignInRecordStatus.success ||
        record.status == SignInRecordStatus.done;
    final color = successful
        ? const Color(0xFF168660)
        : record.status == SignInRecordStatus.failed
        ? const Color(0xFFB42318)
        : const Color(0xFF9C6500);
    return Semantics(
      label: '查看记录详情，${formatDateTime(record.occurredAt)}，${record.title}',
      button: true,
      onTap: onTap,
      child: ExcludeSemantics(
        child: ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(
            successful ? Icons.check_circle_outline : Icons.info_outline,
            color: color,
          ),
          title: Text(record.title, style: TextStyle(color: color)),
          subtitle: Text(
            formatTime(TimeOfDay.fromDateTime(record.occurredAt.toLocal())),
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: onTap,
        ),
      ),
    );
  }
}
