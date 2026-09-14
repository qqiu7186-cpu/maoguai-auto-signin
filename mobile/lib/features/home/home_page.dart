import 'package:flutter/material.dart';

import '../../app_state.dart';
import '../../domain/sign_in_models.dart';
import '../../ui/scenic_page.dart';

class HomePage extends StatelessWidget {
  const HomePage({
    required this.state,
    required this.onAutoSignChanged,
    required this.onSignIn,
    required this.onConfirm,
    super.key,
  });

  final SignInAppViewState state;
  final ValueChanged<bool> onAutoSignChanged;
  final VoidCallback onSignIn;
  final VoidCallback onConfirm;

  @override
  Widget build(BuildContext context) {
    final plan = state.plan;
    final status = switch (state.planStatus) {
      DailyPlanStatus.planned => '今日待签到',
      DailyPlanStatus.checking => '正在检查签到状态',
      DailyPlanStatus.jittering => '准备签到',
      DailyPlanStatus.submitting => '正在提交签到',
      DailyPlanStatus.confirming => '正在确认签到结果',
      DailyPlanStatus.success || DailyPlanStatus.done => '今日已签到',
      DailyPlanStatus.failed => '签到失败',
      DailyPlanStatus.unknown => '签到结果待确认',
    };
    return ScenicScrollPage(
      headerHeight: 220,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ScenicPageHeader(eyebrow: '签到助手', title: state.greeting),
          const SizedBox(height: 20),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(status, style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 18),
                  const Text('今日随机时间'),
                  Text(
                    plan == null
                        ? '—'
                        : formatTime(
                            TimeOfDay.fromDateTime(plan.plannedAt.toLocal()),
                          ),
                    style: Theme.of(context).textTheme.headlineLarge?.copyWith(
                      color: Theme.of(context).colorScheme.primary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '签到时段 ${formatMinute(state.settings.startMinute)}–${formatMinute(state.settings.endMinute)}',
                  ),
                  if (plan?.lateExecution ?? false) ...[
                    const SizedBox(height: 8),
                    const Text('本次为延迟补签'),
                  ],
                  const SizedBox(height: 18),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: state.isRunning ? null : onSignIn,
                      icon: state.isRunning
                          ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.check_rounded),
                      label: Text(state.isRunning ? '签到中…' : '立即签到'),
                      style: FilledButton.styleFrom(
                        minimumSize: const Size(0, 48),
                      ),
                    ),
                  ),
                  if (state.planStatus == DailyPlanStatus.unknown)
                    Center(
                      child: TextButton(
                        onPressed: state.isRunning ? null : onConfirm,
                        child: const Text('确认签到结果'),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: SwitchListTile.adaptive(
              title: const Text('自动签到'),
              subtitle: Text(
                !state.settings.enabled
                    ? '已暂停'
                    : state.nextPlan == null
                    ? '等待生成计划'
                    : '下次 ${formatDateTime(state.nextPlan!.plannedAt)}',
              ),
              value: state.settings.enabled,
              onChanged: state.isRunning ? null : onAutoSignChanged,
            ),
          ),
          if (state.errorMessage case final String message) ...[
            const SizedBox(height: 12),
            Text(message),
          ],
        ],
      ),
    );
  }
}
