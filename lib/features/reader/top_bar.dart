import 'package:flutter/material.dart';
import 'package:venera_next/components/effects.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:venera_next/foundation/widget_utils.dart';

class ReaderTopBar extends StatelessWidget {
  const ReaderTopBar({
    super.key,
    required this.title,
    this.chapterTitle,
    required this.actions,
    required this.onBack,
  });
  final String title;
  final String? chapterTitle;
  final List<Widget> actions;
  final VoidCallback onBack;
  @override
  Widget build(BuildContext context) {
    return BlurEffect(
      child: Container(
        padding: EdgeInsets.only(top: context.padding.top),
        decoration: BoxDecoration(
          color: context.colorScheme.surface.toOpacity(0.92),
          border: Border(
            bottom: BorderSide(color: Colors.grey.toOpacity(0.5), width: 0.5),
          ),
        ),
        child: Padding(
          padding: EdgeInsets.only(
            left: context.padding.left,
            right: context.padding.right,
          ),
          child: Row(
            children: [
              const SizedBox(width: 8),
              BackButton(onPressed: onBack),
              const SizedBox(width: 8),
              Expanded(
                child: chapterTitle == null
                    ? Text(
                        title,
                        style: ts.s18,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            title,
                            style: ts.s16,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          Text(
                            chapterTitle!,
                            style: ts.s12,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
              ),
              const SizedBox(width: 8),
              ...actions,
              const SizedBox(width: 8),
            ],
          ),
        ),
      ),
    );
  }
}
