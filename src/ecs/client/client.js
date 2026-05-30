const https = require("https");
const { defaultProvider } = require("@aws-sdk/credential-provider-node");
const { SignatureV4 } = require("@aws-sdk/signature-v4");
const { HttpRequest } = require("@aws-sdk/protocol-http");
const { Sha256 } = require("@aws-crypto/sha256-js");
const { STSClient, GetCallerIdentityCommand } = require("@aws-sdk/client-sts");

const endpoint = process.env.LATTICE_ENDPOINT;
const region = process.env.AWS_REGION || "us-east-1";

console.log("endpoint:", endpoint);
console.log("region:", region);

const signer = new SignatureV4({
  credentials: defaultProvider(),
  region,
  service: "vpc-lattice-svcs",
  sha256: Sha256,
});

const sts = new STSClient({ region });

async function logIdentity() {
  try {
    const res = await sts.send(new GetCallerIdentityCommand({}));
    console.log("identity:", res.Arn || res.UserId || res);
  } catch (e) {
    console.error("identity error:", e);
  }
}

async function call() {
  try {
    await logIdentity();

    const request = new HttpRequest({
      method: "GET",
      protocol: "https:",
      hostname: endpoint,
      path: "/public/",   // MUST match your service exactly
      headers: {
        host: endpoint,
      },
    });

    const signedRequest = await signer.sign(request);

    console.log("signed headers keys:", Object.keys(signedRequest.headers));

    console.log("AUTH HEADER:", signedRequest.headers["authorization"]);

    const options = {
      hostname: signedRequest.hostname,
      path: signedRequest.path,
      method: signedRequest.method,
      headers: signedRequest.headers,
    };

    const req = https.request(options, (res) => {
      let body = "";

      res.on("data", (chunk) => (body += chunk));

      res.on("end", () => {
        console.log("client status:", res.statusCode);
        if (body) console.log("body:", body);
      });
    });

    req.on("error", (e) => console.error("request error:", e.message));

    req.end();
  } catch (err) {
    console.error("call error:", err);
  }
}

setInterval(call, 5000);