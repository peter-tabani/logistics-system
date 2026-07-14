// Dark / light theme for Stan. The navy brand (headers, primary buttons) stays
// navy in both modes; backgrounds, cards and text flip. The chosen mode is
// persisted. Screens read brand-aware colors via StanTheme.instance.palette().

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

const Color _brandNavy = Color(0xFF0E2140);

class StanPalette {
  const StanPalette({
    required this.surface,
    required this.card,
    required this.appBar,
    required this.border,
    required this.textStrong,
    required this.textSoft,
    required this.muted,
    required this.onDark,
  });

  final Color surface;
  final Color card;
  final Color appBar;
  final Color border;
  final Color textStrong;
  final Color textSoft;
  final Color muted;
  final Color onDark;
}

const StanPalette _lightPalette = StanPalette(
  surface: Color(0xFFEEF2F8),
  card: Colors.white,
  appBar: _brandNavy,
  border: Color(0xFFE2E8F0),
  textStrong: _brandNavy,
  textSoft: Color(0xFF60727A),
  muted: Color(0xFF94A3B8),
  onDark: Colors.white,
);

const StanPalette _darkPalette = StanPalette(
  surface: Color(0xFF0A1524),
  card: Color(0xFF15253B),
  appBar: _brandNavy,
  border: Color(0xFF243B57),
  textStrong: Colors.white,
  textSoft: Color(0xFFB9C6DB),
  muted: Color(0xFF7C8CA3),
  onDark: Colors.white,
);

class StanTheme {
  StanTheme._();
  static final StanTheme instance = StanTheme._();

  static const _key = 'stan_theme_mode';

  final ValueNotifier<ThemeMode> mode = ValueNotifier(ThemeMode.light);

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_key);
    mode.value = switch (saved) {
      'dark' => ThemeMode.dark,
      'light' => ThemeMode.light,
      'system' => ThemeMode.system,
      _ => ThemeMode.light,
    };
  }

  Future<void> setMode(ThemeMode value) async {
    mode.value = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, value.name);
  }

  Future<void> toggle(BuildContext context) =>
      setMode(isDark(context) ? ThemeMode.light : ThemeMode.dark);

  bool isDark(BuildContext context) {
    return switch (mode.value) {
      ThemeMode.dark => true,
      ThemeMode.light => false,
      ThemeMode.system =>
        MediaQuery.platformBrightnessOf(context) == Brightness.dark,
    };
  }

  StanPalette palette(BuildContext context) =>
      isDark(context) ? _darkPalette : _lightPalette;

  ThemeData get lightTheme => _themeFor(Brightness.light, _lightPalette);
  ThemeData get darkTheme => _themeFor(Brightness.dark, _darkPalette);

  ThemeData _themeFor(Brightness brightness, StanPalette p) {
    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      fontFamily: 'Roboto',
      scaffoldBackgroundColor: p.surface,
      colorScheme: ColorScheme.fromSeed(
        seedColor: _brandNavy,
        brightness: brightness,
        surface: p.surface,
      ),
      canvasColor: p.surface,
      dialogTheme: DialogThemeData(backgroundColor: p.card),
      bottomSheetTheme: BottomSheetThemeData(backgroundColor: p.card),
      cardColor: p.card,
      appBarTheme: AppBarTheme(backgroundColor: p.appBar, foregroundColor: p.onDark),
      // Brand primary button — navy pill in both modes.
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: _brandNavy,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 18),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
        ),
      ),
    );
  }
}

/// A compact segmented Light / Dark switch for profile screens.
class ThemeModeToggle extends StatelessWidget {
  const ThemeModeToggle({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: StanTheme.instance.mode,
      builder: (context, _, _) {
        final dark = StanTheme.instance.isDark(context);
        final palette = StanTheme.instance.palette(context);
        return Container(
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: palette.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: palette.border),
          ),
          child: Row(
            children: [
              _segment(context, 'Light', Icons.light_mode, !dark, ThemeMode.light, palette),
              _segment(context, 'Dark', Icons.dark_mode, dark, ThemeMode.dark, palette),
            ],
          ),
        );
      },
    );
  }

  Widget _segment(BuildContext context, String label, IconData icon, bool active,
      ThemeMode target, StanPalette palette) {
    return GestureDetector(
      onTap: () => StanTheme.instance.setMode(target),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: active ? _brandNavy : Colors.transparent,
          borderRadius: BorderRadius.circular(9),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: active ? Colors.white : palette.muted),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                color: active ? Colors.white : palette.muted,
                fontWeight: FontWeight.w800,
                fontSize: 13,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
