/// Progress, cancellation and business completion for one owned check.
abstract interface class FollowUpdateTask {
  Stream<int> get updatedCounts;

  /// Completes after the task's writes and final notification have settled.
  /// Progress subscription cancellation or pausing must not control this future.
  Future<void> get done;

  void cancel();
}
