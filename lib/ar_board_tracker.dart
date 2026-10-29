import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';

/// Representation of the 4 detected corners of a physical chessboard in screen coordinates.
class BoardCorners {
  final Offset topLeft;
  final Offset topRight;
  final Offset bottomRight;
  final Offset bottomLeft;

  const BoardCorners({
    required this.topLeft,
    required this.topRight,
    required this.bottomRight,
    required this.bottomLeft,
  });

  BoardCorners copyWith({
    Offset? topLeft,
    Offset? topRight,
    Offset? bottomRight,
    Offset? bottomLeft,
  }) {
    return BoardCorners(
      topLeft: topLeft ?? this.topLeft,
      topRight: topRight ?? this.topRight,
      bottomRight: bottomRight ?? this.bottomRight,
      bottomLeft: bottomLeft ?? this.bottomLeft,
    );
  }

  Offset get center => Offset(
        (topLeft.dx + topRight.dx + bottomRight.dx + bottomLeft.dx) / 4.0,
        (topLeft.dy + topRight.dy + bottomRight.dy + bottomLeft.dy) / 4.0,
      );

  /// Approximate width in screen pixels.
  double get estimatedWidth =>
      ((topRight - topLeft).distance + (bottomRight - bottomLeft).distance) / 2.0;

  /// Approximate height in screen pixels.
  double get estimatedHeight =>
      ((bottomLeft - topLeft).distance + (bottomRight - topRight).distance) / 2.0;

  /// Smoothly glides towards a new target position (exponential moving average).
  BoardCorners smoothTowards(BoardCorners target, double alpha) {
    return BoardCorners(
      topLeft: _lerp(topLeft, target.topLeft, alpha),
      topRight: _lerp(topRight, target.topRight, alpha),
      bottomRight: _lerp(bottomRight, target.bottomRight, alpha),
      bottomLeft: _lerp(bottomLeft, target.bottomLeft, alpha),
    );
  }

  static Offset _lerp(Offset a, Offset b, double t) {
    return Offset(
      a.dx + (b.dx - a.dx) * t,
      a.dy + (b.dy - a.dy) * t,
    );
  }

  /// Calculates the area of the quadrilateral using the Shoelace formula.
  double get area {
    return 0.5 *
        ((topLeft.dx * topRight.dy +
                topRight.dx * bottomRight.dy +
                bottomRight.dx * bottomLeft.dy +
                bottomLeft.dx * topLeft.dy) -
            (topLeft.dy * topRight.dx +
                topRight.dy * bottomRight.dx +
                bottomRight.dy * bottomLeft.dx +
                bottomLeft.dy * topLeft.dx))
            .abs();
  }
}

/// Perspective mapper that transforms between chessboard coordinates [0..1, 0..1]
/// and 2D live camera screen coordinates.
class PerspectiveMapper {
  final BoardCorners corners;
  late final List<double> _forwardMatrix;

  PerspectiveMapper(this.corners) {
    _forwardMatrix = _computeForwardMatrix(
      corners.topLeft.dx, corners.topLeft.dy,
      corners.topRight.dx, corners.topRight.dy,
      corners.bottomLeft.dx, corners.bottomLeft.dy,
      corners.bottomRight.dx, corners.bottomRight.dy,
    );
  }

  List<double> _computeForwardMatrix(
    double x0, double y0,
    double x1, double y1,
    double x2, double y2,
    double x3, double y3,
  ) {
    final double dx1 = x1 - x3;
    final double dx2 = x2 - x3;
    final double dx3 = x0 - x1 + x3 - x2;

    final double dy1 = y1 - y3;
    final double dy2 = y2 - y3;
    final double dy3 = y0 - y1 + y3 - y2;

    final double denom = dx1 * dy2 - dx2 * dy1;
    if (denom.abs() < 1e-10) {
      return [1, 0, x0, 0, 1, y0, 0, 0, 1];
    }

    final double g = (dx3 * dy2 - dx2 * dy3) / denom;
    final double h = (dx1 * dy3 - dx3 * dy1) / denom;

    final double a = x1 - x0 + g * x1;
    final double b = x2 - x0 + h * x2;
    final double c = x0;

    final double d = y1 - y0 + g * y1;
    final double e = y2 - y0 + h * y2;
    final double f = y0;

    return [a, b, c, d, e, f, g, h, 1.0];
  }

