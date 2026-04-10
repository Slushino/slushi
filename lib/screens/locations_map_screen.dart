// Updated code for locations_map_screen.dart 

import 'package:flutter/material.dart';

class LocationsMapScreen extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Locations Map'),
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            ResponsiveButton(
              onPressed: () {
                // Action for button 1
              },
              label: 'Button 1',
            ),
            SizedBox(height: 20),
            ResponsiveButton(
              onPressed: () {
                // Action for button 2
              },
              label: 'Button 2',
            ),
          ],
        ),
      ),
    );
  }
}

class ResponsiveButton extends StatelessWidget {
  final VoidCallback onPressed;
  final String label;

  const ResponsiveButton({Key? key, required this.onPressed, required this.label}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return ElevatedButton(
      onPressed: onPressed,
      child: Text(label),
      style: ElevatedButton.styleFrom(
        padding: EdgeInsets.symmetric(horizontal: 20, vertical: 15),
        // Response to different screen sizes
      ),
    );
  }
}

// Ensuring location pins are locked can involve the map settings or state management
// Add the necessary code to lock the location pins based on your requirements.
