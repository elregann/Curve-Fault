import 'package:flutter/material.dart';
import 'pages/vault_page.dart';
import 'pages/encrypt_page.dart';
import 'pages/identity_page.dart';
import 'pages/setup_page.dart';
import 'services/seed_service.dart';
import 'theme/app_sizes.dart';
import 'theme/theme_controller.dart';
import 'pages/unlock_page.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await ThemeController.instance.init();
  runApp(const CurveVaultApp());
}

/// The root application widget supporting both light and dark retro visual themes.
class CurveVaultApp extends StatelessWidget {
  const CurveVaultApp({super.key});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: ThemeController.instance,
      builder: (context, _) {
        final isDark = ThemeController.instance.isDark;

        return MaterialApp(
          title: 'Curve Fault',
          debugShowCheckedModeBanner: false,
          themeMode: ThemeController.instance.themeMode,

          // Retro Light Theme (Default)
          theme: ThemeData(
            useMaterial3: false,
            brightness: Brightness.light,
            scaffoldBackgroundColor: Colors.white,
            primaryColor: Colors.black,
            appBarTheme: const AppBarTheme(
              backgroundColor: Colors.white,
              elevation: 0,
              centerTitle: false,
              titleTextStyle: TextStyle(
                color: Colors.black,
                fontSize: AppSizes.title + 1,
                fontWeight: FontWeight.w500,
              ),
              iconTheme: IconThemeData(color: Colors.black),
            ),
            listTileTheme: const ListTileThemeData(
              textColor: Colors.black,
              iconColor: Colors.black,
              contentPadding: EdgeInsets.symmetric(
                horizontal: AppSizes.listPaddingHorizontal,
              ),
            ),
            dividerColor: const Color(0xFFE0E0E0),
          ),

          // Retro Dark Theme
          darkTheme: ThemeData(
            useMaterial3: false,
            brightness: Brightness.dark,
            scaffoldBackgroundColor: Colors.black,
            primaryColor: Colors.white,
            appBarTheme: const AppBarTheme(
              backgroundColor: Colors.black,
              elevation: 0,
              centerTitle: false,
              titleTextStyle: TextStyle(
                color: Colors.white,
                fontSize: AppSizes.title + 1,
                fontWeight: FontWeight.w500,
              ),
              iconTheme: IconThemeData(color: Colors.white),
            ),
            listTileTheme: const ListTileThemeData(
              textColor: Colors.white,
              iconColor: Colors.white,
              contentPadding: EdgeInsets.symmetric(
                horizontal: AppSizes.listPaddingHorizontal,
              ),
            ),
            dividerColor: const Color(0xFF222222),
          ),

          home: FutureBuilder<bool>(
            future: SeedService.hasSetup(),
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return Scaffold(
                  backgroundColor: isDark ? Colors.black : Colors.white,
                  body: Center(
                    child: CircularProgressIndicator(
                      color: isDark ? Colors.white : Colors.black,
                    ),
                  ),
                );
              }

              final hasSetup = snapshot.data ?? false;
              return hasSetup ? const UnlockPage() : const SetupPage();
            },
          ),
        );
      },
    );
  }
}

/// The primary shell structure hosting bottom navigation across Vault, Encrypt, and Identity tabs.
class MainShell extends StatefulWidget {
  const MainShell({super.key});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int _currentIndex = 0;

  final _pages = const [
    VaultPage(),
    EncryptPage(),
    IdentityPage(),
  ];

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final backgroundColor = Theme.of(context).scaffoldBackgroundColor;
    final activeColor = Theme.of(context).primaryColor;
    final inactiveColor = isDark ? Colors.white38 : Colors.black38;
    final dividerColor = Theme.of(context).dividerColor;

    return Scaffold(
      body: IndexedStack(
        index: _currentIndex,
        children: _pages,
      ),
      bottomNavigationBar: Container(
        height: AppSizes.navHeight,
        decoration: BoxDecoration(
          color: backgroundColor,
          border: Border(
            top: BorderSide(color: dividerColor, width: 0.5),
          ),
        ),
        child: BottomNavigationBar(
          currentIndex: _currentIndex,
          onTap: (i) => setState(() => _currentIndex = i),
          backgroundColor: backgroundColor,
          selectedItemColor: activeColor,
          unselectedItemColor: inactiveColor,
          type: BottomNavigationBarType.fixed,
          selectedFontSize: AppSizes.navLabel,
          unselectedFontSize: AppSizes.navLabel,
          iconSize: AppSizes.navIcon,
          items: const [
            BottomNavigationBarItem(
              icon: Icon(Icons.lock_outline),
              activeIcon: Icon(Icons.lock),
              label: 'Vault',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.add_circle_outline),
              activeIcon: Icon(Icons.add_circle),
              label: 'Encrypt',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.person_outline),
              activeIcon: Icon(Icons.person),
              label: 'Identity',
            ),
          ],
        ),
      ),
    );
  }
}
