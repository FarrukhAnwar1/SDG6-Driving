// Each smoothness category contributes separately, even when displayed as one.
double overallDrivingGrade({
  required double properSpeedGrade,
  required double brakingGrade,
  required double acceleratingGrade,
  required double turningGrade,
  required double? focusedDrivingGrade,
  required double? followingDistanceGrade,
}) {
  final grades = [
    properSpeedGrade,
    brakingGrade,
    acceleratingGrade,
    turningGrade,
    ?focusedDrivingGrade,
    ?followingDistanceGrade,
  ];
  return grades.reduce((a, b) => a + b) / grades.length;
}
