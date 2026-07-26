import 'package:flutter/physics.dart';
import 'package:m3e_ui/m3e_ui.dart';

/// 首页运动系统统一弹簧(临界阻尼,settle ~250ms):顶区列表吸附、
/// 工具段吸附、分类抽屉 settle、胶囊 morph 全部同族 —— 且所有收尾
/// 动画**继承松手/上游速度**(此前全是零初速的罐头 easeOutCubic,
/// 跟手段与动画段之间有速度断层,是"不够丝滑"的头号来源)。
///
/// 非 [M3eMotion] 六档 token(最近的 slowEffects=800 收尾更急),
/// 是项目自调参数;用 [M3eSpring] 只为统一定义与派生口径。
const M3eSpring kHeaderMotionSpring = M3eSpring(
  dampingRatio: 1.0,
  stiffness: 500.0,
);

/// [kHeaderMotionSpring] 的 SpringSimulation 消费形态。
final SpringDescription kHeaderSpringDescription =
    kHeaderMotionSpring.description;
