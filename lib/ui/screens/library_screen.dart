import 'dart:async';
import 'dart:io' as io show Platform, exit;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import '../../providers/library_provider.dart';
import '../../providers/romm_provider.dart';
import '../../providers/paginated_games_provider.dart';
import '../../providers/downloaded_games_cache_provider.dart';
import '../../core/storage/directory_service.dart';
import '../../core/ui/system_logo_resolver.dart';
import '../../core/romm/romm_models.dart';
import '../widgets/game_card.dart';
import 'library_skeleton.dart';
import 'game_detail_screen.dart';

import 'library_actions.dart';

import '../../providers/download_provider.dart';
import '../../providers/ui_provider.dart';
import '../../core/input/xinput_controller_service.dart';
import '../../core/input/controller_keymap.dart';
import '../../core/audio/ui_sfx_service.dart';
import '../library_focus_bridge.dart';
import '../widgets/start_top_action_strip.dart';
import 'download_screen.dart';
import 'friends_screen.dart';
import 'settings_screen.dart';

/// Desktop shells often ignore [SystemNavigator.pop]; mobile keeps using it.
void _terminateFlutterApplication() {
  if (kIsWeb) return;
  if (io.Platform.isWindows || io.Platform.isLinux || io.Platform.isMacOS) {
    io.exit(0);
  }
  SystemNavigator.pop();
}

class LibraryScreen extends ConsumerStatefulWidget {
  const LibraryScreen({super.key});

  /// Routes opened from the top strip (Store, Library, …) live under this navigator.
  static final GlobalKey<NavigatorState> shellNavigatorKey = GlobalKey<NavigatorState>();

