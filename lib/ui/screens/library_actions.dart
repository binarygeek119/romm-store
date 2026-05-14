import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/error/error_handler.dart';
import '../../providers/download_provider.dart';
import '../../providers/romm_provider.dart';
import '../../providers/downloaded_games_cache_provider.dart';
import '../../core/storage/directory_service.dart';
import '../../core/romm/romm_models.dart';

mixin LibraryActionsMixin<T extends ConsumerStatefulWidget> on ConsumerState<T> {
  // These need to be implemented by the state class
  Map<String, bool> get downloadedStates;
  void refreshDownloadState(DirectoryService dirService, Game game);
  void refreshAllDownloadStates();

  void startDownload(BuildContext context, WidgetRef ref, Game game) {
    final service = ref.read(rommServiceProvider);
    if (service == null) {
      ErrorHandler.showInfo(context, 'Not Connected', message: 'Not connected to RomM');
      return;
    }
    final url = service.getDownloadUrl(game);
    final headers = <String, String>{'Authorization': service.authHeader};
    ref.read(downloadProvider.notifier).startDownload(game, url, headers: headers);
    if (context.mounted) {
      ErrorHandler.showInfo(context, 'Download Started', message: '${game.name} is downloading...');
    }
    final dirService = ref.read(directoryServiceProvider).asData?.value;
    if (dirService != null) {
      Future.delayed(const Duration(seconds: 2), () {
        // Refresh the new background cache
        ref.read(downloadedGamesCacheProvider.notifier).refresh();
      });
    }
  }

  Future<void> handleLaunch(BuildContext context, WidgetRef ref, Game game) async {
    ErrorHandler.showInfo(
      context,
      'Downloader Only',
      message: 'Launcher/emulator functionality has been removed.',
    );
  }

  /// When [skipConfirmation] is true, the caller has already asked the user (e.g. game detail sheet).
  Future<void> handleDeleteRom(
    BuildContext context,
    WidgetRef ref,
    Game game, {
    bool skipConfirmation = false,
  }) async {
    final dirService = ref.read(directoryServiceProvider).asData?.value;
    if (dirService == null) return;

    if (!skipConfirmation) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Delete ROM?'),
          content: Text(
            'Are you sure you want to delete the local files for ${game.name}? This cannot be undone.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red,
                foregroundColor: Colors.white,
              ),
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Delete'),
            ),
          ],
        ),
      );

      if (confirmed != true) return;
    }

    try {
      await dirService.deleteRom(game);
      if (!context.mounted) return;

      // Refresh the new background cache
      ref.read(downloadedGamesCacheProvider.notifier).refresh();

      if (!context.mounted) return;
      ErrorHandler.showSuccess(context, 'ROM Deleted', message: 'Local files for ${game.name} were removed.');
    } catch (e) {
      if (!context.mounted) return;
      ErrorHandler.showException(context, e, contextLabel: 'Delete Failed');
    }
  }

  Future<void> handlePushSaves(
      BuildContext context, WidgetRef ref, Game game) async {
    ErrorHandler.showInfo(
      context,
      'Downloader Only',
      message: 'Save sync has been removed.',
    );
  }

  Future<void> handlePullSaves(
      BuildContext context, WidgetRef ref, Game game) async {
    ErrorHandler.showInfo(
      context,
      'Downloader Only',
      message: 'Save sync has been removed.',
    );
  }
}
