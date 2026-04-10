import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:hello_flutter/pages/webview_page.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';

// ANCHORFIX_V2: marker width/height now match drawn markerBox (prevents zoom drift).


// Set to true if you ever want the live pin tuning panel back.
const bool kShowPinTuningPanel = false;


/// NOTE:
/// - UI (logo + pill buttons) matches the original Slushi layout.
/// - Marker drift fix: square marker box + NO pixel translate hacks.
/// - Pin stays upright when rotating map: manual counter-rotation around BOTTOM-CENTER (tip).
/// - Blank map on extreme zoom reduced: zoom clamped + tile debounce + buffers + fade-in.
class LocationsMapScreen extends StatefulWidget {
  const LocationsMapScreen({super.key});

  @override
  State<LocationsMapScreen> createState() => _LocationsMapScreenState();
}

class SlushLocation {
  final String name;
  final String address;
  final double lat;
  final double lng;
  final String? notes;

  const SlushLocation({
    required this.name,
    required this.address,
    required this.lat,
    required this.lng,
    this.notes,
  });

  LatLng get point => LatLng(lat, lng);
}

class _LocationsMapScreenState extends State<LocationsMapScreen> {
  // --- Links / assets
  static const String _privacyUrl = 'https://slushi.no/privacy.html';
  static const String _contactUrl = 'https://slushi.no/contact.html';

  // Google Sheets CSV export (gid=0)
  static const String _csvUrl =
      'https://docs.google.com/spreadsheets/d/1qLdNCCpcMnGQoTps9nIpyL8eeWWpeoWxhyOBP5RFA3g/gviz/tq?tqx=out:csv&gid=0';

  static const String _logoAsset = 'assets/Icon2.png';
  static const String _pinAsset = 'assets/pin.png';

  // --- Marker sizing (debug-adjustable)
  double _markerBox = 51.0; // square hitbox/anchor
  double _pinWidth = 70.0;
  double _pinHeight = 90.0;

  double get _hitBoxW => max(_markerBox, _pinWidth + 16.0);
  double get _hitBoxH => max(_markerBox, _pinHeight + _pinTipOffsetY.abs() + 16.0);



  // Pin-only: anchor LatLng to the actual pointy tip inside the PNG.
  // This compensates for the pin art not being perfectly centered and having a small shadow below the tip.

  // Debug-adjustable in release: change live with the on-screen +/- buttons.
  double _pinTipOffsetY = -36.0; // calibrated (start) for new pin size; tweak if needed

  // --- Map settings
  static const String _tileUrl =
      'https://tile.openstreetmap.org/{z}/{x}/{y}.png';

  static const LatLng _startCenter = LatLng(70.6646, 23.6904);
  static const double _startZoom = 12.5;

  // Clamp zoom to avoid extreme "all white" tile churn on OSM
  static const double _minZoom = 4.0;
  static const double _maxZoom = 17.0;

  // --- Debug toggles (enable while tuning pin anchoring)
  bool _showPinDebugAnchor = false;
  bool _showLatLngDebugDot = false;
  bool _showMarkerBoxOutline = false;

  final NetworkTileProvider _tileProvider = NetworkTileProvider(
    headers: <String, String>{
      'User-Agent': 'no.slushi.app (Slushi; contact: support@slushi.no)',
    },
  );

  final MapController _mapController = MapController();

  final GlobalKey _mapKey = GlobalKey();
  bool _darkUi = false;

  bool _loadingMyLocation = false;
  bool _didAutoCenterOnce = false;
  LatLng? _myLocation;

  List<SlushLocation> _locations = [];
  bool _loadingLocations = false;
  String? _locationsError;

  @override
  void initState() {
    super.initState();
    _refreshLocations();
    // Auto center once when we first get location (non-blocking)
    unawaited(_getMyLocation(auto: true, showErrors: false));
  }

  // Simple CSV parser that supports commas inside quotes
  List<List<String>> _parseCsv(String csv) {
    final rows = <List<String>>[];
    final field = StringBuffer();
    var row = <String>[];
    var inQuotes = false;

    for (var i = 0; i < csv.length; i++) {
      final ch = csv[i];

      if (ch == '"') {
        // Escaped quote
        if (inQuotes && i + 1 < csv.length && csv[i + 1] == '"') {
          field.write('"');
          i++;
        } else {
          inQuotes = !inQuotes;
        }
        continue;
      }

      if (!inQuotes && (ch == ',')) {
        row.add(field.toString().trim());
        field.clear();
        continue;
      }

      if (!inQuotes && (ch == '\n')) {
        row.add(field.toString().trim());
        field.clear();
        // ignore empty trailing lines
        if (row.any((c) => c.isNotEmpty)) rows.add(row);
        row = <String>[];
        continue;
      }

      if (ch != '\r') field.write(ch);
    }

    // last field
    row.add(field.toString().trim());
    if (row.any((c) => c.isNotEmpty)) rows.add(row);

    return rows;
  }

