import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

enum ControllerAction {
  up,
  down,
  left,
  right,
  select,
  back,
  refresh,
  previousSection,
  nextSection,
  /// Opens the Store game-list A–Z jump rail (X button).
  alphabetJump,
  /// Left trigger (LT): scroll toward top of page (game detail).
  scrollPageUp,
  /// Right trigger (RT): scroll toward bottom of page (game detail).
  scrollPageDown,
  /// Start button: focus Store search box.
  openSearch,
}

class XInputControllerService {
  Timer? _pollTimer;
  int _activeUserIndex = 0;
  int _previousButtons = 0;
  DateTime _lastDirectionalRepeat = DateTime.fromMillisecondsSinceEpoch(0);
  int _previousLeftTrigger = 0;
  int _previousRightTrigger = 0;
  DateTime _lastTriggerScrollRepeat = DateTime.fromMillisecondsSinceEpoch(0);

  static const Duration _pollInterval = Duration(milliseconds: 16);
  static const Duration _repeatInterval = Duration(milliseconds: 140);
  static const Duration _triggerRepeatInterval = Duration(milliseconds: 115);
  /// Same idea as Win32 `XINPUT_GAMEPAD_TRIGGER_THRESHOLD` (30).
  static const int _triggerPressThreshold = 30;

  void start(void Function(ControllerAction action) onAction) {
    if (!Platform.isWindows) return;
    stop();
    _pollTimer = Timer.periodic(_pollInterval, (_) {
      _poll(onAction);
    });
  }

  void stop() {
    _pollTimer?.cancel();
    _pollTimer = null;
    _activeUserIndex = 0;
    _previousButtons = 0;
    _previousLeftTrigger = 0;
    _previousRightTrigger = 0;
  }

  void _poll(void Function(ControllerAction action) onAction) {
    final state = calloc.allocate<XINPUT_STATE>(sizeOf<XINPUT_STATE>());
    try {
      final result = _readFirstConnectedController(state);
      if (result != ERROR_SUCCESS) {
        _previousButtons = 0;
        _previousLeftTrigger = 0;
        _previousRightTrigger = 0;
        return;
      }

      final buttons = state.ref.Gamepad.wButtons;
      final thumbLX = state.ref.Gamepad.sThumbLX;
      final thumbLY = state.ref.Gamepad.sThumbLY;
      final leftTrigger = state.ref.Gamepad.bLeftTrigger;
      final rightTrigger = state.ref.Gamepad.bRightTrigger;

      _emitOnPress(buttons, XINPUT_GAMEPAD_A, ControllerAction.select, onAction);
      _emitOnPress(buttons, XINPUT_GAMEPAD_B, ControllerAction.back, onAction);
      _emitOnPress(buttons, XINPUT_GAMEPAD_X, ControllerAction.alphabetJump, onAction);
      _emitOnPress(buttons, XINPUT_GAMEPAD_Y, ControllerAction.refresh, onAction);
      _emitOnPress(buttons, XINPUT_GAMEPAD_START, ControllerAction.openSearch, onAction);
      _emitOnPress(buttons, XINPUT_GAMEPAD_LEFT_SHOULDER, ControllerAction.previousSection, onAction);
      _emitOnPress(buttons, XINPUT_GAMEPAD_RIGHT_SHOULDER, ControllerAction.nextSection, onAction);

      _emitDirectional(buttons, thumbLX, thumbLY, onAction);
      _emitTriggerScroll(leftTrigger, rightTrigger, onAction);

      _previousButtons = buttons;
    } finally {
      calloc.free(state);
    }
  }

  int _readFirstConnectedController(Pointer<XINPUT_STATE> state) {
    var result = XInputGetState(_activeUserIndex, state);
    if (result == ERROR_SUCCESS) return result;

    for (var i = 0; i < XUSER_MAX_COUNT; i++) {
      result = XInputGetState(i, state);
      if (result == ERROR_SUCCESS) {
        _activeUserIndex = i;
        _previousButtons = 0;
        return result;
      }
    }

    return result;
  }

