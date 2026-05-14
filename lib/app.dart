import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'main.dart' show scaffoldMessengerKey;
import 'providers/romm_provider.dart';
import 'ui/screens/library_screen.dart';
import 'ui/screens/download_screen.dart';
import 'ui/screens/settings_screen.dart';
import 'ui/screens/onboarding_screen.dart';
import 'providers/ui_provider.dart';
import 'core/storage/file_sanity_service.dart';
import 'core/input/controller_keymap.dart';
import 'core/input/linux_gamepad_service.dart';
import 'core/input/steam_keyboard_service.dart';
import 'core/input/xinput_controller_service.dart';
import 'core/audio/ui_sfx_service.dart';
import 'ui/library_focus_bridge.dart';

class CustomScrollBehavior extends MaterialScrollBehavior {
  @override
  Set<PointerDeviceKind> get dragDevices => {
    PointerDeviceKind.touch,
    PointerDeviceKind.mouse,
    PointerDeviceKind.trackpad,
    PointerDeviceKind.stylus,
  };
}

class RommStoreApp extends ConsumerStatefulWidget {
  const RommStoreApp({super.key});

  @override
  ConsumerState<RommStoreApp> createState() => _RommStoreAppState();
}

class _RommStoreAppState extends ConsumerState<RommStoreApp> with WidgetsBindingObserver {
  final List<Widget> _screens = const [
    LibraryScreen(),
    DownloadScreen(),
    SettingsScreen(),
  ];
  final FocusNode _controllerFocusNode = FocusNode(debugLabel: 'controllerInput');
  final XInputControllerService _xInputControllerService = XInputControllerService();
  final LinuxGamepadService _linuxGamepadService = LinuxGamepadService();
  static const List<String> _storeSections = ['spotlight', 'new', 'highlights'];
  bool _editableHasFocus = false;

