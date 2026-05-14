import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../core/romm/romm_models.dart';
import '../../core/romm/romm_service.dart';
import '../../core/error/error_handler.dart';
import '../../core/input/xinput_controller_service.dart';
import '../../core/input/controller_keymap.dart';
import '../../providers/download_provider.dart';
import '../../providers/romm_provider.dart';
import '../../providers/shared_prefs_provider.dart';
import '../library_focus_bridge.dart';
import '../widgets/screenshot_gallery_dialog.dart';
import '../widgets/download_progress_indicator.dart';

/// Surfaces aligned with [MaterialApp] theme and library shell panels.
abstract final class GameDetailShell {
  static const Color scaffoldBg = Color(0xFF0A121D);
  static const Color panel = Color(0xFF0F1A2A);
  static const Color panelBorder = Color(0xFF2A4464);
  static const Color cardFill = Color(0xFF122033);
  static const Color cardBorder = Color(0xFF24405F);
  static const Color divider = Color(0xFF284061);
  static const Color tileBg = Color(0xFF101E30);
  static const Color tileBorder = Color(0xFF1E3550);
  static const Color outlineBtn = Color(0xFF35577E);
  static const Color accent = Color(0xFF2A4F7D);
  static const Color focusRing = Color(0xFF6FA8FF);
}

/// Where full-screen [GameDetailScreen] goes when dismissed with **B** / Escape.
enum GameDetailExitDestination {
  /// Stay on the shell route that opened detail (e.g. Home spotlight).
  callerShell,
  /// Navigate shell to Store and focus the platform game grid (opened from Store).
  storeGameGrid,
}

class GameDetailScreen extends ConsumerStatefulWidget {
  final Game game;
  final String rommBaseUrl;
  final bool isDownloaded;
  final dynamic onDownload;
  final dynamic onDelete;
  final RommService? rommService;
  final GameDetailExitDestination exitDestination;

  const GameDetailScreen({
    super.key,
    required this.game,
    required this.rommBaseUrl,
    required this.isDownloaded,
    required this.onDownload,
    required this.onDelete,
    this.rommService,
    this.exitDestination = GameDetailExitDestination.storeGameGrid,
  });

  @override
  ConsumerState<GameDetailScreen> createState() => _GameDetailScreenState();
}

