import 'package:flutter/material.dart';

/// Warm, paper-like palette to match the "dusty library" feel.
class DustyTheme {
  static const seed = Color(0xFF8B5E3C);

  static ThemeData light() => _base(
    ColorScheme.fromSeed(seedColor: seed, brightness: Brightness.light),
  );

  static ThemeData dark() => _base(
    ColorScheme.fromSeed(seedColor: seed, brightness: Brightness.dark),
  );

  static ThemeData _base(ColorScheme scheme) => ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    visualDensity: VisualDensity.adaptivePlatformDensity,
    cardTheme: const CardThemeData(
      clipBehavior: Clip.antiAlias,
      margin: EdgeInsets.zero,
    ),
    inputDecorationTheme: const InputDecorationTheme(
      border: OutlineInputBorder(),
    ),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
  );
}

/// Colours used by the reader page filters.
class ReaderPalette {
  /// Aged paper that has lost its cream: dim, and only a few points warmer
  /// than a flat grey so the page does not glare.
  static const paper = Color(0xFFA3A2A0);
  static const paperInk = Color(0xFF2A2928);

  /// Stronger warm tint.
  static const sepia = Color(0xFFE8D5B5);
  static const sepiaInk = Color(0xFF4A3A28);

  static const dark = Color(0xFF121212);
  static const darkInk = Color(0xFFD8D4CC);
}
