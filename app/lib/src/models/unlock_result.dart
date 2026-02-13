enum UnlockPath { cloud, local, none }

class UnlockResult {
  const UnlockResult({
    required this.success,
    required this.path,
    required this.message,
  });

  final bool success;
  final UnlockPath path;
  final String message;
}
