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
  const filePath = path.join(__dirname, '..', fileName);

  // Fail soft when the script file is missing (deploy without expected asset).
  // Returning a plain 503 prevents Vercel from leaking a Node stack trace.
  let body;
  try {
    body = fs.readFileSync(filePath, 'utf8');
  } catch (err) {
    res.statusCode = 503;
    res.setHeader('Content-Type', 'text/plain; charset=utf-8');
    res.setHeader('Cache-Control', 'no-store');
    res.send(`# Contexa installer is temporarily unavailable.\n# Please try again in a few minutes or visit https://docs.ctxa.ai for manual setup.\n`);
    return;
  }

  res.setHeader('Content-Type', 'text/plain; charset=utf-8');
  res.setHeader('Cache-Control', 'no-cache');
  res.send(body);
};
