import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:romm_store/core/romm/romm_models.dart';
import 'package:romm_store/core/romm/romm_service.dart';
import 'package:romm_store/core/storage/directory_service.dart';
import 'package:romm_store/providers/library_provider.dart';
import 'package:romm_store/providers/paginated_games_provider.dart';
import 'package:romm_store/providers/romm_provider.dart';
import 'package:romm_store/providers/shared_prefs_provider.dart';
import 'package:romm_store/providers/ui_provider.dart';
import 'package:romm_store/ui/screens/library_screen.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:romm_store/core/storage/rom_mapping_service.dart';
import 'package:romm_store/core/romm/library_snapshot_service.dart';
import 'package:romm_store/core/storage/metadata_cache_service.dart';
import 'package:romm_store/core/ui/system_logo_resolver.dart';
import 'library_screen_test.mocks.dart';

@GenerateMocks([RommService, DirectoryService, RomMappingService, LibrarySnapshotService, MetadataCacheService])
void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await SystemLogoResolver.preload();
  });

  late MockRommService mockRommService;
  late MockDirectoryService mockDirectoryService;
  late MockRomMappingService mockRomMappingService;
  late MockLibrarySnapshotService mockSnapshotService;
  late MockMetadataCacheService mockCacheService;
  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    mockRommService = MockRommService();
    mockDirectoryService = MockDirectoryService();
    mockRomMappingService = MockRomMappingService();
    mockSnapshotService = MockLibrarySnapshotService();
    mockCacheService = MockMetadataCacheService();

    when(mockRommService.config).thenReturn(RomMConfig(baseUrl: 'https://test.com', username: 'u', password: 'p'));
    when(mockRommService.resolveCoverUrl(any)).thenReturn(null);
    when(mockRommService.getRecentlyPlayed(limit: anyNamed('limit'))).thenAnswer((_) async => []);
    when(mockRommService.getRecentlyAdded(limit: anyNamed('limit'))).thenAnswer((_) async => []);
    when(mockRommService.searchRoms(search: anyNamed('search'), platformId: anyNamed('platformId'))).thenAnswer((_) async => []);
    when(mockRommService.isOffline).thenReturn(ValueNotifier<bool>(false));
    when(mockDirectoryService.status).thenReturn(const StorageStatus());
    when(mockRomMappingService.getMappings()).thenReturn({});
    when(mockRomMappingService.getMTimes()).thenReturn({});
    when(mockSnapshotService.loadPlatforms()).thenAnswer((_) async => []);
    when(mockSnapshotService.loadCollections()).thenAnswer((_) async => []);
    when(mockCacheService.cachedGames).thenReturn([]);
  });

  group('LibraryScreen', () {
    testWidgets('shows loading skeleton while games are fetching', (WidgetTester tester) async {
      when(mockRommService.getPlatforms()).thenAnswer((_) async => []);

      await tester.pumpWidget(ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          rommServiceProvider.overrideWithValue(mockRommService),
          romMappingServiceProvider.overrideWith((ref) => Future.value(mockRomMappingService)),
          romScannerServiceProvider.overrideWithValue(null),
          directoryServiceProvider.overrideWith((ref) => Future.value(mockDirectoryService)),
          librarySnapshotServiceProvider.overrideWithValue(mockSnapshotService),
          metadataCacheServiceProvider.overrideWith((ref) => Future.value(mockCacheService)),
          platformsProvider.overrideWith((ref) async => <Platform>[]),
          startShellActionProvider.overrideWith((ref) => 'store'),
          paginatedGamesProvider.overrideWith((ref) => PaginatedGamesNotifier(ref)..state = const PaginatedGamesState(isLoading: true)),
        ],
        child: const MaterialApp(home: LibraryScreen()),
      ));

      await tester.pump();
      LibraryScreen.shellNavigatorKey.currentState!.pushNamed('/store');
      // Store skeleton GridView runs a repeating shimmer; pumpAndSettle never finishes.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.byType(GridView), findsOneWidget);
    });

    testWidgets('shows game grid when games are loaded', (WidgetTester tester) async {
      final games = [
        Game(id: '1', name: 'Game 1', platformDisplayName: 'GBA', fileSize: 0),
        Game(id: '2', name: 'Game 2', platformDisplayName: 'GBA', fileSize: 0),
      ];

      when(mockRommService.getPlatforms()).thenAnswer((_) async => []);
      when(mockDirectoryService.isRomDownloaded(any)).thenAnswer((_) async => false);

      await tester.pumpWidget(ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          rommServiceProvider.overrideWithValue(mockRommService),
          romMappingServiceProvider.overrideWith((ref) => Future.value(mockRomMappingService)),
          romScannerServiceProvider.overrideWithValue(null),
          directoryServiceProvider.overrideWith((ref) => Future.value(mockDirectoryService)),
          librarySnapshotServiceProvider.overrideWithValue(mockSnapshotService),
          metadataCacheServiceProvider.overrideWith((ref) => Future.value(mockCacheService)),
          platformsProvider.overrideWith((ref) async => <Platform>[]),
          startShellActionProvider.overrideWith((ref) => 'store'),
          paginatedGamesProvider.overrideWith((ref) => PaginatedGamesNotifier(ref)..state = PaginatedGamesState(games: games, total: 2, hasMore: false)),
        ],
        child: const MaterialApp(home: LibraryScreen()),
      ));

      await tester.pump();
      LibraryScreen.shellNavigatorKey.currentState!.pushNamed('/store');
      await tester.pumpAndSettle();

      expect(find.text('Game 1'), findsOneWidget);
      expect(find.text('Game 2'), findsOneWidget);
    });

    testWidgets('shows empty state when platform has no games', (WidgetTester tester) async {
      when(mockRommService.getPlatforms()).thenAnswer((_) async => []);

      await tester.pumpWidget(ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          rommServiceProvider.overrideWithValue(mockRommService),
          romMappingServiceProvider.overrideWith((ref) => Future.value(mockRomMappingService)),
          romScannerServiceProvider.overrideWithValue(null),
          directoryServiceProvider.overrideWith((ref) => Future.value(mockDirectoryService)),
          librarySnapshotServiceProvider.overrideWithValue(mockSnapshotService),
          metadataCacheServiceProvider.overrideWith((ref) => Future.value(mockCacheService)),
          platformsProvider.overrideWith((ref) async => <Platform>[]),
          startShellActionProvider.overrideWith((ref) => 'store'),
          paginatedGamesProvider.overrideWith((ref) => PaginatedGamesNotifier(ref)..state = const PaginatedGamesState(games: [], total: 0, hasMore: false)),
        ],
        child: const MaterialApp(home: LibraryScreen()),
      ));

      await tester.pump();
      LibraryScreen.shellNavigatorKey.currentState!.pushNamed('/store');
      await tester.pumpAndSettle();

      expect(find.text('No games found for this platform.'), findsOneWidget);
    });

    testWidgets('shows error state when RomM connection fails', (WidgetTester tester) async {
      when(mockRommService.getPlatforms()).thenAnswer((_) async => []);

      await tester.pumpWidget(ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          rommServiceProvider.overrideWithValue(mockRommService),
          romMappingServiceProvider.overrideWith((ref) => Future.value(mockRomMappingService)),
          romScannerServiceProvider.overrideWithValue(null),
          directoryServiceProvider.overrideWith((ref) => Future.value(mockDirectoryService)),
          librarySnapshotServiceProvider.overrideWithValue(mockSnapshotService),
          metadataCacheServiceProvider.overrideWith((ref) => Future.value(mockCacheService)),
          platformsProvider.overrideWith((ref) async => <Platform>[]),
          startShellActionProvider.overrideWith((ref) => 'store'),
          paginatedGamesProvider.overrideWith((ref) => PaginatedGamesNotifier(ref)..state = const PaginatedGamesState(error: 'Connection Failed')),
        ],
        child: const MaterialApp(home: LibraryScreen()),
      ));

      await tester.pump();
      LibraryScreen.shellNavigatorKey.currentState!.pushNamed('/store');
      await tester.pumpAndSettle();

      expect(find.text('Error: Connection Failed'), findsOneWidget);
    });
  });
}
