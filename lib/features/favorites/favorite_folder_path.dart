import 'package:flutter/material.dart';
import 'package:venera_next/foundation/translations.dart';

/// Uses real folder labels, never splitting names on the visual separator.
class FavoriteFolderPath extends StatelessWidget {
  const FavoriteFolderPath({
    super.key,
    required this.currentName,
    this.parentName,
    this.onParentSelected,
    this.onCurrentSelected,
  });

  final String currentName;
  final String? parentName;
  final VoidCallback? onParentSelected;
  final VoidCallback? onCurrentSelected;

  @override
  Widget build(BuildContext context) {
    final style = TextButton.styleFrom(
      textStyle: DefaultTextStyle.of(context).style,
      minimumSize: const Size(48, 48),
      padding: const EdgeInsets.symmetric(horizontal: 4),
      alignment: AlignmentDirectional.centerStart,
    );

    Widget current({bool interactive = true}) => Semantics(
      selected: true,
      child: Tooltip(
        message: currentName,
        child: interactive && onCurrentSelected != null
            ? TextButton(
                key: const ValueKey('favorite-path-current'),
                style: style.copyWith(
                  foregroundColor: WidgetStatePropertyAll(
                    Theme.of(context).colorScheme.onSurface,
                  ),
                ),
                onPressed: onCurrentSelected,
                child: _PathLabel(currentName),
              )
            : _PathLabel(currentName),
      ),
    );

    if (parentName == null) return current();
    final parentLabel = '${'Parent folder'.tl}: $parentName';
    return LayoutBuilder(
      builder: (context, constraints) {
        // A narrow title keeps a full-size parent button and prioritizes the
        // current name. Full labels remain available through tooltips/semantics.
        final compact = constraints.maxWidth < 160;
        if (compact && constraints.maxWidth < 48) {
          return current(interactive: false);
        }
        return Row(
          children: [
            if (compact) ...[
              IconButton(
                key: const ValueKey('favorite-path-parent'),
                tooltip: parentLabel,
                constraints: const BoxConstraints.tightFor(
                  width: 48,
                  height: 48,
                ),
                onPressed: onParentSelected,
                icon: Icon(Icons.arrow_upward, semanticLabel: parentLabel),
              ),
              SizedBox(width: constraints.maxWidth >= 104 ? 8 : 0),
            ] else ...[
              Flexible(
                child: Tooltip(
                  message: parentLabel,
                  child: TextButton(
                    key: const ValueKey('favorite-path-parent'),
                    style: style,
                    onPressed: onParentSelected,
                    child: _PathLabel(parentName!),
                  ),
                ),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 4),
                child: ExcludeSemantics(child: _PathLabel('/')),
              ),
            ],
            Expanded(
              flex: compact ? 1 : 2,
              child: current(interactive: constraints.maxWidth >= 104),
            ),
          ],
        );
      },
    );
  }
}

class _PathLabel extends StatelessWidget {
  const _PathLabel(this.name);

  final String name;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final defaults = DefaultTextStyle.of(context);
      final scaler = MediaQuery.textScalerOf(context);
      var fittedScaler = scaler;
      if (constraints.maxHeight.isFinite) {
        final measurement = TextPainter(
          text: TextSpan(text: name, style: defaults.style),
          textDirection: Directionality.of(context),
          textHeightBehavior: defaults.textHeightBehavior,
          textScaler: scaler,
          maxLines: 1,
        )..layout(maxWidth: constraints.maxWidth);
        final height = measurement.height;
        measurement.dispose();
        if (height > constraints.maxHeight && height > 0) {
          final fontSize = defaults.style.fontSize ?? 14;
          // Preserve dynamic scaling up to the fixed toolbar's available
          // height rather than clipping glyphs. Full names keep their semantics.
          fittedScaler = scaler.clamp(
            maxScaleFactor:
                scaler.scale(fontSize) /
                fontSize *
                constraints.maxHeight /
                height,
          );
        }
      }
      return Text(
        name,
        textScaler: fittedScaler,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      );
    },
  );
}
