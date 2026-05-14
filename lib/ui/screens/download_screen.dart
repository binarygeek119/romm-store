import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/input/xinput_controller_service.dart';
import '../../core/input/controller_keymap.dart';
import '../../core/downloader/download_service.dart';
import '../../core/audio/ui_sfx_service.dart';
import '../../providers/download_provider.dart';
import '../library_focus_bridge.dart';
import '../widgets/download_progress_card.dart';

class DownloadScreen extends ConsumerStatefulWidget {
  /// When true (nested under library shell), hides the duplicate AppBar.
  final bool embeddedShell;

  /// Xbox / keyboard focus scope for the embedded shell body ([embeddedShell] only).
  final FocusNode? shellFocusNode;

  const DownloadScreen({super.key, this.embeddedShell = false, this.shellFocusNode});

  @override
  ConsumerState<DownloadScreen> createState() => _DownloadScreenState();
}

class _DownloadScreenState extends ConsumerState<DownloadScreen> {
  int _selectedIndex = 0;
  final FocusNode _standaloneFocus = FocusNode(debugLabel: 'downloads_list_scope');
  final ScrollController _listScrollController = ScrollController();
  final List<GlobalKey> _rowKeys = <GlobalKey>[];
  bool _cancelDialogOpen = false;
  final ValueNotifier<bool> _cancelDialogYesSelected = ValueNotifier<bool>(false);

  FocusNode get _activeFocusNode => widget.shellFocusNode ?? _standaloneFocus;

  @override
  void initState() {
    super.initState();
    LibraryFocusBridge.consumeDownloadsBodyControllerAction = _consumeDownloadsControllerAction;
    LibraryFocusBridge.consumeDownloadsBodyKeyEvent = _consumeDownloadsKeyEvent;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _activeFocusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    if (LibraryFocusBridge.consumeDownloadsBodyControllerAction == _consumeDownloadsControllerAction) {
      LibraryFocusBridge.consumeDownloadsBodyControllerAction = null;
    }
    if (LibraryFocusBridge.consumeDownloadsBodyKeyEvent == _consumeDownloadsKeyEvent) {
      LibraryFocusBridge.consumeDownloadsBodyKeyEvent = null;
    }
    _cancelDialogYesSelected.dispose();
    _listScrollController.dispose();
    _standaloneFocus.dispose();
    super.dispose();
  }

  void _syncRowKeys(int count) {
    while (_rowKeys.length > count) {
      _rowKeys.removeLast();
    }
    while (_rowKeys.length < count) {
      _rowKeys.add(GlobalKey());
    }
  }

