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
            body: body.slice(0, 180)
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
    return { status: "ERR", ok: false, body: err.message };
  }
}

function escapeHtml(str = "") {
  return str.replace(/[&<>"']/g, c => ({
    "&": "&amp;",
    "<": "&lt;",
    ">": "&gt;",
    "\"": "&quot;",
    "'": "&#039;"
  }[c]));
}

function card(name, path, result) {
  const cls = result.ok ? "ok" : "bad";
  return `
    <div class="card ${cls}">
      <h2>${name}</h2>
      <p class="path">${path}</p>
      <p class="status">${result.status}</p>
      <pre>${escapeHtml(result.body)}</pre>
    </div>
  `;
}

async function render() {
  const [aPublic, bPublic, aAdmin] = await Promise.all([
    callAs(clientARoleArn, "client-a", "/public/"),
    callAs(clientBRoleArn, "client-b", "/public/"),
    callAs(clientARoleArn, "client-a-admin", "/admin/")
  ]);

  return `
<!doctype html>
<html>
<head>
  <meta http-equiv="refresh" content="5">
  <title>VPC Lattice Isolation Demo</title>
  <style>
    body { font-family: Arial, sans-serif; background:#111827; color:white; padding:40px; }
    h1 { font-size:36px; margin-bottom:8px; }
    .sub { color:#cbd5e1; margin-bottom:32px; }
    .grid { display:grid; grid-template-columns: repeat(3, 1fr); gap:24px; }
    .card { border-radius:16px; padding:24px; min-height:220px; }
    .ok { background:#064e3b; border:2px solid #34d399; }
    .bad { background:#7f1d1d; border:2px solid #f87171; }
    .path { color:#cbd5e1; font-size:18px; }
    .status { font-size:64px; font-weight:bold; margin:16px 0; }
    pre { white-space:pre-wrap; color:#e5e7eb; font-size:13px; max-height:90px; overflow:hidden; }
  </style>
</head>
<body>
  <h1>VPC Lattice Isolation Demo</h1>
  <div class="sub">Signed requests through VPC Lattice. Auto-refreshes every 5 seconds.</div>
  <div class="grid">
    ${card("Client A", "/public/", aPublic)}
    ${card("Client B", "/public/", bPublic)}
    ${card("Admin Route", "/admin/", aAdmin)}
  </div>
</body>
</html>`;
}

http.createServer(async (req, res) => {
  const html = await render();
  res.writeHead(200, { "Content-Type": "text/html" });
  res.end(html);
}).listen(3000, () => {
  console.log("dashboard listening on http://localhost:3000");
});
