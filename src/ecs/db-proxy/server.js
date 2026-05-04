const express = require("express");
const AWS = require("aws-sdk");
const { Pool } = require("pg");

const app = express();

const {
  DB_HOST,
  DB_NAME,
  DB_USER,
  AWS_REGION
} = process.env;

// IAM DB auth signer
const signer = new AWS.RDS.Signer({
  region: AWS_REGION,
  hostname: DB_HOST,
  port: 5432,
  username: DB_USER
});

// Create a fresh pool using IAM auth token
function createPool() {
  const token = signer.getAuthToken({
    username: DB_USER
  });

  return new Pool({
    host: DB_HOST,
    user: DB_USER,
    password: token,
    database: DB_NAME,
    port: 5432,

    // IAM auth requires SSL
    ssl: {
      rejectUnauthorized: false
    },

    // keep connections short-lived (important for IAM tokens)
    max: 2,
    idleTimeoutMillis: 30000,
    connectionTimeoutMillis: 5000
  });
}

let pool = createPool();

// refresh DB auth token periodically (IAM tokens expire ~15 min)
setInterval(() => {
  console.log("Refreshing IAM DB auth token...");
  pool = createPool();
}, 10 * 60 * 1000);

// Simple health endpoint (useful for ECS + Lattice checks)
app.get("/health", (req, res) => {
  res.json({ status: "ok" });
});

// Main demo endpoint
app.get("/users", async (req, res) => {
  try {
    const result = await pool.query("SELECT NOW() as time");
    res.json({
      service: "db-proxy",
      time: result.rows[0]
    });
  } catch (err) {
    console.error("DB error:", err.message);
    res.status(500).json({
      error: "database_error",
      message: err.message
    });
  }
});

app.listen(3000, () => {
  console.log("DB proxy running on port 3000");
});