// Copyright 2017 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:args/args.dart';
import 'package:path/path.dart' as path;
import 'package:http/http.dart' as http;

const String CHROMIUM_REPO =
    'https://chromium.googlesource.com/external/github.com/flutter/flutter';
const String GITHUB_REPO = 'https://github.com/flutter/flutter.git';
const String MINGIT_FOR_WINDOWS_URL = 'https://storage.googleapis.com/flutter_infra/mingit/'
  '603511c649b00bbef0a6122a827ac419b656bc19/mingit.zip';

/// The type of the process runner function.  This allows us to
/// inject a fake process runner into the ArchiveCreator for tests.
typedef ProcessResult ProcessRunner(
  String executable,
  List<String> arguments, {
  String workingDirectory,
  Map<String, String> environment,
  bool includeParentEnvironment,
  bool runInShell,
  Encoding stdoutEncoding,
  Encoding stderrEncoding,
});

/// Error class for when a process fails to run, so we can catch
/// it and provide something more readable than a stack trace.
class ProcessFailedException extends Error {
  ProcessFailedException([this.message, this.exitCode]);

  String message = '';
  int exitCode = 0;

  @override
  String toString() => message;
}

/// Creates a pre-populated Flutter archive from a git repo.
class ArchiveCreator {
  /// [tmpDir] is the directory to use for creating the archive.  Will place
  /// several GiB of data there, so it should have available space.
  /// [outputFile] is the name of the output archive. It should end in either
  /// ".tar.xz" or ".zip".
  /// The runner argument is used to inject a mock of [Process.runSync] for
  /// testing purposes.
  ArchiveCreator(this.tmpDir, this.outputFile, {ProcessRunner runner})
      : assert(outputFile.path.toLowerCase().endsWith('.zip') ||
            outputFile.path.toLowerCase().endsWith('.tar.xz')),
        flutterRoot = new Directory(path.join(tmpDir.path, 'flutter')),
        _runner = runner ?? Process.runSync {
    flutter = path.join(
      flutterRoot.absolute.path,
      'bin',
      Platform.isWindows ? 'flutter.bat' : 'flutter',
    );
    environment = new Map<String, String>.from(Platform.environment);
    environment['PUB_CACHE'] = path.join(flutterRoot.absolute.path, '.pub-cache');
  }

  final Directory flutterRoot;
  final Directory tmpDir;
  final File outputFile;
  final ProcessRunner _runner;
  String flutter;
  final String git = Platform.isWindows ? 'git.bat' : 'git';
  final String zip = Platform.isWindows ? '7za.exe' : 'zip';
  final String tar = Platform.isWindows ? 'tar.exe' : 'tar';
  final Uri minGitUri = Uri.parse(MINGIT_FOR_WINDOWS_URL);
  Map<String, String> environment;

  /// Performs all of the steps needed to create an archive.
  Future<Null> createArchive(String revision) async {
    checkoutFlutter(revision);
    await installMinGitIfNeeded();
    populateCaches();
    archiveFiles();
  }

  /// Clone the Flutter repo and make sure that the git environment is sane
  /// for when the user will unpack it.
  void checkoutFlutter(String revision) {
    // We want the user to start out the in the 'master' branch instead of a
    // detached head. To do that, we need to make sure master points at the
    // desired revision.
    runGit(<String>['clone', '-b', 'master', CHROMIUM_REPO], workingDirectory: tmpDir);
    runGit(<String>['reset', '--hard', revision]);

    // Make the origin point to github instead of the chromium mirror.
    runGit(<String>['remote', 'remove', 'origin']);
    runGit(<String>['remote', 'add', 'origin', GITHUB_REPO]);
  }

  /// Retrieve the MinGit executable from storage and unpack it.
  Future<Null> installMinGitIfNeeded() async {
    if (!Platform.isWindows) {
      return;
    }
    final Uint8List data = await http.readBytes(minGitUri);
    final File gitFile = new File(path.join(tmpDir.path, 'mingit.zip'));
    await gitFile.open(mode: FileMode.WRITE);
    await gitFile.writeAsBytes(data);

    final Directory minGitPath = new Directory(path.join(flutterRoot.path, 'bin', 'mingit'));
    await minGitPath.create(recursive: true);
    unzipArchive(gitFile, currentDirectory: minGitPath);
  }

  /// Prepare the archive repo so that it has all of the caches warmed up and
  /// is configured for the user to being working.
  void populateCaches() {
    runFlutter(<String>['doctor']);
    runFlutter(<String>['update-packages']);
    runFlutter(<String>['precache']);
    runFlutter(<String>['ide-config']);

    // Create each of the templates, since they will call 'pub get' on
    // themselves when created, and this will warm the cache with their
    // dependencies too.
    for (String template in <String>['app', 'package', 'plugin']) {
      final String createName = path.join(tmpDir.path, 'create_$template');
      runFlutter(
        <String>['create', '--template=$template', createName],
      );
    }

    // Yes, we could just skip all .packages files when constructing
    // the archive, but some are checked in, and we don't want to skip
    // those.
    runGit(<String>['clean', '-f', '-X', '**/.packages']);
  }

  /// Create the archive into the given output file.
  void archiveFiles() {
    if (outputFile.path.toLowerCase().endsWith('.zip')) {
      createZipArchive(outputFile, flutterRoot);
    } else if (outputFile.path.toLowerCase().endsWith('.tar.xz')) {
      createTarArchive(outputFile, flutterRoot);
    }
  }

