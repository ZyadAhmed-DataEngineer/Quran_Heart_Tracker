// ══════════════════════════════════════════════════════════════════════════════
//  Quran Heart Tracker — Enterprise Flutter Desktop v3
//
//  Performance architecture:
//    • Segmentation runs ONCE in an isolate at startup → complete region map
//    • Hover: synchronous O(1) lookup + O(region_size) Float32List point draw
//      → zero isolate overhead, zero async, zero BFS during any user interaction
//    • Click: synchronous pixel write + ONE ui.Image conversion (the only async step)
//    • InteractiveViewer: smooth scroll-wheel & trackpad zoom toward cursor
//    • RepaintBoundary isolates base vs hover repaints
// ══════════════════════════════════════════════════════════════════════════════

import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:audioplayers/audioplayers.dart';

// ─────────────────────────────────────────────────────────────────────────────
//  Colours & constants
// ─────────────────────────────────────────────────────────────────────────────

const int _kFillR = 99,  _kFillG = 190, _kFillB = 255; // #63BEFF – filled
const int _kHovR  = 115, _kHovG  = 196, _kHovB  = 255; // #73C4FF – hover
const int _kHovA  = 115;                                 // hover alpha 0–255
const int _kThr   = 22;                                  // BFS colour tolerance
const int _kMinPx = 50;                                  // min pixels for a valid region
const int _kTotal = 114;                                 // total surahs
const double _kSidebarW = 340;

// ─────────────────────────────────────────────────────────────────────────────
//  Entry point
// ─────────────────────────────────────────────────────────────────────────────

void main() => runApp(const QuranTrackerApp());

class QuranTrackerApp extends StatelessWidget {
  const QuranTrackerApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'متتبع حفظ القرآن الكريم',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      fontFamily: 'Tahoma',
      scaffoldBackgroundColor: const Color(0xFF0F4C81),
      useMaterial3: true,
    ),
    builder: (ctx, child) =>
        Directionality(textDirection: TextDirection.rtl, child: child!),
    home: const TrackerHome(),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
//  Isolate parameter / result types
//  (flat typed arrays — serialise & transfer efficiently through compute())
// ─────────────────────────────────────────────────────────────────────────────

class _SegParams {
  final Uint8List pixels;
  final int width, height;
  const _SegParams(this.pixels, this.width, this.height);
}

class _SegResult {
  /// bgMask[i] == 1  ⟺  pixel i is outer background
  final Uint8List bgMask;

  /// regionMap[pixelIdx] = region index k (≥ 0)  or  < 0 (invalid)
  final Int32List regionMap;

  /// All region pixel-indices concatenated into one array
  final Int32List regionData;

  /// regionOffsets[k] = start index of region k in regionData
  final Int32List regionOffsets;

  /// regionSizes[k] = pixel count of region k
  final Int32List regionSizes;

  const _SegResult(
      this.bgMask, this.regionMap, this.regionData, this.regionOffsets, this.regionSizes);
}

// ─────────────────────────────────────────────────────────────────────────────
//  Top-level isolate function  — runs ONCE at startup
// ─────────────────────────────────────────────────────────────────────────────

