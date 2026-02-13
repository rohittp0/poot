import 'package:flutter/material.dart';

import '../models/device_account.dart';
import '../models/lock_user.dart';
import '../services/admin_users_service.dart';

class AdminUsersScreen extends StatefulWidget {
  const AdminUsersScreen({
    super.key,
    required this.usersService,
    required this.currentUserUid,
  });

  final AdminUsersService usersService;
  final String currentUserUid;

  @override
  State<AdminUsersScreen> createState() => _AdminUsersScreenState();
}

class _AdminUsersScreenState extends State<AdminUsersScreen> {
  bool _saving = false;

  Future<void> _addUserDialog() async {
    final TextEditingController emailController = TextEditingController();
    String role = 'member';
    bool enabled = true;
    bool submitting = false;
    String? dialogError;

    await showDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) {
        return StatefulBuilder(
          builder: (
            BuildContext context,
            void Function(void Function()) setState,
          ) {
            return AlertDialog(
              title: const Text('Add cloud user'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  TextField(
                    controller: emailController,
                    decoration: const InputDecoration(labelText: 'User email'),
                    keyboardType: TextInputType.emailAddress,
                    autocorrect: false,
                  ),
                  const SizedBox(height: 10),
                  DropdownButtonFormField<String>(
                    value: role,
                    items: const <DropdownMenuItem<String>>[
                      DropdownMenuItem(value: 'member', child: Text('member')),
                      DropdownMenuItem(value: 'admin', child: Text('admin')),
                    ],
                    onChanged: (String? value) {
                      if (value == null) {
                        return;
                      }
                      setState(() {
                        role = value;
                      });
                    },
                  ),
                  const SizedBox(height: 10),
                  SwitchListTile(
                    title: const Text('Enabled'),
                    value: enabled,
                    contentPadding: EdgeInsets.zero,
                    onChanged: (bool value) {
                      setState(() {
                        enabled = value;
                      });
                    },
                  ),
                  if (dialogError != null) ...<Widget>[
                    const SizedBox(height: 8),
                    Text(
                      dialogError!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ],
                ],
              ),
              actions: <Widget>[
                TextButton(
                  onPressed:
                      submitting ? null : () => Navigator.pop(dialogContext),
                  child: const Text('Cancel'),
                ),
                ElevatedButton(
                  onPressed:
                      submitting
                          ? null
                          : () async {
                            final String email = emailController.text.trim();
                            if (email.isEmpty) {
                              setState(() {
                                dialogError = 'Email is required.';
                              });
                              return;
                            }

                            setState(() {
                              submitting = true;
                              dialogError = null;
                            });

                            try {
                              final String? uid = await widget.usersService
                                  .findUidByEmail(email);
                              if (uid == null) {
                                setState(() {
                                  submitting = false;
                                  dialogError =
                                      'User must sign in once before being added.';
                                });
                                return;
                              }

                              await widget.usersService.upsertUser(
                                uid: uid,
                                role: role,
                                enabled: enabled,
                              );

                              if (dialogContext.mounted) {
                                Navigator.pop(dialogContext);
                              }
                            } catch (error) {
                              setState(() {
                                submitting = false;
                                dialogError = 'Failed to add user: $error';
                              });
                            }
                          },
                  child: Text(submitting ? 'Saving...' : 'Save'),
                ),
              ],
            );
          },
        );
      },
    );

    emailController.dispose();
  }

  Future<void> _toggleUser(LockUser user, bool enabled) async {
    if (user.uid == widget.currentUserUid) {
      return;
    }

    setState(() {
      _saving = true;
    });

    try {
      await widget.usersService.setEnabled(user.uid, enabled);
    } finally {
      if (mounted) {
        setState(() {
          _saving = false;
        });
      }
    }
  }

  Future<void> _setDeviceAccountDialog(DeviceAccount? current) async {
    final TextEditingController emailController = TextEditingController(
      text: current?.email ?? '',
    );
    bool submitting = false;
    String? dialogError;

    await showDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) {
        return StatefulBuilder(
          builder: (
            BuildContext context,
            void Function(void Function()) setState,
          ) {
            return AlertDialog(
              title: const Text('Set device account'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  TextField(
                    controller: emailController,
                    decoration: const InputDecoration(
                      labelText: 'Device email',
                      hintText: 'device@example.com',
                    ),
                    keyboardType: TextInputType.emailAddress,
                    autocorrect: false,
                  ),
                  if (dialogError != null) ...<Widget>[
                    const SizedBox(height: 8),
                    Text(
                      dialogError!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ],
                ],
              ),
              actions: <Widget>[
                TextButton(
                  onPressed:
                      submitting ? null : () => Navigator.pop(dialogContext),
                  child: const Text('Cancel'),
                ),
                ElevatedButton(
                  onPressed:
                      submitting
                          ? null
                          : () async {
                            final String email = emailController.text.trim();
                            if (email.isEmpty) {
                              setState(() {
                                dialogError = 'Email is required.';
                              });
                              return;
                            }

                            setState(() {
                              submitting = true;
                              dialogError = null;
                            });
                            try {
                              await widget.usersService.setDeviceAccountByEmail(
                                email,
                              );
                              if (dialogContext.mounted) {
                                Navigator.pop(dialogContext);
                              }
                            } on StateError catch (_) {
                              setState(() {
                                submitting = false;
                                dialogError =
                                    'User must sign in once before assignment.';
                              });
                            } catch (error) {
                              setState(() {
                                submitting = false;
                                dialogError =
                                    'Failed to set device account: $error';
                              });
                            }
                          },
                  child: Text(submitting ? 'Saving...' : 'Save'),
                ),
              ],
            );
          },
        );
      },
    );

    emailController.dispose();
  }

  Future<void> _toggleDeviceAccountEnabled(bool enabled) async {
    setState(() {
      _saving = true;
    });

    try {
      await widget.usersService.setDeviceAccountEnabled(enabled);
    } finally {
      if (mounted) {
        setState(() {
          _saving = false;
        });
      }
    }
  }

  Future<void> _changeRole(LockUser user, String role) async {
    if (user.uid == widget.currentUserUid || role == user.role) {
      return;
    }

    setState(() {
      _saving = true;
    });

    try {
      await widget.usersService.setRole(user.uid, role);
    } finally {
      if (mounted) {
        setState(() {
          _saving = false;
        });
      }
    }
  }

  Widget _buildUsersList(
    List<LockUser> users,
    Map<String, String> emailsByUid,
  ) {
    final List<LockUser> sortedUsers = List<LockUser>.from(users);
    sortedUsers.sort((LockUser a, LockUser b) {
      final String left = (emailsByUid[a.uid] ?? a.uid).toLowerCase();
      final String right = (emailsByUid[b.uid] ?? b.uid).toLowerCase();
      return left.compareTo(right);
    });

    if (sortedUsers.isEmpty) {
      return const Center(
        child: Text(
          'No users found. Add a user by email to grant cloud access.',
        ),
      );
    }

    return ListView.separated(
      itemCount: sortedUsers.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (BuildContext context, int index) {
        final LockUser user = sortedUsers[index];
        final bool isSelf = user.uid == widget.currentUserUid;
        final bool disableControls = _saving || isSelf;
        final String email = emailsByUid[user.uid] ?? user.uid;

        return ListTile(
          title: Text(email),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text('uid: ${user.uid}'),
              const SizedBox(height: 6),
              Row(
                children: <Widget>[
                  const Text('Role:'),
                  const SizedBox(width: 8),
                  DropdownButton<String>(
                    value: user.role,
                    onChanged:
                        disableControls
                            ? null
                            : (String? value) {
                              if (value == null) {
                                return;
                              }
                              _changeRole(user, value);
                            },
                    items: const <DropdownMenuItem<String>>[
                      DropdownMenuItem(value: 'member', child: Text('member')),
                      DropdownMenuItem(value: 'admin', child: Text('admin')),
                    ],
                  ),
                  const Spacer(),
                  const Text('Enabled'),
                  Switch(
                    value: user.enabled,
                    onChanged:
                        disableControls
                            ? null
                            : (bool value) => _toggleUser(user, value),
                  ),
                ],
              ),
              if (isSelf)
                const Text('You cannot disable or change your own role.'),
            ],
          ),
          isThreeLine: true,
        );
      },
    );
  }

  Widget _buildDeviceAccountSection(DeviceAccount? deviceAccount) {
    final String email = deviceAccount?.email ?? 'Not configured';
    final String uid = deviceAccount?.uid ?? '-';
    final bool enabled = deviceAccount?.enabled ?? false;

    return Card(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text(
              'Device account',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 6),
            Text('Email: $email'),
            Text('UID: $uid'),
            const SizedBox(height: 8),
            Row(
              children: <Widget>[
                ElevatedButton.icon(
                  onPressed:
                      _saving
                          ? null
                          : () => _setDeviceAccountDialog(deviceAccount),
                  icon: const Icon(Icons.edit),
                  label: Text(
                    deviceAccount == null ? 'Set device' : 'Change device',
                  ),
                ),
                const Spacer(),
                const Text('Enabled'),
                Switch(
                  value: enabled,
                  onChanged:
                      (_saving || deviceAccount == null)
                          ? null
                          : (bool value) => _toggleDeviceAccountEnabled(value),
                ),
              ],
            ),
            const SizedBox(height: 4),
            const Text(
              'Use an email that has already signed in once to this app.',
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Cloud users'),
        actions: <Widget>[
          IconButton(
            onPressed: _saving ? null : _addUserDialog,
            icon: const Icon(Icons.person_add),
          ),
        ],
      ),
      body: StreamBuilder<List<LockUser>>(
        stream: widget.usersService.watchUsers(),
        builder: (
          BuildContext context,
          AsyncSnapshot<List<LockUser>> usersSnapshot,
        ) {
          if (usersSnapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          if (usersSnapshot.hasError) {
            return Center(child: Text('Error: ${usersSnapshot.error}'));
          }

          return StreamBuilder<Map<String, String>>(
            stream: widget.usersService.watchIdentityEmailsByUid(),
            builder: (
              BuildContext context,
              AsyncSnapshot<Map<String, String>> identitySnapshot,
            ) {
              if (identitySnapshot.hasError) {
                return Center(child: Text('Error: ${identitySnapshot.error}'));
              }

              final List<LockUser> users =
                  usersSnapshot.data ?? const <LockUser>[];
              final Map<String, String> emailsByUid =
                  identitySnapshot.data ?? const <String, String>{};

              return StreamBuilder<DeviceAccount?>(
                stream: widget.usersService.watchDeviceAccount(),
                builder: (
                  BuildContext context,
                  AsyncSnapshot<DeviceAccount?> deviceAccountSnapshot,
                ) {
                  if (deviceAccountSnapshot.hasError) {
                    return Center(
                      child: Text('Error: ${deviceAccountSnapshot.error}'),
                    );
                  }

                  return Column(
                    children: <Widget>[
                      _buildDeviceAccountSection(deviceAccountSnapshot.data),
                      const Divider(height: 1),
                      Expanded(child: _buildUsersList(users, emailsByUid)),
                    ],
                  );
                },
              );
            },
          );
        },
      ),
    );
  }
}
