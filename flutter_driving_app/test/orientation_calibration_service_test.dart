// Unit tests for the OrientationCalibrationService
//
// The service turns raw phone sensors into vehicle-frame forward/lateral G, so
// these tests drive a simulated vehicle rather than checking internals. A mount
// describes how the phone is fixed in the car, and the simulator synthesizes the
// three sensor streams and the GPS fixes that mount would produce for a
// commanded driving maneuver. Every expectation is therefore about the numbers
// the smoothness grader consumes: is forwardG/lateralG the acceleration the car
// actually experienced, in any mounting, after a remount, and how quickly does
// the forward axis become available at all.
// Note: if any constants in OrientationCalibrationService are changed, these
// tests may need to be updated accordingly.
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:flutter_driving_app/widgets/orientation_calibration_service.dart';

const double _g = 9.80665;

// How the phone is fixed in the vehicle, expressed as the DEVICE-frame
// components of the vehicle's forward, left and up directions. That is exactly
// what the service has to recover, and writing mounts this way means a test
// reads as "the top of the phone points up and its back points forward".
class _Mount {
  const _Mount({required this.forward, required this.left, required this.up});

  final List<double> forward;
  final List<double> left;
  final List<double> up;

  // Phone flat on the dash, top of the phone pointing forward.
  static const flatOnDash = _Mount(
    forward: [0, 1, 0],
    left: [-1, 0, 0],
    up: [0, 0, 1],
  );

  // Portrait in a windshield mount: top of the phone up, screen facing back.
  static const portrait = _Mount(
    forward: [0, 0, -1],
    left: [-1, 0, 0],
    up: [0, 1, 0],
  );

  // Landscape in the same windshield mount.
  static const landscape = _Mount(
    forward: [0, 0, -1],
    left: [0, 1, 0],
    up: [1, 0, 0],
  );

  // Portrait, but hanging upside down.
  static const upsideDownPortrait = _Mount(
    forward: [0, 0, -1],
    left: [1, 0, 0],
    up: [0, -1, 0],
  );

  // Same UP as [portrait], but the phone has been yawed 90 degrees, so its
  // forward direction is somewhere completely different in device coordinates.
  static const portraitYawed = _Mount(
    forward: [-1, 0, 0],
    left: [0, 0, 1],
    up: [0, 1, 0],
  );

  List<double> toDevice(List<double> vehicleVector) => [
    for (var component = 0; component < 3; component++)
      vehicleVector[0] * forward[component] +
          vehicleVector[1] * left[component] +
          vehicleVector[2] * up[component],
  ];
}

// Generates the sensor and GPS streams a real drive would produce for the given
// mount. Sensors run at the app's game interval (~50 Hz) and GPS at 1 Hz, which
// is what the service sees on a trip.
class _DriveSimulator {
  _DriveSimulator({
    required this.service,
    required this.mount,
    this.gyroBiasDevice = const [0.0, 0.0, 0.0],
    this.linearSampleLag = Duration.zero,
  });

  static const Duration sensorStep = Duration(milliseconds: 20);
  static const Duration gpsStep = Duration(milliseconds: 1000);
  static final DateTime _tripStart = DateTime(2026, 1, 1, 12, 0, 0);

  final OrientationCalibrationService service;

  // Mutable so a test can physically remount the phone mid-drive.
  _Mount mount;

  // Constant gyroscope bias in device coordinates, the sensor imperfection that
  // makes an unaided tilt estimate drift.
  final List<double> gyroBiasDevice;

  // Skew between the raw and gravity-removed streams. Large values model a
  // device where the two cannot be paired to isolate gravity.
  final Duration linearSampleLag;

  DateTime _time = _tripStart;
  double speedMps = 0;
  double headingDegrees = 0;
  Duration _sinceGpsFix = Duration.zero;

  Duration get elapsed => _time.difference(_tripStart);

