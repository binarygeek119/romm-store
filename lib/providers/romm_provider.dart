import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:romm_store/core/storage/directory_service.dart';
import 'package:romm_store/core/romm/romm_models.dart';
import 'package:romm_store/core/romm/romm_service.dart';
import 'package:romm_store/core/save/backup_repository.dart';
import 'package:romm_store/core/save/backup_service.dart';
import 'package:romm_store/core/storage/download_cache_service.dart';
import 'package:romm_store/core/storage/metadata_cache_service.dart';
import 'package:romm_store/core/storage/rom_mapping_service.dart';
import 'package:romm_store/core/romm/rom_scanner_service.dart';
import 'package:romm_store/core/romm/library_snapshot_service.dart';
import 'package:romm_store/providers/shared_prefs_provider.dart';
import 'package:romm_store/core/storage/secure_storage_service.dart';

final downloadCacheServiceProvider = Provider<DownloadCacheService>((ref) {
  final prefs = ref.watch(sharedPreferencesProvider);
  final service = DownloadCacheService(prefs);
  service.load();
  return service;
});

// Provider for loading RomMConfig (including stored Bearer token)
final rommConfigProvider = FutureProvider<RomMConfig>((ref) async {
  final prefs = ref.watch(sharedPreferencesProvider);
  
  String baseUrl = prefs.getString('rommBaseUrl') ?? '';
  // Removed default example.com URL to avoid first-start error screens
  
  final username = prefs.getString('rommUsername') ?? '';
  final password = await SecureStorageService.read('rommPassword', prefs) ?? '';
  final token = await SecureStorageService.read('rommAuthToken', prefs);
  final apiKey = await SecureStorageService.read('rommApiKey', prefs) ?? '';

  debugPrint('[RomM-Init] Loading config:');
  debugPrint('  - Base URL: $baseUrl');
  debugPrint('  - Username: ${username.isEmpty ? "EMPTY" : username}');
  debugPrint('  - Password: ${password.isEmpty ? "EMPTY" : "LOADED"}');
  debugPrint('  - API Key: ${apiKey.isEmpty ? "EMPTY" : "LOADED"}');

  return RomMConfig(
    baseUrl: baseUrl, 
    username: username, 
    password: password, 
    token: token, 
    apiKey: apiKey
  );
});

// Exposes a login function that fetches a Bearer token and refreshes the config/service providers.
final loginProvider = Provider<Future<void> Function(String baseUrl, String username, String password)>((ref) {
  return (baseUrl, username, password) async {
    final prefs = ref.read(sharedPreferencesProvider);
    await RommService.fetchToken(baseUrl, username, password, prefs);
    ref.invalidate(rommConfigProvider);
    ref.invalidate(rommServiceProvider);
  };
});

// Simplified DirectoryService provider
final directoryServiceProvider = FutureProvider<DirectoryService?>((ref) async {
  try {
    final prefs = ref.watch(sharedPreferencesProvider);
    final service = DirectoryService(prefs);
    await service.initialize();
    return service;
  } catch (e) {
    // Return service even on error so UI can access service.status
    final prefs = ref.watch(sharedPreferencesProvider);
    final service = DirectoryService(prefs);
    service.status = StorageStatus(error: StorageError.unknown, message: e.toString());
    return service;
  }
});

// Simplified RommService provider
final rommServiceProvider = Provider<RommService?>((ref) {
  final rommConfigAsync = ref.watch(rommConfigProvider);
  final directoryServiceAsync = ref.watch(directoryServiceProvider);

  final config = rommConfigAsync.asData?.value;
  final directoryService = directoryServiceAsync.asData?.value;

  if (config != null && directoryService != null && config.baseUrl.isNotEmpty) {
    try {
      debugPrint('[RomM-Init] Initializing RommService with config for ${config.baseUrl}');
      final service = RommService(config);
      // Refresh token on startup to ensure latest scopes
      if (config.username.isNotEmpty && config.password.isNotEmpty) {
        debugPrint('[RomM-Init] Triggering background token refresh...');
        final prefs = ref.read(sharedPreferencesProvider);
        service.refreshToken(prefs);
      }
      service.startHeartbeat();
      ref.onDispose(() => service.stopHeartbeat());
      return service;
    } catch (e) {
      debugPrint('[RomM-Init] FAILED to initialize RommService: $e');
      return null;
    }
  }
  return null;
});

final metadataCacheServiceProvider = FutureProvider<MetadataCacheService>((ref) async {
  final service = MetadataCacheService();
  await service.load();
  return service;
});

final librarySnapshotServiceProvider = Provider<LibrarySnapshotService>((ref) {
  return LibrarySnapshotService();
});

final romMappingServiceProvider = FutureProvider<RomMappingService>((ref) async {
  final service = RomMappingService();
  await service.init();
  return service;
});

final romScannerServiceProvider = Provider<RomScannerService?>((ref) {
  final rommService = ref.watch(rommServiceProvider);
  ref.watch(isOfflineProvider);
  final mappingServiceAsync = ref.watch(romMappingServiceProvider);
  final directoryServiceAsync = ref.watch(directoryServiceProvider);
  
  final mappingService = mappingServiceAsync.asData?.value;
  final directoryService = directoryServiceAsync.asData?.value;

  if (rommService != null && mappingService != null && directoryService != null) {
    return RomScannerService(rommService, mappingService, directoryService);
  }
  return null;
});

final isOfflineProvider = StateNotifierProvider<ConnectivityNotifier, bool>((ref) {
  final service = ref.watch(rommServiceProvider);
  return ConnectivityNotifier(service);
});

class ConnectivityNotifier extends StateNotifier<bool> {
  final RommService? _service;
  ConnectivityNotifier(this._service) : super(_service?.isOffline.value ?? true) {
    _service?.isOffline.addListener(_listener);
  }

  void _listener() {
    if (mounted) state = _service?.isOffline.value ?? true;
  }

  @override
  void dispose() {
    _service?.isOffline.removeListener(_listener);
    super.dispose();
  }
}

// ---------------------------------------------------------------------------
// Backup providers
// ---------------------------------------------------------------------------

/// Exposes the Hive-backed [BackupRepository].
final backupRepositoryProvider = Provider<BackupRepository>((ref) {
  final repo = BackupRepository();
  repo.initBox();
  return repo;
});

/// Lightweight service for creating and restoring local save backups.
final backupServiceProvider = Provider<BackupService>((ref) => BackupService());

