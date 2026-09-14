import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const _primaryBlue = Color(0xFF176FE4);

class ScenicScrollPage extends StatelessWidget {
  const ScenicScrollPage({
    required this.child,
    this.headerHeight = 252,
    this.showArtwork = true,
    this.padding = const EdgeInsets.fromLTRB(16, 12, 16, 24),
    super.key,
  });

  final Widget child;
  final double headerHeight;
  final bool showArtwork;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final topInset = MediaQuery.paddingOf(context).top;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.dark.copyWith(
        statusBarColor: Colors.transparent,
        statusBarBrightness: Brightness.light,
      ),
      child: Stack(
        children: [
          const Positioned.fill(child: ColoredBox(color: Color(0xFFF3F9FF))),
          Positioned(
            key: const ValueKey('scenic-status-surface'),
            top: 0,
            left: 0,
            right: 0,
            height: headerHeight + topInset,
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: showArtwork ? null : const Color(0xFFF3F9FF),
                  gradient: showArtwork
                      ? const LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [Color(0xFFE2F3FF), Color(0xFFF7FBFF)],
                        )
                      : null,
                ),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (showArtwork)
                      Positioned(
                        top: 0,
                        left: 0,
                        right: 0,
                        child: Opacity(
                          opacity: 0.88,
                          child: Image.asset(
                            'assets/images/morning_landscape_v1.png',
                            key: const ValueKey('scenic-header'),
                            fit: BoxFit.fitWidth,
                            alignment: Alignment.topCenter,
                          ),
                        ),
                      ),
                    if (showArtwork)
                      const Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        height: 104,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [Color(0x00F3F9FF), Color(0xFFF3F9FF)],
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          Positioned.fill(
            child: SafeArea(
              bottom: false,
              child: SingleChildScrollView(padding: padding, child: child),
            ),
          ),
        ],
      ),
    );
  }
}

class ScenicPageHeader extends StatelessWidget {
  const ScenicPageHeader({
    required this.title,
    this.eyebrow,
    this.subtitle,
    super.key,
  });

  final String title;
  final String? eyebrow;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (eyebrow case final String label) ...[
          Text(
            label,
            style: textTheme.titleLarge?.copyWith(
              color: const Color(0xFF102B63),
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 8),
        ],
        Text(
          title,
          style: textTheme.headlineMedium?.copyWith(
            color: const Color(0xFF0B285E),
            fontWeight: FontWeight.w900,
            letterSpacing: 0.5,
          ),
        ),
        if (subtitle case final String description) ...[
          const SizedBox(height: 6),
          Text(
            description,
            style: textTheme.titleMedium?.copyWith(
              color: const Color(0xFF496486),
              height: 1.35,
            ),
          ),
        ],
      ],
    );
  }
}

class SoftIconCircle extends StatelessWidget {
  const SoftIconCircle({
    required this.icon,
    this.color = _primaryBlue,
    this.size = 54,
    super.key,
  });

  final IconData icon;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        shape: BoxShape.circle,
      ),
      child: Icon(icon, color: color, size: size * 0.52),
    );
  }
}

class SevenDayStrip extends StatelessWidget {
  const SevenDayStrip({required this.isTodayComplete, super.key});

  final bool isTodayComplete;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final days = List<DateTime>.generate(
      7,
      (index) => now.subtract(Duration(days: 3 - index)),
    );
    const weekLabels = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];

    return Row(
      children: days.map((day) {
        final isToday = DateUtils.isSameDay(day, now);
        final complete = isToday && isTodayComplete;
        return Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 1),
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 2),
              decoration: BoxDecoration(
                color: isToday ? const Color(0xFFE7F2FF) : Colors.transparent,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    height: 16,
                    width: double.infinity,
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        weekLabels[day.weekday - 1],
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: isToday
                              ? _primaryBlue
                              : const Color(0xFF64728A),
                          fontWeight: isToday
                              ? FontWeight.w800
                              : FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  SizedBox(
                    height: 16,
                    width: double.infinity,
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        '${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')}',
                        style: Theme.of(context).textTheme.labelSmall
                            ?.copyWith(color: const Color(0xFF66738A)),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: complete ? _primaryBlue : Colors.transparent,
                      shape: BoxShape.circle,
                      border: complete
                          ? null
                          : Border.all(
                              color: isToday
                                  ? _primaryBlue
                                  : const Color(0xFFB4C0D2),
                              width: 2,
                            ),
                    ),
                    child: complete
                        ? const Icon(
                            Icons.check_rounded,
                            color: Colors.white,
                            size: 20,
                          )
                        : null,
                  ),
                ],
              ),
            ),
          ),
        );
      }).toList(),
    );
  }
}

String formatTime(TimeOfDay value) {
  final hour = value.hour.toString().padLeft(2, '0');
  final minute = value.minute.toString().padLeft(2, '0');
  return '$hour:$minute';
}

String formatMinute(int minute) =>
    formatTime(TimeOfDay(hour: minute ~/ 60, minute: minute % 60));

String dayKey(DateTime value) {
  final date = value.toLocal();
  return '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
}

String formatDateTime(DateTime value) {
  final local = value.toLocal();
  return '${local.month}月${local.day}日 ${formatTime(TimeOfDay.fromDateTime(local))}';
}
