// Mirrors API fields from backend/README.md for testing purposes.
// Deliberately no startedAt/endedAt.
Map<String, dynamic> reportJson({
  int id = 12,
  String? reportDate = '2026-07-30T10:30:00',
  num durationMinutes = 30,
  num overallGrade = 87,
  List<Map<String, dynamic>> violations = const [],
}) => {
  'id': id,
  'overallGrade': overallGrade,
  'speedGrade': 87.5,
  'brakingGrade': 90,
  'accelerationGrade': 92.0,
  'turningGrade': 88,
  'focusGrade': 95.0,
  'reportDate': reportDate,
  'tripDurationMinutes': durationMinutes,
  'tripDistanceMiles': 12.4,
  'violations': violations,
};

Map<String, dynamic> violationJson({
  int id = 3,
  String type = 'Proper Speed',
  String? roadName = 'Roosevelt Blvd',
}) => {
  'id': id,
  'violationType': type,
  'roadName': roadName,
  'startTime': '2026-07-30T10:05:00',
  'endTime': '2026-07-30T10:05:18',
};
