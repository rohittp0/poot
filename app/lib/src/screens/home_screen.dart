import 'dart:async';

import 'package:flutter/material.dart';

import '../config/app_config.dart';
import '../models/unlock_result.dart';
import '../services/app_services.dart';
import '../widgets/status_banner.dart';
import 'settings_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.services});

  final AppServices services;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  bool _busy = false;
  bool _didAutoUnlock = false;

  int _unlockAttemptId = 0;

  String _status = 'Ready';
  bool _statusSuccess = true;
  Timer? _unlockPulseTicker;
  Duration _unlockPulseRemaining = Duration.zero;

  bool get _unlockPulseActive => _unlockPulseRemaining > Duration.zero;

  double get _unlockPulseProgress {
    final int totalMs = AppConfig.unlockPulseDuration.inMilliseconds;
    if (totalMs <= 0) {
      return 1;
    }
    final int remainingMs = _unlockPulseRemaining.inMilliseconds.clamp(
      0,
      totalMs,
    );
    return (1 - (remainingMs / totalMs)).clamp(0.0, 1.0);
  }

  int get _unlockPulseSecondsLeft {
    final int ms = _unlockPulseRemaining.inMilliseconds;
    if (ms <= 0) {
      return 0;
    }
    return (ms / 1000).ceil();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runAutoUnlock();
    });
  }

  @override
  void dispose() {
    _unlockPulseTicker?.cancel();
    super.dispose();
  }

  Future<void> _runAutoUnlock() async {
    if (_didAutoUnlock) {
      return;
    }
    _didAutoUnlock = true;

    final bool ok = await widget.services.biometricService.confirmUnlock();
    if (!ok) {
      if (mounted) {
        setState(() {
          _statusSuccess = false;
          _status = 'Biometric check failed or canceled.';
        });
      }
      return;
    }

    await _unlock();
  }

  void _startUnlockPulseCountdown() {
    final Duration duration = AppConfig.unlockPulseDuration;
    if (duration <= Duration.zero) {
      return;
    }

    _unlockPulseTicker?.cancel();
    final DateTime endsAt = DateTime.now().add(duration);

    setState(() {
      _unlockPulseRemaining = duration;
    });

    _unlockPulseTicker = Timer.periodic(const Duration(milliseconds: 100), (
      Timer timer,
    ) {
      if (!mounted) {
        timer.cancel();
        return;
      }

      final Duration remaining = endsAt.difference(DateTime.now());
      if (remaining <= Duration.zero) {
        timer.cancel();
        setState(() {
          _unlockPulseRemaining = Duration.zero;
        });
        return;
      }

      setState(() {
        _unlockPulseRemaining = remaining;
      });
    });
  }

  Widget _buildUnlockedButtonLabel({required Color progressColor}) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        const Text('Unlocked'),
        const SizedBox(width: 10),
        SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(
            value: _unlockPulseProgress,
            strokeWidth: 2.4,
            valueColor: AlwaysStoppedAnimation<Color>(progressColor),
            backgroundColor: progressColor.withValues(alpha: 0.28),
          ),
        ),
        const SizedBox(width: 8),
        Text('${_unlockPulseSecondsLeft}s'),
      ],
    );
  }

  Future<void> _unlock() async {
    if (_busy || _unlockPulseActive) {
      return;
    }

    final int attemptId = ++_unlockAttemptId;
    setState(() {
      _busy = true;
      _status = 'Unlocking...';
      _statusSuccess = true;
    });

    late final UnlockResult result;
    try {
      result = await widget.services.unlockOrchestrator.unlock(
        isCancelled: () => attemptId != _unlockAttemptId,
      );
    } catch (error) {
      debugPrint('Unlock flow failed unexpectedly: $error');
      result = const UnlockResult(
        success: false,
        path: UnlockPath.none,
        message: 'Unlock failed unexpectedly. Please try again.',
      );
    }

    if (!mounted || attemptId != _unlockAttemptId) {
      return;
    }

    setState(() {
      _busy = false;
      _status = result.message;
      _statusSuccess = result.success;
    });

    if (result.success) {
      _startUnlockPulseCountdown();
      return;
    }

    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(result.message)));
  }

  void _cancelUnlock() {
    if (!_busy) {
      return;
    }

    setState(() {
      _unlockAttemptId++;
      _busy = false;
      _status = 'Unlock canceled.';
      _statusSuccess = false;
    });
  }

  Future<void> _openSettings() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder:
            (_) => SettingsScreen(
              settingsService: widget.services.settingsService,
            ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bool unlockCoolingDown = _unlockPulseActive;
    final bool unlockActionsDisabled = _busy || unlockCoolingDown;
    final Color onPrimaryProgressColor =
        Theme.of(context).colorScheme.onPrimary;

    return Scaffold(
      appBar: AppBar(title: const Text('Poot')),
      body: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(20),
        children: <Widget>[
          StatusBanner(message: _status, success: _statusSuccess),
          const SizedBox(height: 16),
          ElevatedButton.icon(
            onPressed:
                _busy ? _cancelUnlock : (unlockCoolingDown ? null : _unlock),
            icon: Icon(
              _busy
                  ? Icons.close
                  : (unlockCoolingDown
                      ? Icons.check_circle
                      : Icons.lock_open),
            ),
            label:
                _busy
                    ? const Text('Cancel')
                    : (unlockCoolingDown
                        ? _buildUnlockedButtonLabel(
                          progressColor: onPrimaryProgressColor,
                        )
                        : const Text('Unlock')),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: unlockActionsDisabled ? null : _openSettings,
            icon: const Icon(Icons.settings),
            label: const Text('Settings'),
          ),
        ],
      ),
    );
  }
}
