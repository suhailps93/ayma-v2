import 'dart:async';
import 'package:flutter/foundation.dart';

typedef NodeAction<T> = Future<T> Function(DAGContext context);

enum NodeStatus { pending, scheduled, running, succeeded, failed, skipped }

class StartupNode<T> {
  final String id;
  final Set<String> dependencies;
  final NodeAction<T> action;
  final Duration? timeout;
  final bool critical;
  final T? fallback;

  final Completer<T?> _completer = Completer<T?>();
  NodeStatus status = NodeStatus.pending;
  T? result;
  Object? error;

  StartupNode({
    required this.id,
    Set<String>? dependencies,
    required this.action,
    this.timeout,
    this.critical = false,
    this.fallback,
  }) : dependencies = dependencies != null ? Set<String>.from(dependencies) : <String>{};

  Future<T?> get future => _completer.future;

  Future<void> execute(DAGContext context) async {
    status = NodeStatus.running;
    try {
      Future<T> computation = action(context);
      if (timeout != null) {
        computation = computation.timeout(timeout!);
      }
      result = await computation;
      status = NodeStatus.succeeded;
      _completer.complete(result);
    } catch (e, stack) {
      status = NodeStatus.failed;
      error = e;
      if (critical) {
        _completer.completeError(e, stack);
        _completer.future.ignore();
        rethrow;
      } else {
        debugPrint('[StartupDAG] Non-critical node $id failed: $e');
        result = fallback;
        _completer.complete(fallback);
      }
    }
  }
}

class DAGContext {
  final Map<String, dynamic> _results = {};

  void put<T>(String id, T value) => _results[id] = value;
  T get<T>(String id) => _results[id] as T;
  T? getOrNull<T>(String id) => _results[id] as T?;
  bool contains(String id) => _results.containsKey(id);
}

class StartupDAG {
  final Map<String, StartupNode<dynamic>> _nodes = {};

  Map<String, StartupNode<dynamic>> get nodes => _nodes;

  void addNode(StartupNode<dynamic> node) {
    _nodes[node.id] = node;
  }

  void register(StartupNode<dynamic> node) => addNode(node);

  void addEdge(String from, String to) {
    if (_nodes.containsKey(to)) {
      _nodes[to]!.dependencies.add(from);
    }
  }

  /// Validates graph structure and ensures no dependency cycles exist.
  /// Throws [StateError] if cycles or missing dependencies are found.
  void validate() {
    for (final node in _nodes.values) {
      for (final dep in node.dependencies) {
        if (!_nodes.containsKey(dep)) {
          throw StateError('Node ${node.id} depends on nonexistent node $dep');
        }
      }
    }

    final visited = <String, int>{}; // 0 = unvisited, 1 = visiting, 2 = visited
    for (final id in _nodes.keys) {
      visited[id] = 0;
    }

    bool hasCycle(String id) {
      visited[id] = 1;
      for (final dep in _nodes[id]!.dependencies) {
        if (visited[dep] == 1) return true;
        if (visited[dep] == 0 && hasCycle(dep)) return true;
      }
      visited[id] = 2;
      return false;
    }

    for (final id in _nodes.keys) {
      if (visited[id] == 0) {
        if (hasCycle(id)) {
          throw StateError('Cyclic dependency detected in StartupDAG');
        }
      }
    }
  }

  /// Executes the DAG scheduling nodes concurrently as their dependencies resolve.
  /// If [targetNodes] is provided, completes when all [targetNodes] have completed.
  Future<DAGContext> run({Set<String>? targetNodes}) {
    validate();
    final context = DAGContext();
    final completer = Completer<DAGContext>();

    final pendingNodes = Map<String, StartupNode<dynamic>>.from(_nodes);
    final completedNodes = <String>{};
    final runningNodes = <String, Future<void>>{};

    void checkCompletion() {
      if (completer.isCompleted) return;

      if (targetNodes != null) {
        if (targetNodes.every(completedNodes.contains)) {
          completer.complete(context);
        }
      } else if (completedNodes.length == _nodes.length) {
        completer.complete(context);
      }
    }

    void scheduleReadyNodes() {
      if (completer.isCompleted && targetNodes != null) {
        // If targetNodes already satisfied, remaining nodes continue in background
      }

      final ready = <StartupNode<dynamic>>[];
      for (final node in pendingNodes.values) {
        if (node.status == NodeStatus.pending &&
            node.dependencies.every(completedNodes.contains)) {
          ready.add(node);
        }
      }

      for (final node in ready) {
        node.status = NodeStatus.scheduled;
        pendingNodes.remove(node.id);

        final fut = () async {
          try {
            await node.execute(context);
            if (node.result != null) {
              context.put(node.id, node.result);
            }
            completedNodes.add(node.id);
            runningNodes.remove(node.id);
            checkCompletion();
            scheduleReadyNodes();
          } catch (e, stack) {
            completedNodes.add(node.id);
            runningNodes.remove(node.id);
            if (node.critical && !completer.isCompleted) {
              completer.completeError(e, stack);
            } else {
              checkCompletion();
              scheduleReadyNodes();
            }
          }
        }();

        runningNodes[node.id] = fut;
      }

      checkCompletion();
    }

    scheduleReadyNodes();
    return completer.future;
  }
}