  String _runProcess(String executable, List<String> args, {Directory workingDirectory}) {
    workingDirectory ??= flutterRoot;
    stderr.write('Running "$executable ${args.join(' ')}" in ${workingDirectory.path}.\n');
    ProcessResult result;
    try {
      result = _runner(
        executable,
        args,
        workingDirectory: workingDirectory.absolute.path,
        environment: environment,
        includeParentEnvironment: false,
      );
    } on ProcessException catch (e) {
      final String message = 'Running "$executable ${args.join(' ')}" in ${workingDirectory.path} '
          'failed with:\n${e.toString()}\n  PATH: ${environment['PATH']}';
      throw new ProcessFailedException(message, -1);
    } catch (e) {
      rethrow;
    }
    stdout.write(result.stdout);
    stderr.write(result.stderr);
    if (result.exitCode != 0) {
      final String message = 'Running "$executable ${args.join(' ')}" in ${workingDirectory.path} '
          'failed with ${result.exitCode}.';
      throw new ProcessFailedException(message, result.exitCode);
    }
    return result.stdout.trim();
  }

  String runFlutter(List<String> args) {
    return _runProcess(flutter, args);
  }

  String runGit(List<String> args, {Directory workingDirectory}) {
    return _runProcess(git, args, workingDirectory: workingDirectory);
  }

  void unzipArchive(File archive, {Directory currentDirectory}) {
    currentDirectory ??= new Directory(path.dirname(archive.absolute.path));
    final List<String> args = <String>[];
    String executable;
    if (zip == 'zip') {
      executable = 'unzip';
    } else {
      executable = zip;
      args.addAll(<String>['x']);
    }
    args.add(archive.absolute.path);

    _runProcess(executable, args, workingDirectory: currentDirectory);
  }

  void createZipArchive(File output, Directory source) {
    final List<String> args = <String>[];
    if (zip == 'zip') {
      args.addAll(<String>['-r', '-9', '-q']);
    } else {
      args.addAll(<String>['a', '-tzip', '-mx=9']);
    }
    args.addAll(<String>[
      output.absolute.path,
      path.basename(source.absolute.path),
    ]);

    _runProcess(zip, args,
        workingDirectory: new Directory(path.dirname(source.absolute.path)));
  }

  void createTarArchive(File output, Directory source) {
    final List<String> args = <String>[
      'cJf',
      output.absolute.path,
      path.basename(source.absolute.path),
    ];
    _runProcess(tar, args,
        workingDirectory: new Directory(path.dirname(source.absolute.path)));
  }
}

/// Prepares a flutter git repo to be packaged up for distribution.
/// It mainly serves to populate the .pub-cache with any appropriate Dart
/// packages, and the flutter cache in bin/cache with the appropriate
/// dependencies and snapshots.
///
/// Note that archives contain the executables and customizations for the
/// platform that they are created on.  So, for instance, a ZIP archive
/// created on a Mac will contain Mac executables and setup, even though
/// it's in a zip file.
Future<Null> main(List<String> argList) async {
  final ArgParser argParser = new ArgParser();
  argParser.addOption(
    'temp_dir',
    defaultsTo: null,
    help: 'A location where temporary files may be written. Defaults to a '
        'directory in the system temp folder. Will write a few GiB of data, '
        'so it should have sufficient free space.',
  );
  argParser.addOption(
    'revision',
    defaultsTo: 'master',
    help: 'The Flutter revision to build the archive with. Defaults to the '
        "master branch's HEAD revision.",
  );
  argParser.addOption(
    'output',
    defaultsTo: null,
    help: 'The path where the output archive should be written. '
        'The suffix determines the output format: .tar.xz or .zip are the '
        'only formats supported.',
  );
  final ArgResults args = argParser.parse(argList);

  void errorExit(String message, {int exitCode = -1}) {
    stderr.write('Error: $message\n\n');
    stderr.write('${argParser.usage}\n');
    exit(exitCode);
  }

  if (args['revision'].isEmpty) {
    errorExit('Invalid argument: --revision must be specified.');
  }

  Directory tmpDir;
  bool removeTempDir = false;
  if (args['temp_dir'] == null || args['temp_dir'].isEmpty) {
    tmpDir = Directory.systemTemp.createTempSync('flutter_');
    removeTempDir = true;
  } else {
    tmpDir = new Directory(args['temp_dir']);
    if (!tmpDir.existsSync()) {
      errorExit("Temporary directory ${args['temp_dir']} doesn't exist.");
    }
  }

  String outputFileString = args['output'];
  if (outputFileString == null || outputFileString.isEmpty) {
    final String suffix = Platform.isWindows ? '.zip' : '.tar.xz';
    outputFileString = path.join(tmpDir.path, 'flutter_${args['revision']}$suffix');
  } else if (!outputFileString.toLowerCase().endsWith('.zip') &&
      !outputFileString.toLowerCase().endsWith('.tar.xz')) {
    errorExit('Output file has unsupported suffix. It should be either ".zip" or ".tar.xz".');
  }

  final File outputFile = new File(outputFileString);
  if (outputFile.existsSync()) {
    errorExit('Output file ${outputFile.absolute.path} already exists.');
  }

  final ArchiveCreator preparer = new ArchiveCreator(tmpDir, outputFile);
  int exitCode = 0;
  String message;
  try {
    await preparer.createArchive(args['revision']);
  } on ProcessFailedException catch (e) {
    exitCode = e.exitCode;
    message = e.message;
  } catch (e) {
    rethrow;
  } finally {
    if (removeTempDir) {
      tmpDir.deleteSync(recursive: true);
    }
    if (exitCode != 0) {
      errorExit(message, exitCode: exitCode);
    }
    exit(0);
  }
  return new Future<Null>.value();
}