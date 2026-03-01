import 'package:flutter/material.dart';
import 'package:hello_flutter/screens/locations_map_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SlushiApp());
}

class SlushiApp extends StatelessWidget {
  const SlushiApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: LocationsMapScreen(),
    );
  }
}
