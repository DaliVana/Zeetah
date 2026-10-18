/* Shared by every page: theme toggle, plus Zig highlighting and copy buttons
 * for the code blocks on the guide / how-it-works pages. Classic script. */
(function () {
  'use strict';

  const THEME_KEY = 'zeetah:theme';
  const esc = (s) => s.replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]);

  /** Minimal Zig highlighter: comments, strings, builtins, keywords. */
  function highlightZig(src) {
    const re = /(\/\/[^\n]*)|("(?:[^"\\\n]|\\.)*")|(@[A-Za-z_]\w*)|\b(const|var|fn|pub|try|defer|errdefer|while|for|if|else|return|void|orelse|catch|switch|struct|error|true|false|null|test|comptime)\b/g;
    let out = '';
    let pos = 0;
    let m;
    while ((m = re.exec(src))) {
      out += esc(src.slice(pos, m.index));
      const cls = m[1] ? 'c' : m[2] ? 's' : m[3] ? 'b' : 'k';
      out += `<span class="${cls}">${esc(m[0])}</span>`;
      pos = m.index + m[0].length;
    }
    return out + esc(src.slice(pos));
  }

  function highlightShell(src) {
    return src
      .split('\n')
      .map((line) => {
        const i = line.indexOf('#');
        return i < 0 ? esc(line) : esc(line.slice(0, i)) + `<span class="c">${esc(line.slice(i))}</span>`;
      })
      .join('\n');
  }

  async function copy(text) {
    try {
      await navigator.clipboard.writeText(text);
      return true;
    } catch (_) {
      const ta = document.createElement('textarea');
      ta.value = text;
      ta.style.position = 'fixed';
      ta.style.opacity = '0';
      document.body.appendChild(ta);
      ta.select();
      let ok = false;
      try {
        ok = document.execCommand('copy');
      } catch (_) {}
      ta.remove();
      return ok;
    }
  }

  function enhanceCode() {
    for (const code of document.querySelectorAll('.doc pre > code')) {
      const src = code.textContent;
      if (code.classList.contains('zig')) code.innerHTML = highlightZig(src);
      else if (code.classList.contains('sh')) code.innerHTML = highlightShell(src);
      const btn = document.createElement('button');
      btn.type = 'button';
      btn.className = 'btn small copy-btn';
      btn.textContent = 'Copy';
      btn.addEventListener('click', async () => {
        btn.textContent = (await copy(src)) ? 'Copied' : 'Copy failed';
        setTimeout(() => (btn.textContent = 'Copy'), 1500);
      });
      code.parentElement.appendChild(btn);
    }
  }

  function wireTheme() {
    const btn = document.getElementById('themeBtn');
    if (!btn) return;
    btn.addEventListener('click', () => {
      const root = document.documentElement;
      const dark = root.dataset.theme ? root.dataset.theme === 'dark' : matchMedia('(prefers-color-scheme: dark)').matches;
      root.dataset.theme = dark ? 'light' : 'dark';
      try {
        localStorage.setItem(THEME_KEY, root.dataset.theme);
      } catch (_) {}
    });
  }

  wireTheme();
  enhanceCode();
  window.ZeetahSite = { highlightZig };
})();
