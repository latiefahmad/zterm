#!/usr/bin/env node
// Generate data ikon Phosphor Duotone untuk macOS, Windows, dan Linux.
//
// Sumber: @phosphor-icons/core (ISC). SVG duotone punya dua path: lapisan
// sekunder (opacity 0.2) dan garis utama. Skrip ini menormalkan semua perintah
// SVG (H/V/S/Q/T/A, relatif) menjadi M/L/C/Z absolut supaya renderer native
// hanya perlu parser sederhana dan hasilnya identik di semua platform.
//
// Jalankan: node scripts/gen-phosphor-icons.mjs

import { mkdir, readFile, readdir, unlink, writeFile } from "node:fs/promises";
import { existsSync } from "node:fs";
import path from "node:path";

const VERSION = "2.1.1";
const BASE = `https://cdn.jsdelivr.net/npm/@phosphor-icons/core@${VERSION}/assets/duotone`;
const ROOT = path.resolve(import.meta.dirname, "..");
const CACHE = path.join(ROOT, "shared", "icons", ".cache");
const LINUX_ACTIONS = path.join(ROOT, "apps", "linux", "data", "icons", "hicolor", "scalable", "actions");

// Ikon yang dipakai aplikasi. Tambahkan di sini lalu jalankan ulang skrip.
const ICONS = [
  // Navigasi
  "hard-drives", "gauge", "wrench", "users-three", "key", "arrows-left-right",
  "folder-open", "database", "stack", "cube", "brackets-curly", "fingerprint",
  "clock", "info", "user-circle",
  // Dashboard
  "cpu", "memory", "hard-drive", "arrow-down", "arrow-up", "arrows-clockwise",
  "bell", "bell-ringing", "bell-slash", "play", "magnifying-glass", "terminal-window", "warning",
  "check-circle", "x-circle", "wifi-high", "wifi-slash", "spinner-gap", "pulse",
  "monitor", "broadcast", "squares-four", "circle", "check", "caret-right",
  "caret-down", "dots-three", "plus", "x", "download-simple", "upload-simple",
  "shield-check", "cloud", "globe", "sliders-horizontal", "funnel",
  "list-magnifying-glass", "arrow-square-out", "copy", "folder-simple",
  "file-code", "lightning", "sparkle", "sun", "moon", "circle-half",
  "identification-badge", "chat-circle-dots", "envelope-simple", "sign-out",
  "tag", "package", "tree-structure", "bug", "gear-six", "chart-line",
  "trend-up", "trend-down", "swap", "arrows-out", "selection-plus",
  "sidebar-simple", "terminal", "desktop-tower", "devices", "link-simple",
  "floppy-disk", "archive", "git-branch", "git-merge", "git-commit", "heart",
  "paper-plane-tilt", "house", "cloud-arrow-down", "cloud-arrow-up", "lock-key",
  "lock-simple", "eye", "eye-slash", "list-dashes", "queue", "stack-simple",
  "chart-donut", "chart-line-up", "arrow-elbow-down-right", "record",
  "circle-notch", "waveform", "graph", "chart-scatter", "rows", "columns",
  "square", "sign-in", "caret-up", "arrow-left", "arrow-right", "dot-outline",
  "minus", "trash", "pencil-simple", "plus-circle", "minus-circle",
  // Halaman lain: navigasi, status, berkas, dan aksi
  "caret-left", "caret-double-left", "caret-double-right", "caret-up-down",
  "arrow-up-right", "arrow-circle-right", "arrow-line-down",
  "file", "file-text", "file-zip", "file-arrow-up", "file-arrow-down",
  "file-magnifying-glass", "file-pdf", "image", "film-strip", "music-notes",
  "cloud-check", "cloud-warning", "envelope-open", "google-logo",
  "user", "users", "user-plus", "user-minus", "folder", "folder-plus",
  "dots-three-circle", "minus-square", "hourglass", "tray", "seal-check",
  "warning-circle", "laptop", "power", "table", "cursor-text",
  "text-strikethrough", "stop", "stop-circle", "check-square", "lock-open",
  "password", "prohibit", "calendar", "list-checks", "arrow-circle-left",
  "arrow-circle-down", "arrow-circle-up", "clipboard", "hash",
  "arrow-counter-clockwise", "arrows-down-up", "arrow-u-up-left", "question",
];

const seen = new Set();
for (const name of ICONS) {
  if (seen.has(name)) throw new Error(`Ikon ganda: ${name}`);
  seen.add(name);
}

// ---------------------------------------------------------------------------
// Parser path SVG -> M/L/C/Z absolut
// ---------------------------------------------------------------------------

const isCommand = (c) => /[MmLlHhVvCcSsQqTtAaZz]/.test(c);
const isDigit = (c) => c >= "0" && c <= "9";

