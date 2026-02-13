import 'package:flutter/material.dart';

class PootTheme {
  const PootTheme._();

  static ThemeData get light {
    const Color primary = Color(0xFF0F6A66);
    const Color accent = Color(0xFFE09F3E);
    const Color bg = Color(0xFFF5F4EF);

    final ColorScheme scheme = ColorScheme.fromSeed(
      seedColor: primary,
      brightness: Brightness.light,
      primary: primary,
      secondary: accent,
      surface: Colors.white,
    );

    return ThemeData(
      colorScheme: scheme,
      scaffoldBackgroundColor: bg,
      useMaterial3: true,
      appBarTheme: const AppBarTheme(
        backgroundColor: primary,
        foregroundColor: Colors.white,
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: primary,
          foregroundColor: Colors.white,
          minimumSize: const Size.fromHeight(48),
          textStyle: const TextStyle(fontWeight: FontWeight.w700),
        ),
      ),
      inputDecorationTheme: const InputDecorationTheme(
        border: OutlineInputBorder(),
      ),
      chipTheme: const ChipThemeData(
        backgroundColor: Color(0xFFE5F1F0),
        labelStyle: TextStyle(color: primary),
      ),
    );
  }
}