  /// [RommStoreApp]'s [State.context] sits **above** [MaterialApp], so [FocusScope.of],
  /// [Navigator.of], and [Actions.invoke] must use a descendant context (inside the navigator).
  final GlobalKey _materialAppSubtreeKey = GlobalKey(debugLabel: 'materialAppSubtree');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    HardwareKeyboard.instance.addHandler(_globalControllerKeyHandler);
    FocusManager.instance.addListener(_handleGlobalFocusChange);
    _xInputControllerService.start(_handleControllerAction);
    _linuxGamepadService.start(_handleControllerAction);
    _ensureControllerFocusSoon();
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_globalControllerKeyHandler);
    FocusManager.instance.removeListener(_handleGlobalFocusChange);
    WidgetsBinding.instance.removeObserver(this);
    _xInputControllerService.stop();
    _linuxGamepadService.stop();
    _controllerFocusNode.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _ensureControllerFocusSoon();
    }
  }

  void _ensureControllerFocusSoon() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final primary = FocusManager.instance.primaryFocus;
      final hasEditableFocus = primary?.context?.widget is EditableText;
      if (hasEditableFocus) return;
      if (primary == null || primary == _controllerFocusNode) {
        _controllerFocusNode.requestFocus();
      }
    });
  }

  void _handleGlobalFocusChange() {
    if (!mounted) return;
    final primary = FocusManager.instance.primaryFocus;
    final hasEditableFocus = primary?.context?.widget is EditableText;
    if (hasEditableFocus == _editableHasFocus) return;
    _editableHasFocus = hasEditableFocus;
    if (hasEditableFocus) {
      SteamKeyboardService.show();
    } else {
      SteamKeyboardService.hide();
    }
  }

  bool _globalControllerKeyHandler(KeyEvent event) {
    if (event is! KeyDownEvent || !mounted) return false;
    final primary = FocusManager.instance.primaryFocus;
    final hasEditableFocus = primary?.context?.widget is EditableText;
    if (hasEditableFocus) return false;
    final action = ControllerKeyMap.toControllerAction(event.logicalKey);
    if (action == null) return false;
    _handleControllerAction(action);
    return true;
  }

  void _handleControllerAction(ControllerAction action) {
    if (!mounted) return;
    final overlayContext = _materialAppSubtreeKey.currentContext;
    if (overlayContext == null) return;
    if (LibraryFocusBridge.consumeExitDialogControllerAction?.call(action) ?? false) {
      return;
    }
    if (action == ControllerAction.select) {
      UiSfxService.instance.play(UiSfx.enter);
    } else if (action == ControllerAction.back) {
      UiSfxService.instance.play(UiSfx.exit);
    } else if (action == ControllerAction.up ||
        action == ControllerAction.down ||
        action == ControllerAction.left ||
        action == ControllerAction.right) {
      UiSfxService.instance.play(UiSfx.movement);
    }

    final context = overlayContext;
    FocusScopeNode focusScope;
    try {
      focusScope = FocusScope.of(context);
    } catch (_) {
      return;
    }
    final hasTargetFocus = focusScope.focusedChild != null &&
        focusScope.focusedChild != _controllerFocusNode;

    if (LibraryFocusBridge.consumeGameDetailControllerAction?.call(action) ?? false) {
      return;
    }

    if (LibraryFocusBridge.consumeSettingsShellControllerAction?.call(action) ??
        false) {
      return;
    }

    if (LibraryFocusBridge.consumeDownloadsShellControllerAction?.call(action) ??
        false) {
      return;
    }

    if (LibraryFocusBridge.consumeDownloadsBodyControllerAction?.call(action) ??
        false) {
      return;
    }

    if (LibraryFocusBridge.consumeFriendsShellControllerAction?.call(action) ??
        false) {
      return;
    }

    if (LibraryFocusBridge.consumeFriendsBodyControllerAction?.call(action) ??
        false) {
      return;
    }

    if (LibraryFocusBridge.consumeStoreControllerAction?.call(action) ?? false) {
      return;
    }

    // Do not treat [ControllerAction.select] like a focus move — A must activate the focused control
    // (e.g. top strip tiles). Otherwise the strip never receives ActivateIntent when focus is still
    // on the root [KeyboardListener] node.
    if (!hasTargetFocus &&
        action != ControllerAction.alphabetJump &&
        (action == ControllerAction.up ||
            action == ControllerAction.down ||
            action == ControllerAction.left ||
            action == ControllerAction.right)) {
      if (ref.read(currentTabIndexProvider) == 0 &&
          LibraryFocusBridge.requestFocusStripPrimary != null) {
        LibraryFocusBridge.requestFocusStripPrimary!();
        return;
      }
      focusScope.nextFocus();
      return;
    }

    switch (action) {
      case ControllerAction.up:
        if (LibraryFocusBridge.stripRowHasPrimaryFocus()) {
          return;
        }
        if (LibraryFocusBridge.friendsShellScopeHasPrimaryFocus()) {
          LibraryFocusBridge.requestFocusStripPrimary?.call();
          return;
        }
        if (LibraryFocusBridge.highlightRailHasPrimaryFocus()) {
          LibraryFocusBridge.requestFocusStripPrimary?.call();
          return;
        }
        focusScope.focusInDirection(TraversalDirection.up);
        break;
      case ControllerAction.down:
        if (LibraryFocusBridge.stripRowHasPrimaryFocus()) {
          final shell = ref.read(startShellActionProvider);
          final shelfReady = LibraryFocusBridge.homeShelfHasFocusableGames?.call() ?? false;
          if (shell == 'home' && shelfReady) {
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
          return;
        }
        focusScope.focusInDirection(TraversalDirection.down);
        break;
      case ControllerAction.left:
        if (LibraryFocusBridge.stripRowHasPrimaryFocus()) {
          LibraryFocusBridge.moveStripFocusHorizontal?.call(-1);
          return;
        }
        if (LibraryFocusBridge.highlightRailHasPrimaryFocus()) {
          LibraryFocusBridge.moveHomeShelfFocusHorizontal?.call(-1);
          return;
        }
        focusScope.focusInDirection(TraversalDirection.left);
        break;
      case ControllerAction.right:
        if (LibraryFocusBridge.stripRowHasPrimaryFocus()) {
          LibraryFocusBridge.moveStripFocusHorizontal?.call(1);
          return;
        }
        if (LibraryFocusBridge.highlightRailHasPrimaryFocus()) {
          LibraryFocusBridge.moveHomeShelfFocusHorizontal?.call(1);
          return;
        }
        focusScope.focusInDirection(TraversalDirection.right);
        break;
      case ControllerAction.select:
        // [Actions.invoke] with [State.context] (above [MaterialApp]) cannot see strip [Actions].
        // When XInput focus is still on [KeyboardListener], move to the strip first; next **A** activates.
        if (FocusManager.instance.primaryFocus == _controllerFocusNode) {
          if (ref.read(currentTabIndexProvider) == 0 &&
              LibraryFocusBridge.requestFocusStripPrimary != null) {
            LibraryFocusBridge.requestFocusStripPrimary!();
            // Same frame: focus is not updated yet — run activate after strip has primary focus.
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted) return;
              final post = FocusManager.instance.primaryFocus?.context;
              if (post != null) {
                Actions.maybeInvoke<ActivateIntent>(post, const ActivateIntent());
              }
            });
          }
          break;
        }
        final primaryCtx = FocusManager.instance.primaryFocus?.context;
        if (primaryCtx != null) {
          Actions.maybeInvoke<ActivateIntent>(primaryCtx, const ActivateIntent());
        }
        break;
      case ControllerAction.back:
        if (LibraryFocusBridge.highlightRailHasPrimaryFocus()) {
          LibraryFocusBridge.requestFocusStripPrimary?.call();
          return;
        }
        final shellNav = LibraryScreen.shellNavigatorKey.currentState;
        if (shellNav != null && shellNav.canPop()) {
          LibraryFocusBridge.popShellHome?.call();
          return;
        }
        final rootNav = Navigator.maybeOf(context);
        if (rootNav != null && rootNav.canPop()) {
          rootNav.maybePop();
        } else {
          Actions.maybeInvoke<DismissIntent>(context, const DismissIntent());
        }
        break;
      case ControllerAction.refresh:
        break;
      case ControllerAction.previousSection:
        if (LibraryFocusBridge.cycleFriendsDetailTab?.call(-1) ?? false) {
          break;
        }
        _cycleStoreSection(-1);
        break;
      case ControllerAction.nextSection:
        if (LibraryFocusBridge.cycleFriendsDetailTab?.call(1) ?? false) {
          break;
        }
        _cycleStoreSection(1);
        break;
      case ControllerAction.alphabetJump:
        break;
      case ControllerAction.scrollPageUp:
      case ControllerAction.scrollPageDown:
        break;
      case ControllerAction.openSearch:
        LibraryFocusBridge.requestFocusStoreSearch?.call();
        break;
    }
  }

  void _cycleStoreSection(int delta) {
    final currentTab = ref.read(currentTabIndexProvider);
    if (currentTab != 0) return; // Only main tab.

    if (LibraryFocusBridge.stripRowHasPrimaryFocus()) return;

    final shell = ref.read(startShellActionProvider);
    if (shell != 'home') return; // Highlight rail tabs only on Home route.

    final current = ref.read(storefrontSectionProvider);
    final currentIndex = _storeSections.indexOf(current);
    final safeIndex = currentIndex < 0 ? 0 : currentIndex;
    final nextIndex = (safeIndex + delta + _storeSections.length) % _storeSections.length;
    ref.read(storefrontSectionProvider.notifier).state = _storeSections[nextIndex];
  }

  void _handleControllerKey(BuildContext context, KeyEvent event) {
    if (event is! KeyDownEvent) return;

    if (LibraryFocusBridge.consumeGameDetailKeyEvent?.call(event) ?? false) {
      return;
    }

    if (LibraryFocusBridge.consumeDownloadsBodyKeyEvent?.call(event) ?? false) {
      return;
    }

    if (LibraryFocusBridge.consumeFriendsShellKeyEvent?.call(event) ?? false) {
      return;
    }

    if (LibraryFocusBridge.consumeFriendsBodyKeyEvent?.call(event) ?? false) {
      return;
    }

    final key = event.logicalKey;
    final focusScope = FocusScope.of(context);
    final hasTargetFocus = focusScope.focusedChild != null &&
        focusScope.focusedChild != _controllerFocusNode;

    if ((ControllerKeyMap.isUp(key) ||
            ControllerKeyMap.isDown(key) ||
            ControllerKeyMap.isLeft(key) ||
            ControllerKeyMap.isRight(key)) &&
        !hasTargetFocus) {
      focusScope.nextFocus();
      return;
    }

    if (ControllerKeyMap.isUp(key)) {
      UiSfxService.instance.play(UiSfx.movement);
      if (LibraryFocusBridge.stripRowHasPrimaryFocus()) {
        return;
      }
      if (LibraryFocusBridge.friendsShellScopeHasPrimaryFocus()) {
        LibraryFocusBridge.requestFocusStripPrimary?.call();
        return;
      }
      if (LibraryFocusBridge.highlightRailHasPrimaryFocus()) {
        LibraryFocusBridge.requestFocusStripPrimary?.call();
        return;
      }
      focusScope.focusInDirection(TraversalDirection.up);
      return;
    }

    if (ControllerKeyMap.isDown(key)) {
      UiSfxService.instance.play(UiSfx.movement);
      if (LibraryFocusBridge.stripRowHasPrimaryFocus()) {
        final shell = ref.read(startShellActionProvider);
        final shelfReady = LibraryFocusBridge.homeShelfHasFocusableGames?.call() ?? false;
        if (shell == 'home' && shelfReady) {
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
        return;
      }
      focusScope.focusInDirection(TraversalDirection.down);
      return;
    }

    if (ControllerKeyMap.isLeft(key)) {
      UiSfxService.instance.play(UiSfx.movement);
      if (LibraryFocusBridge.stripRowHasPrimaryFocus()) {
        LibraryFocusBridge.moveStripFocusHorizontal?.call(-1);
        return;
      }
      if (LibraryFocusBridge.highlightRailHasPrimaryFocus()) {
        LibraryFocusBridge.moveHomeShelfFocusHorizontal?.call(-1);
        return;
      }
      focusScope.focusInDirection(TraversalDirection.left);
      return;
    }

    if (ControllerKeyMap.isRight(key)) {
      UiSfxService.instance.play(UiSfx.movement);
      if (LibraryFocusBridge.stripRowHasPrimaryFocus()) {
        LibraryFocusBridge.moveStripFocusHorizontal?.call(1);
        return;
      }
      if (LibraryFocusBridge.highlightRailHasPrimaryFocus()) {
        LibraryFocusBridge.moveHomeShelfFocusHorizontal?.call(1);
        return;
      }
      focusScope.focusInDirection(TraversalDirection.right);
      return;
    }

    if (ControllerKeyMap.isSelect(key)) {
      UiSfxService.instance.play(UiSfx.enter);
      Actions.invoke(context, const ActivateIntent());
      return;
    }

    if (ControllerKeyMap.isBack(key)) {
      UiSfxService.instance.play(UiSfx.exit);
      if (LibraryFocusBridge.highlightRailHasPrimaryFocus()) {
        LibraryFocusBridge.requestFocusStripPrimary?.call();
        return;
      }
      final shellNav = LibraryScreen.shellNavigatorKey.currentState;
      if (shellNav != null && shellNav.canPop()) {
        LibraryFocusBridge.popShellHome?.call();
        return;
      }
      if (Navigator.of(context).canPop()) {
        Navigator.of(context).maybePop();
      } else {
        Actions.invoke(context, const DismissIntent());
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // Keep the file sanity service alive and running in the background
    ref.watch(fileSanityServiceProvider);

    final currentIndex = ref.watch(currentTabIndexProvider);

    return ExcludeSemantics(
      child: MaterialApp(
        title: 'RomM Store',
        debugShowCheckedModeBanner: false,
        scaffoldMessengerKey: scaffoldMessengerKey,
        scrollBehavior: CustomScrollBehavior(),
        theme: ThemeData(
          useMaterial3: true,
          colorScheme: ColorScheme.fromSeed(            
            seedColor: const Color(0xFF3A66A6),
            brightness: Brightness.dark,
            surface: const Color(0xFF101923),
          ),
          scaffoldBackgroundColor: const Color(0xFF0A121D),
          cardTheme: const CardThemeData(
            color: Color(0xFF122033),
            elevation: 2,
          ),
          appBarTheme: const AppBarTheme(
            backgroundColor: Color(0xFF0A121D),
            foregroundColor: Colors.white,
            elevation: 0,
            surfaceTintColor: Colors.transparent,
          ),
          navigationBarTheme: NavigationBarThemeData(
            backgroundColor: const Color(0xFF101A2B),
            indicatorColor: const Color(0xFF2A4F7D),
          ),
          inputDecorationTheme: InputDecorationTheme(
            filled: true,
            fillColor: const Color(0xFF0F1A2A),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: const BorderSide(color: Color(0xFF284061)),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: const BorderSide(color: Color(0xFF203955)),
            ),
          ),
          elevatedButtonTheme: ElevatedButtonThemeData(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF2A4F7D),
              foregroundColor: Colors.white,
            ),
          ),
        ),
        home: Consumer(
          builder: (context, ref, _) {
            final isOnboardedAsync = ref.watch(rommConfigProvider);
            
            return KeyedSubtree(
              key: _materialAppSubtreeKey,
              child: isOnboardedAsync.when(
                data: (config) {
                  if (config.baseUrl.isEmpty) {
                    return const OnboardingScreen();
                  }

                  final shellAction = ref.watch(startShellActionProvider);
                  final showBumperHints =
                      shellAction != 'store' && shellAction != 'downloads' && shellAction != 'friends';
                  _ensureControllerFocusSoon();

                  return KeyboardListener(
                  focusNode: _controllerFocusNode,
                  autofocus: true,
                  onKeyEvent: (event) => _handleControllerKey(context, event),
                  child: Scaffold(
                    body: _screens[currentIndex],
                    bottomNavigationBar: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                      decoration: const BoxDecoration(
                        color: Color(0xFF0D1828),
                        border: Border(
                          top: BorderSide(color: Color(0xFF284061)),
                        ),
                      ),
                      child: shellAction == 'store'
                          ? const _StoreShellHintBar()
                          : shellAction == 'downloads'
                              ? const _DownloadsShellHintBar()
                              : shellAction == 'friends'
                                  ? const _FriendsShellHintBar()
                                  : Row(
                              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                              children: [
                                const _XboxHint(
                                  iconAsset: 'src/assets/images/controls/360_Dpad.png',
                                  label: 'Move · Strip / Games',
                                ),
                                const _XboxHint(
                                  iconAsset: 'src/assets/images/controls/360_A.png',
                                  label: 'Enter · Select',
                                ),
                                const _XboxHint(
                                  iconAsset: 'src/assets/images/controls/360_B.png',
                                  label: 'Back · Close Page',
                                ),
                                if (showBumperHints) ...const [
                                  _XboxHint(
                                    iconAsset: 'src/assets/images/controls/360_LB.png',
                                    label: 'Prev · Switch tabs',
                                  ),
                                  _XboxHint(
                                    iconAsset: 'src/assets/images/controls/360_RB.png',
                                    label: 'Next · Switch tabs',
                                  ),
                                ],
                              ],
                            ),
                    ),
                  ),
                  );
                },
                loading: () => const Scaffold(body: Center(child: CircularProgressIndicator())),
                error: (e, s) => Scaffold(body: Center(child: Text('Error: $e'))),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// Bottom hints when the library shell is on **Store** (replaces strip + bumper row).
class _StoreShellHintBar extends StatelessWidget {
  const _StoreShellHintBar();

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.start,
        children: const [
          Padding(
            padding: EdgeInsets.only(right: 12),
            child: _XboxHint(
              iconAsset: 'src/assets/images/controls/360_Dpad.png',
              label: 'Move · Platforms / Games',
            ),
          ),
          Padding(
            padding: EdgeInsets.only(right: 12),
            child: _XboxHint(
              iconAsset: 'src/assets/images/controls/360_A.png',
              label: 'Select · Open',
            ),
          ),
          Padding(
            padding: EdgeInsets.only(right: 12),
            child: _XboxHint(
              iconAsset: 'src/assets/images/controls/360_B.png',
              label: 'Back · Home / Up',
            ),
          ),
          Padding(
            padding: EdgeInsets.only(right: 12),
            child: _XboxHint(
              iconAsset: 'src/assets/images/controls/360_X.png',
              label: 'Jump · #–Z',
            ),
          ),
          Padding(
            padding: EdgeInsets.only(right: 12),
            child: _XboxHint(
              iconAsset: 'src/assets/images/controls/360_Y.png',
              label: 'Clear · Platform filter',
            ),
          ),
          Padding(
            padding: EdgeInsets.only(right: 12),
            child: _XboxHint(
              iconAsset: 'src/assets/images/controls/360_LT.png',
              label: 'Fast scroll · List up',
            ),
          ),
          _XboxHint(
            iconAsset: 'src/assets/images/controls/360_RT.png',
            label: 'Fast scroll · List down',
          ),
          Padding(
            padding: EdgeInsets.only(left: 12),
            child: _XboxHint(
              iconAsset: 'src/assets/images/controls/360_Start.png',
              label: 'Search',
            ),
          ),
        ],
      ),
    );
  }
}

/// Bottom hints when the library shell is on **Friends** (matches Steam-style RA mock).
class _FriendsShellHintBar extends StatelessWidget {
  const _FriendsShellHintBar();

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.start,
        children: const [
          Padding(
            padding: EdgeInsets.only(right: 12),
            child: _XboxHint(
              iconAsset: 'src/assets/images/controls/360_A.png',
              label: 'Confirm',
            ),
          ),
          Padding(
            padding: EdgeInsets.only(right: 12),
            child: _XboxHint(
              iconAsset: 'src/assets/images/controls/360_B.png',
              label: 'Back',
            ),
          ),
          Padding(
            padding: EdgeInsets.only(right: 12),
            child: _XboxHint(
              iconAsset: 'src/assets/images/controls/360_Dpad.png',
              label: 'Navigate',
            ),
          ),
          Padding(
            padding: EdgeInsets.only(right: 12),
            child: _XboxHint(
              iconAsset: 'src/assets/images/controls/360_Y.png',
              label: 'Refresh',
            ),
          ),
          Padding(
            padding: EdgeInsets.only(right: 12),
            child: _XboxHint(
              iconAsset: 'src/assets/images/controls/360_LB.png',
              label: 'View Left',
            ),
          ),
          Padding(
            padding: EdgeInsets.only(right: 12),
            child: _XboxHint(
              iconAsset: 'src/assets/images/controls/360_RB.png',
              label: 'View Right',
            ),
          ),
          Padding(
            padding: EdgeInsets.only(right: 12),
            child: _XboxHint(
              iconAsset: 'src/assets/images/controls/360_LT.png',
              label: 'Page Up',
            ),
          ),
          _XboxHint(
            iconAsset: 'src/assets/images/controls/360_RT.png',
            label: 'Page Down',
          ),
        ],
      ),
    );
  }
}

