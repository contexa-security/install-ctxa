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

  // Prepend a UTF-8 BOM (﻿) for PowerShell consumers. PowerShell 5.x's
  // Invoke-RestMethod is known to ignore the Content-Type charset header and
  // fall back to ISO-8859-1 unless it sees a BOM, which mojibakes the banner
  // (utf-8 byte 0xE2 → "â", reported by users as "로고가 깨진다"). Bash, on
  // the other hand, would choke on the BOM as an unknown command at line 1,
  // so we only inject it for the .ps1 path.
  if (wantsPs1 && !body.startsWith('﻿')) {
    body = '﻿' + body;
  }

  res.setHeader('Content-Type', 'text/plain; charset=utf-8');
  res.setHeader('Cache-Control', 'no-cache');
  res.send(body);
};
