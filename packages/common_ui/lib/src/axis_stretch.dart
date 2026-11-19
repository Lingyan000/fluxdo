/// 将有方向的运动量映射为轴向拉伸。满幅时以靠近前端的点为支点，尾部多伸出一些。
/// [travel] 从 -1（向起点）到 1（向终点），支点位置以原长度为单位。
({double amount, double origin}) axisStretch(
  double travel, {
  required double maxStretch,
}) {
  final signed = travel.clamp(-1.0, 1.0);
  return (amount: signed.abs() * maxStretch, origin: .5 + .35 * signed);
}
