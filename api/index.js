const fs = require('fs');
const path = require('path');

// Vercel rewrites all paths to /api, but req.url preserves the original
// request path so we can route by path extension and User-Agent.
//
// Routing:
//   /install.ps1, /win, /windows, PowerShell UA -> install.ps1
//   /install.sh, /sh, /linux, /mac, everything else -> install.sh
module.exports = (req, res) => {
  const pathname = new URL(req.url || '/', 'https://install.ctxa.ai').pathname;
  const routePath = pathname.toLowerCase();
  const ua = (req.headers['user-agent'] || '').toLowerCase();
  const immutableMatch = pathname.match(/^\/(v[0-9a-z][0-9a-z._-]*)\/(install\.(ps1|sh))$/i);
  if (immutableMatch) {
    const tag = immutableMatch[1];
    const fileName = immutableMatch[2].toLowerCase();
    res.statusCode = 302;
    res.setHeader('Location', `https://raw.githubusercontent.com/contexa-security/install-ctxa/${tag}/${fileName}`);
    res.setHeader('Cache-Control', 'public, max-age=31536000, immutable');
    res.setHeader('X-Content-Type-Options', 'nosniff');
    res.send('');
    return;
  }

  const explicitPs1 = routePath === '/install.ps1';
  const explicitSh = routePath === '/install.sh';
  const windowsAlias = routePath === '/win' || routePath === '/windows';
  const shellAlias = routePath === '/sh' || routePath === '/linux' || routePath === '/mac';
  const wantsPs1 = explicitPs1
    || (!explicitSh && !shellAlias && (windowsAlias || ua.includes('powershell') || ua.includes('windowspowershell')));

  const fileName = wantsPs1 ? 'install.ps1' : 'install.sh';
  const stableTag = process.env.CONTEXA_STABLE_INSTALLER_TAG;
  if (stableTag) {
    if (!/^v[0-9A-Za-z][0-9A-Za-z._-]*$/.test(stableTag)) {
      res.statusCode = 503;
      res.setHeader('Content-Type', 'text/plain; charset=utf-8');
      res.setHeader('Cache-Control', 'no-store');
      res.setHeader('X-Content-Type-Options', 'nosniff');
      res.send('# Contexa stable installer channel is temporarily unavailable.\n');
      return;
    }
    res.statusCode = 302;
    res.setHeader('Location', `https://raw.githubusercontent.com/contexa-security/install-ctxa/${stableTag}/${fileName}`);
    res.setHeader('Cache-Control', 'no-store');
    res.setHeader('X-Content-Type-Options', 'nosniff');
    res.send('');
    return;
  }
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
  res.setHeader('Cache-Control', 'no-store');
  res.setHeader('X-Content-Type-Options', 'nosniff');
  res.send(body);
};
