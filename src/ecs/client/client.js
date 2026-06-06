const http = require("http");
const { defaultProvider } = require("@aws-sdk/credential-provider-node");
const { SignatureV4 } = require("@smithy/signature-v4");
const { Sha256 } = require("@aws-crypto/sha256-js");
const { HttpRequest } = require("@smithy/protocol-http");
const { STSClient, GetCallerIdentityCommand } = require("@aws-sdk/client-sts");

const endpoint = process.env.LATTICE_ENDPOINT;
const region = process.env.AWS_REGION || "us-east-1";

const requestPaths = ["/public/", "/admin/"];
let requestIndex = 0;

function summarizeBody(body = "") {
  const lower = body.toLowerCase();

  if (lower.includes("maintenance")) return "MAINTENANCE PAGE";
  if (lower.includes("admin")) return "ADMIN PAGE";
  if (lower.includes("public")) return "PUBLIC PAGE";
  if (lower.includes("accessdenied") || lower.includes("not authorized")) {
    return "ACCESS DENIED";
  }

  return body.replace(/\s+/g, " ").slice(0, 160);
}

async function getIdentity() {
  try {
    const sts = new STSClient({ region });
    const identity = await sts.send(new GetCallerIdentityCommand({}));
    console.log("STS identity ARN:", identity.Arn);
  } catch (err) {
    console.error("STS identity lookup failed:", err.message);
  }
}

async function makeRequest() {
  const requestPath = requestPaths[requestIndex % requestPaths.length];
  requestIndex += 1;

  try {
    await getIdentity();

    const credentials = await defaultProvider()();

    const signer = new SignatureV4({
      credentials,
      region,
      service: "vpc-lattice-svcs",
      sha256: Sha256,
    });

    const request = new HttpRequest({
      protocol: "http:",
      hostname: endpoint,
      method: "GET",
      path: requestPath,
      headers: {
        host: endpoint,
        "x-amz-content-sha256": "UNSIGNED-PAYLOAD",
      },
    });

    const signedRequest = await signer.sign(request);

    console.log("---- REQUEST ----");
    console.log("path:", requestPath);
    console.log("host:", endpoint);
    console.log("auth header exists:", !!signedRequest.headers.authorization);

    const req = http.request(
      {
        hostname: endpoint,
        port: 80,
        path: requestPath,
        method: "GET",
        headers: signedRequest.headers,
      },
      (res) => {
        let body = "";

        res.on("data", (chunk) => {
          body += chunk;
        });

        res.on("end", () => {
          console.log("status:", res.statusCode);
          console.log("result:", summarizeBody(body));
        });
      }
    );

    req.on("error", (err) => {
      console.error("request error:", err.message);
    });

    req.end();
  } catch (err) {
    console.error("client error:", err.message);
  }
}

setInterval(makeRequest, 10000);
makeRequest();
