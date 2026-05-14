import 'dart:io';

import 'package:flutter/services.dart';

class SteamKeyboardService {
  SteamKeyboardService._();

  static DateTime _lastShow = DateTime.fromMillisecondsSinceEpoch(0);
  static const Duration _showThrottle = Duration(milliseconds: 500);

  static bool get isSteamDeckLike {
    if (!Platform.isLinux) return false;
    final home = Platform.environment['HOME'] ?? '';
    return home == '/home/deck' || Directory('/home/deck').existsSync();
  }

  static Future<void> show() async {
    // Ask Flutter text input first (safe no-op on unsupported desktop setups).
    await SystemChannels.textInput.invokeMethod<void>('TextInput.show');
    if (!isSteamDeckLike) return;

    final now = DateTime.now();
    if (now.difference(_lastShow) < _showThrottle) return;
    _lastShow = now;

    try {
      await Process.run('xdg-open', const ['steam://open/keyboard']);
    } catch (_) {
      // Best-effort only.
    }
  }

  static Future<void> hide() async {
    try {
      await SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
    } catch (_) {}
  }
}
