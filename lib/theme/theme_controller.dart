import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/seed_service.dart';

/// Controller responsible for managing and persisting the application's theme state.
class ThemeController extends ChangeNotifier {
  static final ThemeController instance = ThemeController._();
  ThemeController._();

  /// Default theme is Light as requested.
  ThemeMode _themeMode = ThemeMode.light;

  /// The active [ThemeMode] of the application.
  ThemeMode get themeMode => _themeMode;

  /// Indicates whether the active theme is Dark.
  bool get isDark => _themeMode == ThemeMode.dark;

  /// Initializes the theme controller and restores saved preferences if present.
  Future<void> init() async {
    final savedMode = await SeedService.getThemePreference();
    if (savedMode == 'dark') {
      _themeMode = ThemeMode.dark;
    } else {
      // Default to light mode
      _themeMode = ThemeMode.light;
    }
    _syncSystemOverlay();
    notifyListeners();
  }

  /// Toggles between light and dark themes.
  Future<void> toggleTheme(bool enableDark) async {
    _themeMode = enableDark ? ThemeMode.dark : ThemeMode.light;
    _syncSystemOverlay();
    notifyListeners();
    await SeedService.setThemePreference(enableDark ? 'dark' : 'light');
  }

  /// Synchronizes the system status bar and navigation bar styles with the active theme.
  void _syncSystemOverlay() {
    final dark = isDark;
    SystemChrome.setSystemUIOverlayStyle(
      SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: dark ? Brightness.light : Brightness.dark,
        systemNavigationBarColor: dark ? Colors.black : Colors.white,
        systemNavigationBarIconBrightness: dark ? Brightness.light : Brightness.dark,
      ),
    );
  }
}

