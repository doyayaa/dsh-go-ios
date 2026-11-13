// Liquid Glass 适配层（iOS 移植版，docs/ios-port-notes.md）。
//
// 着色器玻璃（折射/霜化）每块表面一个 GPU pass，多表面场景帧率不足，
// 当前恒 false：所有平台统一走 BackdropFilter 路径。
// 系统级 Liquid Glass（键盘/分享面板/上下文菜单）由 iOS 26 SDK 构建自动获得。
// 后续可作为实验性选项重新启用着色器路径。

import 'package:flutter/material.dart';
import 'package:liquid_glass_renderer/liquid_glass_renderer.dart';

/// iOS 上的 Liquid Glass 渲染开关与构造器。
final class IosGlass {
  IosGlass._();

  static bool get enabled => false;

  /// 把 [child] 包进一块 iOS Liquid Glass。调用方（GlassSurface）已经处理过
  /// padding/按压反馈；这里只负责材质本身。
  static Widget surface({
    required Widget child,
    bool circle = false,
    bool stadium = false,
    BorderRadius? borderRadius,
    Brightness brightness = Brightness.light,
  }) {
    final shape = circle
        ? const LiquidOval()
        : LiquidRoundedSuperellipse(
            borderRadius: stadium ? 999 : (borderRadius?.topLeft.x ?? 28),
          );
    return LiquidGlassLayer(
      settings: LiquidGlassSettings.ios27Regular(brightness: brightness),
      child: LiquidGlass(shape: shape, child: child),
    );
  }
}