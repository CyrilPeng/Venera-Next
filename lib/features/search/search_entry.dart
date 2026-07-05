import 'package:flutter/material.dart';
import 'package:venera_next/components/gesture.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/translations.dart';

import 'search_page.dart';

class SearchEntry extends StatelessWidget {
  const SearchEntry({super.key});

  @override
  Widget build(BuildContext context) {
    return SliverToBoxAdapter(
      child: Container(
        height: App.isMobile ? 52 : 46,
        width: double.infinity,
        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        child: Material(
          color: context.colorScheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(32),
          child: ClickInkWell(
            borderRadius: BorderRadius.circular(32),
            onTap: () {
              context.to(() => const SearchPage());
            },
            child: Row(
              children: [
                const SizedBox(width: 16),
                const Icon(Icons.search),
                const SizedBox(width: 8),
                Text('Search'.tl, style: ts.s16),
                const Spacer(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
