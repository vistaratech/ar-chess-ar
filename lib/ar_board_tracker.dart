import 'dart:math';
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

/// Real-Time On-Device Computer Vision Detector.
/// Continuously processes camera frames (like a QR scanner) to detect and track
/// the physical chessboard wherever it appears in the room.
class RealtimeChessboardDetector {
  RealtimeChessboardDetector._();

  /// Analyzes a camera frame in real-time (<5ms) and extracts the 4 corners of the chessboard.
  static BoardCorners? detectBoard({
    required CameraImage image,
    required Size screenSize,
    required int sensorOrientation,
  }) {
    if (image.planes.isEmpty) return null;

    final plane = image.planes[0]; // Luminance plane (Y)
    final bytes = plane.bytes;
    final int srcW = image.width;
    final int srcH = image.height;
    final int rowStride = plane.bytesPerRow;

    // Downsample factor for real-time 30-60 FPS performance
    const int step = 8;
    final int gridW = srcW ~/ step;
    final int gridH = srcH ~/ step;

    final List<int> energyPointsX = [];
    final List<int> energyPointsY = [];

    // 1. Scan the frame for alternating grid edge energy (chessboard pattern)
    for (int gy = 1; gy < gridH - 1; gy++) {
      final int py = gy * step;
      final int rowOffset = py * rowStride;
      final int prevRowOffset = (py - step) * rowStride;
      final int nextRowOffset = (py + step) * rowStride;

      for (int gx = 1; gx < gridW - 1; gx++) {
        final int px = gx * step;

        final int valCenter = bytes[rowOffset + px];
        final int valLeft = bytes[rowOffset + (px - step)];
        final int valRight = bytes[rowOffset + (px + step)];
        final int valTop = bytes[prevRowOffset + px];
        final int valBottom = bytes[nextRowOffset + px];

        // Horizontal & Vertical gradient magnitude
        final int gradX = (valRight - valLeft).abs();
        final int gradY = (valBottom - valTop).abs();
        final int diffCenter = (valCenter - ((valLeft + valRight + valTop + valBottom) >> 2)).abs();

        // High contrast alternating pattern characteristic of chessboard squares
        if (gradX > 38 && gradY > 38 && diffCenter > 25) {
          energyPointsX.add(px);
          energyPointsY.add(py);
        }
      }
    }

    // Must have enough candidate square edge points to form a valid chessboard
    if (energyPointsX.length < 35) {
      return null;
    }

    // 2. Compute Centroid of the detected board
    double sumX = 0;
    double sumY = 0;
    for (int i = 0; i < energyPointsX.length; i++) {
      sumX += energyPointsX[i];
      sumY += energyPointsY[i];
    }
    final double centerX = sumX / energyPointsX.length;
    final double centerY = sumY / energyPointsY.length;

    // 3. Find extreme points in diagonal projections to locate the 4 corners:
    // Top-Left (min x + y), Top-Right (max x - y), Bottom-Right (max x + y), Bottom-Left (min x - y)
    int minSumIdx = 0;
    int maxDiffIdx = 0;
    int maxSumIdx = 0;
    int minDiffIdx = 0;

    double minSum = double.infinity;
    double maxDiff = -double.infinity;
    double maxSum = -double.infinity;
    double minDiff = double.infinity;

    for (int i = 0; i < energyPointsX.length; i++) {
      final double x = energyPointsX[i].toDouble();
      final double y = energyPointsY[i].toDouble();

      final double sum = x + y;
      final double diff = x - y;

      if (sum < minSum) {
        minSum = sum;
        minSumIdx = i;
      }
      if (diff > maxDiff) {
        maxDiff = diff;
        maxDiffIdx = i;
      }
      if (sum > maxSum) {
        maxSum = sum;
        maxSumIdx = i;
      }
      if (diff < minDiff) {
        minDiff = diff;
        minDiffIdx = i;
      }
    }

    // Expand points slightly outward (5%) to cover outer board border
    Offset expandCorner(double px, double py) {
      final double vx = px - centerX;
      final double vy = py - centerY;
      return Offset(px + vx * 0.08, py + vy * 0.08);
    }

    final rawTL = expandCorner(energyPointsX[minSumIdx].toDouble(), energyPointsY[minSumIdx].toDouble());
    final rawTR = expandCorner(energyPointsX[maxDiffIdx].toDouble(), energyPointsY[maxDiffIdx].toDouble());
    final rawBR = expandCorner(energyPointsX[maxSumIdx].toDouble(), energyPointsY[maxSumIdx].toDouble());
    final rawBL = expandCorner(energyPointsX[minDiffIdx].toDouble(), energyPointsY[minDiffIdx].toDouble());

    // 4. Transform from Camera Sensor pixel space to Screen coordinates
    return _transformToScreen(
      rawTL, rawTR, rawBR, rawBL,
      srcW: srcW,
      srcH: srcH,
      screenSize: screenSize,
      sensorOrientation: sensorOrientation,
    );
  }

  static BoardCorners _transformToScreen(
    Offset pTL, Offset pTR, Offset pBR, Offset pBL, {
    required int srcW,
    required int srcH,
    required Size screenSize,
    required int sensorOrientation,
  }) {
    // Android back camera sensor is usually rotated 90° in portrait
    Offset rotate(Offset p) {
      if (sensorOrientation == 90) {
        return Offset(srcH - 1 - p.dy, p.dx);
      } else if (sensorOrientation == 270) {
        return Offset(p.dy, srcW - 1 - p.dx);
      }
      return p;
    }

    final double rotW = (sensorOrientation == 90 || sensorOrientation == 270) ? srcH.toDouble() : srcW.toDouble();
    final double rotH = (sensorOrientation == 90 || sensorOrientation == 270) ? srcW.toDouble() : srcH.toDouble();

    final scale = max(screenSize.width / rotW, screenSize.height / rotH);
    final offsetX = (screenSize.width - rotW * scale) / 2.0;
    final offsetY = (screenSize.height - rotH * scale) / 2.0;

    Offset mapToScreen(Offset p) {
      final rot = rotate(p);
      return Offset(
        rot.dx * scale + offsetX,
        rot.dy * scale + offsetY,
      );
    }

    return BoardCorners(
      topLeft: mapToScreen(pTL),
      topRight: mapToScreen(pTR),
      bottomRight: mapToScreen(pBR),
      bottomLeft: mapToScreen(pBL),
    );
  }
}

/// Continuous Board Tracking Manager with temporal smoothing and auto-lock.
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
      _currentCorners = _currentCorners!.smoothTowards(detected, 0.40);
      _isLocked = true;
    }
  }

  /// Called when a camera frame did not find a high-confidence board.
  void onFrameLost() {
    _framesSinceLastDetection++;
    if (_framesSinceLastDetection > 25) {
      // If lost for nearly a second, unlock so user knows camera is searching
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
