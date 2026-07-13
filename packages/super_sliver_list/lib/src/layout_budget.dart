/// A layout budget controls how much of build time can be used for
/// extent precalculation.
abstract class SuperSliverListLayoutBudget {
  void beginLayout();
  void endLayout();
  bool shouldLayoutNextItem();
  void reset();
}
