/* imd/acc Sepolia test page.
 * No build step and no library: a tiny JSON-RPC client over public Sepolia RPCs for reads,
 * window.ethereum (EIP-1193) for transactions. Selectors are precomputed with `cast sig`.
 */
(() => {
  'use strict';

  const SEL = {
    faucet: '0xde5f72fd',           // faucet()
    nextFaucetAt: '0x5dff2121',     // nextFaucetAt(address)
    credit: '0xef6506db',           // credit(address,uint256)
    approve: '0x095ea7b3',          // approve(address,uint256)
    balanceOf: '0x70a08231',        // balanceOf(address)
    allowance: '0xdd62ed3e',        // allowance(address,address)
    convertToAssets: '0x07a2d13a',  // convertToAssets(uint256)
    traderStacked: '0x6a43f8a7',    // traderStacked(address)
    traderShares: '0xa181a112',     // traderShares(address)
    totalStacked: '0x29eae70d',     // totalStacked()
    totalAssets: '0x01e1d114',      // totalAssets()
    totalSupply: '0x18160ddd',      // totalSupply()
    paused: '0x5c975abb',           // paused()
  };
  // keccak256("Stacked(address,address,uint256,uint256)")
  const STACKED_TOPIC = '0x7fbd7b0bc9aac1aa6f42ea64666fad17288ea759411a11f4231a958bc31838c6';
  const ONE = 10n ** 18n;

  const $ = (id) => document.getElementById(id);
  const state = {
    cfg: null, projects: new Map(), rpcIndex: 0, logs: [], latestBlock: 0,
    account: null, agg: null,
  };

  // ───────────────────────────── encoding helpers ─────────────────────────────
  const pad32 = (hex) => hex.replace(/^0x/, '').padStart(64, '0');
  const encAddr = (a) => pad32(a.toLowerCase());
  const encUint = (n) => pad32(BigInt(n).toString(16));
  const enc = (sel, ...words) => sel + words.join('');
  const toBig = (hex) => (hex && hex !== '0x') ? BigInt(hex) : 0n;
  const hexToAddr = (word) => '0x' + word.slice(-40);
  const isAddr = (a) => /^0x[0-9a-fA-F]{40}$/.test(a || '');
  const short = (a) => a.slice(0, 6) + '…' + a.slice(-4);

  function fmt(big, decimals = 18, dp = 4) {
    const neg = big < 0n; if (neg) big = -big;
    const base = 10n ** BigInt(decimals);
    const whole = big / base;
    let frac = (big % base).toString().padStart(decimals, '0').slice(0, dp).replace(/0+$/, '');
    const w = whole.toString().replace(/\B(?=(\d{3})+(?!\d))/g, ',');
    return (neg ? '-' : '') + w + (frac ? '.' + frac : '');
  }

  function parseAmount(text) {
    const m = String(text).trim().match(/^(\d+)(?:\.(\d{0,18}))?$/);
    if (!m) throw new Error('amount must be a decimal number with at most 18 decimals');
    return BigInt(m[1]) * ONE + BigInt((m[2] || '').padEnd(18, '0'));
  }

  // ───────────────────────────── JSON-RPC with failover ─────────────────────────────
  async function rpc(method, params) {
    const rpcs = state.cfg.rpcs;
    let lastErr;
    for (let i = 0; i < rpcs.length; i++) {
      const url = rpcs[(state.rpcIndex + i) % rpcs.length];
      try {
        const res = await fetch(url, {
          method: 'POST', headers: { 'content-type': 'application/json' },
          body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }),
        });
        const body = await res.json();
        if (body.error) throw new Error(body.error.message || JSON.stringify(body.error));
        state.rpcIndex = (state.rpcIndex + i) % rpcs.length;
        return body.result;
      } catch (e) { lastErr = e; }
    }
    throw lastErr || new Error('no RPC reachable');
  }
  const call = (to, data) => rpc('eth_call', [{ to, data }, 'latest']);
  const callBig = async (to, data) => toBig(await call(to, data));

  // ───────────────────────────── logs: chunked scan + cache ─────────────────────────────
  const cacheKey = () => `imdacc:${state.cfg.chainId}:${state.cfg.addresses.stacker.toLowerCase()}`;

  function parseLog(l) {
    return {
      project: hexToAddr(l.topics[1]).toLowerCase(),
      trader: hexToAddr(l.topics[2]).toLowerCase(),
      imd: BigInt('0x' + l.data.slice(2, 66)),
      shares: BigInt('0x' + l.data.slice(66, 130)),
      block: Number(BigInt(l.blockNumber)),
      tx: l.transactionHash,
    };
  }

  async function scanLogs() {
    const { stacker } = state.cfg.addresses;
    const latest = Number(BigInt(await rpc('eth_blockNumber', [])));
    state.latestBlock = latest;
    const safe = Math.max(0, latest - 12); // leave a reorg margin out of the cache

    let cached = null;
    try { cached = JSON.parse(localStorage.getItem(cacheKey()) || 'null'); } catch (_) { /* ignore */ }
    let logs = [];
    let from = Number(state.cfg.stackerDeployBlock || 0);
    if (cached && cached.toBlock >= from) {
      logs = cached.logs.map((l) => ({ ...l, imd: BigInt(l.imd), shares: BigInt(l.shares) }));
      from = cached.toBlock + 1;
    }

    let chunk = Number(state.cfg.logChunk || 5000);
    let fresh = [];
    let start = from;
    while (start <= latest) {
      const end = Math.min(start + chunk - 1, latest);
      $('scan-info').textContent = `Scanning Stacked events: block ${start.toLocaleString()} of ${latest.toLocaleString()}…`;
      try {
        const raw = await rpc('eth_getLogs', [{
          address: stacker, topics: [STACKED_TOPIC],
          fromBlock: '0x' + start.toString(16), toBlock: '0x' + end.toString(16),
        }]);
        fresh.push(...raw.map(parseLog));
        start = end + 1;
      } catch (e) {
        if (chunk <= 500) throw e;
        chunk = Math.max(500, Math.floor(chunk / 2)); // the RPC rejected the range: shrink it
      }
    }
    logs = logs.concat(fresh);
    try {
      localStorage.setItem(cacheKey(), JSON.stringify({
        toBlock: safe,
        logs: logs.filter((l) => l.block <= safe).map((l) => ({ ...l, imd: l.imd.toString(), shares: l.shares.toString() })),
      }));
    } catch (_) { /* storage full or disabled: fine */ }
    state.logs = logs;
    $('scan-info').textContent = `${logs.length.toLocaleString()} Stacked events up to block ${latest.toLocaleString()}.`;
  }

  // ───────────────────────────── aggregation ─────────────────────────────
  function listing(log) {
    const p = state.projects.get(log.project);
    return p && log.block >= p.fromBlock ? p : null;
  }

  function aggregate() {
    const traders = new Map();
    const projects = new Map();
    for (const l of state.logs) {
      const t = traders.get(l.trader) || { stacked: 0n, points: 0n, shares: 0n };
      t.stacked += l.imd; t.shares += l.shares;
      const p = listing(l);
      if (p) {
        t.points += l.imd;
        const pr = projects.get(l.project) || { name: p.name, stacked: 0n, traders: new Set() };
        pr.stacked += l.imd; pr.traders.add(l.trader);
        projects.set(l.project, pr);
      }
      traders.set(l.trader, t);
    }
    state.agg = { traders, projects };
  }

  // ───────────────────────────── rendering ─────────────────────────────
  const link = (addr, text) => {
    const a = document.createElement('a');
    a.href = `${state.cfg.explorer}/address/${addr}`; a.target = '_blank'; a.rel = 'noopener';
    a.className = 'mono'; a.textContent = text || addr;
    return a;
  };
  const cell = (content, cls) => {
    const td = document.createElement('td');
    if (cls) td.className = cls;
    if (content instanceof Node) td.appendChild(content); else td.textContent = content;
    return td;
  };
  const row = (...cells) => { const tr = document.createElement('tr'); cells.forEach((c) => tr.appendChild(c)); return tr; };
  const setBody = (id, rows, empty) => {
    const tb = $(id).querySelector('tbody'); tb.innerHTML = '';
    if (!rows.length) tb.appendChild(row(cell(empty, 'muted')));
    rows.forEach((r) => tb.appendChild(r));
  };

  function renderContracts() {
    const { testIMD, testSIMD, stacker } = state.cfg.addresses;
    $('addr-imd').replaceChildren(link(testIMD));
    $('addr-simd').replaceChildren(link(testSIMD));
    $('addr-stacker').replaceChildren(link(stacker));
  }

  function renderListed() {
    const rows = [...state.projects.entries()].map(([addr, p]) =>
      row(cell(p.name), cell(link(addr)), cell(p.fromBlock.toLocaleString(), 'num')));
    setBody('listed', rows, 'No listed projects yet: projects.json is empty. Everything stacks as "direct, no points".');
  }

  function renderLeaderboards() {
    const n = state.cfg.leaderboardSize || 20;
    const topT = [...state.agg.traders.entries()]
      .filter(([, t]) => t.points > 0n)
      .sort((a, b) => (b[1].points > a[1].points ? 1 : b[1].points < a[1].points ? -1 : 0))
      .slice(0, n)
      .map(([addr, t], i) => row(cell(String(i + 1)), cell(link(addr, short(addr))), cell(fmt(t.points), 'num'), cell(fmt(t.points, 18, 2), 'num')));
    setBody('top-traders', topT, 'No stacks from listed projects yet.');

    const topP = [...state.agg.projects.entries()]
      .sort((a, b) => (b[1].stacked > a[1].stacked ? 1 : b[1].stacked < a[1].stacked ? -1 : 0))
      .slice(0, n)
      .map(([addr, p], i) => row(cell(String(i + 1)), cell(link(addr, p.name)), cell(fmt(p.stacked), 'num'), cell(String(p.traders.size), 'num')));
    setBody('top-projects', topP, 'No listed project has stacked yet.');
  }

  async function renderVaultState() {
    const { testSIMD, stacker } = state.cfg.addresses;
    const [paused, totalAssets, totalSupply, totalStacked] = await Promise.all([
      callBig(testSIMD, SEL.paused), callBig(testSIMD, SEL.totalAssets),
      callBig(testSIMD, SEL.totalSupply), callBig(stacker, SEL.totalStacked),
    ]);
    $('vault-state').textContent =
      `Vault ${paused ? 'PAUSED (credit reverts)' : 'open'} · ${fmt(totalAssets)} tIMD staked · ` +
      `${fmt(totalSupply, 24)} tsIMD supply · ${fmt(totalStacked)} tIMD stacked through the Stacker.`;
  }

  async function renderMyStack() {
    const me = state.account; if (!me) return;
    const { testIMD, testSIMD, stacker } = state.cfg.addresses;
    const [stacked, shares, imdBal, nextAt] = await Promise.all([
      callBig(stacker, enc(SEL.traderStacked, encAddr(me))),
      callBig(testSIMD, enc(SEL.balanceOf, encAddr(me))),
      callBig(testIMD, enc(SEL.balanceOf, encAddr(me))),
      callBig(testIMD, enc(SEL.nextFaucetAt, encAddr(me))),
    ]);
    const value = shares > 0n ? await callBig(testSIMD, enc(SEL.convertToAssets, encUint(shares))) : 0n;
    const mine = state.agg ? state.agg.traders.get(me.toLowerCase()) : null;

    $('my-stacked').textContent = `${fmt(stacked)} tIMD`;
    $('my-points').textContent = mine ? fmt(mine.points, 18, 2) : '0';
    $('my-shares').textContent = `${fmt(shares, 24)} tsIMD`;
    $('my-value').textContent = `${fmt(value)} tIMD`;
    $('my-imd').textContent = `${fmt(imdBal)} tIMD`;

    const now = Math.floor(Date.now() / 1000);
    const ready = Number(nextAt) <= now;
    $('btn-faucet').disabled = !ready;
    $('faucet-info').textContent = ready ? 'Once per 24h per address.' : `Next faucet at ${new Date(Number(nextAt) * 1000).toLocaleString()}.`;
    $('btn-stack').disabled = false;

    const per = new Map();
    for (const l of state.logs) {
      if (l.trader !== me.toLowerCase()) continue;
      const p = listing(l);
      const key = l.project;
      const e = per.get(key) || { name: p ? p.name : null, direct: l.project === me.toLowerCase(), stacked: 0n, shares: 0n, points: 0n };
      e.stacked += l.imd; e.shares += l.shares; if (p) e.points += l.imd;
      per.set(key, e);
    }
    const rows = [...per.entries()].map(([addr, e]) => {
      const label = document.createElement('span');
      label.appendChild(link(addr, e.name || short(addr)));
      const pill = document.createElement('span');
      pill.className = 'pill' + (e.name ? ' listed' : '');
      pill.textContent = e.name ? 'listed' : 'direct, no points';
      label.appendChild(document.createTextNode(' ')); label.appendChild(pill);
      return row(cell(label), cell(fmt(e.stacked), 'num'), cell(fmt(e.shares, 24), 'num'), cell(e.name ? fmt(e.points, 18, 2) : '—', 'num'));
    });
    setBody('my-projects', rows, 'Nothing stacked to this address yet.');
    $('stack').classList.remove('hidden');
  }

  // ───────────────────────────── wallet ─────────────────────────────
  const eth = () => window.ethereum;
  const logTx = (msg) => { $('tx-log').textContent += msg + '\n'; $('tx-log').scrollTop = 1e9; };

  async function ensureChain() {
    const want = state.cfg.chainIdHex;
    const have = await eth().request({ method: 'eth_chainId' });
    if (have.toLowerCase() === want) return;
    try {
      await eth().request({ method: 'wallet_switchEthereumChain', params: [{ chainId: want }] });
    } catch (e) {
      if (e && e.code === 4902) {
        await eth().request({ method: 'wallet_addEthereumChain', params: [{
          chainId: want, chainName: state.cfg.chainName, rpcUrls: state.cfg.rpcs,
          nativeCurrency: { name: 'Sepolia Ether', symbol: 'ETH', decimals: 18 },
          blockExplorerUrls: [state.cfg.explorer],
        }] });
      } else throw e;
    }
  }

  async function connect() {
    if (!eth()) { setStatus('No EIP-1193 wallet found (install MetaMask or similar).', 'bad'); return; }
    await ensureChain();
    const accounts = await eth().request({ method: 'eth_requestAccounts' });
    state.account = accounts[0];
    $('account').textContent = state.account;
    $('btn-connect').textContent = 'Reconnect';
    await renderMyStack();
  }

  async function sendTx(to, data, label) {
    await ensureChain();
    logTx(`${label}: sending…`);
    const hash = await eth().request({ method: 'eth_sendTransaction', params: [{ from: state.account, to, data }] });
    logTx(`${label}: ${state.cfg.explorer}/tx/${hash}`);
    for (let i = 0; i < 120; i++) {
      await new Promise((r) => setTimeout(r, 3000));
      const rcpt = await eth().request({ method: 'eth_getTransactionReceipt', params: [hash] });
      if (rcpt) {
        if (rcpt.status !== '0x1') throw new Error(`${label}: transaction reverted`);
        logTx(`${label}: confirmed in block ${Number(BigInt(rcpt.blockNumber)).toLocaleString()}`);
        return rcpt;
      }
    }
    throw new Error(`${label}: no receipt after 6 minutes`);
  }

  async function doFaucet() {
    try {
      $('btn-faucet').disabled = true;
      await sendTx(state.cfg.addresses.testIMD, SEL.faucet, 'faucet');
      await renderMyStack();
    } catch (e) { logTx('error: ' + (e.message || e)); $('btn-faucet').disabled = false; }
  }

  async function doStack() {
    const { testIMD, stacker } = state.cfg.addresses;
    try {
      $('btn-stack').disabled = true;
      const amount = parseAmount($('stack-amount').value);
      if (amount === 0n) throw new Error('amount must be > 0');
      const me = state.account;
      const allowance = await callBig(testIMD, enc(SEL.allowance, encAddr(me), encAddr(stacker)));
      if (allowance < amount) {
        await sendTx(testIMD, enc(SEL.approve, encAddr(stacker), encUint(amount)), 'approve');
      }
      await sendTx(stacker, enc(SEL.credit, encAddr(me), encUint(amount)), 'credit(self)');
      await refresh();
    } catch (e) { logTx('error: ' + (e.message || e)); }
    $('btn-stack').disabled = false;
  }

  // ───────────────────────────── boot ─────────────────────────────
  function setStatus(msg, cls) { const s = $('status'); s.textContent = msg; s.className = 'status ' + (cls || ''); }

  async function refresh() {
    await scanLogs();
    aggregate();
    renderLeaderboards();
    await Promise.all([renderVaultState(), renderMyStack()]);
  }

  async function main() {
    const [cfg, projects] = await Promise.all([
      fetch('config.json').then((r) => r.json()),
      fetch('projects.json').then((r) => r.json()),
    ]);
    state.cfg = cfg;
    for (const p of projects) {
      if (!isAddr(p.address)) continue;
      state.projects.set(p.address.toLowerCase(), { name: p.name || short(p.address), fromBlock: Number(p.fromBlock || 0) });
    }
    renderListed();

    const a = cfg.addresses || {};
    if (!isAddr(a.testIMD) || !isAddr(a.testSIMD) || !isAddr(a.stacker)) {
      setStatus('Contract addresses are not configured yet: fill site/config.json after the launch.', 'bad');
      $('scan-info').textContent = 'Waiting for contract addresses.';
      return;
    }
    renderContracts();
    $('btn-connect').addEventListener('click', () => connect().catch((e) => setStatus(e.message || String(e), 'bad')));
    $('btn-faucet').addEventListener('click', doFaucet);
    $('btn-stack').addEventListener('click', doStack);
    if (eth()) {
      eth().on && eth().on('accountsChanged', (acc) => { state.account = acc[0] || null; $('account').textContent = state.account || ''; renderMyStack(); });
      eth().on && eth().on('chainChanged', () => location.reload());
    }
    try {
      setStatus(`Connected to ${cfg.chainName} via public RPC.`, 'ok');
      await refresh();
    } catch (e) {
      setStatus('RPC error: ' + (e.message || e), 'bad');
    }
  }

  main().catch((e) => setStatus('Failed to load: ' + (e.message || e), 'bad'));
})();
