// Pocket Money passbook: reads the guard on Reactive Lasna and each chain's vault over public RPC.
// No server, no keys, no libraries. Refreshes every 15 s; new ledger lines print in.
const C = window.PM_CONFIG;
const $ = (id) => document.getElementById(id);
const film = new URLSearchParams(location.search).has("film");
if (film) document.body.classList.add("film");

// ---- tiny ABI helpers (selectors/topics precomputed with `cast sig` / `cast keccak`) ----
const SEL = {
  agents: "0xfd66091e", extraToday: "0x780baca0", ceiling: "0x753ed1bd", spentToday: "0xf059cf2b",
  householdExtraToday: "0xd8236070", dayStart: "0x9638845d", panicked: "0x94a74249",
  receiptHead: "0xa6eac38a", receiptCount: "0x7f038f3c",
  canSpend: "0x1881656b", floatOf: "0x64d5494c", frozen: "0x054f7d9c", agentFrozen: "0x27e98418", balanceOf: "0x70a08231",
};
const TOPIC = {
  spent: "0x8798e83f2d93295f8f92edc4a3909c10ce08c21de08e84c1a219b79f7fe04864",
  topUp: "0x2cbbc1d6c4c0b8508d295dd8e0e11fc9b9a921895ec28ff1873070cf5fe1bffa",
  quarantined: "0x02c384bdb8a57c6a122a5be1c0a9dc65926404841ff4e4a4d9420f81b1935940",
  panic: "0x17505ea0dd39c3128404365732befe2a0723e243a278a3705a3cdcc7fce9b039",
  raise: "0x655ef3b0b6ebf9dcaf2114b3ddd61a7fd01a813d6ce5b66793c5e8c693f3ad58",
  statement: "0xa615d6359863a50a52657dd177db5fddf42d900b479d58616a4d6e5904ec7a9e",
  synced: "0xc2aef9f4bdbf51739320c3baf3e7674bcf0000ddedb9587fc54799500ef242fc",
  resumed: "0x5d287a3a02ade76478d8449abebe9dc45b38421247132b68127dd3cd6c05f3cf",
  rebalance: "0x68ca8b6c443cf38f1e5017b6c7aef965edb02a12bba36d28f8215ff3055327a4",
  landed: "0xfd1d525c7e03cdae3e1bc4a0e440a7fd104b8a74581ea329122bd6f17444fb71",
};
const pad = (hex) => hex.replace(/^0x/, "").toLowerCase().padStart(64, "0");
const word = (data, i) => BigInt("0x" + data.slice(2 + i * 64, 2 + (i + 1) * 64));
const addrOf = (topic) => "0x" + topic.slice(26).toLowerCase();
const usd = (units) => "$" + (Number(units) / 1e6).toFixed(2);
const short = (h) => h.slice(0, 6) + "…" + h.slice(-4);
const chainName = (id) => C.chains.find((c) => BigInt(c.id) === BigInt(id))?.name ?? `chain ${id}`;

let rpcId = 0;
async function rpc(url, method, params) {
  const r = await fetch(url, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ jsonrpc: "2.0", id: ++rpcId, method, params }) });
  const j = await r.json();
  if (j.error) throw new Error(j.error.message);
  return j.result;
}
const call = (url, to, sel, ...args) => rpc(url, "eth_call", [{ to, data: sel + args.map(pad).join("") }, "latest"]);

// ---- odometer: each character is a reel of digits that rolls to its value ----
function odometer(text) {
  const el = $("odometer");
  const chars = [...text];
  while (el.children.length > chars.length) el.lastChild.remove();
  chars.forEach((ch, i) => {
    let cell = el.children[i];
    if (!cell) { cell = document.createElement("span"); cell.className = "odo-char"; el.append(cell); }
    if (/\d/.test(ch)) {
      if (!cell.firstChild || !cell.firstChild.classList?.contains("odo-reel")) {
        cell.textContent = "";
        const reel = document.createElement("span"); reel.className = "odo-reel";
        for (let d = 0; d <= 9; d++) { const s = document.createElement("span"); s.textContent = d; reel.append(s); }
        cell.append(reel);
      }
      cell.firstChild.style.transform = `translateY(-${Number(ch)}em)`;
    } else { cell.textContent = ch; }
  });
  $("hero-figure-text").textContent = text + " left to spend today";
}