_SegResult _segmentIsolate(_SegParams p) {
  final W = p.width, H = p.height, N = W * H;
  final px = p.pixels;

  // ── Step 1: background mask — BFS from the four corners ─────────────────
  final bgMask = Uint8List(N);
  {
    final vis = Uint8List(N);
    final q   = Int32List(N);
    int head = 0, tail = 0;

    void enq(int i) {
      if (vis[i] == 0) { vis[i] = 1; q[tail++] = i; }
    }
    enq(0); enq(W - 1); enq((H - 1) * W); enq((H - 1) * W + W - 1);

    while (head < tail) {
      final i  = q[head++];
      bgMask[i] = 1;
      final cy = i ~/ W, cx = i % W;
      final bi = i * 4;
      final pr = px[bi], pg = px[bi + 1], pb = px[bi + 2];

      void tryBg(int ni) {
        if (vis[ni] == 1) return;
        vis[ni] = 1;
        final nbi = ni * 4;
        if (px[nbi] < 50 && px[nbi + 1] < 50 && px[nbi + 2] < 50) return;
        if ((px[nbi] - pr).abs() <= 30 &&
            (px[nbi + 1] - pg).abs() <= 30 &&
            (px[nbi + 2] - pb).abs() <= 30) q[tail++] = ni;
      }
      if (cx > 0)     tryBg(i - 1);
      if (cx < W - 1) tryBg(i + 1);
      if (cy > 0)     tryBg(i - W);
      if (cy < H - 1) tryBg(i + W);
    }
  }

  // ── Step 2: region segmentation — BFS per unvisited valid pixel ──────────
  // NOTE: We do NOT pre-reject bgMask pixels here. If we mark them -3 early,
  // heart sections that touch the image boundary get split or lost. Instead we
  // segment everything freely, then post-hoc discard the outer-background region
  // by finding whichever region owns the corner pixels.
  final regionMap  = Int32List(N)..fillRange(0, N, -1);
  final q2         = Int32List(N);
  final tempPx     = <int>[];
  final allRegions = <Int32List>[];

  for (int seed = 0; seed < N; seed++) {
    if (regionMap[seed] != -1) continue;

    final sbi = seed * 4;
    final sr = px[sbi], sg = px[sbi + 1], sb = px[sbi + 2];

    // Black outline → mark and skip
    if (sr < 50 && sg < 50 && sb < 50) { regionMap[seed] = -2; continue; }

    // BFS — no bgMask check here; background will form its own region
    final rid = allRegions.length;
    int head = 0, tail = 0;
    q2[tail++] = seed;
    regionMap[seed] = rid;
    tempPx.clear();

    while (head < tail) {
      final i  = q2[head++];
      tempPx.add(i);
      final cy = i ~/ W, cx = i % W;

      void tryReg(int ni) {
        if (regionMap[ni] != -1) return;
        final nbi = ni * 4;
        final nr = px[nbi], ng = px[nbi + 1], nb = px[nbi + 2];
        if (nr < 50 && ng < 50 && nb < 50) { regionMap[ni] = -2; return; }
        if ((nr - sr).abs() <= _kThr &&
            (ng - sg).abs() <= _kThr &&
            (nb - sb).abs() <= _kThr) {
          regionMap[ni] = rid;
          q2[tail++] = ni;
        }
      }
      if (cx > 0)     tryReg(i - 1);
      if (cx < W - 1) tryReg(i + 1);
      if (cy > 0)     tryReg(i - W);
      if (cy < H - 1) tryReg(i + W);
    }

    if (tempPx.length < _kMinPx) {
      for (final p in tempPx) regionMap[p] = -4; // discard noise
    } else {
      allRegions.add(Int32List.fromList(tempPx));
    }
  }

  // ── Post-hoc: identify outer background region(s) via corner pixels ───────
  // Any region that contains a corner pixel IS the outer background. Mark all
  // its pixels as -3 (non-interactive) so they cannot be hovered or clicked.
  final bgRegionIds = <int>{};
  for (final cornerIdx in [0, W - 1, (H - 1) * W, (H - 1) * W + W - 1]) {
    final r = regionMap[cornerIdx];
    if (r >= 0) bgRegionIds.add(r);
  }
  if (bgRegionIds.isNotEmpty) {
    for (int i = 0; i < N; i++) {
      if (bgRegionIds.contains(regionMap[i])) regionMap[i] = -3;
    }
    // Remove these regions from allRegions (replace with empty sentinel so indices stay valid)
    for (final r in bgRegionIds) {
      if (r < allRegions.length) allRegions[r] = Int32List(0);
    }
  }

  // ── Step 3: pack valid regions into flat arrays ───────────────────────────
  // Filter out empty sentinel entries left by bgRegion removal
  final validRegions = allRegions.where((r) => r.isNotEmpty).toList();
  final nReg    = validRegions.length;
  final offsets = Int32List(nReg + 1);
  final sizes   = Int32List(nReg);
  int total = 0;
  for (int k = 0; k < nReg; k++) {
    offsets[k] = total;
    sizes[k]   = validRegions[k].length;
    total      += validRegions[k].length;
  }
  offsets[nReg] = total;

  final data = Int32List(total);
  int pos = 0;
  for (int k = 0; k < nReg; k++) {
    data.setRange(pos, pos + validRegions[k].length, validRegions[k]);
    pos += validRegions[k].length;
  }

  // Remap regionMap entries to the new compact indices
  // Build a mapping: old allRegions index → new validRegions index (or -3 if removed)
  final remap = Int32List(allRegions.length)..fillRange(0, allRegions.length, -3);
  int newIdx = 0;
  for (int k = 0; k < allRegions.length; k++) {
    if (allRegions[k].isNotEmpty) remap[k] = newIdx++;
  }
  for (int i = 0; i < N; i++) {
    final r = regionMap[i];
    if (r >= 0 && r < allRegions.length) regionMap[i] = remap[r];
  }

  return _SegResult(bgMask, regionMap, data, offsets, sizes);
}

