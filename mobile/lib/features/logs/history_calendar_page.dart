import 'dart:async';

import 'package:flutter/material.dart';

import '../../app_state.dart';
import '../../domain/sign_in_models.dart';
import '../../storage/sign_in_repository.dart';
import '../../ui/scenic_page.dart';
import 'logs_page.dart';
import 'record_detail_page.dart';
import 'record_calendar_data.dart';
import 'calendar_status_icon.dart';

class HistoryCalendarPage extends StatefulWidget {
  const HistoryCalendarPage({
    required this.controller,
    required this.generation,
    required this.initialDay,
    super.key,
  });
  final SignInAppController controller;
  final int generation;
  final DateTime initialDay;

  @override
  State<HistoryCalendarPage> createState() => _HistoryCalendarPageState();
}

class _HistoryCalendarPageState extends State<HistoryCalendarPage> {
  late final SignInRepository _repository;
  late DateTime _selected;
  late DateTime _month;
  List<SignInRecord> _records = [];
  RecordCalendarData? _data;
  bool _loading = true;
  String? _error;
  int _request = 0;

  bool get _current =>
      widget.controller.state.isLoggedIn &&
      widget.controller.state.plan?.generation == widget.generation;

  @override
  void initState() {
    super.initState();
    _selected = DateUtils.dateOnly(widget.initialDay.toLocal());
    _month = DateTime(_selected.year, _selected.month);
    _repository = widget.controller.dependencies.repository.forGeneration(
      widget.generation,
    );
    widget.controller.addListener(_accountChanged);
    unawaited(_load());
  }

  @override
  void dispose() {
    widget.controller.removeListener(_accountChanged);
    super.dispose();
  }

  void _accountChanged() {
    if (_current) return;
    _request++;
    setState(() {
      _records = [];
      _data = null;
      _loading = false;
      _error = '账号已退出，请返回登录';
    });
  }

  Future<void> _load() async {
    final request = ++_request;
    final selected = _selected;
    final month = _month;
    setState(() {
      _loading = true;
      _error = null;
      _records = [];
      _data = null;
    });
    try {
      final data = await RecordCalendarData.load(
        _repository,
        month,
        DateTime(month.year, month.month + 1, 0),
      );
      final stillActive =
          await _repository.activeGeneration() == widget.generation;
      if (!mounted || request != _request) return;
      if (!_current || !stillActive) {
        setState(() {
          _loading = false;
          _error = '账号已退出，请返回登录';
        });
        return;
      }
      setState(() {
        _records = data.recordsForDay(dayKey(selected));
        _data = data;
        _loading = false;
      });
    } catch (_) {
      if (mounted && request == _request) {
        setState(() {
          _loading = false;
          _error = _current ? '读取记录失败，请重试' : '账号已退出，请返回登录';
        });
      }
    }
  }

  void _changeMonth(int delta) {
    _month = DateTime(_month.year, _month.month + delta);
    _selected = _month;
    unawaited(_load());
  }

  @override
  Widget build(BuildContext context) {
    final offset = (_month.weekday - 1) % 7;
    final days = DateTime(_month.year, _month.month + 1, 0).day;
    return Scaffold(
      appBar: AppBar(title: const Text('历史日历')),
      body: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          IconButton(
                            tooltip: '上个月',
                            onPressed: _current ? () => _changeMonth(-1) : null,
                            icon: const Icon(Icons.chevron_left),
                          ),
                          Expanded(
                            child: Center(
                              child: Text(
                                '${_month.year}年${_month.month}月',
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: '下个月',
                            onPressed: _current ? () => _changeMonth(1) : null,
                            icon: const Icon(Icons.chevron_right),
                          ),
                        ],
                      ),
                      Row(
                        children: ['一', '二', '三', '四', '五', '六', '日']
                            .map((d) => Expanded(child: Center(child: Text(d))))
                            .toList(),
                      ),
                      const SizedBox(height: 8),
                      GridView.builder(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        gridDelegate:
                            const SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: 7,
                              mainAxisExtent: 48,
                            ),
                        itemCount: offset + days,
                        itemBuilder: (context, index) {
                          if (index < offset) return const SizedBox.shrink();
                          final day = DateTime(
                            _month.year,
                            _month.month,
                            index - offset + 1,
                          );
                          final selected = DateUtils.isSameDay(day, _selected);
                          final count =
                              _data?.recordsForDay(dayKey(day)).length ?? 0;
                          final status =
                              _data?.statusForDay(dayKey(day)) ??
                              CalendarDayStatus.empty;
                          return Semantics(
                            container: true,
                            excludeSemantics: true,
                            label:
                                '${day.month}月${day.day}日，${calendarStatusLabel(status)}，$count条记录',
                            selected: selected,
                            button: true,
                            onTap: !_current
                                ? null
                                : () {
                                    _selected = day;
                                    unawaited(_load());
                                  },
                            child: InkWell(
                              key: ValueKey(
                                'calendar-day-${day.year}-${day.month}-${day.day}',
                              ),
                              onTap: !_current
                                  ? null
                                  : () {
                                      _selected = day;
                                      unawaited(_load());
                                    },
                              borderRadius: BorderRadius.circular(12),
                              child: Container(
                                margin: const EdgeInsets.all(2),
                                decoration: BoxDecoration(
                                  color: selected
                                      ? const Color(0xFFDDEBFF)
                                      : null,
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Text(
                                      '${day.day}',
                                      style: TextStyle(
                                        color: selected
                                            ? const Color(0xFF176FE4)
                                            : null,
                                      ),
                                    ),
                                    CalendarStatusIcon(
                                      status: status,
                                      size: 14,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              if (_loading)
                const Center(child: CircularProgressIndicator())
              else if (_error != null) ...[
                Text(_error!),
                if (_current)
                  TextButton(onPressed: _load, child: const Text('重试')),
              ] else
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${_selected.month}月${_selected.day}日 · ${_records.length}条记录',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 8),
                        if (_records.isEmpty)
                          const Padding(
                            padding: EdgeInsets.all(24),
                            child: Text('当天暂无记录'),
                          ),
                        ..._records.map(
                          (record) => SignInRecordTile(
                            record: record,
                            onTap: () => openRecordDetail(
                              context,
                              widget.controller,
                              record,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
