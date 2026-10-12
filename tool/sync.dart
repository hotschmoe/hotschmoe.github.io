// Builds every game in games.json from its source repo and assembles the
// deployable site in _site/.
//
//   dart run tool/sync.dart                 build what is stale, assemble _site/
//   dart run tool/sync.dart --check         report stale games, exit 1 if any
//   dart run tool/sync.dart --force         rebuild everything
//   dart run tool/sync.dart --only gemtd    restrict to the listed slugs (comma separated)
//
// A game is stale when its repo's head moved or its manifest entry changed.
// Sources and builds are cached under .cache/, so unchanged games cost one API call.
import 'dart:convert';
import 'dart:io';

const siteFiles = ['index.html', 'tools.html', 'favicon.ico', 'assets', 'css', 'js'];
const cacheDir = '.cache';
const siteDir = '_site';

late final Map<String, String> toolEnv;

Future<void> main(List<String> args) async {
  final check = args.contains('--check');
  final force = args.contains('--force');
  final onlyIdx = args.indexOf('--only');
  final only = onlyIdx >= 0 ? args[onlyIdx + 1].split(',').toSet() : null;

  final home = Platform.environment['HOME'] ?? '';
  toolEnv = {
    'PATH': [
      '$home/.cargo/bin',
      '$home/development/flutter/bin',
      Platform.environment['PATH'] ?? '',
    ].join(':'),
  };

  final games = (jsonDecode(File('games.json').readAsStringSync()) as List)
      .cast<Map<String, dynamic>>();
  final failures = <String>[];
  final stale = <String>[];

  for (final game in games) {
    final slug = game['slug'] as String;
    if (only != null && !only.contains(slug)) continue;
    try {
      final state = await _state(game);
      final tag = switch (state) { _Fresh() => 'fresh', _Stale s => 'STALE (${s.why})' };
      stdout.writeln('${slug.padRight(26)} $tag');
      if (state is _Stale) stale.add(slug);
      if (!check && (force || state is _Stale)) await _build(game);
    } catch (e) {
      stderr.writeln('${slug.padRight(26)} FAILED: $e');
      failures.add(slug);
    }
  }

  if (check) exit(stale.isEmpty && failures.isEmpty ? 0 : 1);

  await _assemble(games);
  if (failures.isNotEmpty) {
    stderr.writeln('failed: ${failures.join(', ')} (previous builds, if any, were kept)');
    exit(1);
  }
}

sealed class _GameState {}

class _Fresh extends _GameState {}

class _Stale extends _GameState {
  _Stale(this.why);
  final String why;
}

String _fingerprint(Map<String, dynamic> game) => jsonEncode(
      {for (final k in ['repo', 'ref', 'build', 'out', 'requires']) k: game[k]});

File _infoFile(String slug) => File('$cacheDir/builds/$slug/.build-info.json');

Future<_GameState> _state(Map<String, dynamic> game) async {
  final slug = game['slug'] as String;
  final info = _infoFile(slug);
  if (!info.existsSync()) return _Stale('never built');
  final built = jsonDecode(info.readAsStringSync()) as Map<String, dynamic>;
  if (built['fingerprint'] != _fingerprint(game)) return _Stale('manifest changed');
  final head = await _remoteHead(game);
  if (built['commit'] != head) {
    return _Stale('${(built['commit'] as String).substring(0, 7)} -> ${head.substring(0, 7)}');
  }
  return _Fresh();
}

Future<String> _remoteHead(Map<String, dynamic> game) async {
  final out = await _run(
      'gh', ['api', 'repos/${game['repo']}/commits/${game['ref'] ?? 'HEAD'}', '--jq', '.sha']);
  return out.trim();
}