// ---- the guard's view ----
async function guardState() {
  const g = C.guard, L = C.lasna;
  const [a, extra, ceil, hSpent, hExtra, dayStart, panicked, head, count] = await Promise.all([
    call(L, g, SEL.agents, C.agent), call(L, g, SEL.extraToday, C.agent), call(L, g, SEL.ceiling),
    call(L, g, SEL.spentToday), call(L, g, SEL.householdExtraToday), call(L, g, SEL.dayStart),
    call(L, g, SEL.panicked), call(L, g, SEL.receiptHead), call(L, g, SEL.receiptCount),
  ]);
  const quarantined = word(a, 1) === 1n, allowance = word(a, 2), spent = word(a, 3);
  const raise = BigInt(extra), cap = BigInt(ceil) + BigInt(hExtra), hs = BigInt(hSpent);
  const left = (x, y) => (y >= x ? 0n : x - y);
  const agentLeft = left(allowance + raise, spent), householdLeft = left(cap, hs);
  return { quarantined, allowance, spent, raise, left: agentLeft < householdLeft ? agentLeft : householdLeft,
    dayEnds: Number(BigInt(dayStart)) + 86400, panicked: BigInt(panicked) === 1n, head, count: Number(BigInt(count)) };
}

async function chainState(c) {
  const [can, flt, bal, fz, afz] = await Promise.all([
    call(c.rpc, c.vault, SEL.canSpend, C.agent, "1"), call(c.rpc, c.vault, SEL.floatOf, C.agent),
    call(c.rpc, c.usdc, SEL.balanceOf, C.agent), call(c.rpc, c.vault, SEL.frozen), call(c.rpc, c.vault, SEL.agentFrozen, C.agent),
  ]);
  return { mirror: word(can, 1), float: BigInt(flt), balance: BigInt(bal), frozen: BigInt(fz) === 1n, agentFrozen: BigInt(afz) === 1n };
}

