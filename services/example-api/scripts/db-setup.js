import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import pg from "pg";

const connectionString = process.env.EXAMPLE_API_DB?.trim();
if (!connectionString) {
  console.error("EXAMPLE_API_DB is required");
  process.exit(1);
}

const dbDir = path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "db");
const client = new pg.Client({ connectionString });

await client.connect();
try {
  for (const file of ["schema.sql", "seed.sql"]) {
    await client.query(fs.readFileSync(path.join(dbDir, file), "utf8"));
    console.log(`applied ${file}`);
  }
} finally {
  await client.end();
}