  void _emitTriggerScroll(
    int lt,
    int rt,
    void Function(ControllerAction action) onAction,
  ) {
    final ltOn = lt > _triggerPressThreshold;
    final rtOn = rt > _triggerPressThreshold;
    if (!ltOn && !rtOn) {
      _previousLeftTrigger = lt;
      _previousRightTrigger = rt;
      return;
    }

    final now = DateTime.now();
    final ltEdge = ltOn && _previousLeftTrigger <= _triggerPressThreshold;
    final rtEdge = rtOn && _previousRightTrigger <= _triggerPressThreshold;
    final canRepeat =
        now.difference(_lastTriggerScrollRepeat) >= _triggerRepeatInterval;

    if (!(ltEdge || rtEdge || canRepeat)) {
      _previousLeftTrigger = lt;
      _previousRightTrigger = rt;
      return;
    }

    if (ltOn && rtOn) {
      if (lt > rt) {
        onAction(ControllerAction.scrollPageUp);
      } else if (rt > lt) {
        onAction(ControllerAction.scrollPageDown);
      } else {
        onAction(ControllerAction.scrollPageDown);
      }
    } else if (ltOn) {
      onAction(ControllerAction.scrollPageUp);
    } else {
      onAction(ControllerAction.scrollPageDown);
    }
    _lastTriggerScrollRepeat = now;
    _previousLeftTrigger = lt;
    _previousRightTrigger = rt;
  }

  void _emitDirectional(
    int buttons,
    int thumbLX,
    int thumbLY,
    void Function(ControllerAction action) onAction,
  ) {
    const stickDeadzone = 12000;
    final stickUp = thumbLY > stickDeadzone;
    final stickDown = thumbLY < -stickDeadzone;
    final stickLeft = thumbLX < -stickDeadzone;
    final stickRight = thumbLX > stickDeadzone;

    final isUp = (buttons & XINPUT_GAMEPAD_DPAD_UP) != 0 || stickUp;
    final isDown = (buttons & XINPUT_GAMEPAD_DPAD_DOWN) != 0 || stickDown;
    final isLeft = (buttons & XINPUT_GAMEPAD_DPAD_LEFT) != 0 || stickLeft;
    final isRight = (buttons & XINPUT_GAMEPAD_DPAD_RIGHT) != 0 || stickRight;

    final wasUp = (_previousButtons & XINPUT_GAMEPAD_DPAD_UP) != 0;
    final wasDown = (_previousButtons & XINPUT_GAMEPAD_DPAD_DOWN) != 0;
    final wasLeft = (_previousButtons & XINPUT_GAMEPAD_DPAD_LEFT) != 0;
    final wasRight = (_previousButtons & XINPUT_GAMEPAD_DPAD_RIGHT) != 0;

    final newDirectionalPress = (isUp && !wasUp) ||
        (isDown && !wasDown) ||
        (isLeft && !wasLeft) ||
        (isRight && !wasRight);

    final now = DateTime.now();
    final canRepeat = now.difference(_lastDirectionalRepeat) >= _repeatInterval;

    if (!(newDirectionalPress || canRepeat)) return;

    if (isUp) {
      onAction(ControllerAction.up);
      _lastDirectionalRepeat = now;
      return;
    }
    if (isDown) {
      onAction(ControllerAction.down);
      _lastDirectionalRepeat = now;
      return;
    }
    if (isLeft) {
      onAction(ControllerAction.left);
      _lastDirectionalRepeat = now;
      return;
    }
    if (isRight) {
      onAction(ControllerAction.right);
      _lastDirectionalRepeat = now;
    }
  }

  void _emitOnPress(
    int buttons,
    int mask,
    ControllerAction action,
    void Function(ControllerAction action) onAction,
  ) {
    final isPressed = (buttons & mask) != 0;
    final wasPressed = (_previousButtons & mask) != 0;
    if (isPressed && !wasPressed) {
      onAction(action);
    }
  }
}
