#!/usr/bin/env node
/**
 * fetch-release-notes.mjs — 抓取 NVIDIA GeForce 驱动 release notes PDF，并提取 "Open Issues" 小节条目。
 *
 * 零依赖：仅用 Node 22+ 内置能力（全局 fetch + node:zlib）。
 * 用法：node fetch-release-notes.mjs <版本号> [--json]
 * 退出码：0 成功 / 1 参数错误 / 2 抓取或 PDF 无效 / 3 网络失败
 */
import { inflateSync } from 'node:zlib';

const BASE_URL = 'https://us.download.nvidia.com/Windows/';
const UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/120.0 Safari/537.36';
// Referer 是绕过 NVIDIA `Zen/4.3` 反爬的关键：裸请求（无 Referer）会被拦回 403，UA 兜底。
const HEADERS = { 'User-Agent': UA, 'Referer': 'https://www.nvidia.com/' };

const USAGE = `用法：
  node fetch-release-notes.mjs <版本号> [--json]

示例：
  node fetch-release-notes.mjs 617.42
  node fetch-release-notes.mjs 617.42 --json

退出码：0 成功 / 1 参数错误 / 2 抓取或 PDF 无效 / 3 网络失败`;

// ---------------------------------------------------------------------------
// PDF 字符串解码（字面量括号串的转义）
// ---------------------------------------------------------------------------
function decodePdfString(inner) {
  let out = '';
  for (let i = 0; i < inner.length; i++) {
    const c = inner[i];
    if (c === '\\') {
      const n = inner[i + 1];
      if (n === 'n') { out += '\n'; i++; }
      else if (n === 'r') { out += '\r'; i++; }
      else if (n === 't') { out += '\t'; i++; }
      else if (n === 'b') { out += '\b'; i++; }
      else if (n === 'f') { out += '\f'; i++; }
      else if (n === '(' || n === ')' || n === '\\') { out += n; i++; }
      else if (/[0-7]/.test(n)) {
        let oct = '';
        let j = 0;
        while (j < 3 && i + 1 + j < inner.length && /[0-7]/.test(inner[i + 1 + j])) { oct += inner[i + 1 + j]; j++; }
        out += String.fromCharCode(parseInt(oct, 8));
        i += j;
      } else { out += n; i++; }
    } else out += c;
  }
  return out;
}

// ---------------------------------------------------------------------------
// 极简 PDF 内容流 tokenizer（只关心字符串、数字、名字、数组、操作符）
// ---------------------------------------------------------------------------
function tokenize(ct) {
  const tokens = [];
  let i = 0;
  const n = ct.length;
  let guard = 0;
  while (i < n && guard++ < n * 20) {
    const c = ct[i];
    if (/\s/.test(c)) { i++; continue; }
    if (c === '%') { while (i < n && ct[i] !== '\n' && ct[i] !== '\r') i++; continue; }
    if (c === '(') {
      let depth = 1, j = i + 1, out = '';
      while (j < n && depth > 0) {
        const ch = ct[j];
        if (ch === '\\') { out += ch + (ct[j + 1] || ''); j += 2; continue; }
        if (ch === '(') { depth++; out += ch; j++; continue; }
        if (ch === ')') { depth--; if (depth > 0) out += ch; j++; continue; }
        out += ch; j++;
      }
      tokens.push({ t: 'str', v: decodePdfString(out) });
      i = j; continue;
    }
    if (c === '[') { tokens.push({ t: '[' }); i++; continue; }
    if (c === ']') { tokens.push({ t: ']' }); i++; continue; }
    if (c === '<') {
      if (ct[i + 1] === '<') { // 字典，跳过
        let depth = 1, j = i + 2;
        while (j < n && depth > 0) {
          if (ct[j] === '<' && ct[j + 1] === '<') { depth++; j += 2; continue; }
          if (ct[j] === '>' && ct[j + 1] === '>') { depth--; j += 2; continue; }
          j++;
        }
        tokens.push({ t: 'dict' });
        i = j; continue;
      } else { // 十六进制字符串
        let j = i + 1, hex = '';
        while (j < n && ct[j] !== '>') { hex += ct[j]; j++; }
        let bytes = '';
        hex = hex.replace(/\s/g, '');
        for (let k = 0; k + 1 < hex.length; k += 2) bytes += String.fromCharCode(parseInt(hex.slice(k, k + 2), 16));
        tokens.push({ t: 'str', v: bytes });
        i = j + 1; continue;
      }
    }
    if (c === '/') {
      let j = i + 1, name = '';
      while (j < n && !/[\s\[\]<>()/{}%]/.test(ct[j])) { name += ct[j]; j++; }
      tokens.push({ t: 'name', v: name });
      i = j; continue;
    }
    if (/[0-9+\-.]/.test(c)) {
      let j = i, num = '';
      while (j < n && /[0-9+\-.eE]/.test(ct[j])) { num += ct[j]; j++; }
      tokens.push({ t: 'num', v: parseFloat(num) });
      i = j; continue;
    }
    let j = i, kw = '';
    while (j < n && !/[\s\[\]<>()/{}%]/.test(ct[j])) { kw += ct[j]; j++; }
    if (j === i) { i++; continue; }
    tokens.push({ t: 'kw', v: kw });
    i = j;
  }
  return tokens;
}

