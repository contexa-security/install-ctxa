const fs = require('fs');
const path = require('path');

// vercel.json rewrites all paths to /api, but req.url preserves the original
// request path so we can route by extension or User-Agent.
//
// Routing:
//   /install.ps1, /win, /windows                       -> install.ps1
//   PowerShell User-Agent (any path)                   -> install.ps1
//   anything else (default - keeps curl pipe sh stable) -> install.sh
module.exports = (req, res) => {
  const url = (req.url || '/').toLowerCase();
  const ua  = (req.headers['user-agent'] || '').toLowerCase();

  const wantsPs1 =
       url.includes('.ps1')
    || url.startsWith('/win')
    || ua.includes('powershell')
    || ua.includes('windowspowershell');

  const fileName = wantsPs1 ? 'install.ps1' : 'install.sh';
  const body = fs.readFileSync(path.join(__dirname, '..', fileName), 'utf8');

  res.setHeader('Content-Type', 'text/plain; charset=utf-8');
  res.setHeader('Cache-Control', 'no-cache');
  res.send(body);
};
