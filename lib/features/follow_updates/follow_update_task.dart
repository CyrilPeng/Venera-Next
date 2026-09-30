/// The background checker needs only progress counts and ownership cancellation.
abstract interface class FollowUpdateTask {
  Stream<int> get updatedCounts;
  void cancel();
}
