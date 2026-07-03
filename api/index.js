const fs = require('fs');
const path = require('path');

// Vercel rewrites all paths to /api, but req.url preserves the original
// request path so we can route by path extension and User-Agent.
//
// Routing:
//   /install.ps1, /win, /windows, PowerShell UA -> install.ps1
//   /install.sh, /sh, /linux, /mac, everything else -> install.sh
module.exports = (req, res) => {
  const url = (req.url || '/').toLowerCase();
  const ua = (req.headers['user-agent'] || '').toLowerCase();

  const wantsPs1 =
       url.includes('.ps1')
    || url === '/win'
    || url === '/windows'
    || url.startsWith('/win?')
    || url.startsWith('/windows?')
    || ua.includes('powershell')
    || ua.includes('windowspowershell');

  const fileName = wantsPs1 ? 'install.ps1' : 'install.sh';
  const filePath = path.join(__dirname, '..', fileName);

  let body;
  try {
    body = fs.readFileSync(filePath, 'utf8');
  } catch (err) {
    res.statusCode = 503;
    res.setHeader('Content-Type', 'text/plain; charset=utf-8');
    res.setHeader('Cache-Control', 'no-store');
    res.setHeader('X-Content-Type-Options', 'nosniff');
    res.send('# Contexa installer is temporarily unavailable.\n# Please try again in a few minutes or visit https://docs.ctxa.ai for manual setup.\n');
    return;
  }

  // No UTF-8 BOM is prepended. PowerShell 5.x honors the charset in
  // Content-Type and may treat a BOM from Invoke-RestMethod as part of the
  // first token when piping to iex.
  res.setHeader('Content-Type', 'text/plain; charset=utf-8');
  res.setHeader('Cache-Control', 'no-cache, no-store, must-revalidate');
  res.setHeader('X-Content-Type-Options', 'nosniff');
  res.send(body);
};