// ---------------------------------------------------------------------------
// 内容流 → 文本 run（带 x/y 坐标）。跟踪 Tm/Td/TD 移动文本矩阵与当前笔位。
// ---------------------------------------------------------------------------
function extractRuns(ct) {
  const tokens = tokenize(ct);
  const runs = [];
  let x = 0, y = 0;
  const stack = [];
  for (let idx = 0; idx < tokens.length; idx++) {
    const tk = tokens[idx];
    if (tk.t === 'str' || tk.t === 'num') {
      if (stack.length && stack[stack.length - 1].t === 'arr') stack[stack.length - 1].v.push(tk);
      else stack.push(tk);
      continue;
    }
    if (tk.t === '[') { stack.push({ t: 'arr', v: [] }); continue; }
    if (tk.t === ']') {
      if (stack.length && stack[stack.length - 1].t === 'arr') {
        const a = stack.pop();
        let s = '';
        for (const e of a.v) if (e.t === 'str') s += e.v;
        stack.push({ t: 'str', v: s });
      }
      continue;
    }
    if (tk.t === 'name') { stack.push(tk); continue; }
    if (tk.t === 'kw') {
      const op = tk.v;
      if (op === 'Tf') { if (stack.length >= 2) stack.length -= 2; continue; }
      if (op === 'Tm') { if (stack.length >= 6) { const f = stack.slice(-6).map(z => z.v); x = f[4]; y = f[5]; stack.length = 0; } continue; }
      if (op === 'Td' || op === 'TD') { if (stack.length >= 2) { x += stack[stack.length - 2].v; y += stack[stack.length - 1].v; stack.length = 0; } continue; }
      if (op === 'T*') { stack.length = 0; continue; }
      if (op === 'Tj' || op === 'TJ') { if (stack.length >= 1) { const l = stack[stack.length - 1]; if (l.t === 'str' && l.v.length) runs.push({ x, y, text: l.v }); } stack.length = 0; continue; }
      stack.length = 0; // 其余操作符（图形状态/颜色/BDC/EMC/BT/ET 等）
    }
  }
  return runs;
}

