import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../romm/romm_models.dart';

/// Raw Redump-style PS2 game ID list (serial → human title), used for download filenames.
/// Source: [PS2-ISO-Batch-Renamer gameid.txt](https://github.com/L10N37/PS2-ISO-Batch-Renamer-).
const String kPs2GameIdCatalogUrl =
    'https://raw.githubusercontent.com/L10N37/PS2-ISO-Batch-Renamer-/refs/heads/main/gameid.txt';

/// Parses `gameid.txt` and resolves a **non-OPL** save name (title from list, not server filename).
class Ps2GameIdCatalog {
  Ps2GameIdCatalog._();
  static final Ps2GameIdCatalog instance = Ps2GameIdCatalog._();

  Map<String, String>? _idToTitle;
  Future<void>? _loadFuture;

  static bool isPs2Platform(Game game) {
    final s = game.platformSlug?.toLowerCase() ?? '';
    return s == 'ps2' || s == 'playstation-2' || s == 'playstation2';
  }

  /// Serial keys like `SLUS_209.74` from free text (filename, title, etc.).
  static Iterable<String> normalizedSerialKeys(String haystack) sync* {
    final s = haystack.toUpperCase();
    final embedded = RegExp(
      r'\b([A-Z0-9]{4})[_-]([0-9]{3})\.([0-9]{2})\b',
      caseSensitive: false,
    );
    for (final m in embedded.allMatches(s)) {
      yield '${m.group(1)}_${m.group(2)}.${m.group(3)}';
    }
    final compact = RegExp(
      r'\b([A-Z]{4})[-_]?([0-9]{5})\b',
      caseSensitive: false,
    );
    for (final m in compact.allMatches(s)) {
      final pfx = m.group(1)!;
      final digits = m.group(2)!;
      yield '${pfx}_${digits.substring(0, 3)}.${digits.substring(3, 5)}';
    }
  }

  static String extensionForDownload(Game game) {
    final from = game.fileName ?? game.fsName ?? '';
    var ext = p.extension(from);
    if (ext.isEmpty) ext = '.iso';
    return ext.toLowerCase();
  }

  static String sanitizeFileStem(String name, {int maxLen = 180}) {
    var s = name
        .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    while (s.endsWith('.')) {
      s = s.substring(0, s.length - 1).trim();
    }
    if (s.isEmpty) return 'rom';
    if (s.length > maxLen) s = s.substring(0, maxLen).trim();
    return s;
  }

  Future<Map<String, String>> _ensureMap() async {
    if (_idToTitle != null) return _idToTitle!;
    _loadFuture ??= _loadFromNetwork();
    await _loadFuture;
    return _idToTitle ?? {};
  }

  Future<void> _loadFromNetwork() async {
    final map = <String, String>{};
    try {
      final dio = Dio(
        BaseOptions(
          connectTimeout: const Duration(seconds: 25),
          receiveTimeout: const Duration(minutes: 3),
          responseType: ResponseType.plain,
          validateStatus: (code) => code != null && code >= 200 && code < 400,
          headers: const {'Accept': 'text/plain'},
        ),
      );
      final res = await dio.get<String>(kPs2GameIdCatalogUrl);
      final body = res.data;
      if (body == null || body.isEmpty) {
        debugPrint('[Ps2GameIdCatalog] Empty response');
        _idToTitle = {};
        return;
      }
      final linePattern = RegExp(
        r'^([A-Z0-9]{4}_[0-9]{3}\.[0-9]{2})\s+(.+?)\s*$',
        caseSensitive: false,
      );
      for (final raw in body.split('\n')) {
        final line = raw.trimRight();
        if (line.isEmpty) continue;
        final m = linePattern.firstMatch(line);
        if (m == null) continue;
        final id = '${m.group(1)}'.toUpperCase();
        final title = m.group(2)!.trim();
        if (title.isEmpty) continue;
        map.putIfAbsent(id, () => title);
      }
      debugPrint('[Ps2GameIdCatalog] Loaded ${map.length} serial entries');
      _idToTitle = map;
    } catch (e, st) {
      debugPrint('[Ps2GameIdCatalog] Failed to load catalog: $e\n$st');
      _idToTitle = {};
    }
  }

  /// Returns a safe **file base name** (no extension) from the catalog, or null to fall back to RomM names.
  Future<String?> resolveDownloadBaseName(Game game) async {
    if (!isPs2Platform(game)) return null;
    final map = await _ensureMap();
    if (map.isEmpty) return null;

    final sources = <String>[
      game.name,
      if (game.fileName != null && game.fileName!.isNotEmpty) game.fileName!,
      if (game.fsName != null && game.fsName!.isNotEmpty) game.fsName!,
      game.id,
    ];
    final tried = <String>{};
    for (final src in sources) {
      for (final key in normalizedSerialKeys(src)) {
        if (!tried.add(key)) continue;
        final title = map[key];
        if (title != null) return sanitizeFileStem(title);
      }
    }
    return null;
  }
}
