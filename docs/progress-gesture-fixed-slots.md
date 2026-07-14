# 进度条长按菜单：固定 8 坑半圆布局

## 问题

进度悬浮条长按弹出的半圆菜单，以前会按「当前启用的按钮数量」重新均分角度和半径，并把启用项**自动挤齐**到连续位置：

- 设置页预览与运行时菜单位置左右不一致
- 启用项从 3 个变成 6/8 个时，同一功能会左右漂移
- 用户无法把按钮固定到指定坑位（例如只要最左和最右）
- 左右端项靠近按压死区，需要先往上抬手再左右扫

## 方案

进度条长按菜单改为 **固定 8 坑（fixed pits）**：

1. 半圆始终按 8 个坑位均分 `[-π/2, π/2]`，半径固定 128
2. 配置是长度恒为 8 的稀疏数组：`null` = 空坑
3. **第 i 个坑的动作永远在第 i 坑**；空坑不渲染、不命中，也不把后面的按钮挤到前面
4. 用户在设置页拖动到指定坑（目标有动作则交换），点 + 填入最左空坑，拖到中央删除
5. 设置页半圆预览与运行时菜单共用 `RadialMenuFixedSlots`

头像等动态径向菜单仍走旧逻辑（按项数均分），不受影响。

## 存储

- key: `pref_progress_gesture_menu_actions`
- 新格式：`StringList` 固定 8 项，空串 = 空坑
- 旧稠密列表（无空串）：迁移为左对齐填入前 N 坑，剩余空坑保留

## 关键文件

| 文件 | 作用 |
| --- | --- |
| `lib/widgets/common/radial_menu_fixed_slots.dart` | 固定坑几何 / 最近坑 / 占用命中 |
| `lib/widgets/common/radial_long_press_menu.dart` | `fixedSlots` + `itemSlots` 渲染/命中 |
| `lib/providers/preferences_provider.dart` | 稀疏 8 坑读写与规范化 |
| `lib/pages/topic_detail_page/widgets/topic_progress_gestures.dart` | 运行时按坑位弹出 |
| `lib/pages/topic_detail_page/widgets/progress_gesture_menu_settings_page.dart` | 设置预览与拖坑 |
| `test/widgets/common/radial_menu_fixed_slots_test.dart` | 几何与命中单测 |

## 验收

1. 设置页只放 3 个动作到坑 0/3/7：预览与运行时左右一致，中间空坑不挤齐。
2. 把最左按钮拖到最右空坑：最左变空、最右出现该按钮，其它坑不动。
3. 左右端坑可直接水平扫中。
4. 头像长按菜单行为不变。

## 非目标

- 不改动作集合本身
- 不改头像径向菜单的动态均分策略
- 不引入新的设置开关（进度条菜单默认固定 8 坑）
