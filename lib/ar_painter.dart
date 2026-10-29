import 'dart:math';
import 'package:flutter/material.dart';
import 'ar_board_tracker.dart';

/// Custom Painter that renders the exact futuristic AR HUD seen in the reference screenshot:
/// - Electric Cyan Glowing Border tracking the real physical chessboard.
/// - Vibrant Lime Green perspective squares on the Source piece and Destination square.
/// - Holographic 3D Floating HUD Badge: "NEXT MOVE \n [PIECE] [from] ➔ [to]".
/// - Fine connecting anchor line linking the badge to the target square.
class ARBoardPainter extends CustomPainter {
  final BoardCorners corners;
  final String? bestMoveFrom;
  final String? bestMoveTo;
  final String? pieceName;
  final String? lastOpponentMoveFrom;
  final String? lastOpponentMoveTo;
  final bool whiteAtBottom;
  final double pulseValue; // 0.0 to 1.0 for pulsating animation
  final bool showGrid;
  final bool isTrackingLocked;

  ARBoardPainter({
    required this.corners,
    this.bestMoveFrom,
    this.bestMoveTo,
    this.pieceName,
    this.lastOpponentMoveFrom,
    this.lastOpponentMoveTo,
    this.whiteAtBottom = true,
    this.pulseValue = 0.5,
    this.showGrid = false,
    this.isTrackingLocked = true,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final mapper = PerspectiveMapper(corners);

    // 1. Draw Electric Cyan Glowing Border around the physical chessboard perimeter
    _drawCyanBoardGlow(canvas);

    // 2. Draw subtle 8x8 perspective grid if enabled
    if (showGrid) {
      _drawPerspectiveGrid(canvas, mapper);
    }

    // 3. Draw Opponent's Last Move (Soft Amber / Red indicator)
    if (lastOpponentMoveFrom != null && lastOpponentMoveTo != null) {
      _drawPerspectiveSquare(
        canvas,
        mapper,
        lastOpponentMoveFrom!,
        fillColor: Colors.amber.withOpacity(0.20 + 0.10 * pulseValue),
        borderColor: Colors.amberAccent.withOpacity(0.8),
      );
      _drawPerspectiveSquare(
        canvas,
        mapper,
        lastOpponentMoveTo!,
        fillColor: Colors.amber.withOpacity(0.35 + 0.15 * pulseValue),
        borderColor: Colors.orangeAccent,
      );
    }

    // 4. Draw Counter Best Move (Source Square & Destination Square)
    if (bestMoveFrom != null && bestMoveTo != null) {
      const Color neonGreen = Color(0xFF00FF40);

      // A) Source Square: Vibrant Glowing Green Perspective Quad on the piece
      _drawPerspectiveSquare(
        canvas,
        mapper,
        bestMoveFrom!,
        fillColor: neonGreen.withOpacity(0.35 + 0.20 * pulseValue),
        borderColor: neonGreen,
        glowColor: neonGreen,
        strokeWidth: 3.0,
      );

      // B) Destination Square: Vibrant Glowing Green Perspective Quad on target square
      _drawPerspectiveSquare(
        canvas,
        mapper,
        bestMoveTo!,
        fillColor: neonGreen.withOpacity(0.40 + 0.20 * pulseValue),
        borderColor: neonGreen,
        glowColor: neonGreen,
        strokeWidth: 3.0,
      );

      // C) Connecting AR Trajectory Line between Source and Destination
      final startPos = mapper.getSquareCenter(bestMoveFrom!, whiteAtBottom: whiteAtBottom);
      final targetPos = mapper.getSquareCenter(bestMoveTo!, whiteAtBottom: whiteAtBottom);
      _drawTrajectoryLine(canvas, startPos, targetPos);

      // D) Floating 3D Holographic Badge: "NEXT MOVE \n BISHOP f8 ➔ e7"
      _drawHolographicBadge(canvas, mapper, targetPos);
    }
  }

  /// Draws the vibrant Electric Cyan glowing border around the physical board edges.
  void _drawCyanBoardGlow(Canvas canvas) {
    const Color cyanGlow = Color(0xFF00E5FF);

    final path = Path()
      ..moveTo(corners.topLeft.dx, corners.topLeft.dy)
      ..lineTo(corners.topRight.dx, corners.topRight.dy)
      ..lineTo(corners.bottomRight.dx, corners.bottomRight.dy)
      ..lineTo(corners.bottomLeft.dx, corners.bottomLeft.dy)
      ..close();

    // Outer intense glow (multi-layer blur)
    final outerGlowPaint = Paint()
      ..color = cyanGlow.withOpacity(0.35 + 0.15 * pulseValue)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 14.0
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10.0);

    final midGlowPaint = Paint()
      ..color = cyanGlow.withOpacity(0.65)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 6.0
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4.0);