  void drive({
    required Duration duration,
    double forwardAccelMps2 = 0,
    double lateralRightAccelMps2 = 0,
    double yawRateRightRadPerSec = 0,
    double verticalAccelMps2 = 0,
  }) {
    var remaining = duration;
    while (remaining > Duration.zero) {
      _time = _time.add(sensorStep);
      final dtSeconds = sensorStep.inMicroseconds / 1e6;

      // Vehicle frame: x forward, y left, z up. Acceleration toward the right
      // is negative y.
      final vehicleAccel = [
        forwardAccelMps2,
        -lateralRightAccelMps2,
        verticalAccelMps2,
      ];
      // An accelerometer measures specific force, so at rest it reports g
      // pointing up rather than zero.
      final specificForce = [
        vehicleAccel[0],
        vehicleAccel[1],
        vehicleAccel[2] + _g,
      ];
      // Turning right is a negative rotation about up by the right-hand rule
      // the gyroscope follows.
      final vehicleAngularRate = [0.0, 0.0, -yawRateRightRadPerSec];

      final linear = mount.toDevice(vehicleAccel);
      final raw = mount.toDevice(specificForce);
      final angularRate = mount.toDevice(vehicleAngularRate);

      service.addUserAccelerometerSample(
        UserAccelerometerEvent(
          linear[0],
          linear[1],
          linear[2],
          _time.subtract(linearSampleLag),
        ),
      );
      service.addAccelerometerSample(
        AccelerometerEvent(raw[0], raw[1], raw[2], _time),
      );
      service.addGyroscopeSample(
        GyroscopeEvent(
          angularRate[0] + gyroBiasDevice[0],
          angularRate[1] + gyroBiasDevice[1],
          angularRate[2] + gyroBiasDevice[2],
          _time,
        ),
      );

      speedMps = math.max(0.0, speedMps + forwardAccelMps2 * dtSeconds);
      headingDegrees =
          (headingDegrees +
              yawRateRightRadPerSec * dtSeconds * 180 / math.pi +
              360) %
          360;

      _sinceGpsFix += sensorStep;
      if (_sinceGpsFix >= gpsStep) {
        _sinceGpsFix = Duration.zero;
        service.addGpsSample(
          speedMps: speedMps,
          headingDegrees: headingDegrees,
          timestamp: _time,
          headingAccuracyDegrees: 5,
        );
      }

      remaining -= sensorStep;
    }
  }

  // Drives in short slices until the forward axis is published, returning how
  // long that took, or null if it never calibrated.
  Duration? driveUntilCalibrated({
    required Duration limit,
    required double forwardAccelMps2,
  }) {
    while (elapsed < limit) {
      drive(duration: sensorStep, forwardAccelMps2: forwardAccelMps2);
      if (service.isForwardCalibrated) return elapsed;
    }
    return null;
  }
}

// A steady 1.5 m/s^2 launch: a deliberate but unremarkable acceleration.
const double _normalLaunchAccelMps2 = 1.5;

