const http = require("http");
const { STSClient, AssumeRoleCommand } = require("@aws-sdk/client-sts");
const { SignatureV4 } = require("@smithy/signature-v4");
const { Sha256 } = require("@aws-crypto/sha256-js");
const { HttpRequest } = require("@smithy/protocol-http");

const region = process.env.AWS_REGION || "us-east-1";
const endpoint = process.env.LATTICE_ENDPOINT;
const clientARoleArn = process.env.CLIENT_A_ROLE_ARN;
const clientBRoleArn = process.env.CLIENT_B_ROLE_ARN;

async function assume(roleArn, name) {
  const sts = new STSClient({ region });

  const res = await sts.send(new AssumeRoleCommand({
    RoleArn: roleArn,
    RoleSessionName: `dashboard-${name}`
  }));

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
      const req = http.request({
        hostname: endpoint,
        port: 80,
        path,
        method: "GET",
        headers: signed.headers
      }, (res) => {
        let body = "";

        res.on("data", chunk => body += chunk);

        res.on("end", () => {
          resolve({
            status: res.statusCode,
            ok: res.statusCode >= 200 && res.statusCode < 300,
            body
          });
        });
      });

      req.on("error", err => resolve({
        status: "ERR",
        ok: false,
        body: err.message
      }));

      req.end();
    });
  } catch (err) {
    return {
      status: "ERR",
      ok: false,
      body: err.message
    };
  }
}

function classify(path, result) {
  const body = (result.body || "").toLowerCase();

  if (result.status === 403) {
    return {
      label: "ISOLATED",
      detail: "VPC Lattice auth policy denied this client",
      className: "bad"
    };
  }

  if (result.status === "ERR") {
    return {
      label: "ERROR",
      detail: result.body,
      className: "bad"
    };
  }

  if (path === "/admin/") {
    if (body.includes("maintenance")) {
      return {
        label: "MAINTENANCE MODE",
        detail: "Admin route shifted to maintenance target group",
        className: "warn"
      };
    }

    if (body.includes("admin")) {
      return {
        label: "ADMIN PAGE",
        detail: "Admin route still points to primary service",
        className: "ok"
      };
    }
  }

  if (result.ok) {
    return {
      label: "ALLOWED",
      detail: "Request succeeded through VPC Lattice",
      className: "ok"
    };
  }

  return {
    label: `${result.status}`,
    detail: result.body.slice(0, 140),
    className: "warn"
  };
}

function card(clientName, path, result) {
  const state = classify(path, result);

  return `
    <div class="card ${state.className}">
      <div class="eyebrow">${clientName}</div>
      <h2>${state.label}</h2>
      <div class="path">${path}</div>
      <div class="status">HTTP ${result.status}</div>
      <p>${state.detail}</p>
    </div>
  `;
}

async function render() {
  const [aPublic, aAdmin, bPublic, bAdmin] = await Promise.all([
    callAs(clientARoleArn, "client-a-public", "/public/"),
    callAs(clientARoleArn, "client-a-admin", "/admin/"),
    callAs(clientBRoleArn, "client-b-public", "/public/"),
    callAs(clientBRoleArn, "client-b-admin", "/admin/")
  ]);

  return `
<!doctype html>
<html>
<head>
  <meta http-equiv="refresh" content="5">
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
      margin-bottom:32px;
      font-size:18px;
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
      font-size:44px;
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
  </style>
</head>
<body>
  <h1>VPC Lattice Isolation Demo</h1>
  <div class="sub">Signed requests through VPC Lattice as Client A and Client B. Auto-refreshes every 5 seconds.</div>

  <div class="grid">
    ${card("Client A", "/public/", aPublic)}
    ${card("Client A", "/admin/", aAdmin)}
    ${card("Client B", "/public/", bPublic)}
    ${card("Client B", "/admin/", bAdmin)}
  </div>
</body>
</html>`;
}

http.createServer(async (req, res) => {
  const html = await render();
  res.writeHead(200, { "Content-Type": "text/html" });
  res.end(html);
}).listen(3000, () => {
  console.log("dashboard listening on :3000");
});