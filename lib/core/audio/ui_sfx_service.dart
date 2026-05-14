import 'package:audioplayers/audioplayers.dart';

enum UiSfx {
  enter,
  exit,
  movement,
  popup,
}

class UiSfxService {
  UiSfxService._() {
    // We pass full asset keys like "src/assets/sounds/enter.mp3", so disable
    // AudioCache's default "assets/" prefix.
    _player.audioCache.prefix = '';
  }

  static final UiSfxService instance = UiSfxService._();

  final AudioPlayer _player = AudioPlayer();
  DateTime _lastMovement = DateTime.fromMillisecondsSinceEpoch(0);

  String _assetFor(UiSfx sfx) {
    switch (sfx) {
      case UiSfx.enter:
        return 'src/assets/sounds/enter.mp3';
      case UiSfx.exit:
        return 'src/assets/sounds/exit.mp3';
      case UiSfx.movement:
        return 'src/assets/sounds/movement.mp3';
      case UiSfx.popup:
        return 'src/assets/sounds/popup.mp3';
    }
  }

  Future<void> play(UiSfx sfx) async {
    // Avoid extremely noisy movement spam when holding D-pad.
    if (sfx == UiSfx.movement) {
      final now = DateTime.now();
      if (now.difference(_lastMovement).inMilliseconds < 45) return;
      _lastMovement = now;
    }

    try {
      await _player.stop();
      await _player.play(AssetSource(_assetFor(sfx)));
    } catch (_) {
      // SFX should never break navigation flow.
    }
  }
}