// ─────────────────────────────────────────────────────────────────────────────
//  Per-region runtime state (main thread only)
// ─────────────────────────────────────────────────────────────────────────────

class _Region {
  bool colored;
  _Region({this.colored = false});
}

// ─────────────────────────────────────────────────────────────────────────────
//  Home screen
// ─────────────────────────────────────────────────────────────────────────────

class TrackerHome extends StatefulWidget {
  const TrackerHome({super.key});
  @override
  State<TrackerHome> createState() => _TrackerHomeState();
}

class _TrackerHomeState extends State<TrackerHome> {

  // ── Image / segmentation ──────────────────────────────────────────────────
  _SegResult?   _seg;
  List<_Region> _regions = [];
  Uint8List?    _origPx;    // pristine RGBA bytes — never modified
  Uint8List?    _dispPx;    // display RGBA bytes — fills applied here
  int           _imgW = 0, _imgH = 0;
  ui.Image?     _uiBase;    // painted from _dispPx

  // ── Hover — fully synchronous, zero async ─────────────────────────────────
  int          _hoverIdx = -1;
  Float32List? _hoverPts;
  List<Float32List?> _ptCache = []; // cached per region → re-hover is O(1)

  // ── UI state ──────────────────────────────────────────────────────────────
  bool _loading  = true;
  bool _clicking = false;
  int  _colored  = 0;
  int  _streak   = 1;

  // ── Zoom / pan ────────────────────────────────────────────────────────────
  final TransformationController _tx = TransformationController();
  bool _txReady = false;

  // ── Click vs drag ─────────────────────────────────────────────────────────
  Offset? _dnPos;
  static const double _kDragThresh = 8.0;

  // ── Audio ─────────────────────────────────────────────────────────────────
  final AudioPlayer _audio = AudioPlayer();

  // ════════════════════════════════════════════════════════════════════════════
  //  Lifecycle
  // ════════════════════════════════════════════════════════════════════════════

  @override
  void initState() {
    super.initState();
    _boot();
  }

  @override
  void dispose() {
    _tx.dispose();
    _audio.dispose();
    super.dispose();
  }

  // ════════════════════════════════════════════════════════════════════════════
  //  Boot
  // ════════════════════════════════════════════════════════════════════════════

  Future<void> _boot() async {
    await _loadStreak();
    await _loadImage();
  }

  Future<void> _loadStreak() async {
    final prefs = await SharedPreferences.getInstance();
    int s = prefs.getInt('streak') ?? 1;
    final last  = prefs.getString('last_login');
    final today = DateTime.now();
    if (last != null) {
      final diff = today.difference(DateTime.parse(last)).inDays;
      if (diff == 1)     s++;
      else if (diff > 1) s = 1;
    }
    await prefs.setInt('streak', s);
    await prefs.setString('last_login', today.toIso8601String());
    if (mounted) setState(() => _streak = s);
  }

  // ── Image decode + one-time segmentation ─────────────────────────────────