  Offset mapUnitToScreen(double u, double v) {
    final double a = _forwardMatrix[0];
    final double b = _forwardMatrix[1];
    final double c = _forwardMatrix[2];
    final double d = _forwardMatrix[3];
    final double e = _forwardMatrix[4];
    final double f = _forwardMatrix[5];
    final double g = _forwardMatrix[6];
    final double h = _forwardMatrix[7];

    final double denominator = g * u + h * v + 1.0;
    if (denominator.abs() < 1e-10) {
      return Offset(c, f);
    }

    final double x = (a * u + b * v + c) / denominator;
    final double y = (d * u + e * v + f) / denominator;
    return Offset(x, y);
  }

  Offset getSquareCenter(String square, {bool whiteAtBottom = true}) {
    if (square.length < 2) return corners.center;
    final fileChar = square[0].toLowerCase();
    final rankChar = square[1];

    final int fileIdx = fileChar.codeUnitAt(0) - 'a'.codeUnitAt(0);
    final int rankIdx = int.tryParse(rankChar) ?? 1;

    double u, v;
    if (whiteAtBottom) {
      u = (fileIdx + 0.5) / 8.0;
      v = (8 - rankIdx + 0.5) / 8.0;
    } else {
      u = (7 - fileIdx + 0.5) / 8.0;
      v = (rankIdx - 1 + 0.5) / 8.0;
    }

    return mapUnitToScreen(u.clamp(0.0, 1.0), v.clamp(0.0, 1.0));
  }

  List<Offset> getSquarePolygon(String square, {bool whiteAtBottom = true}) {
    if (square.length < 2) {
      return [corners.topLeft, corners.topRight, corners.bottomRight, corners.bottomLeft];
    }
    final fileChar = square[0].toLowerCase();
    final rankChar = square[1];

    final int fileIdx = fileChar.codeUnitAt(0) - 'a'.codeUnitAt(0);
    final int rankIdx = int.tryParse(rankChar) ?? 1;

    double u0, u1, v0, v1;
    if (whiteAtBottom) {
      u0 = fileIdx / 8.0;
      u1 = (fileIdx + 1) / 8.0;
      v0 = (8 - rankIdx) / 8.0;
      v1 = (8 - rankIdx + 1) / 8.0;
    } else {
      u0 = (7 - fileIdx) / 8.0;
      u1 = (7 - fileIdx + 1) / 8.0;
      v0 = (rankIdx - 1) / 8.0;
      v1 = (rankIdx) / 8.0;
    }

    return [
      mapUnitToScreen(u0, v0),
      mapUnitToScreen(u1, v0),
      mapUnitToScreen(u1, v1),
      mapUnitToScreen(u0, v1),
    ];
  }
}

/// Fully Automatic, Real-Time On-Device Chessboard Detector.
/// Automatically locates the 4 corners of any physical or screen chessboard in real time:
/// - 100% hands-free (zero manual touch required).
/// - Works in any orientation (vertical on laptop/monitor, flat on desk, tilted, sideways).
/// - Uses Multi-Scale Saddle Point filtering and Principal Component Analysis (PCA) bounding quad estimation.
class RealtimeChessboardDetector {
  RealtimeChessboardDetector._();