class Scanner {
  constructor(text) {
    this.s = text;
    this.i = 0;
  }
  skip() {
    while (this.i < this.s.length && (/\s|,/.test(this.s[this.i]))) this.i++;
  }
  peek() {
    this.skip();
    return this.s[this.i];
  }
  command() {
    const c = this.peek();
    if (!c || !isCommand(c)) return null;
    this.i++;
    return c;
  }
  number() {
    this.skip();
    const start = this.i;
    if (this.s[this.i] === "+" || this.s[this.i] === "-") this.i++;
    while (this.i < this.s.length && isDigit(this.s[this.i])) this.i++;
    if (this.s[this.i] === ".") {
      this.i++;
      while (this.i < this.s.length && isDigit(this.s[this.i])) this.i++;
    }
    if (this.s[this.i] === "e" || this.s[this.i] === "E") {
      this.i++;
      if (this.s[this.i] === "+" || this.s[this.i] === "-") this.i++;
      while (this.i < this.s.length && isDigit(this.s[this.i])) this.i++;
    }
    if (this.i === start) throw new Error(`Angka tidak valid pada ${start}: ${this.s.slice(start, start + 12)}`);
    return Number.parseFloat(this.s.slice(start, this.i));
  }
  hasNumber() {
    const c = this.peek();
    return c === "+" || c === "-" || c === "." || (c !== undefined && isDigit(c));
  }
}

const TAU = Math.PI * 2;
const rad = (deg) => (deg * Math.PI) / 180;
const fmt = (n) => {
  const r = Math.round(n * 100) / 100;
  return Object.is(r, -0) ? "0" : String(r);
};
const v = (x, y) => `${fmt(x)},${fmt(y)}`;

/** Pecah busur SVG menjadi kurva kubik (segmen <= 90°). */
function arcToCubics(x1, y1, rx, ry, rotation, largeArc, sweep, x2, y2) {
  if (rx === 0 || ry === 0 || (x1 === x2 && y1 === y2)) return [[x2, y2]];
  rx = Math.abs(rx);
  ry = Math.abs(ry);
  const phi = rad(rotation % 360);
  const cosPhi = Math.cos(phi);
  const sinPhi = Math.sin(phi);
  const dx = (x1 - x2) / 2;
  const dy = (y1 - y2) / 2;
  const x1p = cosPhi * dx + sinPhi * dy;
  const y1p = -sinPhi * dx + cosPhi * dy;

  const lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry);
  if (lambda > 1) {
    const k = Math.sqrt(lambda);
    rx *= k;
    ry *= k;
  }

  const num = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p;
  const den = rx * rx * y1p * y1p + ry * ry * x1p * x1p;
  const sign = largeArc === sweep ? -1 : 1;
  const coef = sign * Math.sqrt(Math.max(0, num / den));
  const cxp = (coef * (rx * y1p)) / ry;
  const cyp = (coef * -(ry * x1p)) / rx;
  const cx = cosPhi * cxp - sinPhi * cyp + (x1 + x2) / 2;
  const cy = sinPhi * cxp + cosPhi * cyp + (y1 + y2) / 2;

  const angle = (ux, uy, vx, vy) => {
    const dot = ux * vx + uy * vy;
    const len = Math.hypot(ux, uy) * Math.hypot(vx, vy);
    let a = Math.acos(Math.max(-1, Math.min(1, dot / len)));
    if (ux * vy - uy * vx < 0) a = -a;
    return a;
  };

  const ux = (x1p - cxp) / rx;
  const uy = (y1p - cyp) / ry;
  const vx = (-x1p - cxp) / rx;
  const vy = (-y1p - cyp) / ry;
  const theta1 = angle(1, 0, ux, uy);
  let delta = angle(ux, uy, vx, vy);
  if (!sweep && delta > 0) delta -= TAU;
  if (sweep && delta < 0) delta += TAU;

  const segments = Math.max(1, Math.ceil(Math.abs(delta) / (Math.PI / 2)));
  const step = delta / segments;
  const t = (4 / 3) * Math.tan(step / 4);
  const out = [];
  let theta = theta1;
  for (let i = 0; i < segments; i++) {
    const next = theta + step;
    const cos1 = Math.cos(theta);
    const sin1 = Math.sin(theta);
    const cos2 = Math.cos(next);
    const sin2 = Math.sin(next);

    const p1x = cx + rx * cos1 * cosPhi - ry * sin1 * sinPhi;
    const p1y = cy + rx * cos1 * sinPhi + ry * sin1 * cosPhi;
    const p2x = cx + rx * cos2 * cosPhi - ry * sin2 * sinPhi;
    const p2y = cy + rx * cos2 * sinPhi + ry * sin2 * cosPhi;
    const d1x = -rx * sin1 * cosPhi - ry * cos1 * sinPhi;
    const d1y = -rx * sin1 * sinPhi + ry * cos1 * cosPhi;
    const d2x = -rx * sin2 * cosPhi - ry * cos2 * sinPhi;
    const d2y = -rx * sin2 * sinPhi + ry * cos2 * cosPhi;

    out.push([
      p1x + t * d1x,
      p1y + t * d1y,
      p2x - t * d2x,
      p2y - t * d2y,
      p2x,
      p2y,
    ]);
    theta = next;
  }
  return out;
}

