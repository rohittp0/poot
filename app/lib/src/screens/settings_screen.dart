import 'package:flutter/material.dart';

import '../models/local_unlock_settings.dart';
import '../services/settings_service.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.settingsService});

  final SettingsService settingsService;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final TextEditingController _ssidController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _secretController = TextEditingController();
  final TextEditingController _baseUrlController = TextEditingController();

  bool _loading = true;
  bool _saving = false;
  bool _showPassword = false;
  bool _showSharedSecret = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final LocalUnlockSettings settings =
        await widget.settingsService.readSettings();
    _ssidController.text = settings.espSsid;
    _passwordController.text = settings.espPassword;
    _secretController.text = settings.sharedSecret;
    _baseUrlController.text = settings.baseUrl;
    if (mounted) {
      setState(() {
        _loading = false;
      });
    }
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
    });

    final LocalUnlockSettings settings = LocalUnlockSettings(
      espSsid: _ssidController.text,
      espPassword: _passwordController.text,
      sharedSecret: _secretController.text,
      baseUrl: _baseUrlController.text,
    );

    await widget.settingsService.saveSettings(settings);

    if (!mounted) {
      return;
    }

    setState(() {
      _saving = false;
    });

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Local fallback settings saved.')),
    );
  }

  Future<void> _resetToDefaults() async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Reset local fallback?'),
          content: const Text(
            'This will replace current local settings with generated defaults.',
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Reset'),
            ),
          ],
        );
      },
    );

    if (confirmed != true) {
      return;
    }

    setState(() {
      _saving = true;
    });

    final LocalUnlockSettings settings =
        await widget.settingsService.resetToDefaults();

    if (!mounted) {
      return;
    }

    setState(() {
      _ssidController.text = settings.espSsid;
      _passwordController.text = settings.espPassword;
      _secretController.text = settings.sharedSecret;
      _baseUrlController.text = settings.baseUrl;
      _showPassword = false;
      _showSharedSecret = false;
      _saving = false;
    });

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Local fallback settings reset to defaults.'),
      ),
    );
  }

  @override
  void dispose() {
    _ssidController.dispose();
    _passwordController.dispose();
    _secretController.dispose();
    _baseUrlController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Poot settings')),
      body:
          _loading
              ? const Center(child: CircularProgressIndicator())
              : ListView(
                padding: const EdgeInsets.all(20),
                children: <Widget>[
                  const Text(
                    'Local fallback',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _ssidController,
                    decoration: const InputDecoration(
                      labelText: 'ESP hotspot SSID',
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _passwordController,
                    decoration: InputDecoration(
                      labelText: 'ESP hotspot password',
                      suffixIcon: IconButton(
                        icon: Icon(
                          _showPassword
                              ? Icons.visibility_off
                              : Icons.visibility,
                        ),
                        tooltip:
                            _showPassword ? 'Hide password' : 'Show password',
                        onPressed: () {
                          setState(() {
                            _showPassword = !_showPassword;
                          });
                        },
                      ),
                    ),
                    obscureText: !_showPassword,
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _secretController,
                    decoration: InputDecoration(
                      labelText: 'Shared HMAC secret',
                      suffixIcon: IconButton(
                        icon: Icon(
                          _showSharedSecret
                              ? Icons.visibility_off
                              : Icons.visibility,
                        ),
                        tooltip:
                            _showSharedSecret
                                ? 'Hide shared secret'
                                : 'Show shared secret',
                        onPressed: () {
                          setState(() {
                            _showSharedSecret = !_showSharedSecret;
                          });
                        },
                      ),
                    ),
                    obscureText: !_showSharedSecret,
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _baseUrlController,
                    decoration: const InputDecoration(
                      labelText: 'Local base URL',
                      hintText: 'http://192.168.4.1',
                    ),
                  ),
                  const SizedBox(height: 18),
                  ElevatedButton(
                    onPressed: _saving ? null : _save,
                    child: Text(_saving ? 'Saving...' : 'Save settings'),
                  ),
                  const SizedBox(height: 10),
                  OutlinedButton.icon(
                    onPressed: _saving ? null : _resetToDefaults,
                    icon: const Icon(Icons.restore),
                    label: const Text('Reset to defaults'),
                  ),
                ],
              ),
    );
  }
}