  @override
  ConsumerState<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends ConsumerState<LibraryScreen> with LibraryActionsMixin {

  late TextEditingController _searchController;
  Timer? _storeSearchDebounce;
  final GlobalKey<RefreshIndicatorState> _refreshIndicatorKey =
      GlobalKey<RefreshIndicatorState>();
  late ScrollController _scrollController;
  /// Store page platform column — isolated from [_scrollController] so game-grid scroll never moves this list.
  final ScrollController _storePlatformScrollController = ScrollController();
  final List<FocusNode> _stripFocus = List.generate(6, (i) => FocusNode(debugLabel: 'strip_$i'));
  /// Home spotlight shelf — one node per tile for explicit Left/Right navigation.
  final List<FocusNode> _homeShelfGameFocusNodes = [];

  final FocusNode _storePlatformScopeFocus = FocusNode(debugLabel: 'store_platform_scope');
  final FocusNode _storeGameScopeFocus = FocusNode(debugLabel: 'store_game_scope');
  final FocusNode _storeAlphabetScopeFocus = FocusNode(debugLabel: 'store_alpha_scope');
  final FocusNode _storeSearchFocus = FocusNode(debugLabel: 'store_search_box');
  final FocusNode _downloadsShellFocus = FocusNode(debugLabel: 'downloads_shell_scope');
  final FocusNode _friendsShellFocus = FocusNode(debugLabel: 'friends_shell_scope');
  final FocusNode _settingsShellFocus = FocusNode(debugLabel: 'settings_shell_scope');

  static const List<String> _storeLetterBuckets = [
    '#',
    'A',
    'B',
    'C',
    'D',
    'E',
    'F',
    'G',
    'H',
    'I',
    'J',
    'K',
    'L',
    'M',
    'N',
    'O',
    'P',
    'Q',
    'R',
    'S',
    'T',
    'U',
    'V',
    'W',
    'X',
    'Y',
    'Z',
  ];

  int _storeGameFocusIndex = 0;
  int _storePlatformFocusIndex = 0;
  int _storeGridCols = 2;
  double _storeGridCellStride = 150;
  bool _storeAlphabetOpen = false;
  int _storeAlphabetLetterIndex = 0;
  int _storeSavedGameFocusIndex = 0;
  BuildContext? _storeShellRouteContext;

  /// After LB/RB or chip shelf tab change: focus first spotlight tile once nodes exist.
  bool _pendingHomeShelfFocusFirstGame = false;

  bool _libraryHardwareKey(KeyEvent event) {
    if (!mounted) return false;
    return _dispatchLibraryKey(event);
  }

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_libraryHardwareKey);
    _searchController = TextEditingController(text: ref.read(searchQueryProvider));
    _scrollController = ScrollController();
    _scrollController.addListener(_onScroll);
    LibraryFocusBridge.requestFocusHighlightBelow = () {
      if (!mounted || _homeShelfGameFocusNodes.isEmpty) return;
      _homeShelfGameFocusNodes.first.requestFocus();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _homeShelfGameFocusNodes.isEmpty) return;
        final ctx = _homeShelfGameFocusNodes.first.context;
        if (ctx != null && ctx.mounted) {
          Scrollable.ensureVisible(ctx, alignment: 0.35, duration: Duration.zero);
        }
      });
    };
    LibraryFocusBridge.requestFocusStripPrimary = () {
      if (!mounted) return;
      const order = ['home', 'store', 'downloads', 'friends', 'settings', 'exit'];
      final id = ref.read(startShellActionProvider);
      final idx = order.indexOf(id);
      if (idx >= 0 && idx < _stripFocus.length) {
        _stripFocus[idx].requestFocus();
      }
    };
    LibraryFocusBridge.stripFocusedTileIndex = _stripFocusedTileIndex;
    LibraryFocusBridge.moveStripFocusHorizontal = (delta) {
      if (!mounted || delta == 0) return;
      final i = _stripFocusedTileIndex();
      if (i == null) return;
      final next = (i + delta).clamp(0, _stripFocus.length - 1);
      if (next != i) _stripFocus[next].requestFocus();
    };
    LibraryFocusBridge.homeShelfHasFocusableGames = () => _homeShelfGameFocusNodes.isNotEmpty;
    LibraryFocusBridge.moveHomeShelfFocusHorizontal = (delta) {
      if (!mounted || delta == 0 || _homeShelfGameFocusNodes.isEmpty) return;
      final primary = FocusManager.instance.primaryFocus;
      final label = primary?.debugLabel ?? '';
      if (!label.startsWith('highlight_tile_')) return;
      final i = int.tryParse(label.substring('highlight_tile_'.length));
      if (i == null) return;
      final next = (i + delta).clamp(0, _homeShelfGameFocusNodes.length - 1);
      if (next != i) {
        _homeShelfGameFocusNodes[next].requestFocus();
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          final ctx = _homeShelfGameFocusNodes[next].context;
          if (ctx != null) {
            Scrollable.ensureVisible(ctx, alignment: 0.35, duration: Duration.zero);
          }
        });
      }
    };
    LibraryFocusBridge.requestFocusStorePlatforms = () {
      if (!mounted || ref.read(startShellActionProvider) != 'store') return;
      setState(() => _storeAlphabetOpen = false);
      final plist = ref.read(platformsProvider).valueOrNull ?? [];
      if (plist.isNotEmpty) {
        final sid = ref.read(selectedPlatformIdProvider);
        if (sid != null) {
          final selectedIdx = plist.indexWhere((p) => p.id == sid);
          if (selectedIdx >= 0) {
            _storePlatformFocusIndex = selectedIdx;
          }
        } else {
          _storePlatformFocusIndex = _storePlatformFocusIndex.clamp(0, plist.length - 1);
        }
      }
      _storePlatformScopeFocus.requestFocus();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final plist = ref.read(platformsProvider).valueOrNull ?? [];
        var idx = _storePlatformFocusIndex;
        if (plist.isNotEmpty) {
          idx = idx.clamp(0, plist.length - 1);
        }
        _scrollStorePlatformCenter(idx);
      });
    };
    LibraryFocusBridge.requestFocusDownloadsBody = () {
      if (!mounted) return;
      _downloadsShellFocus.requestFocus();
    };
    LibraryFocusBridge.requestFocusFriendsBody = () {
      if (!mounted) return;
      _friendsShellFocus.requestFocus();
    };
    LibraryFocusBridge.requestFocusSettingsBody = () {
      if (!mounted) return;
      _settingsShellFocus.requestFocus();
    };
    LibraryFocusBridge.consumeSettingsShellControllerAction =
        _consumeSettingsShellControllerAction;
    LibraryFocusBridge.consumeSettingsShellKeyEvent = _consumeSettingsShellKeyEvent;
    LibraryFocusBridge.consumeDownloadsShellControllerAction =
        _consumeDownloadsShellControllerAction;
    LibraryFocusBridge.consumeDownloadsShellKeyEvent = _consumeDownloadsShellKeyEvent;
    LibraryFocusBridge.consumeFriendsShellControllerAction =
        _consumeFriendsShellControllerAction;
    LibraryFocusBridge.consumeFriendsShellKeyEvent = _consumeFriendsShellKeyEvent;
    LibraryFocusBridge.consumeStoreControllerAction = _consumeStoreControllerAction;
    LibraryFocusBridge.consumeStoreKeyEvent = _consumeStoreKeyEvent;
    LibraryFocusBridge.requestFocusStoreGameGrid = () {
      if (!mounted || ref.read(startShellActionProvider) != 'store') return;
      _storeGameScopeFocus.requestFocus();
    };
    LibraryFocusBridge.requestFocusStoreSearch = () {
      if (!mounted || ref.read(startShellActionProvider) != 'store') return;
      _storeSearchFocus.requestFocus();
    };
    LibraryFocusBridge.returnFromGameDetailToStore = (int? platformId) {
      if (!mounted) return;
      if (platformId != null) {
        ref.read(selectedPlatformIdProvider.notifier).state = platformId;
      }
      _prepareStoreFilters();
      _goShellRoute('/store', 'store');
      WidgetsBinding.instance.addPostFrameCallback((_) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || ref.read(startShellActionProvider) != 'store') return;
          LibraryFocusBridge.requestFocusStoreGameGrid?.call();
        });
      });
    };
    LibraryFocusBridge.refocusHomeShelfAfterDetailPop = (String gameId) {
      if (!mounted) return;
      if (ref.read(startShellActionProvider) != 'home') return;
      final section = ref.read(storefrontSectionProvider);
      final games = switch (section) {
        'spotlight' => ref.read(recentlyPlayedProvider).valueOrNull ?? [],
        'new' => ref.read(recentlyAddedProvider).valueOrNull ?? [],
        'highlights' => ref.read(storefrontPopularGamesProvider).valueOrNull ?? [],
        _ => ref.read(recentlyPlayedProvider).valueOrNull ?? [],
      };
      final idx = games.indexWhere((g) => g.id == gameId);
      if (idx < 0 || idx >= _homeShelfGameFocusNodes.length) {
        LibraryFocusBridge.requestFocusHighlightBelow?.call();
        return;
      }
      _homeShelfGameFocusNodes[idx].requestFocus();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || idx >= _homeShelfGameFocusNodes.length) return;
        final ctx = _homeShelfGameFocusNodes[idx].context;
        if (ctx != null && ctx.mounted) {
          Scrollable.ensureVisible(ctx, alignment: 0.35, duration: Duration.zero);
        }
      });
    };
    LibraryFocusBridge.popShellHome = () {
      _popShellHome();
    };
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _stripFocus[0].requestFocus();
    });
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_libraryHardwareKey);
    LibraryFocusBridge.requestFocusHighlightBelow = null;
    LibraryFocusBridge.requestFocusStripPrimary = null;
    LibraryFocusBridge.stripFocusedTileIndex = null;
    LibraryFocusBridge.moveStripFocusHorizontal = null;
    LibraryFocusBridge.moveHomeShelfFocusHorizontal = null;
    LibraryFocusBridge.homeShelfHasFocusableGames = null;
    LibraryFocusBridge.requestFocusStorePlatforms = null;
    LibraryFocusBridge.requestFocusDownloadsBody = null;
    LibraryFocusBridge.requestFocusFriendsBody = null;
    LibraryFocusBridge.requestFocusSettingsBody = null;
    LibraryFocusBridge.consumeSettingsShellControllerAction = null;
    LibraryFocusBridge.consumeSettingsShellKeyEvent = null;
    LibraryFocusBridge.consumeDownloadsShellControllerAction = null;
    LibraryFocusBridge.consumeDownloadsShellKeyEvent = null;
    LibraryFocusBridge.consumeFriendsShellControllerAction = null;
    LibraryFocusBridge.consumeFriendsShellKeyEvent = null;
    LibraryFocusBridge.consumeStoreControllerAction = null;
    LibraryFocusBridge.consumeStoreKeyEvent = null;
    LibraryFocusBridge.requestFocusStoreGameGrid = null;
    LibraryFocusBridge.requestFocusStoreSearch = null;
    LibraryFocusBridge.returnFromGameDetailToStore = null;
    LibraryFocusBridge.refocusHomeShelfAfterDetailPop = null;
    LibraryFocusBridge.popShellHome = null;
    _storePlatformScopeFocus.dispose();
    _storeGameScopeFocus.dispose();
    _storeAlphabetScopeFocus.dispose();
    _storeSearchFocus.dispose();
    _downloadsShellFocus.dispose();
    _friendsShellFocus.dispose();
    _settingsShellFocus.dispose();
    for (final n in _stripFocus) {
      n.dispose();
    }
    for (final n in _homeShelfGameFocusNodes) {
      n.dispose();
    }
    _homeShelfGameFocusNodes.clear();
    _storeSearchDebounce?.cancel();
    _searchController.dispose();
    _scrollController.dispose();
    _storePlatformScrollController.dispose();
    super.dispose();
  }

  bool _focusIsInEditableText() {
    final ctx = FocusManager.instance.primaryFocus?.context;
    if (ctx == null) return false;
    return ctx.findAncestorStateOfType<EditableTextState>() != null;
  }

  /// Which top-strip tile owns primary focus — avoids relying on [FocusNode.debugLabel] alone.
  int? _stripFocusedTileIndex() {
    if (!mounted) return null;
    final primary = FocusManager.instance.primaryFocus;
    if (primary == null) return null;
    for (var k = 0; k < _stripFocus.length; k++) {
      if (_stripFocus[k] == primary) return k;
    }
    final label = primary.debugLabel ?? '';
    if (label.startsWith('strip_')) {
      return int.tryParse(label.substring('strip_'.length));
    }
    return null;
  }

  void _ensureHomeShelfFocusNodesSync(int count) {
    while (_homeShelfGameFocusNodes.length > count) {
      _homeShelfGameFocusNodes.removeLast().dispose();
    }
    while (_homeShelfGameFocusNodes.length < count) {
      final i = _homeShelfGameFocusNodes.length;
      _homeShelfGameFocusNodes.add(FocusNode(debugLabel: 'highlight_tile_$i'));
    }
  }

  void _consumePendingHomeShelfFocusIfNeeded() {
    if (!_pendingHomeShelfFocusFirstGame) return;
    if (_homeShelfGameFocusNodes.isEmpty) return;
    _pendingHomeShelfFocusFirstGame = false;
    // Two frames: wait for horizontal ListView + tiles to attach after provider swap.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _homeShelfGameFocusNodes.isEmpty) return;
        _homeShelfGameFocusNodes.first.requestFocus();
        final ctx = _homeShelfGameFocusNodes.first.context;
        if (ctx != null && ctx.mounted) {
          Scrollable.ensureVisible(ctx, alignment: 0.35, duration: Duration.zero);
        }
      });
    });
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    _maybeLoadMoreStoreGamesFromScroll(_scrollController.position);
  }

  void _applyStoreSearchQuery(String rawQuery) {
    final query = rawQuery.trim();
    ref.read(searchQueryProvider.notifier).state = query;
    ref.read(paginatedGamesProvider.notifier).loadInitial(
      platformId: ref.read(selectedPlatformIdProvider)?.toString(),
      search: query.isEmpty ? null : query,
    );
    if (mounted) {
      setState(() => _storeGameFocusIndex = 0);
    }
  }

  void _maybeLoadMoreStoreGamesFromScroll(ScrollMetrics metrics) {
    final state = ref.read(paginatedGamesProvider);
    if (!_canLoadMoreForSelectedStorePlatform(state)) return;
    if (metrics.pixels >= metrics.maxScrollExtent - 360) {
      ref.read(paginatedGamesProvider.notifier).loadMore();
    }
  }

  bool _canLoadMoreForSelectedStorePlatform(PaginatedGamesState state) {
    if (ref.read(startShellActionProvider) != 'store') return false;
    if (ref.read(selectedPlatformIdProvider) == null) return false;
    if (state.isLoading || state.isLoadingMore) return false;
    return state.hasMore;
  }

  void _continueLoadingAtStoreListEnd(PaginatedGamesState state) {
    if (!_canLoadMoreForSelectedStorePlatform(state)) return;
    if (!_scrollController.hasClients) return;
    final pos = _scrollController.position;
    final nearEnd = pos.pixels >= (pos.maxScrollExtent - 360);
    if (!nearEnd) return;
    ref.read(paginatedGamesProvider.notifier).loadMore();
  }

  /// Keyboard navigation for Library (see Xbox controller handling in [RommStoreApp]).
  bool _dispatchLibraryKey(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    if (_focusIsInEditableText()) return false;

    if (LibraryFocusBridge.consumeGameDetailKeyEvent?.call(event) ?? false) {
      return true;
    }

    if (LibraryFocusBridge.consumeSettingsShellKeyEvent?.call(event) ?? false) {
      return true;
    }

    if (LibraryFocusBridge.consumeDownloadsShellKeyEvent?.call(event) ?? false) {
      return true;
    }

    if (LibraryFocusBridge.consumeFriendsShellKeyEvent?.call(event) ?? false) {
      return true;
    }

    if (LibraryFocusBridge.consumeStoreKeyEvent?.call(event) ?? false) {
      return true;
    }

    final key = event.logicalKey;
    final focusScope = FocusScope.of(context);
    final hasTargetFocus = focusScope.focusedChild != null;

    final isUp = ControllerKeyMap.isUp(key);
    final isDown = ControllerKeyMap.isDown(key);
    final isLeft = ControllerKeyMap.isLeft(key);
    final isRight = ControllerKeyMap.isRight(key);

    // Top strip: Left/Right move between tiles only; Up does nothing; Down → shelf on Home when loaded.
    if (LibraryFocusBridge.stripRowHasPrimaryFocus()) {
      if (isLeft) {
        LibraryFocusBridge.moveStripFocusHorizontal?.call(-1);
        return true;
      }
      if (isRight) {
        LibraryFocusBridge.moveStripFocusHorizontal?.call(1);
        return true;
      }
      if (isUp) return true;
      if (isDown) {
        final shell = ref.read(startShellActionProvider);
        if (shell == 'home' && _homeShelfGameFocusNodes.isNotEmpty) {
          LibraryFocusBridge.requestFocusHighlightBelow?.call();
        } else if (shell == 'store') {
          LibraryFocusBridge.requestFocusStorePlatforms?.call();
        } else if (shell == 'downloads') {
          LibraryFocusBridge.requestFocusDownloadsBody?.call();
        } else if (shell == 'friends') {
          LibraryFocusBridge.requestFocusFriendsBody?.call();
        } else if (shell == 'settings') {
          LibraryFocusBridge.requestFocusSettingsBody?.call();
        } else {
          focusScope.focusInDirection(TraversalDirection.down);
        }
        return true;
      }
    }

    // Home spotlight shelf: Left/Right between games; Up → strip.
    if (LibraryFocusBridge.highlightRailHasPrimaryFocus()) {
      if (isLeft) {
        LibraryFocusBridge.moveHomeShelfFocusHorizontal?.call(-1);
        return true;
      }
      if (isRight) {
        LibraryFocusBridge.moveHomeShelfFocusHorizontal?.call(1);
        return true;
      }
      if (isUp) {
        LibraryFocusBridge.requestFocusStripPrimary?.call();
        return true;
      }
    }

    if (LibraryFocusBridge.friendsShellScopeHasPrimaryFocus() && isUp) {
      LibraryFocusBridge.requestFocusStripPrimary?.call();
      return true;
    }

    if (isUp || isDown || isLeft || isRight) {
      if (!hasTargetFocus) {
        focusScope.nextFocus();
        return true;
      }
      if (isUp) focusScope.focusInDirection(TraversalDirection.up);
      if (isDown) focusScope.focusInDirection(TraversalDirection.down);
      if (isLeft) focusScope.focusInDirection(TraversalDirection.left);
      if (isRight) focusScope.focusInDirection(TraversalDirection.right);
      return true;
    }

    if (ControllerKeyMap.isSelect(key)) {
      if (!hasTargetFocus) {
        focusScope.nextFocus();
        return true;
      }
      Actions.invoke(context, const ActivateIntent());
      return true;
    }

    if (ControllerKeyMap.isBack(key)) {
      if (LibraryFocusBridge.highlightRailHasPrimaryFocus()) {
        LibraryFocusBridge.requestFocusStripPrimary?.call();
        return true;
      }
      if (_popShellHome()) return true;
      Navigator.of(context).maybePop();
      return true;
    }

    if (ControllerKeyMap.isYOrRefresh(key)) {
      _refreshIndicatorKey.currentState?.show();
      return true;
    }

    return false;
  }

  void _unfocusEmbeddedShellScopes() {
    _storePlatformScopeFocus.unfocus();
    _storeGameScopeFocus.unfocus();
    _storeAlphabetScopeFocus.unfocus();
    _downloadsShellFocus.unfocus();
    _friendsShellFocus.unfocus();
    _settingsShellFocus.unfocus();
  }

  /// Pops the inner shell route (e.g. `/store`) to `/` and restores focus to the top strip.
  bool _popShellHome() {
    _unfocusEmbeddedShellScopes();
    final shellNav = LibraryScreen.shellNavigatorKey.currentState;
    if (shellNav == null || !shellNav.canPop()) return false;
    shellNav.pop();
    ref.read(startShellActionProvider.notifier).state = 'home';
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (ref.read(startShellActionProvider) != 'home') return;
      LibraryFocusBridge.requestFocusStripPrimary?.call();
    });
    return true;
  }

  bool _consumeSettingsShellControllerAction(ControllerAction action) {
    if (!mounted || ref.read(startShellActionProvider) != 'settings') return false;
    if (action != ControllerAction.back) return false;
    final shellNav = LibraryScreen.shellNavigatorKey.currentState;
    if (shellNav != null && shellNav.canPop()) {
      _popShellHome();
      return true;
    }
    return false;
  }

  bool _consumeSettingsShellKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    if (ref.read(startShellActionProvider) != 'settings') return false;
    final key = event.logicalKey;
    if (!ControllerKeyMap.isBack(key)) return false;
    final shellNav = LibraryScreen.shellNavigatorKey.currentState;
    if (shellNav != null && shellNav.canPop()) {
      _popShellHome();
      return true;
    }
    return false;
  }

  bool _consumeDownloadsShellControllerAction(ControllerAction action) {
    if (!mounted || ref.read(startShellActionProvider) != 'downloads') return false;
    if (LibraryFocusBridge.consumeDownloadsBodyControllerAction?.call(action) ?? false) {
      return true;
    }
    if (action != ControllerAction.back) return false;
    final shellNav = LibraryScreen.shellNavigatorKey.currentState;
    if (shellNav != null && shellNav.canPop()) {
      _popShellHome();
      return true;
    }
    return false;
  }

  bool _consumeDownloadsShellKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    if (ref.read(startShellActionProvider) != 'downloads') return false;
    if (LibraryFocusBridge.consumeDownloadsBodyKeyEvent?.call(event) ?? false) {
      return true;
    }
    final key = event.logicalKey;
    if (!ControllerKeyMap.isBack(key)) return false;
    final shellNav = LibraryScreen.shellNavigatorKey.currentState;
    if (shellNav != null && shellNav.canPop()) {
      _popShellHome();
      return true;
    }
    return false;
  }

  bool _consumeFriendsShellControllerAction(ControllerAction action) {
    if (!mounted || ref.read(startShellActionProvider) != 'friends') return false;
    if (LibraryFocusBridge.consumeFriendsBodyControllerAction?.call(action) ?? false) {
      return true;
    }
    if (action != ControllerAction.back) return false;
    final shellNav = LibraryScreen.shellNavigatorKey.currentState;
    if (shellNav != null && shellNav.canPop()) {
      _popShellHome();
      return true;
    }
    return false;
  }

  bool _consumeFriendsShellKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    if (ref.read(startShellActionProvider) != 'friends') return false;
    if (LibraryFocusBridge.consumeFriendsBodyKeyEvent?.call(event) ?? false) {
      return true;
    }
    final key = event.logicalKey;
    if (!ControllerKeyMap.isBack(key)) return false;
    final shellNav = LibraryScreen.shellNavigatorKey.currentState;
    if (shellNav != null && shellNav.canPop()) {
      _popShellHome();
      return true;
    }
    return false;
  }

  void _scrollStorePlatformCenter(int index) {
    if (!_storePlatformScrollController.hasClients) return;
    const approximateRowStride = 54.0;
    final vp = _storePlatformScrollController.position.viewportDimension;
    final centerOffset = index * approximateRowStride - vp / 2 + approximateRowStride / 2;
    final max = _storePlatformScrollController.position.maxScrollExtent;
    _storePlatformScrollController.jumpTo(centerOffset.clamp(0.0, max));
  }

  void _scrollGameGridToFocusedIndex() {
    if (!_scrollController.hasClients || _storeGridCols <= 0) return;
    final games = ref.read(paginatedGamesProvider).games;
    if (games.isEmpty) return;
    final idx = _storeGameFocusIndex.clamp(0, games.length - 1);
    final row = idx ~/ _storeGridCols;
    final vp = _scrollController.position.viewportDimension;
    final target = row * _storeGridCellStride - vp / 2 + _storeGridCellStride / 2;
    final max = _scrollController.position.maxScrollExtent;
    _scrollController.jumpTo(target.clamp(0.0, max));
  }

  /// LT/RT fast scroll on Store when focus is in the game grid (not A–Z overlay).
  bool _tryFastScrollStoreGameGrid({required bool pageDown}) {
    if (_storeAlphabetOpen) return false;
    final selectedPlatformId = ref.read(selectedPlatformIdProvider);
    if (selectedPlatformId == null) return false;
    final platformScopeActive =
        _storePlatformScopeFocus.hasFocus || LibraryFocusBridge.storePlatformScopeHasPrimaryFocus();
    final alphabetScopeActive =
        _storeAlphabetOpen ||
        _storeAlphabetScopeFocus.hasFocus ||
        LibraryFocusBridge.storeAlphabetScopeHasPrimaryFocus();
    final gameScopeActive =
        _storeGameScopeFocus.hasFocus || LibraryFocusBridge.storeGameScopeHasPrimaryFocus();
    final implicitGameScope = !platformScopeActive && !alphabetScopeActive;
    if (!gameScopeActive && !implicitGameScope) return false;
    if (!gameScopeActive) {
      _storeGameScopeFocus.requestFocus();
    }
    if (!_scrollController.hasClients) return false;
    final cols = _storeGridCols.clamp(1, 40);
    if (cols <= 0) return false;
    final games = ref.read(paginatedGamesProvider).games;
    if (games.isEmpty) return false;

    final stride = _storeGridCellStride;
    if (stride <= 0) return false;

    final pos = _scrollController.position;
    final step = pos.viewportDimension * 0.55;
    final next = (pos.pixels + (pageDown ? step : -step)).clamp(0.0, pos.maxScrollExtent);
    _scrollController.jumpTo(next);

    final maxRow = (games.length - 1) ~/ cols;
    final firstRow = (next / stride).floor().clamp(0, maxRow);
    final col = _storeGameFocusIndex % cols;
    setState(() {
      _storeGameFocusIndex = (firstRow * cols + col).clamp(0, games.length - 1);
    });

    final paginated = ref.read(paginatedGamesProvider);
    if (pageDown && paginated.hasMore && !paginated.isLoadingMore) {
      if (pos.maxScrollExtent - next < 600) {
        ref.read(paginatedGamesProvider.notifier).loadMore();
      }
    }
    return true;
  }

  void _moveStorePlatformVertical(int delta) {
    final platforms = ref.read(platformsProvider).valueOrNull ?? [];
    if (platforms.isEmpty) return;
    var i = _storePlatformFocusIndex.clamp(0, platforms.length - 1);
    final next = (i + delta).clamp(0, platforms.length - 1);
    if (next == i) return;
    setState(() => _storePlatformFocusIndex = next);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _scrollStorePlatformCenter(next);
    });
  }

  void _moveStoreGameGrid(TraversalDirection dir) {
    final paginated = ref.read(paginatedGamesProvider);
    final games = paginated.games;
    final len = games.length;
    if (len == 0) return;
    final cols = _storeGridCols.clamp(1, 40);
    var idx = _storeGameFocusIndex.clamp(0, len - 1);
    final row = idx ~/ cols;
    final col = idx % cols;
    final maxRow = (len - 1) ~/ cols;

    if (dir == TraversalDirection.left) {
      if (col <= 0) return;
      idx -= 1;
    } else if (dir == TraversalDirection.right) {
      if (col >= cols - 1) return;
      final nr = idx + 1;
      if (nr >= len) return;
      idx = nr;
    } else if (dir == TraversalDirection.up) {
      final prevLinear = idx - cols;
      if (prevLinear < 0) return;
      idx = prevLinear;
    } else if (dir == TraversalDirection.down) {
      final nextLinear = idx + cols;
      if (nextLinear < len) {
        idx = nextLinear;
      } else if (row < maxRow) {
        final bottomStart = (row + 1) * cols;
        if (bottomStart < len) {
          final span = len - bottomStart;
          final targetCol = col.clamp(0, span - 1);
          idx = bottomStart + targetCol;
        }
      } else if (paginated.hasMore && !paginated.isLoadingMore) {
        ref.read(paginatedGamesProvider.notifier).loadMore();
        return;
      } else {
        return;
      }
    }

    setState(() => _storeGameFocusIndex = idx.clamp(0, len - 1));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _scrollGameGridToFocusedIndex();
    });
  }

  void _moveAlphabetLetter(int delta) {
    setState(() {
      _storeAlphabetLetterIndex =
          (_storeAlphabetLetterIndex + delta).clamp(0, _storeLetterBuckets.length - 1);
    });
  }

  int _bucketIndexForGame(Game g) {
    for (var i = 0; i < _storeLetterBuckets.length; i++) {
      if (PaginatedGamesNotifier.letterBucketMatches(g, _storeLetterBuckets[i])) return i;
    }
    return 0;
  }

  void _openStoreAlphabetFromGameList() {
    // A-Z jump is only meaningful when a platform is selected and there are visible games.
    if (ref.read(selectedPlatformIdProvider) == null) return;
    final games = ref.read(paginatedGamesProvider).games;
    if (games.isEmpty) return;
    var letterIdx = 0;
    final safeIdx = _storeGameFocusIndex.clamp(0, games.length - 1);
    letterIdx = _bucketIndexForGame(games[safeIdx]);
    setState(() {
      _storeAlphabetOpen = true;
      _storeSavedGameFocusIndex = _storeGameFocusIndex;
      _storeAlphabetLetterIndex = letterIdx;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _storeAlphabetScopeFocus.requestFocus();
    });
  }

  void _dismissStoreAlphabet() {
    setState(() {
      _storeAlphabetOpen = false;
      _storeGameFocusIndex = _storeSavedGameFocusIndex;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _storeGameScopeFocus.requestFocus();
    });
  }

  /// Clears pinned platform filter (same as toolbar “all platforms”). No-op if already unset.
  void _maybeClearStorePlatformFilter() {
    final sid = ref.read(selectedPlatformIdProvider);
    if (sid == null) return;
    ref.read(selectedPlatformIdProvider.notifier).state = null;
    ref.read(paginatedGamesProvider.notifier).loadInitial(
      platformId: null,
      search: ref.read(searchQueryProvider).isEmpty ? null : ref.read(searchQueryProvider),
    );
  }

  Future<void> _confirmAlphabetJump() async {
    if (ref.read(selectedPlatformIdProvider) == null) return;
    final bucket = _storeLetterBuckets[_storeAlphabetLetterIndex];
    final idx = await ref.read(paginatedGamesProvider.notifier).jumpToLetterBucket(bucket);
    if (!mounted) return;
    setState(() {
      _storeAlphabetOpen = false;
      if (idx != null) _storeGameFocusIndex = idx;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _storeGameScopeFocus.requestFocus();
      _scrollGameGridToFocusedIndex();
    });
  }

  Future<void> _jumpToLetterBucketFromPointer(int index) async {
    if (ref.read(selectedPlatformIdProvider) == null) return;
    setState(() {
      _storeAlphabetLetterIndex = index.clamp(0, _storeLetterBuckets.length - 1);
      // Pointer clicks should work even if the X-button alphabet overlay is not open.
      _storeAlphabetOpen = true;
    });
    await _confirmAlphabetJump();
  }

  bool _consumeStoreControllerAction(ControllerAction action) {
    if (!mounted || ref.read(startShellActionProvider) != 'store') return false;

    if (action == ControllerAction.openSearch) {
      _storeSearchFocus.requestFocus();
      return true;
    }

    if (action == ControllerAction.scrollPageUp || action == ControllerAction.scrollPageDown) {
      if (_tryFastScrollStoreGameGrid(pageDown: action == ControllerAction.scrollPageDown)) {
        return true;
      }
    }

    // Y (refresh): clear pinned platform anywhere on Store route (matches toolbar filter-off).
    if (action == ControllerAction.refresh) {
      _maybeClearStorePlatformFilter();
      return true;
    }

    if (_storeAlphabetOpen || _storeAlphabetScopeFocus.hasFocus) {
      switch (action) {
        case ControllerAction.left:
          _moveAlphabetLetter(-1);
          return true;
        case ControllerAction.right:
          _moveAlphabetLetter(1);
          return true;
        case ControllerAction.up:
        case ControllerAction.down:
        case ControllerAction.alphabetJump:
          return true;
        case ControllerAction.select:
          unawaited(_confirmAlphabetJump());
          return true;
        case ControllerAction.back:
          _dismissStoreAlphabet();
          return true;
        case ControllerAction.refresh:
        case ControllerAction.previousSection:
        case ControllerAction.nextSection:
        case ControllerAction.scrollPageUp:
        case ControllerAction.scrollPageDown:
        case ControllerAction.openSearch:
          return false;
      }
    }

    if (_storePlatformScopeFocus.hasFocus || LibraryFocusBridge.storePlatformScopeHasPrimaryFocus()) {
      switch (action) {
        case ControllerAction.up:
          final platforms = ref.read(platformsProvider).valueOrNull ?? [];
          if (platforms.isEmpty) return true;
          final i = _storePlatformFocusIndex.clamp(0, platforms.length - 1);
          if (i > 0) {
            _moveStorePlatformVertical(-1);
          }
          return true;
        case ControllerAction.down:
          _moveStorePlatformVertical(1);
          return true;
        case ControllerAction.left:
          return true;
        case ControllerAction.right:
          // Move from platform filter bar into the game list when a platform is selected.
          if (ref.read(selectedPlatformIdProvider) != null) {
            _storeGameScopeFocus.requestFocus();
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) _scrollGameGridToFocusedIndex();
            });
          }
          return true;
        case ControllerAction.select:
          final platforms = ref.read(platformsProvider).valueOrNull ?? [];
          if (platforms.isEmpty) return true;
          final i = _storePlatformFocusIndex.clamp(0, platforms.length - 1);
          final selected = platforms[i];
          ref.read(selectedPlatformIdProvider.notifier).state = selected.id;
          setState(() => _storeGameFocusIndex = 0);
          ref.read(paginatedGamesProvider.notifier).loadInitial(
                platformId: selected.id.toString(),
                search: ref.read(searchQueryProvider).isEmpty ? null : ref.read(searchQueryProvider),
              );
          _storeGameScopeFocus.requestFocus();
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _scrollGameGridToFocusedIndex();
          });
          return true;
        case ControllerAction.back:
          _popShellHome();
          return true;
        case ControllerAction.alphabetJump:
          return true;
        case ControllerAction.refresh:
        case ControllerAction.previousSection:
        case ControllerAction.nextSection:
        case ControllerAction.scrollPageUp:
        case ControllerAction.scrollPageDown:
        case ControllerAction.openSearch:
          return false;
      }
    }

    final selectedPlatformId = ref.read(selectedPlatformIdProvider);
    final platformScopeActive =
        _storePlatformScopeFocus.hasFocus || LibraryFocusBridge.storePlatformScopeHasPrimaryFocus();
    final alphabetScopeActive =
        _storeAlphabetOpen ||
        _storeAlphabetScopeFocus.hasFocus ||
        LibraryFocusBridge.storeAlphabetScopeHasPrimaryFocus();
    final gameScopeActive =
        _storeGameScopeFocus.hasFocus || LibraryFocusBridge.storeGameScopeHasPrimaryFocus();

    // Fallback: when a platform is selected and focus drifts off explicit game-scope node,
    // keep routing D-pad/A/B to the game list (unless platform or alphabet scopes are active).
    final implicitGameScope = selectedPlatformId != null && !platformScopeActive && !alphabetScopeActive;

    if (gameScopeActive || implicitGameScope) {
      if (!gameScopeActive) {
        _storeGameScopeFocus.requestFocus();
      }
      switch (action) {
        case ControllerAction.up:
          _moveStoreGameGrid(TraversalDirection.up);
          return true;
        case ControllerAction.down:
          _moveStoreGameGrid(TraversalDirection.down);
          return true;
        case ControllerAction.left:
          _moveStoreGameGrid(TraversalDirection.left);
          return true;
        case ControllerAction.right:
          _moveStoreGameGrid(TraversalDirection.right);
          return true;
        case ControllerAction.select:
          final games = ref.read(paginatedGamesProvider).games;
          if (games.isEmpty) return true;
          final i = _storeGameFocusIndex.clamp(0, games.length - 1);
          final ctx = _storeShellRouteContext;
          if (ctx != null && ctx.mounted) {
            unawaited(_handleGameTap(ctx, ref, games[i]));
          }
          return true;
        case ControllerAction.back:
          _storePlatformScopeFocus.requestFocus();
          return true;
        case ControllerAction.alphabetJump:
          _openStoreAlphabetFromGameList();
          return true;
        case ControllerAction.refresh:
        case ControllerAction.previousSection:
        case ControllerAction.nextSection:
        case ControllerAction.scrollPageUp:
        case ControllerAction.scrollPageDown:
        case ControllerAction.openSearch:
          return false;
      }
    }

    return false;
  }

  bool _consumeStoreKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    if (ref.read(startShellActionProvider) != 'store') return false;

    final key = event.logicalKey;
    final mapped = ControllerKeyMap.toControllerAction(key);

    if (mapped != null) return _consumeStoreControllerAction(mapped);
    return false;
  }

  /// Tight square grid for the store browse pane (narrower than full-library width).
  int _storeGridColumnCount(double maxWidth, double spacing) {
    if (maxWidth <= 0) return 2;
    const targetTile = 136.0;
    final n = ((maxWidth + spacing) / (targetTile + spacing)).floor();
    return n.clamp(2, 10);
  }

  String _storefrontSectionTitle(String key) {
    switch (key) {
      case 'spotlight':
        return 'Spotlight';
      case 'new':
        return "What's New";
      case 'highlights':
        return 'Highlights';
      default:
        return 'Browse';
    }
  }

  void _prepareStoreFilters() {
    final f = ref.read(activeFiltersProvider);
    if (f.downloadedOnly) {
      final cleared = f.copyWith(downloadedOnly: false);
      ref.read(activeFiltersProvider.notifier).state = cleared;
      ref.read(paginatedGamesProvider.notifier).reset();
      ref.read(paginatedGamesProvider.notifier).setFilters(cleared);
      ref.read(paginatedGamesProvider.notifier).loadInitial(
            platformId: ref.read(selectedPlatformIdProvider)?.toString(),
            search: ref.read(searchQueryProvider).isEmpty ? null : ref.read(searchQueryProvider),
          );
    }
  }

  void _goShellRoute(String routeName, String stripId) {
    final nav = LibraryScreen.shellNavigatorKey.currentState;
    if (nav == null) return;
    ref.read(startShellActionProvider.notifier).state = stripId;
    nav.popUntil((r) => r.isFirst);
    if (routeName != '/') {
      nav.pushNamed(routeName);
    }
  }

  void _activateStrip(BuildContext context, String action) {
    switch (action) {
      case 'home':
        _goShellRoute('/', 'home');
        break;
      case 'store':
        ref.read(selectedPlatformIdProvider.notifier).state = null;
        setState(() {
          _storePlatformFocusIndex = 0;
          _storeGameFocusIndex = 0;
        });
        _prepareStoreFilters();
        _goShellRoute('/store', 'store');
        WidgetsBinding.instance.addPostFrameCallback((_) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted || ref.read(startShellActionProvider) != 'store') return;
            LibraryFocusBridge.requestFocusStorePlatforms?.call();
          });
        });
        break;
      case 'downloads':
        _goShellRoute('/downloads', 'downloads');
        WidgetsBinding.instance.addPostFrameCallback((_) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            LibraryFocusBridge.requestFocusDownloadsBody?.call();
          });
        });
        break;
      case 'settings':
        _goShellRoute('/settings', 'settings');
        WidgetsBinding.instance.addPostFrameCallback((_) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            LibraryFocusBridge.requestFocusSettingsBody?.call();
          });
        });
        break;
      case 'friends':
        _goShellRoute('/friends', 'friends');
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _friendsShellFocus.requestFocus();
        });
        break;
      case 'exit':
        _promptExit();
        break;
      default:
        break;
    }
  }

  Future<void> _promptExit() async {
    UiSfxService.instance.play(UiSfx.popup);
    final shouldExit = await showDialog<bool>(
      context: context,
      builder: (context) => const _ExitConfirmDialog(),
    );

    if (shouldExit == true) {
      _terminateFlutterApplication();
    }
  }

  Future<void> _refreshLibrary() async {
    ref.invalidate(platformsProvider);
    ref.invalidate(recentlyAddedProvider);
    ref.invalidate(recentlyPlayedProvider);
    ref.invalidate(storefrontPopularGamesProvider);
    ref.read(paginatedGamesProvider.notifier).reset();
    await ref.read(paginatedGamesProvider.notifier).loadInitial(
      platformId: ref.read(selectedPlatformIdProvider)?.toString(),
      search: ref.read(searchQueryProvider).isEmpty ? null : ref.read(searchQueryProvider),
    );
    await ref.read(downloadedGamesCacheProvider.notifier).refresh();
  }

  Future<void> _handleGameTap(
    BuildContext context,
    WidgetRef ref,
    Game game, {
    GameDetailExitDestination exitDestination = GameDetailExitDestination.storeGameGrid,
  }) async {
    final config = ref.read(rommConfigProvider).value;
    final baseUrl = config?.baseUrl ?? '';
    final downloads = ref.read(downloadProvider);
    // CRITICAL: Active download always blocks Playable state
    final isActuallyDownloading = downloads.containsKey(game.id);
    final isDownloaded = (ref.read(downloadedGamesCacheProvider)[game.id] ?? false) && !isActuallyDownloading;

    await Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute(
        builder: (context) => GameDetailScreen(
          game: game,
          rommBaseUrl: baseUrl,
          isDownloaded: isDownloaded,
          rommService: ref.read(rommServiceProvider),
          onDownload: () => startDownload(context, ref, game),
          onDelete: () => handleDeleteRom(context, ref, game, skipConfirmation: true),
          exitDestination: exitDestination,
        ),
      ),
    );
    
    if (mounted) {
      await ref.read(downloadedGamesCacheProvider.notifier).refresh();
    }
  }

  Route<dynamic>? _generateShellRoute(RouteSettings settings) {
    final name = settings.name ?? '/';
    return MaterialPageRoute<void>(
      settings: settings,
      builder: (routeContext) => _shellPageWithRomGate(routeContext, name),
    );
  }

  /// Shown inside the shell [Navigator] when RomM is not configured — keeps [shellNavigatorKey] valid
  /// so top-strip navigation (Home / Store / …) always runs [_goShellRoute].
  Widget _rommSetupRequiredBody(BuildContext routeContext) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.settings_outlined, size: 64, color: Colors.grey),
          const SizedBox(height: 24),
          const Text(
            'Setup Required',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          const Text(
            'Please configure your RomM server in Settings.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey),
          ),
          const SizedBox(height: 24),
          ElevatedButton(
            onPressed: () {
              ref.read(currentTabIndexProvider.notifier).state = 2;
            },
            child: const Text('Go to Settings'),
          ),
        ],
      ),
    );
  }

  Widget _shellPageWithRomGate(BuildContext routeContext, String name) {
    final service = ref.watch(rommServiceProvider);
    if (service == null) {
      return _rommSetupRequiredBody(routeContext);
    }
    return _shellPageForRoute(routeContext, name);
  }

  Widget _shellPageForRoute(BuildContext routeContext, String name) {
    switch (name) {
      case '/':
        return _shellHomeBody(routeContext);
      case '/store':
        return _shellStoreBody(routeContext);
      case '/downloads':
        return DownloadScreen(embeddedShell: true, shellFocusNode: _downloadsShellFocus);
      case '/friends':
        return _shellFriendsBody(routeContext);
      case '/settings':
        return SettingsScreen(embeddedShell: true, shellFocusNode: _settingsShellFocus);
      default:
        return _shellHomeBody(routeContext);
    }
  }

  Widget _shellFriendsBody(BuildContext routeContext) {
    return FriendsScreen(embeddedShell: true, shellFocusNode: _friendsShellFocus);
  }

  Widget _stripFilterToolbar(BuildContext routeContext) {
    return const SizedBox.shrink();
  }

  Widget _paginatedErrorPlaceholder(BuildContext routeContext, String message) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.error_outline, color: Colors.red, size: 48),
          const SizedBox(height: 16),
          Text(
            message,
            style: const TextStyle(color: Colors.red),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          ElevatedButton(
            onPressed: () {
              ref.invalidate(rommServiceProvider);
              ref.read(paginatedGamesProvider.notifier).loadInitial(
                    platformId: ref.read(selectedPlatformIdProvider)?.toString(),
                    search: ref.read(searchQueryProvider),
                  );
            },
            child: const Text('Retry'),
          ),
        ],
      ),
    );
  }

  Widget _shellHomeBody(BuildContext routeContext) {
    final section = ref.watch(storefrontSectionProvider);
    final downloadedCache = ref.watch(downloadedGamesCacheProvider);
    final showTitle = ref.watch(showTitleProvider);
    final gamesAsync = switch (section) {
      'spotlight' => ref.watch(recentlyPlayedProvider),
      'new' => ref.watch(recentlyAddedProvider),
      'highlights' => ref.watch(storefrontPopularGamesProvider),
      _ => ref.watch(recentlyPlayedProvider),
    };

    return RefreshIndicator(
      key: _refreshIndicatorKey,
      onRefresh: _refreshLibrary,
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ExcludeFocus(
              child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final sid in ['spotlight', 'new', 'highlights'])
                  ChoiceChip(
                    label: Text(_storefrontSectionTitle(sid)),
                    selected: section == sid,
                    labelStyle: TextStyle(
                      color: section == sid ? Colors.white : Colors.white70,
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                    ),
                    selectedColor: const Color(0xFF2B4A72),
                    backgroundColor: const Color(0xFF122033),
                    side: BorderSide(color: Colors.white.withValues(alpha: section == sid ? 0.35 : 0.12)),
                    showCheckmark: false,
                    onSelected: (_) => ref.read(storefrontSectionProvider.notifier).state = sid,
                  ),
              ],
              ),
            ),
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: Text(
                    _storefrontSectionTitle(section),
                    style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            SizedBox(
              height: 268,
              child: gamesAsync.when(
                loading: () {
                  _ensureHomeShelfFocusNodesSync(0);
                  _consumePendingHomeShelfFocusIfNeeded();
                  return const Center(child: CircularProgressIndicator());
                },
                error: (e, _) {
                  _ensureHomeShelfFocusNodesSync(0);
                  _consumePendingHomeShelfFocusIfNeeded();
                  return Center(
                    child: Text(
                      'Could not load shelf: $e',
                      style: const TextStyle(color: Colors.white70),
                      textAlign: TextAlign.center,
                    ),
                  );
                },
                data: (games) {
                  if (games.isEmpty) {
                    _ensureHomeShelfFocusNodesSync(0);
                    _consumePendingHomeShelfFocusIfNeeded();
                    return const Center(
                      child: Text(
                        'Nothing here yet.',
                        style: TextStyle(color: Colors.white60),
                      ),
                    );
                  }
                  _ensureHomeShelfFocusNodesSync(games.length);
                  _consumePendingHomeShelfFocusIfNeeded();
                  return ListView.separated(
                    key: ValueKey<String>(section),
                    scrollDirection: Axis.horizontal,
                    itemCount: games.length,
                    separatorBuilder: (context, _) => const SizedBox(width: 12),
                    itemBuilder: (context, index) {
                      final game = games[index];
                      final downloads = ref.watch(downloadProvider);
                      final isActuallyDownloading = downloads.containsKey(game.id);
                      final isDownloaded =
                          (downloadedCache[game.id] ?? false) && !isActuallyDownloading;
                      final coverUrl = ref.read(rommServiceProvider)?.resolveCoverUrl(game);
                      final platformLogoUrl = game.platformSlug != null
                          ? '${ref.read(rommConfigProvider).value?.baseUrl ?? ''}/assets/platforms/${game.platformSlug}.svg'
                          : null;
                      return Actions(
                        actions: <Type, Action<Intent>>{
                          ActivateIntent: CallbackAction<ActivateIntent>(
                            onInvoke: (_) {
                              _handleGameTap(
                                routeContext,
                                ref,
                                game,
                                exitDestination: GameDetailExitDestination.callerShell,
                              );
                              return null;
                            },
                          ),
                        },
                        child: Focus(
                          focusNode: _homeShelfGameFocusNodes[index],
                          child: Builder(
                            builder: (focusCtx) {
                              final hl = Focus.of(focusCtx).hasFocus;
                              return Material(
                                color: Colors.transparent,
                                child: InkWell(
                                  onTap: () => _handleGameTap(
                                        routeContext,
                                        ref,
                                        game,
                                        exitDestination: GameDetailExitDestination.callerShell,
                                      ),
                                  canRequestFocus: false,
                                  borderRadius: BorderRadius.circular(12),
                                  child: AnimatedContainer(
                                    duration: const Duration(milliseconds: 100),
                                    decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(12),
                                      border: hl
                                          ? Border.all(color: const Color(0xFF6FA8FF), width: 2)
                                          : null,
                                    ),
                                    child: SizedBox(
                                      width: 148,
                                      child: GameCard(
                                        game: game,
                                        coverUrl: coverUrl,
                                        isDownloaded: isDownloaded,
                                        platformLogoUrl: platformLogoUrl,
                                        showTitle: showTitle,
                                      ),
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _shellStoreBody(BuildContext routeContext) {
    _storeShellRouteContext = routeContext;
    final paginatedState = ref.watch(paginatedGamesProvider);
    final platformsAsync = ref.watch(platformsProvider);
    final selectedPlatformId = ref.watch(selectedPlatformIdProvider);
    final downloadedCache = ref.watch(downloadedGamesCacheProvider);
    final displayGames = paginatedState.games;
    final cardSpacing = ref.watch(cardSpacingProvider);
    final showTitle = ref.watch(showTitleProvider);

    if (selectedPlatformId != null && paginatedState.isLoading && displayGames.isEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ExcludeFocus(child: _stripFilterToolbar(routeContext)),
          Expanded(
            child: buildSkeletonGrid(
              ref.watch(cardAspectRatioProvider),
              ref.watch(columnCountProvider),
              ref.watch(cardSpacingProvider),
              routeContext,
              showTitle: ref.watch(showTitleProvider),
            ),
          ),
        ],
      );
    }

    if (selectedPlatformId != null &&
        paginatedState.error != null &&
        !paginatedState.error!.contains('Offline Mode')) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ExcludeFocus(child: _stripFilterToolbar(routeContext)),
          Expanded(child: _paginatedErrorPlaceholder(routeContext, 'Error: ${paginatedState.error}')),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ExcludeFocus(child: _stripFilterToolbar(routeContext)),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
            child: Row(
              children: [
                SizedBox(
                  width: 240,
                  child: Focus(
                    focusNode: _storePlatformScopeFocus,
                    child: Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: const Color(0xFF0C1828),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: const Color(0xFF1E3550)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Platforms',
                            style: TextStyle(fontWeight: FontWeight.w800),
                          ),
                          const SizedBox(height: 8),
                          Expanded(
                            child: platformsAsync.when(
                              data: (platforms) {
                                if (platforms.isEmpty) {
                                  return const Align(
                                    alignment: Alignment.topLeft,
                                    child: Text(
                                      'No platforms loaded.',
                                      style: TextStyle(color: Colors.white54, fontSize: 12),
                                    ),
                                  );
                                }
                                return ScrollConfiguration(
                                  behavior: ScrollConfiguration.of(routeContext).copyWith(
                                    scrollbars: false,
                                  ),
                                  child: ListView.separated(
                                    controller: _storePlatformScrollController,
                                    primary: false,
                                    itemCount: platforms.length,
                                    separatorBuilder: (context, index) => const SizedBox(height: 6),
                                    itemBuilder: (context, index) {
                                      final platform = platforms[index];
                                      final selected = selectedPlatformId == platform.id;
                                      final focused =
                                          _storePlatformScopeFocus.hasFocus &&
                                          index == _storePlatformFocusIndex;
                                      return GestureDetector(
                                        onTap: () {
                                          setState(() {
                                            _storePlatformFocusIndex = index;
                                            _storeGameFocusIndex = 0;
                                          });
                                          ref.read(selectedPlatformIdProvider.notifier).state =
                                              platform.id;
                                          ref.read(paginatedGamesProvider.notifier).loadInitial(
                                                platformId: platform.id.toString(),
                                              );
                                        },
                                        child: AnimatedContainer(
                                          duration: const Duration(milliseconds: 80),
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 10, vertical: 8),
                                          decoration: BoxDecoration(
                                            color: selected
                                                ? const Color(0xFF2B4A72)
                                                : const Color(0xFF122033),
                                            borderRadius: BorderRadius.circular(8),
                                            border: Border.all(
                                              color: focused
                                                  ? const Color(0xFF6FA8FF)
                                                  : Colors.transparent,
                                              width: focused ? 2 : 0,
                                            ),
                                          ),
                                          child: Row(
                                            children: [
                                              SizedBox(
                                                width: 130,
                                                height: 24,
                                                child: Image.asset(
                                                  SystemLogoResolver.assetPathForPlatform(
                                                        displayName: platform.nameForDisplay,
                                                        slug: platform.slug,
                                                        fsSlug: platform.fsSlug,
                                                        fallbackName: platform.name,
                                                      ) ??
                                                      '${SystemLogoResolver.prefix}${platform.nameForDisplay}.png',
                                                  fit: BoxFit.contain,
                                                  alignment: Alignment.centerLeft,
                                                  errorBuilder: (context, error, stackTrace) {
                                                    return Text(
                                                      platform.nameForDisplay,
                                                      maxLines: 1,
                                                      overflow: TextOverflow.ellipsis,
                                                      style: TextStyle(
                                                        color: selected
                                                            ? Colors.white
                                                            : Colors.white70,
                                                        fontWeight: selected
                                                            ? FontWeight.w700
                                                            : FontWeight.w500,
                                                      ),
                                                    );
                                                  },
                                                ),
                                              ),
                                              const Spacer(),
                                              Text(
                                                '${platform.gamesCount}',
                                                style: TextStyle(
                                                  fontSize: 11,
                                                  color: selected
                                                      ? Colors.white70
                                                      : Colors.white54,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      );
                                    },
                                  ),
                                );
                              },
                              loading: () => const Center(child: CircularProgressIndicator()),
                              error: (e, s) => Text('Error: $e'),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Focus(
                    focusNode: _storeGameScopeFocus,
                    child: Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: const Color(0xFF0C1828),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: const Color(0xFF1E3550)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Expanded(
                                child: Text(
                                  'Game list',
                                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
                                ),
                              ),
                              SizedBox(
                                width: 320,
                                child: TextField(
                                  focusNode: _storeSearchFocus,
                                  controller: _searchController,
                                  textInputAction: TextInputAction.search,
                                  onChanged: (value) {
                                    if (mounted) setState(() {});
                                    _storeSearchDebounce?.cancel();
                                    _storeSearchDebounce = Timer(
                                      const Duration(milliseconds: 260),
                                      () {
                                        if (!mounted) return;
                                        _applyStoreSearchQuery(value);
                                      },
                                    );
                                  },
                                  onSubmitted: _applyStoreSearchQuery,
                                  decoration: InputDecoration(
                                    hintText: 'Search games',
                                    isDense: true,
                                    prefixIcon: const Icon(Icons.search, size: 18),
                                    suffixIcon: _searchController.text.isEmpty
                                        ? null
                                        : IconButton(
                                            tooltip: 'Clear',
                                            icon: const Icon(Icons.close, size: 18),
                                            onPressed: () {
                                              _searchController.clear();
                                              _applyStoreSearchQuery('');
                                              if (mounted) setState(() {});
                                            },
                                          ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox.shrink(),
                          const SizedBox(height: 8),
                          Focus(
                            focusNode: _storeAlphabetScopeFocus,
                            canRequestFocus: _storeAlphabetOpen,
                            skipTraversal: !_storeAlphabetOpen,
                            child: SizedBox(
                              height: 38,
                              child: ListView.separated(
                                scrollDirection: Axis.horizontal,
                                padding: EdgeInsets.zero,
                                itemCount: _storeLetterBuckets.length,
                                separatorBuilder: (context, _) =>
                                    const SizedBox(width: 5),
                                itemBuilder: (context, i) {
                                  final letter = _storeLetterBuckets[i];
                                  final hl = _storeAlphabetOpen &&
                                      _storeAlphabetScopeFocus.hasFocus &&
                                      i == _storeAlphabetLetterIndex;
                                  return GestureDetector(
                                    behavior: HitTestBehavior.opaque,
                                    onTap: () async {
                                      await _jumpToLetterBucketFromPointer(i);
                                    },
                                    child: AnimatedContainer(
                                      duration: const Duration(milliseconds: 80),
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 10, vertical: 8),
                                      alignment: Alignment.center,
                                      decoration: BoxDecoration(
                                        color: hl
                                            ? const Color(0xFF2B4A72)
                                            : Colors.white.withValues(alpha: 0.06),
                                        borderRadius: BorderRadius.circular(8),
                                        border: Border.all(
                                          color: hl
                                              ? const Color(0xFF6FA8FF)
                                              : Colors.white.withValues(alpha: 0.14),
                                          width: hl ? 2 : 1,
                                        ),
                                      ),
                                      child: Text(
                                        letter,
                                        style: TextStyle(
                                          fontWeight: FontWeight.w800,
                                          fontSize: letter == '#' ? 15 : 13,
                                          color: Colors.white.withValues(alpha: 0.92),
                                        ),
                                      ),
                                    ),
                                  );
                                },
                              ),
                            ),
                          ),
                          const SizedBox(height: 10),
                          Expanded(
                            child: selectedPlatformId == null
                                ? const Center(
                                    child: Text(
                                      'Select a platform to load games.',
                                      style: TextStyle(color: Colors.white60),
                                    ),
                                  )
                                : displayGames.isEmpty
                                ? const Center(
                                    child: Text(
                                      'No games found for this platform.',
                                      style: TextStyle(color: Colors.white60),
                                    ),
                                  )
                                : LayoutBuilder(
                                    builder: (context, constraints) {
                                      final cols =
                                          _storeGridColumnCount(constraints.maxWidth, cardSpacing);
                                      final innerW = constraints.maxWidth;
                                      final cell =
                                          (innerW - (cols - 1) * cardSpacing) / cols;
                                      final stride = cell + cardSpacing;
                                      WidgetsBinding.instance.addPostFrameCallback((_) {
                                        if (!mounted) return;
                                        if (_storeGridCols != cols ||
                                            (_storeGridCellStride - stride).abs() > 0.01) {
                                          setState(() {
                                            _storeGridCols = cols;
                                            _storeGridCellStride = stride;
                                          });
                                        }
                                      });
                                      return ScrollConfiguration(
                                        behavior: ScrollConfiguration.of(context)
                                            .copyWith(scrollbars: false),
                                        child: NotificationListener<ScrollNotification>(
                                          onNotification: (notification) {
                                            if (notification.metrics.axis == Axis.vertical) {
                                              _maybeLoadMoreStoreGamesFromScroll(
                                                  notification.metrics);
                                            }
                                            return false;
                                          },
                                          child: GridView.builder(
                                            controller: _scrollController,
                                            primary: false,
                                            padding: EdgeInsets.zero,
                                            gridDelegate:
                                                SliverGridDelegateWithFixedCrossAxisCount(
                                              crossAxisCount: cols,
                                              crossAxisSpacing: cardSpacing,
                                              mainAxisSpacing: cardSpacing,
                                              childAspectRatio: 1,
                                            ),
                                            itemCount: displayGames.length +
                                                (paginatedState.isLoadingMore ? 1 : 0),
                                            itemBuilder: (context, index) {
                                              if (index >= displayGames.length - 1 &&
                                                  _canLoadMoreForSelectedStorePlatform(
                                                      paginatedState)) {
                                                WidgetsBinding.instance.addPostFrameCallback((_) {
                                                  if (!mounted) return;
                                                  ref
                                                      .read(paginatedGamesProvider.notifier)
                                                      .loadMore();
                                                });
                                              }
                                              if (index == displayGames.length) {
                                                return const Center(
                                                  child: Padding(
                                                    padding: EdgeInsets.all(16),
                                                    child: CircularProgressIndicator(),
                                                  ),
                                                );
                                              }
                                              final game = displayGames[index];
                                              final downloads = ref.watch(downloadProvider);
                                              final isActuallyDownloading =
                                                  downloads.containsKey(game.id);
                                              final isDownloaded =
                                                  (downloadedCache[game.id] ?? false) &&
                                                      !isActuallyDownloading;
                                              final coverUrl = ref
                                                  .read(rommServiceProvider)
                                                  ?.resolveCoverUrl(game);
                                              final gridHl = _storeGameScopeFocus.hasFocus &&
                                                  index == _storeGameFocusIndex &&
                                                  !_storeAlphabetOpen;

                                              return GestureDetector(
                                                onTap: () =>
                                                    _handleGameTap(routeContext, ref, game),
                                                child: AnimatedContainer(
                                                  duration: const Duration(milliseconds: 80),
                                                  decoration: BoxDecoration(
                                                    borderRadius: BorderRadius.circular(12),
                                                    border: Border.all(
                                                      color: gridHl
                                                          ? const Color(0xFF6FA8FF)
                                                          : Colors.transparent,
                                                      width: gridHl ? 2 : 0,
                                                    ),
                                                  ),
                                                  child: GameCard(
                                                    game: game,
                                                    coverUrl: coverUrl,
                                                    isDownloaded: isDownloaded,
                                                    platformLogoUrl: game.platformSlug != null
                                                        ? '${ref.read(rommConfigProvider).value?.baseUrl ?? ''}/assets/platforms/${game.platformSlug}.svg'
                                                        : null,
                                                    showTitle: showTitle,
                                                    coverFit: BoxFit.contain,
                                                    coverAlignment: Alignment.center,
                                                  ),
                                                ),
                                              );
                                            },
                                          ),
                                        ),
                                      );
                                    },
                                  ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  @override
  Map<String, bool> get downloadedStates => ref.watch(downloadedGamesCacheProvider);

  @override
  void refreshDownloadState(DirectoryService dirService, Game game) {
    ref.read(downloadedGamesCacheProvider.notifier).refresh();
  }

  @override
  void refreshAllDownloadStates() {
    ref.read(downloadedGamesCacheProvider.notifier).refresh();
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(platformsProvider);
    ref.watch(selectedPlatformIdProvider);
    ref.watch(paginatedGamesProvider);
    ref.watch(cardAspectRatioProvider);
    ref.watch(columnCountProvider);
    ref.watch(cardSpacingProvider);
    ref.watch(showTitleProvider);
    ref.watch(downloadedGamesCacheProvider);
    ref.watch(storefrontSectionProvider);

    final directoryServiceAsync = ref.watch(directoryServiceProvider);
    final isSyncing = ref.watch(downloadedGamesCacheProvider.notifier).isSyncing;
    final shellAction = ref.watch(startShellActionProvider);

    ref.listen(storefrontSectionProvider, (prev, next) {
      if (prev == next) return;
      if (!mounted) return;
      if (ref.read(startShellActionProvider) != 'home') return;
      _pendingHomeShelfFocusFirstGame = true;
    });

    ref.listen(startShellActionProvider, (prev, next) {
      if (next != 'home') _pendingHomeShelfFocusFirstGame = false;
    });

    // Trigger initial load once service becomes available
    ref.listen(rommServiceProvider, (prev, next) {
      if (prev == null && next != null) {
        ref.read(paginatedGamesProvider.notifier).loadInitial(platformId: null);
      }
    });

    // Reload when platform changes
    ref.listen<int?>(selectedPlatformIdProvider, (prev, next) {
      if (prev != next) {
        final q = ref.read(searchQueryProvider).trim();
        ref.read(paginatedGamesProvider.notifier).loadInitial(
          platformId: next?.toString(),
          search: q.isEmpty ? null : q,
        );
        if (mounted) {
          setState(() => _storeGameFocusIndex = 0);
        }
      }
    });

    ref.listen<PaginatedGamesState>(paginatedGamesProvider, (prev, next) {
      // Chain pagination when user remains at the end of the list:
      // keep requesting pages until hasMore becomes false.
      final completedPage = (prev?.isLoadingMore ?? false) && !next.isLoadingMore;
      if (!completedPage) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _continueLoadingAtStoreListEnd(next);
      });
    });

    final rommService = ref.watch(rommServiceProvider);

    return Scaffold(
      body: ExcludeSemantics(
          child: Column(
            children: [
              if (isSyncing)
                const LinearProgressIndicator(
                  minHeight: 2,
                  backgroundColor: Colors.transparent,
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
                child: _HeaderPanel(rommService: rommService),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    StartTopActionStrip(
                      selectedAction: shellAction,
                      stripFocusNodes: _stripFocus,
                      onActivate: (id) => _activateStrip(context, id),
                    ),
                    if (shellAction == 'store') const SizedBox.shrink(),
                  ],
                ),
              ),
              if (directoryServiceAsync.value?.status.hasError == true)
                Container(
                  color: Colors.red.withValues(alpha: 0.1),
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  child: Row(
                    children: [
                      const Icon(Icons.error_outline, color: Colors.red),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Storage Error',
                              style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold),
                            ),
                            Text(
                              '${directoryServiceAsync.value!.status.message} (${directoryServiceAsync.value!.status.failedPath})',
                              style: const TextStyle(color: Colors.white70, fontSize: 12),
                            ),
                          ],
                        ),
                      ),
                      TextButton(
                        onPressed: () {
                          ref.invalidate(directoryServiceProvider);
                        },
                        child: const Text('Retry'),
                      ),
                    ],
                  ),
                ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                  child: Container(
                    decoration: BoxDecoration(
                      color: const Color(0xFF0F1A2A),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: const Color(0xFF2A4464)),
                    ),
                    child: Navigator(
                      key: LibraryScreen.shellNavigatorKey,
                      initialRoute: '/',
                      onGenerateRoute: _generateShellRoute,
                    ),
                  ),
                ),
              ),
            ],
          ),
      ),
    );
  }
}

class _HeaderPanel extends StatelessWidget {
  final dynamic rommService;

  const _HeaderPanel({required this.rommService});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color: const Color(0xFF0F1A2A),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF2A4464)),
      ),
      child: Row(
        children: [
          SvgPicture.asset(
            'src/assets/images/logo.svg',
            height: 54,
            fit: BoxFit.contain,
            placeholderBuilder: (context) => Image.asset(
              'freegosy_logo.png',
              height: 54,
              fit: BoxFit.contain,
            ),
          ),
          const Spacer(),
          if (rommService != null)
            ValueListenableBuilder<bool>(
              valueListenable: rommService.isOffline,
              builder: (context, offline, _) {
                return Text(
                  offline ? 'Offline Mode' : 'Connected',
                  style: TextStyle(
                    color: offline ? Colors.orange : Colors.lightGreenAccent,
                    fontWeight: FontWeight.w700,
                  ),
                );
              },
            ),
        ],
      ),
    );
  }
}

class _ExitConfirmDialog extends StatefulWidget {
  const _ExitConfirmDialog();

  @override
  State<_ExitConfirmDialog> createState() => _ExitConfirmDialogState();
}

class _ExitConfirmDialogState extends State<_ExitConfirmDialog> {
  final FocusNode _keyboardFocus = FocusNode();
  bool _yesSelected = false;

  bool _consumeExitDialogControllerAction(ControllerAction action) {
    if (!mounted) return false;
    switch (action) {
      case ControllerAction.left:
      case ControllerAction.up:
      case ControllerAction.right:
      case ControllerAction.down:
        setState(() => _yesSelected = !_yesSelected);
        return true;
      case ControllerAction.select:
        Navigator.of(context, rootNavigator: true).pop(_yesSelected);
        return true;
      case ControllerAction.back:
        Navigator.of(context, rootNavigator: true).pop(false);
        return true;
      case ControllerAction.refresh:
      case ControllerAction.alphabetJump:
      case ControllerAction.previousSection:
      case ControllerAction.nextSection:
      case ControllerAction.scrollPageUp:
      case ControllerAction.scrollPageDown:
      case ControllerAction.openSearch:
        return true;
    }
  }

  @override
  void initState() {
    super.initState();
    LibraryFocusBridge.consumeExitDialogControllerAction = _consumeExitDialogControllerAction;
  }

  @override
  void dispose() {
    if (LibraryFocusBridge.consumeExitDialogControllerAction == _consumeExitDialogControllerAction) {
      LibraryFocusBridge.consumeExitDialogControllerAction = null;
    }
    _keyboardFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return KeyboardListener(
      focusNode: _keyboardFocus,
      autofocus: true,
      onKeyEvent: (event) {
        if (event is! KeyDownEvent) return;
        if (ControllerKeyMap.isLeft(event.logicalKey) ||
            ControllerKeyMap.isRight(event.logicalKey) ||
            ControllerKeyMap.isUp(event.logicalKey) ||
            ControllerKeyMap.isDown(event.logicalKey)) {
          setState(() => _yesSelected = !_yesSelected);
          return;
        }
        if (ControllerKeyMap.isSelect(event.logicalKey)) {
          Navigator.of(context, rootNavigator: true).pop(_yesSelected);
          return;
        }
        if (ControllerKeyMap.isBack(event.logicalKey)) {
          Navigator.of(context, rootNavigator: true).pop(false);
        }
      },
      child: AlertDialog(
        backgroundColor: const Color(0xFF0F1A2A),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: Color(0xFF2A4464)),
        ),
        title: const Text(
          'Exit ROMM Store',
          style: TextStyle(fontWeight: FontWeight.w800),
        ),
        content: const Text(
          'Are you sure you want to exit?',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          FilledButton.tonal(
            autofocus: true, // Default focus should stay on No.
            style: FilledButton.styleFrom(
              side: BorderSide(
                color: !_yesSelected ? const Color(0xFF6FA8FF) : Colors.transparent,
                width: 2,
              ),
            ),
            onPressed: () => Navigator.of(context, rootNavigator: true).pop(false),
            child: const Text('No'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              side: BorderSide(
                color: _yesSelected ? const Color(0xFF6FA8FF) : Colors.transparent,
                width: 2,
              ),
            ),
            onPressed: () => Navigator.of(context, rootNavigator: true).pop(true),
            child: const Text('Yes'),
          ),
        ],
      ),
    );
  }
}