  /// Analyzes a camera frame in real time and automatically finds the 4 corners of the chessboard.
  static BoardCorners? detectBoard({
    required CameraImage image,
    required Size screenSize,
    required int sensorOrientation,
  }) {
    if (image.planes.isEmpty) return null;

    final plane = image.planes[0];
    final Uint8List bytes = plane.bytes;
    final int srcW = image.width;
    final int srcH = image.height;
    final int rowStride = plane.bytesPerRow;

    // Detect format: iOS bgra8888 (4 bpp) vs Android yuv420 (1 bpp)
    final int bpp = (image.planes.length == 1 && plane.bytesPerPixel == 4)
        ? 4
        : (plane.bytesPerPixel ?? (image.planes.length == 1 ? 4 : 1));

    // Screen preview mapping parameters (BoxFit.cover)
    final double previewW = (sensorOrientation == 90 || sensorOrientation == 270)
        ? srcH.toDouble()
        : srcW.toDouble();
    final double previewH = (sensorOrientation == 90 || sensorOrientation == 270)
        ? srcW.toDouble()
        : srcH.toDouble();

    final double scale = max(screenSize.width / previewW, screenSize.height / previewH);
    final double renderedW = previewW * scale;
    final double renderedH = previewH * scale;
    final double offsetX = (screenSize.width - renderedW) / 2.0;
    final double offsetY = (screenSize.height - renderedH) / 2.0;

    // Fast luminance reader in sensor space
    int readLuminance(int sx, int sy) {
      if (sx < 0 || sx >= srcW || sy < 0 || sy >= srcH) return 0;
      if (bpp == 4) {
        final int idx = sy * rowStride + (sx << 2);
        if (idx + 2 >= bytes.length) return 0;
        return (bytes[idx + 2] * 77 + bytes[idx + 1] * 150 + bytes[idx] * 29) >> 8;
      } else {
        final int idx = sy * rowStride + sx;
        if (idx >= bytes.length) return 0;
        return bytes[idx];
      }
    }

    // Maps Normalized Screen [0..1, 0..1] to Camera Sensor Coordinates
    Offset screenNormToSensor(double nx, double ny) {
      double sx, sy;
      if (sensorOrientation == 90) {
        sx = ny * (srcW - 1);
        sy = (1.0 - nx) * (srcH - 1);
      } else if (sensorOrientation == 270) {
        sx = (1.0 - ny) * (srcW - 1);
        sy = nx * (srcH - 1);
      } else if (sensorOrientation == 180) {
        sx = (1.0 - nx) * (srcW - 1);
        sy = (1.0 - ny) * (srcH - 1);
      } else {
        sx = nx * (srcW - 1);
        sy = ny * (srcH - 1);
      }
      return Offset(sx, sy);
    }

    // 1. Sample Screen Space in an optimized 2D grid
    const int gridCols = 50;
    const int gridRows = 68;
    final List<List<int>> lumGrid = List.generate(
      gridRows,
      (_) => List<int>.filled(gridCols, 0),
    );

    for (int gy = 0; gy < gridRows; gy++) {
      final double ny = gy / (gridRows - 1);
      for (int gx = 0; gx < gridCols; gx++) {
        final double nx = gx / (gridCols - 1);
        final sensorPt = screenNormToSensor(nx, ny);
        lumGrid[gy][gx] = readLuminance(sensorPt.dx.toInt(), sensorPt.dy.toInt());
      }
    }

    // 2. Multi-Scale Checkerboard Corner Detection
    // Tests both r=1 (far/medium boards) and r=2 (close boards)
    final List<Offset> candidateScreenNorm = [];

    for (int gy = 2; gy < gridRows - 2; gy++) {
      for (int gx = 2; gx < gridCols - 2; gx++) {
        bool isCorner = false;

        for (final int r in [1, 2]) {
          final int tl = lumGrid[gy - r][gx - r];
          final int tr = lumGrid[gy - r][gx + r];
          final int bl = lumGrid[gy + r][gx - r];
          final int br = lumGrid[gy + r][gx + r];

          final int dTop = tr - tl;
          final int dBottom = br - bl;
          final int dLeft = bl - tl;
          final int dRight = br - tr;

          // Sensitive checkerboard saddle response condition:
          // Opposite horizontal differences and opposite vertical differences
          final bool saddleH = (dTop * dBottom) < -120 && (dTop.abs() > 14 || dBottom.abs() > 14);
          final bool saddleV = (dLeft * dRight) < -120 && (dLeft.abs() > 14 || dRight.abs() > 14);

          if (saddleH || saddleV) {
            isCorner = true;
            break;
          }
        }

        if (isCorner) {
          candidateScreenNorm.add(Offset(gx / (gridCols - 1), gy / (gridRows - 1)));
        }
      }
    }

    // Require at least 8 detected checkerboard corners to confirm presence of a chessboard
    if (candidateScreenNorm.length < 8) {
      return null;
    }

    // 3. Density Clustering: isolate the chessboard cluster and reject background noise
    double sumX = 0;
    double sumY = 0;
    for (final p in candidateScreenNorm) {
      sumX += p.dx;
      sumY += p.dy;
    }
    final double initCx = sumX / candidateScreenNorm.length;
    final double initCy = sumY / candidateScreenNorm.length;

    // Filter points by median distance to eliminate keyboard keys or room clutter
    final List<double> dists = candidateScreenNorm
        .map((p) => sqrt((p.dx - initCx) * (p.dx - initCx) + (p.dy - initCy) * (p.dy - initCy)))
        .toList()
      ..sort();

    final double medianDist = dists[dists.length ~/ 2];
    final double maxClusterDist = max(0.14, medianDist * 2.4);

    final List<Offset> cluster = candidateScreenNorm
        .where((p) => sqrt((p.dx - initCx) * (p.dx - initCx) + (p.dy - initCy) * (p.dy - initCy)) <= maxClusterDist)
        .toList();

    if (cluster.length < 8) return null;

    // 4. Principal Component Analysis (PCA) to determine exact board orientation & tilt angle
    double cx = 0;
    double cy = 0;
    for (final p in cluster) {
      cx += p.dx;
      cy += p.dy;
    }
    cx /= cluster.length;
    cy /= cluster.length;

    double sxx = 0;
    double syy = 0;
    double sxy = 0;
    for (final p in cluster) {
      final double dx = p.dx - cx;
      final double dy = p.dy - cy;
      sxx += dx * dx;
      syy += dy * dy;
      sxy += dx * dy;
    }
    sxx /= cluster.length;
    syy /= cluster.length;
    sxy /= cluster.length;

    // Principal angle of the chessboard grid
    final double theta = 0.5 * atan2(2.0 * sxy, sxx - syy);
    final double cosT = cos(-theta);
    final double sinT = sin(-theta);

    // Rotate all cluster points into the board's aligned frame (u, v)
    double minU = double.infinity;
    double maxU = -double.infinity;
    double minV = double.infinity;
    double maxV = -double.infinity;

    for (final p in cluster) {
      final double dx = p.dx - cx;
      final double dy = p.dy - cy;
      final double u = dx * cosT - dy * sinT;
      final double v = dx * sinT + dy * cosT;

      if (u < minU) minU = u;
      if (u > maxU) maxU = u;
      if (v < minV) minV = v;
      if (v > maxV) maxV = v;
    }

    final double boardSpanU = maxU - minU;
    final double boardSpanV = maxV - minV;

    // Must have reasonable aspect ratio and minimum size
    if (boardSpanU < 0.08 || boardSpanV < 0.08) return null;
    final double aspect = boardSpanU / boardSpanV;
    if (aspect < 0.5 || aspect > 2.0) return null;

    // 5. Extrapolate from the inner intersection grid to the full 8x8 outer perimeter + border
    // Inner 7x7 intersections span 6/8 of board = 0.75.
    // Scale factor to reach outer boundary is 8/6 ~ 1.333 + 0.05 padding for wood/bezel = 1.38
    final double halfSpanU = (boardSpanU / 2.0) * 1.36;
    final double halfSpanV = (boardSpanV / 2.0) * 1.36;
    final double centerU = (minU + maxU) / 2.0;
    final double centerV = (minV + maxV) / 2.0;

    // 4 Extrapolated corners in aligned frame (u, v)
    final List<Offset> alignedCorners = [
      Offset(centerU - halfSpanU, centerV - halfSpanV),
      Offset(centerU + halfSpanU, centerV - halfSpanV),
      Offset(centerU + halfSpanU, centerV + halfSpanV),
      Offset(centerU - halfSpanU, centerV + halfSpanV),
    ];

    // 6. Rotate corners back by +theta into normalized screen coordinates
    final double cosBack = cos(theta);
    final double sinBack = sin(theta);

    Offset rotateBack(Offset uv) {
      final double nx = cx + uv.dx * cosBack - uv.dy * sinBack;
      final double ny = cy + uv.dx * sinBack + uv.dy * cosBack;
      return Offset(nx.clamp(0.01, 0.99), ny.clamp(0.01, 0.99));
    }

    final normCorners = alignedCorners.map(rotateBack).toList();

    // 7. Convert Normalized Screen Coordinates to Screen Pixels
    Offset toScreenPixels(Offset norm) {
      return Offset(
        norm.dx * renderedW + offsetX,
        norm.dy * renderedH + offsetY,
      );
    }

    final screenPixelCorners = normCorners.map(toScreenPixels).toList();

    // 8. Order Corners strictly clockwise: Top-Left -> Top-Right -> Bottom-Right -> Bottom-Left
    return orderCorners(screenPixelCorners);
  }

