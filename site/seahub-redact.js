(function(){
  try {
    // OpenKM integration: use JSESSIONID cookie and OpenKM PDF preview iframe
    function h(tag, props, ...kids){ const el = document.createElement(tag); Object.assign(el, props||{}); kids.forEach(k => el.appendChild(typeof k==='string'?document.createTextNode(k):k)); return el; }
    function style(css){ const s = document.createElement('style'); s.textContent = css; document.head.appendChild(s); }
    style(`
      .hn-redact-btn{ padding:4px 8px; border-radius:4px; cursor:pointer; }
      .hn-redact-btn.toolbar{ margin:0 6px 0 0; }
      .hn-redact-overlay{position:fixed;inset:0;background:rgba(0,0,0,0.1);z-index:9998;cursor:crosshair}
      .hn-redact-canvas{position:absolute;left:0;top:0;}
      .hn-redact-toolbar{position:fixed;left:16px;top:16px;z-index:2147480000;display:flex;gap:8px;}
      .hn-redact-fab{position:fixed;right:16px;bottom:16px;z-index:2147480000;padding:10px 14px;border-radius:999px;background:#111827;color:#fff;border:0;}
    `);

    function authedFetch(url, opts){
      const headers = Object.assign({}, (opts && opts.headers)||{});
      if (!opts) opts = {};
      opts.credentials = 'include';
      return fetch(url, Object.assign({}, opts||{}, { headers }));
    }

    function getFileRawUrl(){
      // Prefer explicit download/raw links rendered by Seahub
      const dl1 = document.querySelector('a[href*="raw=1"], a[href*="?dl=1"], a[href*="&dl=1"]');
      if (dl1 && dl1.href) return dl1.href;
      // If PDF viewer iframe has ?file=<encoded-url> parameter, use that
      const iframe = document.querySelector('iframe');
      if (iframe && iframe.src) {
        try { const u = new URL(iframe.src, location.origin); const f = u.searchParams.get('file'); if (f) return new URL(f, location.origin).toString(); } catch {}
      }
      // Fallback: force raw content via ?raw=1 on the current /lib/.../file/... path
      if (location.pathname.includes('/lib/') && location.pathname.includes('/file/')) {
        const rawUrl = location.origin + location.pathname + (location.search ? location.search + '&' : '?') + 'raw=1';
        return rawUrl;
      }
      return location.href;
    }

    function getPdfIframe(){
      // OpenKM uses PDF.js in an iframe under /OpenKM/frontend/preview
      const frames = Array.from(document.querySelectorAll('iframe'));
      for (const fr of frames) {
        try {
          if (fr.src && /OpenKM\/frontend\//i.test(fr.src)) return fr;
          if (fr.contentDocument && (fr.contentDocument.getElementById('toolbarViewerRight') || fr.contentDocument.querySelector('#viewerContainer'))) return fr;
        } catch {}
      }
      return null;
    }

    function findPrintButton(root){
      // Search within provided root (document or iframe document)
      const sel = '#print, [title="Print"], [aria-label="Print"], .sf2-icon-print, .icon-print';
      const candidates = (root || document).querySelectorAll(sel);
      let best = null;
      candidates.forEach(el => { if (!best) best = el; });
      return best;
    }

    function ensureButton(){
      if (document.querySelector('.hn-redact-btn')) return;
      // Only show when a PDF viewer iframe/canvas/object is present to reduce false positives
      const hasViewer = !!(getPdfIframe() || document.querySelector('canvas, embed[type="application/pdf"], object[type="application/pdf"]'));
      if (!hasViewer) return;
      // Prefer injecting into PDF.js toolbar inside iframe for reliability
      const pdfIframe = getPdfIframe();
      if (pdfIframe && pdfIframe.contentDocument) {
        const idoc = pdfIframe.contentDocument;
        const rightBar = idoc.querySelector('#toolbarViewerRight') || idoc.querySelector('#secondaryToolbar');
        const printBtnI = findPrintButton(idoc);
        if (rightBar) {
          const b = idoc.createElement('button');
          b.id = 'hnRedactBtn';
          b.className = 'toolbarButton hn-redact-btn toolbar';
          b.setAttribute('title','Redact');
          b.setAttribute('aria-label','Redact');
          b.textContent = 'Redact';
          if (printBtnI && printBtnI.parentElement === rightBar) rightBar.insertBefore(b, printBtnI); else rightBar.insertBefore(b, rightBar.firstChild);
          b.addEventListener('click', (e)=>{ e.preventDefault(); openOverlay(); });
          return; // Done
        }
      }

      // Fallback: Seahub toolbar in parent doc
      const toolbar = document.querySelector('.view-file-op, .file-op, .pdf-op, header .operations, header .d-flex, header, .file-toolbar, .detail-toolbar, .sf-toolbar');
      const printBtn = findPrintButton(document);
      let btn;
      if (printBtn && toolbar) {
        btn = printBtn.cloneNode(false);
        // Neutralize default navigation/print
        btn.removeAttribute('href');
        btn.setAttribute('href', '#');
        btn.setAttribute('title', 'Redact');
        btn.setAttribute('aria-label', 'Redact');
        btn.classList.add('hn-redact-btn','toolbar');
        btn.textContent = 'Redact';
        toolbar.insertBefore(btn, printBtn);
      } else if (toolbar) {
        btn = h('button',{className:'hn-redact-btn toolbar',innerText:'Redact', title:'Redact'});
        toolbar.insertBefore(btn, toolbar.firstChild || null);
      } else {
        btn = h('button',{className:'hn-redact-btn hn-redact-fab',innerText:'Redact', title:'Redact'});
        document.body.appendChild(btn);
      }
      btn.addEventListener('click', (e)=>{ e.preventDefault(); openOverlay(); });
    }

    function getActivePdfCanvas(){
      const pdfIframe = getPdfIframe();
      const root = pdfIframe && pdfIframe.contentDocument ? pdfIframe.contentDocument : document;
      const canvases = Array.from(root.querySelectorAll('canvas'));
      if (!canvases.length) return null;
      let best = null; let bestArea = 0; const vw = window.innerWidth, vh = window.innerHeight;
      for (const c of canvases) {
        const r = c.getBoundingClientRect();
        const interW = Math.max(0, Math.min(r.right, vw) - Math.max(r.left, 0));
        const interH = Math.max(0, Math.min(r.bottom, vh) - Math.max(r.top, 0));
        const area = interW * interH;
        if (area > bestArea) { bestArea = area; best = c; }
      }
      return best;
    }

    function getActivePdfHostRect(){
      const pdfCanvas = getActivePdfCanvas();
      if (pdfCanvas) return pdfCanvas.getBoundingClientRect();
      // Fallback to <embed>/<object> PDF viewer element
      const pdfObj = document.querySelector('embed[type="application/pdf"], object[type="application/pdf"], iframe.pdf-viewer');
      if (pdfObj) return pdfObj.getBoundingClientRect();
      return { left: 0, top: 0, width: window.innerWidth, height: window.innerHeight };
    }

    function openOverlay(){
      const pdfCanvas = getActivePdfCanvas();
      const targetRect = getActivePdfHostRect();
      const overlay = h('div',{className:'hn-redact-overlay'});
      const canvas = h('canvas',{className:'hn-redact-canvas'});
      overlay.appendChild(canvas);
      document.body.appendChild(overlay);
      const ctx = canvas.getContext('2d');
      const boxes = []; let start=null; let drag=null;
      function resize(){ canvas.width = Math.max(1, Math.floor(targetRect.width)); canvas.height = Math.max(1, Math.floor(targetRect.height)); canvas.style.left = targetRect.left + 'px'; canvas.style.top = targetRect.top + 'px'; draw(); }
      function draw(){ ctx.clearRect(0,0,canvas.width,canvas.height); ctx.fillStyle='rgba(0,0,0,0.05)'; ctx.fillRect(0,0,canvas.width,canvas.height); ctx.fillStyle='rgba(0,0,0,0.65)'; boxes.forEach(b=>ctx.fillRect(b.x,b.y,b.w,b.h)); }
      overlay.addEventListener('mousedown',e=>{ start={x:e.clientX - targetRect.left,y:e.clientY - targetRect.top}; boxes.push({x:start.x,y:start.y,w:0,h:0}); drag=boxes.length-1; });
      overlay.addEventListener('mousemove',e=>{ if(start){ const b=boxes[drag]; b.w=(e.clientX - targetRect.left)-start.x; b.h=(e.clientY - targetRect.top)-start.y; draw(); }});
      window.addEventListener('mouseup',()=>{ start=null; draw(); },{once:false});
      window.addEventListener('resize', resize);
      resize();

      const tb = h('div',{className:'hn-redact-toolbar'});
      const apply = h('button',{innerText:'Apply'});
      const cancel = h('button',{innerText:'Cancel'});
      tb.appendChild(apply); tb.appendChild(cancel); document.body.appendChild(tb);
      cancel.onclick = ()=>{ document.body.removeChild(overlay); document.body.removeChild(tb); };
      apply.onclick = async ()=>{
        try {
          const url = getFileRawUrl();
          const fileRes = await fetch(url, { credentials: 'include', headers: { 'Accept': '*/*' } });
          const blob = await fileRes.blob();
          const fd = new FormData();
          fd.append('file', blob, 'file');
          const rects = boxes.map(b=>({page:1,x:Math.min(b.x,b.x+b.w), y:Math.min(b.y,b.y+b.h), width:Math.abs(b.w), height:Math.abs(b.h)}));
          fd.append('rects', JSON.stringify({ rects }));
          fd.append('kind', url.toLowerCase().includes('.pdf') ? 'pdf' : 'image');
          if (pdfCanvas) {
            fd.append('page_pixels_w', String(pdfCanvas.getBoundingClientRect().width));
            fd.append('page_pixels_h', String(pdfCanvas.getBoundingClientRect().height));
            fd.append('page_canvas_w', String(pdfCanvas.width||''));
            fd.append('page_canvas_h', String(pdfCanvas.height||''));
          } else if (targetRect) {
            fd.append('page_pixels_w', String(targetRect.width));
            fd.append('page_pixels_h', String(targetRect.height));
          }
          // If we can infer repo/path from URL, overwrite in place on the server
          try {
            const m = location.pathname.match(/\/lib\/([^/]+)\/.*\/file\/(.+)$/);
            if (m) {
              fd.append('repo_id', m[1]);
              fd.append('repo_path', '/' + decodeURIComponent(m[2]).replace(/^\/+/, ''));
            }
          } catch {}
          const res = await authedFetch('/community-api/redact-bytes', { method:'POST', body: fd });
          if (!res.ok) { const t = await res.text(); alert('Redaction failed: ' + t.slice(0,180)); return; }
          const ct = res.headers.get('Content-Type') || '';
          if (/application\/(pdf|octet-stream|png)/i.test(ct)) {
            const out = await res.blob();
            const dl = URL.createObjectURL(out);
            const a = document.createElement('a'); a.href=dl; a.download='redacted'; a.click(); URL.revokeObjectURL(dl);
          }
          // Force viewer refresh to pick up the updated file
          try {
            const iframe = document.querySelector('iframe');
            if (iframe && iframe.src) {
              const u = new URL(iframe.src, location.origin);
              u.searchParams.set('v', String(Date.now()));
              iframe.src = u.toString();
            } else {
              const u = new URL(location.href);
              u.searchParams.set('v', String(Date.now()));
              window.location.href = u.toString();
            }
          } catch {}
          cancel.onclick();
        } catch (e) { console.error(e); alert('Redaction error'); }
      };
    }

    // Keep trying in case OpenKM changes DOM after load
    ensureButton();
    function addFloating(){
      if (document.querySelector('.hn-redact-fab')) return;
      const btn = h('button',{className:'hn-redact-btn hn-redact-fab',innerText:'Redact', title:'Redact (R)'});
      btn.addEventListener('click', (e)=>{ e.preventDefault(); openOverlay(); });
      document.body.appendChild(btn);
    }

    document.addEventListener('DOMContentLoaded', ()=>{ try{console.log('[okm-redact] init');}catch(e){} addFloating(); ensureButton(); });
    setInterval(ensureButton, 1500);
    try { new MutationObserver(() => ensureButton()).observe(document.documentElement, {childList:true,subtree:true}); } catch {}
    try { window.addEventListener('keydown', (e)=>{ if ((e.key||'').toLowerCase()==='r') { e.preventDefault(); openOverlay(); } }); } catch {}
    try { window.__hnRedactReady = '1.1'; } catch {}
    try { window.__hnRedactReady = true; } catch {}
  } catch {}
})();


