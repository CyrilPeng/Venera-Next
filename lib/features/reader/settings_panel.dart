import 'package:flutter/widgets.dart';
import 'package:venera_next/components/settings_save_state.dart';
import 'package:venera_next/foundation/image_work.dart';
import 'package:venera_next/routing/settings.dart';

import 'brightness.dart';
import 'settings_effects.dart';

/// Presentation adapter; the request owns target checks and effect ordering.
class ReaderSettingsPanel extends StatelessWidget {
  const ReaderSettingsPanel({
    super.key,
    required this.request,
    required this.work,
    required this.brightnessPreview,
    required this.onChanged,
    required this.isCurrent,
  });

  final ReaderSettingsRequest request;
  final ImageWork work;
  final ReaderBrightnessPreview brightnessPreview;
  final void Function(String) onChanged;
  final bool Function() isCurrent;

  @override
  Widget build(BuildContext context) => SettingsSaveScope(
    work: work,
    child: ReaderSettings(
      comicId: request.comicId,
      comicSource: request.sourceKey,
      currentReaderMode: () => request.currentMode,
      isDetectingLayout: () => isCurrent() && request.isDetectingLayout,
      onDetectLayout: () =>
          isCurrent() ? request.detectLayout() : Future.value(),
      onChanged: onChanged,
      brightnessPreview: brightnessPreview,
    ),
  );
}