// ---------------------------------------------------------------------------
// PDF 对象模型：解析直对象 + ObjStm 压缩对象 + 内容流，重建页面树与逐页文本。
// ---------------------------------------------------------------------------
function parsePdf(pdf) {
  const latin1 = pdf.toString('latin1');

  // 直对象：`N 0 obj ... endobj`
  const direct = new Map();
  {
    const re = /(\d+)\s+0\s+obj\b/g;
    let m;
    while ((m = re.exec(latin1))) {
      const num = parseInt(m[1], 10);
      const bodyStart = re.lastIndex;
      const end = latin1.indexOf('endobj', bodyStart);
      if (end < 0) break;
      direct.set(num, latin1.slice(bodyStart, end));
    }
  }

  // 内容流：`N 0 obj ... stream ... endstream`（按对象号索引）
  const contentStreams = new Map();
  {
    const re = /(\d+)\s+0\s+obj\b/g;
    let m;
    while ((m = re.exec(latin1))) {
      const num = parseInt(m[1], 10);
      const bodyStart = re.lastIndex;
      const endobj = latin1.indexOf('endobj', bodyStart);
      const st = latin1.indexOf('stream', bodyStart);
      if (st >= 0 && st < endobj) {
        let ds = st + 6;
        if (latin1[ds] === '\r') ds++;
        if (latin1[ds] === '\n') ds++;
        const es = latin1.indexOf('endstream', ds);
        let e = es;
        while (e > ds && (latin1[e - 1] === '\r' || latin1[e - 1] === '\n')) e--;
        const filter = /\/Filter\s*\/FlateDecode/.test(latin1.slice(bodyStart, st));
        contentStreams.set(num, { data: pdf.subarray(ds, e), filter });
      }
    }
  }

  // 统一对象表：直对象 + ObjStm 解压出的对象
  const objects = new Map();
  for (const [num, body] of direct) objects.set(num, body);

  function parseObjStm(dict, data) {
    const n = parseInt((dict.match(/\/N\s+(\d+)/) || [])[1], 10);
    const first = parseInt((dict.match(/\/First\s+(\d+)/) || [])[1], 10);
    const infl = inflateSync(data).toString('latin1');
    const header = infl.slice(0, first);
    const nums = header.match(/\d+/g).map(Number);
    const objs = new Map();
    for (let i = 0; i < n; i++) {
      const on = nums[i * 2];
      const off = nums[i * 2 + 1];
      const nextOff = (i + 1 < n) ? nums[(i + 1) * 2 + 1] : undefined;
      const body = nextOff !== undefined ? infl.slice(first + off, first + nextOff) : infl.slice(first + off);
      objs.set(on, body);
    }
    return objs;
  }
  {
    const re = /stream\r?\n/g;
    let m;
    while ((m = re.exec(latin1))) {
      const ss = m.index + m[0].length;
      const end = latin1.indexOf('endstream', ss);
      if (end < 0) break;
      const dict = latin1.slice(Math.max(0, m.index - 500), m.index);
      if (/\/Type\s*\/ObjStm/.test(dict)) {
        let s = ss, e = end;
        while (s < e && (pdf[s] === 13 || pdf[s] === 10)) s++;
        while (e > s && (pdf[e - 1] === 13 || pdf[e - 1] === 10)) e--;
        try {
          const objs = parseObjStm(dict, pdf.subarray(s, e));
          for (const [k, v] of objs) if (!objects.has(k)) objects.set(k, v);
        } catch { /* 跳过无法解压的对象流 */ }
      }
    }
  }

  // 页面树：从 Catalog → /Pages → 递归 /Kids（/Type /Page 叶子）
  function collectPages(rootRef) {
    const pageList = [];
    const seen = new Set();
    function walk(ref) {
      if (seen.has(ref)) return;
      seen.add(ref);
      const body = objects.get(ref);
      if (!body) return;
      if (/\/Type\s*\/Page[^s]/.test(body)) { pageList.push(ref); return; }
      const km = body.match(/\/Kids\s*\[([^\]]*)\]/);
      if (km) {
        const refs = [...km[1].matchAll(/(\d+)\s+0\s+R/g)].map(x => parseInt(x[1], 10));
        for (const r of refs) walk(r);
      }
    }
    walk(rootRef);
    return pageList;
  }
  const catalog = [...objects.entries()].find(([, b]) => /\/Type\s*\/Catalog/.test(b));
  if (!catalog) throw new Error('未找到 Catalog 对象');
  const pagesRef = parseInt((catalog[1].match(/\/Pages\s+(\d+)\s+0\s+R/) || [])[1], 10);
  if (!pagesRef) throw new Error('未找到页面树根');
  const pages = collectPages(pagesRef);

  // 单页文本：合并该页所有内容流的 run，按 y 聚类成行、按 x 排序拼接。
  const win1252 = new TextDecoder('windows-1252');
  function pageLines(ref) {
    const body = objects.get(ref);
    if (!body) return [];
    let refs;
    const arrMatch = body.match(/\/Contents\s+\[([^\]]*)\]/);
    if (arrMatch) refs = [...arrMatch[1].matchAll(/(\d+)\s+0\s+R/g)].map(x => parseInt(x[1], 10));
    else { const s = body.match(/\/Contents\s+(\d+)\s+0\s+R/); refs = s ? [parseInt(s[1], 10)] : []; }

    const runs = [];
    for (const cr of refs) {
      const cs = contentStreams.get(cr);
      if (!cs) continue;
      let t;
      if (cs.filter) { try { t = inflateSync(cs.data).toString('latin1'); } catch { continue; } }
      else t = cs.data.toString('latin1');
      runs.push(...extractRuns(t));
    }
    for (const r of runs) {
      const bytes = new Uint8Array(r.text.length);
      for (let i = 0; i < r.text.length; i++) bytes[i] = r.text.charCodeAt(i) & 0xff;
      r.text = win1252.decode(bytes);
    }
    runs.sort((a, b) => b.y - a.y);
    const lines = [];
    for (const r of runs) {
      let placed = false;
      for (const L of lines) { if (Math.abs(L.y - r.y) <= 1.0) { L.runs.push(r); placed = true; break; } }
      if (!placed) lines.push({ y: r.y, runs: [r] });
    }
    for (const L of lines) { L.runs.sort((a, b) => a.x - b.x); L.text = L.runs.map(x => x.text).join(''); }
    lines.sort((a, b) => b.y - a.y);
    return lines.map(L => L.text);
  }

  return { pages, pageLines };
}

