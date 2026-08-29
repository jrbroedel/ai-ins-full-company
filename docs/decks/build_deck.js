const pptxgen = require("pptxgenjs");
const p = new pptxgen();
p.layout = "LAYOUT_WIDE"; // 13.333 x 7.5
const W = 13.333, H = 7.5;

// ---- palette (no #) ----
const BG = "141B2A", NAVY = "1F3A5F", SLATE = "33465F";
const ACCENT = "E0A62E", GOLD_DK = "B7791F";
const LIGHT = "FFFFFF", PAPER = "F4F6FA", CARDLN = "E3E8F0";
const INK = "1C2534", MUTE_L = "5C6B7E", MUTE_D = "9FB0C6";
const RED = "D64545", GREEN = "2E9E76";
const HEAD = "Cambria", BODY = "Calibri";

const shadow = () => ({ type: "outer", color: "9AA6B8", blur: 8, offset: 3, angle: 90, opacity: 0.28 });

function notes(s, t) { s.addNotes(t); }
function kicker(s, txt, x = 0.7, y = 0.55, color = GOLD_DK) {
  s.addText(txt.toUpperCase(), { x, y, w: 8, h: 0.3, isTextBox: true, fontFace: BODY, fontSize: 12, bold: true, color, charSpacing: 3, align: "left", margin: 0 });
}
function title(s, txt, { dark = false, y = 0.85, x = 0.7, w = 12, size = 32 } = {}) {
  s.addText(txt, { x, y, w, h: 1.0, isTextBox: true, fontFace: HEAD, fontSize: size, bold: true, color: dark ? LIGHT : INK, align: "left", margin: 0 });
}
function pageTag(s, n) {
  s.addText([{ text: "Torque Underwriters", options: { color: MUTE_L, bold: true } }, { text: "  ·  Investor briefing (working draft)", options: { color: MUTE_L } }],
    { x: 0.7, y: 7.02, w: 9, h: 0.3, isTextBox: true, fontFace: BODY, fontSize: 9, align: "left", margin: 0 });
  s.addText(String(n).padStart(2, "0"), { x: 12.2, y: 7.02, w: 0.6, h: 0.3, isTextBox: true, fontFace: BODY, fontSize: 9, color: MUTE_L, align: "right", margin: 0 });
}
function card(s, x, y, w, h, fill = LIGHT) {
  s.addShape(p.ShapeType.roundRect, { x, y, w, h, fill: { color: fill }, line: { color: CARDLN, width: 1 }, rectRadius: 0.06, shadow: shadow() });
}

// =================== SLIDE 1 — TITLE ===================
let s = p.addSlide(); s.background = { color: BG };
// gold gauge-arc motif (a subtle premium mark, not a stripe)
s.addShape(p.ShapeType.blockArc, { x: 10.0, y: 1.1, w: 3.4, h: 3.4, angleRange: [140, 400], fill: { color: ACCENT, transparency: 78 }, line: { type: "none" } });
s.addShape(p.ShapeType.ellipse, { x: 11.35, y: 2.45, w: 0.7, h: 0.7, fill: { color: ACCENT }, line: { type: "none" }, shadow: shadow() });
s.addText("TORQUE UNDERWRITERS", { x: 0.75, y: 2.55, w: 9.5, h: 1.1, isTextBox: true, fontFace: HEAD, fontSize: 46, bold: true, color: LIGHT, align: "left", margin: 0 });
s.addText("A tech-enabled MGA for luxury & collector auto", { x: 0.8, y: 3.65, w: 9, h: 0.5, isTextBox: true, fontFace: BODY, fontSize: 20, color: ACCENT, align: "left", margin: 0 });
s.addText("Lloyd's-backed delegated underwriting · automation-first cost base", { x: 0.8, y: 4.2, w: 9, h: 0.4, isTextBox: true, fontFace: BODY, fontSize: 14, color: MUTE_D, align: "left", margin: 0 });
s.addText("[ COMPANY LOGO ]", { x: 0.8, y: 6.35, w: 3, h: 0.35, isTextBox: true, fontFace: BODY, fontSize: 10, color: SLATE, align: "left", margin: 0 });
s.addText("Confidential · working draft", { x: 9.3, y: 6.9, w: 3.3, h: 0.3, isTextBox: true, fontFace: BODY, fontSize: 10, color: MUTE_D, align: "right", margin: 0 });
notes(s, "Opening frame. One sentence: Torque is a technology-first MGA writing luxury and collector auto on Lloyd's paper — we run underwriting as software so our cost base is structurally lower than anyone we compete with. Set up that the whole pitch is one idea: in insurance, the durable edge is cost, and we built the machine to win on cost. This is the working scaffold — swap in the logo, tighten to the room.");

