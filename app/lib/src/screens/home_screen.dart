import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../config/app_config.dart';
import '../models/lock_state.dart';
import '../models/unlock_result.dart';
import '../services/app_services.dart';
import '../widgets/status_banner.dart';
import 'admin_users_screen.dart';
import 'settings_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.services, required this.user});

  final AppServices services;
  final User user;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  bool _busy = false;
  bool _didAutoUnlock = false;
  bool _isAdmin = false;

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
    final double progress = 1 - (remainingMs / totalMs);
    return progress.clamp(0.0, 1.0);
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
    _seedIdentityFromCurrentUser();
    _loadAccess();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runAutoUnlock();
    });
  }

  @override
  void dispose() {
    _unlockPulseTicker?.cancel();
    super.dispose();
  }

  void _seedIdentityFromCurrentUser() {
    final String? email = widget.user.email;
    if (email == null || email.trim().isEmpty) {
      debugPrint(
        'Skipping identity upsert: no email for uid ${widget.user.uid}',
      );
      return;
    }

    unawaited(
      widget.services.adminUsersService
          .upsertIdentity(uid: widget.user.uid, email: email)
          .catchError((Object error) {
            debugPrint('Identity upsert failed: $error');
          }),
    );
  }

  Future<void> _loadAccess() async {
    final user = await widget.services.adminUsersService.getUser(
      widget.user.uid,
    );
    if (!mounted) {
      return;
    }

    setState(() {
      _isAdmin = user?.enabled == true && user?.role == 'admin';
    });
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

    final UnlockResult result = await widget.services.unlockOrchestrator.unlock(
      requestedByUid: widget.user.uid,
      isCancelled: () => attemptId != _unlockAttemptId,
    );

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

    if (!result.success) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(result.message)));
    }
  }

  Future<void> _unlockLocal() async {
    if (_busy || _unlockPulseActive) {
      return;
    }

    final int attemptId = ++_unlockAttemptId;
    setState(() {
      _busy = true;
      _status = 'Unlocking locally...';
      _statusSuccess = true;
    });

    final local =
        await widget.services.localUnlockService.unlockViaAccessPoint();

    if (!mounted || attemptId != _unlockAttemptId) {
      return;
    }

    final UnlockResult result =
        local.success
            ? const UnlockResult(
              success: true,
              path: UnlockPath.local,
              message: 'Unlocked through local hotspot fallback.',
            )
            : UnlockResult(
              success: false,
              path: UnlockPath.none,
              message: 'Local unlock failed: ${local.reason}',
            );

    setState(() {
      _busy = false;
      _status = result.message;
      _statusSuccess = result.success;
    });

    if (result.success) {
      _startUnlockPulseCountdown();
      return;
    }

    if (!result.success) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(result.message)));
    }
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

  Future<void> _openAdmin() async {
    if (!_isAdmin) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Only admins can access cloud users.')),
      );
      return;
    }

    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder:
            (_) => AdminUsersScreen(
              usersService: widget.services.adminUsersService,
              currentUserUid: widget.user.uid,
            ),
      ),
    );
  }

  String _formatLastSeen(int? epochSec) {
    if (epochSec == null || epochSec <= 0) {
      return 'unknown';
    }

    final DateTime seenAt =
        DateTime.fromMillisecondsSinceEpoch(
          epochSec * 1000,
          isUtc: true,
        ).toLocal();
    final Duration age = DateTime.now().difference(seenAt);
    if (age.inSeconds < 60) {
      return '${age.inSeconds}s ago';
    }
    if (age.inMinutes < 60) {
      return '${age.inMinutes}m ago';
    }
    if (age.inHours < 24) {
      return '${age.inHours}h ago';
    }
    return '${age.inDays}d ago';
  }

  bool _isHeartbeatFresh(int? epochSec) {
    if (epochSec == null || epochSec <= 0) {
      return false;
    }
    final DateTime seenAt = DateTime.fromMillisecondsSinceEpoch(
      epochSec * 1000,
      isUtc: true,
    );
    final Duration age = DateTime.now().toUtc().difference(seenAt);
    return age.inSeconds <= AppConfig.deviceHeartbeatSeconds;
  }

  Widget _buildDeviceStatusCard() {
    return StreamBuilder<DeviceCloudState>(
      stream: widget.services.lockStateService.watchState(),
      builder: (
        BuildContext context,
        AsyncSnapshot<DeviceCloudState> snapshot,
      ) {
        if (snapshot.hasError) {
          return const ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.cloud_off, color: Color(0xFF932323)),
            title: Text('Device status unavailable'),
            subtitle: Text('Check cloud user access or network connectivity.'),
          );
        }

        if (snapshot.connectionState == ConnectionState.waiting &&
            !snapshot.hasData) {
          return const ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.sync),
            title: Text('Checking device status...'),
          );
        }

        final DeviceCloudState state =
            snapshot.data ??
            const DeviceCloudState(
              online: false,
              wifiConnected: false,
              relayState: 'unknown',
              lastSeenEpochSec: null,
              fwVersion: '',
            );

        final bool online =
            state.online && _isHeartbeatFresh(state.lastSeenEpochSec);
        return ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(
            online ? Icons.wifi_tethering : Icons.portable_wifi_off,
            color: online ? const Color(0xFF0A5B40) : const Color(0xFF932323),
          ),
          title: Text(online ? 'Device online' : 'Device offline'),
          subtitle: Text(
            'Relay: ${state.relayState}  •  Last seen: ${_formatLastSeen(state.lastSeenEpochSec)}'
            '${state.fwVersion.isEmpty ? '' : '  •  FW: ${state.fwVersion}'}',
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final bool unlockCoolingDown = _unlockPulseActive;
    final bool unlockActionsDisabled = _busy || unlockCoolingDown;
    final Color primaryProgressColor = Theme.of(context).colorScheme.primary;
    final Color onPrimaryProgressColor =
        Theme.of(context).colorScheme.onPrimary;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Poot'),
        actions: <Widget>[
          IconButton(
            onPressed:
                _busy ? null : () => widget.services.authService.signOut(),
            icon: const Icon(Icons.logout),
            tooltip: 'Sign out',
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: <Widget>[
          Text(
            widget.user.email ?? widget.user.uid,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          _buildDeviceStatusCard(),
          const SizedBox(height: 12),
          StatusBanner(message: _status, success: _statusSuccess),
          const SizedBox(height: 16),
          ElevatedButton.icon(
            onPressed:
                _busy ? _cancelUnlock : (unlockCoolingDown ? null : _unlock),
            icon: Icon(
              _busy
                  ? Icons.close
                  : (unlockCoolingDown ? Icons.check_circle : Icons.lock_open),
            ),
            label:
                _busy
                    ? const Text('Cancel')
                    : (unlockCoolingDown
                        ? _buildUnlockedButtonLabel(
                          progressColor: onPrimaryProgressColor,
                        )
                        : const Text('Unlock now')),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: unlockActionsDisabled ? null : _unlockLocal,
            icon: Icon(unlockCoolingDown ? Icons.check_circle : Icons.wifi),
            label:
                unlockCoolingDown
                    ? _buildUnlockedButtonLabel(
                      progressColor: primaryProgressColor,
                    )
                    : const Text('Local unlock'),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _busy ? null : _openSettings,
            icon: const Icon(Icons.settings),
            label: const Text('Local fallback settings'),
          ),
          if (_isAdmin) ...<Widget>[
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _busy ? null : _openAdmin,
              icon: const Icon(Icons.group),
              label: const Text('Cloud user access'),
            ),
          ],
        ],
      ),
    );
  }
}
