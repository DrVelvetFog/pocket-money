// "Follow one payment": replays one real Spent event from the guard, step by step, and lets the
// reader ask the real vaults the question a shop asks. Read-only public RPC; no server, no keys.
//   ?tx=<guard tx on Lasna>  open on that payment      ?play  start stepping automatically
const C = window.PM_CONFIG;
const $ = (id) => document.getElementById(id);
const q = new URLSearchParams(location.search);

const SEL = { canSpend: "0x1881656b", floatOf: "0x64d5494c", agentFrozen: "0x27e98418", balanceOf: "0x70a08231", mirrorOf: "0xaf6458de" };
const TOPIC = {
  spent: "0x8798e83f2d93295f8f92edc4a3909c10ce08c21de08e84c1a219b79f7fe04864",
  topUp: "0x2cbbc1d6c4c0b8508d295dd8e0e11fc9b9a921895ec28ff1873070cf5fe1bffa",
  quarantined: "0x02c384bdb8a57c6a122a5be1c0a9dc65926404841ff4e4a4d9420f81b1935940",
  synced: "0xc2aef9f4bdbf51739320c3baf3e7674bcf0000ddedb9587fc54799500ef242fc",
};
const pad = (hex) => hex.replace(/^0x/, "").toLowerCase().padStart(64, "0");
const word = (data, i) => BigInt("0x" + data.slice(2 + i * 64, 2 + (i + 1) * 64));
const wordHex = (data, i) => "0x" + data.slice(2 + i * 64, 2 + (i + 1) * 64);
const usd = (units) => "$" + (Number(units) / 1e6).toFixed(2);
const short = (h) => h.slice(0, 6) + "…" + h.slice(-4);
const min = (a, b) => (a < b ? a : b);
const text = (bytes32) => (bytes32.slice(2).match(/../g) || []).map((b) => parseInt(b, 16)).filter(Boolean).map((n) => String.fromCharCode(n)).join("");
const link = (href, label) => `<a class="mono" href="${href}" target="_blank" rel="noopener">${label}</a>`;

let rpcId = 0;
async function rpc(url, method, params) {
  const r = await fetch(url, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ jsonrpc: "2.0", id: ++rpcId, method, params }) });
  const j = await r.json();
  if (j.error) throw new Error(j.error.message);
  return j.result;
}
const call = (url, to, sel, ...args) => rpc(url, "eth_call", [{ to, data: sel + args.map(pad).join("") }, "latest"]);

function payeeLabel(p) {
  const key = Object.keys(C.payees).find((k) => k.length > 3 && pad(k) === p.slice(2).toLowerCase());
  return key ? C.payees[key] : null;
}

// ---- every payment the guard has booked, oldest first ----
async function payments() {
  const head = Number(BigInt(await rpc(C.lasna, "eth_blockNumber", [])));
  const logs = [];
  for (let a = C.fromBlock; a <= head; a += 20000) {
    const b = Math.min(a + 19999, head);
    logs.push(...(await rpc(C.lasna, "eth_getLogs", [{ address: C.guard, fromBlock: "0x" + a.toString(16), toBlock: "0x" + b.toString(16), topics: [Object.values(TOPIC)] }])));
  }
  const byTx = new Map();
  for (const l of logs) { if (!byTx.has(l.transactionHash)) byTx.set(l.transactionHash, []); byTx.get(l.transactionHash).push(l); }
  const out = [];
  for (const [tx, ls] of byTx) {
    const get = (t) => ls.filter((l) => l.topics[0] === t).pop();
    const s = get(TOPIC.spent); if (!s) continue;
    const top = get(TOPIC.topUp), syn = get(TOPIC.synced);
    out.push({
      tx, block: s.blockNumber, order: Number(BigInt(s.blockNumber)) * 1e4 + Number(BigInt(s.logIndex)),
      chain: C.chains.find((c) => BigInt(c.id) === BigInt(s.topics[2])), payee: s.topics[3], label: payeeLabel(s.topics[3]),
      amount: word(s.data, 0), origin: wordHex(s.data, 1), index: Number(word(s.data, 2)), head: wordHex(s.data, 3),
      topUp: top ? word(top.data, 1) : null, left: syn ? min(word(syn.data, 0), word(syn.data, 1)) : null,
      caught: !!get(TOPIC.quarantined),
    });
  }
  out.sort((a, b) => a.order - b.order);
  out.forEach((p, i) => { p.prevHead = i ? out[i - 1].head : null; });
  await Promise.all(out.map(async (p) => {
    p.time = Number(BigInt((await rpc(C.lasna, "eth_getBlockByNumber", [p.block, false])).timestamp)) * 1000;
    await originOf(p);
  }));
  return out;
}