  /// Organizes 4 quadrilateral points strictly clockwise starting from Top-Left in Screen Space.
  /// Prevents any inversion, twist, or diagonal flipping across any orientation or device.
  static BoardCorners orderCorners(List<Offset> pts) {
    if (pts.length != 4) {
      throw ArgumentError('orderCorners requires exactly 4 points');
    }

    final double cx = (pts[0].dx + pts[1].dx + pts[2].dx + pts[3].dx) / 4.0;
    final double cy = (pts[0].dy + pts[1].dy + pts[2].dy + pts[3].dy) / 4.0;

    // Sort points radially around the centroid by angle
    final List<Offset> radial = List.of(pts)
      ..sort((a, b) {
        final angA = atan2(a.dy - cy, a.dx - cx);
        final angB = atan2(b.dy - cy, b.dx - cx);
        return angA.compareTo(angB);
      });

    // Ensure Clockwise Winding Order
    final p0 = radial[0];
    final p1 = radial[1];
    final p2 = radial[2];
    final cross = (p1.dx - p0.dx) * (p2.dy - p1.dy) - (p1.dy - p0.dy) * (p2.dx - p1.dx);
    final List<Offset> clockwise = cross > 0 ? radial : radial.reversed.toList();

    // Find the point closest to Top-Left in Screen Space (minimum x + y)
    int tlIdx = 0;
    double minSum = double.infinity;
    for (int i = 0; i < 4; i++) {
      final double sum = clockwise[i].dx + clockwise[i].dy;
      if (sum < minSum) {
        minSum = sum;
        tlIdx = i;
      }
    }

    final tl = clockwise[tlIdx];
    final tr = clockwise[(tlIdx + 1) % 4];
    final br = clockwise[(tlIdx + 2) % 4];
    final bl = clockwise[(tlIdx + 3) % 4];

    return BoardCorners(
      topLeft: tl,
      topRight: tr,
      bottomRight: br,
      bottomLeft: bl,
    );
  }

