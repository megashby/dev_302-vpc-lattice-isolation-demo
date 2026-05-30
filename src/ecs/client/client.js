const http = require("http");
const { defaultProvider } = require("@aws-sdk/credential-provider-node");
const { SignatureV4 } = require("@smithy/signature-v4");
const { Sha256 } = require("@aws-crypto/sha256-js");
const { HttpRequest } = require("@smithy/protocol-http");
const { STSClient, GetCallerIdentityCommand } = require("@aws-sdk/client-sts");

const endpoint = process.env.LATTICE_ENDPOINT;

async function getIdentity() {
  try {
    const sts = new STSClient({ region: "us-east-1" });
    const identity = await sts.send(new GetCallerIdentityCommand({}));

    console.log("STS identity ARN:", identity.Arn);
  } catch (err) {
    console.error("STS identity lookup failed:", err);
  }
}

async function makeRequest() {
  try {
    await getIdentity();

    const credentials = await defaultProvider()();

    const signer = new SignatureV4({
      credentials,
      region: "us-east-1",
      service: "vpc-lattice-svcs",
      sha256: Sha256,
    });

    const request = new HttpRequest({
      protocol: "http:",
      hostname: endpoint,
      method: "GET",
      path: "/public/",
      headers: {
        host: endpoint,
        "x-amz-content-sha256": "UNSIGNED-PAYLOAD",
      },
    });

    const signedRequest = await signer.sign(request);

    console.log("---- REQUEST ----");
    console.log("path:", request.path);
    console.log("host:", endpoint);
    console.log(
      "auth header exists:",
      !!signedRequest.headers.authorization
    );

    const options = {
      hostname: endpoint,
      port: 80,
      path: "/public/",
      method: "GET",
      headers: signedRequest.headers,
    };

    const req = http.request(options, (res) => {
      let body = "";

      res.on("data", (chunk) => {
        body += chunk;
      });

      res.on("end", () => {
        console.log("status:", res.statusCode);
        console.log("body:", body);
      });
    });

    req.on("error", (err) => {
      console.error("request error:", err.message);
    });

    req.end();
  } catch (err) {
    console.error("client error:", err);
  }
}

setInterval(makeRequest, 10000);
makeRequest();