// =================== SLIDE 2 — WHAT WE ARE ===================
s = p.addSlide(); s.background = { color: LIGHT };
kicker(s, "The one-liner");
title(s, "What Torque Underwriters is");
s.addText([
  { text: "We do everything an insurer does at the front line — take the risk in, price it, decide it, issue it — ", options: { color: INK } },
  { text: "without carrying the risk on our own balance sheet.", options: { color: GOLD_DK, bold: true } },
], { x: 0.7, y: 1.9, w: 11.9, h: 0.9, isTextBox: true, fontFace: BODY, fontSize: 18, align: "left", margin: 0, lineSpacingMultiple: 1.1 });
const pillars = [
  ["Delegated Lloyd's authority", "We underwrite on syndicate paper under a binding authority — a Lloyd's coverholder."],
  ["No balance-sheet risk", "Capacity carries the claims. We earn commission on premium, plus a profit share when the book performs."],
  ["Automation-first cost base", "The whole lifecycle runs as software. Humans step in only where compliance or judgment requires."],
];
pillars.forEach(([h, d], i) => {
  const x = 0.7 + i * 4.03;
  card(s, x, 3.15, 3.75, 2.9);
  s.addShape(p.ShapeType.ellipse, { x: x + 0.35, y: 3.5, w: 0.5, h: 0.5, fill: { color: NAVY }, line: { type: "none" } });
  s.addText(String(i + 1), { x: x + 0.35, y: 3.5, w: 0.5, h: 0.5, isTextBox: true, fontFace: HEAD, fontSize: 18, bold: true, color: ACCENT, align: "center", valign: "middle", margin: 0 });
  s.addText(h, { x: x + 0.35, y: 4.2, w: 3.1, h: 0.7, isTextBox: true, fontFace: HEAD, fontSize: 16, bold: true, color: INK, align: "left", margin: 0 });
  s.addText(d, { x: x + 0.35, y: 4.95, w: 3.1, h: 1.0, isTextBox: true, fontFace: BODY, fontSize: 12.5, color: MUTE_L, align: "left", margin: 0, lineSpacingMultiple: 1.05 });
});
pageTag(s, 2);
notes(s, "Anchor the model. An MGA is a licensed underwriting operation that runs on someone else's balance sheet — Lloyd's syndicates back us. That's the key economic fact: we don't need insurer capital, we earn fees and a profit share. The third pillar is the whole story — 'automation-first cost base' is why we win. Land the three pillars and move on.");

// =================== SLIDE 3 — PROBLEM ===================
s = p.addSlide(); s.background = { color: PAPER };
kicker(s, "The market reality");
title(s, "The cycle punishes fixed cost");
s.addText("Insurance rates rise and fall in cycles. When the market softens, rates fall and commissions compress — but the cost of running an insurer doesn't move with them.",
  { x: 0.7, y: 1.85, w: 11.6, h: 0.8, isTextBox: true, fontFace: BODY, fontSize: 17, color: INK, align: "left", margin: 0, lineSpacingMultiple: 1.1 });
const squeeze = [["Rates", "fall", RED], ["Commissions", "compress", RED], ["Expense base", "stays sticky", SLATE]];
squeeze.forEach(([a, b, c], i) => {
  const x = 0.7 + i * 4.03;
  card(s, x, 3.0, 3.75, 1.9);
  s.addText(a, { x: x + 0.35, y: 3.25, w: 3.1, h: 0.5, isTextBox: true, fontFace: HEAD, fontSize: 20, bold: true, color: INK, align: "left", margin: 0 });
  s.addText(b, { x: x + 0.35, y: 3.85, w: 3.1, h: 0.7, isTextBox: true, fontFace: BODY, fontSize: 24, bold: true, color: c, align: "left", margin: 0 });
});
card(s, 0.7, 5.25, 11.93, 1.15, NAVY);
s.addText([
  { text: "The result:  ", options: { color: ACCENT, bold: true } },
  { text: "most MGAs look competitive in a hard market and go underwater in a soft one.", options: { color: LIGHT } },
], { x: 1.05, y: 5.25, w: 11.2, h: 1.15, isTextBox: true, fontFace: BODY, fontSize: 18, align: "left", valign: "middle", margin: 0 });
pageTag(s, 3);
notes(s, "Set up the pain. This is the cyclicality everyone in insurance knows but few build for. Rates and commissions are market-set and they compress in a soft market; your expense base — people, systems, overhead — does not. The MGAs that die are the ones whose expense ratio was fine at peak rates and fatal at trough rates. This is the problem we designed the company around.");

