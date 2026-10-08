import 'package:flutter/material.dart';
import 'package:venera_next/components/button.dart';
import 'package:venera_next/features/comic_widgets/comic_widgets.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:venera_next/foundation/navigation_admission.dart';
import 'package:venera_next/foundation/res.dart';
import 'package:venera_next/foundation/translations.dart';

class ComicRatingDialog extends StatefulWidget {
  const ComicRatingDialog({super.key, required this.submit});

  final Future<Res<bool>> Function(int rating) submit;

  @override
  State<ComicRatingDialog> createState() => _ComicRatingDialogState();
}

class _ComicRatingDialogState extends State<ComicRatingDialog> {
  double rating = 1;
  bool isLoading = false;

  Future<void> submit() async {
    if (isLoading || !NavigationAdmission.allows(context)) return;
    final route = ModalRoute.of(context);
    final navigator = Navigator.of(context);
    setState(() => isLoading = true);
    Res<bool> result;
    try {
      result = await widget.submit(rating.round());
    } catch (error, stack) {
      result = Res.fromException(error, stack);
    }
    if (!mounted) return;
    setState(() => isLoading = false);
    if (route?.isCurrent != true ||
        !identical(ModalRoute.of(context), route) ||
        !navigator.mounted ||
        !NavigationAdmission.allows(context)) {
      return;
    }
    if (result.error) {
      context.showMessage(message: result.errorMessage!);
    } else {
      context.showMessage(message: "Success".tl);
      navigator.pop();
    }
  }

  @override
  Widget build(BuildContext context) => SimpleDialog(
    title: Text("Rating".tl),
    alignment: Alignment.center,
    children: [
      SizedBox(
        height: 100,
        child: Center(
          child: SizedBox(
            width: 210,
            child: Column(
              children: [
                const SizedBox(height: 10),
                RatingWidget(
                  padding: 2,
                  onRatingUpdate: (value) => rating = value,
                  value: 1,
                  selectable: true,
                  size: 40,
                ),
                const Spacer(),
                Button.filled(
                  isLoading: isLoading,
                  onPressed: submit,
                  child: Text("Submit".tl),
                ),
              ],
            ),
          ),
        ),
      ),
    ],
  );
}
