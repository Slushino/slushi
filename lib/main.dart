import 'dart:convert';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:hello_flutter/pages/webview_page.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

void main() {
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

/// =======================
/// MODEL
/// =======================
class SlushLocation {
  final String id;
  final String name;
  final String description;
  final String address;
  final double lat;
  final double lng;
  final String? imageUrl;

  const SlushLocation({
    required this.id,
    required this.name,
    required this.description,
    required this.address,
    required this.lat,
    required this.lng,
    this.imageUrl,
  });

  LatLng get point => LatLng(lat, lng);
}

/// =======================
/// SCREEN
/// =======================
class LocationsMapScreen extends StatefulWidget {
  const LocationsMapScreen({super.key});

  @override
  State<LocationsMapScreen> createState() => _LocationsMapScreenState();
}

class _LocationsMapScreenState extends State<LocationsMapScreen> {
  static const String logoAsset = 'assets/Icon2.png';
  static const String pinAsset = 'assets/pin.png';

  // ✅ Your published CSV link (you sent this)
  static const String _csvUrl =
      'https://docs.google.com/spreadsheets/d/e/2PACX-1vTAOcnlq0N_r7itvVdMhhzoWLo4AmXlvb1KwZlpjZnbNoslqExGlqdpRUxnWa1wqPGo9Lmnhqr5LTMi/pub?output=csv';

  // ✅ Privacy link
  static const String _privacyUrl = 'https://slushi.no/privacy.html';

  final MapController _mapController = MapController();

  final LatLng _startCenter = const LatLng(60.4720, 8.4689);
  final double _startZoom = 5.6;

  List<SlushLocation> _locations = const [];

  LatLng? _myLocation;
  bool _loadingMyLocation = false;

  @override
  void initState() {
    super.initState();
    _loadLocationsFromPublishedCsv();
  }

  /// Opens Privacy Policy inside the app (WebView)
  void _openPrivacyPolicyInApp() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => const WebViewPage(
          title: 'Privacy Policy',
          url: _privacyUrl,
        ),
      ),
    );
  }
  /// Opens Contact Us inside the app (WebView)
  void _openContactUsInApp() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => const WebViewPage(
          title: 'Contact Us',
          url: 'https://slushi.no/contact.html',
        ),
      ),
    );
  }

  Future<void> _loadLocationsFromPublishedCsv() async {
    try {
      final res = await http.get(Uri.parse(_csvUrl));
      if (res.statusCode != 200) {
        throw Exception('HTTP ${res.statusCode}');
      }

      // ✅ Fix for æ/ø/å (force UTF-8)
      final csvText = utf8.decode(res.bodyBytes);

      final rows = _parseCsv(csvText);
      if (rows.isEmpty) throw Exception('CSV is empty');

      final headers = rows.first.map((h) => h.trim()).toList();
      int idx(String name) => headers.indexOf(name);

      final idI = idx('id');
      final nameI = idx('name');
      final descI = idx('description');
      final addrI = idx('address');
      final latI = idx('lat');
      final lngI = idx('lng');
      final imgI = idx('imageUrl');

      if (idI == -1 || nameI == -1 || latI == -1 || lngI == -1) {
        throw Exception(
          'Missing headers. Must include: id,name,lat,lng (and preferably description,address,imageUrl).',
        );
      }

      final parsed = <SlushLocation>[];

      for (final row in rows.skip(1)) {
        if (row.every((c) => c.trim().isEmpty)) continue;

        String cell(int i) => (i >= 0 && i < row.length) ? row[i].trim() : '';

        final id = cell(idI);
        final name = cell(nameI);
        final description = descI == -1 ? '' : cell(descI);
        final address = addrI == -1 ? '' : cell(addrI);

        // Handle comma decimals just in case
        final latStr = cell(latI).replaceAll(',', '.');
        final lngStr = cell(lngI).replaceAll(',', '.');

        final lat = double.tryParse(latStr);
        final lng = double.tryParse(lngStr);

        if (id.isEmpty || name.isEmpty || lat == null || lng == null) {
          continue;
        }

        String? imageUrl;
        if (imgI != -1) {
          final img = cell(imgI);
          if (img.isNotEmpty) imageUrl = img;
        }

        parsed.add(
          SlushLocation(
            id: id,
            name: name,
            description: description,
            address: address,
            lat: lat,
            lng: lng,
            imageUrl: imageUrl,
          ),
        );
      }

      if (!mounted) return;
      setState(() => _locations = parsed);

      if (parsed.isEmpty && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No valid rows found in CSV.')),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not load locations: $e')),
      );
    }
  }

  /// Simple CSV parser (handles commas + quotes)
  List<List<String>> _parseCsv(String input) {
    final rows = <List<String>>[];
    var currentRow = <String>[];
    final current = StringBuffer();
    bool inQuotes = false;

    for (int i = 0; i < input.length; i++) {
      final char = input[i];

      if (char == '"') {
        if (inQuotes && i + 1 < input.length && input[i + 1] == '"') {
          current.write('"');
          i++;
        } else {
          inQuotes = !inQuotes;
        }
      } else if (char == ',' && !inQuotes) {
        currentRow.add(current.toString());
        current.clear();
      } else if ((char == '\n' || char == '\r') && !inQuotes) {
        if (char == '\r' && i + 1 < input.length && input[i + 1] == '\n') {
          i++;
        }
        currentRow.add(current.toString());
        current.clear();
        rows.add(currentRow);
        currentRow = <String>[];
      } else {
        current.write(char);
      }
    }

    currentRow.add(current.toString());
    rows.add(currentRow);

    if (rows.isNotEmpty && rows.last.every((c) => c.trim().isEmpty)) {
      rows.removeLast();
    }
    return rows;
  }

  Future<LatLng?> _getMyLocation() async {
    if (!await Geolocator.isLocationServiceEnabled()) return null;

    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    if (perm == LocationPermission.denied ||
        perm == LocationPermission.deniedForever) {
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
      final loc = await _getMyLocation();
      if (!mounted || loc == null) return;

      setState(() => _myLocation = loc);
      _mapController.move(loc, 14.5);
    } finally {
      if (mounted) setState(() => _loadingMyLocation = false);
    }
  }

  void _nearestSlush() async {
    if (_locations.isEmpty) return;

    final me = _myLocation ?? await _getMyLocation();
    if (!mounted || me == null) return;

    setState(() => _myLocation = me);

    final dist = const Distance();
    SlushLocation nearest = _locations.first;
    double best = dist(me, nearest.point);

    for (final l in _locations.skip(1)) {
      final d = dist(me, l.point);
      if (d < best) {
        best = d;
        nearest = l;
      }
    }

    _mapController.move(nearest.point, 15);
    _openLocationSheet(nearest, best);
  }

  void _openLocationSheet(SlushLocation loc, double distanceMeters) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => LocationSheet(
        location: loc,
        distanceMeters: distanceMeters,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final List<Marker> markers = _locations.map<Marker>((loc) {
      const double pinW = 52;
      const double pinH = 60;

      return Marker(
        point: loc.point,
        width: pinW,
        height: pinH,
        child: Builder(
          builder: (context) {
            // counter-rotate so pin stays straight
            final rotation = MapCamera.of(context).rotationRad;

            return GestureDetector(
              onTap: () => _openLocationSheet(loc, 0),
              child: Transform.translate(
                // move pin up so the "tip" hits the coordinate
                offset: const Offset(0, -pinH / 2 + 6),
                child: Transform.rotate(
                  angle: -rotation,
                  child: Image.asset(
  pinAsset,
  fit: BoxFit.contain,
  filterQuality: FilterQuality.high, //
                  ),
                ),
              ),
            );
          },
        ),
      );
    }).toList();

    final List<Marker> myMarker = _myLocation == null
        ? <Marker>[]
        : <Marker>[
            Marker(
              point: _myLocation!,
              width: 16,
              height: 16,
              child: Container(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.blueAccent,
                  border: Border.all(color: Colors.white, width: 3),
                ),
              ),
            ),
          ];

    return Scaffold(
      body: Stack(
        children: [
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: _startCenter,
              initialZoom: _startZoom,
              interactionOptions: const InteractionOptions(
                flags: InteractiveFlag.all,
              ),
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.example.slushi',
              ),
              MarkerLayer(markers: markers),
              MarkerLayer(markers: myMarker),
            ],
          ),

          // TOP BAR
          Positioned(
            top: 34,
            left: 14,
            right: 14,
            child: Row(
              children: [
                Image.asset(logoAsset, width: 64, height: 64),
                const Spacer(),
                _PillButton(
                  icon: Icons.near_me,
                  text: 'Nearest slush',
                  onTap: _nearestSlush,
                ),
                const SizedBox(width: 12),
                _PillButton(
                  icon: Icons.email_outlined,
                  text: 'Contact Us',
                  onTap: _openContactUsInApp,
                ),
              ],
            ),
          ),

          // MY LOCATION BUTTON
          Positioned(
            left: 16,
            bottom: 54,
            child: _CircleButton(
              icon: _loadingMyLocation
                  ? Icons.hourglass_bottom
                  : Icons.my_location,
              onTap: _goToMyLocation,
            ),
          ),

          // PRIVACY POLICY (IN-APP WEBVIEW)
          Positioned(
            left: 16,
            bottom: 18,
            child: GestureDetector(
              onTap: _openPrivacyPolicyInApp,
              child: const Text(
                'Privacy Policy',
                style: TextStyle(
                  fontSize: 12,
                  decoration: TextDecoration.underline,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// =======================
/// UI COMPONENTS
/// =======================
class _PillButton extends StatelessWidget {
  final IconData icon;
  final String text;
  final VoidCallback onTap;

  const _PillButton({
    required this.icon,
    required this.text,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFFE6F4FF),
      borderRadius: BorderRadius.circular(22),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(22),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              Icon(icon, size: 18, color: const Color(0xFF1E6FB9)),
              const SizedBox(width: 8),
              Text(
                text,
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF1E6FB9),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CircleButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;

  const _CircleButton({
    required this.icon,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 52,
      height: 52,
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
      child: IconButton(
        icon: Icon(icon),
        onPressed: onTap,
      ),
    );
  }
}

/// =======================
/// LOCATION SHEET
/// =======================
class LocationSheet extends StatelessWidget {
  final SlushLocation location;
  final double distanceMeters;

  const LocationSheet({
    super.key,
    required this.location,
    required this.distanceMeters,
  });

  Future<void> _openGoogleMaps() async {
    final lat = location.lat;
    final lng = location.lng;

    final url = Uri.parse(
      'https://www.google.com/maps/search/?api=1&query=$lat,$lng',
    );

    await launchUrl(url, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    final distanceText = distanceMeters <= 0
        ? null
        : (distanceMeters < 1000
            ? '${distanceMeters.toStringAsFixed(0)} m away'
            : '${(distanceMeters / 1000).toStringAsFixed(2)} km away');

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 18),
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
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                location.name,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            const SizedBox(height: 6),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(location.description),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                location.address,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            if (distanceText != null) ...[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(distanceText),
              ),
            ],
            const SizedBox(height: 12),

            if (location.imageUrl != null) ...[
              ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: CachedNetworkImage(
                  imageUrl: location.imageUrl!,
                  height: 170,
                  width: double.infinity,
                  fit: BoxFit.cover,
                  placeholder: (context, _) => Container(
                    height: 170,
                    color: Colors.black12,
                    alignment: Alignment.center,
                    child: const CircularProgressIndicator(),
                  ),
                  errorWidget: (context, _, __) => Container(
                    height: 170,
                    color: Colors.black12,
                    alignment: Alignment.center,
                    child: const Text('Could not load image'),
                  ),
                ),
              ),
              const SizedBox(height: 14),
            ],

            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _openGoogleMaps,
                    icon: const Icon(Icons.directions),
                    label: const Text('Navigate'),
                  ),
                ),
                const SizedBox(width: 12),
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

/// =======================
/// WEBVIEW SCREEN
/// =======================
class WebViewScreen extends StatefulWidget {
  final String title;
  final String url;

  const WebViewScreen({
    super.key,
    required this.title,
    required this.url,
  });

  @override
  State<WebViewScreen> createState() => _WebViewScreenState();
}

class _WebViewScreenState extends State<WebViewScreen> {
  late final WebViewController _controller;
  bool _loading = true;

  @override
  void initState() {
    super.initState();

    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (_) => setState(() => _loading = true),
          onPageFinished: (_) => setState(() => _loading = false),
        ),
      )
      ..loadRequest(Uri.parse(widget.url));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => _controller.reload(),
          ),
        ],
      ),
      body: Stack(
        children: [
          WebViewWidget(controller: _controller),
          if (_loading)
            const Center(
              child: CircularProgressIndicator(),
            ),
        ],
      ),
    );
  }
}