// =================== SLIDE 4 — THE INSIGHT ===================
s = p.addSlide(); s.background = { color: LIGHT };
kicker(s, "The wedge");
title(s, "You can't out-price loss cost");
const cols = [
  ["Loss cost", "The actual cost of claims. It does not soften with the market. No MGA can compete it away — it is what it is.", RED, "Fixed by reality"],
  ["Expense & margin", "Everything else — acquisition, servicing, overhead. This is where the entire industry actually competes, and where automation wins permanently.", GREEN, "Where we compete"],
];
cols.forEach(([h, d, c, tag], i) => {
  const x = 0.7 + i * 6.13;
  card(s, x, 2.05, 5.8, 3.35);
  s.addShape(p.ShapeType.ellipse, { x: x + 0.45, y: 2.4, w: 0.28, h: 0.28, fill: { color: c }, line: { type: "none" } });
  s.addText(h, { x: x + 0.9, y: 2.32, w: 4.7, h: 0.5, isTextBox: true, fontFace: HEAD, fontSize: 22, bold: true, color: INK, align: "left", margin: 0 });
  s.addText(tag.toUpperCase(), { x: x + 0.9, y: 2.85, w: 4.7, h: 0.3, isTextBox: true, fontFace: BODY, fontSize: 11, bold: true, color: c, charSpacing: 2, align: "left", margin: 0 });
  s.addText(d, { x: x + 0.45, y: 3.4, w: 5.05, h: 1.7, isTextBox: true, fontFace: BODY, fontSize: 15, color: MUTE_L, align: "left", margin: 0, lineSpacingMultiple: 1.15 });
});
s.addText([
  { text: "Torque's edge is a cost structure, not a pricing trick — ", options: { color: INK, bold: true } },
  { text: "and a cost structure compounds.", options: { color: GOLD_DK, bold: true } },
], { x: 0.7, y: 5.75, w: 11.9, h: 0.6, isTextBox: true, fontFace: BODY, fontSize: 18, align: "left", margin: 0 });
pageTag(s, 4);
notes(s, "This is the intellectual core. Two levers: loss cost and expense. You cannot win on loss cost — claims cost what they cost, and pretending otherwise is how you go broke. You CAN win on expense, and expense is most of the fight. So we deliberately do not compete on underpricing risk; we compete on being the cheapest operator. Say plainly: we are not smarter at picking risk, we are structurally cheaper at running the business.");

// =================== SLIDE 5 — CROSSOVER (chart) ===================
s = p.addSlide(); s.background = { color: BG };
kicker(s, "The money slide", 0.7, 0.55, ACCENT);
title(s, "Where competitors go red — and we don't", { dark: true });
s.addText("As the market softens, a high-cost book crosses into loss. A lean cost base stays above the line.",
  { x: 0.7, y: 1.75, w: 11.6, h: 0.5, isTextBox: true, fontFace: BODY, fontSize: 15, color: MUTE_D, align: "left", margin: 0 });