// ---------------------------------------------------------------------------
// 文本归一化：智能引号/连字符 → ASCII，压缩空白。
// ---------------------------------------------------------------------------
function normalize(s) {
  return s
    .replace(/[\u201C\u201D]/g, '"')   // “ ”
    .replace(/[\u2018\u2019]/g, "'")   // ‘ ’
    .replace(/[\u2013\u2014]/g, '-')   // – —
    .replace(/\s+/g, ' ')
    .trim();
}

// ---------------------------------------------------------------------------
// 从扁平文本行提取 "3.2 Open Issues" 小节的 bullet 条目。
// 判定「正文标题」（非目录页）：行首 `3.2` + `Open Issues` 且不含目录点线 `..`。
// ---------------------------------------------------------------------------
function collectOpenIssues(flat) {
  let start = -1;
  for (let i = 0; i < flat.length; i++) {
    const t = flat[i];
    if (/^3\.2\s+Open Issues/i.test(t) && !t.includes('..')) { start = i; break; }
  }
  if (start < 0) return null;

  const isStop = (t) => /^3\.3\s+Issues Not Caused/i.test(t) && !t.includes('..');
  const isFooter = (t) => /^RN-/.test(t) || /^Release\s+\d+/.test(t) || /^NVIDIA\s*Corporation/.test(t);
  const isHeading = (t) => /^\d+(\.\d+)*\s/.test(t);

  const bullets = [];
  let cur = null;
  for (let i = start + 1; i < flat.length; i++) {
    const t = flat[i];
    if (isStop(t)) break;
    if (t.startsWith('>')) {
      if (cur !== null) bullets.push(cur);
      cur = t.replace(/^>\s*/, '');
    } else if (cur !== null) {
      if (t.length && !isFooter(t) && !isHeading(t)) cur += ' ' + t;
    }
  }
  if (cur !== null) bullets.push(cur);
  return bullets.map(normalize);
}