// What only the origin chain knows: did this happen there (EVM), or was it reported from Sui/Solana?
async function originOf(p) {
  p.originTx = p.chain ? await rpc(p.chain.rpc, "eth_getTransactionByHash", [p.origin]).catch(() => null) : null;
  const foreign = !p.originTx || /Sui|Solana/.test(p.label || "");
  p.where = /Sui/.test(p.label || "") ? "Sui" : /Solana/.test(p.label || "") ? "Solana" : foreign ? "Sui or Solana" : p.chain.name;
  p.kind = p.caught ? "caught" : foreign ? "foreign" : "shop";
}
async function chainNow(c) {
  const [can, flt, bal, afz] = await Promise.all([
    call(c.rpc, c.vault, SEL.canSpend, C.agent, "1"), call(c.rpc, c.vault, SEL.floatOf, C.agent),
    call(c.rpc, c.usdc, SEL.balanceOf, C.agent), call(c.rpc, c.vault, SEL.agentFrozen, C.agent),
  ]);
  return { left: word(can, 1), float: BigInt(flt), balance: BigInt(bal), frozen: BigInt(afz) === 1n };
}
// The shop's path: registry -> the vault holding this payer's limit -> canSpend.
async function mirrorOf(c) {
  if (!c.registry) return c.vault;
  return "0x" + (await call(c.rpc, c.registry, SEL.mirrorOf, C.agent)).slice(26);
}

