this is not javascript
import http from "node:http";
import pg from "pg";

const port = Number(process.env.PORT ?? 4201);
const connectionString = process.env.EXAMPLE_API_DB?.trim();

if (!connectionString) {
  console.error("EXAMPLE_API_DB is required");
  process.exit(1);
}

const pool = new pg.Pool({ connectionString });

function sendJson(res, status, body) {
  res.writeHead(status, { "content-type": "application/json" });
  res.end(JSON.stringify(body));
}

const server = http.createServer(async (req, res) => {
  try {
    if (req.method === "GET" && req.url === "/health") {
      try {
        await pool.query("SELECT 1");
        return sendJson(res, 200, { status: "ok" });
      } catch (err) {
        return sendJson(res, 503, { status: "db-unavailable", error: err.message });
      }
    }

    if (req.method === "GET" && req.url === "/items") {
      const { rows } = await pool.query("SELECT id, name FROM items ORDER BY id");
      return sendJson(res, 200, rows);
    }

    sendJson(res, 404, { error: "not found" });
  } catch (err) {
    sendJson(res, 500, { error: err.message });
  }
});

server.listen(port, () => {
  console.log(`example-api listening on ${port}`);
});