  void _scrollToSelected() {
    final entries = _entries();
    if (entries.isEmpty) return;
    final i = _selectedIndex.clamp(0, entries.length - 1);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || i >= _rowKeys.length) return;
      final rowContext = _rowKeys[i].currentContext;
      if (rowContext != null) {
        Scrollable.ensureVisible(
          rowContext,
          alignment: 0.2,
          duration: const Duration(milliseconds: 90),
        );
      }
    });
  }

  List<MapEntry<String, DownloadProgress>> _entries() {
    final entries = ref.read(downloadProvider).entries.toList(growable: false);
    if (entries.isEmpty) return entries;
    final clamped = _selectedIndex.clamp(0, entries.length - 1);
    if (clamped != _selectedIndex) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _selectedIndex = clamped);
      });
    }
    return entries;
  }

  Future<bool> _showCancelConfirmation(String gameName) async {
    UiSfxService.instance.play(UiSfx.popup);
    _cancelDialogOpen = true;
    _cancelDialogYesSelected.value = false;
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => _DownloadCancelConfirmDialog(
        gameName: gameName,
        yesSelectedListenable: _cancelDialogYesSelected,
      ),
    );
    _cancelDialogOpen = false;
    return result ?? false;
  }

  void _moveSelection(int delta) {
    final entries = _entries();
    if (entries.isEmpty) return;
    final next = (_selectedIndex + delta).clamp(0, entries.length - 1);
    if (next == _selectedIndex) return;
    setState(() => _selectedIndex = next);
    _scrollToSelected();
  }

  void _togglePauseSelected() {
    final entries = _entries();
    if (entries.isEmpty) return;
    final selected = entries[_selectedIndex.clamp(0, entries.length - 1)];
    final gameId = selected.key;
    final progress = selected.value;
    if (progress.isComplete || progress.error != null) return;

    if (progress.isPaused) {
      if (progress.game != null && progress.downloadUrl != null) {
        ref.read(downloadProvider.notifier).startDownload(
              progress.game!,
              progress.downloadUrl!,
            );
      }
      return;
    }

    ref.read(downloadProvider.notifier).pauseDownload(gameId);
  }

  Future<void> _cancelOrClearSelected() async {
    final entries = _entries();
    if (entries.isEmpty) return;
    final selected = entries[_selectedIndex.clamp(0, entries.length - 1)];
    final gameId = selected.key;
    final progress = selected.value;

    if (progress.isComplete || progress.error != null) {
      ref.read(downloadProvider.notifier).cancelDownload(gameId);
      return;
    }

    final shouldCancel = await _showCancelConfirmation(progress.gameName);
    if (!mounted || !shouldCancel) return;
    ref.read(downloadProvider.notifier).cancelDownload(gameId);
  }

  void _clearAllDownloads() {
    final ids = ref.read(downloadProvider).keys.toList(growable: false);
    for (final id in ids) {
      ref.read(downloadProvider.notifier).cancelDownload(id);
    }
  }

  bool _consumeDownloadsControllerAction(ControllerAction action) {
    if (!mounted) return false;
    if (_cancelDialogOpen) {
      switch (action) {
        case ControllerAction.left:
        case ControllerAction.up:
        case ControllerAction.right:
        case ControllerAction.down:
          _cancelDialogYesSelected.value = !_cancelDialogYesSelected.value;
          return true;
        case ControllerAction.select:
          Navigator.of(context, rootNavigator: true).pop(_cancelDialogYesSelected.value);
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
    // Strip has focus (e.g. after Up from this route): let root controller handler move strip left/right.
    if (LibraryFocusBridge.stripRowHasPrimaryFocus()) {
      return false;
    }
    final entries = _entries();

    switch (action) {
      case ControllerAction.up:
        if (entries.isEmpty) return true;
        _moveSelection(-1);
        return true;
      case ControllerAction.down:
        if (entries.isEmpty) return true;
        _moveSelection(1);
        return true;
      case ControllerAction.select: // A button
        if (entries.isEmpty) return true;
        _togglePauseSelected();
        return true;
      case ControllerAction.alphabetJump: // X button
        if (entries.isEmpty) return true;
        _cancelOrClearSelected();
        return true;
      case ControllerAction.refresh: // Y button
        if (entries.isEmpty) return true;
        _clearAllDownloads();
        return true;
      case ControllerAction.back:
        // Let shell-level handler process B as "back to Home".
        return false;
      case ControllerAction.left:
      case ControllerAction.right:
        // Keep Downloads focus locked to the list body.
        return true;
      case ControllerAction.previousSection:
      case ControllerAction.nextSection:
      case ControllerAction.scrollPageUp:
      case ControllerAction.scrollPageDown:
      case ControllerAction.openSearch:
        return false;
    }
  }

  bool _consumeDownloadsKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    final mapped = ControllerKeyMap.toControllerAction(event.logicalKey);
    if (mapped == null) return false;
    return _consumeDownloadsControllerAction(mapped);
  }

  @override
  Widget build(BuildContext context) {
    final downloads = ref.watch(downloadProvider);
    final entries = downloads.entries.toList(growable: false);
    _syncRowKeys(entries.length);
    if (entries.isEmpty) {
      _selectedIndex = 0;
    } else {
      _selectedIndex = _selectedIndex.clamp(0, entries.length - 1);
    }

    final bodyContent = downloads.isEmpty
        ? const Center(child: Text('No active downloads'))
        : Focus(
            focusNode: _activeFocusNode,
            child: ScrollConfiguration(
              behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
              child: ListView.builder(
                controller: _listScrollController,
                itemCount: entries.length,
                itemBuilder: (context, index) {
                  final gameId = entries[index].key;
                  final progress = entries[index].value;
                  final highlighted = index == _selectedIndex;
                  return AnimatedContainer(
                    key: _rowKeys[index],
                    duration: const Duration(milliseconds: 90),
                    decoration: BoxDecoration(
                      border: highlighted
                          ? Border.all(color: const Color(0xFF6FA8FF), width: 2)
                          : null,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    child: DownloadProgressCard(
                      gameName: progress.gameName,
                      progress: progress,
                      onPause: () => ref.read(downloadProvider.notifier).pauseDownload(gameId),
                      onResume: () {
                        if (progress.game != null && progress.downloadUrl != null) {
                          ref.read(downloadProvider.notifier).startDownload(
                                progress.game!,
                                progress.downloadUrl!,
                              );
                        }
                      },
                      onCancel: () async {
                        if (progress.isComplete || progress.error != null) {
                          ref.read(downloadProvider.notifier).cancelDownload(gameId);
                        } else if (await _showCancelConfirmation(progress.gameName)) {
                          ref.read(downloadProvider.notifier).cancelDownload(gameId);
                        }
                      },
                    ),
                  );
                },
              ),
            ),
          );

    return Scaffold(
      appBar: widget.embeddedShell
          ? null
          : AppBar(
              title: Row(
                children: [
                  Image.asset(
                    'freegosy_logo.png',
                    height: 32,
                    width: 32,
                  ),
                  const SizedBox(width: 12),
                  const Text('Downloads'),
                ],
              ),
            ),
      body: ExcludeSemantics(child: bodyContent),
    );
  }
}

class _DownloadCancelConfirmDialog extends StatefulWidget {
  final String gameName;
  final ValueListenable<bool> yesSelectedListenable;
  const _DownloadCancelConfirmDialog({
    required this.gameName,
    required this.yesSelectedListenable,
  });

  @override
  State<_DownloadCancelConfirmDialog> createState() => _DownloadCancelConfirmDialogState();
}

class _DownloadCancelConfirmDialogState extends State<_DownloadCancelConfirmDialog> {
  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: widget.yesSelectedListenable,
      builder: (context, yesSelected, _) {
        return AlertDialog(
          title: const Text('Cancel Download'),
          content: Text('Are you sure you want to cancel downloading ${widget.gameName}?'),
          actions: [
            TextButton(
              style: TextButton.styleFrom(
                side: BorderSide(
                  color: !yesSelected ? const Color(0xFF6FA8FF) : Colors.transparent,
                  width: 2,
                ),
              ),
              autofocus: true,
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('No'),
            ),
            TextButton(
              style: TextButton.styleFrom(
                side: BorderSide(
                  color: yesSelected ? const Color(0xFF6FA8FF) : Colors.transparent,
                  width: 2,
                ),
              ),
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Yes', style: TextStyle(color: Colors.red)),
            ),
          ],
        );
      },
    );
  }
}
