import 'dart:async';

import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:venera_next/foundation/context.dart';

class ReaderBatterySnapshot {
  const ReaderBatterySnapshot(this.level, {required this.charging});
  final int level;
  final bool charging;
}

typedef ReaderBatteryRead = Future<ReaderBatterySnapshot?> Function();

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

/// Owns one clock timer and at most one battery query per dependency generation.
/// A null battery snapshot means unsupported; errors retain the previous value
/// and retry on the next tick. Platform Futures cannot be aborted on disposal.
class ReaderStatusInfo extends StatefulWidget {
  const ReaderStatusInfo({super.key, this.readBattery, this.now});
  final ReaderBatteryRead? readBattery;
  final DateTime Function()? now;
  @override
  State<ReaderStatusInfo> createState() => _ReaderStatusInfoState();
}

class _ReaderStatusInfoState extends State<ReaderStatusInfo> {
  late ReaderBatteryRead _read;
  late Timer _timer;
  late String _time;
  ReaderBatterySnapshot? _battery;
  bool _reading = false;
  bool _supported = true;
  int _generation = 0;

  String _clockText() {
    final now = (widget.now ?? DateTime.now)();
    return '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
  }

  @override
  void initState() {
    super.initState();
    _read = widget.readBattery ?? _platformBatteryReader();
    _time = _clockText();
    _sample();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      final time = _clockText();
      if (_time != time) setState(() => _time = time);
      _sample();
    });
  }

  @override
  void didUpdateWidget(covariant ReaderStatusInfo oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.readBattery != widget.readBattery) {
      _generation++;
      _read = widget.readBattery ?? _platformBatteryReader();
      _reading = false;
      _supported = true;
      _battery = null;
      _sample();
    }
    _time = _clockText();
  }

  Future<void> _sample() async {
    if (_reading || !_supported) return;
    _reading = true;
    final generation = _generation;
    try {
      final next = await _read();
      if (!mounted || generation != _generation) return;
      _supported = next != null;
      if (_battery?.level != next?.level ||
          _battery?.charging != next?.charging) {
        setState(() => _battery = next);
      }
    } catch (_) {
      // Battery information is optional; retry transient platform failures.
    } finally {
      if (mounted && generation == _generation) _reading = false;
    }
  }

  @override
  void dispose() {
    _generation++;
    _timer.cancel();
    super.dispose();
  }

  Widget _text(String text) => Stack(
    children: [
      Text(
        text,
        style: TextStyle(
          fontSize: 14,
          foreground: Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.4
            ..color = context.colorScheme.onInverseSurface,
        ),
      ),
      Text(text),
    ],
  );

  @override
  Widget build(BuildContext context) => Row(
    children: [
      _text(_time),
      const SizedBox(width: 10),
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
        _text('$batteryLevel%'),
      ],
    );
  }
}
