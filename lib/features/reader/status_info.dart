import 'dart:async';

import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:venera_next/components/window_frame.dart';
import 'package:venera_next/components/window_selection_task.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:venera_next/foundation/selection_operation.dart';

import 'status_polling.dart';
import 'information_text.dart';

export 'status_polling.dart' show ReaderBatteryRead, ReaderBatterySnapshot;

ReaderBatteryRead _platformBatteryReader() {
  final battery = Battery();
  return () async {
    try {
      final level = await battery.batteryLevel;
      final state = await battery.batteryState;
      if (state == BatteryState.unknown) return null;
      return ReaderBatterySnapshot(
        level,
        charging: state == BatteryState.charging,
      );
    } on MissingPluginException {
      return null;
    }
  };
}

/// Displays optional telemetry retained by its original application and window.
class ReaderStatusInfo extends StatefulWidget {
  const ReaderStatusInfo({super.key, this.readBattery, this.now});
  final ReaderBatteryRead? readBattery;
  final DateTime Function()? now;
  @override
  State<ReaderStatusInfo> createState() => _ReaderStatusInfoState();
}

class _ReaderStatusInfoState extends State<ReaderStatusInfo> {
  _StatusOwner? _owner;
  ReaderBatterySnapshot? get _battery => _owner?.polling.battery;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    context.dependOnInheritedWidgetOfExactType<SelectionTasksScope>();
    context.dependOnInheritedWidgetOfExactType<WindowFrameController>();
    if (_owner?.belongsTo(context) != true) _replaceOwner();
  }

  void _replaceOwner() {
    _owner?.dispose();
    final owner = _owner = _StatusOwner(
      context,
      ReaderStatusPolling(
        readBattery: widget.readBattery ?? _platformBatteryReader(),
        now: widget.now ?? DateTime.now,
        onChanged: () {
          if (mounted) setState(() {});
        },
      ),
    );
    owner.start();
  }

  @override
  void didUpdateWidget(covariant ReaderStatusInfo oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.readBattery != widget.readBattery) {
      _replaceOwner();
    } else {
      _owner?.polling.setClock(widget.now ?? DateTime.now);
    }
  }

  @override
  void dispose() {
    _owner?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 10,
    runSpacing: 2,
    alignment: WrapAlignment.end,
    crossAxisAlignment: WrapCrossAlignment.center,
    children: [
      ReaderInformationText(text: _owner!.polling.time),
      if (_battery != null) _batteryInfo(_battery!.level),
    ],
  );

  Widget _batteryInfo(int batteryLevel) {
    IconData batteryIcon;
    Color batteryColor = context.colorScheme.onSurface;

    if (_battery!.charging) {
      batteryIcon = Icons.battery_charging_full;
    } else if (batteryLevel >= 96) {
      batteryIcon = Icons.battery_full_sharp;
    } else if (batteryLevel >= 84) {
      batteryIcon = Icons.battery_6_bar_sharp;
    } else if (batteryLevel >= 72) {
      batteryIcon = Icons.battery_5_bar_sharp;
    } else if (batteryLevel >= 60) {
      batteryIcon = Icons.battery_4_bar_sharp;
    } else if (batteryLevel >= 48) {
      batteryIcon = Icons.battery_3_bar_sharp;
    } else if (batteryLevel >= 36) {
      batteryIcon = Icons.battery_2_bar_sharp;
    } else if (batteryLevel >= 24) {
      batteryIcon = Icons.battery_1_bar_sharp;
    } else if (batteryLevel >= 12) {
      batteryIcon = Icons.battery_0_bar_sharp;
    } else {
      batteryIcon = Icons.battery_alert_sharp;
      batteryColor = Colors.red;
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          batteryIcon,
          size: 16,
          color: batteryColor,
          // Stroke
          shadows: List.generate(9, (index) {
            if (index == 4) {
              return null;
            }
            double offsetX = (index % 3 - 1) * 0.8;
            double offsetY = ((index / 3).floor() - 1) * 0.8;
            return Shadow(
              color: context.colorScheme.onInverseSurface,
              offset: Offset(offsetX, offsetY),
            );
          }).whereType<Shadow>().toList(),
        ),
        Flexible(child: ReaderInformationText(text: '$batteryLevel%')),
      ],
    );
  }
}

/// Register before sampling. Retirement stops scheduling immediately, while
/// outstanding reads stay attached to their original host until they settle.
class _StatusOwner with WidgetsBindingObserver {
  _StatusOwner(BuildContext context, this.polling)
    : _registry = context
          .getInheritedWidgetOfExactType<SelectionTasksScope>()
          ?.registry,
      _frame = context.getInheritedWidgetOfExactType<WindowFrameController>();

  final ReaderStatusPolling polling;
  final SelectionTaskRegistry? _registry;
  final WindowFrameController? _frame;
  void Function()? _releaseHost;
  Future<void>? _closing;
  bool _windowPaused = false;

  bool belongsTo(BuildContext context) =>
      identical(
        _registry,
        context.getInheritedWidgetOfExactType<SelectionTasksScope>()?.registry,
      ) &&
      _frame?.addExitTask ==
          context
              .getInheritedWidgetOfExactType<WindowFrameController>()
              ?.addExitTask;

  void start() {
    if (_registry?.isClosing == true) {
      dispose();
      return;
    }
    _windowPaused = _frame?.isClosing == true;
    WidgetsBinding.instance.addObserver(this);
    _frame?.addCloseStartListener(_pauseWindow);
    _frame?.addCloseFailureListener(_resumeWindow);
    _frame?.addExitTask(_prepareWindow);
    _releaseHost = _registry?.retain(cancel: dispose, close: closeAndWait);
    _updateActivity();
  }

  void _updateActivity() {
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    polling.setActive(
      !_windowPaused &&
          _registry?.isClosing != true &&
          _frame?.isClosing != true &&
          (lifecycle == null || lifecycle == AppLifecycleState.resumed),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) => _updateActivity();

  void _pauseWindow() {
    _windowPaused = true;
    polling.setActive(false);
  }

  void _resumeWindow() {
    _windowPaused = false;
    // WindowFrame clears its closing flag after recovery listeners return.
    scheduleMicrotask(_updateActivity);
  }

  Future<void> _prepareWindow() {
    _pauseWindow();
    return polling.drain();
  }

  void dispose() => unawaited(closeAndWait());

  Future<void> closeAndWait() {
    if (_closing case final closing?) return closing;
    WidgetsBinding.instance.removeObserver(this);
    final closing = _closing = polling.closeAndWait();
    unawaited(
      closing.then((_) {
        _releaseHost?.call();
        _releaseHost = null;
        _frame?.removeCloseStartListener(_pauseWindow);
        _frame?.removeCloseFailureListener(_resumeWindow);
        _frame?.removeExitTask(_prepareWindow);
      }),
    );
    return closing;
  }
}
