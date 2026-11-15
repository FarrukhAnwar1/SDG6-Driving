// Defines the app's light and dark color palettes and shared widget styling.
import 'package:flutter/material.dart';

abstract final class AppTheme {
  static const green = Color(0xff074907);
  static const lightBackground = Color(0xfff5f5f5);
  static const darkBackground = Color(0xff1b1b1b);

  static final light = _build(Brightness.light);
  static final dark = _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final background = dark ? darkBackground : lightBackground;
    // Use a lighter companion green for text/icons on dark surfaces, while
    // keeping the requested green on filled controls in both themes.
    final accent = dark ? const Color(0xffa8d5a5) : green;
    final scheme =
        ColorScheme.fromSeed(seedColor: green, brightness: brightness).copyWith(
          primary: green,
          onPrimary: Colors.white,
          primaryContainer: dark ? green : const Color(0xffdcebdc),
          onPrimaryContainer: dark ? Colors.white : green,
          secondary: accent,
          secondaryContainer: dark ? green : const Color(0xffdcebdc),
          onSecondaryContainer: dark ? Colors.white : green,
          surface: background,
          surfaceDim: dark ? const Color(0xff151515) : const Color(0xffdedede),
          surfaceBright: dark ? const Color(0xff383838) : lightBackground,
          surfaceContainerLowest: dark
              ? const Color(0xff151515)
              : lightBackground,
          surfaceContainerLow: dark
              ? const Color(0xff222222)
              : const Color(0xffeeeeee),
          surfaceContainer: dark
              ? const Color(0xff272727)
              : const Color(0xffe9e9e9),
          surfaceContainerHigh: dark
              ? const Color(0xff303030)
              : const Color(0xffe4e4e4),
          surfaceContainerHighest: dark
              ? const Color(0xff383838)
              : const Color(0xffdedede),
          onSurface: dark ? lightBackground : darkBackground,
          onSurfaceVariant: dark
              ? const Color(0xffc6c6c6)
              : const Color(0xff555555),
          outline: dark ? const Color(0xff8c8c8c) : const Color(0xff757575),
          outlineVariant: dark
              ? const Color(0xff494949)
              : const Color(0xffcccccc),
        );

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: background,
      appBarTheme: AppBarTheme(
        backgroundColor: background,
        foregroundColor: scheme.onSurface,
        surfaceTintColor: Colors.transparent,
      ),
      cardTheme: const CardThemeData(surfaceTintColor: Colors.transparent),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: accent),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(foregroundColor: accent),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(color: accent),
      inputDecorationTheme: InputDecorationTheme(
        focusedBorder: OutlineInputBorder(
          borderSide: BorderSide(color: accent, width: 2),
        ),
        floatingLabelStyle: WidgetStateTextStyle.resolveWith((states) {
          return TextStyle(
            color: states.contains(WidgetState.error)
                ? scheme.error
                : states.contains(WidgetState.focused)
                ? accent
                : scheme.onSurfaceVariant,
          );
        }),
      ),
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: accent,
        selectionColor: accent.withValues(alpha: 0.3),
        selectionHandleColor: accent,
      ),
      switchTheme: SwitchThemeData(
        trackColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.disabled)) return null;
          return states.contains(WidgetState.selected) ? green : null;
        }),
        thumbColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.disabled)) return null;
          return states.contains(WidgetState.selected) ? Colors.white : null;
        }),
      ),
    );
  }
}
