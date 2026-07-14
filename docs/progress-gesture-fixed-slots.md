# 进度条长按菜单：固定 8 槽半圆布局

## 问题

进度悬浮条长按弹出的半圆菜单，以前会按「当前启用的按钮数量」重新均分角度和半径：

- 设置页预览与运行时菜单位置左右不一致
- 启用项从 3 个变成 6/8 个时，同一功能会左右漂移
- 左右端项靠近按压死区，需要先往上抬手再左右扫，手感像 BUG

## 方案

进度条长按菜单改为 **固定 8 槽（fixed slots）**：

1. 半圆始终按 8 个槽位均分 `[-π/2, π/2]`
2. 第 `i` 个启用动作永远落在第 `i` 个槽
3. 半径固定为 128（旧版 8 项时的半径），不再随项数缩放
4. 空槽不渲染、不命中
5. 设置页半圆预览与运行时菜单共用 `RadialMenuFixedSlots`

头像等动态径向菜单仍走旧逻辑（按项数均分），不受影响。

## 关键文件

| 文件 | 作用 |
| --- | --- |
| `lib/widgets/common/radial_menu_fixed_slots.dart` | 固定槽几何 / 命中 |
| `lib/widgets/common/radial_long_press_menu.dart` | `fixedSlots` 开关与渲染/命中分支 |
| `lib/pages/topic_detail_page/widgets/topic_progress_gestures.dart` | 进度条长按启用 fixed slots |
| `lib/pages/topic_detail_page/widgets/progress_gesture_menu_settings_page.dart` | 设置预览同步固定槽 |
| `test/widgets/common/radial_menu_fixed_slots_test.dart` | 几何与命中单测 |

## 验收

1. 设置页只选 3 个动作：预览中第 1 项在最左槽，第 2/3 项按 8 槽网格往右排，不会挤在中间。
2. 话题页长按进度悬浮条：菜单位置与设置预览左右一致。
3. 左右端项可直接水平扫中，不需要额外上抬很大角度。
4. 增加到 8 个动作时，前几个动作位置保持不变。
5. 头像长按菜单行为不变。

## 非目标

- 不改动作集合 / 配置存储
- 不改头像径向菜单的动态均分策略
- 不引入新的设置开关（进度条菜单默认固定 8 槽）
