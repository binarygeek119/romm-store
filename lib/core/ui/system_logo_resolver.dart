import 'dart:convert';

import 'package:flutter/services.dart';

/// Maps RomM / IGDB-style platform slugs and short names to LaunchBox-style clear-logo
/// basenames (filename without `.png`) shipped under [prefix].
///
/// Call [preload] from `main()` before `runApp` so lookups are accurate.
class SystemLogoResolver {
  SystemLogoResolver._();

  static const String prefix = 'src/assets/images/systems/';

  static Map<String, String>? _normalizedStemToAssetPath;
  static List<String>? _stemsByDescendingLength;

  static Future<void> preload() async {
    if (_normalizedStemToAssetPath != null) return;

    late final Iterable<String> assetPaths;
    try {
      final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
      assetPaths = manifest.listAssets();
    } catch (_) {
      try {
        final raw = await rootBundle.loadString('AssetManifest.json');
        assetPaths = (json.decode(raw) as Map<String, dynamic>).keys.cast<String>();
      } catch (_) {
        _normalizedStemToAssetPath = {};
        _stemsByDescendingLength = [];
        return;
      }
    }

    final stemToPath = <String, String>{};
    final stems = <String>[];

    for (final path in assetPaths) {
      if (!path.startsWith(prefix) || !path.endsWith('.png')) continue;
      final relative = path.substring(prefix.length);
      if (relative.contains('/')) continue;

      final stem = relative.substring(0, relative.length - 4);
      stems.add(stem);
      stemToPath.putIfAbsent(_normalize(stem), () => path);
    }

    stems.sort((a, b) => b.length.compareTo(a.length));
    _normalizedStemToAssetPath = stemToPath;
    _stemsByDescendingLength = stems;
  }

