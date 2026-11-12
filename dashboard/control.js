// The owner's controls. Everyone sees "Needs the owner"; the desk appears only when the connected
// browser wallet is the guard's owner. The wallet signs; this page never holds a key.
// Two rules: anything that tightens (stop, lower, remove) goes straight to the wallet; anything that
// loosens (raise, approve, unfreeze) first says in plain words what it will allow and asks.
// Every transaction is simulated against the chain first, so a doomed one never reaches the wallet.
const C = window.PM_CONFIG, L = window.PM_LIB;
const $ = (id) => document.getElementById(id);
const eth = window.ethereum;
const { rpc, call, pad, word, usd, short } = L;

const LASNA = { id: 5318007, name: "Reactive Lasna", rpc: C.lasna, tx: C.explorer + "/tx/", symbol: "lREACT" };
const SEL = { // `cast sig`
  owner: "0x8da5cb5b", panic: "0x4700d305", unfreeze: "0x6a28f000", unfreezeAgent: "0xa2e97ab4", approveRaise: "0xbd22e44a",
  setAgent: "0xa9aa177a", setPayee: "0x34764f3d", setForeignPayee: "0x806fffb1", resume: "0x046f7da2", resumeAgent: "0x3b2c1056",
  balanceOf: "0x70a08231",
};
const data = (sel, ...args) => sel + args.map((a) => pad(typeof a === "bigint" ? a.toString(16) : a === true ? "1" : a === false ? "0" : a)).join("");
const units = (v) => BigInt(Math.round(Number(v) * 1e6));
const eq = (a, b) => !!a && !!b && a.toLowerCase() === b.toLowerCase();
const ether = (hex) => Number(BigInt(hex)) / 1e18;
const name = C.agentName;

let owner = null, me = null, busy = false, thawOK = false;

// ---- wallet ----
const net = (c) => ({ chainId: "0x" + c.id.toString(16), chainName: c.name, rpcUrls: [c.rpc], blockExplorerUrls: [c.tx.replace(/\/tx\/$/, "")],
  nativeCurrency: { name: c.symbol || "ETH", symbol: c.symbol || "ETH", decimals: 18 } });
async function switchTo(c) {
  try { await eth.request({ method: "wallet_switchEthereumChain", params: [{ chainId: net(c).chainId }] }); }
  catch (e) { // the wallet has never seen this chain: offer to add it, which also switches
    if (e.code !== 4902 && !/unrecognized|not been added/i.test(e.message || "")) throw e;
    await eth.request({ method: "wallet_addEthereumChain", params: [net(c)] });
  }
}
async function confirmed(c, hash) {
  for (let i = 0; i < 60; i++) {
    const r = await rpc(c.rpc, "eth_getTransactionReceipt", [hash]).catch(() => null);
    if (r) return r.status === "0x1";
    await new Promise((s) => setTimeout(s, 2000));
  }
  return null;
}
function say(html, bad) { const s = $("desk-status"); s.hidden = false; s.innerHTML = html; s.classList.toggle("bad", !!bad); }

// One owner transaction: simulate, switch chain, sign in the wallet, wait, re-read the chains.
async function act({ chain, to, calldata, doing, after = "" }) {
  if (busy) return; busy = true; document.body.classList.add("desk-busy");
  try {
    say(`${doing}: checking it against ${chain.name}…`);
    try { await rpc(chain.rpc, "eth_call", [{ from: owner, to, data: calldata }, "latest"]); }
    catch (e) { say(`${doing}: ${chain.name} would reject this (${e.message}). Nothing was sent.`, true); return; }
    say(`${doing}: switching your wallet to ${chain.name}…`);
    await switchTo(chain);
    say(`${doing}: approve it in your wallet. It goes to ${chain.name}.`);
    const hash = await eth.request({ method: "eth_sendTransaction", params: [{ from: me, to, data: calldata }] });
    const where = `<a class="mono" href="${chain.tx}${hash}" target="_blank" rel="noopener">${short(hash)}</a>`;
    say(`${doing}: sent (${where}). Waiting for ${chain.name} to confirm…`);
    const ok = await confirmed(chain, hash);
    if (ok === true) say(`${doing}: done (${where}). ${after}`);
    else if (ok === false) say(`${doing}: the transaction failed on ${chain.name} (${where}). Nothing changed.`, true);
    else say(`${doing}: still not confirmed after two minutes (${where}). Check it before trying again.`, true);
    await window.PM.refresh();
  } catch (e) {
    say(e.code === 4001 ? `${doing}: you declined it in the wallet. Nothing was sent.` : `${doing}: ${e.message || e}`, true);
  } finally { busy = false; document.body.classList.remove("desk-busy"); }
}
// The loosening rule: say what it will allow, and wait for a yes.
function allow(slot, words, yes) {
  return new Promise((done) => {
    slot.innerHTML = `<p>${words}</p><button type="button" class="yes">${yes}</button><button type="button" class="no">Cancel</button>`;
    slot.querySelector(".yes").onclick = () => { slot.innerHTML = ""; done(true); };
    slot.querySelector(".no").onclick = () => { slot.innerHTML = ""; done(false); };
    slot.querySelector(".no").focus();
  });
}