/// Bottom hints when the library shell is on **Downloads**.
class _DownloadsShellHintBar extends StatelessWidget {
  const _DownloadsShellHintBar();

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.start,
        children: const [
          Padding(
            padding: EdgeInsets.only(right: 12),
            child: _XboxHint(
              iconAsset: 'src/assets/images/controls/360_Dpad.png',
              label: 'Move · Downloads',
            ),
          ),
          Padding(
            padding: EdgeInsets.only(right: 12),
            child: _XboxHint(
              iconAsset: 'src/assets/images/controls/360_X.png',
              label: 'Cancel / Clear',
            ),
          ),
          Padding(
            padding: EdgeInsets.only(right: 12),
            child: _XboxHint(
              iconAsset: 'src/assets/images/controls/360_A.png',
              label: 'Pause / Resume',
            ),
          ),
          Padding(
            padding: EdgeInsets.only(right: 12),
            child: _XboxHint(
              iconAsset: 'src/assets/images/controls/360_Y.png',
              label: 'Clear all',
            ),
          ),
          _XboxHint(
            iconAsset: 'src/assets/images/controls/360_B.png',
            label: 'Back · Home',
          ),
        ],
      ),
    );
  }
}

class _XboxHint extends StatelessWidget {
  final String iconAsset;
  final String label;

  const _XboxHint({
    required this.iconAsset,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Image.asset(
          iconAsset,
          width: 18,
          height: 18,
          fit: BoxFit.contain,
          errorBuilder: (context, error, stackTrace) => const Icon(Icons.circle, size: 14),
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: const TextStyle(
            fontSize: 12,
            color: Colors.white70,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}
