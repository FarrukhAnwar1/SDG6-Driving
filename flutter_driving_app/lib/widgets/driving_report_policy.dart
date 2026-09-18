// Development toggle: set to false to generate and upload reports for trips
// shorter than one mile. Keep true for normal use.
bool enforceMinimumTripDistance = true;

const double minimumReportDistanceMiles = 1.0;

bool canGenerateDrivingReport(double milesDriven) {
  return !enforceMinimumTripDistance ||
      milesDriven >= minimumReportDistanceMiles;
}
