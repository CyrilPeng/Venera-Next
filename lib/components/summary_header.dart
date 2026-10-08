import 'package:flutter/material.dart';
import 'package:venera_next/foundation/widget_utils.dart';

/// A compact overview title/count that keeps the trailing navigation cue visible.
class SummaryHeader extends StatelessWidget {
  const SummaryHeader({super.key, required this.title, required this.count});

  final String title;
  final int count;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16),
    child: SizedBox(
      height: 56,
      child: Row(
        children: [
          Expanded(
            child: Row(
              children: [
                Flexible(
                  child: Text(
                    title,
                    style: ts.s18,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Container(
                  margin: const EdgeInsets.symmetric(horizontal: 8),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.secondaryContainer,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(count.toString(), style: ts.s12),
                ),
              ],
            ),
          ),
          const Icon(Icons.arrow_right),
        ],
      ),
    ),
  );
}