card(s, 0.7, 2.35, 11.93, 4.2, LIGHT);
const cats = ["Hard", "Firm", "Softening", "Soft", "Deep soft"];
s.addChart(p.ChartType.line, [
  { name: "High-cost carrier / MGA", labels: cats, values: [14, 9, 4, -1, -6] },
  { name: "Torque (lean MGA)", labels: cats, values: [20, 16, 12, 9, 6] },
  { name: "Breakeven", labels: cats, values: [0, 0, 0, 0, 0] },
], {
  x: 0.95, y: 2.55, w: 11.4, h: 3.55,
  chartColors: [RED, ACCENT, "AEB9C7"], lineSize: [3, 3, 1.25], lineDash: ["solid", "solid", "dash"],
  showTitle: false, showLegend: true, legendPos: "b", legendFontFace: BODY, legendFontSize: 11, legendColor: INK,
  showValAxisTitle: true, valAxisTitle: "Underwriting margin  (%)", valAxisTitleFontSize: 11, valAxisTitleColor: MUTE_L,
  catAxisLabelColor: MUTE_L, catAxisLabelFontFace: BODY, catAxisLabelFontSize: 11,
  valAxisLabelColor: MUTE_L, valAxisLabelFontFace: BODY, valAxisLabelFontSize: 11,
  valGridLine: { color: "EDF0F5", size: 1 }, catGridLine: { style: "none" },
  valAxisMinVal: -10, valAxisMaxVal: 24, valAxisMajorUnit: 8,
});
s.addText("Illustrative — shape of the thesis, not a forecast.", { x: 0.7, y: 6.62, w: 11, h: 0.3, isTextBox: true, fontFace: BODY, fontSize: 10, italic: true, color: MUTE_D, align: "left", margin: 0 });
notes(s, "This is the emotional peak of the deck — slow down here. Walk the two lines left to right. In a hard market everyone makes money, so nobody's edge is visible. As rates soften, the high-cost operator's margin erodes and crosses below breakeven — that's the red line going underwater. Our line bends toward the same pressure but stays profitable, because our cost base is so much lower. The gap between the lines at the right edge is the whole investment case. Stress that it's illustrative — it shows the mechanism, and the mechanism is real: loss cost is shared by everyone, expense is not.");

// =================== SLIDE 6 — PIPELINE ===================
s = p.addSlide(); s.background = { color: LIGHT };
kicker(s, "How it works");
title(s, "What happens that you can't see");
s.addText("A clean risk never touches a human. Everything below runs as software, in order, in seconds.",
  { x: 0.7, y: 1.85, w: 11.6, h: 0.5, isTextBox: true, fontFace: BODY, fontSize: 16, color: MUTE_L, align: "left", margin: 0 });
const steps = [
  ["Intake", "Application in, structured & ID'd"],
  ["Enrich", "MVR, VIN, title, prior losses added"],
  ["Referral gate", "Route only what needs a human"],
  ["Rate", "Price inside what the state allows"],
  ["Quote", "Offer + logged, explainable decision"],
];
const bw = 2.15, gap = 0.28, startx = 0.7, by = 3.05, bh = 2.15;
steps.forEach(([h, d], i) => {
  const x = startx + i * (bw + gap);
  card(s, x, by, bw, bh, PAPER);
  s.addShape(p.ShapeType.ellipse, { x: x + bw / 2 - 0.3, y: by + 0.28, w: 0.6, h: 0.6, fill: { color: NAVY }, line: { type: "none" }, shadow: shadow() });
  s.addText(String(i + 1), { x: x + bw / 2 - 0.3, y: by + 0.28, w: 0.6, h: 0.6, isTextBox: true, fontFace: HEAD, fontSize: 20, bold: true, color: ACCENT, align: "center", valign: "middle", margin: 0 });
  s.addText(h, { x: x + 0.1, y: by + 1.0, w: bw - 0.2, h: 0.4, isTextBox: true, fontFace: HEAD, fontSize: 15, bold: true, color: INK, align: "center", margin: 0 });
  s.addText(d, { x: x + 0.12, y: by + 1.4, w: bw - 0.24, h: 0.7, isTextBox: true, fontFace: BODY, fontSize: 10.5, color: MUTE_L, align: "center", margin: 0, lineSpacingMultiple: 1.0 });
  if (i < steps.length - 1) s.addText("→", { x: x + bw - 0.04, y: by, w: gap + 0.08, h: bh, isTextBox: true, fontFace: BODY, fontSize: 20, bold: true, color: ACCENT, align: "center", valign: "middle", margin: 0 });
});
card(s, 0.7, 5.55, 11.93, 0.95, NAVY);
s.addText([
  { text: "The referral gate is the control. ", options: { color: ACCENT, bold: true } },
  { text: "It fires before anything is priced, and every decision it makes is written down and explainable.", options: { color: LIGHT } },
], { x: 1.05, y: 5.55, w: 11.2, h: 0.95, isTextBox: true, fontFace: BODY, fontSize: 15, align: "left", valign: "middle", margin: 0 });
pageTag(s, 6);
notes(s, "Demystify the automation without drowning them in detail. Five stages: take it in, enrich it with outside data, gate it, price it, quote it. The one to emphasize is the referral gate — that's what makes automation safe. It catches anything that needs a human (fraud signals, DUIs, sanctions, missing data, out-of-appetite) BEFORE pricing, so the machine only auto-quotes the clean stuff. That's how you get low cost without losing control.");