  /// Basenames without `.png` that exist in your asset pack — indexed by slug / shorthand.
  static const Map<String, String> slugToBasename = {
    // Nintendo
    'nes': 'Nintendo Entertainment System',
    'famicom': 'Nintendo Famicom 01',
    'fds': 'Nintendo Famicom Disk System 01',
    'snes': 'Super Nintendo Entertainment System',
    'super-nintendo': 'Super Nintendo Entertainment System',
    'sfc': 'Super Famicom',
    'super-famicom': 'Super Famicom',
    'n64': 'Nintendo 64',
    '64dd': 'Nintendo 64DD',
    'gc': 'Nintendo GameCube',
    'ngc': 'Nintendo GameCube',
    'gamecube': 'Nintendo GameCube',
    'wii': 'Nintendo Wii',
    'wiiu': 'Nintendo Wii U',
    'switch': 'Nintendo Switch',
    'gb': 'Nintendo Game Boy',
    'gbc': 'Nintendo Game Boy Color',
    'gba': 'Nintendo Game Boy Advance',
    'nds': 'Nintendo DS',
    'dsi': 'Nintendo DS',
    '3ds': 'Nintendo 3DS',
    'vb': 'Nintendo Virtual Boy',
    'virtual-boy': 'Nintendo Virtual Boy',
    'pokemon-mini': 'Nintendo Pokemon Mini',
    'game-and-watch': 'Nintendo Game & Watch',
    'game-&-watch': 'Nintendo Game & Watch',
    'satellaview': 'Nintendo Stellaview',
    'sufami': 'Nintendo Sufami Turbo',
    'sfam': 'Nintendo Sufami Turbo',
    'super-game-boy': 'Nintendo Super Gameboy',
    'super-gameboy': 'Nintendo Super Gameboy',
    'sgb': 'Nintendo Super Gameboy',
    'playchoice': 'Nintendo Playchoice',
    'playchoice-10': 'Nintendo Playchoice-10',
    'virtual-console': 'Nintendo Virtual Console',
    'wiiware': 'Nintendo Wiiware',

    // Sony
    'ps': 'Sony Playstation',
    'psx': 'Sony Playstation',
    'playstation': 'Sony Playstation',
    'ps2': 'Sony Playstation 2',
    'ps3': 'Sony Playstation 3',
    'ps4': 'Sony Playstation 4',
    'psp': 'Sony PSP',
    'ps-vita': 'Sony Playstation Vita',
    'vita': 'Sony Playstation Vita',
    'pocketstation': 'Sony PocketStation',

    // Microsoft
    'xbox': 'Microsoft Xbox',
    'xbox360': 'Microsoft Xbox 360',
    'xbox-360': 'Microsoft Xbox 360',
    'xbox-one': 'Microsoft Xbox One',
    'xbla': 'Microsoft Xbox LIVE Arcade',

    // Sega
    'sms': 'Sega Master System',
    'mastersystem': 'Sega Master System',
    'master-system': 'Sega Master System',
    'genesis': 'Sega Genesis',
    'mega-drive': 'Sega Mega Drive 03',
    'megadrive': 'Sega Mega Drive 03',
    'mega-drive-japan': 'Sega Mega Drive 03',
    'gamegear': 'Sega Game Gear',
    'game-gear': 'Sega Game Gear',
    'segacd': 'Sega CD',
    'mega-cd': 'Sega Mega CD 03',
    '32x': 'Sega 32X',
    'saturn': 'Sega Saturn Japan 02',
    'dreamcast': 'Sega Dreamcast',
    'dc': 'Sega Dreamcast',
    'sg1000': 'Sega SG-1000',
    'sg-1000': 'Sega SG-1000',
    'sc3000': 'Sega SC-3000',
    'pico': 'Sega Pico',
    'nomad': 'Sega Nomad',
    'model2': 'Sega Model 2',
    'model-2': 'Sega Model 2',
    'model3': 'Sega Model 3',
    'model-3': 'Sega Model 3',
    'naomi': 'Sega Naomi',
    'atomiswave': 'Sammy Atomiswave',
    'triforce': 'Sega Triforce',

    // SNK / Neo Geo
    'neogeo': 'SNK Neo Geo',
    'neo-geo': 'SNK Neo Geo',
    'neogeoaes': 'SNK Neo Geo AES',
    'neo-geo-aes': 'SNK Neo Geo AES',
    'neogeocd': 'SNK Neo Geo CD',
    'neo-geo-cd': 'SNK Neo Geo CD',
    'neo-geo-pocket-color': 'SNK Neo Geo Pocket Color',
    'neo-geo-pocket': 'SNK Neo Geo Pocket Color',
    'ngpc': 'SNK Neo Geo Pocket Color',

    // NEC / Turbo
    'tg16': 'Turbografx-16',
    'turbografx16': 'Turbografx-16',
    'pc-engine': 'PC Engine',
    'pcengine': 'PC Engine',
    'supergrafx': 'Super Grafx',
    'super-grafx': 'Super Grafx',
    'tg-cd': 'Turbografx-CD',
    'pc-engine-cd': 'PC Engine CD-Rom System',
    'pc-engine-duo': 'NEC Turbo Duo',

    // Atari
    '2600': 'Atari 2600',
    '5200': 'Atari 5200',
    '7800': 'Atari 7800',
    'lynx': 'Atari Lynx 01',
    'jaguar': 'Atari Jaguar',
    'jaguar-cd': 'Atari Jaguar CD',
    'st': 'Atari ST',
    'atarist': 'Atari ST',

    // Other consoles / computers (RomM folder-style slugs)
    '3do': '3DO Interactive Multiplayer',
    'cd-i': 'Philips CD-i',
    'cdi': 'Philips CD-i',
    'amiga': 'Amiga',
    'amiga-cd32': 'Amiga CD32',
    'c64': 'Commodore 64',
    'commodore-64': 'Commodore 64',
    'vic20': 'Commodore VIC-20',
    'vic-20': 'Commodore VIC-20',
    'cpc': 'Amstrad CPC',
    'amstradcpc': 'Amstrad CPC',
    'msx': 'Microsoft MSX',
    'msx2': 'Microsoft MSX2',
    'msx2+': 'Microsoft MSX2+',
    'zx-spectrum': 'Sinclair ZX Spectrum',
    'zxspectrum': 'Sinclair ZX Spectrum',
    'zx81': 'Sinclair ZX-81',
    'dos': 'MS-DOS',
    'msx-dos': 'MS-DOS',
    'windows': 'Windows 01',
    'mac': 'Mac OS',
    'macos': 'Mac OS',
    'arcade': 'MAME',
    'mame': 'MAME',
    'cps1': 'Capcom Play System',
    'cps2': 'Capcom Play System II',
    'cps3': 'Capcom Play System III',
    'intellivision': 'Intellivision 01',
    'coleco': 'Coleco',
    'colecovision': 'Colecovision',
    'vectrex': 'GCE Vectrex',
    'odyssey': 'Magnavox Odyssey',
    'fairchild-channel-f': 'Fairchild Channel F',
    'channel-f': 'Fairchild Channel F',
    'bandai-wonderswan': 'WonderSwan',
    'wonderswan': 'WonderSwan',
    'swancrystal': 'Swan Crystal',
    'neogeopocket': 'SNK Neo Geo',
    'plug-and-play': 'Console Hacks',
    'pegasus': 'Aamber Pegasus',
    'acorn-archimedes': 'Acorn Archimedes',
    'acorn-electron': 'Acorn Electron',
    'bbc-micro': 'BBC Microcomputer System',
    'dragon-32': 'Dragon 32-64',
    'dragon-64': 'Dragon 32-64',
    'apple-ii': 'Apple II',
    'apple-iigs': 'Apple IIGS',
    'oric': 'Oric Atmos',
    'sharp-x68000': 'Sharp X68000',
    'fm-towns': 'Fujitsu FM Towns',
    'pc': 'IBM PC',
    'steam': 'Steam',
    'gog': 'GOG',
    'android': 'Android 01',
    'ios': 'iOS',
    'casio-loopy': 'Casio Loopy',
    'supervision': 'Watara Supervision',
    'gamewave': 'Game Wave Family Entertainment System',
    'nuon': 'NUON',
    'gp32': 'Gamepark GP32',
    'gp32-handheld': 'Gamepark GP32',
    'openbor': 'OpenBOR',
    'scummvm': 'ScummVM',
    'pv1000': 'Casio PV-1000',
    'pv-1000': 'Casio PV-1000',
    'pv2000': 'Casio PV-2000',
    'pv-2000': 'Casio PV-2000',
  };

