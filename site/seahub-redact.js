(function(){
  try {
    const token = localStorage.getItem('token') || '';
    function h(tag, props, ...kids){ const el = document.createElement(tag); Object.assign(el, props||{}); kids.forEach(k => el.appendChild(typeof k==='string'?document.createTextNode(k):k)); return el; }
    function style(css){ const s = document.createElement('style'); s.textContent = css; document.head.appendChild(s); }
    style(`
      .hn-redact-btn{position:fixed;right:16px;top:16px;z-index:9999;padding:8px 12px;border-radius:8px;background:#111827;color:#fff;border:0;}
      /* When placed into Seahub toolbar (flex), force it to the front */
      .hn-redact-btn.toolbar{position:static;margin:0 8px 0 0;order:-1;}
      .hn-redact-overlay{position:fixed;inset:0;background:rgba(0,0,0,0.1);z-index:9998;cursor:crosshair}
      .hn-redact-canvas{position:absolute;left:0;top:0;}
      .hn-redact-toolbar{position:fixed;left:16px;top:16px;z-index:9999;display:flex;gap:8px;}
    `);

    function authedFetch(url, opts){
      const headers = Object.assign({}, (opts && opts.headers)||{}, token ? { 'Authorization':'Bearer '+token } : {});
      // Always include cookies so Seahub session can authorize
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

    function ensureButton(){
      if (!(location.pathname.includes('/lib/') && location.pathname.includes('/file/'))) return;
      if (document.querySelector('.hn-redact-btn')) return;
      // Try to place inside Seahub toolbar if present
      const toolbar = document.querySelector('.view-file-op, .file-op, .pdf-op, header .operations, header .d-flex, header');
      const btn = h('button',{className:'hn-redact-btn',innerText:'Redact', title:'Draw boxes to redact'});
      if (toolbar) {
        btn.classList.add('toolbar');
        const printBtn = document.querySelector('[title="Print"], [aria-label="Print"], .sf2-icon-print, .icon-print');
        if (printBtn && printBtn.parentElement === toolbar) {
          toolbar.insertBefore(btn, printBtn);
        } else if (toolbar.firstChild) {
          toolbar.insertBefore(btn, toolbar.firstChild);
        } else {
          toolbar.appendChild(btn);
        }
      } else {
        document.body.appendChild(btn);
      }
      btn.addEventListener('click', openOverlay);
    }

    function getActivePdfCanvas(){
      const canvases = Array.from(document.querySelectorAll('canvas'));
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

    function openOverlay(){
      const pdfCanvas = getActivePdfCanvas();
      const targetRect = pdfCanvas ? pdfCanvas.getBoundingClientRect() : { left: 0, top: 0, width: window.innerWidth, height: window.innerHeight };
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
          cancel.onclick();
        } catch (e) { console.error(e); alert('Redaction error'); }
      };
    }

    // Keep trying in case Seahub changes DOM after load
    ensureButton();
    document.addEventListener('DOMContentLoaded', ensureButton);
    setInterval(ensureButton, 1500);
    try { window.__hnRedactReady = true; } catch {}
  } catch {}
})();