async function connect() {
  const b = $("connect");
  if (!eth) { b.textContent = "No wallet found in this browser"; b.title = "Install a browser wallet and import your pm-owner key, then reload."; return; }
  try { [me] = await eth.request({ method: "eth_requestAccounts" }); } catch { return; }
  signedIn();
}
function signedIn() {
  const b = $("connect"), mine = eq(me, owner);
  $("desk").hidden = !mine;
  b.textContent = !me ? "Owner? Connect a wallet" : mine ? "Owner connected" : "That wallet isn't the owner";
  b.title = me && !mine ? `Connected ${me}. The owner is ${owner}.` : "";
  b.disabled = mine;
  if (mine) { $("desk-owner").textContent = short(owner); render(); }
}

// ---- "Needs the owner": the same checks as script/watch.sh, for anyone to read ----
async function needs() {
  const { guard: g, chains } = window.PM, out = [];
  if (g.panicked) out.push("Everything is stopped: panic was pressed. The owner lifts it from the desk below.");
  if (g.quarantined) out.push(`${name} paid an address that wasn't approved and is frozen on every chain.`);
  C.chains.forEach((c, i) => { if (!g.panicked && !g.quarantined && (chains[i].frozen || chains[i].agentFrozen)) out.push(`Still frozen on ${c.name}.`); });
  const lre = ether(await rpc(C.lasna, "eth_getBalance", [C.guard, "latest"]));
  if (lre < 0.5) out.push(`The guard has ${lre.toFixed(2)} lREACT left. Top-ups stop when it runs out. Send lREACT to <span class="mono">${C.guard}</span> on Reactive Lasna.`);
  await Promise.all(C.chains.map(async (c, i) => {
    const [u, e] = await Promise.all([call(c.rpc, c.usdc, SEL.balanceOf, c.vault), rpc(c.rpc, "eth_getBalance", [c.vault, "latest"])]);
    if (BigInt(u) < chains[i].float) out.push(`The ${c.name} vault holds ${usd(BigInt(u))}, less than one float, so top-ups there will stop. Send USDC to <span class="mono">${c.vault}</span>.`);
    if (ether(e) < 0.00005) out.push(`The ${c.name} vault is nearly out of gas for the guard's instructions. Send a little ETH to <span class="mono">${c.vault}</span>.`);
  }));
  $("needs-list").innerHTML = out.length ? out.map((t) => `<li>${t}</li>`).join("") : `<li class="empty">Nothing needs you. ${name} is within its allowance and every vault is funded.</li>`;
}

// ---- the desk ----
function payees() { // the guard's own PayeeSet events, newest wins
  const m = new Map();
  for (const l of window.PM.logs) if (l.topics[0] === L.TOPIC.payeeSet) m.set(l.topics[1], word(l.data, 0) === 1n);
  return [...m].filter(([, on]) => on).map(([p]) => p);
}
const isAddress = (p) => p.slice(2, 26) === "0".repeat(24);
const label = (p) => { const k = Object.keys(C.payees).find((k) => k.length > 3 && pad(k) === p.slice(2).toLowerCase()); return k ? C.payees[k] : "no name on file"; };
function thawSteps() {
  const { guard: g, chains } = window.PM, s = [];
  if (g.panicked) s.push({ words: "Lift the panic on the guard", chain: LASNA, to: C.guard, calldata: data(SEL.resume) });
  if (g.quarantined) s.push({ words: `Take ${name} out of quarantine on the guard`, chain: LASNA, to: C.guard, calldata: data(SEL.resumeAgent, C.agent) });
  C.chains.forEach((c, i) => {
    if (chains[i].frozen) s.push({ words: `Unfreeze the ${c.name} vault`, chain: c, to: c.vault, calldata: data(SEL.unfreeze) });
    if (chains[i].agentFrozen) s.push({ words: `Unfreeze ${name} on ${c.name}`, chain: c, to: c.vault, calldata: data(SEL.unfreezeAgent, C.agent) });
  });
  return s;
}
function render() {
  if (!window.PM || !eq(me, owner)) return;
  const { guard: g } = window.PM;
  $("allow-now").textContent = usd(g.allowance);
  $("allow-ceiling").textContent = usd(g.ceiling) + " a day";
  if (!$("stop-chain").options.length) for (const id of ["stop-chain", "raise-chain"]) $(id).innerHTML = C.chains.map((c, i) => `<option value="${i}">${c.name}</option>`).join("");
  const stopped = g.panicked || window.PM.chains.every((c) => c.frozen);
  $("stop").disabled = stopped; $("stop").textContent = stopped ? "Already stopped" : "Stop everything";

  $("payees").innerHTML = payees().map((p) => `<li><span>${label(p)}<small class="mono">${isAddress(p) ? "0x" + p.slice(26) : p}</small></span><button type="button" data-remove="${p}">Remove</button></li>`).join("") || `<li class="empty">Nobody is approved, so any payment will freeze ${name}.</li>`;

  const steps = thawSteps();
  $("thaw-card").hidden = !steps.length;
  if (!steps.length) { thawOK = false; return; }
  const q = [...window.PM.logs].reverse().find((l) => l.topics[0] === L.TOPIC.quarantined);
  $("thaw-why").innerHTML = g.panicked || window.PM.chains.some((c) => c.frozen) ? "Panic was pressed, so every vault is frozen."
    : `${name} paid <span class="mono">${q ? short("0x" + q.data.slice(26, 66)) : "an address"}</span>, which wasn't on the approved list, and was frozen on every chain.`;
  $("thaw-steps").innerHTML = steps.map((s, i) => `<li><button type="button" data-thaw="${i}" ${thawOK ? "" : "disabled"}>${s.words}</button><small>${s.chain.name}</small></li>`).join("");
  if (!thawOK && !$("thaw-confirm").innerHTML) {
    allow($("thaw-confirm"), `Lifting this lets ${name} spend again on every chain. It takes ${steps.length} transaction${steps.length > 1 ? "s" : ""}, one per line below. Only do it once you know why the freeze happened.`, "I know why. Unlock the steps")
      .then((yes) => { thawOK = yes; render(); });
  }
}

