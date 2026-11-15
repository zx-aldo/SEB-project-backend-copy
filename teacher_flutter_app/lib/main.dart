import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

// Use --dart-define=BACKEND_BASE_URL=http://localhost:8080 when running
const String BASE_URL = String.fromEnvironment('BACKEND_BASE_URL', defaultValue: 'http://localhost:8080');

// --- API Functions ---
Future<List<dynamic>> _fetchGet(String path) async {
  final response = await http.get(Uri.parse('$BASE_URL$path'));
  if (response.statusCode != 200) throw Exception('Error: ${response.statusCode}');
  return jsonDecode(response.body);
}

Future<List<dynamic>> getSessionEvents(String sessionId) => _fetchGet('/session-events?session_id=$sessionId');
Future<dynamic> getCursorEvents(String sessionId, String email) => _fetchGet('/cursors?session_id=$sessionId&email=$email');
Future<dynamic> getKeypressEvents(String sessionId, String email) => _fetchGet('/keypresses?session_id=$sessionId&email=$email');
Future<dynamic> getLogEvents(String sessionId, String email) => _fetchGet('/logs?session_id=$sessionId&email=$email');
Future<List<dynamic>> getDiagnosticSummary(String sessionId) => _fetchGet('/diagnostic-summary?session_id=$sessionId');
Future<dynamic> getDiagnosticsEvents(String sessionId, String email) => _fetchGet('/diagnostics?session_id=$sessionId&email=$email&limit=1000');

// --- Helpers ---
String formatTimestamp(String ts) {
  try {
    final dt = DateTime.parse(ts).toLocal();
    return '${dt.year} ${_month(dt.month)} ${dt.day}, ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}:${dt.second.toString().padLeft(2, '0')}';
  } catch (_) { return ts; }
}

String _month(int m) => ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'][m - 1];

Color statusColor(String? status) {
  switch (status?.toUpperCase()) {
    case 'OK': return const Color(0xFF16A34A);
    case 'WARN': return const Color(0xFFCA8A04);
    case 'CRIT': return const Color(0xFFDC2626);
    default: return const Color(0xFF64748B);
  }
}

Color statusBg(String? status) {
  switch (status?.toUpperCase()) {
    case 'OK': return const Color(0xFFDCFCE7);
    case 'WARN': return const Color(0xFFFEF9C3);
    case 'CRIT': return const Color(0xFFFEE2E2);
    default: return const Color(0xFFF1F5F9);
  }
}

String worstStatus(List<dynamic> items) {
  final statuses = items.map((i) => (i['status'] ?? '').toString().toUpperCase()).toList();
  if (statuses.contains('CRIT')) return 'CRIT';
  if (statuses.contains('WARN')) return 'WARN';
  if (statuses.contains('OK')) return 'OK';
  return items.isNotEmpty ? (items[0]['status'] ?? '') : '';
}

const int GAP_MS = 15000;
const int ACTIVE_MS = 5000;

List<Map<String, dynamic>> buildIntervals(List<dynamic> items) {
  final sorted = items.reversed.toList();
  if (sorted.isEmpty) return [];

  final lastMs = DateTime.parse(sorted.last['received_at']).millisecondsSinceEpoch;
  final lastEnd = DateTime.fromMillisecondsSinceEpoch(lastMs + ACTIVE_MS).toIso8601String();

  final raw = <Map<String, dynamic>>[];
  for (int i = 0; i < sorted.length; i++) {
    final cur = sorted[i];
    final curMs = DateTime.parse(cur['received_at']).millisecondsSinceEpoch;

    if (i == sorted.length - 1) {
      raw.add({'status': cur['status'], 'details': cur['details'], 'from': cur['received_at'], 'to': lastEnd, 'isGap': false});
    } else {
      final next = sorted[i + 1];
      final gap = DateTime.parse(next['received_at']).millisecondsSinceEpoch - curMs;
      if (gap > GAP_MS) {
        final activeEnd = DateTime.fromMillisecondsSinceEpoch(curMs + ACTIVE_MS).toIso8601String();
        raw.add({'status': cur['status'], 'details': cur['details'], 'from': cur['received_at'], 'to': activeEnd, 'isGap': false});
        raw.add({'status': null, 'details': null, 'from': activeEnd, 'to': next['received_at'], 'isGap': true});
      } else {
        raw.add({'status': cur['status'], 'details': cur['details'], 'from': cur['received_at'], 'to': next['received_at'], 'isGap': false});
      }
    }
  }

  final merged = <Map<String, dynamic>>[];
  for (final seg in raw) {
    if (merged.isNotEmpty && !seg['isGap'] && !merged.last['isGap'] &&
        seg['status'] == merged.last['status'] &&
        jsonEncode(seg['details']) == jsonEncode(merged.last['details'])) {
      merged.last['to'] = seg['to'];
    } else {
      merged.add(Map.from(seg));
    }
  }
  return merged;
}

