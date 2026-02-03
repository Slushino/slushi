import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:hello_flutter/pages/webview_page.dart';

void main() {
  runApp(const SlushiApp());
}

class SlushiApp extends StatefulWidget {
  const SlushiApp({super.key});

  @override
  State<SlushiApp> createState() => _SlushiAppState();
}

class _SlushiAppState extends State<SlushiApp> {
  ThemeMode _mode = ThemeMode.light;

  void _toggleTheme() {
    setState(() {
      _mode = _mode == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark;
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Slushi',
      themeMode: _mode,
      theme: ThemeData(useMaterial3: true, brightness: Brightness.light),
      darkTheme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
      home: LocationsMapScreen(
        themeMode: _mode,
        onToggleTheme: _toggleTheme,
      ),
    );
  }
}

class SlushLocation {
  final String id;
  final String name;
  final String? subtitle;
  final double lat;
  final double lng;

  const SlushLocation({
    required this.id,
    required this.name,
    required this.lat,
    required this.lng,
    this.subtitle,
  });

  LatLng get point => LatLng(lat, lng);

  factory SlushLocation.fromJson(Map<String, dynamic> json) {
    return SlushLocation(
      id: json['id'] as String,
      name: json['name'] as String,
      subtitle: json['subtitle'] as String?,
      lat: (json['lat'] as num).toDouble(),
      lng: (json['lng'] as num).toDouble(),
    );
  }
}

class LocationsMapScreen extends StatefulWidget {
  final ThemeMode themeMode;
  final VoidCallback onToggleTheme;

  const LocationsMapScreen({
    super.key,
    required this.themeMode,
    required this.onToggleTheme,
  });

  @override
  State<LocationsMapScreen> createState() => _LocationsMapScreenState();
}

class _LocationsMapScreenState extends State<LocationsMapScreen> {
  // IMPORTANT: your exact icon filename (case-sensitive)
  static const String kIconAsset = 'assets/Icon2.png';

  // Button colors (your screenshot vibe)

  final MapController _map = MapController();

  List<SlushLocation> _locations = const [];

  final LatLng _startCenter = const LatLng(60.4720, 8.4689);
  final double _startZoom = 5.6;

  LatLng? _myPoint;
  bool _loadingMyLocation = false;

  bool get _isDark => Theme.of(context).brightness == Brightness.dark;

  String get _tileUrl => _isDark
      ? 'https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}{r}.png'
      : 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';

  @override
  void initState() {
    super.initState();
    _loadLocations();
  }

  Future<void> _loadLocations() async {
    try {
      final raw = await rootBundle.loadString('assets/locations.json');
      final decoded = (jsonDecode(raw) as List).cast<dynamic>();
      final parsed = decoded
          .map((e) => SlushLocation.fromJson((e as Map).cast<String, dynamic>()))
          .toList();

      if (!mounted) return;
      setState(() => _locations = parsed);
    } catch (e) {
      // If locations.json isn't there yet, app still runs with empty list.
      _toast('Could not load assets/locations.json');
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  // ---- D) My location ----
  Future<LatLng?> _fetchMyLocation() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      _toast('Location services are off.');
      return null;
    }

    LocationPermission perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }

    if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
      _toast('Location permission denied.');
      return null;
    }

    final pos = await Geolocator.getCurrentPosition(
      desiredAccuracy: LocationAccuracy.high,
    );

