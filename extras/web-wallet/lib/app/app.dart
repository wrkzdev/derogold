import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/providers/app_providers.dart';
import '../l10n/generated/app_localizations.dart';
import '../shared/theme/app_theme.dart';
import 'router.dart';

class DeroGoldWebApp extends ConsumerWidget {
  const DeroGoldWebApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(routerProvider);
    final themeMode = ref.watch(themeModeProvider);
    final locale = ref.watch(localeProvider);
    // Watched, not read, purely to build the provider at startup: its notifier
    // is what pushes the stored level into the wallet module, whose logger
    // starts DISABLED every time the module loads.
    ref.watch(logLevelProvider);

    return MaterialApp.router(
      title: 'DeroGold Web Wallet',
      debugShowCheckedModeBanner: false,
      theme: buildLightTheme(),
      darkTheme: buildDarkTheme(),
      themeMode: themeMode,
      locale: locale,
      supportedLocales: supportedLocales,
      localizationsDelegates: const [
        S.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      routerConfig: router,
    );
  }
}
