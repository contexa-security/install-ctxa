const fs = require('fs');
const path = require('path');

module.exports = (req, res) => {
  const sh = fs.readFileSync(path.join(__dirname, '..', 'install.sh'), 'utf8');
  res.setHeader('Content-Type', 'text/plain; charset=utf-8');
  res.setHeader('Cache-Control', 'no-cache');
  res.send(sh);
};
