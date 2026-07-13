## 0.4.1

* Fix missing propagation of `rect` inside `RenderViewportExt.getOffsetToRevealExt`.
* Add missing constructors in `SuperSliverList` to have `SliverList` parity.

## 0.4.0

* BREAKING: Changed signature of `ExtentEstimationProvider` where the `index` is now nullable.
* Added `layoutKeptAliveChildren` argument to `SuperSliverList`.
* Improved performance with very large lists (millions of items).
* Bugfixes

## 0.3.0

* Fixed layout exception for shrink-wrapped lists.
* BREAKING: ExtentPrecalculationContext.viewportMainAxisExtent is now nullable

## 0.2.2

* Fixed exception when calling markAllDirty on empty list.

## 0.2.1

* Prevent overscroll when jumping and animating to items at the edge with alignment that would otherwise cause overscroll. For example jumping to the first item with `alignment: 1.0` or jumping to the last item with `alignment: 0.0` should no longer cause overscroll.

## 0.2.0

* Added `visibleRange` and `unobstructedVisibleRange` properties to `ListController`.
* Layout fixes.
* Renamed `ExtentController` to `ListController`.

## 0.2.0-dev.2

* Introduced the concept of child obstruction extent. This is a property that
  can be set on Sliver geometry and allows for reliable positioning of items
  in slivers that are wrapped in a sticky header sliver.
* Added sticky headers to example.

## 0.2.0-dev.1

This is a major update and a complete rewrite of `SuperSliverList`.
* Added `SuperListView` as a convenient drop-in replacement for `ListView`.
* Added ability to jump / animate to specific item using `ExtentController`.
* Added ability to asynchronously precompute item extents using `ExtentPrecalculationPolicy`.
* Comprehensive test coverage.

## 0.0.8

* Fixed problem when accessing layout offset from a LayoutBuilder child widget.

## 0.0.7

* Fix inserted children not being build properly.

## 0.0.6

* Bug fixes

## 0.0.5

* Bug fixes

## 0.0.4

* Bug fixes

## 0.0.3

* Various bug fixes and improvements

## 0.0.2

* Various bug fixes

## 0.0.1

* Initial release


