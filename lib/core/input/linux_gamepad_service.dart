import 'dart:async';
import 'dart:io';

import 'package:gamepads/gamepads.dart';

import 'xinput_controller_service.dart';

class LinuxGamepadService {
  StreamSubscription<GamepadEvent>? _sub;
  Timer? _dpadHoldTimer;

  DateTime _lastDirectionalRepeat = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastTriggerRepeat = DateTime.fromMillisecondsSinceEpoch(0);
  static const Duration _repeatInterval = Duration(milliseconds: 140);
  static const Duration _triggerRepeatInterval = Duration(milliseconds: 115);

  static const double _stickDeadzone = 0.45;
  static const double _triggerPressThreshold = 0.55;

  final Map<String, double> _axis = <String, double>{
    'leftX': 0,
    'leftY': 0,
    'lt': 0,
    'rt': 0,
  };
  final Map<String, bool> _buttonDown = <String, bool>{};

  void start(void Function(ControllerAction action) onAction) {
    if (!Platform.isLinux) return;
    stop();
    _sub = Gamepads.events.listen((event) {
      _handleEvent(event, onAction);
    });
  }

  void stop() {
    _sub?.cancel();
    _sub = null;
    _dpadHoldTimer?.cancel();
    _dpadHoldTimer = null;
    _axis.updateAll((key, value) => 0);
    _buttonDown.clear();
  }

  void _handleEvent(GamepadEvent event, void Function(ControllerAction action) onAction) {
    if (event.type == KeyType.button) {
      final id = event.key;
      final pressed = event.value > 0.5;
      final wasPressed = _buttonDown[id] ?? false;
      _buttonDown[id] = pressed;
      if (pressed && !wasPressed) {
        _emitButton(id, onAction);
      }
      _updateHeldDirectionalRepeater(onAction);
      return;
    }

    if (event.type == KeyType.analog) {
      _trackAxis(event.key, event.value, onAction);
      _emitAxisDirections(onAction);
      _emitAxisTriggers(onAction);
    }
  }

  void _updateHeldDirectionalRepeater(void Function(ControllerAction action) onAction) {
    final hasHeldDirection = _buttonDown['14'] == true ||
        _buttonDown['15'] == true ||
        _buttonDown['16'] == true ||
        _buttonDown['17'] == true ||
        _buttonDown['11'] == true ||
        _buttonDown['12'] == true ||
        _buttonDown['13'] == true ||
        _buttonDown['10'] == true;
    if (!hasHeldDirection) {
      _dpadHoldTimer?.cancel();
      _dpadHoldTimer = null;
      return;
    }
    if (_dpadHoldTimer != null) return;
    _dpadHoldTimer = Timer.periodic(_repeatInterval, (_) {
      if (!(_buttonDown['14'] == true ||
          _buttonDown['15'] == true ||
          _buttonDown['16'] == true ||
          _buttonDown['17'] == true ||
          _buttonDown['11'] == true ||
          _buttonDown['12'] == true ||
          _buttonDown['13'] == true ||
          _buttonDown['10'] == true)) {
        _dpadHoldTimer?.cancel();
        _dpadHoldTimer = null;
        return;
      }
      // Priority matches existing directional behavior.
      if (_buttonDown['14'] == true || _buttonDown['11'] == true) {
        onAction(ControllerAction.up);
      } else if (_buttonDown['15'] == true || _buttonDown['12'] == true) {
        onAction(ControllerAction.down);
      } else if (_buttonDown['16'] == true || _buttonDown['13'] == true) {
        onAction(ControllerAction.left);
      } else if (_buttonDown['17'] == true || _buttonDown['10'] == true) {
        onAction(ControllerAction.right);
      }
    });
  }

