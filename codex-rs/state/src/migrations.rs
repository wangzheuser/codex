use std::borrow::Cow;

use sqlx::AssertSqlSafe;
use sqlx::SqlSafeStr;
use sqlx::SqlitePool;
use sqlx::migrate::Migration;
use sqlx::migrate::Migrator;

pub(crate) static STATE_MIGRATOR: Migrator = sqlx::migrate!("./migrations");
pub(crate) static LOGS_MIGRATOR: Migrator = sqlx::migrate!("./logs_migrations");
pub(crate) static GOALS_MIGRATOR: Migrator = sqlx::migrate!("./goals_migrations");
pub(crate) static MEMORIES_MIGRATOR: Migrator = sqlx::migrate!("./memory_migrations");

/// Allow an older Codex binary to open a database that has already been
/// migrated by a newer binary running in parallel.
///
/// We intentionally ignore applied migration versions that are newer than the
/// embedded migration set. Known migration versions are still validated by
/// checksum, so this only relaxes the "database is ahead of me" case.
fn runtime_migrator(base: &'static Migrator) -> Migrator {
    Migrator {
        migrations: runtime_migrations(base),
        ignore_missing: true,
        locking: base.locking,
        no_tx: base.no_tx,
        table_name: base.table_name.clone(),
        create_schemas: base.create_schemas.clone(),
    }
}

#[cfg(windows)]
fn runtime_migrations(base: &'static Migrator) -> Cow<'static, [Migration]> {
    Cow::Owned(
        base.migrations
            .iter()
            .map(|migration| {
                Migration::new(
                    migration.version,
                    migration.description.clone(),
                    migration.migration_type,
                    AssertSqlSafe(with_crlf_line_endings(migration.sql.as_str())).into_sql_str(),
                    migration.no_tx,
                )
            })
            .collect(),
    )
}

#[cfg(not(windows))]
fn runtime_migrations(base: &'static Migrator) -> Cow<'static, [Migration]> {
    Cow::Borrowed(base.migrations.as_ref())
}

pub(crate) fn runtime_state_migrator() -> Migrator {
    runtime_migrator(&STATE_MIGRATOR)
}

pub(crate) fn runtime_logs_migrator() -> Migrator {
    runtime_migrator(&LOGS_MIGRATOR)
}

pub(crate) fn runtime_goals_migrator() -> Migrator {
    runtime_migrator(&GOALS_MIGRATOR)
}

pub(crate) fn runtime_memories_migrator() -> Migrator {
    runtime_migrator(&MEMORIES_MIGRATOR)
}

#[cfg(windows)]
fn with_crlf_line_endings(sql: &str) -> String {
    sql.replace("\r\n", "\n").replace('\n', "\r\n")
}

fn with_lf_line_endings(sql: &str) -> String {
    sql.replace("\r\n", "\n")
}

pub(crate) async fn repair_line_ending_migration_checksums(
    pool: &SqlitePool,
    migrator: &Migrator,
) -> anyhow::Result<()> {
    let migrations_table_exists = sqlx::query_scalar::<_, i64>(
        "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = '_sqlx_migrations'",
    )
    .fetch_optional(pool)
    .await?
    .is_some();
    if !migrations_table_exists {
        return Ok(());
    }

    for migration in migrator.migrations.iter() {
        let lf_migration = Migration::new(
            migration.version,
            migration.description.clone(),
            migration.migration_type,
            AssertSqlSafe(with_lf_line_endings(migration.sql.as_str())).into_sql_str(),
            migration.no_tx,
        );
        if lf_migration.checksum == migration.checksum {
            continue;
        }

        sqlx::query(
            r#"
UPDATE _sqlx_migrations
SET checksum = ?
WHERE version = ?
  AND checksum = ?
            "#,
        )
        .bind(migration.checksum.as_ref())
        .bind(migration.version)
        .bind(lf_migration.checksum.as_ref())
        .execute(pool)
        .await?;
    }

    Ok(())
}

pub(crate) async fn repair_legacy_recency_migration_version(
    pool: &SqlitePool,
    migrator: &Migrator,
) -> anyhow::Result<()> {
    let Some(recency_migration) = migrator
        .migrations
        .iter()
        .find(|migration| migration.version == 39)
    else {
        return Ok(());
    };
    let lf_recency_migration = Migration::new(
        recency_migration.version,
        recency_migration.description.clone(),
        recency_migration.migration_type,
        AssertSqlSafe(with_lf_line_endings(recency_migration.sql.as_str())).into_sql_str(),
        recency_migration.no_tx,
    );
    let migrations_table_exists = sqlx::query_scalar::<_, i64>(
        "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = '_sqlx_migrations'",
    )
    .fetch_optional(pool)
    .await?
    .is_some();
    if !migrations_table_exists {
        return Ok(());
    }

    sqlx::query(
        r#"
UPDATE _sqlx_migrations
SET version = ?, description = ?, checksum = ?
WHERE version = ?
  AND (checksum = ? OR checksum = ?)
  AND NOT EXISTS (
      SELECT 1 FROM _sqlx_migrations WHERE version = ?
  )
        "#,
    )
    .bind(recency_migration.version)
    .bind(recency_migration.description.as_ref())
    .bind(recency_migration.checksum.as_ref())
    .bind(38_i64)
    .bind(recency_migration.checksum.as_ref())
    .bind(lf_recency_migration.checksum.as_ref())
    .bind(recency_migration.version)
    .execute(pool)
    .await?;
    Ok(())
}

#[cfg(test)]
#[path = "migrations_tests.rs"]
mod tests;
