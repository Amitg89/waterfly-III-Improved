import 'package:flutter/material.dart';

/// Shows a draggable "vault" modal bottom sheet: rounded top corners, grab
/// handle, snaps between 60 % and 95 % of the screen, swipe-down dismisses.
///
/// [builder] receives the sheet's [ScrollController]; the content MUST attach
/// it to its scrollable (e.g. `ListView(controller: scrollController)`) so
/// dragging the list resizes/dismisses the sheet.
Future<T?> showVaultSheet<T>({
  required BuildContext context,
  required Widget Function(
    BuildContext context,
    ScrollController scrollController,
  )
  builder,
}) {
  final ColorScheme cs = Theme.of(context).colorScheme;
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: cs.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
    ),
    clipBehavior: Clip.antiAlias,
    builder:
        (BuildContext sheetContext) => DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.6,
          minChildSize: 0.45,
          maxChildSize: 0.95,
          snap: true,
          snapSizes: const <double>[0.6, 0.95],
          builder: (
            BuildContext builderContext,
            ScrollController scrollController,
          ) {
            return Column(
              children: <Widget>[
                // Grab handle.
                Container(
                  margin: const EdgeInsetsDirectional.only(top: 10, bottom: 8),
                  width: 42,
                  height: 5,
                  decoration: BoxDecoration(
                    color: Theme.of(builderContext).colorScheme.outline,
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
                Expanded(child: builder(builderContext, scrollController)),
              ],
            );
          },
        ),
  );
}