// =================== SLIDE 7 — COMPLIANCE MOAT ===================
s = p.addSlide(); s.background = { color: PAPER };
kicker(s, "The moat");
title(s, "Compliance built in as a moat");
s.addText("Underwriting with AI and external data is now regulated state by state. Torque builds to the strictest bar — New York's DFS standard — by default, so every other state is a subset, not a special case.",
  { x: 0.7, y: 1.85, w: 11.9, h: 0.85, isTextBox: true, fontFace: BODY, fontSize: 16, color: INK, align: "left", margin: 0, lineSpacingMultiple: 1.1 });
const moat = [
  ["Every decision logged", "Each quote records which permitted factors drove the price — unredacted, at the moment of decision."],
  ["Explainable adverse action", "When we decline or refer, the reason is captured and defensible in a market-conduct exam."],
  ["One standard, not 50", "Build to the toughest rule once; every looser state is automatically covered."],
];
moat.forEach(([h, d], i) => {
  const x = 0.7 + i * 4.03;
  card(s, x, 3.0, 3.75, 2.5);
  s.addShape(p.ShapeType.ellipse, { x: x + 0.35, y: 3.3, w: 0.45, h: 0.45, fill: { color: ACCENT }, line: { type: "none" } });
  s.addText(h, { x: x + 0.35, y: 3.9, w: 3.1, h: 0.6, isTextBox: true, fontFace: HEAD, fontSize: 15, bold: true, color: INK, align: "left", margin: 0 });
  s.addText(d, { x: x + 0.35, y: 4.5, w: 3.1, h: 0.9, isTextBox: true, fontFace: BODY, fontSize: 12, color: MUTE_L, align: "left", margin: 0, lineSpacingMultiple: 1.05 });
});
s.addText([
  { text: "In an AI-underwriting world, ", options: { color: INK } },
  { text: "defensibility is the product.", options: { color: GOLD_DK, bold: true } },
], { x: 0.7, y: 5.8, w: 11.9, h: 0.5, isTextBox: true, fontFace: BODY, fontSize: 18, align: "left", margin: 0 });
pageTag(s, 7);
notes(s, "Turn the scariest thing about AI underwriting — regulation — into an advantage. Regulators (NY DFS leading) now demand that algorithmic underwriting be explainable and non-discriminatory. Most startups treat that as a tax. We built to the hardest standard from day one, so compliance is a moat: it's expensive for a sloppy competitor to retrofit, and it lets us enter any state without re-architecting. Defensibility isn't overhead here — it's part of what we're selling.");

// =================== SLIDE 8 — PROOF (dark stats) ===================
s = p.addSlide(); s.background = { color: BG };
kicker(s, "Proof", 0.7, 0.55, ACCENT);
title(s, "The machine runs today — end to end", { dark: true });
const stats = [
  ["3,300", "submissions processed"],
  ["73%", "bind ratio"],
  ["$23.0M", "GWP (modeled)"],
  ["4", "states onboarded"],
];
stats.forEach(([n, l], i) => {
  const x = 0.7 + i * 3.0;
  s.addText(n, { x, y: 2.35, w: 2.8, h: 1.1, isTextBox: true, fontFace: HEAD, fontSize: 52, bold: true, color: ACCENT, align: "left", margin: 0 });
  s.addText(l, { x: x + 0.03, y: 3.5, w: 2.8, h: 0.5, isTextBox: true, fontFace: BODY, fontSize: 14, color: MUTE_D, align: "left", margin: 0 });
});
card(s, 0.7, 4.55, 11.93, 1.15, SLATE);
s.addText([
  { text: "Full pipeline — intake to bound policy — ", options: { color: LIGHT, bold: true } },
  { text: "plus a live investor dashboard and control panel, running on cloud infrastructure with per-state compliance rules exercised.", options: { color: MUTE_D } },
], { x: 1.05, y: 4.55, w: 11.2, h: 1.15, isTextBox: true, fontFace: BODY, fontSize: 15, align: "left", valign: "middle", margin: 0 });
s.addText("Modeled demonstration · synthetic data · not in-force results.", { x: 0.7, y: 6.5, w: 11.9, h: 0.35, isTextBox: true, fontFace: BODY, fontSize: 11, italic: true, color: MUTE_D, align: "left", margin: 0 });
notes(s, "This proves the thing is real, not a slideware concept. The full pipeline runs end to end on a synthetic book, four states are onboarded with their compliance rules live, and there's a working dashboard you can show. Be scrupulous — and Kent, keep this scrupulous in the investor cut too: these numbers are a MODELED demonstration on synthetic data. They prove the machine works, not that we've sold policies. Do not let anyone read $23M as traction. The honesty here is itself a credibility signal.");