// ---- the ledger: every line comes from the guard's own events, grouped by Reactive tx ----
const blockTime = new Map();
async function timeOf(bn) {
  if (!blockTime.has(bn)) blockTime.set(bn, Number(BigInt((await rpc(C.lasna, "eth_getBlockByNumber", [bn, false])).timestamp)) * 1000);
  return blockTime.get(bn);
}
async function guardLogs() {
  const head = Number(BigInt(await rpc(C.lasna, "eth_blockNumber", [])));
  const out = [];
  for (let a = C.fromBlock; a <= head; a += 20000) {
    const b = Math.min(a + 19999, head);
    out.push(...(await rpc(C.lasna, "eth_getLogs", [{ address: C.guard, fromBlock: "0x" + a.toString(16), toBlock: "0x" + b.toString(16), topics: [Object.values(TOPIC)] }])));
  }
  return out;
}
function payeeLabel(p) {
  const key = Object.keys(C.payees).find((k) => k !== "0x" && (pad(k) === p.slice(2).toLowerCase()));
  if (key) return C.payees[key];
  return p.slice(2, 26) === "0".repeat(24) ? "an unapproved address " + short(addrOf(p)) : "an unapproved address";
}
// A Sui/Solana spend arrives through the inbox with its source id as "txHash"; an EVM spend's txHash
// is a real transaction on that chain. Payee shape alone can't tell them apart (a Solana address
// can look like a padded EVM one), so ask the chain.
const foreignCache = new Map();
async function isForeign(spent) {
  const label = payeeLabel(spent.topics[3]);
  if (label.includes("Sui") || label.includes("Solana")) return true;
  if (spent.topics[3].slice(2, 26) !== "0".repeat(24)) return true;
  const ref = "0x" + spent.data.slice(66, 130);
  if (!foreignCache.has(ref)) {
    const chain = C.chains.find((c) => BigInt(c.id) === BigInt(spent.topics[2]));
    const tx = chain ? await rpc(chain.rpc, "eth_getTransactionByHash", [ref]).catch(() => null) : null;
    foreignCache.set(ref, !tx);
  }
  return foreignCache.get(ref);
}
async function ledgerLines(logs) {
  const byTx = new Map();
  for (const l of logs) { if (!byTx.has(l.transactionHash)) byTx.set(l.transactionHash, []); byTx.get(l.transactionHash).push(l); }
  const lines = [];
  for (const [tx, ls] of byTx) {
    const t0 = ls[0].topics[0];
    const get = (t) => ls.find((l) => l.topics[0] === t);
    const spent = get(TOPIC.spent), top = get(TOPIC.topUp), q = get(TOPIC.quarantined), syn = ls.filter((l) => l.topics[0] === TOPIC.synced).pop();
    const panic = get(TOPIC.panic), raise = get(TOPIC.raise), resumed = get(TOPIC.resumed), reb = get(TOPIC.rebalance), landed = get(TOPIC.landed);
    const line = { tx, block: ls[0].blockNumber, order: Number(BigInt(ls[0].blockNumber)) * 1e4 + Number(BigInt(ls[0].logIndex)) };
    if (spent) {
      const payee = spent.topics[3];
      const foreign = await isForeign(spent);
      line.desc = `Paid ${foreign && !/Sui|Solana/.test(payeeLabel(payee)) ? "an unapproved address on Sui/Solana" : payeeLabel(payee)}`;
      line.sub = foreign ? "reported from Sui/Solana through the inbox" : `on ${chainName(BigInt(spent.topics[2]))} · origin ${short("0x" + spent.data.slice(66, 130))}`;
      line.out = word(spent.data, 0);
      if (top) line.in = word(top.data, 1);
      if (syn) { const a = word(syn.data, 0), h = word(syn.data, 1); line.left = a < h ? a : h; }
      if (q) line.stamp = "CAUGHT";
    } else if (panic) { line.desc = `Panic pressed on ${chainName(BigInt(panic.topics[1]))}`; line.sub = "every vault frozen"; line.stamp = "FROZEN"; }
    else if (raise) { line.desc = `Raise approved on ${chainName(BigInt(raise.topics[2]))}`; line.sub = `+${usd(word(raise.data, 0))} allowance for today`; if (syn) { const a = word(syn.data, 0), h = word(syn.data, 1); line.left = a < h ? a : h; } }
    else if (reb) { line.desc = `Vault refill requested: ${chainName(BigInt(reb.topics[1]))} → ${chainName(BigInt(reb.topics[2]))}`; line.sub = `${usd(word(reb.data, 0))} over Circle CCTP`; }
    else if (landed) { line.desc = `Refill landed on ${chainName(BigInt(landed.topics[1]))}`; line.sub = `${usd(word(landed.data, 0))} minted`; }
    else if (resumed) { line.desc = addrOf(resumed.topics[1]) === "0x0000000000000000000000000000000000000000" ? "Panic lifted by the owner" : "Agent unfrozen by the owner"; }
    else if (syn && t0 === TOPIC.synced) { line.desc = "Budget set by the owner"; line.sub = "mirrored to every chain"; const a = word(syn.data, 0), h = word(syn.data, 1); line.left = a < h ? a : h; }
    else continue;
    line.time = await timeOf(line.block);
    lines.push(line);
  }
  return lines.sort((a, b) => a.order - b.order);
}

