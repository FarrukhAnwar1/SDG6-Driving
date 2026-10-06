// Summary of a Driving Family's data for each member
import 'package:flutter/foundation.dart';

// The family response contract is documented in flutter_driving_app/docs/driving_family.md
@immutable
class DrivingFamilySummary {
  const DrivingFamilySummary({
    required this.id,
    required this.adminUserId,
    required this.members,
  });

  final int id;
  final int adminUserId;
  final List<FamilyMemberSummary> members;

  FamilyMemberSummary get admin =>
      members.firstWhere((member) => member.userId == adminUserId);

  factory DrivingFamilySummary.fromJson(Map<String, dynamic> json) {
    final members = (json['members'] as List<dynamic>)
        .map(
          (item) => FamilyMemberSummary.fromJson(item as Map<String, dynamic>),
        )
        .toList();
    final adminUserId = json['adminUserId'] as int;
    if (!members.any((member) => member.userId == adminUserId) ||
        members.map((member) => member.userId).toSet().length !=
            members.length) {
      throw const FormatException('Invalid family membership.');
    }
    return DrivingFamilySummary(
      id: json['id'] as int,
      adminUserId: adminUserId,
      members: List.unmodifiable(members),
    );
  }
}

@immutable
class FamilyMemberSummary {
  const FamilyMemberSummary({
    required this.userId,
    required this.username,
    required this.driveCount,
    required this.averageGrades,
    required this.latestDrive,
    required this.totalDrivingMinutes,
    required this.totalDistanceMiles,
  });

  final int userId;
  final String username;
  final int driveCount;
  final FamilyGrades? averageGrades;
  final FamilyLatestDrive? latestDrive;
  final double totalDrivingMinutes;
  final double totalDistanceMiles;

  factory FamilyMemberSummary.fromJson(Map<String, dynamic> json) {
    final driveCount = json['driveCount'] as int;
    if (driveCount < 0) throw const FormatException('Invalid drive count.');
    return FamilyMemberSummary(
      userId: json['userId'] as int,
      username: json['username'] as String,
      driveCount: driveCount,
      // A driver without reports has no grades, rather than six zero scores
      averageGrades: driveCount == 0 || json['averageGrades'] == null
          ? null
          : FamilyGrades.fromJson(
              json['averageGrades'] as Map<String, dynamic>,
            ),
      latestDrive: driveCount == 0 || json['latestDrive'] == null
          ? null
          : FamilyLatestDrive.fromJson(
              json['latestDrive'] as Map<String, dynamic>,
            ),
      totalDrivingMinutes: _nonNegativeNumber(json['totalDrivingMinutes']),
      totalDistanceMiles: _nonNegativeNumber(json['totalDistanceMiles']),
    );
  }
}

@immutable
class FamilyGrades {
  const FamilyGrades(this.byLabel);

  final Map<String, double?> byLabel;

  static const fieldsByLabel = {
    'Overall': 'overallGrade',
    'Speed': 'speedGrade',
    'Braking': 'brakingGrade',
    'Acceleration': 'accelerationGrade',
    'Turning': 'turningGrade',
    'Focused Driving': 'focusGrade',
  };

  factory FamilyGrades.fromJson(Map<String, dynamic> json) {
    return FamilyGrades(
      Map.unmodifiable({
        for (final entry in fieldsByLabel.entries)
          entry.key: _grade(json[entry.value]),
      }),
    );
  }
}

@immutable
class FamilyLatestDrive {
  const FamilyLatestDrive({required this.reportDate, required this.grades});

  final DateTime? reportDate;
  final FamilyGrades grades;

  factory FamilyLatestDrive.fromJson(Map<String, dynamic> json) {
    final date = json['reportDate'] as String?;
    DateTime? reportDate;
    if (date != null) {
      final parsed = DateTime.parse(date);
      // Stored report timestamps without an offset are UTC, as in Analytics
      reportDate = parsed.isUtc ? parsed : DateTime.parse('${date}Z');
    }
    return FamilyLatestDrive(
      reportDate: reportDate,
      grades: FamilyGrades.fromJson(json),
    );
  }
}

double _nonNegativeNumber(dynamic value) {
  final number = (value as num).toDouble();
  if (!number.isFinite || number < 0) {
    throw const FormatException('Invalid driving total.');
  }
  return number;
}

double? _grade(dynamic value) {
  if (value == null) return null;
  final number = (value as num).toDouble();
  if (!number.isFinite || number < 0 || number > 100) {
    throw const FormatException('Invalid driving grade.');
  }
  return number;
}