$("connect").onclick = connect;
$("stop").onclick = () => { const c = C.chains[$("stop-chain").value]; act({ chain: c, to: c.vault, calldata: data(SEL.panic), doing: "Stop everything", after: "The guard is freezing the other chains now." }); };
$("thaw-steps").onclick = (e) => { const i = e.target.dataset.thaw; if (i !== undefined) act({ ...thawSteps()[i], doing: thawSteps()[i].words }); };
$("allow-set").onclick = async () => {
  const now = window.PM.guard.allowance, next = units($("allow-new").value);
  if (!($("allow-new").value !== "" && next >= 0n)) return say("Enter the new daily allowance in dollars.", true);
  if (next === now) return say(`The allowance is already ${usd(now)}.`);
  if (next > now) {
    const cap = window.PM.guard.ceiling;
    const yes = await allow($("allow-confirm"), `${name} will be able to spend up to ${usd(next)} a day across every chain, ${usd(next - now)} more than now.${next > cap ? ` The household ceiling is ${usd(cap)}, so anything above that has no effect.` : ""}`, `Yes, allow ${usd(next)} a day`);
    if (!yes) return;
  }
  act({ chain: LASNA, to: C.guard, calldata: data(SEL.setAgent, C.agent, next), doing: `Set the allowance to ${usd(next)}`, after: "Each chain's vault gets the new figure in a few seconds." });
};
$("raise-set").onclick = async () => {
  const a = units($("raise-amount").value), c = C.chains[$("raise-chain").value];
  if (!(a > 0n)) return say("Enter how much extra to allow today, in dollars.", true);
  // The guard's day is 24 hours from its own start and rolls on its next reaction, so count from there.
  const secs = 86400 - ((Date.now() / 1000 - window.PM.guard.dayEnds) % 86400 + 86400) % 86400;
  const yes = await allow($("raise-confirm"), `${name} will be able to spend ${usd(a)} more than its allowance, on every chain, until the day resets in ${Math.floor(secs / 3600)}h ${Math.floor((secs % 3600) / 60)}m. It ends by itself.`, `Yes, allow ${usd(a)} extra today`);
  if (yes) act({ chain: c, to: c.vault, calldata: data(SEL.approveRaise, C.agent, a), doing: `Approve a ${usd(a)} raise`, after: "The guard applies it on every chain in a few seconds." });
};
$("payee-add").onclick = async () => {
  const a = $("payee-new").value.trim();
  if (!/^0x[0-9a-fA-F]{40}$/.test(a)) return say("That isn't an address. It should be 0x followed by 40 characters.", true);
  if (payees().some((p) => pad(a) === p.slice(2).toLowerCase())) return say("That address is already approved.");
  const yes = await allow($("payee-confirm"), `${name} will be able to pay <span class="mono">${a}</span> on every chain without being frozen. Check every character: money sent to a wrong address can't be called back.`, "Yes, approve this address");
  if (yes) act({ chain: LASNA, to: C.guard, calldata: data(SEL.setPayee, a, true), doing: `Approve ${short(a)}` });
};
$("payees").onclick = (e) => {
  const p = e.target.dataset.remove; if (!p) return;
  act({ chain: LASNA, to: C.guard, doing: `Remove ${isAddress(p) ? short("0x" + p.slice(26)) : short(p)}`,
    calldata: isAddress(p) ? data(SEL.setPayee, "0x" + p.slice(26), false) : data(SEL.setForeignPayee, p, false) });
};

document.addEventListener("pm:state", () => { needs().catch(console.error); render(); });
(async () => {
  owner = "0x" + (await call(C.lasna, C.guard, SEL.owner)).slice(26);
  if (!eth) return;
  eth.on?.("accountsChanged", (a) => { me = a[0] || null; signedIn(); });
  [me] = await eth.request({ method: "eth_accounts" }).catch(() => []); // already connected earlier: no prompt
  if (me) signedIn();
})();
