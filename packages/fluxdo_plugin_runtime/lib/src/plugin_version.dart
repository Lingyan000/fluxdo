/// 插件和市场共用的 SemVer 比较，构建号不参与版本优先级。
class PluginVersion implements Comparable<PluginVersion> {
  PluginVersion._(this.numbers, this.prerelease);
  final List<BigInt> numbers;
  final List<String> prerelease;

  static PluginVersion parse(String value) {
    final match = RegExp(
      r'^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$',
    ).firstMatch(value);
    if (match == null) throw const FormatException('插件版本须符合 SemVer');
    final pre = match[4]?.split('.') ?? <String>[];
    for (final item in pre) {
      if (RegExp(r'^\d+$').hasMatch(item) &&
          item.length > 1 &&
          item.startsWith('0')) {
        throw const FormatException('预发布数字标识不能以零开头');
      }
    }
    return PluginVersion._([
      for (var i = 1; i <= 3; i++) BigInt.parse(match[i]!),
    ], pre);
  }

  @override
  int compareTo(PluginVersion other) {
    for (var i = 0; i < numbers.length; i++) {
      final comparison = numbers[i].compareTo(other.numbers[i]);
      if (comparison != 0) return comparison;
    }
    if (prerelease.isEmpty || other.prerelease.isEmpty) {
      return prerelease.isEmpty == other.prerelease.isEmpty
          ? 0
          : prerelease.isEmpty
          ? 1
          : -1;
    }
    for (var i = 0; i < prerelease.length && i < other.prerelease.length; i++) {
      final left = prerelease[i], right = other.prerelease[i];
      final leftNumber = RegExp(r'^\d+$').hasMatch(left)
          ? BigInt.parse(left)
          : null;
      final rightNumber = RegExp(r'^\d+$').hasMatch(right)
          ? BigInt.parse(right)
          : null;
      final int comparison;
      if (leftNumber != null && rightNumber != null) {
        comparison = leftNumber.compareTo(rightNumber);
      } else if ((leftNumber == null) != (rightNumber == null)) {
        comparison = leftNumber == null ? 1 : -1;
      } else {
        comparison = left.compareTo(right);
      }
      if (comparison != 0) return comparison;
    }
    return prerelease.length.compareTo(other.prerelease.length);
  }
}