// =================== SLIDE 9 — ECONOMICS ===================
s = p.addSlide(); s.background = { color: LIGHT };
kicker(s, "The economics");
title(s, "Lean by design");
s.addText("25% total acquisition cost, and a profit-commission share when the book performs. The rest of the premium flows to capacity.",
  { x: 0.7, y: 1.85, w: 11.9, h: 0.6, isTextBox: true, fontFace: BODY, fontSize: 16, color: INK, align: "left", margin: 0, lineSpacingMultiple: 1.1 });
// premium split bar
const barX = 0.7, barY = 3.0, barW = 11.93, barH = 0.95;
const seg = [["Torque MGA", 12.5, NAVY], ["Broker", 12.5, SLATE], ["Capacity", 75, ACCENT]];
let cx = barX;
seg.forEach(([lab, pct, col]) => {
  const w = barW * pct / 100;
  s.addShape(p.ShapeType.rect, { x: cx, y: barY, w, h: barH, fill: { color: col }, line: { color: LIGHT, width: 1.5 } });
  s.addText(`${pct}%`, { x: cx, y: barY, w, h: barH, isTextBox: true, fontFace: HEAD, fontSize: 18, bold: true, color: col === ACCENT ? INK : LIGHT, align: "center", valign: "middle", margin: 0 });
  s.addText(lab, { x: cx, y: barY + barH + 0.08, w, h: 0.35, isTextBox: true, fontFace: BODY, fontSize: 12.5, bold: true, color: MUTE_L, align: "center", margin: 0 });
  cx += w;
});
card(s, 0.7, 4.85, 11.93, 1.55, PAPER);
s.addText([
  { text: "Why it compounds:  ", options: { color: GOLD_DK, bold: true } },
  { text: "the cost to write and service a policy is largely software. As volume grows, revenue scales with the book while the cost base barely moves — the expense ratio falls exactly when the market makes everyone else's rise.", options: { color: INK } },
], { x: 1.05, y: 4.85, w: 11.2, h: 1.55, isTextBox: true, fontFace: BODY, fontSize: 15, align: "left", valign: "middle", margin: 0, lineSpacingMultiple: 1.1 });
pageTag(s, 9);
notes(s, "Keep this structural, not a full P&L (that's the next slide). The premium splits three ways: our MGA commission, the broker's, and the majority to the syndicates who carry the risk. The point isn't the exact split — it's the operating leverage: our costs are software costs, so they don't scale linearly with the book. That's the mechanism behind the crossover chart. Deliberately NOT showing the full model here — that stays a placeholder until the numbers are cleared.");

// =================== SLIDE 10 — UNIT ECONOMICS PLACEHOLDER ===================
s = p.addSlide(); s.background = { color: PAPER };
kicker(s, "Unit economics");
title(s, "The model goes here");
s.addShape(p.ShapeType.roundRect, { x: 0.7, y: 2.0, w: 11.93, h: 3.1, fill: { color: "ECF0F6" }, line: { color: SLATE, width: 1.5, dashType: "dash" }, rectRadius: 0.06 });
s.addText("[  Full P&L · expense ratio · unit economics — to be populated with cleared figures  ]",
  { x: 1.1, y: 2.9, w: 11.1, h: 0.8, isTextBox: true, fontFace: BODY, fontSize: 18, bold: true, color: SLATE, align: "center", margin: 0 });
