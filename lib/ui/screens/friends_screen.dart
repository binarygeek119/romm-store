import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/input/xinput_controller_service.dart';
import '../../core/input/controller_keymap.dart';
import '../../providers/retroachievements_provider.dart';
import '../../providers/ui_provider.dart';
import '../library_focus_bridge.dart';

class FriendsScreen extends ConsumerStatefulWidget {
  final bool embeddedShell;
  final FocusNode? shellFocusNode;

  const FriendsScreen({super.key, this.embeddedShell = false, this.shellFocusNode});

  @override
  ConsumerState<FriendsScreen> createState() => _FriendsScreenState();
}

class _FriendsScreenState extends ConsumerState<FriendsScreen> {
  int _selectedFriendIndex = 0;
  int _detailTabIndex = 0;
  final ScrollController _friendsScrollController = ScrollController();
  final ScrollController _playedScrollController = ScrollController();
  final ScrollController _achievementsScrollController = ScrollController();
  final List<GlobalKey> _friendRowKeys = <GlobalKey>[];
  final FocusNode _standaloneFocus = FocusNode(debugLabel: 'friends_standalone_scope');

  bool _cycleFriendsDetailTabHandler(int delta) {
    if (!mounted || !widget.embeddedShell) return false;
    if (LibraryFocusBridge.stripRowHasPrimaryFocus()) return false;
    if (ref.read(startShellActionProvider) != 'friends') return false;
    setState(() => _detailTabIndex = (_detailTabIndex + delta + 2) % 2);
    return true;
  }

