import 'dart:io';
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:maoguai_signin/storage/app_database.dart';
import 'package:maoguai_signin/storage/sign_in_repository.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);
  for (final hasLegacyData in [true, false]) {
    test(
      'v1 migration preserves data=$hasLegacyData and durable logout across connections',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'signin-generation-',
        );
        final previousFactory = sqflite.databaseFactoryOrNull;
        final previousPath = await databaseFactoryFfi.getDatabasesPath();
        sqflite.databaseFactoryOrNull = databaseFactoryFfi;
        await databaseFactoryFfi.setDatabasesPath(directory.path);
        addTearDown(() async {
          sqflite.databaseFactoryOrNull = previousFactory;
          await databaseFactoryFfi.setDatabasesPath(previousPath);
          await directory.delete(recursive: true);
        });
        final legacy = await databaseFactoryFfi.openDatabase(
          path.join(directory.path, 'maoguai_signin.db'),
          options: OpenDatabaseOptions(
            version: 1,
            onCreate: (db, _) async {
              await db.execute(
                'CREATE TABLE schedule_settings (id INTEGER PRIMARY KEY, enabled INTEGER, notifications_enabled INTEGER, start_minute INTEGER, end_minute INTEGER)',
              );
              await db.execute(
                'CREATE TABLE daily_plans (day TEXT PRIMARY KEY, start_minute INTEGER, end_minute INTEGER, planned_at TEXT, status TEXT, attempted_at TEXT, actual_at TEXT, range_regenerated INTEGER, late_execution INTEGER)',
              );
              await db.execute(
                'CREATE TABLE sign_in_records (id INTEGER PRIMARY KEY AUTOINCREMENT, day TEXT, planned_at TEXT, occurred_at TEXT, source TEXT, status TEXT, title TEXT, detail TEXT, error_kind TEXT)',
              );
              if (hasLegacyData) {
                await db.execute(
                  "INSERT INTO daily_plans VALUES ('2026-09-09', 480, 600, '2026-09-09T09:00:00.000', 'success', '2026-09-09T09:00:00.000', '2026-09-09T09:00:00.000', 0, 0)",
                );
                await db.execute(
                  "INSERT INTO sign_in_records (day, occurred_at, source, status, title, detail) VALUES ('2026-09-09', '2026-09-09T09:00:00.000', 'manual', 'success', '签到成功', '今日签到状态已确认。')",
                );
              }
            },
          ),
        );
        await legacy.close();
        var database = await AppDatabase.open(singleInstance: false);
        var repository = SqliteSignInRepository(database);
        expect(await repository.activeGeneration(), hasLegacyData ? 1 : isNull);
        if (hasLegacyData) {
          expect((await repository.planForDay('2026-09-09'))!.generation, 1);
          expect(
            (await repository.recordsForDay('2026-09-09')).single.generation,
            1,
          );
        }
        expect(
          (await database.database.rawQuery('PRAGMA table_info(account_state)'))
              .map((row) => row['name']),
          ['id', 'generation', 'active'],
        );
        await repository.clearAccountData();
        await database.close();
        database = await AppDatabase.open(singleInstance: false);
        addTearDown(database.close);
        repository = SqliteSignInRepository(database);
        expect(await repository.activeGeneration(), isNull);
        expect(await repository.activateAccount(), 3);
        expect(await repository.recordsForDay('2026-09-09'), isEmpty);
        expect(await repository.planForDay('2026-09-09'), isNull);
        final otherConnection = await AppDatabase.open(singleInstance: false);
        addTearDown(otherConnection.close);
        final other = SqliteSignInRepository(otherConnection);
        final entered = Completer<void>();
        final release = Completer<void>();
        final publication = repository.withGeneration(3, () async {
          entered.complete();
          await release.future;
        });
        await entered.future;
        var invalidated = false;
        final invalidation = other.clearAccountData().then(
          (_) => invalidated = true,
        );
        await Future<void>.delayed(Duration.zero);
        expect(invalidated, isFalse);
        release.complete();
        await publication;
        await invalidation;
        expect(await repository.activeGeneration(), isNull);
      },
    );
  }
}