  /// Generates a centered board fallback if needed.
  static BoardCorners createCenteredBoard(Size screenSize, {Offset? targetCenter, double? boardSize}) {
    final center = targetCenter ?? Offset(screenSize.width / 2.0, screenSize.height * 0.46);
    final size = boardSize ?? min(screenSize.width * 0.82, screenSize.height * 0.48);
    final half = size / 2.0;

    return BoardCorners(
      topLeft: Offset(center.dx - half, center.dy - half),
      topRight: Offset(center.dx + half, center.dy - half),
      bottomRight: Offset(center.dx + half, center.dy + half),
      bottomLeft: Offset(center.dx - half, center.dy + half),
    );
  }
}

/// Continuous Board Tracking Manager with adaptive temporal smoothing.
class AutomaticBoardTracker {
  BoardCorners? _currentCorners;
  bool _isLocked = false;
  int _consecutiveDetections = 0;
  int _framesSinceLastDetection = 0;

  BoardCorners? get currentCorners => _currentCorners;
  bool get isLocked => _isLocked;
  int get consecutiveDetections => _consecutiveDetections;

  /// Called whenever a new camera frame is processed.
  void updateWithDetected(BoardCorners detected) {
    _framesSinceLastDetection = 0;
    _consecutiveDetections++;

    if (_currentCorners == null) {
      _currentCorners = detected;
      _isLocked = true;
    } else {
      // Dynamic temporal smoothing: smoothly glides corners to follow camera movement
      // and eliminates high-frequency jitter.
      _currentCorners = _currentCorners!.smoothTowards(detected, 0.45);
      _isLocked = true;
    }
  }

  /// Called when a camera frame did not find a high-confidence board.
  void onFrameLost() {
    _framesSinceLastDetection++;
    // Keep tracking active across brief motion blurs (up to 45 frames ~ 1.5s)
    if (_framesSinceLastDetection > 45) {
      _isLocked = false;
      _consecutiveDetections = 0;
    }
  }

  void setManualCorners(BoardCorners corners) {
    _currentCorners = corners;
    _isLocked = true;
    _framesSinceLastDetection = 0;
  }

  void reset() {
    _currentCorners = null;
    _isLocked = false;
    _framesSinceLastDetection = 0;
    _consecutiveDetections = 0;
  }
}
