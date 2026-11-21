import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'src/sync_controller.dart';
import 'src/ui/home_screen.dart';
import 'src/ui/theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Draw behind the status and navigation bars (screens use SafeArea).
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  final controller = SyncController();
  controller.init();
  runApp(ClipStackApp(controller: controller));
}

class ClipStackApp extends StatelessWidget {
  const ClipStackApp({super.key, required this.controller});

  final SyncController controller;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ClipStack',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      home: HomeScreen(controller: controller),
    );
  }
}
