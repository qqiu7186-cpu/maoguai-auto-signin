import 'package:flutter/material.dart';

import 'record_calendar_data.dart';

class CalendarStatusIcon extends StatelessWidget {
  const CalendarStatusIcon({required this.status, this.size = 18, super.key});
  final CalendarDayStatus status;
  final double size;

  @override
  Widget build(BuildContext context) => Icon(
    switch (status) {
      CalendarDayStatus.empty => Icons.circle_outlined,
      CalendarDayStatus.planned => Icons.schedule,
      CalendarDayStatus.success => Icons.check_circle,
      CalendarDayStatus.problem => Icons.error_outline,
    },
    color: switch (status) {
      CalendarDayStatus.empty => const Color(0xFF8795A7),
      CalendarDayStatus.planned => const Color(0xFF176FE4),
      CalendarDayStatus.success => const Color(0xFF168660),
      CalendarDayStatus.problem => const Color(0xFFB42318),
    },
    size: size,
  );
}