  Future<void> _loadImage() async {
    if (mounted) setState(() { _loading = true; _hoverIdx = -1; _hoverPts = null; });
    try {
      final data    = await rootBundle.load('assets/Heart_Image.jpg');
      final decoded = img.decodeImage(data.buffer.asUint8List())!;
      _imgW = decoded.width;
      _imgH = decoded.height;

      final raw = decoded.getBytes(order: img.ChannelOrder.rgba);
      _origPx = Uint8List.fromList(raw);
      _dispPx = Uint8List.fromList(raw);

      // Full segmentation — runs once, in isolate, never again
      _seg     = await compute(_segmentIsolate, _SegParams(_origPx!, _imgW, _imgH));
      final n  = _seg!.regionSizes.length;
      _regions = List.generate(n, (_) => _Region());
      _ptCache = List<Float32List?>.filled(n, null);

      await _restoreProgress();
      _uiBase  = await _toUiImage(_dispPx!, _imgW, _imgH);
      _colored = _regions.where((r) => r.colored).length;
      _txReady = false;
    } catch (e) {
      debugPrint('Load error: $e');
    }
    if (mounted) {
      setState(() => _loading = false);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_txReady) _initTransform();
      });
    }
  }

  Future<ui.Image> _toUiImage(Uint8List pixels, int w, int h) async {
    final buf   = await ui.ImmutableBuffer.fromUint8List(pixels);
    final desc  = ui.ImageDescriptor.raw(buf,
        width: w, height: h, pixelFormat: ui.PixelFormat.rgba8888);
    final codec = await desc.instantiateCodec();
    final frame = await codec.getNextFrame();
    return frame.image;
  }

  void _initTransform() {
    if (_imgW == 0 || !mounted) return;
    final size   = MediaQuery.of(context).size;
    final availW = size.width  - _kSidebarW - 32;
    final availH = size.height - 32;
    final scale  = min(availW / _imgW, availH / _imgH) * 0.90;
    final tx     = (availW - _imgW * scale) / 2;
    final ty     = (availH - _imgH * scale) / 2;
    _tx.value = Matrix4.identity()
      ..scale(scale)
      ..translate(tx / scale, ty / scale);
    _txReady = true;
  }

  // ════════════════════════════════════════════════════════════════════════════
  //  Coordinate mapping
  // ════════════════════════════════════════════════════════════════════════════

  (int, int)? _toImgCoords(Offset local) {
    if (_imgW == 0) return null;
    final inv    = Matrix4.inverted(_tx.value);
    final imgPos = MatrixUtils.transformPoint(inv, local);
    return (
    imgPos.dx.toInt().clamp(0, _imgW - 1),
    imgPos.dy.toInt().clamp(0, _imgH - 1),
    );
  }

  // ════════════════════════════════════════════════════════════════════════════
  //  Hover — SYNCHRONOUS, zero isolate, zero async
  // ════════════════════════════════════════════════════════════════════════════

  void _handleHover(Offset local) {
    if (_seg == null || _clicking) return;
    final coords = _toImgCoords(local);
    if (coords == null) return;
    final (px, py) = coords;

    final rid = _seg!.regionMap[py * _imgW + px];
    final regionIdx = (rid >= 0 && rid < _regions.length) ? rid : -1;
    if (regionIdx == _hoverIdx) return; // same region — nothing to do

    _hoverIdx = regionIdx;
    if (regionIdx >= 0) {
      // Build (or retrieve cached) Float32List of pixel-centre points
      _ptCache[regionIdx] ??= _buildPoints(regionIdx);
      _hoverPts = _ptCache[regionIdx];
    } else {
      _hoverPts = null;
    }
    setState(() {}); // only invalidates the hover RepaintBoundary
  }

  void _clearHover() {
    if (_hoverIdx == -1 && _hoverPts == null) return;
    _hoverIdx = -1;
    _hoverPts = null;
    setState(() {});
  }

  /// Convert a region's pixel index list → Float32List of (x+0.5, y+0.5) pairs.
  /// canvas.drawRawPoints(PointMode.points, …) batches all points into ONE GPU call.
  Float32List _buildPoints(int rid) {
    final off  = _seg!.regionOffsets[rid];
    final size = _seg!.regionSizes[rid];
    final pts  = Float32List(size * 2);
    for (int i = 0; i < size; i++) {
      final pixIdx   = _seg!.regionData[off + i];
      pts[i * 2]     = (pixIdx % _imgW) + 0.5;
      pts[i * 2 + 1] = (pixIdx ~/ _imgW) + 0.5;
    }
    return pts;
  }

  // ════════════════════════════════════════════════════════════════════════════
  //  Click — synchronous pixel write + one ui.Image conversion
  // ════════════════════════════════════════════════════════════════════════════

  Future<void> _handleTap(Offset local) async {
    if (_seg == null || _clicking || _loading) return;
    final coords = _toImgCoords(local);
    if (coords == null) return;
    final (px, py) = coords;

    final rid = _seg!.regionMap[py * _imgW + px];
    if (rid < 0 || rid >= _regions.length) return;

    final region    = _regions[rid];
    final willColor = !region.colored;
    region.colored  = willColor;

    // Synchronous pixel write — O(region_size), no allocations
    final off  = _seg!.regionOffsets[rid];
    final size = _seg!.regionSizes[rid];
    for (int i = 0; i < size; i++) {
      final bi = _seg!.regionData[off + i] * 4;
      if (willColor) {
        _dispPx![bi]     = _kFillR;
        _dispPx![bi + 1] = _kFillG;
        _dispPx![bi + 2] = _kFillB;
        _dispPx![bi + 3] = 255;
      } else {
        _dispPx![bi]     = _origPx![bi];
        _dispPx![bi + 1] = _origPx![bi + 1];
        _dispPx![bi + 2] = _origPx![bi + 2];
        _dispPx![bi + 3] = _origPx![bi + 3];
      }
    }
    _colored = _regions.where((r) => r.colored).length;
    if (willColor) _audio.play(AssetSource('check.wav')).catchError((_) {});

    if (mounted) setState(() => _clicking = true);

    // Single async step: bytes → GPU texture
    final next = await _toUiImage(_dispPx!, _imgW, _imgH);
    await _saveProgress();

    if (mounted) setState(() { _uiBase = next; _clicking = false; });
  }

  // ════════════════════════════════════════════════════════════════════════════
  //  Persistence
  // ════════════════════════════════════════════════════════════════════════════

  Future<void> _saveProgress() async {
    final prefs   = await SharedPreferences.getInstance();
    final indices = <int>[];
    for (int i = 0; i < _regions.length; i++) {
      if (_regions[i].colored) indices.add(i);
    }
    await prefs.setString('colored_v3', indices.join(','));
  }

  Future<void> _restoreProgress() async {
    final prefs = await SharedPreferences.getInstance();
    final raw   = prefs.getString('colored_v3');
    if (raw == null || raw.isEmpty) return;
    for (final part in raw.split(',')) {
      final idx = int.tryParse(part);
      if (idx == null || idx < 0 || idx >= _regions.length) continue;
      _regions[idx].colored = true;
      final off  = _seg!.regionOffsets[idx];
      final size = _seg!.regionSizes[idx];
      for (int i = 0; i < size; i++) {
        final bi = _seg!.regionData[off + i] * 4;
        _dispPx![bi]     = _kFillR;
        _dispPx![bi + 1] = _kFillG;
        _dispPx![bi + 2] = _kFillB;
        _dispPx![bi + 3] = 255;
      }
    }
  }

  // ════════════════════════════════════════════════════════════════════════════
  //  Reset — fast: restore pixels from origPx, clear prefs, no re-segmentation
  // ════════════════════════════════════════════════════════════════════════════

  void _confirmReset() {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF0A3A5F),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
        title: const Text('تأكيد إعادة التعيين',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 18)),
        content: const Text(
            'هل تريد مسح كل التقدم؟\nلا يمكن التراجع عن هذا الإجراء.',
            style: TextStyle(color: Colors.white70, fontSize: 14, height: 1.7)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('إلغاء',
                style: TextStyle(color: Color(0xFFFFD700), fontSize: 15)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF8B1A1A),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            onPressed: () { Navigator.pop(context); _doReset(); },
            child: const Text('مسح',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  Future<void> _doReset() async {
    if (_seg == null || _origPx == null || _dispPx == null) return;
    if (mounted) setState(() { _clicking = true; _hoverIdx = -1; _hoverPts = null; });

    // 1. Clear saved prefs immediately
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('colored_v3');

    // 2. Reset all region states
    for (final r in _regions) r.colored = false;
    _colored = 0;

    // 3. Restore display pixels from pristine original — synchronous O(W*H)
    _dispPx!.setRange(0, _dispPx!.length, _origPx!);

    // 4. Clear hover point cache (colors changed)
    for (int i = 0; i < _ptCache.length; i++) _ptCache[i] = null;

    // 5. Convert to ui.Image — the only async step
    final next = await _toUiImage(_dispPx!, _imgW, _imgH);
    if (mounted) setState(() { _uiBase = next; _clicking = false; });
  }

  // ════════════════════════════════════════════════════════════════════════════
  //  Helpers
  // ════════════════════════════════════════════════════════════════════════════

  String _ar(int n) => n.toString().replaceAllMapped(
      RegExp(r'\d'), (m) => '٠١٢٣٤٥٦٧٨٩'[int.parse(m.group(0)!)]);

  String get _streakStr {
    if (_streak == 1)  return 'يوم واحد';
    if (_streak == 2)  return 'يومان';
    if (_streak <= 10) return 'أيام ${_ar(_streak)}';
    return 'يوماً ${_ar(_streak)}';
  }

  String get _motivation {
    final pct = _colored / _kTotal * 100;
    if (pct == 0)  return 'بسم الله نبدأ.\nالخطوة الأولى هي الأهم.';
    if (pct < 25)  return 'بداية موفقة.\nاستمر على بركة الله.';
    if (pct < 50)  return 'أداء ثابت.\nقليل دائم خير من كثير منقطع.';
    if (pct < 75)  return 'تجاوزت النصف.\nهمة عالية وعمل متقبل بإذن الله.';
    if (pct < 100) return 'أوشكت على الختام.\nثبتك الله وأعانك.';
    return 'الحمد لله الذي بنعمته تتم الصالحات.\nتقبل الله سعيك.';
  }

  // ════════════════════════════════════════════════════════════════════════════
  //  Build
  // ════════════════════════════════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F4C81),
      body: Row(
        // RTL layout: first child → right (sidebar), second → left (canvas)
        children: [
          _buildSidebar(),
          Expanded(child: _buildMainArea()),
        ],
      ),
    );
  }

  // ── Sidebar ──────────────────────────────────────────────────────────────

  Widget _buildSidebar() {
    final pct = _kTotal > 0 ? _colored / _kTotal : 0.0;
    return Container(
      width: _kSidebarW,
      decoration: const BoxDecoration(
        color: Color(0xFF0A3A5F),
        boxShadow: [
          BoxShadow(color: Color(0x55000000), blurRadius: 20, offset: Offset(4, 0)),
        ],
      ),
      padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Title
          const Text(
            'الورد والتقدم',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white, fontSize: 25,
                fontWeight: FontWeight.bold, letterSpacing: 0.4),
          ),
          const SizedBox(height: 26),

          // Card: surahs completed
          _StatCard(
            title: 'السور المنجزة',
            value: '${_ar(_kTotal)} / ${_ar(_colored)}',
            subtitle: 'تتبع مرئي للتقدم',
            valueColor: Colors.white,
            icon: Icons.favorite_rounded,
            iconColor: const Color(0xFFFF6B6B),
          ),
          const SizedBox(height: 18),

          // Card: streak
          _StatCard(
            title: 'سلسلة المواظبة',
            value: _streakStr,
            subtitle: 'أحب الأعمال أدومها',
            valueColor: const Color(0xFF00E5FF),
            icon: Icons.local_fire_department_rounded,
            iconColor: const Color(0xFFFF9800),
          ),
          const SizedBox(height: 20),

          // Motivation
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 18),
            decoration: BoxDecoration(
              color: const Color(0xFF16426B).withOpacity(0.55),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.white.withOpacity(0.07)),
            ),
            child: Text(
              _motivation,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white, fontSize: 14, height: 1.8),
            ),
          ),

          const Spacer(),

          // Processing indicator
          if (_clicking)
            const Padding(
              padding: EdgeInsets.only(bottom: 10),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox(width: 13, height: 13,
                      child: CircularProgressIndicator(
                          color: Color(0xFF63BEFF), strokeWidth: 2)),
                  SizedBox(width: 8),
                  Text('جاري الحفظ...',
                      style: TextStyle(color: Colors.white54, fontSize: 11)),
                ],
              ),
            ),

          // Reset button
          SizedBox(
            height: 58,
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF8B1A1A),
                foregroundColor: Colors.white,
                elevation: 4,
                shadowColor: const Color(0xFF8B1A1A),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16)),
              ),
              icon: const Icon(Icons.refresh_rounded, size: 24),
              label: const Text('إعادة تعيين التقدم',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              onPressed: (_loading || _clicking) ? null : _confirmReset,
            ),
          ),
        ],
      ),
    );
  }

  // ── Main canvas area — white rounded card ─────────────────────────────────

  Widget _buildMainArea() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Material(
        elevation: 12,
        shadowColor: Colors.black54,
        borderRadius: BorderRadius.circular(22),
        clipBehavior: Clip.antiAlias,
        color: Colors.white,
        child: _loading || _uiBase == null
            ? const Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              CircularProgressIndicator(
                  color: Color(0xFF63BEFF), strokeWidth: 3),
              SizedBox(height: 20),
              Text('جاري تحميل وتحليل الصورة...',
                  style: TextStyle(color: Color(0xFF0A3A5F), fontSize: 14)),
            ],
          ),
        )
            : _buildInteractiveCanvas(),
      ),
    );
  }

  Widget _buildInteractiveCanvas() {
    return Listener(
      onPointerDown: (e) => _dnPos = e.localPosition,
      onPointerUp:   (e) {
        if (_dnPos == null) return;
        if ((e.localPosition - _dnPos!).distance < _kDragThresh) {
          _handleTap(e.localPosition);
        }
        _dnPos = null;
      },
      child: MouseRegion(
        cursor: _clicking ? SystemMouseCursors.wait : SystemMouseCursors.click,
        onHover: (e) => _handleHover(e.localPosition),
        onExit:  (_)  => _clearHover(),
        child: InteractiveViewer(
          transformationController: _tx,
          minScale: 0.05,
          maxScale: 30.0,
          constrained: false,
          boundaryMargin: const EdgeInsets.all(double.infinity),
          child: SizedBox(
            width:  _imgW.toDouble(),
            height: _imgH.toDouble(),
            child: Stack(
              fit: StackFit.expand,
              children: [
                // Base image — only repaints when _uiBase changes (on click)
                RepaintBoundary(
                  child: CustomPaint(painter: _BasePainter(_uiBase!)),
                ),
                // Hover overlay — repaints only when _hoverPts changes (on hover)
                if (_hoverPts != null)
                  RepaintBoundary(
                    child: CustomPaint(painter: _HoverPainter(_hoverPts)),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  CustomPainters
// ─────────────────────────────────────────────────────────────────────────────

/// Paints the full base RGBA image at native resolution.
class _BasePainter extends CustomPainter {
  final ui.Image image;
  const _BasePainter(this.image);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      Rect.fromLTWH(0, 0, size.width, size.height),
      Paint()..filterQuality = FilterQuality.high,
    );
  }

  @override
  bool shouldRepaint(covariant _BasePainter old) => old.image != image;
}

/// Paints the hovered region as coloured square points.
/// canvas.drawRawPoints(PointMode.points, …) = single GPU call — no ui.Image.
class _HoverPainter extends CustomPainter {
  final Float32List? points;
  const _HoverPainter(this.points);

  static final Paint _p = Paint()
    ..color       = Color.fromARGB(_kHovA, _kHovR, _kHovG, _kHovB)
    ..strokeWidth  = 1.0
    ..strokeCap    = StrokeCap.square
    ..isAntiAlias  = false;

  @override
  void paint(Canvas canvas, Size size) {
    if (points == null || points!.isEmpty) return;
    canvas.drawRawPoints(ui.PointMode.points, points!, _p);
  }

  @override
  bool shouldRepaint(covariant _HoverPainter old) => old.points != points;
}

// ─────────────────────────────────────────────────────────────────────────────
//  Stat card
// ─────────────────────────────────────────────────────────────────────────────

class _StatCard extends StatelessWidget {
  final String   title, value, subtitle;
  final Color    valueColor;
  final IconData icon;
  final Color    iconColor;

  const _StatCard({
    required this.title,
    required this.value,
    required this.subtitle,
    required this.valueColor,
    required this.icon,
    required this.iconColor,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 22, horizontal: 18),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end:   Alignment.bottomRight,
          colors: [Color(0xFF1E5490), Color(0xFF16426B)],
        ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withOpacity(0.07)),
        boxShadow: [
          BoxShadow(color: Colors.black.withOpacity(0.40),
              blurRadius: 12, offset: const Offset(2, 6)),
        ],
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: iconColor, size: 18),
              const SizedBox(width: 7),
              Text(title,
                  style: const TextStyle(
                      color: Color(0xFFFFD700), fontSize: 16,
                      fontWeight: FontWeight.bold)),
            ],
          ),
          const SizedBox(height: 12),
          Text(value,
              textAlign: TextAlign.center,
              style: TextStyle(color: valueColor, fontSize: 36,
                  fontWeight: FontWeight.bold, height: 1.15)),
          const SizedBox(height: 9),
          Text(subtitle,
              style: const TextStyle(color: Color(0xFFB0C4DE), fontSize: 13)),
        ],
      ),
    );
  }
}