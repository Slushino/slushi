import 'dart:convert';
import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:hello_flutter/pages/webview_page.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  // Show a visible error UI instead of a blank screen in release/TestFlight.
  ErrorWidget.builder = (FlutterErrorDetails details) {
    return Material(
      color: Colors.white,
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Text(
            'Slushi failed to start:

${details.exceptionAsString()}',
            style: const TextStyle(fontSize: 14, color: Colors.black),
          ),
        ),
      ),
    );
  };

  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    debugPrint('FlutterError: ${details.exceptionAsString()}');
  };

  runZonedGuarded(
    () => runApp(const SlushiApp()),
    (error, stack) {
      debugPrint('Uncaught zone error: $error
$stack');
    },
  );
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

class _LocationsMapScreenState extends State<LocationsMapScreen> with WidgetsBindingObserver {
  static const String logoAsset = 'assets/Icon2.png';
  static const String pinAsset = 'assets/pin.png';

  // ✅ Published CSV link
  static const String _csvUrl =
      'https://docs.google.com/spreadsheets/d/e/2PACX-1vTAOcnlq0N_r7itvVdMhhzoWLo4AmXlvb1KwZlpjZnbNoslqExGlqdpRUxnWa1wqPGo9Lmnhqr5LTMi/pub?output=csv';

  // ✅ Privacy link
  static const String _privacyUrl = 'https://slushi.no/privacy.html';

  late MapController _mapController;

  // iOS: force rebuild of the native map view on resume (prevents blank tiles)
  Key _mapKey = UniqueKey();

  // Gate camera moves until the map is ready
  bool _mapReady = false;
  LatLng? _pendingCenter;
  double? _pendingZoom;

  final LatLng _startCenter = const LatLng(60.4720, 8.4689);
  final double _startZoom = 5.6;

  List<SlushLocation> _locations = const [];

  LatLng? _myLocation;
  bool _loadingMyLocation = false;
  bool _didAutoCenterOnce = false;

  // Tile diagnostics (helps debug TestFlight blank maps without Xcode logs)
  int _tileErrorCount = 0;
  String? _lastTileError;
  Timer? _tileErrDebounce;


  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _mapController = MapController();
    _loadLocationsFromPublishedCsv();

    // Auto-center only if permission is already granted.
// If Info.plist is missing location usage strings, Geolocator can throw at startup in release/TestFlight.
// So we guard everything with try/catch and avoid prompting on launch.
WidgetsBinding.instance.addPostFrameCallback((_) async {
  try {
    final perm = await Geolocator.checkPermission();
    final ok = perm == LocationPermission.whileInUse || perm == LocationPermission.always;
    if (ok) {
      await _goToMyLocation(showErrors: false, auto: true);
    }
  } catch (e) {
    debugPrint('Auto location skipped: $e');
  }
});
  }


  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _tileErrDebounce?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Recreate map widget + controller to avoid iOS blank tile state after reopen
      setState(() {
        _mapReady = false;
        _pendingCenter = null;
        _pendingZoom = null;
        _mapController = MapController();
        _mapKey = UniqueKey();
      });

      // Reload pins (cold start / resume timing differs in TestFlight sometimes)
      _loadLocationsFromPublishedCsv();

      // Re-center once map is ready if we already have a location
      if (_myLocation != null) {
        _pendingCenter = _myLocation;
        _pendingZoom = 14.5;
      }
    }
  }

  double _clampZoom(double z) => z.clamp(3.0, 19.0);

  void _safeMove(LatLng center, double zoom) {
    final z = _clampZoom(zoom);

    if (!_mapReady) {
      _pendingCenter = center;
      _pendingZoom = z;
      return;
    }

    // Big zoom jumps can burst-request many tiles, which sometimes causes “blank map until interaction”
    // on iOS/TestFlight. A 2-step move reduces request spikes.
    final currentZoom = _mapController.camera.zoom;
    final needsStep = (z - currentZoom).abs() > 4.5 && z > 11.5;

    if (needsStep) {
      final midZoom = (currentZoom < z) ? 12.0 : 10.0;
      _mapController.move(center, _clampZoom(midZoom));
      Future.delayed(const Duration(milliseconds: 250), () {
        if (!mounted) return;
        _mapController.move(center, z);
        setState(() {}); // nudge repaint
      });
      return;
    }

    _mapController.move(center, z);

    // iOS tile redraw workaround: a second move + rebuild shortly after often forces tiles to render
    Future.delayed(const Duration(milliseconds: 220), () {
      if (!mounted) return;
      _mapController.move(center, z);
      setState(() {}); // force layers/tiles to repaint
    });
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

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  void _noteTileError(Object error) {
    _tileErrorCount++;
    _lastTileError = error.toString();

    // Avoid rebuilding the whole UI for every single failed tile
    _tileErrDebounce?.cancel();
    _tileErrDebounce = Timer(const Duration(milliseconds: 500), () {
      if (!mounted) return;
      setState(() {});
    });
  }

  void _retryMapTiles() {
    setState(() {
      _mapReady = false;
      _pendingCenter = null;
      _pendingZoom = null;
      _tileErrorCount = 0;
      _lastTileError = null;
      _mapController = MapController();
      _mapKey = UniqueKey();
    });
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
        _snack('No valid rows found in CSV.');
      }
    } catch (e) {
      if (!mounted) return;
      _snack('Could not load locations: $e');
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

  /// Opens a dialog with a single action button.
  Future<void> _showActionDialog({
    required String title,
    required String message,
    required String actionText,
    required Future<void> Function() action,
  }) async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(ctx);
              await action();
            },
            child: Text(actionText),
          ),
        ],
      ),
    );
  }

  /// Robust iOS/Android location flow with clear messages + fallback settings buttons.
  Future<LatLng?> _getMyLocation({required bool showErrors}) async {
    // Debug prints show in Xcode console
    debugPrint('GET LOCATION: start');

    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    debugPrint('GET LOCATION: serviceEnabled=$serviceEnabled');

    if (!serviceEnabled) {
      if (showErrors) {
        _snack('Location Services are OFF. Turn them on in Settings.');
        await _showActionDialog(
          title: 'Location Services Off',
          message:
              'To find nearby slushi spots, turn on Location Services in iPhone Settings.',
          actionText: 'Open Settings',
          action: () => Geolocator.openLocationSettings(),
        );
      }
      return null;
    }

    var perm = await Geolocator.checkPermission();
    debugPrint('GET LOCATION: initial permission=$perm');

    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
      debugPrint('GET LOCATION: after request permission=$perm');
    }

    if (perm == LocationPermission.denied) {
      if (showErrors) _snack('Location permission denied.');
      return null;
    }

    if (perm == LocationPermission.deniedForever) {
      if (showErrors) {
        _snack('Location permission is blocked. Enable it in Settings.');
        await _showActionDialog(
          title: 'Location Permission Blocked',
          message:
              'Location access is blocked for Slushi. Open Settings and set Location to “While Using the App”.',
          actionText: 'Open App Settings',
          action: () => Geolocator.openAppSettings(),
        );
      }
      return null;
    }

    try {
      final pos = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
        timeLimit: const Duration(seconds: 12),
      );
      debugPrint('GET LOCATION: success lat=${pos.latitude} lng=${pos.longitude}');
      return LatLng(pos.latitude, pos.longitude);
    } catch (e) {
      debugPrint('GET LOCATION: error $e');
      if (showErrors) _snack('Could not get your location. Try again.');
      return null;
    }
  }

  Future<void> _goToMyLocation({bool showErrors = true, bool auto = false}) async {
  if (_loadingMyLocation) return;
  if (auto && _didAutoCenterOnce) return;

  setState(() => _loadingMyLocation = true);

  try {
    LatLng? loc;
    try {
      loc = await _getMyLocation(showErrors: showErrors);
    } catch (e, st) {
      debugPrint('Geolocator error: \$e\n\$st');
      if (showErrors) _snack('Location failed. Check Settings and try again.');
      loc = null;
    }

    if (!mounted || loc == null) return;

    setState(() => _myLocation = loc);

    // ✅ Use safe move (waits for map ready + forces tile refresh)
    _safeMove(loc, 14.5);

    if (auto) _didAutoCenterOnce = true;
  } finally {
    if (mounted) setState(() => _loadingMyLocation = false);
  }
}

  void _nearestSlush() async {
    if (_locations.isEmpty) return;

    final me = _myLocation ?? await _getMyLocation(showErrors: true);
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

    _safeMove(nearest.point, 15);
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
      // Use a square marker box + bottom-center alignment to prevent marker drift on zoom.
      // (Non-square marker boxes can cause visible offset at different zoom levels in flutter_map.)
      const double box = 60;
      const double pinW = 52;
      const double pinH = 60;

      return Marker(
        point: loc.point,
        width: box,
        height: box,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => _openLocationSheet(loc, 0),
          child: Align(
            alignment: Alignment.bottomCenter,
            child: SizedBox(
              width: pinW,
              height: pinH,
              child: Image.asset(
                pinAsset,
                fit: BoxFit.contain,
                filterQuality: FilterQuality.high,
                errorBuilder: (context, error, stack) => const Icon(Icons.location_on),
              ),
            ),
          ),
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
            key: _mapKey,
            mapController: _mapController,
            options: MapOptions(
              initialCenter: _startCenter,
              initialZoom: _startZoom,
              interactionOptions: const InteractionOptions(
                flags: InteractiveFlag.all,
              ),
              onMapReady: () {
                _mapReady = true;

                if (_pendingCenter != null && _pendingZoom != null) {
                  final c = _pendingCenter!;
                  final z = _pendingZoom!;
                  _pendingCenter = null;
                  _pendingZoom = null;
                  _safeMove(c, z);
                } else if (_myLocation != null) {
                  _safeMove(_myLocation!, 14.5);
                }
              },
            ),
            children: [
              TileLayer(
                // NOTE: tile.openstreetmap.org is not meant for heavy production app usage and may throttle/block.
                // Consider switching to a commercial/free tier tile provider for stability.
                urlTemplate: 'https://{s}.basemaps.cartocdn.com/light_all/{z}/{x}/{y}{r}.png',
                subdomains: const ['a', 'b', 'c', 'd'],
                userAgentPackageName: 'no.slushi.app',
                minZoom: 3,
                maxZoom: 19,
                maxNativeZoom: 19,

                // Buffers help reduce “blank until interaction” during/after programmatic moves
                panBuffer: 1,
                keepBuffer: 2,

                // Prefer instant display to reduce odd fade/repaint states on iOS
                tileDisplay: const TileDisplay.instantaneous(),

                // Explicit headers help some servers accept requests on iOS/TestFlight
                tileProvider: NetworkTileProvider(
                  headers: const {
                    'User-Agent': 'no.slushi.app',
                  },
                ),

                // Evict failed tiles so they don't get stuck in cache
                evictErrorTileStrategy: EvictErrorTileStrategy.dispose,

                // Log tile failures (check device logs via Console.app when testing TestFlight)
                errorTileCallback: (tile, error, stackTrace) {
                  _noteTileError(error);
                },
              ),
              MarkerLayer(alignment: Alignment.bottomCenter, markers: markers),
              MarkerLayer(alignment: Alignment.center, markers: myMarker),

              RichAttributionWidget(
                alignment: AttributionAlignment.bottomRight,
                attributions: [
                  TextSourceAttribution('© OpenStreetMap contributors © CARTO'),
                ],
              ),
            ],
          ),

          // TILE DEBUG / RETRY (shows only if tiles are failing)
          if (_tileErrorCount > 0)
            Positioned(
              left: 14,
              right: 14,
              bottom: 110,
              child: GestureDetector(
                onTap: _retryMapTiles,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.72),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.wifi_off, color: Colors.white, size: 18),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Map tiles failing ($_tileErrorCount). Tap to retry.\n${_lastTileError ?? ''}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Colors.white, fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),


          // TOP BAR
          Positioned(
            top: 34,
            left: 14,
            right: 14,
            child: Row(
              children: [
                Image.asset(
                  logoAsset,
                  width: 64,
                  height: 64,
                  errorBuilder: (context, error, stack) => const SizedBox(width: 64, height: 64),
                ),
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
              icon: _loadingMyLocation ? Icons.hourglass_bottom : Icons.my_location,
              onTap: () => _goToMyLocation(showErrors: true),
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
