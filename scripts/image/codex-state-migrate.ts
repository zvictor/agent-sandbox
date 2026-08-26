import { Database } from "bun:sqlite";
import { isAbsolute, join } from "node:path";
import { readdirSync } from "node:fs";

function normalizedHome(name: string, value: string | undefined): string {
  if (!value || !isAbsolute(value)) {
    throw new Error(`${name} must be an absolute path`);
  }

  return value.length > 1 ? value.replace(/\/+$/, "") : value;
}

function migrateDatabase(
  databasePath: string,
  sourcePrefix: string,
  targetPrefix: string,
): number {
  const database = new Database(databasePath, {
    readwrite: true,
    strict: true,
  });

  try {
    database.run("PRAGMA busy_timeout = 5000");
    const tableQuery = database.prepare(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?1",
    );
    const threadsTable = tableQuery.get("threads");
    tableQuery.finalize();
    if (!threadsTable) {
      return 0;
    }

    database.run("BEGIN IMMEDIATE");
    try {
      const result = database.run(
        `
        UPDATE threads
        SET rollout_path = ?1 || substr(rollout_path, ?2)
        WHERE substr(rollout_path, 1, ?3) = ?4
        `,
        [
          targetPrefix,
          sourcePrefix.length + 1,
          sourcePrefix.length,
          sourcePrefix,
        ],
      );
      database.run("COMMIT");
      return Number(result.changes);
    } catch (error) {
      database.run("ROLLBACK");
      throw error;
    }
  } finally {
    database.close(true);
  }
}

function main(): void {
  const sourceHome = normalizedHome(
    "AGENT_CODEX_ROLLOUT_SOURCE_HOME",
    process.env.AGENT_CODEX_ROLLOUT_SOURCE_HOME,
  );
  const targetHome = normalizedHome("CODEX_HOME", process.env.CODEX_HOME);
  if (sourceHome === targetHome) {
    return;
  }

  const sourcePrefix = `${sourceHome}/`;
  const targetPrefix = `${targetHome}/`;
  const databaseNames = readdirSync(targetHome, { withFileTypes: true })
    .filter(
      (entry) => entry.isFile() && /^state_[0-9]+\.sqlite$/.test(entry.name),
    )
    .map((entry) => entry.name)
    .sort();

  let migratedPathCount = 0;
  for (const databaseName of databaseNames) {
    migratedPathCount += migrateDatabase(
      join(targetHome, databaseName),
      sourcePrefix,
      targetPrefix,
    );
  }

  if (migratedPathCount > 0) {
    console.error(
      `[agent] migrated ${migratedPathCount} Codex rollout paths from ${sourceHome} to ${targetHome}`,
    );
  }
}

try {
  main();
} catch (error) {
  const message = error instanceof Error ? error.message : String(error);
  console.error(`[agent] ERROR: could not migrate Codex rollout paths: ${message}`);
  process.exitCode = 1;
}