s.addText("Kent — drop the model in here once numbers are signed off.",
  { x: 1.1, y: 3.7, w: 11.1, h: 0.5, isTextBox: true, fontFace: BODY, fontSize: 13, italic: true, color: MUTE_L, align: "center", margin: 0 });
s.addText("Drivers to show: target expense ratio · blended commission · profit-commission bands · plan GWP · loss-ratio assumption (technical basis).",
  { x: 0.7, y: 5.4, w: 11.9, h: 0.7, isTextBox: true, fontFace: BODY, fontSize: 13, color: MUTE_L, align: "left", margin: 0, lineSpacingMultiple: 1.1 });
pageTag(s, 10);
notes(s, "Intentional placeholder. The full financial model and unit economics belong here, but those figures need to be cleared before they go on an investor slide — and the plan-level opex is calibrated to a much larger GWP than the demo, so the two can't be mashed together without a reconciliation note. Kent: this is where your model slots in. Keep loss ratio labeled as technical/rater basis so it isn't mistaken for an accounting loss ratio.");

// =================== SLIDE 11 — WHERE WE ARE ===================
s = p.addSlide(); s.background = { color: LIGHT };
kicker(s, "Status");
title(s, "Where we are — honestly");
card(s, 0.7, 2.05, 5.8, 4.35);
s.addText("BUILT", { x: 1.05, y: 2.3, w: 5.1, h: 0.4, isTextBox: true, fontFace: BODY, fontSize: 13, bold: true, color: GREEN, charSpacing: 2, align: "left", margin: 0 });
s.addText([
  "Platform live & decision-tracked (40+ recorded decisions)",
  "Rating engine + referral / compliance gate",
  "Per-state compliance registry",
  "Demo environment, dashboard & control panel",
  "Cloud infrastructure stood up",
].map((t, i, a) => ({ text: t, options: { bullet: { indent: 15 }, color: INK, breakLine: true, paraSpaceAfter: 8 } })),
  { x: 1.05, y: 2.8, w: 5.1, h: 3.4, isTextBox: true, fontFace: BODY, fontSize: 13.5, align: "left", margin: 0 });
card(s, 6.83, 2.05, 5.8, 4.35);
s.addText("NEXT", { x: 7.18, y: 2.3, w: 5.1, h: 0.4, isTextBox: true, fontFace: BODY, fontSize: 13, bold: true, color: GOLD_DK, charSpacing: 2, align: "left", margin: 0 });
s.addText([
  "External data feeds (VIN decode, title, MVR)",
  "Sanctions / OFAC screening vendor",
  "Sub-state territory pricing (metro & ZIP cat zones)",
  "Renewals workflow",
  "State-by-state filings toward 50-state rollout",
].map((t) => ({ text: t, options: { bullet: { indent: 15 }, color: INK, breakLine: true, paraSpaceAfter: 8 } })),
  { x: 7.18, y: 2.8, w: 5.1, h: 3.4, isTextBox: true, fontFace: BODY, fontSize: 13.5, align: "left", margin: 0 });
pageTag(s, 11);
notes(s, "Credibility through candor. The platform, the engine, the compliance registry, the demo and the infra are real and built. The 'Next' column is honest about what's stubbed or unbuilt — external data integrations, a sanctions vendor, sub-state pricing depth, renewals, and the actual state filings. Investors trust a founder who names what isn't done. Don't oversell the left column or hide the right one.");