  @override
  void initState() {
    super.initState();
    if (widget.embeddedShell && widget.shellFocusNode != null) {
      LibraryFocusBridge.consumeFriendsBodyControllerAction = _consumeFriendsControllerAction;
      LibraryFocusBridge.consumeFriendsBodyKeyEvent = _consumeFriendsKeyEvent;
      LibraryFocusBridge.cycleFriendsDetailTab = _cycleFriendsDetailTabHandler;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (widget.shellFocusNode != null) {
        widget.shellFocusNode!.requestFocus();
      } else {
        _standaloneFocus.requestFocus();
      }
    });
  }

  @override
  void dispose() {
    if (LibraryFocusBridge.consumeFriendsBodyControllerAction == _consumeFriendsControllerAction) {
      LibraryFocusBridge.consumeFriendsBodyControllerAction = null;
    }
    if (LibraryFocusBridge.consumeFriendsBodyKeyEvent == _consumeFriendsKeyEvent) {
      LibraryFocusBridge.consumeFriendsBodyKeyEvent = null;
    }
    if (LibraryFocusBridge.cycleFriendsDetailTab == _cycleFriendsDetailTabHandler) {
      LibraryFocusBridge.cycleFriendsDetailTab = null;
    }
    _friendsScrollController.dispose();
    _playedScrollController.dispose();
    _achievementsScrollController.dispose();
    _standaloneFocus.dispose();
    super.dispose();
  }

  void _syncFriendKeys(int count) {
    while (_friendRowKeys.length > count) {
      _friendRowKeys.removeLast();
    }
    while (_friendRowKeys.length < count) {
      _friendRowKeys.add(GlobalKey());
    }
  }

  void _scrollFriendIntoView(int i) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || i >= _friendRowKeys.length) return;
      final ctx = _friendRowKeys[i].currentContext;
      if (ctx != null) {
        Scrollable.ensureVisible(
          ctx,
          alignment: 0.12,
          duration: const Duration(milliseconds: 90),
        );
      }
    });
  }

  int _sidebarRowCount(List<RaFriend> friends) => 1 + friends.length;

  void _moveFriendSelection(int delta, int rowCount) {
    if (rowCount <= 0) return;
    final next = (_selectedFriendIndex + delta).clamp(0, rowCount - 1);
    if (next == _selectedFriendIndex) return;
    setState(() {
      _selectedFriendIndex = next;
      _detailTabIndex = 0;
    });
    _scrollFriendIntoView(next);
  }

  void _refreshSelectedRaData(RaCredentials creds, List<RaFriend> friends) {
    final name = _selectedUserName(creds, friends);
    ref.invalidate(raFriendsProvider);
    if (_selectedFriendIndex == 0) {
      ref.invalidate(raUserProfileProvider);
      ref.invalidate(raRecentGamesProvider);
    }
    ref.invalidate(raUserProfileForProvider(name));
    ref.invalidate(raRecentGamesForProvider(name));
    ref.invalidate(raRecentAchievementsForProvider(name));
  }

  String _selectedUserName(RaCredentials creds, List<RaFriend> friends) {
    if (_selectedFriendIndex == 0) return creds.username;
    final fi = _selectedFriendIndex - 1;
    if (fi >= 0 && fi < friends.length) return friends[fi].username;
    return creds.username;
  }

  void _pageDetailList(bool down) {
    final c = _detailTabIndex == 0 ? _playedScrollController : _achievementsScrollController;
    if (!c.hasClients) return;
    final pos = c.position;
    final step = pos.viewportDimension * 0.85;
    final target = (pos.pixels + (down ? step : -step)).clamp(0.0, pos.maxScrollExtent);
    c.jumpTo(target);
  }

  bool _consumeFriendsControllerAction(ControllerAction action) {
    if (!mounted || !widget.embeddedShell) return false;
    if (LibraryFocusBridge.stripRowHasPrimaryFocus()) {
      return false;
    }
    final friends = ref.read(raFriendsProvider).valueOrNull ?? [];
    final rowCount = _sidebarRowCount(friends);

    switch (action) {
      case ControllerAction.up:
        _moveFriendSelection(-1, rowCount);
        return true;
      case ControllerAction.down:
        _moveFriendSelection(1, rowCount);
        return true;
      case ControllerAction.left:
      case ControllerAction.right:
        return true;
      case ControllerAction.refresh:
        final creds = ref.read(raCredentialsProvider).valueOrNull;
        if (creds != null) _refreshSelectedRaData(creds, friends);
        return true;
      case ControllerAction.scrollPageUp:
        _pageDetailList(false);
        return true;
      case ControllerAction.scrollPageDown:
        _pageDetailList(true);
        return true;
      case ControllerAction.previousSection:
      case ControllerAction.nextSection:
        return false;
      case ControllerAction.back:
        return false;
      case ControllerAction.select:
      case ControllerAction.alphabetJump:
      case ControllerAction.openSearch:
        return false;
    }
  }

  bool _consumeFriendsKeyEvent(KeyEvent event) {
    if (!mounted || !widget.embeddedShell) return false;
    if (event is! KeyDownEvent) return false;
    ControllerAction? mapped = ControllerKeyMap.toControllerAction(event.logicalKey);
    if (mapped == ControllerAction.right) mapped = ControllerAction.left;
    if (mapped != null) return _consumeFriendsControllerAction(mapped);
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final credsAsync = ref.watch(raCredentialsProvider);

    final body = credsAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => _ErrorPane(
        message: 'Could not load account: $e',
        onRetry: () => ref.invalidate(raCredentialsProvider),
      ),
      data: (creds) {
        if (creds == null) {
          return _ConnectRaCallout(
            onOpenSettings: () => ref.read(currentTabIndexProvider.notifier).state = 2,
          );
        }

        final profileAsync = ref.watch(raUserProfileProvider);
        final friendsAsync = ref.watch(raFriendsProvider);

        return profileAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => _ErrorPane(
            message: 'Profile error: $e',
            onRetry: () {
              ref.invalidate(raUserProfileProvider);
              ref.invalidate(raFriendsProvider);
            },
          ),
          data: (selfProfile) {
            if (selfProfile == null) {
              return _ErrorPane(
                message: 'Could not load RetroAchievements profile.',
                onRetry: () => ref.invalidate(raUserProfileProvider),
              );
            }

            return friendsAsync.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => _ErrorPane(
                message: 'Friends error: $e',
                onRetry: () => ref.invalidate(raFriendsProvider),
              ),
              data: (friends) {
                final rows = _sidebarRowCount(friends);
                _syncFriendKeys(rows);
                final safeIdx = _selectedFriendIndex.clamp(0, rows - 1);
                if (safeIdx != _selectedFriendIndex) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted) setState(() => _selectedFriendIndex = safeIdx);
                  });
                }

                final selectedName = _selectedUserName(creds, friends);
                final isSelf = safeIdx == 0;

                return Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      flex: 1,
                      child: _FriendsSidebar(
                        selfUsername: creds.username,
                        selfProfile: selfProfile,
                        friends: friends,
                        selectedIndex: safeIdx,
                        rowKeys: _friendRowKeys,
                        scrollController: _friendsScrollController,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      flex: 3,
                      child: _FriendDetailPane(
                        tabIndex: _detailTabIndex,
                        onTabSelected: (i) => setState(() => _detailTabIndex = i),
                        isSelf: isSelf,
                        selectedUsername: selectedName,
                        playedScrollController: _playedScrollController,
                        achievementsScrollController: _achievementsScrollController,
                      ),
                    ),
                  ],
                );
              },
            );
          },
        );
      },
    );

    final wrapped = Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      child: body,
    );

    if (widget.embeddedShell && widget.shellFocusNode != null) {
      return Focus(
        focusNode: widget.shellFocusNode,
        child: wrapped,
      );
    }
    return Focus(
      focusNode: _standaloneFocus,
      child: wrapped,
    );
  }
}