    return LatLng(pos.latitude, pos.longitude);
  }

  Future<void> _goToMyLocation() async {
    if (_loadingMyLocation) return;
    setState(() => _loadingMyLocation = true);

    try {
      final me = await _fetchMyLocation();
      if (!mounted) return;
      if (me == null) return;

      setState(() => _myPoint = me);
      _map.move(me, 14.5);
    } finally {
      if (mounted) setState(() => _loadingMyLocation = false);
    }
  }

  // ---- B) Marker tap -> bottom sheet ----
  void _openLocationSheet(SlushLocation loc, {double? distanceMeters}) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => LocationSheet(location: loc, distanceMeters: distanceMeters),
    );
  }

  // ---- A) Nearest slush ----
  Future<void> _nearestSlush() async {
    if (_locations.isEmpty) {
      _toast('No locations loaded yet.');
      return;
    }

    LatLng? me = _myPoint;
    me ??= await _fetchMyLocation();
    if (!mounted) return;
    if (me == null) return;

    setState(() => _myPoint = me);

    const dist = Distance();
    SlushLocation nearest = _locations.first;
    double best = dist(me, nearest.point);

    for (final loc in _locations.skip(1)) {
      final d = dist(me, loc.point);
      if (d < best) {
        best = d;
        nearest = loc;
      }
    }

    _map.move(nearest.point, 15.0);
    _openLocationSheet(nearest, distanceMeters: best);
  }

  void _contactUs() {
    _toast('Contact Us (we can open email/web next)');
  }

  @override
  Widget build(BuildContext context) {
    final locationMarkers = _locations.map((loc) {
      return Marker(
        point: loc.point,
        width: 48,
        height: 48,
        child: GestureDetector(
          onTap: () => _openLocationSheet(loc),
          child: Image.asset(kIconAsset),
        ),
      );
    }).toList();

    final myMarker = _myPoint == null
        ? <Marker>[]
        : [
            Marker(
              point: _myPoint!,
              width: 18,
              height: 18,
              child: Container(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.blueAccent,
                  border: Border.all(color: Colors.white, width: 3),
                  boxShadow: const [BoxShadow(blurRadius: 10, color: Colors.black26)],
                ),
              ),
            ),
          ];

    return Scaffold(
      body: Stack(
        children: [
          FlutterMap(
            mapController: _map,
            options: MapOptions(
              initialCenter: _startCenter,
              initialZoom: _startZoom,
            ),
            children: [
              TileLayer(
                urlTemplate: _tileUrl,
                subdomains: _isDark ? const ['a', 'b', 'c', 'd'] : const [],
                userAgentPackageName: 'com.example.slushi',
              ),
              MarkerLayer(markers: locationMarkers),
              MarkerLayer(markers: myMarker),
            ],
          ),

          // Top-left logo (bigger, no text)
          Positioned(
            left: 14,
            top: 42,
            child: Image.asset(kIconAsset, width: 46, height: 46),
          ),

          // Top-right: Nearest + Contact + Theme toggle
          Positioned(
            right: 14,
            top: 34,
            child: Row(
              children: [
                PillButton(
                  icon: Icons.near_me,
                  text: 'Nearest slush',
                  onTap: _nearestSlush,
                ),
                const SizedBox(width: 12),
                PillButton(
                  icon: Icons.email_outlined,
                  text: 'Contact Us',
                  onTap: _contactUs,
                ),
                const SizedBox(width: 12),
                CircleIconButton(
                  icon: widget.themeMode == ThemeMode.dark
                      ? Icons.wb_sunny
                      : Icons.nightlight_round,
                  onTap: widget.onToggleTheme,
                ),
              ],
            ),
          ),

          // Bottom-left: My location button
          Positioned(
            left: 16,
            bottom: 54,
            child: CircleIconButton(
              icon: _loadingMyLocation ? Icons.hourglass_bottom : Icons.my_location,
              onTap: _goToMyLocation,
              size: 52,
            ),
          ),

          // Privacy policy placeholder
          Positioned(
            left: 16,
            bottom: 18,
            child: GestureDetector(
              onTap: () => _toast('Privacy Policy (we can open a page next)'),
              child: const Text(
                'Privacy Policy',
                style: TextStyle(fontSize: 12, decoration: TextDecoration.underline),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class PillButton extends StatelessWidget {
  final IconData icon;
  final String text;
  final VoidCallback onTap;

  const PillButton({
    super.key,
    required this.icon,
    required this.text,
    required this.onTap,
  });

  static const Color bg = Color(0xFFE6F4FF);
  static const Color fg = Color(0xFF1E6FB9);

  @override
  Widget build(BuildContext context) {
    return Material(
      color: bg,
      elevation: 0,
      borderRadius: BorderRadius.circular(22),
      child: InkWell(
        borderRadius: BorderRadius.circular(22),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: const BoxDecoration(
            boxShadow: [
              BoxShadow(
                blurRadius: 10,
                offset: Offset(0, 4),
                color: Color(0x22000000),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 18, color: fg),
              const SizedBox(width: 8),
              Text(
                text,
                style: const TextStyle(
                  color: fg,
                  fontWeight: FontWeight.w700,
                  fontSize: 14,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class CircleIconButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final double size;

  const CircleIconButton({
    super.key,
    required this.icon,
    required this.onTap,
    this.size = 44,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: size,
        height: size,
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.white,
          boxShadow: [
            BoxShadow(
              blurRadius: 16,
              offset: Offset(0, 6),
              color: Color(0x33000000),
            ),
          ],
        ),
        child: Icon(icon),
      ),
    );
  }
}

class LocationSheet extends StatelessWidget {
  final SlushLocation location;
  final double? distanceMeters;

  const LocationSheet({
    super.key,
    required this.location,
    this.distanceMeters,
  });

  String _distanceText() {
    if (distanceMeters == null) return '';
    final m = distanceMeters!;
    if (m < 1000) return '${m.toStringAsFixed(0)} m away';
    return '${(m / 1000).toStringAsFixed(2)} km away';
    }

  @override
  Widget build(BuildContext context) {
    final dist = _distanceText();

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 44,
              height: 5,
              margin: const EdgeInsets.only(bottom: 12),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.15),
                borderRadius: BorderRadius.circular(999),
              ),
            ),
            Row(
              children: [
                Expanded(
                  child: Text(
                    location.name,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            ),
            if (location.subtitle != null) ...[
              const SizedBox(height: 6),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  location.subtitle!,
                  style: TextStyle(
                    color: Theme.of(context).textTheme.bodyMedium?.color?.withOpacity(0.7),
                  ),
                ),
              ),
            ],
            if (dist.isNotEmpty) ...[
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  dist,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
            ],
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Close'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
