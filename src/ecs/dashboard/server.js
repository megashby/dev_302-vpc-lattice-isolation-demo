const http = require("http");
const { STSClient, AssumeRoleCommand } = require("@aws-sdk/client-sts");
const {
  CloudWatchLogsClient,
  FilterLogEventsCommand
} = require("@aws-sdk/client-cloudwatch-logs");
const { SignatureV4 } = require("@smithy/signature-v4");
const { Sha256 } = require("@aws-crypto/sha256-js");
const { HttpRequest } = require("@smithy/protocol-http");

const region = process.env.AWS_REGION || "us-east-1";
const endpoint = process.env.LATTICE_ENDPOINT;
const clientARoleArn = process.env.CLIENT_A_ROLE_ARN;
const clientBRoleArn = process.env.CLIENT_B_ROLE_ARN;

const REQUIRED_CONSECUTIVE_RESULTS = 2;
const LOG_LOOKBACK_MINUTES = 2;

const logs = new CloudWatchLogsClient({ region });
const stateCache = new Map();

async function assume(roleArn, name) {
  const sts = new STSClient({ region });

  const res = await sts.send(
    new AssumeRoleCommand({
      RoleArn: roleArn,
      RoleSessionName: `dashboard-${name}`
    })
  );

  return {
    accessKeyId: res.Credentials.AccessKeyId,
    secretAccessKey: res.Credentials.SecretAccessKey,
    sessionToken: res.Credentials.SessionToken
  };
}

async function callAs(roleArn, name, path) {
  try {
    const credentials = await assume(roleArn, name);

    const signer = new SignatureV4({
      credentials,
      region,
      service: "vpc-lattice-svcs",
      sha256: Sha256
    });

    const request = new HttpRequest({
      protocol: "http:",
      hostname: endpoint,
      method: "GET",
      path,
      headers: {
        host: endpoint,
        "x-amz-content-sha256": "UNSIGNED-PAYLOAD"
      }
    });

    const signed = await signer.sign(request);

    return await new Promise((resolve) => {
      const req = http.request(
        {
          hostname: endpoint,
          port: 80,
          path,
          method: "GET",
          headers: signed.headers
        },
        (res) => {
          let body = "";

          res.on("data", (chunk) => {
            body += chunk;
          });

          res.on("end", () => {
            resolve({
              status: res.statusCode,
              headers: res.headers || {},
              ok: res.statusCode >= 200 && res.statusCode < 300,
              body
            });
          });
        }
      );

      req.on("error", (err) =>
        resolve({
          status: "ERR",
          headers: {},
          ok: false,
          body: err.message
        })
      );

      req.end();
    });
  } catch (err) {
    return {
      status: "ERR",
      headers: {},
      ok: false,
      body: err.message
    };
  }
}

function cleanLogMessage(message = "") {
  return String(message)
    .replace(/<[^>]*>/g, "")
    .replace(/\s+/g, " ")
    .trim();
}

async function getRecentLogs(logGroupName, minutes = LOG_LOOKBACK_MINUTES) {
  if (!logGroupName) return "log group not configured";

  try {
    const res = await logs.send(
      new FilterLogEventsCommand({
        logGroupName,
        startTime: Date.now() - minutes * 60 * 1000,
        limit: 100,
        interleaved: true
      })
    );

    const output = (res.events || [])
      .sort((a, b) => b.timestamp - a.timestamp)
      .map((e) => `${new Date(e.timestamp).toISOString()} ${cleanLogMessage(e.message)}`)
      .join("\n");

    return output || `no logs in the last ${minutes} minutes`;
  } catch (err) {
    return `error reading logs from ${logGroupName}: ${err.message}`;
  }
}

function escapeHtml(str = "") {
  return String(str).replace(/[&<>"']/g, (c) => ({
    "&": "&amp;",
    "<": "&lt;",
    ">": "&gt;",
    "\"": "&quot;",
    "'": "&#039;"
  }[c]));
}

