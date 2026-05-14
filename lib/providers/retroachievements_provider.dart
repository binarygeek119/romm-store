import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../core/storage/secure_storage_service.dart';
import 'shared_prefs_provider.dart';

class RaCredentials {
  final String username;
  final String apiKey;

  const RaCredentials({
    required this.username,
    required this.apiKey,
  });
}

class RaUserProfile {
  final String username;
  final int points;
  final String? richPresence;
  /// Site-relative path (e.g. `/UserPic/foo.png`).
  final String? userPic;

  const RaUserProfile({
    required this.username,
    required this.points,
    this.richPresence,
    this.userPic,
  });
}

class RaFriend {
  final String username;
  final int points;

  const RaFriend({
    required this.username,
    required this.points,
  });
}

class RaRecentGame {
  final String title;
  final String consoleName;
  final String? imageUrl;
  final String? lastPlayed;

  const RaRecentGame({
    required this.title,
    required this.consoleName,
    this.imageUrl,
    this.lastPlayed,
  });
}

class RaRecentAchievement {
  final String title;
  final String description;
  final String gameTitle;
  final String consoleName;
  final String date;
  final String? badgeUrl;

  const RaRecentAchievement({
    required this.title,
    required this.description,
    required this.gameTitle,
    required this.consoleName,
    required this.date,
    this.badgeUrl,
  });
}

Future<File> _raCredentialsFile() async {
  final dir = await getApplicationSupportDirectory();
  return File('${dir.path}${Platform.pathSeparator}ra_credentials.json');
}

Future<void> saveRaCredentialsToFile(RaCredentials credentials) async {
  final file = await _raCredentialsFile();
  await file.parent.create(recursive: true);
  await file.writeAsString(jsonEncode({
    'username': credentials.username,
    'apiKey': credentials.apiKey,
  }));
}

Future<RaCredentials?> readRaCredentialsFromFile() async {
  try {
    final file = await _raCredentialsFile();
    if (!await file.exists()) return null;
    final raw = await file.readAsString();
    final map = jsonDecode(raw);
    if (map is! Map<String, dynamic>) return null;
    final username = (map['username'] ?? '').toString().trim();
    final apiKey = (map['apiKey'] ?? '').toString().trim();
    if (username.isEmpty || apiKey.isEmpty) return null;
    return RaCredentials(username: username, apiKey: apiKey);
  } catch (_) {
    return null;
  }
}

Future<void> deleteRaCredentialsFile() async {
  try {
    final file = await _raCredentialsFile();
    if (await file.exists()) {
      await file.delete();
    }
  } catch (_) {}
}

final raCredentialsProvider = FutureProvider<RaCredentials?>((ref) async {
  final prefs = ref.read(sharedPreferencesProvider);
  final username = (prefs.getString('raUsername') ?? '').trim();
  final apiKey = (await SecureStorageService.read('raApiKey', prefs) ?? '').trim();
  if (username.isNotEmpty && apiKey.isNotEmpty) {
    // Keep file mirror up to date for portable Linux/AppImage environments.
    await saveRaCredentialsToFile(RaCredentials(username: username, apiKey: apiKey));
    return RaCredentials(username: username, apiKey: apiKey);
  }

  // Fallback: file-backed credentials (requested for cross-session persistence).
  final fileCreds = await readRaCredentialsFromFile();
  if (fileCreds == null) return null;

  // Rehydrate primary stores from file fallback.
  await prefs.setString('raUsername', fileCreds.username);
  await SecureStorageService.write('raApiKey', fileCreds.apiKey, prefs);
  return fileCreds;
});

Map<String, dynamic> _asMap(dynamic value) =>
    value is Map<String, dynamic> ? value : <String, dynamic>{};

List<dynamic> _asList(dynamic value) => value is List<dynamic> ? value : <dynamic>[];

Future<dynamic> _raGet(String endpoint, Map<String, String> query) async {
  final uri = Uri.https('retroachievements.org', '/API/$endpoint', query);
  final response = await http.get(uri);
  if (response.statusCode != 200) {
    throw Exception('RetroAchievements request failed: ${response.statusCode}');
  }
  return jsonDecode(response.body);
}

final raUserProfileProvider = FutureProvider<RaUserProfile?>((ref) async {
  final creds = await ref.watch(raCredentialsProvider.future);
  if (creds == null) return null;
  final raw = await _raGet('API_GetUserProfile.php', {
    'u': creds.username,
    'y': creds.apiKey,
  });
  return _mapUserProfile(raw, creds.username);
});

