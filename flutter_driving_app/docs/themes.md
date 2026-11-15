# App themes

The first-launch defaults are **Dark Theme on** and **Auto Theme Switching off**.
Light uses `#f5f5f5`; dark uses `#1b1b1b`. Filled controls use `#074907` in both
themes, with lighter green foreground accents for readability on dark surfaces.

Settings saves the automatic preference and the last manual selection together in
device storage. When automatic switching is off, the Dark Theme switch and the
sun/moon button to the left of Live Voice Feedback both update the same preference.
Enabling automatic switching hides both manual controls. Disabling it restores the
last manual selection.

Automatic switching reuses the app's existing location stream and last known
location, without starting another GPS subscription or requesting permissions.
It uses the [NOAA solar-position equations](https://gml.noaa.gov/grad/solcalc/solareqns.PDF)
and the apparent sunrise/sunset horizon to choose light during daylight and dark
at night. Calculations run locally, including polar day/night, without a network
API. The app refreshes on position changes, every 30 seconds, and when resumed.
UTC calculations account for longitude without relying on the phone's time zone.
Until a location is available, automatic mode uses dark and explains this in Settings.
