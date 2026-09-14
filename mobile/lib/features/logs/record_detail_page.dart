import 'package:flutter/material.dart';

import '../../app_state.dart';
import '../../domain/sign_in_models.dart';
import '../../ui/scenic_page.dart';

void openRecordDetail(
  BuildContext context,
  SignInAppController controller,
  SignInRecord record,
) {
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => RecordDetailPage(controller: controller, record: record),
    ),
  );
}

class RecordDetailPage extends StatelessWidget {
  const RecordDetailPage({
    required this.controller,
    required this.record,
    super.key,
  });
  final SignInAppController controller;
  final SignInRecord record;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('记录详情')),
    body: ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        if (!controller.state.isLoggedIn ||
            controller.state.plan?.generation != record.generation) {
          return const Center(child: Text('账号已退出，请返回登录'));
        }
        final source = switch (record.source) {
          TriggerSource.manual => '手动签到',
          TriggerSource.shortcut => '快捷指令',
          TriggerSource.shortcutBackground => '快捷指令后台签到',
          TriggerSource.scheduled => '自动签到',
          TriggerSource.lateCatchUp => '延迟补签',
          TriggerSource.statusSync => '状态同步',
        };
        return SafeArea(
          top: false,
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      record.title,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 16),
                    Text('签到日期：${record.day}'),
                    const SizedBox(height: 8),
                    Text('执行时间：${formatDateTime(record.occurredAt)}'),
                    if (record.plannedAt != null) ...[
                      const SizedBox(height: 8),
                      Text('计划时间：${formatDateTime(record.plannedAt!)}'),
                    ],
                    const SizedBox(height: 8),
                    Text('触发方式：$source'),
                    const Divider(height: 32),
                    SelectableText(record.detail),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    ),
  );
}
