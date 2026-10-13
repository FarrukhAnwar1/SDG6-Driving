// Sample data for testing Driving Family features
Map<String, dynamic> familyGrades({double overall = 88}) => {
  'overallGrade': overall,
  'speedGrade': 91.5,
  'brakingGrade': 82,
  'accelerationGrade': 85,
  'turningGrade': 94,
  'focusGrade': 96,
};

Map<String, dynamic> familyMemberJson({
  int userId = 1,
  String username = 'Alex',
  int driveCount = 3,
  double averageOverall = 88,
  double latestOverall = 93,
}) => {
  'userId': userId,
  'username': username,
  'driveCount': driveCount,
  'averageGrades': driveCount == 0
      ? null
      : familyGrades(overall: averageOverall),
  'latestDrive': driveCount == 0
      ? null
      : {
          'reportDate': '2026-10-05T14:30:00Z',
          ...familyGrades(overall: latestOverall),
        },
  'totalDrivingMinutes': driveCount == 0 ? 0 : 90.5,
  'totalDistanceMiles': driveCount == 0 ? 0 : 45.6,
};

Map<String, dynamic> familyResponse({
  List<Map<String, dynamic>>? members,
  int adminUserId = 1,
}) => {
  'family': {
    'id': 7,
    'adminUserId': adminUserId,
    'members':
        members ??
        [
          familyMemberJson(),
          familyMemberJson(userId: 2, username: 'Sam', driveCount: 0),
        ],
  },
};
