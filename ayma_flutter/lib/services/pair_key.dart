/// The deterministic id shared by a `matches` doc and its `dm_threads` doc
/// (§5.7, §6.6): the two uids sorted and joined with `__`. Same rule on the
/// backend (`pair_key.sorted_pair_key`).
String sortedPairKey(String a, String b) {
  final lo = a.compareTo(b) <= 0 ? a : b;
  final hi = a.compareTo(b) <= 0 ? b : a;
  return '${lo}__$hi';
}
