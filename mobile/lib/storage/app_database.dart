import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart';

class AppDatabase {
  AppDatabase._(this.database);

  static const _databaseName = 'maoguai_signin.db';
  static const _schemaVersion = 3;

  final Database database;

  static Future<AppDatabase> open({bool singleInstance = true}) async {
    final databasesPath = await getDatabasesPath();
    return _open(
      path.join(databasesPath, _databaseName),
      databaseFactory,
      singleInstance: singleInstance,
    );
  }

  static Future<AppDatabase> openForTest(DatabaseFactory factory) =>
      _open(inMemoryDatabasePath, factory);

  static Future<AppDatabase> _open(
    String databasePath,
    DatabaseFactory factory, {
    bool singleInstance = true,
  }) async {
    final database = await factory.openDatabase(
      databasePath,
      options: OpenDatabaseOptions(
        version: _schemaVersion,
        singleInstance: singleInstance,
        onCreate: _createSchema,
        onUpgrade: _upgradeSchema,
      ),
    );
    return AppDatabase._(database);
  }

  static Future<void> _upgradeSchema(
    Database database,
    int oldVersion,
    int newVersion,
  ) async {
    if (oldVersion < 2) {
      // Legacy single-account data is stamped with the first nonsecret lifetime.
      await database.execute(
        'CREATE TABLE account_state (id INTEGER PRIMARY KEY CHECK (id = 1), generation INTEGER NOT NULL, active INTEGER NOT NULL)',
      );
      await database.execute(
        'INSERT INTO account_state SELECT 1, 1, CASE WHEN '
        'EXISTS (SELECT 1 FROM schedule_settings) OR '
        'EXISTS (SELECT 1 FROM daily_plans) OR '
        'EXISTS (SELECT 1 FROM sign_in_records) THEN 1 ELSE 0 END',
      );
      await database.execute(
        'ALTER TABLE daily_plans ADD COLUMN generation INTEGER NOT NULL DEFAULT 1',
      );
      await database.execute(
        'ALTER TABLE sign_in_records ADD COLUMN generation INTEGER NOT NULL DEFAULT 1',
      );
    }
    if (oldVersion < 3) {
      await database.execute(
        'CREATE TABLE native_result_imports (result_id TEXT PRIMARY KEY, credential_instance_id TEXT NOT NULL)',
      );
    }
  }

  Future<void> close() => database.close();

  static Future<void> _createSchema(Database database, int version) async {
    final batch = database.batch();
    batch.execute(
      'CREATE TABLE account_state (id INTEGER PRIMARY KEY CHECK (id = 1), generation INTEGER NOT NULL, active INTEGER NOT NULL)',
    );
    batch.execute('INSERT INTO account_state VALUES (1, 0, 0)');
    batch.execute('''
      CREATE TABLE schedule_settings (
        id INTEGER PRIMARY KEY CHECK (id = 1),
        enabled INTEGER NOT NULL,
        notifications_enabled INTEGER NOT NULL,
        start_minute INTEGER NOT NULL,
        end_minute INTEGER NOT NULL
      )
    ''');
    batch.execute('''
      CREATE TABLE daily_plans (
        day TEXT PRIMARY KEY,
        generation INTEGER NOT NULL,
        start_minute INTEGER NOT NULL,
        end_minute INTEGER NOT NULL,
        planned_at TEXT NOT NULL,
        status TEXT NOT NULL,
        attempted_at TEXT,
        actual_at TEXT,
        range_regenerated INTEGER NOT NULL DEFAULT 0,
        late_execution INTEGER NOT NULL DEFAULT 0
      )
    ''');
    batch.execute('''
      CREATE TABLE sign_in_records (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        day TEXT NOT NULL,
        generation INTEGER NOT NULL,
        planned_at TEXT,
        occurred_at TEXT NOT NULL,
        source TEXT NOT NULL,
        status TEXT NOT NULL,
        title TEXT NOT NULL,
        detail TEXT NOT NULL,
        error_kind TEXT
      )
    ''');
    batch.execute(
      'CREATE INDEX idx_records_day_time ON sign_in_records(day, occurred_at DESC)',
    );
    batch.execute(
      'CREATE TABLE native_result_imports (result_id TEXT PRIMARY KEY, credential_instance_id TEXT NOT NULL)',
    );
    await batch.commit(noResult: true);
  }
}
