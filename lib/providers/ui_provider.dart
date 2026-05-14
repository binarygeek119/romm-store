import 'package:flutter_riverpod/flutter_riverpod.dart';

final currentTabIndexProvider = StateProvider<int>((ref) => 0);

/// Primary navigation within the main tab strip (Home, Store, Downloads, …).
final startShellActionProvider = StateProvider<String>((ref) => 'home');

/// Highlight rail on the home storefront (LB/RB): spotlight, what's new, highlights.
final storefrontSectionProvider = StateProvider<String>((ref) => 'spotlight');
