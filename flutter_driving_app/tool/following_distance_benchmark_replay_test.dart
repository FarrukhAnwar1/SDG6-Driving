// Explicit artifact validation; run after collecting the phone dataset outputs.
import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_driving_app/widgets/following_distance/following_distance_grading_service.dart';
import 'package:flutter_driving_app/widgets/following_distance/road_model_output.dart';
import 'package:flutter_driving_app/widgets/following_distance/vehicle_distance_estimator.dart';

void main() {
  final root = Directory(
    Platform.environment['FD_BENCHMARK_ROOT'] ??
        'build/following_distance_benchmark',
  );
  final manifest =
      jsonDecode(File('${root.path}/dataset/manifest.json').readAsStringSync())
          as Map<String, dynamic>;
  final frames = (manifest['frames'] as List).cast<Map<String, dynamic>>();
  final predictions = {
    for (final line in File(
      '${root.path}/phone_predictions.jsonl',
    ).readAsLinesSync())
      (jsonDecode(line) as Map<String, dynamic>)['id'] as String:
          jsonDecode(line) as Map<String, dynamic>,
  };
  final summary =
      jsonDecode(File('${root.path}/accuracy_summary.json').readAsStringSync())
          as Map<String, dynamic>;
  final review =
      jsonDecode(File('${root.path}/reference_review.json').readAsStringSync())
          as Map<String, dynamic>;

  test('benchmark policy matches the current production headway threshold', () {
    expect(
      summary['gradingPolicy']['requiredHeadwaySeconds'],
      FollowingDistanceGradingService.requiredHeadwaySeconds,
    );
    for (final prediction in predictions.values) {
      expect(
        prediction['requiredHeadwaySeconds'],
        FollowingDistanceGradingService.requiredHeadwaySeconds,
      );
    }
  });

  test(
    'all recorded observations reproduce production selection and grades',
    () {
      var estimator = VehicleDistanceEstimator();
      var grading = FollowingDistanceGradingService();
      String? sequence;
      for (final row in frames) {
        if (sequence != row['sequence']) {
          sequence = row['sequence'] as String;
          estimator = VehicleDistanceEstimator();
          grading = FollowingDistanceGradingService();
        }
        final prediction = predictions[row['id']]!;
        final timestamp = DateTime.fromMicrosecondsSinceEpoch(
          (row['timestampUs'] as num).toInt(),
          isUtc: true,
        );
        final observation = RoadObservation(
          timestamp: timestamp,
          roadVisible: prediction['roadVisible'] as bool,
          vehicles: [
            for (final raw in prediction['vehicles'] as List)
              RoadVehicleObservation(
                detection: VehicleDetection(
                  label: 'vehicle',
                  confidence: (raw['confidence'] as num).toDouble(),
                  normalizedBox: Rect.fromLTRB(
                    (raw['box'][0] as num).toDouble(),
                    (raw['box'][1] as num).toDouble(),
                    (raw['box'][2] as num).toDouble(),
                    (raw['box'][3] as num).toDouble(),
                  ),
                ),
                inEgoLane: raw['inEgoLane'] as bool,
                distanceMeters: (raw['distanceMeters'] as num?)?.toDouble(),
              ),
          ],
        );
        final measurement = estimator.estimate(observation);
        expect(
          measurement.status.name,
          prediction['status'],
          reason: row['id'] as String,
        );
        expect(measurement.distanceMeters, prediction['distanceMeters']);
        grading.addSample(
          speedMph: (row['speedMph'] as num).toDouble(),
          distanceMeters: measurement.distanceMeters,
          timestamp: timestamp,
          latitude: (row['latitude'] as num).toDouble(),
          longitude: (row['longitude'] as num).toDouble(),
          leadVehicleId: measurement.leadVehicleId,
        );
        expect(
          grading.grade,
          closeTo((prediction['grade'] as num).toDouble(), 1e-8),
        );
        expect(grading.isPenalizing, prediction['isPenalizing']);
      }
      expect(predictions.length, frames.length);
    },
  );

  test(
    'reference distances reproduce reported grades in the production grader',
    () {
      var grader = FollowingDistanceGradingService();
      String? sequence;
      final finalGrades = <String, double>{};
      var confirmedViolations = 0;
      for (final row in frames) {
        if (sequence != row['sequence']) {
          grader.finalizeTrip();
          confirmedViolations += grader.violations.length;
          sequence = row['sequence'] as String;
          grader = FollowingDistanceGradingService();
        }
        Map<String, dynamic>? selected;
        for (final range in review['ranges'][sequence] as List) {
          if ((range['firstFrame'] as num) <= (row['frame'] as num) &&
              (range['lastFrame'] as num) >= (row['frame'] as num)) {
            for (final object in row['objects'] as List) {
              if (object['trackId'] == range['trackId']) {
                selected = object as Map<String, dynamic>;
              }
            }
          }
        }
        grader.addSample(
          speedMph: (row['speedMph'] as num).toDouble(),
          distanceMeters: (selected?['distanceMeters'] as num?)?.toDouble(),
          timestamp: DateTime.fromMicrosecondsSinceEpoch(
            (row['timestampUs'] as num).toInt(),
            isUtc: true,
          ),
          latitude: (row['latitude'] as num).toDouble(),
          longitude: (row['longitude'] as num).toDouble(),
          leadVehicleId: selected?['trackId'] as String?,
        );
        finalGrades[sequence!] = grader.grade;
      }
      grader.finalizeTrip();
      confirmedViolations += grader.violations.length;
      for (final entry in finalGrades.entries) {
        final expected =
            (summary['finalGrades'][entry.key]['referenceGrade'] as num)
                .toDouble();
        expect(entry.value, closeTo(expected, 1e-5));
      }
      expect(confirmedViolations, summary['referenceConfirmedViolations'] ?? 1);
    },
  );
}