class _GameDetailScreenState extends ConsumerState<GameDetailScreen> {
  late Game _currentGame;
  late bool _isDownloaded;
  late bool _backlogged;
  late bool _nowPlaying;
  late int _rating;
  late String? _status;
  late int _completion;
  bool _isSaving = false;
  final ScrollController _detailScrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _currentGame = widget.game;
    _isDownloaded = widget.isDownloaded;
    _syncStateWithGame(_currentGame);
    _checkDownloadStatus();
    // Targeted Lazy Sync: Ensure this game is mapped if it exists on disk
    _lazySync();
    // Initial refresh to get latest notes and status
    _refreshGame();
    LibraryFocusBridge.consumeGameDetailControllerAction = _consumeGameDetailController;
    LibraryFocusBridge.consumeGameDetailKeyEvent = _consumeGameDetailKey;
  }

  @override
  void dispose() {
    if (LibraryFocusBridge.consumeGameDetailControllerAction == _consumeGameDetailController) {
      LibraryFocusBridge.consumeGameDetailControllerAction = null;
    }
    if (LibraryFocusBridge.consumeGameDetailKeyEvent == _consumeGameDetailKey) {
      LibraryFocusBridge.consumeGameDetailKeyEvent = null;
    }
    _detailScrollController.dispose();
    super.dispose();
  }

  bool _gameDetailRouteIsCurrent() {
    final route = ModalRoute.of(context);
    return route != null && route.isCurrent;
  }

  bool _focusIsInEditableText() {
    final ctx = FocusManager.instance.primaryFocus?.context;
    if (ctx == null) return false;
    return ctx.findAncestorStateOfType<EditableTextState>() != null;
  }

  bool _consumeGameDetailController(ControllerAction action) {
    if (!_gameDetailRouteIsCurrent()) return false;
    if (action == ControllerAction.scrollPageUp) {
      _scrollDetailPage(up: true);
      return true;
    }
    if (action == ControllerAction.scrollPageDown) {
      _scrollDetailPage(up: false);
      return true;
    }
    if (_focusIsInEditableText()) return false;
    switch (action) {
      case ControllerAction.select:
        _invokePrimaryDownloadOrResume();
        return true;
      case ControllerAction.back:
        _popGameDetail();
        return true;
      default:
        return false;
    }
  }

  void _scrollDetailPage({required bool up}) {
    if (!_detailScrollController.hasClients || !mounted) return;
    final step = MediaQuery.sizeOf(context).height * 0.18;
    final pos = _detailScrollController.position;
    final delta = up ? -step : step;
    _detailScrollController.jumpTo(
      (pos.pixels + delta).clamp(0.0, pos.maxScrollExtent),
    );
  }

  String _controllerHintSelectLabel() {
    if (_isDownloaded) return 'Remove game';
    final p = ref.watch(downloadProvider)[_currentGame.id];
    if (p != null && !p.isComplete && p.error == null) {
      if (p.isPaused) return 'Resume download';
      return 'Pause · use screen';
    }
    return 'Download';
  }

  Widget _buildControllerHintBar() {
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    return DecoratedBox(
      decoration: const BoxDecoration(
        color: Color(0xFF0D1828),
        border: Border(top: BorderSide(color: Color(0xFF284061))),
      ),
      child: Padding(
        padding: EdgeInsets.fromLTRB(8, 10, 8, 10 + bottomInset),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.start,
            children: [
              _DetailHintChip(
                asset: 'src/assets/images/controls/360_LT.png',
                label: 'Scroll up',
              ),
              _DetailHintChip(
                asset: 'src/assets/images/controls/360_RT.png',
                label: 'Scroll down',
              ),
              _DetailHintChip(
                asset: 'src/assets/images/controls/360_A.png',
                label: _controllerHintSelectLabel(),
              ),
              _DetailHintChip(
                asset: 'src/assets/images/controls/360_B.png',
                label: widget.exitDestination == GameDetailExitDestination.callerShell
                    ? 'Back · Spotlight'
                    : 'Back · Store list',
              ),
            ],
          ),
        ),
      ),
    );
  }

  bool _consumeGameDetailKey(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    if (!_gameDetailRouteIsCurrent()) return false;
    if (_focusIsInEditableText()) return false;
    final key = event.logicalKey;
    if (ControllerKeyMap.isSelect(key)) {
      _invokePrimaryDownloadOrResume();
      return true;
    }
    if (ControllerKeyMap.isBack(key)) {
      _popGameDetail();
      return true;
    }
    return false;
  }

  void _popGameDetail() {
    switch (widget.exitDestination) {
      case GameDetailExitDestination.storeGameGrid:
        LibraryFocusBridge.returnFromGameDetailToStore?.call(_currentGame.platformId);
        break;
      case GameDetailExitDestination.callerShell:
        LibraryFocusBridge.refocusHomeShelfAfterDetailPop?.call(_currentGame.id);
        break;
    }
    if (mounted) {
      Navigator.of(context, rootNavigator: true).pop();
    }
  }

  Future<void> _invokePrimaryDownloadOrResume() async {
    if (_isDownloaded) {
      if (!mounted) return;
      final confirmed = await _showDeleteDownloadedConfirmation();
      if (!mounted || confirmed != true) return;
      await widget.onDelete();
      ref.invalidate(downloadProvider);
      await _checkDownloadStatus();
      return;
    }
    final progress = ref.read(downloadProvider)[_currentGame.id];
    if (progress != null &&
        !progress.isComplete &&
        progress.error == null &&
        !progress.isPaused) {
      return;
    }
    if (progress != null &&
        !progress.isComplete &&
        progress.isPaused &&
        progress.downloadUrl != null) {
      ref.read(downloadProvider.notifier).startDownload(
            progress.game ?? _currentGame,
            progress.downloadUrl!,
          );
      await _checkDownloadStatus();
      return;
    }
    await widget.onDownload();
    await _checkDownloadStatus();
  }

  Future<void> _lazySync() async {
    final scanner = ref.read(romScannerServiceProvider);
    if (scanner != null) {
      await scanner.syncSingleGame(_currentGame);
      // Re-check status after sync to update the "Play" button if found
      _checkDownloadStatus();
    }
  }

  void _syncStateWithGame(Game game) {
    _backlogged = game.backlogged;
    _nowPlaying = game.nowPlaying;
    _rating = game.userRating;
    _status = game.status;
    _completion = game.completion;
  }

  Future<void> _checkDownloadStatus() async {
    final ds = ref.read(directoryServiceProvider).value;
    if (ds != null) {
      final exists = await ds.isRomDownloaded(_currentGame);
      if (mounted) {
        setState(() => _isDownloaded = exists);
      }
    }
  }

  Future<void> _refreshGame() async {
    if (widget.rommService == null) return;
    try {
      final updated = await widget.rommService!.getGame(_currentGame.id);
      if (updated != null && mounted) {
        setState(() {
          _currentGame = updated;
          _syncStateWithGame(updated);
        });
        _checkDownloadStatus();

        // Update persistent cache so the list view and offline mode have the latest details
        final cacheService = ref.read(metadataCacheServiceProvider).value;
        if (cacheService != null) {
          await cacheService.saveGames([updated]);
        }
      }
    } catch (_) {}
  }

  Future<void> _addNote() async {
    final titleController = TextEditingController();
    final contentController = TextEditingController();

    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add Note'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: titleController,
              decoration: const InputDecoration(labelText: 'Title'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: contentController,
              decoration: const InputDecoration(labelText: 'Content'),
              maxLines: 3,
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Add'),
          ),
        ],
      ),
    );

    if (result == true && widget.rommService != null) {
      final title = titleController.text.trim();
      final content = contentController.text.trim();
      if (title.isNotEmpty || content.isNotEmpty) {
        final success = await widget.rommService!.createRomNote(_currentGame.id, title, content);
        if (success) {
          _refreshGame();
        } else {
          if (mounted) {
            // ignore: use_build_context_synchronously
            ErrorHandler.showException(context, Exception('Failed to create note'), contextLabel: 'Add Note');
          }
        }
      }
    }
  }

  Future<void> _deleteNote(int noteId) async {
    if (widget.rommService == null) return;
    
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Note'),
        content: const Text('Are you sure you want to delete this note?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirm == true) {
      final success = await widget.rommService!.deleteRomNote(_currentGame.id, noteId);
      if (success) {
        _refreshGame();
      } else {
        if (mounted) {
          // ignore: use_build_context_synchronously
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Failed to delete note')));
        }
      }
    }
  }

  void _viewNote(RomNote note) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(note.title.isNotEmpty ? note.title : 'Note'),
        content: SingleChildScrollView(
          child: Text(note.content),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _saveProps(BuildContext context) async {
    if (widget.rommService == null) return;
    
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _isSaving = true);
    
    final prefs = ref.read(sharedPreferencesProvider);
    final success = await widget.rommService!.updateRomProps(
      _currentGame.id,
      prefs,
      backlogged: _backlogged,
      nowPlaying: _nowPlaying,
      rating: _rating,
      status: _status,
      completion: _completion,
    );
    
    if (mounted) {
      setState(() => _isSaving = false);
      if (success) {
        _refreshGame();
        messenger.showSnackBar(
          const SnackBar(content: Text('Properties saved successfully')),
        );
      } else {
        // Safe to use ErrorHandler here if it's a global/static UI helper
        // but let's be double sure and check mounted again
        if (mounted) {
          // ignore: use_build_context_synchronously
          ErrorHandler.showException(context, Exception('Failed to update properties'), contextLabel: 'Update Status');
        }
      }
    }
  }

  void _showScreenshotFullscreen(BuildContext context, int initialIndex, List<String> imageUrls) {
    showDialog(
      context: context,
      useRootNavigator: true,
      builder: (context) => ScreenshotGalleryDialog(
        initialIndex: initialIndex,
        imageUrls: imageUrls,
      ),
    );
  }

  String _normalizeUrl(String? path) {
    if (path == null || path.isEmpty) return '';
    if (path.startsWith('http')) return path;
    final base = widget.rommBaseUrl.endsWith('/')
        ? widget.rommBaseUrl.substring(0, widget.rommBaseUrl.length - 1)
        : widget.rommBaseUrl;
    final normalizedPath = path.startsWith('/') ? path : '/$path';
    return '$base$normalizedPath';
  }

  /// Returns true only if the user chooses **Yes**. **No** is focused first (controller-safe default).
  /// Styled to match [GameDetailShell] (single confirmation — [handleDeleteRom] skips its own dialog).
  Future<bool> _showDeleteDownloadedConfirmation() async {
    final noFocus = FocusNode(debugLabel: 'delete_rom_no');
    try {
      final result = await showDialog<bool>(
        context: context,
        useRootNavigator: true,
        barrierColor: Colors.black.withValues(alpha: 0.72),
        builder: (dialogContext) {
          return AlertDialog(
            backgroundColor: GameDetailShell.panel,
            surfaceTintColor: Colors.transparent,
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
              side: const BorderSide(color: GameDetailShell.panelBorder),
            ),
            title: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.delete_forever_outlined,
                  color: Colors.redAccent.withValues(alpha: 0.95),
                  size: 28,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Remove download?',
                    style: Theme.of(dialogContext).textTheme.titleLarge?.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                ),
              ],
            ),
            content: Text(
              'This removes "${_currentGame.name}" from this device and deletes the local ROM file. You can download it again from your RomM library later.',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.78),
                height: 1.45,
                fontSize: 14,
              ),
            ),
            actionsAlignment: MainAxisAlignment.end,
            actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            actions: [
              TextButton(
                focusNode: noFocus,
                autofocus: true,
                style: TextButton.styleFrom(
                  foregroundColor: Colors.white70,
                  side: const BorderSide(color: GameDetailShell.outlineBtn),
                  padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('No', style: TextStyle(fontWeight: FontWeight.w600)),
              ),
              const SizedBox(width: 8),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFFB71C1C),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('Remove', style: TextStyle(fontWeight: FontWeight.w700)),
              ),
            ],
          );
        },
      );
      return result ?? false;
    } finally {
      noFocus.dispose();
    }
  }

  Future<bool> _showCancelConfirmation(BuildContext context, String gameName) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Cancel Download'),
        content: Text('Are you sure you want to cancel downloading $gameName? This will delete the partial file.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Cancel Download', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(downloadProvider, (prev, next) {
      final progress = next[_currentGame.id];
      if (progress != null && progress.isComplete) {
        // Download just finished
        _checkDownloadStatus();
        // Remove from progress map so we show the action buttons instead of "100% Done"
        ref.read(downloadProvider.notifier).removeDownload(_currentGame.id);
      }
    });

    final theme = Theme.of(context);
    final size = MediaQuery.of(context).size;
    final headerHeight = size.height * 0.4;

    String? backgroundUrl;
    if (_currentGame.screenshotUrl != null && _currentGame.screenshotUrl!.isNotEmpty) {
      backgroundUrl = _normalizeUrl(_currentGame.screenshotUrl);
    } else if (_currentGame.mergedScreenshots.isNotEmpty) {
      backgroundUrl = _normalizeUrl(_currentGame.mergedScreenshots.first);
    }

    return Scaffold(
      backgroundColor: GameDetailShell.scaffoldBg,
      bottomNavigationBar: _buildControllerHintBar(),
      body: SingleChildScrollView(
        controller: _detailScrollController,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // SECTION 1 - Hero header
            SizedBox(
              height: headerHeight,
              child: Stack(
                children: [
                  // Background Image
                  Positioned.fill(
                    child: backgroundUrl != null
                        ? CachedNetworkImage(
                            imageUrl: backgroundUrl,
                            fit: BoxFit.cover,
                            placeholder: (context, url) =>
                                Container(color: GameDetailShell.cardFill),
                            errorWidget: (context, url, error) =>
                                Container(color: GameDetailShell.cardFill),
                          )
                        : Container(color: GameDetailShell.cardFill),
                  ),
                  // Gradient Overlay — blend into app scaffold
                  Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Colors.transparent,
                            GameDetailShell.scaffoldBg.withValues(alpha: 0.65),
                            GameDetailShell.scaffoldBg,
                          ],
                          stops: const [0.45, 0.82, 1.0],
                        ),
                      ),
                    ),
                  ),
                  // Back Button
                  Positioned(
                    top: MediaQuery.of(context).padding.top + 8,
                    left: 16,
                    child: OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: GameDetailShell.outlineBtn),
                        foregroundColor: Colors.white70,
                        padding: const EdgeInsets.all(10),
                        minimumSize: const Size(44, 44),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                      onPressed: _popGameDetail,
                      child: const Icon(Icons.arrow_back, size: 20),
                    ),
                  ),
                  // Content (Cover + Title)
                  Positioned(
                    bottom: 16,
                    left: 16,
                    right: 16,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        // Cover Image
                        Hero(
                          tag: 'game_cover_${_currentGame.id}',
                          child: Container(
                            width: 130,
                            height: 180,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(8),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.45),
                                  blurRadius: 12,
                                  offset: const Offset(0, 4),
                                ),
                              ],
                            ),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: CachedNetworkImage(
                                imageUrl: _normalizeUrl(_currentGame.pathCoverLarge),
                                fit: BoxFit.cover,
                                placeholder: (context, url) =>
                                    Container(color: GameDetailShell.cardFill),
                                errorWidget: (context, url, error) =>
                                    Icon(Icons.image_not_supported, color: Colors.white.withValues(alpha: 0.35)),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 16),
                        // Title and Platform
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                _currentGame.name,
                                style: theme.textTheme.headlineSmall?.copyWith(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                ),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                              if (_currentGame.platformDisplayName != null)
                                Text(
                                  _currentGame.platformDisplayName!,
                                  style: theme.textTheme.titleMedium?.copyWith(
                                    color: Colors.white70,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
              child: Container(
                width: double.infinity,
                decoration: BoxDecoration(
                  color: GameDetailShell.panel,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: GameDetailShell.panelBorder),
                ),
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                  // SECTION 2 - Action buttons row
                  Consumer(
                    builder: (context, ref, _) {
                      final downloads = ref.watch(downloadProvider);
                      final progress = downloads[_currentGame.id];

                      return SizedBox(
                        width: double.infinity,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            if (!_isDownloaded)
                              if (progress != null) ...[
                                Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 8.0),
                                  child: DownloadProgressIndicator(
                                    progress: progress,
                                    compact: true,
                                  ),
                                ),
                                const SizedBox(height: 12),
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                                  children: [
                                    if (!progress.isComplete && progress.error == null)
                                      _ActionButton(
                                        icon: progress.isPaused ? Icons.play_arrow : Icons.pause,
                                        label: progress.isPaused ? 'Resume' : 'Pause',
                                        onPressed: () {
                                          if (progress.isPaused) {
                                            if (progress.game != null && progress.downloadUrl != null) {
                                              ref.read(downloadProvider.notifier).startDownload(
                                                progress.game!,
                                                progress.downloadUrl!,
                                              );
                                            }
                                          } else {
                                            ref.read(downloadProvider.notifier).pauseDownload(_currentGame.id);
                                          }
                                        },
                                      ),
                                    _ActionButton(
                                      icon: Icons.close,
                                      label: 'Cancel',
                                      color: Colors.red,
                                      onPressed: () async {
                                        if (progress.isComplete || progress.error != null) {
                                          ref.read(downloadProvider.notifier).cancelDownload(_currentGame.id);
                                        } else if (await _showCancelConfirmation(context, progress.gameName)) {
                                          ref.read(downloadProvider.notifier).cancelDownload(_currentGame.id);
                                        }
                                      },
                                    ),
                                  ],
                                ),
                              ] else
                                _SteamDownloadButton(
                                  onPressed: () async {
                                    await widget.onDownload();
                                    _checkDownloadStatus();
                                  },
                                )
                            else ...[
                              _ActionButton(
                                icon: Icons.delete,
                                label: 'Delete',
                                onPressed: () async {
                                  if (!await _showDeleteDownloadedConfirmation()) return;
                                  await widget.onDelete();
                                  ref.invalidate(downloadProvider);
                                  _checkDownloadStatus();
                                },
                                color: Colors.red,
                              ),
                            ],
                          ],
                        ),
                      );
                    },
                  ),

                  const SizedBox(height: 24),

                  // SECTION 3 - Metadata chips row
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      // Genres (first 2)
                      ..._currentGame.genres.take(2).map((g) => _MetadataChip(label: g)),
                      // Player Count
                      if (_currentGame.playerCount != null && _currentGame.playerCount!.isNotEmpty)
                        _MetadataChip(
                          label: _currentGame.playerCount!,
                          icon: Icons.people_outline,
                        ),
                      // Average Rating
                      if (_currentGame.averageRating != null)
                        _MetadataChip(
                          label: '${_currentGame.averageRating!.toStringAsFixed(0)}/100',
                          icon: Icons.star_outline,
                        ),
                      // Release Year
                      if (_currentGame.firstReleaseDate != null)
                        _MetadataChip(
                          label: DateTime.fromMillisecondsSinceEpoch(_currentGame.firstReleaseDate!).year.toString(),
                          icon: Icons.calendar_today_outlined,
                        ),
                    ],
                  ),
                  const SizedBox(height: 24),

                  // SECTION 4 - Description
                  Text(
                    'About',
                    style: theme.textTheme.titleLarge?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _currentGame.summary ?? 'No description available',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: Colors.white70,
                      height: 1.5,
                    ),
                  ),
                  const SizedBox(height: 24),

                  // SECTION 5 - Details grid
                  Text(
                    'Details',
                    style: theme.textTheme.titleLarge?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 12),
                  _DetailsGrid(game: _currentGame),
                  const SizedBox(height: 24),

                  // SECTION 6 - Notes
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'Notes',
                        style: theme.textTheme.titleLarge?.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.add_comment, color: GameDetailShell.focusRing),
                        tooltip: 'Add note',
                        onPressed: _addNote,
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  if (_currentGame.notes.isEmpty)
                    const Text('No notes added yet.', style: TextStyle(color: Colors.white54, fontSize: 13))
                  else
                    ..._currentGame.notes.map((note) => Card(
                      color: GameDetailShell.cardFill,
                      elevation: 0,
                      margin: const EdgeInsets.only(bottom: 8),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                        side: const BorderSide(color: GameDetailShell.cardBorder),
                      ),
                      child: ListTile(
                        onTap: () => _viewNote(note),
                        title: Text(
                          note.title.isNotEmpty ? note.title : 'Note',
                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          note.content,
                          style: const TextStyle(color: Colors.white70),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: IconButton(
                          icon: const Icon(Icons.delete_outline, color: Colors.white38, size: 18),
                          onPressed: () => _deleteNote(note.id),
                        ),
                      ),
                    )),
                  const SizedBox(height: 24),

                  // SECTION 7 - Screenshots
                  if (_currentGame.mergedScreenshots.isNotEmpty) ...[
                    Text(
                      'Screenshots',
                      style: theme.textTheme.titleLarge?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      height: 120,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemCount: _currentGame.mergedScreenshots.length,
                        separatorBuilder: (context, index) => const SizedBox(width: 12),
                        itemBuilder: (context, index) {
                          final imageUrl = _normalizeUrl(_currentGame.mergedScreenshots[index]);
                          return GestureDetector(
                            onTap: () {
                              final allUrls = _currentGame.mergedScreenshots
                                  .map((path) => _normalizeUrl(path))
                                  .toList();
                              _showScreenshotFullscreen(context, index, allUrls);
                            },
                            child: Container(
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(color: GameDetailShell.cardBorder),
                                color: GameDetailShell.cardFill,
                              ),
                              clipBehavior: Clip.antiAlias,
                              width: 200,
                              height: 120,
                              child: CachedNetworkImage(
                                imageUrl: imageUrl,
                                fit: BoxFit.cover,
                                placeholder: (context, url) =>
                                    Container(color: GameDetailShell.cardFill),
                                errorWidget: (context, url, error) =>
                                    Icon(Icons.image_not_supported,
                                        color: Colors.white.withValues(alpha: 0.35)),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: 24),
                  ],

                  // SECTION 7 - Personal
                  const SizedBox(height: 8),
                  const Divider(color: GameDetailShell.divider, height: 1),
                  const SizedBox(height: 8),
                  Text('Personal', style: theme.textTheme.titleLarge?.copyWith(
                    color: Colors.white, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 16),

                  // Status dropdown
                  Row(
                    children: [
                      const Text('Status', style: TextStyle(color: Colors.white54, fontSize: 13)),
                      const Spacer(),
                      DropdownButton<String>(
                        value: const [
                          'never_playing',
                          'incomplete',
                          'finished',
                          'completed_100',
                          'retired'
                        ].contains(_status) ? _status : null,
                        dropdownColor: GameDetailShell.panel,
                        style: const TextStyle(color: Colors.white),
                        hint: const Text('Not set', style: TextStyle(color: Colors.white54)),
                        underline: const SizedBox(),
                        items: const [
                          DropdownMenuItem(value: 'never_playing', child: Text('Never Played')),
                          DropdownMenuItem(value: 'incomplete', child: Text('Incomplete')),
                          DropdownMenuItem(value: 'finished', child: Text('Finished')),
                          DropdownMenuItem(value: 'completed_100', child: Text('100% Completed')),
                          DropdownMenuItem(value: 'retired', child: Text('Dropped')),
                        ],
                        onChanged: (val) => setState(() => _status = val),
                      ),
                    ],
                  ),

                  // Rating stars
                  Row(
                    children: [
                      const Text('Rating', style: TextStyle(color: Colors.white54, fontSize: 13)),
                      const Spacer(),
                      Row(
                        children: List.generate(10, (i) => GestureDetector(
                          onTap: () => setState(() => _rating = i + 1),
                          child: Icon(
                            i < _rating ? Icons.star : Icons.star_border,
                            color: Colors.amber,
                            size: 20,
                          ),
                        )),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),

                  // Completion slider
                  Row(
                    children: [
                      const Text('Completion', style: TextStyle(color: Colors.white54, fontSize: 13)),
                      const Spacer(),
                      Text('$_completion%', style: const TextStyle(color: Colors.white)),
                    ],
                  ),
                  SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      activeTrackColor: GameDetailShell.accent,
                      inactiveTrackColor: Colors.white24,
                      thumbColor: GameDetailShell.focusRing,
                      overlayColor: WidgetStateColor.resolveWith(
                        (_) => GameDetailShell.focusRing.withValues(alpha: 0.18),
                      ),
                    ),
                    child: Slider(
                      value: _completion.toDouble(),
                      min: 0,
                      max: 100,
                      divisions: 20,
                      label: '$_completion%',
                      onChanged: (val) => setState(() => _completion = val.toInt()),
                    ),
                  ),

                  // Toggles row
                  Row(
                    children: [
                      Expanded(
                        child: SwitchListTile(
                          title: const Text('Backlog',
                              style: TextStyle(fontSize: 13, color: Colors.white70)),
                          value: _backlogged,
                          activeTrackColor: GameDetailShell.accent.withValues(alpha: 0.55),
                          activeThumbColor: Colors.white,
                          inactiveTrackColor: Colors.white24,
                          inactiveThumbColor: Colors.white54,
                          onChanged: (val) => setState(() => _backlogged = val),
                          contentPadding: EdgeInsets.zero,
                        ),
                      ),
                      Expanded(
                        child: SwitchListTile(
                          title: const Text('Now Playing',
                              style: TextStyle(fontSize: 13, color: Colors.white70)),
                          value: _nowPlaying,
                          activeTrackColor: GameDetailShell.accent.withValues(alpha: 0.55),
                          activeThumbColor: Colors.white,
                          inactiveTrackColor: Colors.white24,
                          inactiveThumbColor: Colors.white54,
                          onChanged: (val) => setState(() => _nowPlaying = val),
                          contentPadding: EdgeInsets.zero,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),

                  // Save button
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: _isSaving ? null : () => _saveProps(context),
                      child: _isSaving
                          ? const SizedBox(height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Text('Save'),
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
              ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Xbox-style legend for game detail (matches shell hint strip in [RommStoreApp]).
class _DetailHintChip extends StatelessWidget {
  final String asset;
  final String label;

  const _DetailHintChip({
    required this.asset,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Image.asset(
            asset,
            width: 18,
            height: 18,
            fit: BoxFit.contain,
            errorBuilder: (context, error, stackTrace) =>
                const Icon(Icons.gamepad_outlined, size: 16, color: Colors.white54),
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
      ),
    );
  }
}

/// Steam-client style primary install/download control (green gradient bar).
class _SteamDownloadButton extends StatelessWidget {
  final VoidCallback onPressed;

  const _SteamDownloadButton({required this.onPressed});

  static const Color _greenTop = Color(0xFF9DC556);
  static const Color _greenMid = Color(0xFF7BA428);
  static const Color _greenBottom = Color(0xFF5E8019);
  static const Color _border = Color(0xFF4A6B14);

  @override
  Widget build(BuildContext context) {
    const radius = 3.0;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(radius),
        splashColor: Colors.white24,
        highlightColor: Colors.white10,
        child: Ink(
          height: 46,
          width: double.infinity,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(radius),
            gradient: const LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [_greenTop, _greenMid, _greenBottom],
              stops: [0.0, 0.42, 1.0],
            ),
            border: Border.all(color: _border, width: 1),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.5),
                blurRadius: 8,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: Stack(
            alignment: Alignment.center,
            children: [
              // Subtle top gloss line (Steam-ish highlight)
              Positioned(
                top: 2,
                left: 8,
                right: 8,
                child: Container(
                  height: 1,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(1),
                    gradient: LinearGradient(
                      colors: [
                        Colors.white.withValues(alpha: 0),
                        Colors.white.withValues(alpha: 0.22),
                        Colors.white.withValues(alpha: 0),
                      ],
                    ),
                  ),
                ),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.download_rounded, color: Colors.white.withValues(alpha: 0.96), size: 23),
                  const SizedBox(width: 12),
                  Text(
                    'DOWNLOAD',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.97),
                      fontWeight: FontWeight.w700,
                      fontSize: 14,
                      letterSpacing: 1.35,
                      shadows: [
                        Shadow(
                          color: Colors.black.withValues(alpha: 0.42),
                          offset: const Offset(0, 1),
                          blurRadius: 2,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onPressed;
  final Color? color;

  const _ActionButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final fg = color ?? Colors.white70;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: GameDetailShell.tileBg,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: GameDetailShell.tileBorder),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: fg, size: 26),
              const SizedBox(height: 6),
              Text(
                label,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: fg, fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MetadataChip extends StatelessWidget {
  final String label;
  final IconData? icon;

  const _MetadataChip({required this.label, this.icon});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: GameDetailShell.cardFill,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: GameDetailShell.cardBorder),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 14, color: Colors.white.withValues(alpha: 0.65)),
            const SizedBox(width: 6),
          ],
          Text(
            label,
            style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w500),
          ),
        ],
      ),
    );
  }
}

class _DetailsGrid extends StatelessWidget {
  final Game game;

  const _DetailsGrid({required this.game});

  @override
  Widget build(BuildContext context) {
    final details = <String, String>{};
    if (game.companies.isNotEmpty) details['Developer'] = game.companies.join(', ');
    if (game.regions.isNotEmpty) details['Regions'] = game.regions.join(', ');
    if (game.languages.isNotEmpty) details['Languages'] = game.languages.join(', ');
    if (game.playerCount != null && game.playerCount!.isNotEmpty) details['Players'] = game.playerCount!;

    if (details.isEmpty) return const SizedBox.shrink();

    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisExtent: 40,
        crossAxisSpacing: 16,
        mainAxisSpacing: 8,
      ),
      itemCount: details.length,
      itemBuilder: (context, index) {
        final entry = details.entries.elementAt(index);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              entry.key,
              style: const TextStyle(color: Colors.white54, fontSize: 12),
            ),
            Text(
              entry.value,
              style: const TextStyle(color: Colors.white, fontSize: 14),
              overflow: TextOverflow.ellipsis,
            ),
          ],
        );
      },
    );
  }
}
