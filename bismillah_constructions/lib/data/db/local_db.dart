import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class LocalDb {
  LocalDb._();
  static final LocalDb instance = LocalDb._();

  /// Test-only: applies the latest schema to an open db. Real callers go
  /// through [open], which routes through [_onCreate] / [_onUpgrade] like
  /// normal.
  @visibleForTesting
  Future<void> applySchemaForTests(Database db) => _onCreate(db, 17);

  Database? _db;
  String? _dbPath;

  /// Absolute path of the open database — used by backup service.
  String? get dbPath => _dbPath;

  /// Closes the database connection so that [open] can reopen it with new
  /// content — called by the auto-restore flow after copying a backup file
  /// to [dbPath].
  Future<void> reinitialize() async {
    await _db?.close();
    _db = null;
  }

  Future<Database> open() async {
    if (_db != null) return _db!;

    DatabaseFactory factory;
    String path;

    if (Platform.isWindows || Platform.isLinux) {
      sqfliteFfiInit();
      factory = databaseFactoryFfi;
      final dir = await getApplicationSupportDirectory();
      path = p.join(dir.path, 'solo_con.db');
    } else {
      factory = databaseFactory;
      path = p.join(await getDatabasesPath(), 'solo_con.db');
    }
    _dbPath = path;

    _db = await factory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 17,
        onConfigure: (db) async {
          await db.execute('PRAGMA foreign_keys = ON');
        },
        onCreate: _onCreate,
        onUpgrade: _onUpgrade,
      ),
    );
    return _db!;
  }

  Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE suppliers (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        phone TEXT,
        category TEXT,
        tax_status TEXT,
        bank_details TEXT,
        is_archived INTEGER NOT NULL DEFAULT 0,
        archived_at TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
      )
    ''');

    await db.execute('''
      CREATE TABLE banks (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        account_no TEXT,
        is_archived INTEGER NOT NULL DEFAULT 0,
        archived_at TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
      )
    ''');

    await db.execute('''
      CREATE TABLE counter_entities (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        type TEXT NOT NULL,
        amount REAL NOT NULL DEFAULT 0,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
      )
    ''');

    await db.execute('''
      CREATE TABLE projects (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        model TEXT NOT NULL,
        status TEXT NOT NULL,
        client_name TEXT,                      -- free-text client; no Customer entity exists
        site_address TEXT,
        budget REAL,
        project_manager TEXT,
        service_fee_percent REAL,
        -- v14: manual completion estimate (0..100) entered by the owner.
        -- Intentionally not derived from BOQ / quantities — this is a
        -- gut-feel number that informs dashboards and forecasting.
        completion_percent INTEGER NOT NULL DEFAULT 0,
        is_archived INTEGER NOT NULL DEFAULT 0,
        archived_at TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
      )
    ''');

    await db.execute('''
      CREATE TABLE material_inventory (
        id TEXT PRIMARY KEY,
        project_id TEXT NOT NULL,
        -- nullable as of v12: counter-purchase rows are not attached to
        -- a supplier (cash buys from a hardware store, etc.).
        supplier_id TEXT,
        transaction_id TEXT,
        material_type TEXT NOT NULL,
        unit TEXT NOT NULL,
        -- nullable as of v17: a material buy can be logged without a
        -- quantity. Such rows carry a null rate and are skipped by the
        -- Material Price Trend; their detail lives in the memo instead.
        quantity REAL,
        rate REAL,
        total_cost REAL NOT NULL,
        txn_type TEXT NOT NULL,
        created_at TEXT NOT NULL,
        -- v13: soft-delete flag linked to the parent journal txn so the
        -- price-trend and BvA reports stay in sync with the ledger
        -- when the user soft-deletes a material buy.
        is_deleted INTEGER NOT NULL DEFAULT 0,
        deleted_at TEXT,
        updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
        FOREIGN KEY (project_id) REFERENCES projects(id),
        FOREIGN KEY (supplier_id) REFERENCES suppliers(id)
      )
    ''');

    await db.execute('''
      CREATE TABLE journal_entries (
        id TEXT PRIMARY KEY,
        transaction_id TEXT NOT NULL,
        account_id TEXT NOT NULL,
        project_id TEXT REFERENCES projects(id),
        supplier_id TEXT REFERENCES suppliers(id),
        debit REAL NOT NULL DEFAULT 0,
        credit REAL NOT NULL DEFAULT 0,
        description TEXT,
        created_at TEXT NOT NULL,
        synced INTEGER NOT NULL DEFAULT 0,
        is_deleted INTEGER NOT NULL DEFAULT 0,
        deleted_at TEXT,
        updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
      )
    ''');

    await db.execute('''
      CREATE TABLE change_log (
        id TEXT PRIMARY KEY,
        entity_type TEXT NOT NULL,
        entity_id TEXT NOT NULL,
        action TEXT NOT NULL,
        original_data TEXT,
        new_data TEXT,
        note TEXT,
        device_id TEXT,
        timestamp TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE app_settings (
        key TEXT PRIMARY KEY,
        value TEXT
      )
    ''');

    // v7 base columns + v8 procurement metadata. uom_typ is one of
    // 'discrete' / 'surface' / 'volume' / 'weight'; cov_rate / dims are
    // only meaningful for some uom_typ values, so they're nullable.
    //
    // is_builtin used to lock the original five seeded rows from deletion.
    // v9 removed seeding entirely (the user wants to define every material
    // type themselves), so the column is left for backwards-compat with
    // upgraded installs but is no longer enforced anywhere.
    await db.execute('''
      CREATE TABLE material_types (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL UNIQUE,
        is_builtin INTEGER NOT NULL DEFAULT 0,
        sort_order INTEGER NOT NULL DEFAULT 0,
        uom_typ TEXT,
        uom TEXT,
        cov_rate REAL,
        waste_f REAL,
        lead_d INTEGER,
        dims TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
      )
    ''');
    // No seeds. Fresh installs start with an empty material catalog so the
    // user can define every type from scratch.

    await db.execute(
      'CREATE INDEX idx_je_txn ON journal_entries(transaction_id)',
    );
    await db.execute(
      'CREATE INDEX idx_je_account ON journal_entries(account_id)',
    );
    await db.execute(
      'CREATE INDEX idx_je_project ON journal_entries(project_id)',
    );
    await db.execute(
      'CREATE INDEX idx_je_supplier ON journal_entries(supplier_id)',
    );
    await db.execute('CREATE INDEX idx_je_synced ON journal_entries(synced)');
    await db.execute(
      'CREATE INDEX idx_je_deleted ON journal_entries(is_deleted)',
    );
    await db.execute(
      'CREATE INDEX idx_cl_entity ON change_log(entity_type, entity_id)',
    );

    await db.execute('''
      CREATE TABLE labour_types (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL UNIQUE,
        description TEXT,
        default_daily_rate REAL,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
      )
    ''');

    // v14: operational memory layer.
    //   * `notes` — free-text notes attached to a project / supplier. The
    //     entity column pair (`entity_type`, `entity_id`) is intentionally
    //     un-FK'd so notes survive a hard-delete of the entity (rare, but
    //     guards against orphan-cleanup losing history).
    //   * `follow_ups` — customer / supplier payment-recovery tracker.
    //     Lightweight CRM-replacement: an expected date, a priority, a
    //     status, optional ties to project and party.
    await db.execute('''
      CREATE TABLE notes (
        id TEXT PRIMARY KEY,
        entity_type TEXT NOT NULL,             -- 'project' | 'supplier'
        entity_id TEXT NOT NULL,
        body TEXT NOT NULL,
        is_pinned INTEGER NOT NULL DEFAULT 0,
        is_deleted INTEGER NOT NULL DEFAULT 0,
        deleted_at TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
      )
    ''');
    await db.execute(
        'CREATE INDEX idx_notes_entity ON notes(entity_type, entity_id)');
    await db.execute(
        'CREATE INDEX idx_notes_pinned ON notes(is_pinned, is_deleted)');

    await db.execute('''
      CREATE TABLE follow_ups (
        id TEXT PRIMARY KEY,
        project_id TEXT REFERENCES projects(id),
        supplier_id TEXT REFERENCES suppliers(id),
        title TEXT NOT NULL,
        note TEXT,
        expected_date TEXT,                    -- ISO-8601 UTC, nullable
        priority TEXT NOT NULL DEFAULT 'medium', -- 'low' | 'medium' | 'high'
        status TEXT NOT NULL DEFAULT 'pending',  -- 'pending' | 'resolved' | 'cancelled'
        amount_estimate REAL,
        is_deleted INTEGER NOT NULL DEFAULT 0,
        deleted_at TEXT,
        created_at TEXT NOT NULL,
        resolved_at TEXT,
        updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
      )
    ''');
    await db.execute(
        'CREATE INDEX idx_followups_status ON follow_ups(status, is_deleted)');
    await db.execute(
        'CREATE INDEX idx_followups_project ON follow_ups(project_id)');
    await db.execute(
        'CREATE INDEX idx_followups_supplier ON follow_ups(supplier_id)');

    // v15: bump-on-update triggers powering the cloud-sync cursor. Mirror
    // of the migration in `_onUpgrade(< 15)` — they have to exist on
    // fresh installs too, not just upgrades.
    const syncTables = <String>[
      'projects',
      'suppliers',
      'banks',
      'journal_entries',
      'material_inventory',
      'material_types',
      'labour_types',
      'counter_entities',
      'notes',
      'follow_ups',
    ];
    for (final t in syncTables) {
      await db.execute('''
        CREATE TRIGGER trg_bump_${t}_updated
        AFTER UPDATE ON $t
        FOR EACH ROW
        WHEN NEW.updated_at = OLD.updated_at
        BEGIN
          UPDATE $t SET updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
          WHERE rowid = NEW.rowid;
        END
      ''');
    }
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      await db.execute('ALTER TABLE customers ADD COLUMN ntn_cnic TEXT');
      await db.execute('ALTER TABLE customers ADD COLUMN address TEXT');
      await db.execute('ALTER TABLE customers ADD COLUMN credit_limit REAL');
      await db.execute('ALTER TABLE suppliers ADD COLUMN category TEXT');
      await db.execute('ALTER TABLE suppliers ADD COLUMN tax_status TEXT');
      await db.execute('ALTER TABLE suppliers ADD COLUMN bank_details TEXT');
      await db.execute('ALTER TABLE projects ADD COLUMN customer_id TEXT');
      await db.execute('ALTER TABLE projects ADD COLUMN site_address TEXT');
      await db.execute('ALTER TABLE projects ADD COLUMN budget REAL');
      await db.execute('ALTER TABLE projects ADD COLUMN project_manager TEXT');

      await db.execute('''
        CREATE TABLE IF NOT EXISTS banks (
          id TEXT PRIMARY KEY,
          name TEXT NOT NULL,
          account_no TEXT,
          created_at TEXT NOT NULL
        )
      ''');

      await db.execute('''
        CREATE TABLE IF NOT EXISTS counter_entities (
          id TEXT PRIMARY KEY,
          name TEXT NOT NULL,
          type TEXT NOT NULL,
          amount REAL NOT NULL DEFAULT 0,
          created_at TEXT NOT NULL
        )
      ''');

      await db.execute('''
        CREATE TABLE IF NOT EXISTS material_inventory (
          id TEXT PRIMARY KEY,
          project_id TEXT NOT NULL,
          supplier_id TEXT NOT NULL,
          transaction_id TEXT,
          material_type TEXT NOT NULL,
          unit TEXT NOT NULL,
          quantity REAL NOT NULL,
          rate REAL NOT NULL,
          total_cost REAL NOT NULL,
          txn_type TEXT NOT NULL,
          created_at TEXT NOT NULL
        )
      ''');
    }

    if (oldVersion < 4) {
      // v4: device_id on change_log so audits identify the writing install.
      try {
        await db.execute('ALTER TABLE change_log ADD COLUMN device_id TEXT');
      } catch (_) {/* column may already exist on fresh installs */}
    }

    if (oldVersion < 6) {
      // v6: archival on suppliers + banks (parity with projects). Keeps the
      // ledger history intact while hiding the row from default lists.
      for (final table in const ['suppliers', 'banks']) {
        try {
          await db.execute(
              'ALTER TABLE $table ADD COLUMN is_archived INTEGER NOT NULL DEFAULT 0');
        } catch (_) {/* may already exist */}
        try {
          await db.execute('ALTER TABLE $table ADD COLUMN archived_at TEXT');
        } catch (_) {/* may already exist */}
      }
    }

    if (oldVersion < 5) {
      // v5: free-text `client_name` on projects (replaces the customer FK
      // for the user's flow). Banks become user-defined accounts — seed the
      // legacy hardcoded bank ids into the `banks` table when they are
      // referenced by existing journal_entries so old data keeps a
      // human-readable label.
      try {
        await db.execute('ALTER TABLE projects ADD COLUMN client_name TEXT');
      } catch (_) {/* may already exist */}

      const seeds = <Map<String, String>>[
        {'id': 'BANK_HBL', 'name': 'Bank — HBL'},
        {'id': 'BANK_MEEZAN', 'name': 'Bank — Meezan'},
        {'id': 'BANK_ALFALAH', 'name': 'Bank — Alfalah'},
      ];
      for (final s in seeds) {
        final hits = await db.rawQuery(
          'SELECT 1 FROM journal_entries WHERE account_id = ? LIMIT 1',
          [s['id']],
        );
        if (hits.isNotEmpty) {
          await db.insert(
            'banks',
            {
              'id': s['id'],
              'name': s['name'],
              'account_no': null,
              'created_at': DateTime.now().toUtc().toIso8601String(),
            },
            conflictAlgorithm: ConflictAlgorithm.ignore,
          );
        }
      }
    }

    if (oldVersion < 7) {
      // v7: user-defined material types table. Originally the five legacy
      // enum values were seeded as built-ins; v9 removed that — so we
      // create the table empty and let the user define their own rows.
      await db.execute('''
        CREATE TABLE IF NOT EXISTS material_types (
          id TEXT PRIMARY KEY,
          name TEXT NOT NULL UNIQUE,
          is_builtin INTEGER NOT NULL DEFAULT 0,
          sort_order INTEGER NOT NULL DEFAULT 0,
          created_at TEXT NOT NULL
        )
      ''');
    }

    if (oldVersion < 8) {
      // v8: procurement metadata on material types. All nullable so existing
      // rows survive untouched; the UI offers them as optional fields.
      for (final ddl in const [
        'ALTER TABLE material_types ADD COLUMN uom_typ TEXT',
        'ALTER TABLE material_types ADD COLUMN uom TEXT',
        'ALTER TABLE material_types ADD COLUMN cov_rate REAL',
        'ALTER TABLE material_types ADD COLUMN waste_f REAL',
        'ALTER TABLE material_types ADD COLUMN lead_d INTEGER',
        'ALTER TABLE material_types ADD COLUMN dims TEXT',
      ]) {
        try {
          await db.execute(ddl);
        } catch (_) {/* may already exist on partial upgrades */}
      }
    }

    if (oldVersion < 9) {
      // v9: drop the seeded built-in material types — the user wants to
      // define every category themselves. Historical material_inventory
      // rows still display correctly because they store the type name as
      // a free-form string, not a foreign key.
      await db.delete('material_types', where: 'is_builtin = 1');
    }

    if (oldVersion < 10) {
      // v10: user-defined labour categories (Mason, Electrician, etc.).
      await db.execute('''
        CREATE TABLE IF NOT EXISTS labour_types (
          id TEXT PRIMARY KEY,
          name TEXT NOT NULL UNIQUE,
          description TEXT,
          default_daily_rate REAL,
          created_at TEXT NOT NULL
        )
      ''');
    }

    if (oldVersion < 11) {
      // v11: add REFERENCES constraints to journal_entries.project_id and
      // journal_entries.supplier_id so the DB enforces referential integrity.
      //
      // SQLite cannot ADD CONSTRAINT to an existing table, so we:
      //   1. Null out any orphaned references (safety net for any historical
      //      hard-deletes of projects / suppliers).
      //   2. Recreate the table with the FK declarations.
      //   3. Copy all rows across and rebuild indexes.
      //
      // sqflite wraps _onUpgrade in a SQLite transaction on Android/iOS, so
      // a failure here rolls back automatically and leaves the DB at v10.
      await db.rawUpdate('''
        UPDATE journal_entries
        SET project_id = NULL
        WHERE project_id IS NOT NULL
          AND project_id NOT IN (SELECT id FROM projects)
      ''');
      await db.rawUpdate('''
        UPDATE journal_entries
        SET supplier_id = NULL
        WHERE supplier_id IS NOT NULL
          AND supplier_id NOT IN (SELECT id FROM suppliers)
      ''');
      await db.execute('''
        CREATE TABLE journal_entries_v11 (
          id TEXT PRIMARY KEY,
          transaction_id TEXT NOT NULL,
          account_id TEXT NOT NULL,
          project_id TEXT REFERENCES projects(id),
          supplier_id TEXT REFERENCES suppliers(id),
          customer_id TEXT,
          debit REAL NOT NULL DEFAULT 0,
          credit REAL NOT NULL DEFAULT 0,
          description TEXT,
          created_at TEXT NOT NULL,
          synced INTEGER NOT NULL DEFAULT 0,
          is_deleted INTEGER NOT NULL DEFAULT 0,
          deleted_at TEXT
        )
      ''');
      await db.execute(
          'INSERT INTO journal_entries_v11 SELECT * FROM journal_entries');
      await db.execute('DROP TABLE journal_entries');
      await db.execute(
          'ALTER TABLE journal_entries_v11 RENAME TO journal_entries');
      // Rebuild all indexes that existed on the old table.
      await db.execute(
          'CREATE INDEX idx_je_txn ON journal_entries(transaction_id)');
      await db.execute(
          'CREATE INDEX idx_je_account ON journal_entries(account_id)');
      await db.execute(
          'CREATE INDEX idx_je_project ON journal_entries(project_id)');
      await db.execute(
          'CREATE INDEX idx_je_supplier ON journal_entries(supplier_id)');
      await db.execute(
          'CREATE INDEX idx_je_customer ON journal_entries(customer_id)');
      await db.execute(
          'CREATE INDEX idx_je_synced ON journal_entries(synced)');
      await db.execute(
          'CREATE INDEX idx_je_deleted ON journal_entries(is_deleted)');
    }

    if (oldVersion < 12) {
      // v12: relax material_inventory.supplier_id to allow NULL so a
      // counter-purchase material buy (Dr Material Costs / Cr Cash, no
      // supplier on the credit side) can still record its quantity and
      // unit rate against the project — enabling the price-trend report.
      //
      // SQLite can't DROP NOT NULL on a column in place; recreate the
      // table and copy data over.
      await db.execute('''
        CREATE TABLE material_inventory_v12 (
          id TEXT PRIMARY KEY,
          project_id TEXT NOT NULL,
          supplier_id TEXT,
          transaction_id TEXT,
          material_type TEXT NOT NULL,
          unit TEXT NOT NULL,
          quantity REAL NOT NULL,
          rate REAL NOT NULL,
          total_cost REAL NOT NULL,
          txn_type TEXT NOT NULL,
          created_at TEXT NOT NULL,
          FOREIGN KEY (project_id) REFERENCES projects(id),
          FOREIGN KEY (supplier_id) REFERENCES suppliers(id)
        )
      ''');
      await db.execute(
          'INSERT INTO material_inventory_v12 SELECT * FROM material_inventory');
      await db.execute('DROP TABLE material_inventory');
      await db.execute(
          'ALTER TABLE material_inventory_v12 RENAME TO material_inventory');
    }

    if (oldVersion < 13) {
      // v13: link material_inventory to the parent journal txn's
      // deletion state. Before this, soft-deleting (or hard-deleting) a
      // material buy left the corresponding `material_inventory` row
      // intact — so the Budget vs Actual breakdown and Material Price
      // Trend continued to show the deleted purchase. The new column
      // and the matching changes in soft/hard delete + restore fix
      // that.
      for (final ddl in const [
        'ALTER TABLE material_inventory ADD COLUMN is_deleted INTEGER NOT NULL DEFAULT 0',
        'ALTER TABLE material_inventory ADD COLUMN deleted_at TEXT',
      ]) {
        try {
          await db.execute(ddl);
        } catch (_) {/* column may already exist on partial upgrades */}
      }
    }

    if (oldVersion < 14) {
      // v14: operational-memory layer.
      //   * Manual `completion_percent` on projects (owner-entered, 0..100).
      //   * `notes` table for free-text memory attached to projects /
      //     suppliers.
      //   * `follow_ups` table for customer recovery + payment-promise
      //     tracking — separate from `change_log` because these are
      //     forward-looking, not audit records.
      try {
        await db.execute(
            'ALTER TABLE projects ADD COLUMN completion_percent INTEGER NOT NULL DEFAULT 0');
      } catch (_) {/* column may already exist on partial upgrades */}

      await db.execute('''
        CREATE TABLE IF NOT EXISTS notes (
          id TEXT PRIMARY KEY,
          entity_type TEXT NOT NULL,
          entity_id TEXT NOT NULL,
          body TEXT NOT NULL,
          is_pinned INTEGER NOT NULL DEFAULT 0,
          is_deleted INTEGER NOT NULL DEFAULT 0,
          deleted_at TEXT,
          created_at TEXT NOT NULL,
          updated_at TEXT
        )
      ''');
      await db.execute(
          'CREATE INDEX IF NOT EXISTS idx_notes_entity ON notes(entity_type, entity_id)');
      await db.execute(
          'CREATE INDEX IF NOT EXISTS idx_notes_pinned ON notes(is_pinned, is_deleted)');

      await db.execute('''
        CREATE TABLE IF NOT EXISTS follow_ups (
          id TEXT PRIMARY KEY,
          project_id TEXT REFERENCES projects(id),
          supplier_id TEXT REFERENCES suppliers(id),
          title TEXT NOT NULL,
          note TEXT,
          expected_date TEXT,
          priority TEXT NOT NULL DEFAULT 'medium',
          status TEXT NOT NULL DEFAULT 'pending',
          amount_estimate REAL,
          is_deleted INTEGER NOT NULL DEFAULT 0,
          deleted_at TEXT,
          created_at TEXT NOT NULL,
          resolved_at TEXT
        )
      ''');
      await db.execute(
          'CREATE INDEX IF NOT EXISTS idx_followups_status ON follow_ups(status, is_deleted)');
      await db.execute(
          'CREATE INDEX IF NOT EXISTS idx_followups_project ON follow_ups(project_id)');
      await db.execute(
          'CREATE INDEX IF NOT EXISTS idx_followups_supplier ON follow_ups(supplier_id)');
    }

    if (oldVersion < 15) {
      // v15: cloud-sync support.
      //
      // Every table that mirrors to Supabase needs an `updated_at` column
      // so the sync service can ask "what's changed since last push?". On
      // the pull side, rows incoming from Supabase whose id already exists
      // locally are skipped — the local DB always wins on its own rows.
      //
      // We add the column nullable (so existing rows survive the ALTER),
      // then backfill with the row's `created_at`. The CURRENT_TIMESTAMP
      // default kicks in for future inserts that don't pass the column
      // explicitly. UPDATE triggers bump `updated_at` to "now" on every
      // row change.
      //
      // `notes.updated_at` already existed (v14) but was nullable; we
      // backfill any nulls so the cursored push doesn't trip over them.
      const syncTables = <String>[
        'projects',
        'suppliers',
        'banks',
        'journal_entries',
        'material_inventory',
        'material_types',
        'labour_types',
        'counter_entities',
        'follow_ups',
      ];
      for (final t in syncTables) {
        try {
          await db.execute(
              'ALTER TABLE $t ADD COLUMN updated_at TEXT');
        } catch (_) {/* column may already exist on partial upgrades */}
        await db.execute(
            'UPDATE $t SET updated_at = COALESCE(updated_at, created_at, CURRENT_TIMESTAMP) WHERE updated_at IS NULL');
      }
      // notes.updated_at already exists since v14 but as nullable —
      // backfill its nulls too.
      await db.execute(
          "UPDATE notes SET updated_at = COALESCE(updated_at, created_at, CURRENT_TIMESTAMP) WHERE updated_at IS NULL");

      // Bump-on-update triggers. Skip the trigger on `journal_entries`
      // for soft-delete because the delete flow already touches the row
      // — the trigger would still fire and that's the behaviour we want
      // (soft-delete must propagate to the cloud).
      const triggerTables = <String>[
        ...syncTables,
        'notes',
      ];
      for (final t in triggerTables) {
        await db.execute('''
          CREATE TRIGGER IF NOT EXISTS trg_bump_${t}_updated
          AFTER UPDATE ON $t
          FOR EACH ROW
          WHEN NEW.updated_at = OLD.updated_at
          BEGIN
            UPDATE $t SET updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
            WHERE rowid = NEW.rowid;
          END
        ''');
      }
    }

    if (oldVersion < 3) {
      // v3: soft delete, archive, change log, settings, service fee
      await db.execute(
          'ALTER TABLE journal_entries ADD COLUMN is_deleted INTEGER NOT NULL DEFAULT 0');
      await db.execute(
          'ALTER TABLE journal_entries ADD COLUMN deleted_at TEXT');
      await db.execute(
          'ALTER TABLE projects ADD COLUMN service_fee_percent REAL');
      await db.execute(
          'ALTER TABLE projects ADD COLUMN is_archived INTEGER NOT NULL DEFAULT 0');
      await db.execute('ALTER TABLE projects ADD COLUMN archived_at TEXT');

      await db.execute('''
        CREATE TABLE IF NOT EXISTS change_log (
          id TEXT PRIMARY KEY,
          entity_type TEXT NOT NULL,
          entity_id TEXT NOT NULL,
          action TEXT NOT NULL,
          original_data TEXT,
          new_data TEXT,
          note TEXT,
          timestamp TEXT NOT NULL
        )
      ''');

      await db.execute('''
        CREATE TABLE IF NOT EXISTS app_settings (
          key TEXT PRIMARY KEY,
          value TEXT
        )
      ''');

      await db.execute(
          'CREATE INDEX IF NOT EXISTS idx_je_deleted ON journal_entries(is_deleted)');
      await db.execute(
          'CREATE INDEX IF NOT EXISTS idx_cl_entity ON change_log(entity_type, entity_id)');
    }

    if (oldVersion < 16) {
      // v16: remove the customer entity entirely. The app is project-centric —
      // the client is free-text `projects.client_name`; there is no Customer /
      // Client table and no `customer_id` foreign key. Drop the three dead
      // remnants left by older versions.
      //
      // ALTER TABLE ... DROP COLUMN needs SQLite >= 3.35 (2021). It's wrapped
      // in try/catch so older engines simply keep the (now always-null,
      // never-read) columns — the model and repository no longer reference
      // them either way, so a leftover column is inert.
      try {
        await db.execute('DROP INDEX IF EXISTS idx_je_customer');
      } catch (_) {/* index may not exist */}
      try {
        await db
            .execute('ALTER TABLE journal_entries DROP COLUMN customer_id');
      } catch (_) {/* SQLite < 3.35: leave the dead column in place */}
      try {
        await db.execute('ALTER TABLE projects DROP COLUMN customer_id');
      } catch (_) {/* SQLite < 3.35: leave the dead column in place */}
      // The `customers` table was created by very old installs but never
      // written to once free-text `client_name` replaced it (v5). No FK
      // references it, so it is safe to drop outright.
      await db.execute('DROP TABLE IF EXISTS customers');
    }

    if (oldVersion < 17) {
      // v17: make material_inventory.quantity / .rate nullable so a material
      // buy can be logged without a quantity (its detail then lives in the
      // memo). Quantity-less rows are excluded from the Material Price Trend.
      //
      // SQLite can't DROP NOT NULL in place; recreate the table and copy the
      // data over. Columns are named explicitly so the copy is order-proof.
      await db.execute('''
        CREATE TABLE material_inventory_v17 (
          id TEXT PRIMARY KEY,
          project_id TEXT NOT NULL,
          supplier_id TEXT,
          transaction_id TEXT,
          material_type TEXT NOT NULL,
          unit TEXT NOT NULL,
          quantity REAL,
          rate REAL,
          total_cost REAL NOT NULL,
          txn_type TEXT NOT NULL,
          created_at TEXT NOT NULL,
          is_deleted INTEGER NOT NULL DEFAULT 0,
          deleted_at TEXT,
          updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
          FOREIGN KEY (project_id) REFERENCES projects(id),
          FOREIGN KEY (supplier_id) REFERENCES suppliers(id)
        )
      ''');
      await db.execute('''
        INSERT INTO material_inventory_v17 (
          id, project_id, supplier_id, transaction_id, material_type, unit,
          quantity, rate, total_cost, txn_type, created_at, is_deleted,
          deleted_at, updated_at)
        SELECT
          id, project_id, supplier_id, transaction_id, material_type, unit,
          quantity, rate, total_cost, txn_type, created_at, is_deleted,
          deleted_at, updated_at
        FROM material_inventory
      ''');
      await db.execute('DROP TABLE material_inventory');
      await db.execute(
          'ALTER TABLE material_inventory_v17 RENAME TO material_inventory');
      // DROP TABLE took the bump-on-update trigger with it (v15). Recreate
      // it so the cloud-sync cursor keeps tracking edits to this table.
      await db.execute('''
        CREATE TRIGGER trg_bump_material_inventory_updated
        AFTER UPDATE ON material_inventory
        FOR EACH ROW
        WHEN NEW.updated_at = OLD.updated_at
        BEGIN
          UPDATE material_inventory
          SET updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
          WHERE rowid = NEW.rowid;
        END
      ''');
    }
  }

}