function summarizeBody(body = "") {
  const lower = body.toLowerCase();

  if (lower.includes("maintenance")) return "MAINTENANCE PAGE";
  if (lower.includes("admin")) return "ADMIN PAGE";
  if (lower.includes("public")) return "PUBLIC PAGE";
  if (lower.includes("accessdenied") || lower.includes("not authorized")) {
    return "ACCESS DENIED";
  }

  return body.replace(/<[^>]*>/g, "").replace(/\s+/g, " ").slice(0, 160);
}

function rawState(path, result) {
  const summary = summarizeBody(result.body);

  if (result.status === 403) return "ISOLATED";
  if (result.status === "ERR") return "ERROR";

  if (path === "/admin/") {
    if (summary === "MAINTENANCE PAGE") return "MAINTENANCE MODE";
    if (summary === "ADMIN PAGE") return "ADMIN PAGE";
  }

  if (result.ok) return "ALLOWED";

  return `HTTP ${result.status}`;
}

function stableKey(clientName, path) {
  return `${clientName}:${path}`;
}

function getStableState(clientName, path, result) {
  const key = stableKey(clientName, path);
  const observed = rawState(path, result);
  const previous = stateCache.get(key);

  if (!previous) {
    const initial = {
      stable: observed,
      candidate: observed,
      count: 1
    };

    stateCache.set(key, initial);
    return initial;
  }

  if (observed === previous.stable) {
    previous.candidate = observed;
    previous.count = 1;
    return previous;
  }

  if (observed === previous.candidate) {
    previous.count += 1;
  } else {
    previous.candidate = observed;
    previous.count = 1;
  }

  if (previous.count >= REQUIRED_CONSECUTIVE_RESULTS) {
    previous.stable = observed;
    previous.count = 1;
  }

  return previous;
}

function classifyStable(stableState, result) {
  if (stableState === "ISOLATED") {
    return {
      label: "ISOLATED",
      detail: "VPC Lattice auth policy denied this client",
      className: "bad"
    };
  }

  if (stableState === "ERROR") {
    return {
      label: "ERROR",
      detail: result.body,
      className: "bad"
    };
  }

  if (stableState === "MAINTENANCE MODE") {
    return {
      label: "MAINTENANCE MODE",
      detail: "Admin route shifted to maintenance target group",
      className: "warn"
    };
  }

  if (stableState === "ADMIN PAGE") {
    return {
      label: "ADMIN PAGE",
      detail: "Admin route points to primary service",
      className: "ok"
    };
  }

  if (stableState === "ALLOWED") {
    return {
      label: "ALLOWED",
      detail: "Request succeeded through VPC Lattice",
      className: "ok"
    };
  }

  return {
    label: stableState,
    detail: summarizeBody(result.body),
    className: "warn"
  };
}

function card(clientName, path, result) {
  const stable = getStableState(clientName, path, result);
  const state = classifyStable(stable.stable, result);
  const bodySummary = summarizeBody(result.body);

  const pending =
    stable.candidate !== stable.stable
      ? `<div class="pending">observed ${escapeHtml(stable.candidate)} ${stable.count}/${REQUIRED_CONSECUTIVE_RESULTS}</div>`
      : "";

  return `
    <div class="card ${state.className}">
      <div class="eyebrow">${clientName}</div>
      <h2>${escapeHtml(state.label)}</h2>
      <div class="path">${escapeHtml(path)}</div>
      <div class="status">HTTP ${escapeHtml(result.status)}</div>
      <p>${escapeHtml(state.detail)}</p>
      <div class="summary">Response: ${escapeHtml(bodySummary)}</div>
      ${pending}
    </div>
  `;
}

function logSection(title, logs, open = false) {
  return `
    <details class="logs" ${open ? "open" : ""}>
      <summary>${escapeHtml(title)}</summary>
      <pre>${escapeHtml(logs)}</pre>
    </details>
  `;
}

