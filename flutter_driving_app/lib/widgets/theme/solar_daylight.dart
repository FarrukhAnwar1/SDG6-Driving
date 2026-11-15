// Determines local daylight from the current time and geographic coordinates.
import 'dart:math' as math;

/// Whether the sun is above the apparent sunrise/sunset horizon at [time].
/// NOAA solar-position equations, including the 90.833 degree horizon:
/// https://gml.noaa.gov/grad/solcalc/solareqns.PDF
/// UTC avoids time-zone and daylight-saving assumptions. This also handles
/// polar day/night without special sunrise/sunset date arithmetic.
bool isSolarDaylight(DateTime time, double latitude, double longitude) {
  if (!latitude.isFinite ||
      !longitude.isFinite ||
      latitude.abs() > 90 ||
      longitude.abs() > 180) {
    return false;
  }

  final utc = time.toUtc();
  final startOfYear = DateTime.utc(utc.year);
  final daysInYear = DateTime.utc(utc.year + 1).difference(startOfYear).inDays;
  final hour = utc.hour + utc.minute / 60 + utc.second / 3600;
  final day = DateTime.utc(
    utc.year,
    utc.month,
    utc.day,
  ).difference(startOfYear).inDays;
  final gamma = 2 * math.pi / daysInYear * (day + (hour - 12) / 24);
  final equationOfTime =
      229.18 *
      (0.000075 +
          0.001868 * math.cos(gamma) -
          0.032077 * math.sin(gamma) -
          0.014615 * math.cos(2 * gamma) -
          0.040849 * math.sin(2 * gamma));
  final declination =
      0.006918 -
      0.399912 * math.cos(gamma) +
      0.070257 * math.sin(gamma) -
      0.006758 * math.cos(2 * gamma) +
      0.000907 * math.sin(2 * gamma) -
      0.002697 * math.cos(3 * gamma) +
      0.00148 * math.sin(3 * gamma);
  final solarMinutes = (hour * 60 + equationOfTime + 4 * longitude) % 1440;
  final hourAngle = (solarMinutes / 4 - 180) * math.pi / 180;
  final lat = latitude * math.pi / 180;
  final cosineZenith =
      math.sin(lat) * math.sin(declination) +
      math.cos(lat) * math.cos(declination) * math.cos(hourAngle);
  return cosineZenith > math.cos(90.833 * math.pi / 180);
}
