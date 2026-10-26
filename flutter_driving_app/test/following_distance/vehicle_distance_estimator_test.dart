// Tests metric lead selection, identity continuity and uncertain observations.

import 'dart:ui';

import 'package:flutter_driving_app/widgets/following_distance/vehicle_distance_estimator.dart';
import 'package:flutter_test/flutter_test.dart';

import '../fixtures/road_vision_fixtures.dart';

void main() {
  final start = DateTime.utc(2026, 10, 23);
  late VehicleDistanceEstimator estimator;
  setUp(() => estimator = VehicleDistanceEstimator());

  test(
    'learned depth supplies distance independent of assumed vehicle width',
    () {
      expect(
        estimator.estimate(roadScene(start)).status,
        FollowingDistanceStatus.tracking,
      );
      final observation = estimator.estimate(
        roadScene(start.add(const Duration(seconds: 1))),
      );
      expect(observation.status, FollowingDistanceStatus.tracking);
      expect(observation.distanceMeters, 26.8224);
      final smallerBox = estimator.estimate(
        roadScene(
          start.add(const Duration(seconds: 2)),
          vehicles: [
            roadVehicle(box: const Rect.fromLTRB(0.44, 0.4, 0.56, 0.6)),
          ],
        ),
      );
      expect(smallerBox.distanceMeters, 26.8224);
      expect(smallerBox.leadVehicleId, observation.leadVehicleId);
    },
  );

  test(
    'a moderate-confidence first sighting supplies the current distance',
    () {
      final result = estimator.estimate(
        roadScene(start, vehicles: [roadVehicle(confidence: 0.25)]),
      );
      expect(result.status, FollowingDistanceStatus.tracking);
      expect(result.distanceMeters, 26.8224);
      expect(result.leadVehicleId, isNotNull);
    },
  );

  test('weak detections need a matching observed lead', () {
    expect(
      estimator
          .estimate(roadScene(start, vehicles: [roadVehicle(confidence: 0.2)]))
          .distanceMeters,
      isNull,
    );
    final initial = estimator.estimate(
      roadScene(start.add(const Duration(seconds: 1))),
    );
    final result = estimator.estimate(
      roadScene(
        start.add(const Duration(seconds: 2)),
        vehicles: [
          roadVehicle(
            confidence: 0.2,
            distance: 10,
            box: const Rect.fromLTRB(0.35, 0.64, 0.65, 0.9),
          ),
        ],
      ),
    );
    expect(result.status, FollowingDistanceStatus.confirming);
    expect(result.distanceMeters, isNull);
    final returned = estimator.estimate(
      roadScene(start.add(const Duration(seconds: 3))),
    );
    expect(returned.leadVehicleId, initial.leadVehicleId);
  });

  test('low-confidence matching retains the observed lead', () {
    estimator.estimate(roadScene(start));
    final confirmed = estimator.estimate(
      roadScene(start.add(const Duration(seconds: 1))),
    );
    final weak = estimator.estimate(
      roadScene(
        start.add(const Duration(seconds: 2)),
        vehicles: [roadVehicle(confidence: 0.1)],
      ),
    );
    expect(weak.status, FollowingDistanceStatus.tracking);
    expect(weak.leadVehicleId, confirmed.leadVehicleId);
  });

  test('box movement at slow processing cadence preserves lead identity', () {
    final initial = estimator.estimate(roadScene(start));
    final moved = estimator.estimate(
      roadScene(
        start.add(const Duration(seconds: 3)),
        vehicles: [
          roadVehicle(
            confidence: 0.15,
            box: const Rect.fromLTRB(0.53, 0.38, 0.73, 0.68),
          ),
        ],
      ),
    );
    expect(moved.status, FollowingDistanceStatus.tracking);
    expect(moved.leadVehicleId, initial.leadVehicleId);
    expect(moved.distanceMeters, 26.8224);
  });

  test('a short miss preserves identity without inventing a distance', () {
    estimator.estimate(roadScene(start));
    final confirmed = estimator.estimate(
      roadScene(start.add(const Duration(seconds: 1))),
    );
    final missed = estimator.estimate(
      roadScene(start.add(const Duration(seconds: 2)), vehicles: []),
    );
    expect(missed.status, FollowingDistanceStatus.confirming);
    expect(missed.distanceMeters, isNull);
    final recovered = estimator.estimate(
      roadScene(start.add(const Duration(seconds: 3))),
    );
    expect(recovered.leadVehicleId, confirmed.leadVehicleId);
    expect(recovered.distanceMeters, 26.8224);
  });

  test('adjacent lane traffic cannot replace the lead', () {
    final vehicles = [
      roadVehicle(distance: 40),
      roadVehicle(
        distance: 8,
        inEgoLane: false,
        box: const Rect.fromLTRB(0.7, 0.4, 0.9, 0.8),
      ),
    ];
    estimator.estimate(roadScene(start, vehicles: vehicles));
    final result = estimator.estimate(
      roadScene(start.add(const Duration(seconds: 1)), vehicles: vehicles),
    );
    expect(result.distanceMeters, 40);
  });

  test('adjacent traffic alone does not leave the UI confirming a lead', () {
    final vehicles = [
      roadVehicle(
        inEgoLane: false,
        box: const Rect.fromLTRB(0.7, 0.4, 0.9, 0.8),
      ),
    ];
    estimator.estimate(roadScene(start, vehicles: vehicles));
    final result = estimator.estimate(
      roadScene(start.add(const Duration(seconds: 1)), vehicles: vehicles),
    );
    expect(result.status, FollowingDistanceStatus.noVehicle);
    expect(result.distanceMeters, isNull);
  });

  test('a nearer cut-in immediately supplies distance with a new identity', () {
    final initial = estimator.estimate(roadScene(start));
    estimator.estimate(roadScene(start.add(const Duration(seconds: 1))));
    final result = estimator.estimate(
      roadScene(
        start.add(const Duration(seconds: 2)),
        vehicles: [
          roadVehicle(),
          roadVehicle(
            distance: 10,
            box: const Rect.fromLTRB(0.35, 0.64, 0.65, 0.9),
          ),
        ],
      ),
    );
    expect(result.status, FollowingDistanceStatus.tracking);
    expect(result.distanceMeters, 10);
    expect(result.leadVehicleId, isNot(initial.leadVehicleId));
  });

  test(
    'uncertain closer vehicle never substitutes the distance of a farther one',
    () {
      final result = estimator.estimate(
        roadScene(
          start,
          vehicles: [
            roadVehicle(distance: 40),
            roadVehicle(
              distance: null,
              box: const Rect.fromLTRB(0.35, 0.64, 0.65, 0.9),
            ),
          ],
        ),
      );
      expect(result.status, FollowingDistanceStatus.unreliable);
      expect(result.distanceMeters, isNull);
    },
  );

  test('no road, invalid depth and abrupt depth jumps cannot grade', () {
    estimator.estimate(roadScene(start));
    estimator.estimate(roadScene(start.add(const Duration(seconds: 1))));
    expect(
      estimator
          .estimate(
            roadScene(
              start.add(const Duration(seconds: 2)),
              vehicles: [roadVehicle(distance: 2)],
            ),
          )
          .status,
      FollowingDistanceStatus.unreliable,
    );
    expect(
      estimator
          .estimate(
            roadScene(
              start.add(const Duration(seconds: 3)),
              roadVisible: false,
            ),
          )
          .distanceMeters,
      isNull,
    );
    expect(
      estimator
          .estimate(
            roadScene(
              start.add(const Duration(seconds: 4)),
              vehicles: [roadVehicle(distance: double.nan)],
            ),
          )
          .status,
      FollowingDistanceStatus.unreliable,
    );
  });

  test('expiry and reset give immediate measurements new identities', () {
    estimator.estimate(roadScene(start));
    final initial = estimator.estimate(
      roadScene(start.add(const Duration(seconds: 1))),
    );
    expect(
      estimator
          .estimate(roadScene(start.add(const Duration(seconds: 8))))
          .status,
      FollowingDistanceStatus.tracking,
    );
    final later = estimator.estimate(
      roadScene(start.add(const Duration(seconds: 9))),
    );
    expect(later.leadVehicleId, isNot(initial.leadVehicleId));
    estimator.reset();
    estimator.estimate(roadScene(start.add(const Duration(seconds: 10))));
    final reset = estimator.estimate(
      roadScene(start.add(const Duration(seconds: 11))),
    );
    expect(reset.leadVehicleId, isNot(later.leadVehicleId));
  });

  test('an off-lane lead is forgotten rather than kept confirming', () {
    final initial = estimator.estimate(roadScene(start));
    final offLane = estimator.estimate(
      roadScene(
        start.add(const Duration(seconds: 1)),
        vehicles: [roadVehicle(inEgoLane: false)],
      ),
    );
    expect(offLane.status, FollowingDistanceStatus.noVehicle);
    final returned = estimator.estimate(
      roadScene(start.add(const Duration(seconds: 2))),
    );
    expect(returned.leadVehicleId, isNot(initial.leadVehicleId));
  });

  test('separate estimators never reuse lead identities', () {
    final first = estimator.estimate(roadScene(start));
    final second = VehicleDistanceEstimator().estimate(roadScene(start));
    expect(second.leadVehicleId, isNot(first.leadVehicleId));
  });

  test('nonfinite confidence and malformed boxes cannot supply a distance', () {
    for (final vehicle in [
      roadVehicle(confidence: double.nan),
      roadVehicle(confidence: 1.1),
      roadVehicle(confidence: 0.09),
      roadVehicle(box: const Rect.fromLTRB(0.6, 0.3, 0.4, 0.6)),
      roadVehicle(box: const Rect.fromLTRB(double.nan, 0.3, 0.6, 0.6)),
    ]) {
      estimator.reset();
      expect(
        estimator
            .estimate(roadScene(start, vehicles: [vehicle]))
            .distanceMeters,
        isNull,
      );
    }
  });

  test('out-of-order observations cannot change a confirmed lead', () {
    estimator.estimate(roadScene(start));
    final initial = estimator.estimate(
      roadScene(start.add(const Duration(seconds: 1))),
    );
    expect(
      estimator.estimate(roadScene(start)).status,
      FollowingDistanceStatus.unreliable,
    );
    expect(
      estimator
          .estimate(roadScene(start.add(const Duration(seconds: 2))))
          .leadVehicleId,
      initial.leadVehicleId,
    );
  });
}