  void _trackAxis(
    String axisKey,
    double value,
    void Function(ControllerAction action) onAction,
  ) {
    // Linux event keys vary by driver:
    // - xboxdrv/evdev often: 0:leftX, 1:leftY, 3/4: triggers, 6/7:dpad
    // - SDL mappings often: 2/5 for triggers (or right-stick axes on some pads)
    // We support both trigger layouts to keep LT/RT fast-scroll reliable.
    switch (axisKey) {
      case '0':
        _axis['leftX'] = value;
        break;
      case '1':
        _axis['leftY'] = value;
        break;
      case '2':
      case '3':
        _axis['lt'] = _normalizeTrigger(value);
        break;
      case '5':
      case '4':
        _axis['rt'] = _normalizeTrigger(value);
        break;
      case '6':
        if (value <= -_stickDeadzone) _emitAxisDigital(ControllerAction.left, onAction);
        if (value >= _stickDeadzone) _emitAxisDigital(ControllerAction.right, onAction);
        break;
      case '7':
        if (value <= -_stickDeadzone) _emitAxisDigital(ControllerAction.up, onAction);
        if (value >= _stickDeadzone) _emitAxisDigital(ControllerAction.down, onAction);
        break;
      default:
        break;
    }
  }

  void _emitButton(String key, void Function(ControllerAction action) onAction) {
    // Common Linux xbox360 button mapping.
    switch (key) {
      case '0': // A
        onAction(ControllerAction.select);
        return;
      case '1': // B
        onAction(ControllerAction.back);
        return;
      case '2': // X
        onAction(ControllerAction.alphabetJump);
        return;
      case '3': // Y
        onAction(ControllerAction.refresh);
        return;
      case '4': // LB
        onAction(ControllerAction.previousSection);
        return;
      case '5': // RB
        onAction(ControllerAction.nextSection);
        return;
      case '7': // Start/Menu
        onAction(ControllerAction.openSearch);
        return;
      case '14': // D-pad up (common evdev mapping)
      case '11': // D-pad up (alternate mapping)
        onAction(ControllerAction.up);
        return;
      case '15': // D-pad down (common evdev mapping)
      case '12': // D-pad down (alternate mapping)
        onAction(ControllerAction.down);
        return;
      case '16': // D-pad left (common evdev mapping)
      case '13': // D-pad left (alternate mapping)
        onAction(ControllerAction.left);
        return;
      case '17': // D-pad right (common evdev mapping)
      case '10': // D-pad right (alternate mapping)
        onAction(ControllerAction.right);
        return;
      case '6': // back
      case '8': // guide
      case '9': // unknown
      default:
        return;
    }
  }

  void _emitAxisDigital(
    ControllerAction action,
    void Function(ControllerAction action) onAction,
  ) {
    final now = DateTime.now();
    if (now.difference(_lastDirectionalRepeat) < _repeatInterval) return;
    _lastDirectionalRepeat = now;
    onAction(action);
  }

  void _emitAxisDirections(void Function(ControllerAction action) onAction) {
    final x = _axis['leftX'] ?? 0;
    final y = _axis['leftY'] ?? 0;
    if (x.abs() < _stickDeadzone && y.abs() < _stickDeadzone) return;

    final now = DateTime.now();
    if (now.difference(_lastDirectionalRepeat) < _repeatInterval) return;
    _lastDirectionalRepeat = now;

    if (y <= -_stickDeadzone) {
      onAction(ControllerAction.up);
      return;
    }
    if (y >= _stickDeadzone) {
      onAction(ControllerAction.down);
      return;
    }
    if (x <= -_stickDeadzone) {
      onAction(ControllerAction.left);
      return;
    }
    if (x >= _stickDeadzone) {
      onAction(ControllerAction.right);
    }
  }

  void _emitAxisTriggers(void Function(ControllerAction action) onAction) {
    final lt = _axis['lt'] ?? 0;
    final rt = _axis['rt'] ?? 0;
    if (lt < _triggerPressThreshold && rt < _triggerPressThreshold) return;
    final now = DateTime.now();
    if (now.difference(_lastTriggerRepeat) < _triggerRepeatInterval) return;
    _lastTriggerRepeat = now;

    if (lt >= rt) {
      onAction(ControllerAction.scrollPageUp);
    } else {
      onAction(ControllerAction.scrollPageDown);
    }
  }

  double _normalizeTrigger(double raw) {
    // Some Linux drivers expose triggers as [-1,1], others [0,1].
    if (raw < 0) return ((raw + 1) / 2).clamp(0.0, 1.0);
    return raw.clamp(0.0, 1.0);
  }
}
