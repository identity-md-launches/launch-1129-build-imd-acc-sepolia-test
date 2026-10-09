/* imd/acc Sepolia test page.
 * No wallet library: a tiny JSON-RPC client over public Sepolia RPCs for reads and
 * window.ethereum (EIP-1193) for transactions. Selectors were computed from the pinned source
 * with `cast sig` and are listed in the README.
 */
import './style.css';

// ───────────────────────────── types ─────────────────────────────
interface Config {
  label: string;
  chainId: number;
  chainIdHex: string;
  chainName: string;
  explorer: string;
  rpcs: string[];
  addresses: { testIMD: string; testSIMD: string; stacker: string };
  stackerDeployBlock: number;
  logChunk?: number;
  leaderboardSize?: number;
}
interface ListedProject { name: string; fromBlock: number }
interface StackedLog { project: string; trader: string; imd: bigint; shares: bigint; block: number; tx: string }
interface TraderAgg { stacked: bigint; points: bigint; shares: bigint }
interface ProjectAgg { name: string; stacked: bigint; traders: Set<string> }
interface Eip1193 {
  request(args: { method: string; params?: unknown[] | object }): Promise<unknown>;
  on?(event: string, handler: (...args: never[]) => void): void;
}
interface RpcError { code?: number; message?: string; data?: unknown }
declare global { interface Window { ethereum?: Eip1193 } }

// ───────────────────────────── constants ─────────────────────────────
const SEL = {
  faucet: '0xde5f72fd', // faucet()
  nextFaucetAt: '0x5dff2121', // nextFaucetAt(address)
  credit: '0xef6506db', // credit(address,uint256)
  approve: '0x095ea7b3', // approve(address,uint256)
  balanceOf: '0x70a08231', // balanceOf(address)
  allowance: '0xdd62ed3e', // allowance(address,address)
  convertToAssets: '0x07a2d13a', // convertToAssets(uint256)
  traderStacked: '0x6a43f8a7', // traderStacked(address)
  totalStacked: '0x29eae70d', // totalStacked()
  totalAssets: '0x01e1d114', // totalAssets()
  totalSupply: '0x18160ddd', // totalSupply()
  paused: '0x5c975abb', // paused()
} as const;
// keccak256("Stacked(address,address,uint256,uint256)")
const STACKED_TOPIC = '0x7fbd7b0bc9aac1aa6f42ea64666fad17288ea759411a11f4231a958bc31838c6';
const ONE = 10n ** 18n;
const SHARE_DECIMALS = 24; // TestSIMD: 18 + decimals offset of 6
// Custom errors the contracts can raise, mapped to a sentence that says what to do.
const ERRORS: Record<string, string> = {
  '0x12272bab': 'The faucet is on cooldown for this address. Wait for the time shown next to the button.', // FaucetCooldown(uint256)
  '0xb3c61a83': 'The vault refused the deposit: it is paused. Ask the vault owner to unpause, then try again.', // DepositMoreThanMax()
  '0xd93c0665': 'The vault is paused. Ask the vault owner to unpause, then try again.', // EnforcedPause()
  '0xfb8f41b2': 'The Stacker allowance is too small. Approve again with the full amount.', // ERC20InsufficientAllowance
  '0xe450d38c': 'Not enough tIMD in this wallet. Use the faucet first.', // ERC20InsufficientBalance
  '0x3454155a': 'The trader address is zero.', // ZeroTrader()
  '0x9811e0c7': 'The vault would mint zero shares for this amount. Try a larger amount.', // ZeroShares()
};

// ───────────────────────────── state ─────────────────────────────
const state = {
  cfg: null as Config | null,
  projects: new Map<string, ListedProject>(),
  rpcIndex: 0,
  logs: [] as StackedLog[],
  latestBlock: 0,
  account: null as string | null,
  walletChainId: null as string | null,
  agg: null as { traders: Map<string, TraderAgg>; projects: Map<string, ProjectAgg> } | null,
  busy: false,
};