void main() {
  group('OrientationCalibrationService', () {
    // Any mounting has to produce the same vehicle-frame answers, since the
    // service is supposed to learn the mount rather than assume one.
    final mounts = <String, _Mount>{
      'flat on the dash': _Mount.flatOnDash,
      'portrait': _Mount.portrait,
      'landscape': _Mount.landscape,
      'upside-down portrait': _Mount.upsideDownPortrait,
    };

    mounts.forEach((description, mount) {
      test('reports true forward and lateral G mounted $description', () {
        final service = OrientationCalibrationService();
        final simulator = _DriveSimulator(service: service, mount: mount);

        simulator.drive(
          duration: const Duration(seconds: 8),
          forwardAccelMps2: _normalLaunchAccelMps2,
        );

        expect(service.isForwardCalibrated, isTrue);
        expect(
          service.forwardG,
          closeTo(_normalLaunchAccelMps2 / _g, 0.005),
          reason: 'accelerating forward should read positive and true-sized',
        );
        expect(service.lateralG, closeTo(0, 0.005));

        // Braking has to flip the sign, not just the magnitude.
        simulator.drive(
          duration: const Duration(seconds: 3),
          forwardAccelMps2: -2.5,
        );
        expect(service.forwardG, closeTo(-2.5 / _g, 0.01));

        // A steady right-hand turn at constant speed: lateral only, and
        // positive because positive lateral G means turning right.
        final turnRateRadPerSec = 0.25;
        simulator.drive(
          duration: const Duration(seconds: 3),
          yawRateRightRadPerSec: turnRateRadPerSec,
          lateralRightAccelMps2: simulator.speedMps * turnRateRadPerSec,
        );
        expect(
          service.lateralG,
          closeTo(simulator.speedMps * turnRateRadPerSec / _g, 0.02),
        );
        expect(service.forwardG, closeTo(0, 0.02));
      });
    });

    test('an unambiguous launch calibrates on its first eligible GPS interval', () {
      final service = OrientationCalibrationService();
      final simulator = _DriveSimulator(
        service: service,
        mount: _Mount.portrait,
      );

      final calibratedAt = simulator.driveUntilCalibrated(
        limit: const Duration(seconds: 20),
        forwardAccelMps2: _normalLaunchAccelMps2,
      );

      // Signed calibration is held back until the interval's average speed
      // clears 12 mph, because GPS speed cannot tell forward from reverse. At
      // 1.5 m/s^2 that is the interval ending 5 seconds in, and this launch is
      // clean enough on every gate to be trusted by itself, so the axis is
      // published there instead of waiting for a second interval to agree.
      expect(calibratedAt, isNotNull);
      expect(calibratedAt!.inMilliseconds, greaterThan(4000));
      expect(calibratedAt.inMilliseconds, lessThanOrEqualTo(5100));
    });

    test('a gentle launch still waits for a second agreeing interval', () {
      final service = OrientationCalibrationService();
      final simulator = _DriveSimulator(
        service: service,
        mount: _Mount.portrait,
      );

      // 0.8 m/s^2 clears the gates but not by much, so one interval is only
      // partial evidence: a lagging or noisy GPS speed trend at this size could
      // still be mislabeled, and getting the polarity wrong mirrors the whole
      // vehicle basis.
      final calibratedAt = simulator.driveUntilCalibrated(
        limit: const Duration(seconds: 30),
        forwardAccelMps2: 0.8,
      );

      expect(calibratedAt, isNotNull);
      // First eligible interval ends at 8s; the confirming one at 9s.
      expect(calibratedAt!.inMilliseconds, greaterThan(8100));
      expect(calibratedAt.inMilliseconds, lessThanOrEqualTo(9100));
    });

    test('a trip that starts mid-acceleration still gets the horizontal plane '
        'right', () {
      final service = OrientationCalibrationService();
      final simulator = _DriveSimulator(
        service: service,
        mount: _Mount.flatOnDash,
      );

      // The driver is already accelerating hard when tracking starts, so the
      // very first accelerometer reading is gravity plus 3 m/s^2 and points
      // about 17 degrees away from true up. Taking the platform's
      // gravity-removed acceleration out of that reading recovers gravity by
      // itself, so the horizontal plane is right immediately instead of being
      // anchored to a tilted "up" that a motion-gated correction then has to
      // spend a long time walking back.
      const launchAccelMps2 = 3.0;
      simulator.drive(
        duration: const Duration(seconds: 8),
        forwardAccelMps2: launchAccelMps2,
      );

      expect(service.isForwardCalibrated, isTrue);
      expect(service.forwardG, closeTo(launchAccelMps2 / _g, 0.005));

      // Vertical road input only reaches the horizontal axes through a tilted
      // plane, which makes it a direct read-out of the tilt error: at 17 degrees
      // off, this bump alone would register as ~0.07 G of phantom braking and be
      // scored as harsh driving.
      simulator.drive(duration: const Duration(seconds: 2));
      simulator.drive(
        duration: const Duration(seconds: 1),
        verticalAccelMps2: 2.5,
      );
      expect(
        service.forwardG.abs(),
        lessThan(0.005),
        reason: 'a bump must not be reported as braking',
      );
      expect(service.lateralG.abs(), lessThan(0.005));
    });

    test('gyroscope bias does not accumulate into forward G', () {
      final service = OrientationCalibrationService();
      // Bias about the vehicle's left axis is the damaging one: it tilts the
      // estimated horizontal plane in the same plane the forward axis lives in.
      // The accelerometer is the only thing that can correct it, since the
      // GPS-heading correction only covers the yaw component.
      final simulator = _DriveSimulator(
        service: service,
        mount: _Mount.flatOnDash,
        gyroBiasDevice: const [-0.02, 0.0, 0.0],
      );

      simulator.drive(
        duration: const Duration(seconds: 20),
        forwardAccelMps2: _normalLaunchAccelMps2,
      );

      expect(service.isForwardCalibrated, isTrue);
      // Left uncorrected, 20 seconds of 0.02 rad/s bias would be a 23 degree
      // tilt and an 8% error here.
      expect(
        service.forwardG,
        closeTo(_normalLaunchAccelMps2 / _g, 0.005),
        reason: 'tilt drift must not leak into forward G',
      );
    });

    test('a pure roll remount is corrected without waiting for GPS', () {
      final service = OrientationCalibrationService();
      final simulator = _DriveSimulator(
        service: service,
        mount: _Mount.portrait,
      );

      simulator.drive(
        duration: const Duration(seconds: 8),
        forwardAccelMps2: _normalLaunchAccelMps2,
      );
      expect(service.isForwardCalibrated, isTrue);

      // The phone is rotated about the vehicle's forward axis, so UP moves a
      // long way in device coordinates while forward does not. The stored basis
      // is transported into the new frame from the UP change alone.
      simulator.mount = const _Mount(
        forward: [0, 0, -1],
        left: [0, -1, 0],
        up: [-1, 0, 0],
      );

      simulator.drive(
        duration: const Duration(milliseconds: 600),
        forwardAccelMps2: _normalLaunchAccelMps2,
      );

      expect(service.isForwardCalibrated, isTrue);
      expect(
        service.forwardG,
        closeTo(_normalLaunchAccelMps2 / _g, 0.01),
        reason: 'a remount must not invalidate or mirror the calibration',
      );
      expect(service.lateralG, closeTo(0, 0.02));
    });

    test('a yaw-only remount is relearned from the next decisive event', () {
      final service = OrientationCalibrationService();
      final simulator = _DriveSimulator(
        service: service,
        mount: _Mount.portrait,
      );

      simulator.drive(
        duration: const Duration(seconds: 8),
        forwardAccelMps2: _normalLaunchAccelMps2,
      );
      expect(service.isForwardCalibrated, isTrue);

      // Yawing the phone in its cradle leaves UP unchanged, so there is no tilt
      // change to transport: the new mounting has to be relearned from
      // GPS-labelled acceleration. This one happens instantly, as if the phone
      // were lifted and replaced between sensor samples, so not even the
      // gyroscope saw the rotation.
      simulator.mount = _Mount.portraitYawed;

      // One decisive braking event, clean on every gate, is enough to snap to
      // the new mounting instead of needing two agreeing intervals.
      simulator.drive(
        duration: const Duration(seconds: 3),
        forwardAccelMps2: -2.5,
      );

      expect(
        service.forwardG,
        closeTo(-2.5 / _g, 0.02),
        reason: 'braking after a yaw remount must still read as braking',
      );
    });

    test('falls back to the raw accelerometer when the gravity-removed stream '
        'cannot be paired with it', () {
      final service = OrientationCalibrationService();
      // 150 ms of skew between the two streams is past the pairing window, so
      // gravity cannot be isolated and the older motion-gated raw path is used.
      final simulator = _DriveSimulator(
        service: service,
        mount: _Mount.portrait,
        linearSampleLag: const Duration(milliseconds: 150),
      );

      simulator.drive(
        duration: const Duration(seconds: 8),
        forwardAccelMps2: _normalLaunchAccelMps2,
      );

      expect(service.isForwardCalibrated, isTrue);
      expect(service.forwardG, closeTo(_normalLaunchAccelMps2 / _g, 0.01));
      expect(service.lateralG, closeTo(0, 0.01));
    });

    test('forward G is withheld rather than guessed before calibration', () {
      final service = OrientationCalibrationService();
      final simulator = _DriveSimulator(
        service: service,
        mount: _Mount.portrait,
      );

      // Below the signed-calibration speed gate there is no trustworthy way to
      // tell vehicle forward from vehicle rear, so nothing is published.
      simulator.drive(
        duration: const Duration(seconds: 3),
        forwardAccelMps2: 1.0,
      );

      expect(service.isForwardCalibrated, isFalse);
      expect(service.forwardG, 0);
      expect(
        service.forwardCalibrationConfirmations,
        lessThan(service.forwardCalibrationConfirmationsRequired),
      );
    });

    test('a real brake reaches its true peak instead of being flattened by the '
        'output filter', () {
      final service = OrientationCalibrationService();
      final simulator = _DriveSimulator(
        service: service,
        mount: _Mount.portrait,
      );

      simulator.drive(
        duration: const Duration(seconds: 8),
        forwardAccelMps2: _normalLaunchAccelMps2,
      );
      expect(service.isForwardCalibrated, isTrue);

      // A hard stop lasting only a few tenths of a second is exactly the event
      // smoothness grading scores, and a fixed long time constant would report
      // it as considerably gentler than it was.
      simulator.drive(
        duration: const Duration(milliseconds: 200),
        forwardAccelMps2: -6.0,
      );

      expect(
        service.forwardG.abs(),
        greaterThan(0.9 * 6.0 / _g),
        reason: 'a 200 ms brake should be reported near its real size',
      );
    });
  });
}
