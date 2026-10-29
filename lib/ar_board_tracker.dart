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

/// Advanced Real-Time Computer Vision Detector for Chessboards.
/// Accurately detects and aligns to physical or digital chessboards in ANY orientation:
/// - Flat on a table
/// - Vertical / upright on a laptop or computer monitor
/// - Tilted or viewed from acute angles
/// - Rotated sideways
class RealtimeChessboardDetector {
  RealtimeChessboardDetector._();

  /// Analyzes a camera frame in real time and returns accurately aligned screen-space corners.
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

    // Detect pixel format:
    // iOS produces bgra8888 (1 plane, 4 bytes per pixel)
    // Android produces yuv420 (plane 0 is Y, 1 byte per pixel)
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

    // Helper to read luminance in sensor space
    int readLuminance(int sx, int sy) {
      if (sx < 0 || sx >= srcW || sy < 0 || sy >= srcH) return 0;
      if (bpp == 4) {
        final int idx = sy * rowStride + (sx << 2);
        if (idx + 2 >= bytes.length) return 0;
        // Rec.601 integer luminance: (R*77 + G*150 + B*29) >> 8
        return (bytes[idx + 2] * 77 + bytes[idx + 1] * 150 + bytes[idx] * 29) >> 8;
      } else {
        final int idx = sy * rowStride + sx;
        if (idx >= bytes.length) return 0;
        return bytes[idx];
      }
    }

    // Helper to map Normalized Screen Coordinates [0..1, 0..1] to Camera Sensor Coordinates
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

    // 1. Sample Screen Space directly in a fast 2D grid
    const int gridCols = 54;
    const int gridRows = 72;
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

    // 2. Identify 2D Checkerboard Saddle Points (Corners where 4 squares meet)
    // At an alternating checkerboard junction, diagonal differences have strong opposite signs.
    final List<Offset> candidateScreenNorm = [];
    const int r = 2; // Radius in grid cells (~1/20th of screen)

    for (int gy = r; gy < gridRows - r; gy++) {
      for (int gx = r; gx < gridCols - r; gx++) {
        final int tl = lumGrid[gy - r][gx - r];
        final int tr = lumGrid[gy - r][gx + r];
        final int bl = lumGrid[gy + r][gx - r];
        final int br = lumGrid[gy + r][gx + r];

        // Horizontal gradients along top and bottom rows
        final int dTop = tr - tl;
        final int dBottom = br - bl;

        // Vertical gradients along left and right cols
        final int dLeft = bl - tl;
        final int dRight = br - tr;

        // Diagonal gradients
        final int dDiag1 = br - tl;
        final int dDiag2 = tr - bl;

        // Checkerboard saddle test: opposite signs on opposite sides with high contrast
        final bool isSaddleH = (dTop * dBottom) < -400 && (dTop.abs() > 22 || dBottom.abs() > 22);
        final bool isSaddleV = (dLeft * dRight) < -400 && (dLeft.abs() > 22 || dRight.abs() > 22);
        final bool isCrossDiag = (dDiag1.abs() > 30 || dDiag2.abs() > 30);

        if ((isSaddleH || isSaddleV) && isCrossDiag) {
          candidateScreenNorm.add(Offset(gx / (gridCols - 1), gy / (gridRows - 1)));
        }
      }
    }

    // Need a minimum cluster of internal corners to represent a chessboard
    if (candidateScreenNorm.length < 14) {
      return null;
    }

    // 3. Spatial Clustering & Outlier Rejection
    // Compute centroid of candidates
    double sumX = 0;
    double sumY = 0;
    for (final p in candidateScreenNorm) {
      sumX += p.dx;
      sumY += p.dy;
    }
    final double cx = sumX / candidateScreenNorm.length;
    final double cy = sumY / candidateScreenNorm.length;

    // Filter points to retain only the dense central cluster (removes keyboard & room clutter)
    final List<double> dists = candidateScreenNorm
        .map((p) => sqrt((p.dx - cx) * (p.dx - cx) + (p.dy - cy) * (p.dy - cy)))
        .toList()
      ..sort();

    final double medianDist = dists[dists.length ~/ 2];
    final double maxClusterDist = max(0.12, medianDist * 2.2);

    final List<Offset> cluster = candidateScreenNorm
        .where((p) => sqrt((p.dx - cx) * (p.dx - cx) + (p.dy - cy) * (p.dy - cy)) <= maxClusterDist)
        .toList();

    if (cluster.length < 10) return null;

    // Recompute refined centroid of the board cluster
    double refX = 0;
    double refY = 0;
    for (final p in cluster) {
      refX += p.dx;
      refY += p.dy;
    }
    final double boardCenterX = refX / cluster.length;
    final double boardCenterY = refY / cluster.length;

    // 4. Find the 4 Extreme Quadrant Corners in Screen Space
    // A chessboard has 4 corners. In any perspective orientation, projecting points
    // along the two diagonals (+45° and -45°) uniquely identifies the 4 corners:
    // TL: min(x + y), TR: max(x - y), BR: max(x + y), BL: min(x - y)
    Offset candTL = cluster.first;
    Offset candTR = cluster.first;
    Offset candBR = cluster.first;
    Offset candBL = cluster.first;