  Future<void> _refreshLocations() async {
    if (_loadingLocations) return;
    setState(() {
      _loadingLocations = true;
      _locationsError = null;
    });

    try {
      final res = await http
          .get(Uri.parse(_csvUrl))
          .timeout(const Duration(seconds: 12));
      if (res.statusCode != 200) {
        throw Exception('HTTP ${res.statusCode}');
      }

      final rows = _parseCsv(res.body);
      if (rows.isEmpty) throw Exception('Empty CSV');

      final header = rows.first.map((h) => h.toLowerCase()).toList();

      int idxLat = header.indexWhere((h) => h.contains('lat'));
      int idxLng = header.indexWhere(
        (h) => h.contains('lng') || h.contains('lon') || h.contains('long'),
      );
      int idxName = header.indexWhere(
        (h) => h.contains('name') || h.contains('title'),
      );
      int idxAddr = header.indexWhere(
        (h) => h.contains('address') || h.contains('addr'),
      );
      int idxNotes = header.indexWhere((h) => h.contains('note'));

      // Fallback indices if headers are missing
      idxName = idxName >= 0 ? idxName : 0;
      idxAddr = idxAddr >= 0 ? idxAddr : min(1, header.length - 1);

      if (idxLat < 0 || idxLng < 0) {
        // try common fixed positions: [name, address, lat, lng]
        if (header.length >= 4) {
          idxLat = 2;
          idxLng = 3;
        } else {
          throw Exception('Could not detect lat/lng columns');
        }
      }

      final parsed = <SlushLocation>[];
      for (final r in rows.skip(1)) {
        if (r.length <= max(max(idxLat, idxLng), max(idxName, idxAddr)))
          continue;

        final lat = double.tryParse(r[idxLat].replaceAll(',', '.'));
        final lng = double.tryParse(r[idxLng].replaceAll(',', '.'));
        if (lat == null || lng == null) continue;

        parsed.add(
          SlushLocation(
            name: r[idxName].isNotEmpty ? r[idxName] : 'Slush',
            address: r[idxAddr],
            lat: lat,
            lng: lng,
            notes: (idxNotes >= 0 && idxNotes < r.length) ? r[idxNotes] : null,
          ),
        );
      }

      if (!mounted) return;
      setState(() {
        _locations = parsed;
        _loadingLocations = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingLocations = false;
        _locationsError = 'DownloadFailed';
      });
    }
  }

