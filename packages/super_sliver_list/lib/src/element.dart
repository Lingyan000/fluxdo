import "package:flutter/rendering.dart";
import "package:flutter/widgets.dart";

import "extent_manager.dart";
import "render_object.dart";
import "super_sliver_list.dart";

abstract class MeasuringRenderSliverBoxChildManager
    extends RenderSliverBoxChildManager {
  double measureExtentForItem(int index, SliverConstraints constraints);

  ExtentManager get extentManager;
}

class SuperSliverMultiBoxAdaptorElement extends SliverMultiBoxAdaptorElement
    implements MeasuringRenderSliverBoxChildManager, ExtentManagerDelegate {
  SuperSliverMultiBoxAdaptorElement(
    SuperSliverList widget, {
    required super.replaceMovedChildren,
  }) : super(widget) {
    _extentManager = ExtentManager(delegate: this);
    _currentController = widget.listController;
    _currentController?.setDelegate(_extentManager);
  }

  @override
  RenderSuperSliverList get renderObject =>
      super.renderObject as RenderSuperSliverList;

  @override
  void onMarkNeedsLayout() {
    renderObject.markNeedsLayout();
  }

  @override
  double estimateExtentForItem(int? index) {
    return renderObject.estimateExtentForItem(index);
  }

  @override
  double getOffsetToReveal(
    int index,
    double alignment, {
    required bool estimationOnly,
    Rect? rect,
  }) {
    return renderObject.getOffsetToReveal(
      index,
      alignment,
      estimationOnly: estimationOnly,
      rect: rect,
    );
  }

  ListController? _currentController;

  @override
  void update(covariant SuperSliverList newWidget) {
    final childCountBefore = childCount;
    super.update(newWidget);
    if (childCountBefore != childCount) {
      renderObject.markNeedsLayout();
    }
    if (_currentController != newWidget.listController) {
      _currentController?.unsetDelegate(_extentManager);
      _currentController = newWidget.listController;
      _currentController?.setDelegate(_extentManager);
    }
  }

  @override
  void deactivate() {
    super.deactivate();
    _currentController?.unsetDelegate(_extentManager);
    _currentController = null;
  }

  @override
  double measureExtentForItem(int index, SliverConstraints constraints) {
    _createTemporaryChild(index);
    final renderObject = _tempRenderObject! as RenderBox;
    renderObject.layout(constraints.asBoxConstraints(), parentUsesSize: true);
    final extent = constraints.axis == Axis.vertical
        ? renderObject.size.height
        : renderObject.size.width;
    removeTempElement();
    return extent;
  }

  late final ExtentManager _extentManager;

  @override
  ExtentManager get extentManager => _extentManager;

  int? _tempSlot;
  Element? _tempElement;
  RenderObject? _tempRenderObject;

  void _createTemporaryChild(int index) {
    assert(_tempElement == null);
    assert(_tempRenderObject == null);
    assert(_tempSlot == null);
    owner!.buildScope(this, () {
      final SliverMultiBoxAdaptorWidget adaptorWidget =
          widget as SliverMultiBoxAdaptorWidget;
      _tempSlot = index;
      _tempElement = updateChild(
        null,
        adaptorWidget.delegate.build(this, index),
        index,
      );
      assert(_tempRenderObject != null);
      _tempSlot = null;
    });
  }

  @override
  void insertRenderObjectChild(covariant RenderObject child, int slot) {
    if (_tempSlot == slot) {
      _tempRenderObject = child;
      renderObject.adoptChild(child);
    } else {
      super.insertRenderObjectChild(child, slot);
    }
  }

  @override
  void removeRenderObjectChild(
      covariant RenderObject child, covariant int slot) {
    if (_tempRenderObject == child) {
      // Nothing to do here - most importantly don't call super as it doesn't
      // know about the render object and would throw an assertion.
    } else {
      super.removeRenderObjectChild(child, slot);
    }
  }

  void removeTempElement() {
    assert(_tempElement != null);
    assert(_tempRenderObject != null);

    // ignore: invalid_use_of_protected_member
    renderObject.dropChild(_tempRenderObject!);

    deactivateChild(_tempElement!);
    _tempRenderObject = null;
    _tempElement = null;
  }

  @override
  void didAdoptChild(RenderBox child) {
    if (_tempRenderObject != child) {
      super.didAdoptChild(child);
    }
  }
}
