import 'package:flutter/material.dart';

class StartTopActionStrip extends StatelessWidget {
  final String selectedAction;
  final ValueChanged<String> onActivate;
  final List<FocusNode> stripFocusNodes;

  const StartTopActionStrip({
    super.key,
    required this.selectedAction,
    required this.onActivate,
    required this.stripFocusNodes,
  }) : assert(stripFocusNodes.length == _actions.length);

  static const List<_TopActionItem> _actions = [
    _TopActionItem('home', 'Home', 'Featured storefront', Icons.home_outlined),
    _TopActionItem('store', 'Store', 'Browse all platforms and games', Icons.storefront_outlined),
    _TopActionItem('downloads', 'Downloads', 'Queue and transfer games', Icons.download_outlined),
    _TopActionItem(
      'friends',
      'Friends',
      'RetroAchievements following & activity',
      Icons.people_outline,
    ),
    _TopActionItem('settings', 'Settings', 'RomM connection and paths', Icons.settings_outlined),
    _TopActionItem('exit', 'Exit', 'Close RomM Store app', Icons.exit_to_app),
  ];

  static const double _minTileWidth = 118;
  /// Same footprint for every strip tile (wide layout + horizontal scroll mode).
  static const double _tileHeight = 78;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        const gap = 8.0;
        final totalGaps = gap * (_actions.length - 1);
        final slotWidth = (constraints.maxWidth - totalGaps) / _actions.length;
        final useScroll = slotWidth < _minTileWidth;

        Widget tile(int i, _TopActionItem action) {
          final isSelected = action.id == selectedAction;
          return Padding(
            padding: const EdgeInsets.only(right: gap),
            child: Actions(
              actions: <Type, Action<Intent>>{
                ActivateIntent: CallbackAction<ActivateIntent>(
                  onInvoke: (_) {
                    onActivate(action.id);
                    return null;
                  },
                ),
              },
              child: Focus(
                focusNode: stripFocusNodes[i],
                child: Builder(
                  builder: (ctx) {
                    final focused = Focus.maybeOf(ctx)?.hasFocus ?? false;
                    // Border must follow **focus** only. [isSelected] reflects the current shell route
                    // (e.g. Home while on `/`); combining it with focus made Home look focused after moving
                    // the controller to Store/Downloads/etc.
                    return SizedBox(
                      width: useScroll ? _minTileWidth : double.infinity,
                      height: _tileHeight,
                      child: InkWell(
                        onTap: () => onActivate(action.id),
                        borderRadius: BorderRadius.circular(10),
                        canRequestFocus: false,
                        child: Container(
                          width: double.infinity,
                          height: double.infinity,
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                          decoration: BoxDecoration(
                            color: const Color(0xFF101E30),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: focused ? const Color(0xFF6FA8FF) : const Color(0xFF1E3550),
                              width: focused ? 1.3 : 1,
                            ),
                          ),
                          alignment: Alignment.centerLeft,
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Icon(action.icon, size: 14, color: isSelected ? Colors.white : Colors.white70),
                                  const SizedBox(width: 6),
                                  Expanded(
                                    child: Text(
                                      action.title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontWeight: FontWeight.w700,
                                        color: isSelected ? Colors.white : Colors.white70,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 4),
                              Text(
                                action.subtitle,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 10, color: Colors.white54, height: 1.2),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          );
        }

        final children = [for (var i = 0; i < _actions.length; i++) tile(i, _actions[i])];
        if (useScroll) {
          return SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: children,
            ),
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < children.length; i++)
              Expanded(child: children[i]),
          ],
        );
      },
    );
  }
}

class _TopActionItem {
  final String id;
  final String title;
  final String subtitle;
  final IconData icon;

  const _TopActionItem(this.id, this.title, this.subtitle, this.icon);
}