  Future<LatLng?> _getMyLocation({
    bool auto = false,
    bool showErrors = true,
  }) async {
    if (_loadingMyLocation) return null;
    if (auto && _didAutoCenterOnce) return _myLocation;

    setState(() => _loadingMyLocation = true);

    try {
      final enabled = await Geolocator.isLocationServiceEnabled();
      if (!enabled) {
        if (showErrors && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Location services are disabled.')),
          );
        }
        return null;
      }

      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.deniedForever ||
          perm == LocationPermission.denied) {
        if (showErrors && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Location permission not granted.')),
          );
        }
        return null;
      }

      final pos = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
        timeLimit: const Duration(seconds: 8),
      );

      final loc = LatLng(pos.latitude, pos.longitude);
      if (!mounted) return loc;

      setState(() => _myLocation = loc);

      if (auto) _didAutoCenterOnce = true;

      // Center map once if auto
      if (auto) {
        _safeMove(loc, 14.5);
      }

      return loc;
    } catch (_) {
      return null;
    } finally {
      if (mounted) setState(() => _loadingMyLocation = false);
    }
  }

  void _safeMove(LatLng center, double zoom) {
    // clamp zoom to avoid OSM extremes
    final z = zoom.clamp(_minZoom, _maxZoom).toDouble();
    _mapController.move(center, z);
  }

  void _nearestSlush() async {
    if (_locations.isEmpty) return;

    final me = _myLocation ?? await _getMyLocation(showErrors: true);
    if (!mounted || me == null) return;

    setState(() => _myLocation = me);

    SlushLocation nearest = _locations.first;
    double best = const Distance().distance(me, nearest.point);

    for (final l in _locations.skip(1)) {
      final d = const Distance().distance(me, l.point);
      if (d < best) {
        best = d;
        nearest = l;
      }
    }

    _safeMove(nearest.point, 14.5);
    _openLocationSheet(nearest, best);
  }

  void _openLocationSheet(SlushLocation loc, double distanceMeters) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => LocationSheet(
        location: loc,
        distanceMeters: distanceMeters,
        onDirections: () {
          final url =
              'https://www.google.com/maps/dir/?api=1&destination=${loc.lat},${loc.lng}';
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => WebViewPage(title: 'Directions', url: url),
            ),
          );
        },
      ),
    );
  }

  void _openPrivacyInApp() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => WebViewPage(title: 'Privacy Policy', url: _privacyUrl),
      ),
    );
  }

  void _openContactUsInApp() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => WebViewPage(title: 'Contact Us', url: _contactUrl),
      ),
    );
  }

  Future<void> _openOsmCopyright() async {
    final uri = Uri.parse('https://www.openstreetmap.org/copyright');
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  Widget _dbgBtn(String label, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      child: Container(
        width: 28,
        height: 28,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: _darkUi ? Colors.white10 : Colors.black.withOpacity(0.06),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.black12),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w800,
            color: _darkUi ? Colors.white : Colors.black,
          ),
        ),
      ),
    );
  }

  Widget _dbgToggle({
    required String label,
    required bool value,
    required ValueChanged<bool> onChanged,
    required bool dark,
  }) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Switch(
          value: value,
          onChanged: onChanged,
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        Text(
          label,
          style: TextStyle(color: dark ? Colors.white70 : Colors.black87),
        ),
      ],
    );
  }



  // DEBUG panel to tune pin anchoring/sizing LIVE (works in release too).
  bool _showTuningPanel = true;

  Widget _tuningPanel() {
    if (!_showTuningPanel) {
      return Positioned(
        right: 12,
        top: 120,
        child: FloatingActionButton.small(
          onPressed: () => setState(() => _showTuningPanel = true),
          child: const Icon(Icons.tune),
        ),
      );
    }

    Widget sliderRow({
      required String label,
      required double value,
      required double min,
      required double max,
      required double step,
      required ValueChanged<double> onChanged,
    }) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '$label: ${value.toStringAsFixed(1)}',
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                ),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                onPressed: () => onChanged((value - step).clamp(min, max)),
                icon: const Icon(Icons.remove),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                onPressed: () => onChanged((value + step).clamp(min, max)),
                icon: const Icon(Icons.add),
              ),
            ],
          ),
          Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            onChanged: onChanged,
          ),
        ],
      );
    }

    if (!kShowPinTuningPanel) return const SizedBox.shrink();

    return Positioned(
      right: 12,
      top: 120,
      child: Material(
        color: Colors.transparent,
        child: Container(
          width: 280,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.72),
            borderRadius: BorderRadius.circular(14),
          ),
          child: DefaultTextStyle(
            style: const TextStyle(color: Colors.white),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'Pin tuning (release)',
                        style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
                      ),
                    ),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      onPressed: () => setState(() => _showTuningPanel = false),
                      icon: const Icon(Icons.close, color: Colors.white),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    FilterChip(
                      label: const Text('Box outline'),
                      selected: _showMarkerBoxOutline,
                      onSelected: (v) => setState(() => _showMarkerBoxOutline = v),
                      selectedColor: Colors.white24,
                      checkmarkColor: Colors.white,
                      labelStyle: const TextStyle(color: Colors.white),
                    ),
                    FilterChip(
                      label: const Text('Anchor dot'),
                      selected: _showPinDebugAnchor,
                      onSelected: (v) => setState(() => _showPinDebugAnchor = v),
                      selectedColor: Colors.white24,
                      checkmarkColor: Colors.white,
                      labelStyle: const TextStyle(color: Colors.white),
                    ),
                    FilterChip(
                      label: const Text('LatLng dot'),
                      selected: _showLatLngDebugDot,
                      onSelected: (v) => setState(() => _showLatLngDebugDot = v),
                      selectedColor: Colors.white24,
                      checkmarkColor: Colors.white,
                      labelStyle: const TextStyle(color: Colors.white),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                sliderRow(
                  label: 'Tip Y (px)',
                  value: _pinTipOffsetY,
                  min: -80,
                  max: 30,
                  step: 1,
                  onChanged: (v) => setState(() => _pinTipOffsetY = v),
                ),
                sliderRow(
                  label: 'Marker box',
                  value: _markerBox,
                  min: 28,
                  max: 80,
                  step: 1,
                  onChanged: (v) => setState(() => _markerBox = v),
                ),
                sliderRow(
                  label: 'Pin width',
                  value: _pinWidth,
                  min: 16,
                  max: 70,
                  step: 1,
                  onChanged: (v) => setState(() => _pinWidth = v),
                ),
                sliderRow(
                  label: 'Pin height',
                  value: _pinHeight,
                  min: 20,
                  max: 90,
                  step: 1,
                  onChanged: (v) => setState(() => _pinHeight = v),
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    ElevatedButton(
                      onPressed: () {
                        setState(() {
                          _markerBox = 46;
                          _pinWidth = 26;
                          _pinHeight = 38;
                          _pinTipOffsetY = -45.0;
                        });
                      },
                      child: const Text('Reset'),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Send me: box=${_markerBox.toStringAsFixed(1)}, w=${_pinWidth.toStringAsFixed(1)}, h=${_pinHeight.toStringAsFixed(1)}, tipY=${_pinTipOffsetY.toStringAsFixed(1)}',
                        style: const TextStyle(fontSize: 11, color: Colors.white70),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildResponsiveTopBar(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final shortest = size.shortestSide;
    final isCompact = shortest < 390 || size.width < 430;

    final double sidePadding = isCompact ? 10 : 14;
    final double topInset = isCompact ? 20 : 34;
    final double logoSize = isCompact ? 48 : 64;
    final double gap = isCompact ? 8 : 12;

    final buttons = Wrap(
      alignment: WrapAlignment.end,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: gap,
      runSpacing: gap,
      children: [
        _PillButton(
          icon: Icons.near_me_outlined,
          text: 'Nearest slush',
          onTap: _nearestSlush,
          compact: isCompact,
        ),
        _PillButton(
          icon: Icons.email_outlined,
          text: 'Contact Us',
          onTap: _openContactUsInApp,
          compact: isCompact,
        ),
      ],
    );

    return Positioned(
      top: topInset,
      left: sidePadding,
      right: sidePadding,
      child: SafeArea(
        bottom: false,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final stackVertically = isCompact || constraints.maxWidth < 360;

            if (stackVertically) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Image.asset(_logoAsset, width: logoSize, height: logoSize),
                  SizedBox(height: gap),
                  Align(
                    alignment: Alignment.centerRight,
                    child: buttons,
                  ),
                ],
              );
            }

            return Row(
              children: [
                Image.asset(_logoAsset, width: logoSize, height: logoSize),
                const Spacer(),
                Flexible(
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: buttons,
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bg = _darkUi ? const Color(0xFF07121A) : const Color(0xFFEAF6FF);

    final List<Marker> markers = [
      for (final loc in _locations) ...[
        // Slush pin: anchor to bottom tip and keep upright (MarkerLayer.rotate=true)
        Marker(
          point: loc.point,
          width: _hitBoxW,
          height: _hitBoxH,
          alignment: Alignment.bottomCenter,
          rotate: true,
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: () {
              final dist = _myLocation == null
                  ? 0.0
                  : const Distance().distance(_myLocation!, loc.point);
              _openLocationSheet(loc, dist);
            },
            child: SizedBox(
                width: _hitBoxW,
                height: _hitBoxH,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  if (_showMarkerBoxOutline)
                    Positioned.fill(
                      child: IgnorePointer(
                        child: Container(
                          decoration: BoxDecoration(
                            border: Border.all(color: Colors.purpleAccent, width: 1),
                          ),
                        ),
                      ),
                    ),
                  Align(
                    alignment: Alignment.bottomCenter,
                    child: Transform.translate(
                      offset: Offset(0, _pinTipOffsetY),
                      child: Image.asset(
                        _pinAsset,
                        width: _pinWidth,
                        height: _pinHeight,
                        fit: BoxFit.contain,
                        alignment: Alignment.bottomCenter,
                      ),
                    ),
                  ),
                  if (_showPinDebugAnchor)
                    Positioned(
                      left: (_markerBox / 2) - 2,
                      bottom: -2,
                      child: Container(
                        width: 4,
                        height: 4,
                        decoration: const BoxDecoration(
                          color: Colors.red,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),

        // Debug: independent LatLng marker (truth dot) on the same point
        if (_showLatLngDebugDot)
          Marker(
            point: loc.point,
            width: 10,
            height: 10,
          alignment: Alignment.center,
            rotate: false,
            child: Container(
              width: 10,
              height: 10,
              decoration: const BoxDecoration(
                color: Colors.green,
                shape: BoxShape.circle,
              ),
            ),
          ),
      ],
      if (_myLocation != null)
        Marker(
          point: _myLocation!,
          width: 18,
          height: 18,
          alignment: Alignment.center,
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
      backgroundColor: bg,
      body: Stack(
        children: [
          FlutterMap(
            key: _mapKey,
            mapController: _mapController,
            options: MapOptions(
              initialCenter: _startCenter,
              initialZoom: _startZoom,
              minZoom: _minZoom,
              maxZoom: _maxZoom,
              interactionOptions: const InteractionOptions(
                flags: InteractiveFlag.all, // keep rotation + pinch
              ),
            ),
            children: [
              TileLayer(
                urlTemplate: _tileUrl,
                userAgentPackageName: 'no.slushi.app',
                tileProvider: _tileProvider,

                // IMPORTANT: must be mutable (flutter_map writes into it)
                additionalOptions: <String, String>{},

                // Reduce blanking while zooming
                keepBuffer: 8,
                panBuffer: 2,
                tileDisplay: const TileDisplay.fadeIn(
                  duration: Duration(milliseconds: 150),
                ),
                tileUpdateTransformer: TileUpdateTransformers.ignoreTapEvents,
              ),
              MarkerLayer(markers: markers, rotate: true),
            ],
          ),

          _buildResponsiveTopBar(context),

          // OPENSTREETMAP ATTRIBUTION
          Positioned(
            left: 14,
            bottom: 74,
            child: GestureDetector(
              onTap: _openOsmCopyright,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: const Color(0xCCFFFFFF),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: const Text(
                  '© OpenStreetMap contributors',
                  style: TextStyle(fontSize: 11),
                ),
              ),
            ),
          ),
          // PRIVACY
          Positioned(
            left: 14,
            bottom: 18,
            child: _PillButton(
              icon: Icons.privacy_tip_outlined,
              text: 'Privacy Policy',
              onTap: _openPrivacyInApp,
            ),
          ),
          // MY LOCATION
          Positioned(
            right: 14,
            bottom: 18,
            child: _PillIconButton(
              icon: _loadingMyLocation
                  ? Icons.hourglass_empty
                  : Icons.my_location,
              onTap: () =>
                  _getMyLocation(auto: false, showErrors: true).then((loc) {
                    if (loc != null) _safeMove(loc, 14.5);
                  }),
            ),
          ),

          if (_loadingLocations)
            const Positioned(
              top: 110,
              left: 0,
              right: 0,
              child: Center(child: CircularProgressIndicator()),
            ),

          if (_locationsError != null && !_loadingLocations)
            Positioned(
              top: 110,
              left: 0,
              right: 0,
              child: Center(
                child: Text(
                  _locationsError!,
                  style: const TextStyle(color: Colors.red),
                ),
              ),
            ),
          _tuningPanel(),
        ],
      ),
    );
  }
}

class _PillButton extends StatelessWidget {
  final IconData icon;
  final String text;
  final VoidCallback onTap;
  final bool compact;

  const _PillButton({
    required this.icon,
    required this.text,
    required this.onTap,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(22),
      onTap: onTap,
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 12 : 14,
          vertical: compact ? 9 : 10,
        ),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.92),
          borderRadius: BorderRadius.circular(22),
          boxShadow: [
            BoxShadow(
              blurRadius: 12,
              color: Colors.black.withOpacity(0.10),
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: compact ? 17 : 18, color: Colors.black87),
            SizedBox(width: compact ? 6 : 8),
            Text(
              text,
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: Colors.black87,
                fontSize: compact ? 13 : 14,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PillIconButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;

  const _PillIconButton({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(22),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.92),
          borderRadius: BorderRadius.circular(22),
          boxShadow: [
            BoxShadow(
              blurRadius: 12,
              color: Colors.black.withOpacity(0.10),
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Icon(icon, size: 20, color: Colors.black87),
      ),
    );
  }
}

class LocationSheet extends StatelessWidget {
  final SlushLocation location;
  final double distanceMeters;
  final VoidCallback onDirections;

  const LocationSheet({
    super.key,
    required this.location,
    required this.distanceMeters,
    required this.onDirections,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Container(
        margin: const EdgeInsets.all(12),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(18),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              location.name,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 6),
            Text(
              location.address,
              style: const TextStyle(fontSize: 14, color: Colors.black54),
            ),
            if (location.notes != null &&
                location.notes!.trim().isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(location.notes!, style: const TextStyle(fontSize: 14)),
            ],
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: onDirections,
                    icon: const Icon(Icons.directions),
                    label: const Text('Directions'),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
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