// ---- the five steps, in words, for the three kinds of payment ----
const who = () => C.agentName;
function steps(p, now) {
  const chain = p.where, amt = usd(p.amount), here = p.originTx ? now[C.chains.indexOf(p.chain)] : null;
  const payee = p.label ?? "an address nobody approved";
  const originLink = p.originTx ? link(p.chain.tx + p.origin, short(p.origin)) : `<span class="mono">${short(p.origin)}</span>`;
  const guardLink = link(`${C.explorer}/tx/${p.tx}`, short(p.tx));
  const perChain = C.chains.map((c, i) => [`${c.name}, now`, `${usd(now[i].left)} left today`, `float ${usd(now[i].balance)} of ${usd(now[i].float)}${now[i].frozen ? " · agent frozen" : ""}`]);

  const agent = {
    title: `${who()} wants to pay ${amt}`,
    words: `${who()} never holds the whole budget, only a small float on each chain. ` + (p.kind === "shop"
      ? `To pay, it signs a permission slip for exactly this amount to exactly this payee. Signing sends no transaction and needs no gas.`
      : p.kind === "caught" ? `This time its key was used to send money directly, with no shop involved.`
      : `It also has a wallet on ${chain}, and pays the shop there directly.`),
    facts: [["Paying", payee, short("0x" + p.payee.slice(26))], ["Amount", amt], ["On", chain], here ? ["Its float there, now", `${usd(here.balance)} of ${usd(here.float)}`] : null],
  };
  const guard = {
    title: "The guard sees it and writes a receipt",
    words: (p.originTx ? `Nobody has to report the payment. Reactive Network watches USDC leaving ${who()}'s wallet on every chain and wakes the guard contract.`
      : `Reactive Network watches the inbox and wakes the guard contract when a report arrives.`) + ` The guard adds the amount to today's total across all chains, and chains a receipt to the one before it so the history can't be quietly edited.`,
    facts: [["Guard transaction", guardLink, "on Reactive Lasna"], ["Receipt", `No. ${p.index + 1}`], ["Receipt hash", `<span class="mono" title="${p.head}">${short(p.head)}</span>`, p.prevHead ? `built on ${short(p.prevHead)}` : "the first receipt"], p.left != null ? ["Left today, after this", usd(p.left)] : null],
  };

  if (p.kind === "caught") return [agent, {
    title: "This one skipped the shop",
    words: `This payment went straight from ${who()}'s key to an address nobody approved, the way a stolen key would be used. No shop was involved, so nothing checked the limit first. The next steps are what catches it anyway.`,
    facts: [["Paid to", short("0x" + p.payee.slice(26)), "not on the approved list"]],
  }, {
    title: `The money moves on ${chain}`,
    words: `It can't be stopped here: whoever holds the key signed a valid transfer. What limits the damage is that the wallet only ever holds a small amount.`,
    facts: [[p.originTx ? "Transaction" : "Payment reference", originLink, `on ${chain}`], ["Amount", amt]],
  }, { ...guard, title: "The guard sees it, and sees who was paid", stamp: "CAUGHT" }, {
    title: "The guard freezes the agent on every chain",
    words: `No top-up was sent. The guard told every vault to freeze ${who()}, so the float could not be refilled and shops were refused from then on. The loss stopped at what was in the wallet. ` + (now.some((n) => n.frozen)
      ? `It is still frozen, and stays that way until the owner lifts it.`
      : `Only the owner can lift the freeze. The owner has since done so, which is why the vaults below show ${who()} able to spend again.`),
    facts: perChain,
  }];

  if (p.kind === "foreign") return [agent, {
    title: "There is no vault to ask on this chain",
    words: `This payment happened on ${chain}, where Pocket Money has no vault for a shop to ask. It still counts against the same daily allowance. It is reported afterwards, which the next two steps show.`,
    facts: [["Paid to", payee]],
  }, {
    title: "The payment is reported to an inbox",
    words: `A service watching that chain reported the payment to an inbox contract on Base Sepolia. Each payment can be reported exactly once.`,
    facts: [["Payment reference", `<span class="mono" title="${p.origin}">${short(p.origin)}</span>`], ["Amount", amt]],
  }, guard, {
    title: "Every chain learns the new balance",
    words: `The guard sends the new figure to the vault on every chain. A shop on Base, Unichain or Ethereum now sees less left to spend, even though this money moved somewhere else entirely.`,
    facts: perChain,
  }];

  return [agent, {
    title: "The shop checks the limit before taking the money",
    words: `The shop looks ${who()} up in a public registry, which points to the vault holding its limit on ${chain}. The shop asks that vault whether this amount is allowed. If the answer is no, the shop refuses and no money moves. This payment passed when it was made.`,
    facts: [["Registry", p.chain.registry ? `<span class="mono">${short(p.chain.registry)}</span>` : "not deployed here", `on ${chain}`], ["Points to the vault", `<span class="mono">${short(p.mirror ?? p.chain.vault)}</span>`]],
    ask: true,
  }, {
    title: `The shop collects the payment on ${chain}`,
    words: `The shop hands the signed slip to the USDC contract and pays the gas itself. ${amt} moves from ${who()}'s float to the shop.`,
    facts: [["Transaction", originLink, `on ${chain}`], ["Sent by", `<span class="mono">${short(p.originTx.from)}</span>`, "the shop pays the gas"], ["Amount", amt]],
  }, guard, {
    title: "The float is refilled and every chain learns the new balance",
    words: `The guard sends two instructions back out. The vault on ${chain} tops the float back up, and the vault on every chain updates its copy of what's left. That is why a shop on a chain ${who()} hasn't touched today already knows the answer.`,
    facts: [["Top-up requested", p.topUp != null ? usd(p.topUp) : "none needed", `to the vault on ${chain}`], ...perChain],
  }];
}

// ---- render ----
let list = [], current = null, now = [], script = [], at = 0, timer = null;
function show(i) {
  at = Math.max(0, Math.min(script.length - 1, i));
  const s = script[at];
  $("coin").parentElement.style.setProperty("--step", at);
  document.querySelectorAll("#route button").forEach((b, n) => { b.toggleAttribute("aria-current", n === at); if (n === at) b.setAttribute("aria-current", "step"); b.classList.toggle("done", n < at); });
  $("step-title").innerHTML = s.title + (s.stamp ? `<span class="stamp">${s.stamp}</span>` : "");
  $("step-words").textContent = s.words;
  $("step-facts").innerHTML = s.facts.filter(Boolean).map(([k, v, sub]) => `<div><dt>${k}</dt><dd>${v}${sub ? `<small>${sub}</small>` : ""}</dd></div>`).join("");
  $("ask").hidden = !s.ask;
  if (s.ask) ask();
  $("prev").disabled = at === 0;
  $("next").disabled = at === script.length - 1;
  if (at === script.length - 1) stop();
}
function stop() { clearInterval(timer); timer = null; $("play").textContent = "Play"; }
function play() {
  if (timer) return stop();
  if (at === script.length - 1) show(0);
  $("play").textContent = "Pause";
  timer = setInterval(() => show(at + 1), 4500);
}