const $ = <T extends HTMLElement = HTMLElement>(id: string): T => {
  const el = document.getElementById(id);
  if (!el) throw new Error(`missing element #${id}`);
  return el as T;
};
const cfg = (): Config => {
  if (!state.cfg) throw new Error('config not loaded');
  return state.cfg;
};

// ───────────────────────────── encoding helpers ─────────────────────────────
const pad32 = (hex: string) => hex.replace(/^0x/, '').padStart(64, '0');
const encAddr = (a: string) => pad32(a.toLowerCase());
const encUint = (n: bigint) => pad32(n.toString(16));
const enc = (sel: string, ...words: string[]) => sel + words.join('');
const toBig = (hex: unknown) => (typeof hex === 'string' && hex !== '0x') ? BigInt(hex) : 0n;
const hexToAddr = (word: string) => '0x' + word.slice(-40);
const isAddr = (a: unknown): a is string => typeof a === 'string' && /^0x[0-9a-fA-F]{40}$/.test(a);
const short = (a: string) => a.slice(0, 6) + '…' + a.slice(-4);

function fmt(big: bigint, decimals = 18, dp = 4): string {
  const neg = big < 0n;
  if (neg) big = -big;
  const base = 10n ** BigInt(decimals);
  const whole = big / base;
  const frac = (big % base).toString().padStart(decimals, '0').slice(0, dp).replace(/0+$/, '');
  const w = whole.toString().replace(/\B(?=(\d{3})+(?!\d))/g, ',');
  return (neg ? '-' : '') + w + (frac ? '.' + frac : '');
}

function parseAmount(text: string): bigint {
  const m = text.trim().match(/^(\d+)(?:\.(\d{0,18}))?$/);
  if (!m) throw new Error('Enter the amount as a number with at most 18 decimals, for example 100 or 0.5.');
  return BigInt(m[1]) * ONE + BigInt((m[2] ?? '').padEnd(18, '0'));
}

// ───────────────────────────── JSON-RPC with failover ─────────────────────────────
async function rpc<T = unknown>(method: string, params: unknown[]): Promise<T> {
  const rpcs = cfg().rpcs;
  let lastErr: unknown;
  for (let i = 0; i < rpcs.length; i++) {
    const idx = (state.rpcIndex + i) % rpcs.length;
    try {
      const res = await fetch(rpcs[idx], {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }),
      });
      const body = await res.json() as { result?: T; error?: { message?: string } };
      if (body.error) throw new Error(body.error.message ?? JSON.stringify(body.error));
      state.rpcIndex = idx;
      return body.result as T;
    } catch (e) { lastErr = e; }
  }
  throw lastErr instanceof Error ? lastErr : new Error('No Sepolia RPC reachable');
}
const call = (to: string, data: string) => rpc<string>('eth_call', [{ to, data }, 'latest']);
const callBig = async (to: string, data: string) => toBig(await call(to, data));

// ───────────────────────────── logs: chunked scan + cache ─────────────────────────────
const cacheKey = () => `imdacc:${cfg().chainId}:${cfg().addresses.stacker.toLowerCase()}`;
interface RawLog { topics: string[]; data: string; blockNumber: string; transactionHash: string }
interface CachedLog { project: string; trader: string; imd: string; shares: string; block: number; tx: string }

function parseLog(l: RawLog): StackedLog {
  return {
    project: hexToAddr(l.topics[1]).toLowerCase(),
    trader: hexToAddr(l.topics[2]).toLowerCase(),
    imd: BigInt('0x' + l.data.slice(2, 66)),
    shares: BigInt('0x' + l.data.slice(66, 130)),
    block: Number(BigInt(l.blockNumber)),
    tx: l.transactionHash,
  };
}