/// People the signed-in RA user follows ([API_GetUsersIFollow]).
final raFriendsProvider = FutureProvider<List<RaFriend>>((ref) async {
  final creds = await ref.watch(raCredentialsProvider.future);
  if (creds == null) return const [];
  final raw = await _raGet('API_GetUsersIFollow.php', {
    'y': creds.apiKey,
    'c': '100',
  });
  final list = raw is Map<String, dynamic>
      ? _asList(raw['Results'] ?? raw['results'])
      : _asList(raw);
  return list.map((entry) {
    if (entry is String) {
      return RaFriend(username: entry, points: 0);
    }
    final map = _asMap(entry);
    final pointsRaw = map['Points'] ?? map['points'] ?? map['TotalPoints'] ?? 0;
    return RaFriend(
      username: (map['User'] ?? map['user'] ?? map['Username'] ?? 'Unknown').toString(),
      points: int.tryParse(pointsRaw.toString()) ?? 0,
    );
  }).toList(growable: false);
});

List<RaRecentGame> _mapRecentGames(dynamic raw) {
  final list = raw is Map<String, dynamic> ? _asList(raw['RecentGames']) : _asList(raw);
  return list.map((entry) {
    final map = _asMap(entry);
    final imageIcon = map['ImageIcon'] ?? map['GameIcon'];
    final iconStr = imageIcon?.toString();
    return RaRecentGame(
      title: (map['Title'] ?? map['GameTitle'] ?? 'Unknown game').toString(),
      consoleName: (map['ConsoleName'] ?? map['Console'] ?? '').toString(),
      imageUrl: iconStr != null && iconStr.isNotEmpty
          ? 'https://media.retroachievements.org$iconStr'
          : null,
      lastPlayed: map['LastPlayed']?.toString(),
    );
  }).toList(growable: false);
}

final raRecentGamesProvider = FutureProvider<List<RaRecentGame>>((ref) async {
  final creds = await ref.watch(raCredentialsProvider.future);
  if (creds == null) return const [];
  final raw = await _raGet('API_GetUserRecentlyPlayedGames.php', {
    'u': creds.username,
    'y': creds.apiKey,
    'c': '50',
  });
  return _mapRecentGames(raw);
});

RaUserProfile? _mapUserProfile(dynamic raw, String fallbackUsername) {
  final map = _asMap(raw);
  if (map.isEmpty) return null;
  final pointsRaw = map['TotalPoints'] ?? map['TotalSoftcorePoints'] ?? 0;
  return RaUserProfile(
    username: (map['User'] ?? fallbackUsername).toString(),
    points: int.tryParse(pointsRaw.toString()) ?? 0,
    richPresence: map['RichPresenceMsg']?.toString(),
    userPic: map['UserPic']?.toString(),
  );
}

/// Profile for any RA user (for Friends detail pane).
final raUserProfileForProvider =
    FutureProvider.family<RaUserProfile?, String>((ref, username) async {
  final creds = await ref.watch(raCredentialsProvider.future);
  if (creds == null || username.isEmpty) return null;
  final raw = await _raGet('API_GetUserProfile.php', {
    'u': username,
    'y': creds.apiKey,
  });
  return _mapUserProfile(raw, username);
});

/// Recently played games for any RA user.
final raRecentGamesForProvider =
    FutureProvider.family<List<RaRecentGame>, String>((ref, username) async {
  final creds = await ref.watch(raCredentialsProvider.future);
  if (creds == null || username.isEmpty) return const [];
  final raw = await _raGet('API_GetUserRecentlyPlayedGames.php', {
    'u': username,
    'y': creds.apiKey,
    'c': '50',
  });
  return _mapRecentGames(raw);
});

/// Recent unlocks ([API_GetUserRecentAchievements]); [m] = minutes lookback.
final raRecentAchievementsForProvider =
    FutureProvider.family<List<RaRecentAchievement>, String>((ref, username) async {
  final creds = await ref.watch(raCredentialsProvider.future);
  if (creds == null || username.isEmpty) return const [];
  final raw = await _raGet('API_GetUserRecentAchievements.php', {
    'u': username,
    'y': creds.apiKey,
    'm': '43200',
  });
  final list = _asList(raw);
  return list.map((entry) {
    final map = _asMap(entry);
    final badgeRaw = map['BadgeURL'] ?? map['badgeUrl'];
    final badgeStr = badgeRaw?.toString();
    return RaRecentAchievement(
      title: (map['Title'] ?? map['title'] ?? 'Achievement').toString(),
      description: (map['Description'] ?? map['description'] ?? '').toString(),
      gameTitle: (map['GameTitle'] ?? map['gameTitle'] ?? '').toString(),
      consoleName: (map['ConsoleName'] ?? map['consoleName'] ?? '').toString(),
      date: (map['Date'] ?? map['date'] ?? '').toString(),
      badgeUrl: badgeStr != null && badgeStr.isNotEmpty
          ? (badgeStr.startsWith('http')
              ? badgeStr
              : 'https://media.retroachievements.org$badgeStr')
          : null,
    );
  }).toList(growable: false);
});