class _ConnectRaCallout extends StatelessWidget {
  final VoidCallback onOpenSettings;

  const _ConnectRaCallout({required this.onOpenSettings});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.link_off_outlined, size: 56, color: Colors.white38),
            const SizedBox(height: 16),
            const Text(
              'Connect RetroAchievements',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Text(
              'Add your RetroAchievements username and web API key in Settings.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white.withValues(alpha: 0.65), height: 1.35),
            ),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: onOpenSettings,
              child: const Text('Open Settings'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorPane extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _ErrorPane({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.error_outline, color: Colors.redAccent, size: 40),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.tonal(onPressed: onRetry, child: const Text('Retry')),
        ],
      ),
    );
  }
}

class _FriendsSidebar extends StatelessWidget {
  final String selfUsername;
  final RaUserProfile selfProfile;
  final List<RaFriend> friends;
  final int selectedIndex;
  final List<GlobalKey> rowKeys;
  final ScrollController scrollController;

  const _FriendsSidebar({
    required this.selfUsername,
    required this.selfProfile,
    required this.friends,
    required this.selectedIndex,
    required this.rowKeys,
    required this.scrollController,
  });

  String _selfSubtitle() {
    final rp = selfProfile.richPresence?.trim();
    if (rp != null && rp.isNotEmpty) return rp;
    if (selfProfile.points > 0) return '${selfProfile.points} points';
    return 'No score yet — link your RetroAchievements account';
  }