async function scanLogs(): Promise<void> {
  const c = cfg();
  const scanInfo = $('scan-info');
  const latest = Number(BigInt(await rpc<string>('eth_blockNumber', [])));
  state.latestBlock = latest;
  const safe = Math.max(0, latest - 12); // reorg margin kept out of the cache

  let cached: { toBlock: number; logs: CachedLog[] } | null = null;
  try { cached = JSON.parse(localStorage.getItem(cacheKey()) ?? 'null'); } catch { /* ignore */ }
  let logs: StackedLog[] = [];
  let from = Number(c.stackerDeployBlock || 0);
  if (cached && cached.toBlock >= from) {
    logs = cached.logs.map((l) => ({ ...l, imd: BigInt(l.imd), shares: BigInt(l.shares) }));
    from = cached.toBlock + 1;
  }

  let chunk = Number(c.logChunk || 5000);
  const fresh: StackedLog[] = [];
  let start = from;
  while (start <= latest) {
    const end = Math.min(start + chunk - 1, latest);
    scanInfo.textContent = `Scanning Stacked events: block ${start.toLocaleString()} of ${latest.toLocaleString()}…`;
    try {
      const raw = await rpc<RawLog[]>('eth_getLogs', [{
        address: c.addresses.stacker,
        topics: [STACKED_TOPIC],
        fromBlock: '0x' + start.toString(16),
        toBlock: '0x' + end.toString(16),
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
  } catch { /* storage full or disabled: fine */ }
  state.logs = logs;
  scanInfo.textContent = `${logs.length.toLocaleString()} Stacked ${logs.length === 1 ? 'event' : 'events'} up to block ${latest.toLocaleString()}.`;
}

// ───────────────────────────── aggregation ─────────────────────────────
function listing(log: StackedLog): ListedProject | null {
  const p = state.projects.get(log.project);
  return p && log.block >= p.fromBlock ? p : null;
}

function aggregate(): void {
  const traders = new Map<string, TraderAgg>();
  const projects = new Map<string, ProjectAgg>();
  for (const l of state.logs) {
    const t = traders.get(l.trader) ?? { stacked: 0n, points: 0n, shares: 0n };
    t.stacked += l.imd;
    t.shares += l.shares;
    const p = listing(l);
    if (p) {
      t.points += l.imd;
      const pr = projects.get(l.project) ?? { name: p.name, stacked: 0n, traders: new Set<string>() };
      pr.stacked += l.imd;
      pr.traders.add(l.trader);
      projects.set(l.project, pr);
    }
    traders.set(l.trader, t);
  }
  state.agg = { traders, projects };
}

// ───────────────────────────── rendering ─────────────────────────────
function link(addr: string, text?: string, kind: 'address' | 'tx' = 'address'): HTMLAnchorElement {
  const a = document.createElement('a');
  a.href = `${cfg().explorer}/${kind}/${addr}`;
  a.target = '_blank';
  a.rel = 'noopener';
  a.className = 'mono';
  a.textContent = text ?? addr;
  if (text) a.title = addr;
  return a;
}
function cell(content: Node | string, cls?: string): HTMLTableCellElement {
  const td = document.createElement('td');
  if (cls) td.className = cls;
  if (content instanceof Node) td.appendChild(content); else td.textContent = content;
  return td;
}
function row(...cells: HTMLTableCellElement[]): HTMLTableRowElement {
  const tr = document.createElement('tr');
  cells.forEach((c) => tr.appendChild(c));
  return tr;
}
function setBody(id: string, rows: HTMLTableRowElement[], empty: string): void {
  const table = $<HTMLTableElement>(id);
  const tb = table.querySelector('tbody')!;
  tb.replaceChildren();
  if (!rows.length) {
    const td = cell(empty, 'empty');
    td.colSpan = table.querySelectorAll('thead th').length;
    tb.appendChild(row(td));
  }
  rows.forEach((r) => tb.appendChild(r));
}
function pill(text: string, cls?: string): HTMLSpanElement {
  const s = document.createElement('span');
  s.className = 'pill' + (cls ? ' ' + cls : '');
  s.textContent = text;
  return s;
}
const byBig = <T>(key: (x: T) => bigint) => (a: T, b: T) => (key(b) > key(a) ? 1 : key(b) < key(a) ? -1 : 0);

function renderContracts(): void {
  const { testIMD, testSIMD, stacker } = cfg().addresses;
  $('addr-imd').replaceChildren(link(testIMD));
  $('addr-simd').replaceChildren(link(testSIMD));
  $('addr-stacker').replaceChildren(link(stacker));
}

function renderListed(): void {
  const rows = [...state.projects.entries()].map(([addr, p]) =>
    row(cell(p.name), cell(link(addr, short(addr))), cell(p.fromBlock.toLocaleString(), 'num')));
  setBody('listed', rows, 'No listed projects yet. Add {address, name, fromBlock} entries to projects.json; until then every stack counts as direct, no points.');
}

function renderLeaderboards(): void {
  const agg = state.agg;
  if (!agg) return;
  const n = cfg().leaderboardSize ?? 20;
  const topT = [...agg.traders.entries()]
    .filter(([, t]) => t.points > 0n)
    .sort(byBig(([, t]) => t.points))
    .slice(0, n)
    .map(([addr, t], i) => row(cell(String(i + 1)), cell(link(addr, short(addr))), cell(fmt(t.stacked), 'num'), cell(fmt(t.points, 18, 2), 'num')));
  setBody('top-traders', topT, 'No points yet. Points start when a listed project stacks for a trader.');

  const topP = [...agg.projects.entries()]
    .sort(byBig(([, p]) => p.stacked))
    .slice(0, n)
    .map(([addr, p], i) => row(cell(String(i + 1)), cell(link(addr, p.name)), cell(fmt(p.stacked), 'num'), cell(String(p.traders.size), 'num')));
  setBody('top-projects', topP, 'No listed project has stacked yet.');

  const recent = [...state.logs].slice(-10).reverse().map((l) => {
    const p = state.projects.get(l.project);
    const proj = document.createElement('span');
    proj.appendChild(link(l.project, p ? p.name : short(l.project)));
    proj.appendChild(document.createTextNode(' '));
    proj.appendChild(pill(listing(l) ? 'listed' : l.project === l.trader ? 'direct' : 'unlisted'));
    return row(cell(link(l.tx, l.block.toLocaleString(), 'tx')), cell(proj), cell(link(l.trader, short(l.trader))), cell(fmt(l.imd), 'num'));
  });
  setBody('recent', recent, 'No Stacked events yet. Use the faucet, then stack to yourself to create the first one.');
}

async function renderVaultState(): Promise<void> {
  const { testSIMD, stacker } = cfg().addresses;
  const [paused, totalAssets, totalSupply, totalStacked] = await Promise.all([
    callBig(testSIMD, SEL.paused), callBig(testSIMD, SEL.totalAssets),
    callBig(testSIMD, SEL.totalSupply), callBig(stacker, SEL.totalStacked),
  ]);
  const el = $('vault-state');
  el.textContent = paused ? 'Paused: credit reverts' : 'Open';
  el.className = 'pill ' + (paused ? 'bad' : 'ok');
  $('vault-totals').textContent =
    `${fmt(totalAssets)} tIMD staked in the vault · ${fmt(totalSupply, SHARE_DECIMALS)} tsIMD supply · ` +
    `${fmt(totalStacked)} tIMD stacked through the Stacker.`;
}

async function renderMyStack(): Promise<void> {
  const me = state.account;
  const onChain = state.walletChainId === cfg().chainIdHex;
  $('stack-empty').hidden = !!me;
  $('stack').hidden = !me;
  $('tools-hint').hidden = !!me && onChain;
  if (!me) {
    $<HTMLButtonElement>('btn-faucet').disabled = true;
    $<HTMLButtonElement>('btn-stack').disabled = true;
    $('faucet-info').textContent = '';
    return;
  }
  const { testIMD, testSIMD, stacker } = cfg().addresses;
  const [stacked, shares, imdBal, nextAt] = await Promise.all([
    callBig(stacker, enc(SEL.traderStacked, encAddr(me))),
    callBig(testSIMD, enc(SEL.balanceOf, encAddr(me))),
    callBig(testIMD, enc(SEL.balanceOf, encAddr(me))),
    callBig(testIMD, enc(SEL.nextFaucetAt, encAddr(me))),
  ]);
  const value = shares > 0n ? await callBig(testSIMD, enc(SEL.convertToAssets, encUint(shares))) : 0n;
  const mine = state.agg?.traders.get(me.toLowerCase());

  $('my-stacked').textContent = `${fmt(stacked)} tIMD`;
  $('my-points').textContent = mine ? fmt(mine.points, 18, 2) : '0';
  $('my-shares').textContent = `${fmt(shares, SHARE_DECIMALS)} tsIMD`;
  $('my-value').textContent = `${fmt(value)} tIMD`;
  $('my-imd').textContent = `${fmt(imdBal)} tIMD`;

  const now = Math.floor(Date.now() / 1000);
  const ready = Number(nextAt) <= now;
  if (!state.busy) {
    $<HTMLButtonElement>('btn-faucet').disabled = !ready || !onChain;
    $<HTMLButtonElement>('btn-stack').disabled = !onChain;
  }
  $('faucet-info').textContent = ready
    ? 'Once per 24 hours per address.'
    : `Next faucet at ${new Date(Number(nextAt) * 1000).toLocaleString()}.`;

  const per = new Map<string, { name: string | null; stacked: bigint; points: bigint }>();
  for (const l of state.logs) {
    if (l.trader !== me.toLowerCase()) continue;
    const p = listing(l);
    const e = per.get(l.project) ?? { name: p ? p.name : null, stacked: 0n, points: 0n };
    e.stacked += l.imd;
    if (p) e.points += l.imd;
    per.set(l.project, e);
  }
  const rows = [...per.entries()].map(([addr, e]) => {
    const label = document.createElement('span');
    label.appendChild(link(addr, e.name ?? (addr === me.toLowerCase() ? 'you' : short(addr))));
    label.appendChild(document.createTextNode(' '));
    label.appendChild(pill(e.name ? 'listed' : 'direct, no points', e.name ? 'ok' : undefined));
    return row(cell(label), cell(fmt(e.stacked), 'num'), cell(e.name ? fmt(e.points, 18, 2) : '—', 'num'));
  });
  setBody('my-projects', rows, 'Nothing stacked to this address yet. Mint tIMD with the faucet, then stack to yourself.');
}

// ───────────────────────────── wallet ─────────────────────────────
const eth = (): Eip1193 | undefined => window.ethereum;

type StatusKind = 'pending' | 'ok' | 'bad' | '';
function setAction(id: string, kind: StatusKind, text: string, href?: string): void {
  const el = $(id);
  el.className = 'action-status' + (kind ? ' ' + kind : '');
  const prefix = kind === 'pending' ? '⏳ ' : kind === 'ok' ? '✓ ' : kind === 'bad' ? '✕ ' : '';
  el.replaceChildren(document.createTextNode(prefix + text));
  if (href) {
    el.appendChild(document.createTextNode(' '));
    const a = document.createElement('a');
    a.href = href; a.target = '_blank'; a.rel = 'noopener';
    a.textContent = 'View on Etherscan';
    el.appendChild(a);
  }
}
function setStatus(msg: string, cls: 'ok' | 'bad' | '' = ''): void {
  const s = $('status');
  s.textContent = msg;
  s.className = 'status ' + cls;
}

function describeError(e: unknown): string {
  const err = (typeof e === 'object' && e) ? e as RpcError & { cause?: RpcError; error?: RpcError } : {};
  const code = err.code ?? err.cause?.code ?? err.error?.code;
  if (code === 4001 || /user (rejected|denied)/i.test(String(err.message))) return 'You rejected the request in your wallet. Nothing was sent.';
  if (code === -32002) return 'Your wallet already has a request open. Open the wallet and finish it.';
  const blob = JSON.stringify(e, Object.getOwnPropertyNames(err).concat(['data', 'message', 'cause', 'error']));
  for (const [sel, text] of Object.entries(ERRORS)) if (blob.includes(sel)) return text;
  if (/insufficient funds/i.test(blob)) return 'Not enough Sepolia ETH for gas. Get some from a Sepolia faucet, then try again.';
  const msg = err.message ?? (e instanceof Error ? e.message : String(e));
  return msg.length > 220 ? msg.slice(0, 220) + '…' : msg;
}

function renderChain(): void {
  const badge = $('chain-badge');
  const sw = $<HTMLButtonElement>('btn-switch');
  if (!state.account) { badge.hidden = true; sw.hidden = true; return; }
  const ok = state.walletChainId === cfg().chainIdHex;
  badge.hidden = false;
  badge.textContent = ok ? `${cfg().chainName} (chain ${cfg().chainId})` : `Wrong network: chain ${state.walletChainId ? Number(BigInt(state.walletChainId)) : '?'}`;
  badge.className = 'pill ' + (ok ? 'ok' : 'bad');
  sw.hidden = ok;
}

async function switchChain(): Promise<void> {
  const c = cfg();
  const w = eth();
  if (!w) throw new Error('No wallet found.');
  try {
    await w.request({ method: 'wallet_switchEthereumChain', params: [{ chainId: c.chainIdHex }] });
  } catch (e) {
    const code = (e as RpcError).code;
    if (code === 4902 || /unrecognized chain|not added/i.test(String((e as RpcError).message))) {
      await w.request({ method: 'wallet_addEthereumChain', params: [{
        chainId: c.chainIdHex, chainName: c.chainName, rpcUrls: c.rpcs,
        nativeCurrency: { name: 'Sepolia Ether', symbol: 'ETH', decimals: 18 },
        blockExplorerUrls: [c.explorer],
      }] });
    } else throw e;
  }
  state.walletChainId = String(await w.request({ method: 'eth_chainId' })).toLowerCase();
  renderChain();
  await renderMyStack();
}

async function withButton(id: string, pendingLabel: string, fn: () => Promise<void>): Promise<void> {
  const btn = $<HTMLButtonElement>(id);
  const label = btn.textContent;
  btn.disabled = true;
  btn.setAttribute('aria-busy', 'true');
  btn.textContent = pendingLabel;
  try { await fn(); } finally {
    btn.textContent = label;
    btn.removeAttribute('aria-busy');
    btn.disabled = false;
  }
}

let eventsBound = false;
function bindWalletEvents(): void {
  const w = eth();
  if (eventsBound || !w?.on) return;
  eventsBound = true;
  w.on('accountsChanged', ((acc: string[]) => {
    state.account = acc[0] ?? null;
    const el = $('account');
    el.hidden = !state.account;
    el.textContent = state.account ?? '';
    setAction('wallet-status', state.account ? 'ok' : '', state.account ? 'Account changed.' : 'Wallet disconnected.');
    renderChain();
    void renderMyStack();
  }) as never);
  w.on('chainChanged', ((id: string) => {
    state.walletChainId = String(id).toLowerCase();
    renderChain();
    void renderMyStack();
  }) as never);
}

async function connect(): Promise<void> {
  const w = eth();
  if (!w) {
    setAction('wallet-status', 'bad', 'No wallet found. Install a browser wallet such as MetaMask, then reload this page.');
    return;
  }
  bindWalletEvents();
  setAction('wallet-status', 'pending', 'Approve the connection in your wallet…');
  const accounts = await w.request({ method: 'eth_requestAccounts' }) as string[];
  state.account = accounts[0] ?? null;
  state.walletChainId = String(await w.request({ method: 'eth_chainId' })).toLowerCase();
  const acc = $('account');
  acc.hidden = !state.account;
  acc.textContent = state.account ?? '';
  $('btn-connect').textContent = 'Reconnect wallet';
  renderChain();
  if (state.walletChainId !== cfg().chainIdHex) {
    setAction('wallet-status', 'pending', `Connected on the wrong network. Switch to ${cfg().chainName} to continue.`);
    await renderMyStack();
    try { await switchChain(); } catch (e) { setAction('wallet-status', 'bad', describeError(e)); return; }
  }
  setAction('wallet-status', 'ok', 'Connected.');
  await renderMyStack();
}

async function sendTx(to: string, data: string, statusId: string, step: string): Promise<string> {
  const w = eth();
  if (!w || !state.account) throw new Error('Connect a wallet first.');
  if (state.walletChainId !== cfg().chainIdHex) throw new Error(`Switch your wallet to ${cfg().chainName} first.`);
  setAction(statusId, 'pending', `${step}: confirm in your wallet…`);
  const hash = String(await w.request({ method: 'eth_sendTransaction', params: [{ from: state.account, to, data }] }));
  const txUrl = `${cfg().explorer}/tx/${hash}`;
  setAction(statusId, 'pending', `${step}: sent, waiting for confirmation…`, txUrl);
  for (let i = 0; i < 100; i++) {
    await new Promise((r) => setTimeout(r, 3000));
    let rcpt: { status: string; blockNumber: string } | null = null;
    try { rcpt = await rpc('eth_getTransactionReceipt', [hash]); } catch { /* retry */ }
    if (!rcpt) {
      try { rcpt = await w.request({ method: 'eth_getTransactionReceipt', params: [hash] }) as typeof rcpt; } catch { /* retry */ }
    }
    if (rcpt) {
      if (rcpt.status !== '0x1') {
        setAction(statusId, 'bad', `${step}: the transaction reverted.`, txUrl);
        throw Object.assign(new Error('reverted'), { handled: true });
      }
      setAction(statusId, 'ok', `${step}: confirmed in block ${Number(BigInt(rcpt.blockNumber)).toLocaleString()}.`, txUrl);
      return txUrl;
    }
  }
  setAction(statusId, 'bad', `${step}: no confirmation after 5 minutes. Check the transaction in the explorer.`, txUrl);
  throw Object.assign(new Error('timeout'), { handled: true });
}

async function doFaucet(): Promise<void> {
  state.busy = true;
  await withButton('btn-faucet', 'Minting…', async () => {
    try {
      const url = await sendTx(cfg().addresses.testIMD, SEL.faucet, 'faucet-status', 'Faucet');
      await refreshAfterTx();
      setAction('faucet-status', 'ok', 'Minted 10,000 tIMD to your wallet.', url);
    } catch (e) {
      if (!(e as { handled?: boolean }).handled) setAction('faucet-status', 'bad', describeError(e));
    }
  });
  state.busy = false;
  await renderMyStack();
}

async function doStack(): Promise<void> {
  const { testIMD, stacker } = cfg().addresses;
  const input = $<HTMLInputElement>('stack-amount');
  input.removeAttribute('aria-invalid');
  let amount: bigint;
  try {
    amount = parseAmount(input.value);
    if (amount === 0n) throw new Error('Enter an amount greater than 0.');
  } catch (e) {
    input.setAttribute('aria-invalid', 'true');
    setAction('stack-status', 'bad', describeError(e));
    input.focus();
    return;
  }
  state.busy = true;
  await withButton('btn-stack', 'Stacking…', async () => {
    try {
      const me = state.account!;
      const balance = await callBig(testIMD, enc(SEL.balanceOf, encAddr(me)));
      if (balance < amount) throw new Error(`Your balance is ${fmt(balance)} tIMD. Lower the amount or use the faucet first.`);
      const allowance = await callBig(testIMD, enc(SEL.allowance, encAddr(me), encAddr(stacker)));
      if (allowance < amount) {
        await sendTx(testIMD, enc(SEL.approve, encAddr(stacker), encUint(amount)), 'stack-status', 'Step 1 of 2, approve');
      }
      const url = await sendTx(stacker, enc(SEL.credit, encAddr(me), encUint(amount)), 'stack-status', allowance < amount ? 'Step 2 of 2, credit' : 'Credit');
      await refreshAfterTx();
      setAction('stack-status', 'ok', `Stacked ${fmt(amount)} tIMD to yourself. Your stack and the recent stacks are updated.`, url);
    } catch (e) {
      if (!(e as { handled?: boolean }).handled) setAction('stack-status', 'bad', describeError(e));
    }
  });
  state.busy = false;
  await renderMyStack();
}

// ───────────────────────────── theme ─────────────────────────────
const THEME_KEY = 'imdacc:theme';
const THEMES = ['system', 'light', 'dark'] as const;
function applyTheme(t: string): void {
  if (t === 'light' || t === 'dark') document.documentElement.dataset.theme = t;
  else delete document.documentElement.dataset.theme;
  const btn = $('btn-theme');
  btn.textContent = `Theme: ${t}`;
  btn.setAttribute('aria-label', `Theme: ${t}. Activate to change.`);
}
function initTheme(): void {
  const saved = localStorage.getItem(THEME_KEY) ?? 'system';
  applyTheme(saved);
  $('btn-theme').addEventListener('click', () => {
    const cur = (localStorage.getItem(THEME_KEY) ?? 'system') as typeof THEMES[number];
    const next = THEMES[(THEMES.indexOf(cur) + 1) % THEMES.length];
    localStorage.setItem(THEME_KEY, next);
    // Snap, do not crossfade: suppress transitions for one frame.
    const style = document.createElement('style');
    style.textContent = '*,*::before,*::after{transition:none !important}';
    document.head.appendChild(style);
    applyTheme(next);
    void document.body.offsetHeight;
    requestAnimationFrame(() => style.remove());
  });
}

// ───────────────────────────── boot ─────────────────────────────
async function refresh(): Promise<void> {
  await scanLogs();
  aggregate();
  renderLeaderboards();
  await Promise.all([renderVaultState(), renderMyStack()]);
}
async function refreshAfterTx(): Promise<void> {
  try { await refresh(); } catch (e) { setStatus('Reload failed: ' + describeError(e), 'bad'); }
}

async function main(): Promise<void> {
  initTheme();
  const [c, projects] = await Promise.all([
    fetch('./config.json').then((r) => r.json() as Promise<Config>),
    fetch('./projects.json').then((r) => r.json() as Promise<Array<{ address?: string; name?: string; fromBlock?: number }>>),
  ]);
  state.cfg = c;
  for (const p of projects) {
    if (!isAddr(p.address)) continue;
    state.projects.set(p.address.toLowerCase(), { name: p.name ?? short(p.address), fromBlock: Number(p.fromBlock ?? 0) });
  }
  renderListed();

  const a = c.addresses ?? {};
  if (!isAddr(a.testIMD) || !isAddr(a.testSIMD) || !isAddr(a.stacker)) {
    setStatus('Contract addresses are not configured: fill addresses in config.json.', 'bad');
    $('scan-info').textContent = 'Waiting for contract addresses.';
    return;
  }
  renderContracts();
  $('btn-connect').addEventListener('click', () => {
    withButton('btn-connect', 'Connecting…', connect).catch((e) => setAction('wallet-status', 'bad', describeError(e)));
  });
  $('btn-switch').addEventListener('click', () => {
    withButton('btn-switch', 'Switching…', async () => {
      try { await switchChain(); setAction('wallet-status', 'ok', `Switched to ${c.chainName}.`); }
      catch (e) { setAction('wallet-status', 'bad', describeError(e)); }
    });
  });
  $('btn-faucet').addEventListener('click', () => { void doFaucet(); });
  $('btn-stack').addEventListener('click', () => { void doStack(); });
  $<HTMLInputElement>('stack-amount').addEventListener('keydown', (ev) => {
    if (ev.key === 'Enter' && !$<HTMLButtonElement>('btn-stack').disabled) void doStack();
  });
  bindWalletEvents();
  try {
    setStatus(`Reading ${c.chainName} via public RPC…`);
    await refresh();
    setStatus(`Live on ${c.chainName} (chain ${c.chainId}). Reads use public RPCs; transactions go through your wallet.`, 'ok');
  } catch (e) {
    setStatus('Unable to read Sepolia: ' + describeError(e) + ' Reload to retry.', 'bad');
  }
}

main().catch((e) => setStatus('Unable to load the page configuration: ' + describeError(e), 'bad'));