    double minSum = double.infinity;
    double maxDiff = -double.infinity;
    double maxSum = -double.infinity;
    double minDiff = double.infinity;

    for (final p in cluster) {
      final double sum = p.dx + p.dy;
      final double diff = p.dx - p.dy;

      if (sum < minSum) {
        minSum = sum;
        candTL = p;
      }
      if (diff > maxDiff) {
        maxDiff = diff;
        candTR = p;
      }
      if (sum > maxSum) {
        maxSum = sum;
        candBR = p;
      }
      if (diff < minDiff) {
        minDiff = diff;
        candBL = p;
      }
    }

    // 5. Extrapolate from the 7x7 internal corner grid to the full 8x8 outer perimeter + border
    // The internal intersections span 6 squares out of 8 (ratio 6/8 = 0.75).
    // To reach the outer edge, we scale outward from the center by ~1.36.
    const double expansionFactor = 1.35;
    Offset expandPoint(Offset p) {
      final double vx = p.dx - boardCenterX;
      final double vy = p.dy - boardCenterY;
      return Offset(
        (boardCenterX + vx * expansionFactor).clamp(0.02, 0.98),
        (boardCenterY + vy * expansionFactor).clamp(0.02, 0.98),
      );
    }

    final Offset normTL = expandPoint(candTL);
    final Offset normTR = expandPoint(candTR);
    final Offset normBR = expandPoint(candBR);
    final Offset normBL = expandPoint(candBL);

    // 6. Convert Normalized Screen Coordinates to Absolute Screen Pixels
    Offset toScreenPixels(Offset norm) {
      return Offset(
        norm.dx * renderedW + offsetX,
        norm.dy * renderedH + offsetY,
      );
    }

    final rawCorners = [
      toScreenPixels(normTL),
      toScreenPixels(normTR),
      toScreenPixels(normBR),
      toScreenPixels(normBL),
    ];

    // 7. Strictly Order Corners Clockwise: Top-Left -> Top-Right -> Bottom-Right -> Bottom-Left
    return orderCorners(rawCorners);
  }

  /// Organizes 4 quadrilateral points strictly clockwise starting from Top-Left in Screen Space.
  /// Prevents any inversion, twist, or diagonal flipping across any orientation or device.
  static BoardCorners orderCorners(List<Offset> pts) {
    if (pts.length != 4) {
      throw ArgumentError('orderCorners requires exactly 4 points');
    }

    // 1. Compute Centroid
    final double cx = (pts[0].dx + pts[1].dx + pts[2].dx + pts[3].dx) / 4.0;
    final double cy = (pts[0].dy + pts[1].dy + pts[2].dy + pts[3].dy) / 4.0;

    // 2. Sort points radially around the centroid by angle
    final List<Offset> radial = List.of(pts)
      ..sort((a, b) {
        final angA = atan2(a.dy - cy, a.dx - cx);
        final angB = atan2(b.dy - cy, b.dx - cx);
        return angA.compareTo(angB);
      });

    // 3. Ensure Clockwise Winding Order
    final p0 = radial[0];
    final p1 = radial[1];
    final p2 = radial[2];
    final cross = (p1.dx - p0.dx) * (p2.dy - p1.dy) - (p1.dy - p0.dy) * (p2.dx - p1.dx);
    final List<Offset> clockwise = cross > 0 ? radial : radial.reversed.toList();

    // 4. Identify the point closest to Top-Left in Screen Space (minimum x + y)
    int tlIdx = 0;
    double minSum = double.infinity;
    for (int i = 0; i < 4; i++) {
      final double sum = clockwise[i].dx + clockwise[i].dy;
      if (sum < minSum) {
        minSum = sum;
        tlIdx = i;
      }
    }

    // 5. Extract clockwise corners starting at Top-Left
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

  /// Generates a perfectly proportioned square chessboard centered on a given screen point.
  /// Used for one-tap snapping or instant center-lock.
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
  int _framesSinceLastDetection = 0;

  BoardCorners? get currentCorners => _currentCorners;
  bool get isLocked => _isLocked;

  /// Called whenever a new camera frame is processed.
  void updateWithDetected(BoardCorners detected) {
    _framesSinceLastDetection = 0;

    if (_currentCorners == null) {
      _currentCorners = detected;
      _isLocked = true;
    } else {
      // Dynamic smoothing: smoothly glides corners to follow camera movement
      // and eliminates high-frequency jitter.
      _currentCorners = _currentCorners!.smoothTowards(detected, 0.35);
      _isLocked = true;
    }
  }

  /// Called when a camera frame did not find a high-confidence board.
  void onFrameLost() {
    _framesSinceLastDetection++;
    if (_framesSinceLastDetection > 30) {
      // If lost for over 1 second, unlock so user knows camera is searching
      _isLocked = false;
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
  }
}