function previewError(path, result) {
  return `
<!doctype html>
<html>
<head>
  <style>
    body {
      font-family: Arial, sans-serif;
      background:#111827;
      color:white;
      margin:0;
      padding:32px;
    }

    .box {
      background:#7f1d1d;
      border:3px solid #f87171;
      border-radius:16px;
      padding:28px;
    }

    h1 {
      margin-top:0;
      font-size:24px;
    }

    code {
      background:#111827;
      padding:4px 8px;
      border-radius:6px;
    }

    pre {
      white-space:pre-wrap;
      overflow:auto;
    }
  </style>
</head>
<body>
  <div class="box">
    <h1>Preview failed</h1>
    <p><strong>Path:</strong> <code>${escapeHtml(path)}</code></p>
    <p><strong>Status:</strong> <code>${escapeHtml(result.status)}</code></p>
    <pre>${escapeHtml(result.body)}</pre>
  </div>
</body>
</html>`;
}

async function renderPreview(path) {
  const result = await callAs(
    clientARoleArn,
    `preview-${path.replace(/\//g, "") || "root"}`,
    path
  );

  if (!result.ok) {
    return {
      status: result.status === "ERR" ? 502 : result.status,
      body: previewError(path, result)
    };
  }

  return {
    status: 200,
    body: result.body
  };
}

