import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'app/app.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  // No window manager, tray or notifier here: the browser owns the window, and
  // the wallet module is booted lazily by WalletCApi.init() the first time
  // anything asks it for something. Starting it here would only move the wait
  // in front of the first frame.
  runApp(const ProviderScope(child: DeroGoldWebApp()));
}
