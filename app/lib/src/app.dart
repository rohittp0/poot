import 'package:flutter/material.dart';

import 'screens/home_screen.dart';
import 'services/app_services.dart';
import 'theme/poot_theme.dart';

class PootApp extends StatelessWidget {
  const PootApp({super.key, required this.services});

  final AppServices services;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Poot',
      debugShowCheckedModeBanner: false,
      theme: PootTheme.light,
      home: HomeScreen(services: services),
    );
  }
}
