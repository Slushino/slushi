import 'package:flutter/material.dart';
import 'screens/locations_map_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SlushiApp());
}

/// Keep main.dart thin; all UI styling is handled inside LocationsMapScreen.
class SlushiApp extends StatelessWidget {
  const SlushiApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Slushi',
      home: LocationsMapScreen(),
    );
  }
}
