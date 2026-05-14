import 'package:flutter/widgets.dart';

import '../core/input/xinput_controller_service.dart';

/// Focus helpers for Xbox navigation between the top strip and home highlight rail.
class LibraryFocusBridge {
  LibraryFocusBridge._();

  static VoidCallback? requestFocusHighlightBelow;
  static VoidCallback? requestFocusStripPrimary;
  /// Store route: focus the platforms column (after opening Store from the strip).
  static VoidCallback? requestFocusStorePlatforms;
  /// Store route: focus the game grid (after returning from game detail to the same platform list).
  static VoidCallback? requestFocusStoreGameGrid;
  /// Store route: focus the search box in the game-list header.
  static VoidCallback? requestFocusStoreSearch;
  /// Downloads shell route: focus the downloads pane body.
  static VoidCallback? requestFocusDownloadsBody;
  /// Friends shell route: focus the placeholder page body.
  static VoidCallback? requestFocusFriendsBody;
  /// Settings shell route: focus the settings pane body.
  static VoidCallback? requestFocusSettingsBody;
  /// Registered by [LibraryScreen]: strip tile index owning primary focus, or null.
  static int? Function()? stripFocusedTileIndex;

  /// Shift focus among strip tiles (-1 left, +1 right). Stops at Home / Exit (no wrap).
  static void Function(int delta)? moveStripFocusHorizontal;
  /// Shift focus among home spotlight shelf tiles (-1 left, +1 right).
  static void Function(int delta)? moveHomeShelfFocusHorizontal;
  /// True when Home spotlight shelf has at least one focusable game tile (controller Down routing).
  static bool Function()? homeShelfHasFocusableGames;

  /// Pops the library shell [Navigator] to `/`, syncs the top strip to Home, and recenters focus.
  /// Registered while [LibraryScreen] is mounted.
  static VoidCallback? popShellHome;

  static bool stripRowHasPrimaryFocus() {
    final idx = stripFocusedTileIndex?.call();
    if (idx != null) return true;
    final l = FocusManager.instance.primaryFocus?.debugLabel ?? '';
    return l.startsWith('strip_');
  }

  static bool highlightRailHasPrimaryFocus() {
    final l = FocusManager.instance.primaryFocus?.debugLabel ?? '';
    return l.startsWith('highlight_');
  }

  static bool storePlatformScopeHasPrimaryFocus() =>
      FocusManager.instance.primaryFocus?.debugLabel == 'store_platform_scope';

  static bool storeGameScopeHasPrimaryFocus() =>
      FocusManager.instance.primaryFocus?.debugLabel == 'store_game_scope';

  static bool storeAlphabetScopeHasPrimaryFocus() =>
      FocusManager.instance.primaryFocus?.debugLabel == 'store_alpha_scope';

  static bool friendsShellScopeHasPrimaryFocus() =>
      FocusManager.instance.primaryFocus?.debugLabel == 'friends_shell_scope';

  /// When on the Store shell route, handles directional buttons and face buttons before default traversal.
  /// Returns true if the action was consumed.
  static bool Function(ControllerAction action)? consumeStoreControllerAction;

  /// Keyboard parallel to [consumeStoreControllerAction]. Returns true if consumed.
  static bool Function(KeyEvent event)? consumeStoreKeyEvent;

  /// Downloads shell: **B** returns to Home when the embedded route is open.
  static bool Function(ControllerAction action)? consumeDownloadsShellControllerAction;

  /// Keyboard parallel for downloads shell **B** / Escape.
  static bool Function(KeyEvent event)? consumeDownloadsShellKeyEvent;

  /// Downloads list body (tab or shell): handles row nav/actions (Up/Down/X/A/Y).
  static bool Function(ControllerAction action)? consumeDownloadsBodyControllerAction;

  /// Keyboard parallel for downloads body controls.
  static bool Function(KeyEvent event)? consumeDownloadsBodyKeyEvent;

  /// Friends shell: **B** returns to Home; delegates other input to body consumer when set.
  static bool Function(ControllerAction action)? consumeFriendsShellControllerAction;

  /// Keyboard parallel for friends shell **B** / Escape and body delegation.
  static bool Function(KeyEvent event)? consumeFriendsShellKeyEvent;

  /// Friends page body: locks D-pad to the following list (Up/Down) when embedded.
  static bool Function(ControllerAction action)? consumeFriendsBodyControllerAction;

  /// Keyboard parallel for friends body controls.
  static bool Function(KeyEvent event)? consumeFriendsBodyKeyEvent;

  /// Settings shell: **B** returns to Home when the embedded route is open.
  static bool Function(ControllerAction action)? consumeSettingsShellControllerAction;

  /// Keyboard parallel for settings shell **B** / Escape.
  static bool Function(KeyEvent event)? consumeSettingsShellKeyEvent;

  /// Open Store for [platformId], navigate shell to `/store`, then focus the game grid.
  /// Registered by [LibraryScreen]; used when leaving game detail from **Store**.
  static void Function(int? platformId)? returnFromGameDetailToStore;

  /// Home spotlight: refocus the shelf tile for [gameId] after closing detail (**B**).
  /// Registered by [LibraryScreen].
  static void Function(String gameId)? refocusHomeShelfAfterDetailPop;

  /// Full-screen game detail: **A** = primary download / resume; **B** depends on launch context.
  /// Returns true if consumed.
  static bool Function(ControllerAction action)? consumeGameDetailControllerAction;

  /// Keyboard parallel: **A** / Enter = download or resume; **B** / Escape = pop detail (Home vs Store per launch context).
  static bool Function(KeyEvent event)? consumeGameDetailKeyEvent;

  /// Exit confirmation popup: handles controller navigation between No/Yes and A/B actions.
  static bool Function(ControllerAction action)? consumeExitDialogControllerAction;

  /// Friends shell detail pane: **LB** / **RB** cycle Played Games vs Achievements tabs.
  /// Return true when the Friends route consumed the bumper (shell is friends).
  static bool Function(int delta)? cycleFriendsDetailTab;
}