// ---------------------------------------------------------------------------
// 网络抓取：返回 PDF Buffer，或 null（非 200 / 非 PDF / 魔数不符）。
// 网络层错误向上抛，由调用方转成退出码 3。
// ---------------------------------------------------------------------------
async function fetchPdf(url) {
  const res = await fetch(url, { headers: HEADERS, redirect: 'follow' });
  if (res.status !== 200) return null;
  const ct = (res.headers.get('content-type') || '').toLowerCase();
  if (!ct.includes('application/pdf')) return null;
  const buf = Buffer.from(await res.arrayBuffer());
  if (buf.length < 8) return null;
  if (buf.subarray(0, 5).toString('latin1') !== '%PDF-') return null;
  return buf;
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------
async function main(argv) {
  if (argv.includes('-h') || argv.includes('--help')) { console.log(USAGE); process.exit(0); }
  const json = argv.includes('--json');
  const positional = argv.filter(a => !a.startsWith('-'));
  const version = positional[0];
  if (!version) { console.error('缺少版本号参数。\n' + USAGE); process.exit(1); }
  if (!/^\d+\.\d+(\.\d+)*$/.test(version)) { console.error(`无效版本号: ${version}\n` + USAGE); process.exit(1); }

  // 候选 URL：Studio/NSD 优先，其次 Game Ready。
  const candidates = [
    `${BASE_URL}${version}/${version}-win10-win11-nsd-release-notes.pdf`, // Studio/NSD
    `${BASE_URL}${version}/${version}-win11-win10-release-notes.pdf`,     // Game Ready
  ];

  let buf = null;
  let pdfUrl = null;
  for (const url of candidates) {
    try {
      const b = await fetchPdf(url);
      if (b) { buf = b; pdfUrl = url; break; }
    } catch (e) {
      console.error(`网络失败（${url}）: ${e.message}`);
      process.exit(3);
    }
  }
  if (!buf) {
    console.error(`抓取失败：版本 ${version} 的所有候选 URL 均未返回有效 PDF（HTTP 非 200 或非 application/pdf）。`);
    process.exit(2);
  }

  let parsed;
  try { parsed = parsePdf(buf); }
  catch (e) { console.error(`PDF 解析失败: ${e.message}`); process.exit(2); }

  const flat = [];
  for (const ref of parsed.pages) for (const l of parsed.pageLines(ref)) flat.push(l.trim());

  // 发布日期：取首个标题页的 `RN-... | <月 日, 年>`。
  let releaseDate = null;
  const dateRe = /RN-[^\s|]+\s*\|\s*([A-Za-z]+\s+\d{1,2},\s+\d{4})/;
  for (const l of flat) { const m = l.match(dateRe); if (m) { releaseDate = m[1]; break; } }

  const openIssues = collectOpenIssues(flat);
  if (openIssues === null) {
    console.error(`未在 PDF 中找到 "3.2 Open Issues" 小节（PDF 结构可能已变化）。`);
    process.exit(2);
  }

  const result = { version, pdfUrl, releaseDate, openIssues };
  if (json) {
    console.log(JSON.stringify(result));
  } else {
    console.log(`版本: ${result.version}`);
    console.log(`发布日期: ${result.releaseDate || '未知'}`);
    console.log('Open Issues:');
    for (const it of result.openIssues) console.log(`  - ${it}`);
  }
  process.exit(0);
}

main(process.argv.slice(2)).catch((e) => {
  console.error('未预期错误: ' + (e && e.message));
  process.exit(2);
});
