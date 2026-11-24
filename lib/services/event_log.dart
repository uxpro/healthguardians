import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config.dart';

/// One step of a check-in, stored in `public.hg_events` (production database).
class HgEvent {
  HgEvent({
    required this.sessionId,
    required this.eventType,
    required this.mode,
    this.question,
    this.answer,
    this.details = const {},
    DateTime? clientTime,
  }) : clientTime = clientTime ?? DateTime.now();

  final String sessionId;

  /// session_started, mood_answer, medication_answer, exercise_demo or session_completed
  final String eventType;

  /// idle, speaking, listening or action
  final String mode;
  final String? question;
  final String? answer;
  final Map<String, Object?> details;
  final DateTime clientTime;

  /// Row for the insert. `user_id` is not sent: the database takes it from the JWT.
  Map<String, Object?> toRow() => {
        'session_id': sessionId,
        'event_type': eventType,
        'mode': mode,
        if (question != null) 'question': question,
        if (answer != null) 'answer': answer,
        'details': details,
        'client_time': clientTime.toUtc().toIso8601String(),
      };
}

enum EventLogStatus {
  /// signed in, nothing sent yet or the last event was saved
  ready,

  /// the last event could not be saved; it is retried with the next one
  failed,

  /// not signed in: events stay on this device only
  offline,
}

/// Where events go. [log] never throws: a check-in must not stop because the network is down.
abstract class EventSink {
  ValueListenable<EventLogStatus> get status;
  Future<void> log(HgEvent event);
}

/// Without an account: keeps the events in memory (shown in debug output). Also used by tests.
class LocalEventLog implements EventSink {
  final List<HgEvent> events = [];
  final _status = ValueNotifier(EventLogStatus.offline);

  @override
  ValueListenable<EventLogStatus> get status => _status;

  @override
  Future<void> log(HgEvent event) async {
    events.add(event);
    debugPrint('event (not saved): ${event.toRow()}');
  }
}

/// Signed in: inserts the events into the production database with the account's JWT.
/// Events that fail are kept (up to [maxPending]) and sent again before the next one.
class SupabaseEventLog implements EventSink {
  SupabaseEventLog(this._client, {this.maxPending = 50});

  final SupabaseClient _client;
  final int maxPending;
  final List<HgEvent> _pending = [];
  final _status = ValueNotifier(EventLogStatus.ready);
  Future<void> _queue = Future.value();

  @override
  ValueListenable<EventLogStatus> get status => _status;

  /// Events not saved yet.
  int get pendingCount => _pending.length;

  @override
  Future<void> log(HgEvent event) {
    // one insert at a time, in order
    _queue = _queue.then((_) => _send(event));
    return _queue;
  }

  Future<void> _send(HgEvent event) async {
    _pending.add(event);
    if (_pending.length > maxPending) _pending.removeAt(0);
    try {
      final rows = [for (final e in _pending) e.toRow()];
      await _client.from(AppConfig.eventsTable).insert(rows);
      _pending.clear();
      _status.value = EventLogStatus.ready;
    } catch (e) {
      debugPrint('event log: $e');
      _status.value = EventLogStatus.failed;
    }
  }
}