// --- Main App ---
void main() => runApp(const ExamMonitorApp());

class ExamMonitorApp extends StatelessWidget {
  const ExamMonitorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Teacher Monitoring',
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0F111A),
        primaryColor: Colors.blue,
      ),
      home: const App(),
    );
  }
}

class App extends StatefulWidget {
  const App({super.key});
  @override
  State<App> createState() => _AppState();
}

class _AppState extends State<App> {
  String _sessionId = '';
  String? _currentEmail;

  @override
  Widget build(BuildContext context) {
    if (_sessionId.isEmpty) {
      return SessionEntry(onSubmit: (id) => setState(() => _sessionId = id));
    }
    if (_currentEmail != null) {
      return StudentDetail(
        email: _currentEmail!,
        sessionId: _sessionId,
        onBack: () => setState(() => _currentEmail = null),
      );
    }
    return StudentList(
      sessionId: _sessionId,
      onStudentClick: (email) => setState(() => _currentEmail = email),
    );
  }
}

// --- Shared UI ---
class AppCard extends StatelessWidget {
  final Widget child;
  final String title;
  final Widget? headerAction;
  const AppCard({super.key, required this.title, required this.child, this.headerAction});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Card(
        color: const Color(0xFF1E1E2E),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: const BoxDecoration(
                border: Border(bottom: BorderSide(color: Color(0xFF333333))),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(title, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                  if (headerAction != null) headerAction!,
                ],
              ),
            ),
            Expanded(child: child),
          ],
        ),
      ),
    );
  }
}

// --- Session Entry ---
class SessionEntry extends StatefulWidget {
  final Function(String) onSubmit;
  const SessionEntry({super.key, required this.onSubmit});
  @override
  State<SessionEntry> createState() => _SessionEntryState();
}

class _SessionEntryState extends State<SessionEntry> {
  final _controller = TextEditingController();
  String _error = '';

