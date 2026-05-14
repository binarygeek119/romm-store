import 'package:flutter/services.dart';

import 'xinput_controller_service.dart';

class ControllerKeyMap {
  static bool isUp(LogicalKeyboardKey key) =>
      key == LogicalKeyboardKey.arrowUp || _tokenMatch(key, const ['dpad up', 'd-pad up']);

  static bool isDown(LogicalKeyboardKey key) =>
      key == LogicalKeyboardKey.arrowDown || _tokenMatch(key, const ['dpad down', 'd-pad down']);

  static bool isLeft(LogicalKeyboardKey key) =>
      key == LogicalKeyboardKey.arrowLeft || _tokenMatch(key, const ['dpad left', 'd-pad left']);

  static bool isRight(LogicalKeyboardKey key) =>
      key == LogicalKeyboardKey.arrowRight || _tokenMatch(key, const ['dpad right', 'd-pad right']);

  static bool isSelect(LogicalKeyboardKey key) =>
      key == LogicalKeyboardKey.gameButtonA ||
      key == LogicalKeyboardKey.enter ||
      _tokenMatch(key, const ['game button 1', 'button 1', 'south']);

  static bool isBack(LogicalKeyboardKey key) =>
      key == LogicalKeyboardKey.gameButtonB ||
      key == LogicalKeyboardKey.escape ||
      _tokenMatch(key, const ['game button 2', 'button 2', 'east', 'back']);

  static bool isX(LogicalKeyboardKey key) =>
      key == LogicalKeyboardKey.gameButtonX ||
      _tokenMatch(key, const ['game button 3', 'button 3', 'west']);

  static bool isYOrRefresh(LogicalKeyboardKey key) =>
      key == LogicalKeyboardKey.gameButtonY ||
      key == LogicalKeyboardKey.f5 ||
      _tokenMatch(key, const ['game button 4', 'button 4', 'north']);

  static bool isPreviousSection(LogicalKeyboardKey key) =>
      _tokenMatch(key, const [
        'left shoulder',
        'left bumper',
        'game button 5',
        'button 5',
        'l1',
      ]);

  static bool isNextSection(LogicalKeyboardKey key) =>
      _tokenMatch(key, const [
        'right shoulder',
        'right bumper',
        'game button 6',
        'button 6',
        'r1',
      ]);

  static bool isScrollPageUp(LogicalKeyboardKey key) =>
      _tokenMatch(key, const [
        'left trigger',
        'game button 7',
        'button 7',
        'l2',
      ]);

  static bool isScrollPageDown(LogicalKeyboardKey key) =>
      _tokenMatch(key, const [
        'right trigger',
        'game button 8',
        'button 8',
        'r2',
      ]);

  static bool isOpenSearch(LogicalKeyboardKey key) =>
      key == LogicalKeyboardKey.gameButtonStart ||
      _tokenMatch(key, const ['start', 'menu']);

  static ControllerAction? toControllerAction(LogicalKeyboardKey key) {
    if (isUp(key)) return ControllerAction.up;
    if (isDown(key)) return ControllerAction.down;
    if (isLeft(key)) return ControllerAction.left;
    if (isRight(key)) return ControllerAction.right;
    if (isSelect(key)) return ControllerAction.select;
    if (isBack(key)) return ControllerAction.back;
    if (isX(key)) return ControllerAction.alphabetJump;
    if (isYOrRefresh(key)) return ControllerAction.refresh;
    if (isPreviousSection(key)) return ControllerAction.previousSection;
    if (isNextSection(key)) return ControllerAction.nextSection;
    if (isScrollPageUp(key)) return ControllerAction.scrollPageUp;
    if (isScrollPageDown(key)) return ControllerAction.scrollPageDown;
    if (isOpenSearch(key)) return ControllerAction.openSearch;
    return null;
  }

  static bool _tokenMatch(LogicalKeyboardKey key, List<String> terms) {
    final debug = key.debugName?.toLowerCase() ?? '';
    final label = key.keyLabel.toLowerCase();
    for (final term in terms) {
      if (debug.contains(term) || label.contains(term)) {
        return true;
      }
    }
    return false;
  }
}
