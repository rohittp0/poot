import 'package:flutter/material.dart';

class StatusBanner extends StatelessWidget {
  const StatusBanner({super.key, required this.message, required this.success});

  final String message;
  final bool success;

  @override
  Widget build(BuildContext context) {
    final Color bg =
        success ? const Color(0xFFDCEFE8) : const Color(0xFFFCE1E1);
    final Color fg =
        success ? const Color(0xFF0A5B40) : const Color(0xFF932323);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        message,
        style: TextStyle(color: fg, fontWeight: FontWeight.w600),
      ),
    );
  }
}
