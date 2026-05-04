const https = require("https");

const endpoint = process.env.LATTICE_ENDPOINT;

setInterval(() => {
  https.get(`https://${endpoint}/users`, (res) => {
    console.log("client status:", res.statusCode);
  }).on("error", (e) => {
    console.error("error:", e.message);
  });
}, 5000);