async function render() {
  const [
    aPublic,
    aAdmin,
    bPublic,
    bAdmin,
    routerLogs,
    applyAuthLogs,
    isolateEndpointLogs,
    clientALogs,
    clientBLogs
  ] = await Promise.all([
    callAs(clientARoleArn, "client-a-public", "/public/"),
    callAs(clientARoleArn, "client-a-admin", "/admin/"),
    callAs(clientBRoleArn, "client-b-public", "/public/"),
    callAs(clientBRoleArn, "client-b-admin", "/admin/"),
    getRecentLogs(process.env.ROUTER_LOG_GROUP),
    getRecentLogs(process.env.APPLY_AUTH_LOG_GROUP),
    getRecentLogs(process.env.ISOLATE_ENDPOINT_LOG_GROUP),
    getRecentLogs(process.env.CLIENT_A_LOG_GROUP),
    getRecentLogs(process.env.CLIENT_B_LOG_GROUP)
  ]);

  return `
<!doctype html>
<html>
<head>
  <title>VPC Lattice Isolation Demo</title>
  <style>
    body {
      font-family: Arial, sans-serif;
      background:#0f172a;
      color:white;
      padding:40px;
      margin:0;
    }

    h1 {
      font-size:40px;
      margin:0 0 8px 0;
    }

    .sub {
      color:#cbd5e1;
      margin-bottom:18px;
      font-size:18px;
    }

    button {
      background:#2563eb;
      color:white;
      border:0;
      border-radius:10px;
      padding:12px 18px;
      font-size:16px;
      cursor:pointer;
      margin-bottom:24px;
    }

    .grid {
      display:grid;
      grid-template-columns: repeat(2, 1fr);
      gap:24px;
    }

    .card {
      border-radius:18px;
      padding:28px;
      min-height:230px;
      box-shadow:0 12px 30px rgba(0,0,0,.25);
    }

    .ok {
      background:#064e3b;
      border:3px solid #34d399;
    }

    .bad {
      background:#7f1d1d;
      border:3px solid #f87171;
    }

    .warn {
      background:#78350f;
      border:3px solid #fbbf24;
    }

    .eyebrow {
      color:#e5e7eb;
      font-size:18px;
      letter-spacing:.08em;
      text-transform:uppercase;
      margin-bottom:10px;
    }

    h2 {
      font-size:36px;
      margin:0 0 12px 0;
    }

    .path {
      color:#cbd5e1;
      font-size:22px;
      margin-bottom:16px;
      font-family: monospace;
    }

    .status {
      font-size:28px;
      font-weight:bold;
      margin-bottom:14px;
    }

    p {
      color:#e5e7eb;
      font-size:18px;
      margin:0;
      line-height:1.4;
    }

    .summary {
      margin-top:14px;
      font-size:18px;
      color:#dbeafe;
    }

    .pending {
      margin-top:14px;
      font-size:14px;
      color:#fde68a;
      opacity:.9;
    }

    .preview-grid {
      margin-top:32px;
      display:grid;
      grid-template-columns:1fr 1fr;
      gap:24px;
    }

    .preview-card {
      background:#020617;
      border:1px solid #334155;
      border-radius:12px;
      padding:16px;
    }

    .preview-card h2 {
      font-size:24px;
      margin:0 0 12px 0;
    }

    .preview-card iframe {
      width:100%;
      height:300px;
      border:none;
      border-radius:8px;
      background:white;
    }

    .log-grid {
      margin-top:32px;
      display:grid;
      grid-template-columns:1fr;
      gap:12px;
    }

    .logs {
      background:#020617;
      border:1px solid #334155;
      border-radius:12px;
      padding:16px;
    }

    .logs summary {
      cursor:pointer;
      font-size:20px;
      font-weight:bold;
    }

    .logs pre {
      margin-top:12px;
      white-space:pre-wrap;
      color:#cbd5e1;
      font-size:18px;
      max-height:600px;
      overflow:auto;
      line-height:1.45;
    }
  </style>
</head>
<body>
  <h1>VPC Lattice Isolation Demo</h1>
  <div class="sub">
    Signed requests through VPC Lattice as Client A and Client B.
    Click refresh to update live state. Logs are delayed and shown newest first.
  </div>

  <button onclick="window.location.reload()">Refresh status</button>

  <div class="grid">
    ${card("Client A", "/public/", aPublic)}
    ${card("Client A", "/admin/", aAdmin)}
    ${card("Client B", "/public/", bPublic)}
    ${card("Client B", "/admin/", bAdmin)}
  </div>

  <div class="preview-grid">
    <div class="preview-card">
      <h2>Public Route: /public/</h2>
      <iframe src="/preview/public"></iframe>
    </div>

    <div class="preview-card">
      <h2>Admin Route: /admin/</h2>
      <iframe src="/preview/admin"></iframe>
    </div>
  </div>

  <div class="log-grid">
    ${logSection(`Client A ECS logs, last ${LOG_LOOKBACK_MINUTES} min`, clientALogs)}
    ${logSection(`Client B ECS logs, last ${LOG_LOOKBACK_MINUTES} min`, clientBLogs)}
    ${logSection(`Router Lambda logs, last ${LOG_LOOKBACK_MINUTES} min`, routerLogs)}
    ${logSection(`ApplyAuth Lambda logs, last ${LOG_LOOKBACK_MINUTES} min`, applyAuthLogs)}
    ${logSection(`IsolateEndpoint Lambda logs, last ${LOG_LOOKBACK_MINUTES} min`, isolateEndpointLogs)}
  </div>
</body>
</html>`;
}

http.createServer(async (req, res) => {
  if (req.url === "/preview/public") {
    const preview = await renderPreview("/public/");

    res.writeHead(preview.status, {
      "Content-Type": "text/html",
      "Cache-Control": "no-store"
    });

    return res.end(preview.body);
  }

  if (req.url === "/preview/admin") {
    const preview = await renderPreview("/admin/");

    res.writeHead(preview.status, {
      "Content-Type": "text/html",
      "Cache-Control": "no-store"
    });

    return res.end(preview.body);
  }

  const html = await render();

  res.writeHead(200, {
    "Content-Type": "text/html",
    "Cache-Control": "no-store"
  });

  res.end(html);
}).listen(3000, () => {
  console.log("dashboard listening on :3000");
});