  void _submit() {
    if (_controller.text.trim().isEmpty) {
      setState(() => _error = 'Session ID is required');
      return;
    }
    setState(() => _error = '');
    widget.onSubmit(_controller.text);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: SizedBox(
          width: 400,
          child: AppCard(
            title: 'Teacher Monitoring Dashboard',
            child: Padding(
              padding: const EdgeInsets.all(24.0),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text('Session ID', style: TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _controller,
                    decoration: InputDecoration(
                      hintText: 'Enter session ID',
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(4)),
                    ),
                  ),
                  if (_error.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(_error, style: const TextStyle(color: Colors.red, fontSize: 12)),
                  ],
                  const SizedBox(height: 16),
                  ElevatedButton(
                    onPressed: _submit,
                    child: const Text('Enter Session'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// --- Student List ---
class StudentList extends StatefulWidget {
  final String sessionId;
  final Function(String) onStudentClick;
  const StudentList({super.key, required this.sessionId, required this.onStudentClick});
  @override
  State<StudentList> createState() => _StudentListState();
}

class _StudentListState extends State<StudentList> {
  List<dynamic> _students = [];
  Map<String, dynamic> _diagSummary = {};
  bool _loading = true;
  String? _error;
  Timer? _timer;
  String _prevStudentsJson = '';

  @override
  void initState() {
    super.initState();
    _fetchStudents();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _fetchStudents());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _fetchStudents() async {
    try {
      final results = await Future.wait([
        getSessionEvents(widget.sessionId),
        getDiagnosticSummary(widget.sessionId),
      ]);
      final eventsData = results[0];
      final summaryData = results[1];

      final currentJson = jsonEncode(eventsData);
      if (currentJson != _prevStudentsJson) {
        setState(() {
          _students = eventsData;
          _prevStudentsJson = currentJson;
        });
      }

      final Map<String, dynamic> summaryMap = {};
      for (var s in summaryData) { summaryMap[s['email']] = s; }
      setState(() { _diagSummary = summaryMap; _error = null; });
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _getEventTypeName(String type) {
    switch (type) {
      case 'cursor_position': return 'Cursor Movement';
      case 'key_press': return 'Keypress';
      case 'log': return 'System Log';
      default: return type;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    
    return Scaffold(
      body: AppCard(
        title: 'Student Monitoring',
        child: _error != null
            ? Center(child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(_error!, style: const TextStyle(color: Colors.red)),
                  const SizedBox(height: 16),
                  ElevatedButton(onPressed: _fetchStudents, child: const Text('Retry')),
                ],
              ))
            : _students.isEmpty
                ? const Center(child: Text('No students found', style: TextStyle(color: Colors.grey)))
                : ListView.builder(
                    itemCount: _students.length,
                    itemBuilder: (context, index) {
                      final student = _students[index];
                      final email = student['email'];
                      final diag = _diagSummary[email];
                      return ListTile(
                        onTap: () => widget.onStudentClick(email),
                        title: Row(
                          children: [
                            Text(email, style: const TextStyle(fontWeight: FontWeight.bold)),
                            if (diag != null) ...[
                              const SizedBox(width: 8),
                              if (diag['crit'] > 0) _buildDot(diag['crit'], 'CRIT'),
                              if (diag['warn'] > 0) _buildDot(diag['warn'], 'WARN'),
                              if (diag['ok'] > 0) _buildDot(diag['ok'], 'OK'),
                            ],
                          ],
                        ),
                        subtitle: Text(_getEventTypeName(student['event_type'])),
                        trailing: Text(formatTimestamp(student['event_time']), style: const TextStyle(fontSize: 12)),
                      );
                    },
                  ),
      ),
    );
  }

  Widget _buildDot(int count, String status) {
    return Container(
      margin: const EdgeInsets.only(right: 4),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(color: statusBg(status), borderRadius: BorderRadius.circular(10)),
      child: Text('$count', style: TextStyle(color: statusColor(status), fontSize: 12)),
    );
  }
}

// --- Student Detail ---
class StudentDetail extends StatefulWidget {
  final String email;
  final String sessionId;
  final VoidCallback onBack;
  const StudentDetail({super.key, required this.email, required this.sessionId, required this.onBack});
  @override
  State<StudentDetail> createState() => _StudentDetailState();
}

class _StudentDetailState extends State<StudentDetail> {
  Map<String, List<dynamic>> _events = {'cursor': [], 'keypress': [], 'log': [], 'diagnostic': []};
  bool _loading = true;
  String? _error;
  Timer? _timer;
  String _activeTab = 'events';
  Map<String, bool> _openCodes = {};

  @override
  void initState() {
    super.initState();
    _fetchAllEvents();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _fetchAllEvents());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _fetchAllEvents() async {
    try {
      final results = await Future.wait([
        getCursorEvents(widget.sessionId, widget.email),
        getKeypressEvents(widget.sessionId, widget.email),
        getLogEvents(widget.sessionId, widget.email),
        getDiagnosticsEvents(widget.sessionId, widget.email),
      ]);

      setState(() {
        // Assuming your backend wraps the lists in {"data": [...]}
        _events = {
          'cursor': results[0]['data'] ?? [],
          'keypress': results[1]['data'] ?? [],
          'log': results[2]['data'] ?? [],
          'diagnostic': results[3]['data'] ?? [],
        };
        _error = null;
      });
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Scaffold(body: Center(child: CircularProgressIndicator()));

    return Scaffold(
      body: AppCard(
        title: 'Details for ${widget.email}',
        headerAction: TextButton.icon(
          onPressed: widget.onBack,
          icon: const Icon(Icons.arrow_back),
          label: const Text('Back'),
        ),
        child: _error != null
            ? Center(child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(_error!, style: const TextStyle(color: Colors.red)),
                  const SizedBox(height: 16),
                  ElevatedButton(onPressed: _fetchAllEvents, child: const Text('Retry')),
                ],
              ))
            : Column(
                children: [
                  // Tabs
                  Row(
                    children: [
                      _buildTab('events', 'Events'),
                      _buildTab('diagnostics', 'Diagnostics'),
                    ],
                  ),
                  Expanded(
                    child: _activeTab == 'events' ? _buildEventsTab() : _buildDiagnosticsTab(),
                  ),
                ],
              ),
      ),
    );
  }

  Widget _buildTab(String id, String title) {
    final isActive = _activeTab == id;
    return Expanded(
      child: InkWell(
        onTap: () => setState(() => _activeTab = id),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: isActive ? Colors.blue : Colors.transparent, width: 2)),
          ),
          child: Text(title, textAlign: TextAlign.center, style: TextStyle(color: isActive ? Colors.blue : Colors.grey)),
        ),
      ),
    );
  }

  Widget _buildEventsTab() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _buildCollapsibleSection('Cursor Movements events', _events['cursor']!, (e) => 'Position: (${e['x']}, ${e['y']})'),
        _buildCollapsibleSection('Keypresses events', _events['keypress']!, (e) {
          final mods = (e['modifiers'] as List).isNotEmpty ? ' (${e['modifiers'].join(', ')})' : '';
          return 'Key: ${e['key_name']}$mods';
        }),
        _buildCollapsibleSection('System Logs events', _events['log']!, (e) => '${e['level']}: ${e['message']}'),
        if (_events['cursor']!.isEmpty && _events['keypress']!.isEmpty && _events['log']!.isEmpty)
          const Padding(
            padding: EdgeInsets.all(32),
            child: Text('No events recorded for this student yet.', textAlign: TextAlign.center, style: TextStyle(color: Colors.grey)),
          ),
      ],
    );
  }

  Widget _buildCollapsibleSection(String title, List<dynamic> items, String Function(dynamic) textBuilder) {
    return ExpansionTile(
      title: Text(title, style: const TextStyle(fontSize: 16)),
      initiallyExpanded: true,
      children: items.isEmpty
          ? [const Padding(padding: EdgeInsets.all(16), child: Text('No data recorded', style: TextStyle(color: Colors.grey)))]
          : items.map((e) => ListTile(
              title: Text(textBuilder(e)),
              trailing: Text(formatTimestamp(e['ts']), style: const TextStyle(fontSize: 12)),
            )).toList(),
    );
  }

  Widget _buildDiagnosticsTab() {
    final List<dynamic> diagnostics = _events['diagnostic']!;
    if (diagnostics.isEmpty) return const Center(child: Text('No diagnostics recorded', style: TextStyle(color: Colors.grey)));

    final Map<String, List<dynamic>> grouped = {};
    for (var item in diagnostics) {
      grouped.putIfAbsent(item['code'], () => []).add(item);
    }

    final summary = {'CRIT': 0, 'WARN': 0, 'OK': 0};
    grouped.forEach((_, items) {
      final w = worstStatus(items);
      if (summary.containsKey(w)) summary[w] = summary[w]! + 1;
    });

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Wrap(
          spacing: 8,
          children: [
            if (summary['CRIT']! > 0) _buildBadge('CRIT: ${summary['CRIT']}', 'CRIT'),
            if (summary['WARN']! > 0) _buildBadge('WARN: ${summary['WARN']}', 'WARN'),
            if (summary['OK']! > 0) _buildBadge('OK: ${summary['OK']}', 'OK'),
          ],
        ),
        const SizedBox(height: 16),
        ...grouped.entries.map((entry) {
          final code = entry.key;
          final items = entry.value;
          final worst = worstStatus(items);
          final intervals = buildIntervals(items);
          final isOpen = _openCodes[code] ?? false;

          return ExpansionTile(
            title: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(code),
                _buildBadge(worst, worst),
              ],
            ),
            initiallyExpanded: isOpen,
            onExpansionChanged: (val) => setState(() => _openCodes[code] = val),
            children: [
              if (isOpen)
                ...intervals.map((interval) => ListTile(
                  title: interval['isGap']
                      ? const Text('no data', style: TextStyle(fontStyle: FontStyle.italic, color: Colors.grey))
                      : Row(
                          children: [
                            _buildBadge(interval['status'] ?? '', interval['status']),
                            const SizedBox(width: 8),
                            Expanded(child: Text(jsonEncode(interval['details']), style: const TextStyle(fontSize: 12))),
                          ],
                        ),
                  trailing: Text(
                    '${formatTimestamp(interval['from'])} — ${formatTimestamp(interval['to'])}',
                    style: const TextStyle(fontSize: 12),
                  ),
                )),
            ],
          );
        }),
      ],
    );
  }

  Widget _buildBadge(String text, String status) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(color: statusBg(status), borderRadius: BorderRadius.circular(4)),
      child: Text(text, style: TextStyle(color: statusColor(status), fontWeight: FontWeight.bold, fontSize: 12)),
    );
  }
}