  static String _normalize(String input) {
    var s = input.toLowerCase().trim();
    s = s.replaceAll('&', 'and');
    s = s.replaceAll(RegExp(r'[/\-_]'), ' ');
    s = s.replaceAll(RegExp(r'[^\w\s]'), '');
    s = s.replaceAll(RegExp(r'\s+'), ' ');
    return s.trim();
  }

  static String _humanizeSlug(String? slug) {
    if (slug == null || slug.isEmpty) return '';
    final parts = slug.split(RegExp(r'[-_]')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '';
    return parts.map((w) {
      if (w.length <= 4 && RegExp(r'^[a-z]+$').hasMatch(w)) {
        return w.toUpperCase();
      }
      return '${w[0].toUpperCase()}${w.substring(1)}';
    }).join(' ');
  }

  static String? _lookupNormalizedStem(String candidate) {
    final map = _normalizedStemToAssetPath;
    if (map == null || candidate.isEmpty) return null;
    return map[_normalize(candidate)];
  }

  static String? assetPathForPlatform({
    required String? displayName,
    required String? slug,
    required String? fsSlug,
    String? fallbackName,
  }) {
    final attempts = <String>[];

    void add(String? s) {
      final t = s?.trim();
      if (t != null && t.isNotEmpty) attempts.add(t);
    }

    add(displayName);
    add(fallbackName);

    final sl = slug?.toLowerCase().trim();
    if (sl != null && sl.isNotEmpty) {
      add(slugToBasename[sl]);
    }

    final fs = fsSlug?.toLowerCase().trim();
    if (fs != null && fs.isNotEmpty && fs != sl) {
      add(slugToBasename[fs]);
    }

    add(_humanizeSlug(slug));
    add(_humanizeSlug(fsSlug));

    if (_normalizedStemToAssetPath != null) {
      for (final attempt in attempts) {
        final hit = _lookupNormalizedStem(attempt);
        if (hit != null) return hit;
      }

      final fuzzy = _fuzzyStem(displayName) ?? _fuzzyStem(slug) ?? _fuzzyStem(fsSlug);
      if (fuzzy != null) return '$prefix$fuzzy.png';
    }

    // Manifest not loaded yet — preserve legacy behaviour.
    final primary = displayName?.trim();
    if (primary != null && primary.isNotEmpty) {
      return '$prefix$primary.png';
    }
    return null;
  }

  static String? assetPathForGame({
    required String? platformDisplayName,
    required String? platformSlug,
  }) {
    return assetPathForPlatform(
      displayName: platformDisplayName,
      slug: platformSlug,
      fsSlug: null,
    );
  }

  static String? _fuzzyStem(String? raw) {
    final stems = _stemsByDescendingLength;
    if (stems == null || raw == null || raw.trim().isEmpty) return null;

    final needle = _normalize(raw);
    if (needle.length < 4) return null;

    // Prefer the shortest logo filename whose normalized stem still contains the query
    // (e.g. "Game Boy" -> Nintendo Game Boy, not Game Boy Advance).
    String? shortestContain;
    var shortestLen = 1 << 30;
    for (var i = stems.length - 1; i >= 0; i--) {
      final stem = stems[i];
      final hay = _normalize(stem);
      if (hay.isEmpty) continue;
      if (hay == needle || (hay.contains(needle) && (needle.length >= 5 || hay == needle))) {
        if (stem.length < shortestLen) {
          shortestLen = stem.length;
          shortestContain = stem;
        }
      }
    }
    if (shortestContain != null) return shortestContain;

    // Longer RomM titles that embed a shorter stem (less common).
    String? longestEmbedded;
    var longestEmbeddedHay = -1;
    for (final stem in stems) {
      final hay = _normalize(stem);
      if (hay.isEmpty || hay.length >= needle.length) continue;
      if (needle.contains(hay) && hay.length >= 6) {
        if (hay.length > longestEmbeddedHay) {
          longestEmbeddedHay = hay.length;
          longestEmbedded = stem;
        }
      }
    }
    return longestEmbedded;
  }
}