    // Inner sharp core line
    final corePaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5;

    canvas.drawPath(path, outerGlowPaint);
    canvas.drawPath(path, midGlowPaint);
    canvas.drawPath(path, corePaint);

    // Corner HUD brackets
    _drawCornerBracket(canvas, corners.topLeft, 1, 1);
    _drawCornerBracket(canvas, corners.topRight, -1, 1);
    _drawCornerBracket(canvas, corners.bottomRight, -1, -1);
    _drawCornerBracket(canvas, corners.bottomLeft, 1, -1);
  }

  void _drawCornerBracket(Canvas canvas, Offset p, double dirX, double dirY) {
    const len = 22.0;
    final bracketPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.5
      ..strokeCap = StrokeCap.round;

    canvas.drawLine(p, Offset(p.dx + dirX * len, p.dy), bracketPaint);
    canvas.drawLine(p, Offset(p.dx, p.dy + dirY * len), bracketPaint);
  }

  /// Draws a perspective-correct square mapped flat on the physical board plane.
  void _drawPerspectiveSquare(
    Canvas canvas,
    PerspectiveMapper mapper,
    String square, {
    required Color fillColor,
    required Color borderColor,
    Color? glowColor,
    double strokeWidth = 2.0,
  }) {
    final poly = mapper.getSquarePolygon(square, whiteAtBottom: whiteAtBottom);
    if (poly.length < 4) return;

    final path = Path()
      ..moveTo(poly[0].dx, poly[0].dy)
      ..lineTo(poly[1].dx, poly[1].dy)
      ..lineTo(poly[2].dx, poly[2].dy)
      ..lineTo(poly[3].dx, poly[3].dy)
      ..close();

    // Glow underlay
    if (glowColor != null) {
      final glowPaint = Paint()
        ..color = glowColor.withOpacity(0.5)
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth + 6.0
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6.0);
      canvas.drawPath(path, glowPaint);
    }

    // Fill
    final fillPaint = Paint()
      ..color = fillColor
      ..style = PaintingStyle.fill;
    canvas.drawPath(path, fillPaint);

    // Sharp stroke
    final strokePaint = Paint()
      ..color = borderColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth;
    canvas.drawPath(path, strokePaint);
  }

  /// Draws subtle glowing connecting line between From and To squares.
  void _drawTrajectoryLine(Canvas canvas, Offset start, Offset end) {
    final linePaint = Paint()
      ..color = const Color(0xFF00FF40).withOpacity(0.6)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;

    canvas.drawLine(start, end, linePaint);
  }

  /// Draws the exact floating holographic badge:
  /// NEXT MOVE
  /// BISHOP f8 ➔ e7
  void _drawHolographicBadge(
    Canvas canvas,
    PerspectiveMapper mapper,
    Offset targetCenter,
  ) {
    final String piece = pieceName?.toUpperCase() ?? 'PIECE';
    final String fromStr = bestMoveFrom!.toLowerCase();
    final String toStr = bestMoveTo!.toLowerCase();

    // Position badge floating slightly above target square
    final Offset badgeCenter = Offset(targetCenter.dx, targetCenter.dy - 44.0);

    const double badgeWidth = 145.0;
    const double badgeHeight = 44.0;
    final Rect badgeRect = Rect.fromCenter(
      center: badgeCenter,
      width: badgeWidth,
      height: badgeHeight,
    );

    // Connecting anchor pin line
    final pinPaint = Paint()
      ..color = const Color(0xFF00FF40)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    canvas.drawLine(targetCenter, Offset(badgeCenter.dx, badgeCenter.dy + badgeHeight / 2), pinPaint);

    // Badge Background (Jet black with green glow)
    final bgPaint = Paint()
      ..color = const Color(0xFF0D1117).withOpacity(0.92)
      ..style = PaintingStyle.fill;

    final borderPaint = Paint()
      ..color = const Color(0xFF00FF40)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;

    final RRect rrect = RRect.fromRectAndRadius(badgeRect, const Radius.circular(8.0));
    canvas.drawRRect(rrect, bgPaint);
    canvas.drawRRect(rrect, borderPaint);

    // "NEXT MOVE" Header Text
    final textSpanHeader = TextSpan(
      text: 'NEXT MOVE',
      style: TextStyle(
        color: Colors.white.withOpacity(0.65),
        fontSize: 8.5,
        fontWeight: FontWeight.w800,
        letterSpacing: 1.0,
      ),
    );
    final painterHeader = TextPainter(
      text: textSpanHeader,
      textDirection: TextDirection.ltr,
    )..layout();
    painterHeader.paint(canvas, Offset(badgeRect.left + 12, badgeRect.top + 7));

    // "[PIECE] [from] ➔ [to]" Main Text
    final textSpanBody = TextSpan(
      children: [
        TextSpan(
          text: '$piece ',
          style: const TextStyle(
            color: Colors.white,
            fontSize: 12,
            fontWeight: FontWeight.w900,
            letterSpacing: 0.5,
          ),
        ),
        TextSpan(
          text: '$fromStr ➔ $toStr',
          style: const TextStyle(
            color: Color(0xFF00FF40),
            fontSize: 13,
            fontWeight: FontWeight.w900,
            letterSpacing: 0.5,
          ),
        ),
      ],
    );
    final painterBody = TextPainter(
      text: textSpanBody,
      textDirection: TextDirection.ltr,
    )..layout();
    painterBody.paint(canvas, Offset(badgeRect.left + 12, badgeRect.top + 21));
  }

  void _drawPerspectiveGrid(Canvas canvas, PerspectiveMapper mapper) {
    final gridPaint = Paint()
      ..color = const Color(0xFF00E5FF).withOpacity(0.18)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;

    for (int i = 1; i < 8; i++) {
      final double v = i / 8.0;
      canvas.drawLine(mapper.mapUnitToScreen(0.0, v), mapper.mapUnitToScreen(1.0, v), gridPaint);
    }
    for (int j = 1; j < 8; j++) {
      final double u = j / 8.0;
      canvas.drawLine(mapper.mapUnitToScreen(u, 0.0), mapper.mapUnitToScreen(u, 1.0), gridPaint);
    }
  }

  @override
  bool shouldRepaint(covariant ARBoardPainter oldDelegate) {
    return oldDelegate.corners != corners ||
        oldDelegate.bestMoveFrom != bestMoveFrom ||
        oldDelegate.bestMoveTo != bestMoveTo ||
        oldDelegate.pieceName != pieceName ||
        oldDelegate.lastOpponentMoveFrom != lastOpponentMoveFrom ||
        oldDelegate.lastOpponentMoveTo != lastOpponentMoveTo ||
        oldDelegate.pulseValue != pulseValue ||
        oldDelegate.showGrid != showGrid ||
        oldDelegate.isTrackingLocked != isTrackingLocked;
  }
}
