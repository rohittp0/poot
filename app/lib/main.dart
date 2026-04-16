import 'package:flutter/material.dart';

import 'src/app.dart';
import 'src/services/app_services.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(PootApp(services: AppServices.create()));
}