function normalizePath(d) {
  const sc = new Scanner(d);
  const out = [];
  let cx = 0;
  let cy = 0;
  let sx = 0;
  let sy = 0;
  let lastCubic = null; // [x, y]
  let lastQuad = null; // [x, y]
  let previous = "";
  let command = sc.command();

  const move = (x, y) => {
    out.push(`M${v(x, y)}`);
    cx = x;
    cy = y;
    sx = x;
    sy = y;
  };
  const line = (x, y) => {
    out.push(`L${v(x, y)}`);
    cx = x;
    cy = y;
  };
  const cubic = (x1, y1, x2, y2, x, y) => {
    out.push(`C${v(x1, y1)} ${v(x2, y2)} ${v(x, y)}`);
    cx = x;
    cy = y;
  };

  while (command) {
    const rel = command === command.toLowerCase();
    const upper = command.toUpperCase();
    // Koordinat berikutnya: absolut, atau relatif terhadap titik saat ini.
    // Harus dievaluasi per angka, karena satu perintah bisa berisi banyak pasangan.
    const nx = () => (rel ? cx + sc.number() : sc.number());
    const ny = () => (rel ? cy + sc.number() : sc.number());

    if (upper === "Z") {
      out.push("Z");
      cx = sx;
      cy = sy;
      previous = "Z";
      lastCubic = lastQuad = null;
      command = sc.command();
      continue;
    }

    if (upper === "M") {
      move(nx(), ny());
      previous = "M";
      lastCubic = lastQuad = null;
      // Pasangan berikutnya tanpa perintah = lineto.
      while (sc.hasNumber()) {
        line(nx(), ny());
        previous = "L";
      }
      command = sc.command();
      continue;
    }

    if (upper === "L") {
      do {
        line(nx(), ny());
      } while (sc.hasNumber());
      previous = "L";
      lastCubic = lastQuad = null;
    } else if (upper === "H") {
      do {
        line(nx(), cy);
      } while (sc.hasNumber());
      previous = "H";
      lastCubic = lastQuad = null;
    } else if (upper === "V") {
      do {
        line(cx, ny());
      } while (sc.hasNumber());
      previous = "V";
      lastCubic = lastQuad = null;
    } else if (upper === "C") {
      do {
        const x1 = nx();
        const y1 = ny();
        const x2 = nx();
        const y2 = ny();
        const x = nx();
        const y = ny();
        cubic(x1, y1, x2, y2, x, y);
        lastCubic = [x2, y2];
        lastQuad = null;
        previous = "C";
      } while (sc.hasNumber());
    } else if (upper === "S") {
      do {
        const x2 = nx();
        const y2 = ny();
        const x = nx();
        const y = ny();
        const [x1, y1] = previous === "C" || previous === "S" ? [2 * cx - lastCubic[0], 2 * cy - lastCubic[1]] : [cx, cy];
        cubic(x1, y1, x2, y2, x, y);
        lastCubic = [x2, y2];
        lastQuad = null;
        previous = "S";
      } while (sc.hasNumber());
    } else if (upper === "Q") {
      do {
        const qx = nx();
        const qy = ny();
        const x = nx();
        const y = ny();
        cubic(cx + (2 / 3) * (qx - cx), cy + (2 / 3) * (qy - cy), x + (2 / 3) * (qx - x), y + (2 / 3) * (qy - y), x, y);
        lastQuad = [qx, qy];
        lastCubic = null;
        previous = "Q";
      } while (sc.hasNumber());
    } else if (upper === "T") {
      do {
        const x = nx();
        const y = ny();
        const [qx, qy] = previous === "Q" || previous === "T" ? [2 * cx - lastQuad[0], 2 * cy - lastQuad[1]] : [cx, cy];
        cubic(cx + (2 / 3) * (qx - cx), cy + (2 / 3) * (qy - cy), x + (2 / 3) * (qx - x), y + (2 / 3) * (qy - y), x, y);
        lastQuad = [qx, qy];
        lastCubic = null;
        previous = "T";
      } while (sc.hasNumber());
    } else if (upper === "A") {
      do {
        const rx = sc.number();
        const ry = sc.number();
        const rotation = sc.number();
        const largeArc = sc.number() !== 0;
        const sweep = sc.number() !== 0;
        const x = nx();
        const y = ny();
        for (const c of arcToCubics(cx, cy, rx, ry, rotation, largeArc, sweep, x, y)) {
          if (c.length === 2) line(c[0], c[1]);
          else cubic(c[0], c[1], c[2], c[3], c[4], c[5]);
        }
        lastCubic = lastQuad = null;
        previous = "A";
      } while (sc.hasNumber());
    } else {
      throw new Error(`Perintah tidak dikenal: ${command}`);
    }
    command = sc.command();
  }
  return out.join(" ");
}

