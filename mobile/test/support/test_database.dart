import 'package:maoguai_signin/storage/app_database.dart';
import 'package:maoguai_signin/storage/sign_in_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class TestDatabaseBundle {
  TestDatabaseBundle(this.database, this.repository);

  final AppDatabase database;
  final SqliteSignInRepository repository;
}

Future<TestDatabaseBundle> openTestDatabase() async {
  final database = await AppDatabase.openForTest(databaseFactoryFfi);
  final repository = SqliteSignInRepository(database);
  await repository.activateAccount();
  return TestDatabaseBundle(database, repository);
}