// =================== SLIDE 12 — ROLLOUT ===================
s = p.addSlide(); s.background = { color: PAPER };
kicker(s, "The path");
title(s, "From 4 states to 50");
s.addText([
  { text: "The unlock:  ", options: { color: GOLD_DK, bold: true } },
  { text: "national base rates + a per-state (then sub-state) territory factor. We scale geographically without rebuilding the rating engine for every state.", options: { color: INK } },
], { x: 0.7, y: 1.85, w: 11.9, h: 0.8, isTextBox: true, fontFace: BODY, fontSize: 16, align: "left", margin: 0, lineSpacingMultiple: 1.1 });
const phases = [
  ["Phase 1", "Launch states", "Filed rates live in the first states; pipeline bound end to end."],
  ["Phase 2", "Territory depth", "Add metro relativities and ZIP-level catastrophe zones on top of the state factor."],
  ["Phase 3", "National + renewals", "Roll state filings out toward 50; stand up the renewal book."],
];
phases.forEach(([ph, h, d], i) => {
  const x = 0.7 + i * 4.03;
  card(s, x, 3.0, 3.75, 3.0);
  s.addText(ph.toUpperCase(), { x: x + 0.35, y: 3.25, w: 3.1, h: 0.35, isTextBox: true, fontFace: BODY, fontSize: 12, bold: true, color: ACCENT, charSpacing: 2, align: "left", margin: 0 });
  s.addText(h, { x: x + 0.35, y: 3.65, w: 3.1, h: 0.6, isTextBox: true, fontFace: HEAD, fontSize: 18, bold: true, color: INK, align: "left", margin: 0 });
  s.addText(d, { x: x + 0.35, y: 4.35, w: 3.1, h: 1.5, isTextBox: true, fontFace: BODY, fontSize: 13, color: MUTE_L, align: "left", margin: 0, lineSpacingMultiple: 1.1 });
  if (i < phases.length - 1) s.addText("→", { x: x + 3.75, y: 3.0, w: 0.28, h: 3.0, isTextBox: true, fontFace: BODY, fontSize: 22, bold: true, color: ACCENT, align: "center", valign: "middle", margin: 0 });
});
pageTag(s, 12);
notes(s, "Show the scaling logic so 50 states doesn't sound like 50 rebuilds. The architectural trick: base rates are national, and only a territory factor varies by state — so onboarding a state is a data + filing exercise, not an engineering rebuild. Phase 2 deepens pricing granularity (metro, ZIP cat zones); Phase 3 is breadth plus renewals. Keep it directional; exact timing goes with the model.");

// =================== SLIDE 13 — THE ASK ===================
s = p.addSlide(); s.background = { color: BG };
kicker(s, "The ask", 0.7, 0.7, ACCENT);
s.addText("[  Raise:  $X  ]", { x: 0.7, y: 1.3, w: 11.9, h: 1.1, isTextBox: true, fontFace: HEAD, fontSize: 44, bold: true, color: LIGHT, align: "left", margin: 0 });
s.addText("Kent — set the amount and use-of-funds split.", { x: 0.72, y: 2.45, w: 11, h: 0.4, isTextBox: true, fontFace: BODY, fontSize: 13, italic: true, color: MUTE_D, align: "left", margin: 0 });
const use = [["Capacity & binder", "Secure/expand delegated authority"], ["State filings", "Rate & form filings toward rollout"], ["Data integrations", "VIN, title, MVR, sanctions feeds"], ["Team", "Underwriting & engineering depth"]];
use.forEach(([h, d], i) => {
  const x = 0.7 + (i % 2) * 6.13, y = 3.15 + Math.floor(i / 2) * 1.55;
  s.addShape(p.ShapeType.roundRect, { x, y, w: 5.8, h: 1.35, fill: { color: SLATE }, line: { type: "none" }, rectRadius: 0.05, shadow: shadow() });
  s.addShape(p.ShapeType.ellipse, { x: x + 0.35, y: y + 0.45, w: 0.4, h: 0.4, fill: { color: ACCENT }, line: { type: "none" } });
  s.addText(h, { x: x + 0.95, y: y + 0.22, w: 4.6, h: 0.4, isTextBox: true, fontFace: HEAD, fontSize: 16, bold: true, color: LIGHT, align: "left", margin: 0 });
  s.addText(d, { x: x + 0.95, y: y + 0.68, w: 4.6, h: 0.5, isTextBox: true, fontFace: BODY, fontSize: 12.5, color: MUTE_D, align: "left", margin: 0 });
});
s.addText("The lean MGA that's still standing when the market turns.", { x: 0.7, y: 6.55, w: 11.9, h: 0.5, isTextBox: true, fontFace: HEAD, fontSize: 18, italic: true, bold: true, color: ACCENT, align: "left", margin: 0 });
notes(s, "Close on the thesis, not the mechanics. Restate the one sentence: we're the operator whose cost base lets us stay profitable through the soft market that takes everyone else out. The four use-of-funds buckets are the scaffold — Kent sets the raise number and the split. End on the tagline; that's the line you want them repeating in the partner meeting.");

p.writeFile({ fileName: "torque-underwriters-investor-deck.pptx" }).then(f => console.log("wrote", f));
