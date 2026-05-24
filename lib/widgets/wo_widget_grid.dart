import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// Android 桌面 Widget 风格的异形栅格。
///
/// - 栅格由 [crossAxisCount] 列正方形 cell 组成（或按 [cellAspectRatio] 调整）
/// - 每张 tile 通过 [WoWidgetGridTile] 指定 `(cw, ch)` 占用的 cell 数
/// - 自动 first-fit 寻位：从左到右、从上到下找第一个能放下的位置
/// - 卡片大小不一但都对齐到同一栅格
///
/// 用法：
/// ```dart
/// WoWidgetGrid(
///   crossAxisCount: 4,
///   gap: 12,
///   children: [
///     WoWidgetGridTile(cw: 4, ch: 2, child: PhotoCard()),
///     WoWidgetGridTile(cw: 2, ch: 2, child: AnnivCard()),
///     ...
///   ],
/// )
/// ```
class WoWidgetGrid extends StatelessWidget {
  const WoWidgetGrid({
    super.key,
    required this.crossAxisCount,
    required this.children,
    this.gap = 12,
    this.cellAspectRatio = 1.0,
  })  : assert(crossAxisCount > 0),
        assert(gap >= 0),
        assert(cellAspectRatio > 0);

  /// 列数（栅格的横向 cell 总数）
  final int crossAxisCount;

  /// cell 之间的间距（横纵相同）
  final double gap;

  /// cell 宽高比（默认 1 表示正方形）
  final double cellAspectRatio;

  /// tile 列表。会按声明顺序贪心放入栅格。
  final List<WoWidgetGridTile> children;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final cellWidth = (constraints.maxWidth - gap * (crossAxisCount - 1)) /
            crossAxisCount;
        final cellHeight = cellWidth / cellAspectRatio;

        final placements = _placeTiles(children, crossAxisCount);
        var maxRow = 0;
        for (final p in placements) {
          maxRow = math.max(maxRow, p.row + p.ch);
        }
        final totalHeight =
            maxRow == 0 ? 0.0 : maxRow * cellHeight + (maxRow - 1) * gap;

        return SizedBox(
          width: constraints.maxWidth,
          height: totalHeight,
          child: Stack(
            children: [
              for (var i = 0; i < children.length; i++)
                Positioned(
                  left: placements[i].col * (cellWidth + gap),
                  top: placements[i].row * (cellHeight + gap),
                  width: placements[i].cw * cellWidth +
                      (placements[i].cw - 1) * gap,
                  height: placements[i].ch * cellHeight +
                      (placements[i].ch - 1) * gap,
                  child: children[i].child,
                ),
            ],
          ),
        );
      },
    );
  }
}

/// 网格中的一格。`cw` × `ch` 表示横纵分别占几 cell。
@immutable
class WoWidgetGridTile {
  const WoWidgetGridTile({
    required this.cw,
    required this.ch,
    required this.child,
  })  : assert(cw > 0),
        assert(ch > 0);

  final int cw;
  final int ch;
  final Widget child;
}

@immutable
class _Placement {
  const _Placement({
    required this.col,
    required this.row,
    required this.cw,
    required this.ch,
  });

  final int col;
  final int row;
  final int cw;
  final int ch;
}

/// 一格的尺寸（cw × ch，单位 cell）。
typedef WoGridSize = ({int cw, int ch});

/// 一格的栅格坐标（左上角所在的 col / row）。
typedef WoGridPos = ({int col, int row});

/// First-fit 摆放：按声明顺序，依次找第一个能放下当前 tile 的位置，返回每格的
/// 栅格坐标。公开出来，便于调用方（如首页拖拽重排）按相同规则算出 col/row 后
/// 持久化到后端，保证本地视觉与服务端布局一致。
List<WoGridPos> computeWoGridPlacements(List<WoGridSize> sizes, int cols) {
  // occupied[row][col]，按需扩容
  final occupied = <List<bool>>[];

  void ensureRows(int rows) {
    while (occupied.length < rows) {
      occupied.add(List<bool>.filled(cols, false));
    }
  }

  bool fits(int col, int row, int cw, int ch) {
    if (col + cw > cols) return false;
    ensureRows(row + ch);
    for (var r = row; r < row + ch; r++) {
      for (var c = col; c < col + cw; c++) {
        if (occupied[r][c]) return false;
      }
    }
    return true;
  }

  void mark(int col, int row, int cw, int ch) {
    ensureRows(row + ch);
    for (var r = row; r < row + ch; r++) {
      for (var c = col; c < col + cw; c++) {
        occupied[r][c] = true;
      }
    }
  }

  final positions = <WoGridPos>[];
  for (final size in sizes) {
    final cw = size.cw.clamp(1, cols);
    final ch = size.ch;
    var placed = false;
    for (var row = 0; !placed; row++) {
      for (var col = 0; col + cw <= cols; col++) {
        if (fits(col, row, cw, ch)) {
          positions.add((col: col, row: row));
          mark(col, row, cw, ch);
          placed = true;
          break;
        }
      }
    }
  }
  return positions;
}

/// 内部：把 tile 列表映射为带尺寸的 [_Placement]。
List<_Placement> _placeTiles(List<WoWidgetGridTile> tiles, int cols) {
  final positions =
      computeWoGridPlacements([for (final t in tiles) (cw: t.cw, ch: t.ch)], cols);
  return [
    for (var i = 0; i < tiles.length; i++)
      _Placement(
        col: positions[i].col,
        row: positions[i].row,
        cw: tiles[i].cw,
        ch: tiles[i].ch,
      ),
  ];
}
