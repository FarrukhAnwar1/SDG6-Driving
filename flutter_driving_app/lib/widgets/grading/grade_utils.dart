// Shared presentation helpers for driving/letter grade colors (0-100)
import 'package:flutter/material.dart';

String letterGradeFor(double grade) {
  return switch (grade) {
    >= 90 => 'A',
    >= 80 => 'B',
    >= 70 => 'C',
    >= 60 => 'D',
    _ => 'F',
  };
}

Color gradeColorFor(double grade) {
  if (grade >= 90) return const Color.fromARGB(255, 104, 209, 72);
  if (grade >= 80) return const Color.fromARGB(255, 127, 190, 68);
  if (grade >= 70) return const Color.fromARGB(255, 249, 230, 57);
  if (grade >= 60) return Colors.orange;
  return Colors.red;
}

// One fixed color per metric, shared by the history chart's lines, its
// grade dropdown, violation titles, and comparison rows, so the
// same metric reads as the same color everywhere it shows up on the
// Analytics screen. Order here also controls display order.
const Map<String, Color> metricColors = {
  'Overall': Colors.indigo,
  'Speed': Colors.blue,
  'Braking': Colors.deepOrange,
  'Acceleration': Colors.teal,
  'Turning': Colors.purple,
  'Focused Driving': Colors.green,
};