Future<String> _run(String exe, List<String> args,
    {String? cwd, Map<String, String>? env, bool stream = false}) async {
  if (stream) {
    final p = await Process.start(exe, args,
        workingDirectory: cwd, environment: env, mode: ProcessStartMode.inheritStdio);
    final code = await p.exitCode;
    if (code != 0) throw '$exe ${args.join(' ')} exited $code';
    return '';
  }
  final r = await Process.run(exe, args, workingDirectory: cwd, environment: env);
  if (r.exitCode != 0) throw '$exe ${args.join(' ')} exited ${r.exitCode}: ${r.stderr}';
  return r.stdout as String;
}

Future<void> _build(Map<String, dynamic> game) async {
  final slug = game['slug'] as String;
  final src = Directory('$cacheDir/src/$slug');
  final ref = game['ref'] as String?;
  final repo = game['repo'] as String;

  if (!src.existsSync()) {
    src.parent.createSync(recursive: true);
    await _run('gh', ['repo', 'clone', repo, src.path, '--', '--depth', '1', '-q']);
  }
  await _run('git', ['fetch', '--depth', '1', '-q', 'origin', ref ?? 'HEAD'], cwd: src.path);
  await _run('git', ['checkout', '-q', '-f', '--detach', 'FETCH_HEAD'], cwd: src.path);
  final commit = (await _run('git', ['rev-parse', 'HEAD'], cwd: src.path)).trim();

  final out = Directory('${src.path}/${game['out']}');
  if (out.existsSync()) out.deleteSync(recursive: true);

  final base = '/projects/$slug/';
  final command = (game['build'] as String).replaceAll('{base}', base);
  stdout.writeln('  building $slug @ ${commit.substring(0, 7)}: $command');
  await _run('bash', ['-ec', command],
      cwd: src.path,
      env: toolEnv,
      stream: true);
  if (!out.existsSync()) throw 'build produced no ${game['out']}';

  final dest = Directory('$cacheDir/builds/$slug');
  if (dest.existsSync()) dest.deleteSync(recursive: true);
  dest.parent.createSync(recursive: true);
  await _run('cp', ['-r', out.path, dest.path]);

  final visibility = (await _run(
          'gh', ['repo', 'view', repo, '--json', 'isPrivate', '--jq', '.isPrivate']))
      .trim();
  _infoFile(slug).writeAsStringSync(jsonEncode({
    'fingerprint': _fingerprint(game),
    'commit': commit,
    'built_at': DateTime.now().toUtc().toIso8601String(),
    'private': visibility != 'false',
  }));
}

Future<void> _assemble(List<Map<String, dynamic>> games) async {
  final site = Directory(siteDir);
  if (site.existsSync()) site.deleteSync(recursive: true);
  site.createSync();
  for (final f in siteFiles) {
    if (FileSystemEntity.typeSync(f) == FileSystemEntityType.notFound) continue;
    await _run('cp', ['-r', f, '$siteDir/$f']);
  }

  final projects = <Map<String, dynamic>>[];
  for (final game in games) {
    final slug = game['slug'] as String;
    final built = Directory('$cacheDir/builds/$slug');
    if (!built.existsSync()) continue;
    final dest = '$siteDir/projects/$slug';
    Directory(dest).parent.createSync(recursive: true);
    await _run('cp', ['-r', built.path, dest]);
    File('$dest/.build-info.json').deleteSync();

    final info = jsonDecode(_infoFile(slug).readAsStringSync()) as Map<String, dynamic>;
    projects.add({
      'id': projects.length + 1,
      'slug': slug,
      'kind': game['kind'],
      'title': game['title'],
      'tagline': game['tagline'],
      'description': game['description'],
      'tech': game['tech'],
      'path': '/projects/$slug/',
      'github': info['private'] == true ? null : 'https://github.com/${game['repo']}',
      'requires': game['requires'],
      'commit': (info['commit'] as String).substring(0, 7),
      'built_at': info['built_at'],
    });
  }
  const encoder = JsonEncoder.withIndent('  ');
  final json = '${encoder.convert(projects)}\n';
  File('$siteDir/projects.json').writeAsStringSync(json);
  stdout.writeln('assembled $siteDir/ with ${projects.length} projects');
}
