extension FutureExt<T> on Future<T> {
  /// Wrap the future to make sure it will return at least the duration.
  Future<T> minTime(Duration duration) async {
    var res = await Future.wait([this, Future.delayed(duration)]);
    return res[0];
  }
}
