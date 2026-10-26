// Supplies observed road scenes for perception and trip-grading regression tests.

import 'dart:ui';

import 'package:flutter_driving_app/widgets/following_distance/road_model_output.dart';
import 'package:flutter_driving_app/widgets/following_distance/vehicle_distance_estimator.dart';

RoadVehicleObservation roadVehicle({
  double? distance = 26.8224,
  double confidence = 0.9,
  bool inEgoLane = true,
  Rect box = const Rect.fromLTRB(0.4, 0.35, 0.6, 0.65),
}) => RoadVehicleObservation(
  detection: VehicleDetection(
    label: 'vehicle',
    confidence: confidence,
    normalizedBox: box,
  ),
  distanceMeters: distance,
  inEgoLane: inEgoLane,
);

RoadObservation roadScene(
  DateTime timestamp, {
  List<RoadVehicleObservation>? vehicles,
  bool roadVisible = true,
}) => RoadObservation(
  timestamp: timestamp,
  vehicles: vehicles ?? [roadVehicle()],
  roadVisible: roadVisible,
);