// ---------------------------------------------------------------------------
// Ambil SVG, ekstrak dua path
// ---------------------------------------------------------------------------

async function svgFor(name) {
  await mkdir(CACHE, { recursive: true });
  const file = path.join(CACHE, `${name}.svg`);
  if (existsSync(file)) return readFile(file, "utf8");
  const res = await fetch(`${BASE}/${name}-duotone.svg`);
  if (!res.ok) throw new Error(`Gagal mengambil ${name}: HTTP ${res.status}`);
  const svg = await res.text();
  await writeFile(file, svg);
  return svg;
}

function pathsFrom(svg, name) {
  const paths = [...svg.matchAll(/<path\b([^>]*)\/?>/g)].map((m) => {
    const attrs = m[1];
    const d = /\bd="([^"]+)"/.exec(attrs)?.[1];
    if (!d) throw new Error(`Path tanpa d pada ${name}`);
    return { d, secondary: /\bopacity="0?\.2"/.test(attrs) };
  });
  if (paths.length !== 2) throw new Error(`${name}: diharapkan 2 path, dapat ${paths.length}`);
  const secondary = paths.find((p) => p.secondary);
  const primary = paths.find((p) => !p.secondary);
  if (!secondary || !primary) throw new Error(`${name}: lapisan duotone tidak lengkap`);
  return {
    secondary: normalizePath(secondary.d),
    primary: normalizePath(primary.d),
  };
}

// ---------------------------------------------------------------------------
// Keluaran platform
// ---------------------------------------------------------------------------

const csharpString = (s) => `"${s}"`;

async function main() {
  const icons = {};
  for (const name of ICONS) {
    icons[name] = pathsFrom(await svgFor(name), name);
    process.stdout.write(`\r${Object.keys(icons).length}/${ICONS.length} ${name.padEnd(28)}`);
  }
  process.stdout.write("\n");

  const json = { version: VERSION, size: 256, icons };
  const sharedDir = path.join(ROOT, "shared", "icons");
  await mkdir(sharedDir, { recursive: true });
  await writeFile(path.join(sharedDir, "phosphor.json"), JSON.stringify(json, null, 2) + "\n");

  const header = `// <auto-generated>\n// Dibuat oleh scripts/gen-phosphor-icons.mjs dari @phosphor-icons/core ${VERSION} (ISC).\n// Jangan diubah manual.\n// </auto-generated>\n`;
  const cs = `${header}
using System.Collections.Generic;

namespace Zterm;

internal static class PhosphorData
{
    public readonly record struct Glyph(string Secondary, string Primary);

    public static readonly IReadOnlyDictionary<string, Glyph> All = new Dictionary<string, Glyph>
    {
${Object.entries(icons)
  .map(([name, g]) => `        [${csharpString(name)}] = new(${csharpString(g.secondary)}, ${csharpString(g.primary)}),`)
  .join("\n")}
    };
}
`;
  await writeFile(path.join(ROOT, "apps", "windows", "Zterm", "Core", "PhosphorIcons.g.cs"), cs);

  // Linux: satu SVG simbolik per ikon. GTK mewarnai ulang path sesuai `color`
  // CSS dan tetap mempertahankan opacity 0.2 pada lapisan duotone.
  await mkdir(LINUX_ACTIONS, { recursive: true });
  const files = new Set();
  for (const [name, g] of Object.entries(icons)) {
    const file = `zterm-${name}-symbolic.svg`;
    files.add(file);
    const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="256" height="256" viewBox="0 0 256 256">
  <path fill="#000000" opacity="0.2" d="${g.secondary}"/>
  <path fill="#000000" d="${g.primary}"/>
</svg>
`;
    await writeFile(path.join(LINUX_ACTIONS, file), svg);
  }
  for (const old of await readdir(LINUX_ACTIONS)) {
    if (old.startsWith("zterm-") && old.endsWith("-symbolic.svg") && !files.has(old)) {
      await unlink(path.join(LINUX_ACTIONS, old));
    }
  }

  console.log(`Selesai: ${ICONS.length} ikon -> shared/icons/phosphor.json + Windows + Linux.`);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
