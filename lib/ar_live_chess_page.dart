import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:stockfish/stockfish.dart';
import 'package:chess/chess.dart' as chess_lib;
import 'ar_board_tracker.dart';
import 'ar_painter.dart';
import 'sound_service.dart';

/// Fullscreen Live Augmented Reality Chess Assistant.
/// Continuously tracks the 4 corners of a physical chessboard via camera,
/// monitors the game, and projects the best Stockfish counter-moves in 3D AR directly
/// over the real board.
class ARLiveChessPage extends StatefulWidget {
  final bool initialPlayAsWhite;

  const ARLiveChessPage({
    super.key,
    this.initialPlayAsWhite = true,
  });

  @override
  State<ARLiveChessPage> createState() => _ARLiveChessPageState();
}

class _ARLiveChessPageState extends State<ARLiveChessPage>
    with SingleTickerProviderStateMixin {
  // Camera
  CameraController? _cameraController;
  List<CameraDescription> _cameras = [];
  bool _isCameraReady = false;
  String? _cameraError;

  // Board Tracking & AR
  late AutomaticBoardTracker _tracker;
  BoardCorners? _corners;
  bool _isAdjustingCorners = false;
  bool _showGrid = true;

  // Pulse animation for AR arrows and glow
  late AnimationController _pulseController;

  // Chess Engine & Game
  late chess_lib.Chess _game;
  Stockfish? _stockfish;
  bool _isEngineReady = false;
  bool _isEngineCalculating = false;
  int _searchDepth = 15;

  late bool _playAsWhite;
  String _positionScore = '+0.00';
  String? _bestMoveFrom;
  String? _bestMoveTo;
  String? _lastOpponentMoveFrom;
  String? _lastOpponentMoveTo;

  // Sound
  final SoundService _sound = SoundService();

  @override
  void initState() {
    super.initState();
    _playAsWhite = widget.initialPlayAsWhite;
    _game = chess_lib.Chess();
    _tracker = AutomaticBoardTracker();

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat(reverse: true);

    _initCamera();
    _initStockfish();
  }

  @override
  void dispose() {
    _cameraController?.dispose();
    _pulseController.dispose();
    _stockfish?.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Camera Setup
  // ---------------------------------------------------------------------------
  Future<void> _initCamera() async {
    try {
      _cameras = await availableCameras();
      if (_cameras.isEmpty) {
        setState(() => _cameraError = 'No camera found on this device');
        return;
      }

      // Select back camera
      final backCamera = _cameras.firstWhere(
        (cam) => cam.lensDirection == CameraLensDirection.back,
        orElse: () => _cameras.first,
      );

      _cameraController = CameraController(
        backCamera,
        ResolutionPreset.high,
        enableAudio: false,
      );

      await _cameraController!.initialize();

      if (!mounted) return;
      setState(() => _isCameraReady = true);

      // Start continuous real-time camera image stream (like a QR scanner)
      _cameraController!.startImageStream((CameraImage image) {
        _processCameraFrame(image);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _cameraError = 'Failed to initialize camera: $e');
    }
  }

  bool _isProcessingFrame = false;

  void _processCameraFrame(CameraImage image) {
    if (!mounted || _isProcessingFrame || _isAdjustingCorners) return;
    _isProcessingFrame = true;

    try {
      final size = MediaQuery.of(context).size;
      final detected = RealtimeChessboardDetector.detectBoard(
        image: image,
        screenSize: size,
        sensorOrientation: _cameraController!.description.sensorOrientation,
      );

      if (detected != null) {
        _tracker.updateWithDetected(detected);
      } else {
        _tracker.onFrameLost();
      }

      if (mounted) {
        setState(() {
          _corners = _tracker.currentCorners;
        });
      }
    } catch (_) {
      // Ignore frame drop
    } finally {
      _isProcessingFrame = false;
    }
  }

  // ---------------------------------------------------------------------------
  // Stockfish Setup & UCI Handlers
  // ---------------------------------------------------------------------------
  Future<void> _initStockfish() async {
    try {
      _stockfish = Stockfish();

      _stockfish!.stdout.listen((line) {
        if (!mounted) return;

        // Parse bestmove
        if (line.startsWith('bestmove')) {
          final parts = line.split(' ');
          if (parts.length > 1) {
            final moveStr = parts[1];
            if (moveStr.length >= 4) {
              setState(() {
                _bestMoveFrom = moveStr.substring(0, 2);
                _bestMoveTo = moveStr.substring(2, 4);
                _isEngineCalculating = false;
              });
            }
          }
          return;
        }

        // Parse score
        if (line.contains('info') && line.contains('score')) {
          final parts = line.split(' ');
          final cpIndex = parts.indexOf('cp');
          final mateIndex = parts.indexOf('mate');

          if (mateIndex != -1 && mateIndex + 1 < parts.length) {
            final mateIn = int.tryParse(parts[mateIndex + 1]) ?? 0;
            setState(() {
              _positionScore = '#${mateIn.abs()}';
            });
          } else if (cpIndex != -1 && cpIndex + 1 < parts.length) {
            final cp = int.tryParse(parts[cpIndex + 1]) ?? 0;
            final isWhiteTurn = _game.turn == chess_lib.Color.WHITE;
            final whiteCp = isWhiteTurn ? cp : -cp;
            final scoreStr = (whiteCp.abs() / 100.0).toStringAsFixed(2);
            setState(() {
              _positionScore = whiteCp >= 0 ? '+$scoreStr' : '-$scoreStr';
            });
          }
        }

        if (line == 'readyok') {
          setState(() => _isEngineReady = true);
          _evaluateCurrentPosition();
        }
      });

      _stockfish!.stdin = 'uci';
      _stockfish!.stdin = 'isready';
    } catch (e) {
      debugPrint('Stockfish init error: $e');
    }
  }

  void _evaluateCurrentPosition() {
    if (_stockfish == null || !_isEngineReady) return;
    setState(() => _isEngineCalculating = true);
    _stockfish!.stdin = 'position fen ${_game.fen}';
    _stockfish!.stdin = 'go depth $_searchDepth';
  }

  // ---------------------------------------------------------------------------
  // Game Actions
  // ---------------------------------------------------------------------------

  bool get _isMyTurn =>
      (_game.turn == chess_lib.Color.WHITE && _playAsWhite) ||
      (_game.turn == chess_lib.Color.BLACK && !_playAsWhite);

  /// Called when the player executes the suggested AR counter move on the physical board.
  void _confirmMyMove() {
    if (_bestMoveFrom == null || _bestMoveTo == null) return;

    final moveResult = _game.move({
      'from': _bestMoveFrom,
      'to': _bestMoveTo,
      'promotion': 'q',
    });

    if (moveResult) {
      _sound.playNormal();
      setState(() {
        _lastOpponentMoveFrom = null;
        _lastOpponentMoveTo = null;
        _bestMoveFrom = null;
        _bestMoveTo = null;
      });
      _evaluateCurrentPosition();
    }
  }

  /// Opens a quick, intuitive picker for what move the opponent made on the real board.
  void _showOpponentMoveDialog() {
    String from = '';
    String to = '';
    final controllerFrom = TextEditingController();
    final controllerTo = TextEditingController();

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return Padding(
          padding: EdgeInsets.only(
            left: 24,
            right: 24,
            top: 24,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 24,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.psychology_rounded, color: Colors.amberAccent, size: 28),
                  const SizedBox(width: 12),
                  const Text(
                    "Register Opponent's Move",
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white60),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                "Enter the square your friend moved from and to (e.g. e7 -> e5):",
                style: TextStyle(color: Colors.white.withOpacity(0.7), fontSize: 13),
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: controllerFrom,
                      autofocus: true,
                      style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                      decoration: InputDecoration(
                        labelText: 'From Square',
                        labelStyle: const TextStyle(color: Colors.white60),
                        hintText: 'e7',
                        hintStyle: TextStyle(color: Colors.white.withOpacity(0.3)),
                        filled: true,
                        fillColor: Colors.white.withOpacity(0.08),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),
                  const Icon(Icons.arrow_forward_rounded, color: Colors.amberAccent),
                  const SizedBox(width: 16),
                  Expanded(
                    child: TextField(
                      controller: controllerTo,
                      style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                      decoration: InputDecoration(
                        labelText: 'To Square',
                        labelStyle: const TextStyle(color: Colors.white60),
                        hintText: 'e5',
                        hintStyle: TextStyle(color: Colors.white.withOpacity(0.3)),
                        filled: true,
                        fillColor: Colors.white.withOpacity(0.08),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 22),
              SizedBox(
                width: double.infinity,
                height: 50,
                child: ElevatedButton.icon(
                  icon: const Icon(Icons.check_circle_rounded, color: Colors.black),
                  label: const Text(
                    "Apply & Calculate Counter Move",
                    style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold, fontSize: 15),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.amberAccent,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  ),
                  onPressed: () {
                    from = controllerFrom.text.trim().toLowerCase();
                    to = controllerTo.text.trim().toLowerCase();
                    if (from.length >= 2 && to.length >= 2) {
                      final moveSuccess = _game.move({
                        'from': from,
                        'to': to,
                        'promotion': 'q',
                      });
                      if (moveSuccess) {
                        _sound.playNormal();
                        setState(() {
                          _lastOpponentMoveFrom = from;
                          _lastOpponentMoveTo = to;
                        });
                        Navigator.pop(ctx);
                        _evaluateCurrentPosition();
                      } else {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text("Illegal chess move: $from -> $to"),
                            backgroundColor: Colors.redAccent,
                          ),
                        );
                      }
                    }
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  void _resetGame() {
    setState(() {
      _game = chess_lib.Chess();
      _bestMoveFrom = null;
      _bestMoveTo = null;
      _lastOpponentMoveFrom = null;
      _lastOpponentMoveTo = null;
      _positionScore = '+0.00';
    });
    _evaluateCurrentPosition();
  }

  void _toggleFlipSide() {
    setState(() {
      _playAsWhite = !_playAsWhite;
    });
    _evaluateCurrentPosition();
  }

  String _getPieceNameForSquare(String? square) {
    if (square == null || square.length < 2) return 'PIECE';
    try {
      final piece = _game.get(square);
      if (piece != null) {
        switch (piece.type.toString().toLowerCase()) {
          case 'p': return 'PAWN';
          case 'n': return 'KNIGHT';
          case 'b': return 'BISHOP';
          case 'r': return 'ROOK';
          case 'q': return 'QUEEN';
          case 'k': return 'KING';
        }
      }
    } catch (_) {}
    return 'PIECE';
  }

  // ---------------------------------------------------------------------------
  // Build Method
  // ---------------------------------------------------------------------------
  @override
  Widget build(BuildContext context) {
    if (_cameraError != null) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Text(
              _cameraError!,
              style: const TextStyle(color: Colors.redAccent, fontSize: 16),
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }

    if (!_isCameraReady || _cameraController == null) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(color: Color(0xFF00E676)),
              SizedBox(height: 16),
              Text(
                'Starting AR Camera Stream...',
                style: TextStyle(color: Colors.white, fontSize: 15),
              ),
            ],
          ),
        ),
      );
    }

    final size = MediaQuery.of(context).size;

    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTapUp: (details) {
          if (_isAdjustingCorners) return;
          // One-tap instant snap to center chessboard under finger
          final size = MediaQuery.of(context).size;
          final snapped = RealtimeChessboardDetector.createCenteredBoard(
            size,
            targetCenter: details.localPosition,
          );
          _tracker.setManualCorners(snapped);
          setState(() {
            _corners = snapped;
          });
        },
        child: Stack(
          fit: StackFit.expand,
          children: [
            // 1. Camera Viewfinder
            FittedBox(
              fit: BoxFit.cover,
              child: SizedBox(
                width: _cameraController!.value.previewSize?.height ?? size.width,
                height: _cameraController!.value.previewSize?.width ?? size.height,
                child: CameraPreview(_cameraController!),
              ),
            ),

          // Scanning Reticle (Shown when searching for board like QR code scanner)
          if (!_tracker.isLocked && _corners == null)
            Center(
              child: Container(
                width: size.width * 0.78,
                height: size.width * 0.78,
                decoration: BoxDecoration(
                  border: Border.all(
                    color: Colors.amberAccent.withOpacity(0.6),
                    width: 2.0,
                  ),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.qr_code_scanner_rounded,
                      size: 52,
                      color: Colors.amberAccent.withOpacity(0.9),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'Point Camera at Chessboard\nAuto-Detecting 4 Corners...',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.95),
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        shadows: [
                          Shadow(color: Colors.black.withOpacity(0.8), blurRadius: 6),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),

          // 2. AR 3D Overlay Painter
          if (_corners != null)
            AnimatedBuilder(
              animation: _pulseController,
              builder: (context, _) {
                return CustomPaint(
                  size: size,
                  painter: ARBoardPainter(
                    corners: _corners!,
                    bestMoveFrom: _bestMoveFrom,
                    bestMoveTo: _bestMoveTo,
                    pieceName: _getPieceNameForSquare(_bestMoveFrom),
                    lastOpponentMoveFrom: _lastOpponentMoveFrom,
                    lastOpponentMoveTo: _lastOpponentMoveTo,
                    whiteAtBottom: _playAsWhite,
                    pulseValue: _pulseController.value,
                    showGrid: _showGrid,
                    isTrackingLocked: _tracker.isLocked,
                  ),
                );
              },
            ),

          // 3. Manual Corner Adjustment Handles (if user enables tweak mode)
          if (_isAdjustingCorners && _corners != null)
            _buildInteractiveCornerHandles(size),

          // 4. Top Navigation & Quick HUD Bar
          _buildTopBar(),

          // 5. Bottom Game Assistant Panel
          _buildBottomPanel(),
        ],
      ),
    ),
  );
  }

  /// Builds the top bar with tracking indicator, flip side, and settings.
  Widget _buildTopBar() {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              // Back Button
              Container(
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.6),
                  shape: BoxShape.circle,
                ),
                child: IconButton(
                  icon: const Icon(Icons.arrow_back_ios_new_rounded, color: Colors.white, size: 20),
                  onPressed: () => Navigator.pop(context),
                ),
              ),
              const SizedBox(width: 12),

              // Dynamic Real-time Tracking Status Pill (QR-Scanner style)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.75),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: _tracker.isLocked
                        ? const Color(0xFF00E676)
                        : Colors.amberAccent,
                    width: 1.5,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: _tracker.isLocked
                            ? const Color(0xFF00E676)
                            : Colors.amberAccent,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      _tracker.isLocked
                          ? 'CHESSBOARD LOCKED 🎯'
                          : 'SCANNING FOR BOARD... 📷',
                      style: TextStyle(
                        color: _tracker.isLocked
                            ? const Color(0xFF00E676)
                            : Colors.amberAccent,
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.8,
                      ),
                    ),
                  ],
                ),
              ),

              const Spacer(),

              // Quick Snap to Center Button
              Container(
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.6),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: IconButton(
                  icon: const Icon(
                    Icons.filter_center_focus_rounded,
                    color: Color(0xFF00E5FF),
                    size: 21,
                  ),
                  tooltip: 'Instant Snap to View',
                  onPressed: () {
                    final size = MediaQuery.of(context).size;
                    final centered = RealtimeChessboardDetector.createCenteredBoard(size);
                    _tracker.setManualCorners(centered);
                    setState(() {
                      _corners = centered;
                    });
                  },
                ),
              ),
              const SizedBox(width: 8),

              // Reset / Re-Scan Button
              Container(
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.6),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: IconButton(
                  icon: const Icon(
                    Icons.refresh_rounded,
                    color: Colors.white70,
                    size: 21,
                  ),
                  tooltip: 'Reset and Auto-Scan',
                  onPressed: () {
                    _tracker.reset();
                    setState(() {
                      _corners = null;
                      _isAdjustingCorners = false;
                    });
                  },
                ),
              ),
              const SizedBox(width: 8),

              // Tweak Corners Button
              Container(
                decoration: BoxDecoration(
                  color: _isAdjustingCorners
                      ? const Color(0xFF00E676)
                      : Colors.black.withOpacity(0.6),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: IconButton(
                  icon: Icon(
                    _isAdjustingCorners ? Icons.check : Icons.tune_rounded,
                    color: _isAdjustingCorners ? Colors.black : Colors.white,
                    size: 20,
                  ),
                  tooltip: 'Tweak Board Corners',
                  onPressed: () {
                    setState(() {
                      _isAdjustingCorners = !_isAdjustingCorners;
                    });
                  },
                ),
              ),
              const SizedBox(width: 8),

              // Toggle Side (White/Black)
              Container(
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.6),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: IconButton(
                  icon: Icon(
                    Icons.swap_vert_rounded,
                    color: _playAsWhite ? Colors.white : Colors.amberAccent,
                    size: 22,
                  ),
                  tooltip: 'Switch White/Black Perspective',
                  onPressed: _toggleFlipSide,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Builds interactive draggable corner handles for manual touch alignment.
  Widget _buildInteractiveCornerHandles(Size size) {
    if (_corners == null) return const SizedBox.shrink();

    final cornerPoints = [
      _corners!.topLeft,
      _corners!.topRight,
      _corners!.bottomRight,
      _corners!.bottomLeft,
    ];
    final labels = ['TL', 'TR', 'BR', 'BL'];

    return Stack(
      children: List.generate(4, (index) {
        final p = cornerPoints[index];
        return Positioned(
          left: p.dx - 24,
          top: p.dy - 24,
          child: GestureDetector(
            onPanUpdate: (details) {
              final newOffset = Offset(
                (p.dx + details.delta.dx).clamp(0.0, size.width),
                (p.dy + details.delta.dy).clamp(0.0, size.height),
              );
              setState(() {
                switch (index) {
                  case 0:
                    _corners = _corners!.copyWith(topLeft: newOffset);
                    break;
                  case 1:
                    _corners = _corners!.copyWith(topRight: newOffset);
                    break;
                  case 2:
                    _corners = _corners!.copyWith(bottomRight: newOffset);
                    break;
                  case 3:
                    _corners = _corners!.copyWith(bottomLeft: newOffset);
                    break;
                }
                _tracker.setManualCorners(_corners!);
              });
            },
            child: Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: const Color(0xFF00E676).withOpacity(0.85),
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 2.5),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF00E676).withOpacity(0.5),
                    blurRadius: 10,
                    spreadRadius: 2,
                  ),
                ],
              ),
              child: Center(
                child: Text(
                  labels[index],
                  style: const TextStyle(
                    color: Colors.black,
                    fontSize: 12,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
            ),
          ),
        );
      }),
    );
  }

  /// Builds the bottom game assistant control panel.
  Widget _buildBottomPanel() {
    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        child: Container(
          margin: const EdgeInsets.all(16),
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: const Color(0xFF161616).withOpacity(0.92),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: Colors.white.withOpacity(0.12), width: 1.5),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.7),
                blurRadius: 20,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Status Bar & Evaluation Score
              Row(
                children: [
                  // Turn Indicator
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: _isMyTurn
                          ? const Color(0xFF00E676).withOpacity(0.2)
                          : Colors.amberAccent.withOpacity(0.2),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: _isMyTurn ? const Color(0xFF00E676) : Colors.amberAccent,
                        width: 1.2,
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          _isMyTurn ? Icons.play_arrow_rounded : Icons.hourglass_top_rounded,
                          size: 16,
                          color: _isMyTurn ? const Color(0xFF00E676) : Colors.amberAccent,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          _isMyTurn ? 'YOUR TURN' : "OPPONENT'S TURN",
                          style: TextStyle(
                            color: _isMyTurn ? const Color(0xFF00E676) : Colors.amberAccent,
                            fontSize: 12,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Spacer(),

                  // Eval score
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.08),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      'Eval: $_positionScore',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),

                  // Reset
                  IconButton(
                    icon: const Icon(Icons.refresh_rounded, color: Colors.white60, size: 20),
                    tooltip: 'New Game',
                    onPressed: _resetGame,
                  ),
                ],
              ),

              const SizedBox(height: 14),

              // Suggestion Message or Action
              if (_isMyTurn) ...[
                if (_bestMoveFrom != null && _bestMoveTo != null) ...[
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: const Color(0xFF00E676).withOpacity(0.2),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.near_me_rounded, color: Color(0xFF00E676), size: 22),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Best Counter-Move (See AR Arrow):',
                              style: TextStyle(color: Colors.white70, fontSize: 12),
                            ),
                            Text(
                              '${_bestMoveFrom!.toUpperCase()} ➔ ${_bestMoveTo!.toUpperCase()}',
                              style: const TextStyle(
                                color: Color(0xFF00E676),
                                fontSize: 20,
                                fontWeight: FontWeight.w900,
                                letterSpacing: 1.0,
                              ),
                            ),
                          ],
                        ),
                      ),
                      ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF00E676),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                        ),
                        onPressed: _confirmMyMove,
                        child: const Text(
                          'I Moved ✅',
                          style: TextStyle(color: Colors.black, fontWeight: FontWeight.w900),
                        ),
                      ),
                    ],
                  ),
                ] else if (_isEngineCalculating) ...[
                  const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF00E676)),
                      ),
                      SizedBox(width: 10),
                      Text(
                        'Stockfish is calculating best counter move...',
                        style: TextStyle(color: Colors.white70, fontSize: 13),
                      ),
                    ],
                  ),
                ] else ...[
                  const Text(
                    'Position ready. Waiting for engine move...',
                    style: TextStyle(color: Colors.white60, fontSize: 13),
                  ),
                ],
              ] else ...[
                // Opponent's turn
                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: ElevatedButton.icon(
                    icon: const Icon(Icons.touch_app_rounded, color: Colors.black),
                    label: const Text(
                      "Opponent Moved ♟️ (Record Move)",
                      style: TextStyle(
                        color: Colors.black,
                        fontWeight: FontWeight.w900,
                        fontSize: 14,
                      ),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.amberAccent,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    ),
                    onPressed: _showOpponentMoveDialog,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
