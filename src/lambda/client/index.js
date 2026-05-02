const https = require("https");

exports.handler = async () => {
  const url = process.env.LATTICE_URL;

  return new Promise((resolve) => {
    https.get(`https://${url}`, (res) => {
      let data = "";
      res.on("data", chunk => data += chunk);
      res.on("end", () => {
        resolve({
          statusCode: res.statusCode,
          body: data
        });
      });
    });
  });
};