  String _friendSubtitle(RaFriend f) {
    if (f.points > 0) return '${f.points} points';
    return 'RetroAchievements';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF0C1828),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF2A4464)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Friends',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: ScrollConfiguration(
              behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
              child: ListView(
                controller: scrollController,
                primary: false,
                padding: EdgeInsets.zero,
                children: [
                  KeyedSubtree(
                    key: rowKeys[0],
                    child: _FriendSidebarTile(
                      avatarLetter: selfUsername.isNotEmpty ? selfUsername[0] : '?',
                      title: 'My Activity ($selfUsername)',
                      subtitle: _selfSubtitle(),
                      highlight: selectedIndex == 0,
                    ),
                  ),
                  const SizedBox(height: 8),
                  for (var i = 0; i < friends.length; i++)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: KeyedSubtree(
                        key: rowKeys[i + 1],
                        child: _FriendSidebarTile(
                          avatarLetter:
                              friends[i].username.isNotEmpty ? friends[i].username[0] : '?',
                          title: friends[i].username,
                          subtitle: _friendSubtitle(friends[i]),
                          highlight: selectedIndex == i + 1,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _FriendSidebarTile extends StatelessWidget {
  final String avatarLetter;
  final String title;
  final String subtitle;
  final bool highlight;

  const _FriendSidebarTile({
    required this.avatarLetter,
    required this.title,
    required this.subtitle,
    required this.highlight,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 90),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      decoration: BoxDecoration(
        color: highlight ? const Color(0xFF1A3352) : const Color(0xFF122033),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: highlight ? const Color(0xFF6FA8FF) : const Color(0xFF1E3550),
          width: highlight ? 2 : 1,
        ),
        boxShadow: highlight
            ? [
                BoxShadow(
                  color: const Color(0xFF6FA8FF).withValues(alpha: 0.35),
                  blurRadius: 10,
                  spreadRadius: 0,
                ),
              ]
            : null,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          CircleAvatar(
            radius: 22,
            backgroundColor: const Color(0xFF2A4464),
            child: Text(
              avatarLetter.toUpperCase(),
              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
                ),
                const SizedBox(height: 3),
                Text(
                  subtitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.25,
                    color: Colors.white.withValues(alpha: 0.55),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _FriendDetailPane extends ConsumerWidget {
  final int tabIndex;
  final ValueChanged<int> onTabSelected;
  final bool isSelf;
  final String selectedUsername;
  final ScrollController playedScrollController;
  final ScrollController achievementsScrollController;

  const _FriendDetailPane({
    required this.tabIndex,
    required this.onTabSelected,
    required this.isSelf,
    required this.selectedUsername,
    required this.playedScrollController,
    required this.achievementsScrollController,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selfProfileAsync = ref.watch(raUserProfileProvider);
    final friendProfileAsync = ref.watch(raUserProfileForProvider(selectedUsername));
    final playedSelfAsync = ref.watch(raRecentGamesProvider);
    final playedFriendAsync = ref.watch(raRecentGamesForProvider(selectedUsername));
    final achievementsAsync = ref.watch(raRecentAchievementsForProvider(selectedUsername));

    final profileAsync = isSelf ? selfProfileAsync : friendProfileAsync;
    final playedAsync = isSelf ? playedSelfAsync : playedFriendAsync;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF0C1828),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF2A4464)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              _DetailTabChip(
                label: 'Played Games',
                selected: tabIndex == 0,
                onTap: () => onTabSelected(0),
              ),
              const SizedBox(width: 10),
              _DetailTabChip(
                label: 'Achievements',
                selected: tabIndex == 1,
                onTap: () => onTabSelected(1),
              ),
              const Spacer(),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Image.asset(
                    'src/assets/images/controls/360_LB.png',
                    width: 22,
                    height: 22,
                    errorBuilder: (_, _, _) => const SizedBox(width: 22, height: 22),
                  ),
                  const SizedBox(width: 4),
                  Image.asset(
                    'src/assets/images/controls/360_RB.png',
                    width: 22,
                    height: 22,
                    errorBuilder: (_, _, _) => const SizedBox(width: 22, height: 22),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'Change Tabs',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: Colors.white.withValues(alpha: 0.65),
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 14),
          profileAsync.when(
            loading: () => const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: LinearProgressIndicator(minHeight: 2),
            ),
            error: (e, _) => Text(
              'Could not load profile: $e',
              style: TextStyle(color: Colors.red.withValues(alpha: 0.9), fontSize: 13),
            ),
            data: (profile) {
              if (profile == null) {
                return Text(
                  'No profile for $selectedUsername.',
                  style: TextStyle(color: Colors.white.withValues(alpha: 0.6)),
                );
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    profile.username,
                    style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${profile.points} points · Loaded from RetroAchievements',
                    style: TextStyle(
                      fontSize: 13,
                      color: Colors.white.withValues(alpha: 0.55),
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              );
            },
          ),
          const SizedBox(height: 14),
          Expanded(
            child: tabIndex == 0
                ? playedAsync.when(
                    loading: () => const Center(child: CircularProgressIndicator()),
                    error: (e, _) => Center(child: Text('Games: $e')),
                    data: (games) => _PlayedGamesList(
                      games: games,
                      scrollController: playedScrollController,
                    ),
                  )
                : achievementsAsync.when(
                    loading: () => const Center(child: CircularProgressIndicator()),
                    error: (e, _) => Center(child: Text('Achievements: $e')),
                    data: (list) => _AchievementsList(
                      achievements: list,
                      scrollController: achievementsScrollController,
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _DetailTabChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _DetailTabChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 100),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: selected ? const Color(0xFF2B4A72) : const Color(0xFF122033),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: selected ? const Color(0xFF6FA8FF) : const Color(0xFF2A4464),
              width: selected ? 2 : 1,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontWeight: FontWeight.w800,
              fontSize: 13,
              color: selected ? Colors.white : Colors.white.withValues(alpha: 0.72),
            ),
          ),
        ),
      ),
    );
  }
}

class _PlayedGamesList extends StatelessWidget {
  final List<RaRecentGame> games;
  final ScrollController scrollController;

  const _PlayedGamesList({
    required this.games,
    required this.scrollController,
  });

  @override
  Widget build(BuildContext context) {
    if (games.isEmpty) {
      return Center(
        child: Text(
          'No recently played games.',
          style: TextStyle(color: Colors.white.withValues(alpha: 0.55)),
        ),
      );
    }
    return ScrollConfiguration(
      behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
      child: ListView.separated(
        controller: scrollController,
        primary: false,
        itemCount: games.length,
        separatorBuilder: (_, _) => const SizedBox(height: 10),
        itemBuilder: (context, index) {
          final g = games[index];
          return ExcludeFocus(
            child: Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0xFF122033),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0xFF1E3550)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: g.imageUrl != null
                        ? Image.network(
                            g.imageUrl!,
                            width: 56,
                            height: 56,
                            fit: BoxFit.cover,
                            errorBuilder: (_, _, _) => const _GameThumbPlaceholder(),
                          )
                        : const _GameThumbPlaceholder(),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          g.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          g.consoleName,
                          style: TextStyle(
                            fontSize: 13,
                            color: Colors.white.withValues(alpha: 0.55),
                          ),
                        ),
                        if (g.lastPlayed != null && g.lastPlayed!.trim().isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(
                              g.lastPlayed!,
                              style: TextStyle(
                                fontSize: 12,
                                color: Colors.white.withValues(alpha: 0.45),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _AchievementsList extends StatelessWidget {
  final List<RaRecentAchievement> achievements;
  final ScrollController scrollController;

  const _AchievementsList({
    required this.achievements,
    required this.scrollController,
  });

  @override
  Widget build(BuildContext context) {
    if (achievements.isEmpty) {
      return Center(
        child: Text(
          'No recent achievements in the last 30 days.',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.white.withValues(alpha: 0.55)),
        ),
      );
    }
    return ScrollConfiguration(
      behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
      child: ListView.separated(
        controller: scrollController,
        primary: false,
        itemCount: achievements.length,
        separatorBuilder: (_, _) => const SizedBox(height: 10),
        itemBuilder: (context, index) {
          final a = achievements[index];
          return ExcludeFocus(
            child: Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0xFF122033),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0xFF1E3550)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: a.badgeUrl != null
                        ? Image.network(
                            a.badgeUrl!,
                            width: 48,
                            height: 48,
                            fit: BoxFit.cover,
                            errorBuilder: (_, _, _) => const _BadgePlaceholder(),
                          )
                        : const _BadgePlaceholder(),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          a.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
                        ),
                        if (a.description.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(
                              a.description,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 11,
                                color: Colors.white.withValues(alpha: 0.5),
                              ),
                            ),
                          ),
                        const SizedBox(height: 4),
                        Text(
                          '${a.gameTitle} · ${a.consoleName}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.white.withValues(alpha: 0.48),
                          ),
                        ),
                        if (a.date.isNotEmpty)
                          Text(
                            a.date,
                            style: TextStyle(
                              fontSize: 11,
                              color: Colors.white.withValues(alpha: 0.42),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _GameThumbPlaceholder extends StatelessWidget {
  const _GameThumbPlaceholder();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 56,
      height: 56,
      color: const Color(0xFF1E3550),
      child: const Icon(Icons.sports_esports, size: 26, color: Colors.white24),
    );
  }
}

class _BadgePlaceholder extends StatelessWidget {
  const _BadgePlaceholder();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 48,
      height: 48,
      color: const Color(0xFF1E3550),
      child: const Icon(Icons.military_tech, size: 24, color: Colors.white24),
    );
  }
}