// ---- render ----
const seen = new Set();
function renderLedger(lines) {
  const body = $("ledger-body");
  $("ledger-empty").hidden = lines.length > 0;
  for (const l of lines) {
    if (seen.has(l.tx)) continue;
    seen.add(l.tx);
    const tr = document.createElement("tr");
    if (l.stamp) tr.className = "caught";
    const d = new Date(l.time);
    const cell = (cls, html) => { const td = document.createElement("td"); if (cls) td.className = cls; td.innerHTML = html; return td; };
    tr.append(
      cell("date", d.toLocaleDateString(undefined, { month: "short", day: "numeric" }) + "<br>" + d.toLocaleTimeString(undefined, { hour: "2-digit", minute: "2-digit" })),
      cell("", `${l.desc}${l.stamp ? `<span class="stamp">${l.stamp}</span>` : ""}${l.sub ? `<span class="sub">${l.sub} · <a href="${C.explorer}/tx/${l.tx}" target="_blank" rel="noopener">${short(l.tx)}</a></span>` : `<span class="sub"><a href="${C.explorer}/tx/${l.tx}" target="_blank" rel="noopener">${short(l.tx)}</a></span>`}`),
      cell("num", l.out != null ? usd(l.out) : ""),
      cell("num", l.in != null ? usd(l.in) : ""),
      cell("num", l.left != null ? usd(l.left) : ""),
    );
    if (renderLedger.primed) tr.classList.add("printing");
    body.prepend(tr);
  }
  renderLedger.primed = true;
}
function renderStatements(logs) {
  const st = logs.filter((l) => l.topics[0] === TOPIC.statement);
  $("statements-empty").hidden = st.length > 0;
  $("statements").innerHTML = st.map((l) => `<li class="statement"><b>Day ${Number(BigInt(l.topics[1])) + 1}</b><span>spent ${usd(word(l.data, 0))}</span><span>topped up ${usd(word(l.data, 1))}</span><span class="mono">${Number(word(l.data, 2))} receipts</span></li>`).join("");
}
function renderChains(states) {
  $("chain-grid").innerHTML = C.chains.map((c, i) => {
    const s = states[i];
    const pct = s.float > 0n ? Math.min(1, Number(s.balance) / Number(s.float)) : 0;
    const flag = s.frozen ? "vault frozen" : s.agentFrozen ? "agent frozen" : "";
    return `<article class="chain"><h3>${c.name}${flag ? `<span class="flag">${flag}</span>` : ""}</h3><dl>
      <div><dt>Float</dt><dd>${usd(s.balance)} <span class="sub">of ${usd(s.float)}</span><div class="float-track"><span style="transform:scaleX(${pct})"></span></div></dd></div>
      <div><dt>Mirror says left</dt><dd>${usd(s.mirror)}</dd></div></dl></article>`;
  }).join("");
}
function renderGuard(g) {
  odometer(usd(g.left));
  const cap = g.allowance + g.raise;
  $("budget-fill").style.transform = `scaleX(${cap > 0n ? Number(g.left) / Number(cap) : 0})`;
  $("f-allowance").textContent = usd(g.allowance);
  $("f-spent").textContent = usd(g.spent);
  $("f-raise").textContent = g.raise > 0n ? "+" + usd(g.raise) : "none";
  const secs = Math.max(0, g.dayEnds - Date.now() / 1000);
  $("f-reset").textContent = `${Math.floor(secs / 3600)}h ${Math.floor((secs % 3600) / 60)}m`;
  const status = $("status");
  status.dataset.state = g.panicked ? "panic" : g.quarantined ? "frozen" : "clear";
  status.textContent = g.panicked ? "Panic · everything frozen" : g.quarantined ? "Agent frozen" : "All clear";
  $("p-count").textContent = g.count;
  $("p-head").textContent = g.head;
  const day = Math.floor((Date.now() - Date.parse(C.liveStart + "T00:00:00Z")) / 86400000) + 1;
  $("run-day").textContent = day >= 1 ? `Day ${day} of the live run` : `Live run starts ${C.liveStart}`;
}

async function refresh() {
  try {
    const [g, logs, ...chains] = await Promise.all([guardState(), guardLogs(), ...C.chains.map(chainState)]);
    renderGuard(g);
    renderChains(chains);
    renderLedger(await ledgerLines(logs));
    renderStatements(logs);
    $("p-updated").textContent = new Date().toLocaleTimeString();
  } catch (e) {
    $("status").dataset.state = "loading";
    $("status").textContent = "Chains unreachable, retrying";
    console.error(e);
  }
}

$("agent-name").textContent = C.agentName;
$("agent-addr").textContent = short(C.agent);
$("p-guard").textContent = short(C.guard);
$("p-guard").href = `${C.explorer}/address/${C.guard}`;
refresh();
setInterval(refresh, 15000);