async function choose(tx) {
  stop();
  current = list.find((p) => p.tx === tx) ?? list[list.length - 1];
  $("payment").value = current.tx;
  history.replaceState(null, "", "?tx=" + current.tx);
  $("status").textContent = "Reading the chains…";
  now = await Promise.all(C.chains.map(chainNow));
  if (current.kind === "shop") current.mirror ??= await mirrorOf(current.chain).catch(() => null);
  $("station-chain").textContent = current.kind === "foreign" ? "The inbox" : current.where;
  $("ask-amount").value = (Number(current.amount) / 1e6).toFixed(2);
  script = steps(current, now);
  show(0);
  $("status").dataset.state = "clear";
  $("status").textContent = "Live from the chains";
}

// The reader's own question, put to the real vault on each chain.
let askSeq = 0;
async function ask() {
  const v = Number($("ask-amount").value), seq = ++askSeq;
  if (!(v >= 0)) { $("answers").innerHTML = "<li>Enter an amount in dollars.</li>"; return; }
  const units = BigInt(Math.round(v * 1e6)).toString(16);
  const rows = await Promise.all(C.chains.map(async (c) => {
    try {
      const r = await call(c.rpc, await mirrorOf(c), SEL.canSpend, C.agent, units);
      const ok = word(r, 0) === 1n, why = text(wordHex(r, 2));
      return `<li><span>${c.name}</span><span>${ok ? "Yes" : `<span class="no">No: ${why}</span>`} <small>${usd(word(r, 1))} left today</small></span></li>`;
    } catch { return `<li><span>${c.name}</span><span><small>couldn't reach this chain</small></span></li>`; }
  }));
  if (seq === askSeq) $("answers").innerHTML = rows.join("");
}

async function start() {
  $("agent-name").textContent = C.agentName;
  try {
    list = await payments();
    if (!list.length) { $("payment").innerHTML = "<option>No payments yet</option>"; $("status").textContent = "No payments yet"; return; }
    const when = (t) => new Date(t).toLocaleString(undefined, { month: "short", day: "numeric", hour: "numeric", minute: "2-digit" });
    $("payment").innerHTML = [...list].reverse().map((p) => `<option value="${p.tx}">${when(p.time)} · ${usd(p.amount)} · ${p.where} · ${p.label ?? "unapproved address"}${p.caught ? " · CAUGHT" : ""}</option>`).join("");
    $("payment").disabled = false;
    // open on the newest ordinary shop payment unless the link names one
    const pick = list.find((p) => p.tx === q.get("tx")) ?? [...list].reverse().find((p) => !p.caught && p.label && !/Sui|Solana/.test(p.label)) ?? list[list.length - 1];
    await choose(pick.tx);
    if (q.has("play")) play();
  } catch (e) {
    $("status").dataset.state = "loading";
    $("status").textContent = "Chains unreachable";
    console.error(e);
  }
}

$("payment").addEventListener("change", (e) => choose(e.target.value));
$("route").addEventListener("click", (e) => { const b = e.target.closest("button"); if (b && script.length) { stop(); show(Number(b.dataset.step)); } });
$("prev").addEventListener("click", () => { stop(); show(at - 1); });
$("next").addEventListener("click", () => { stop(); show(at + 1); });
$("play").addEventListener("click", play);
let debounce;
$("ask-amount").addEventListener("input", () => { clearTimeout(debounce); debounce = setTimeout(ask, 300); });
document.addEventListener("keydown", (e) => {
  if (e.target.matches("input, select") || !script.length) return;
  if (e.key === "ArrowRight") { stop(); show(at + 1); }
  if (e.key === "ArrowLeft") { stop(); show(at - 1); }
});
start();
