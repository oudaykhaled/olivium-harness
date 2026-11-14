#!/bin/bash
# Isolation probe. Runs inside an agent container, prints one JSON object on
# stdout and exits 0 only when every check passes.
#   PROBE_METER_URL    default http://meter:8080/healthz
#   PROBE_GATEWAY_IPS  space-separated bridge gateway candidates
#   PROBE_CONTROL=1    positive control for an egress network: only example.com
#                      is tried, api.anthropic.com is never contacted.
exec node --no-warnings - <<'NODE'
const dns = require("dns"), net = require("net"), http = require("http"), fs = require("fs"), os = require("os");
const path = require("path"), cp = require("child_process");

const CONTROL = process.env.PROBE_CONTROL === "1";
const METER = process.env.PROBE_METER_URL || "http://meter:8080/healthz";
const DUMMY = process.env.ANTHROPIC_API_KEY || "";
const withTimeout = (p, ms, label) => Promise.race([
  p, new Promise((resolve) => setTimeout(() => resolve({ code: "TIMEOUT", label }), ms)),
]);
const lookup = (name) => withTimeout(new Promise((resolve) =>
  dns.lookup(name, { all: true }, (err, addrs) =>
    resolve(err ? { code: err.code } : { code: "RESOLVED", addrs: addrs.map((a) => a.address) }))), 8000, name);
const tcp = (host, port, ms = 3000) => new Promise((resolve) => {
  const s = net.connect({ host, port, family: 4 });
  const done = (code) => { s.destroy(); resolve({ host, port, code }); };
  s.setTimeout(ms, () => done("TIMEOUT"));
  s.once("connect", () => done("CONNECTED"));
  s.once("error", (e) => done(e.code || "ERROR"));
});
// A refused connection proves the packet arrived, so it counts as reachable.
const blocked = (r) => ["TIMEOUT", "ENETUNREACH", "EHOSTUNREACH", "ENETDOWN", "EACCES", "EPERM"].includes(r.code);
const unresolved = (r) => r.code !== "RESOLVED";

async function hostCheck(name) {
  const res = await lookup(name);
  const out = { dns: res, tcp: [] };
  if (res.code === "RESOLVED")
    for (const addr of res.addrs.filter((a) => a.includes(".")))
      for (const port of [80, 443]) out.tcp.push(await tcp(addr, port));
  out.pass = unresolved(res) && out.tcp.every(blocked);
  return out;
}
async function ipCheck(targets) {
  const out = [];
  for (const [ip, port] of targets) out.push(await tcp(ip, port));
  return { attempts: out, pass: out.length > 0 && out.every(blocked) };
}
function statusField(name) {
  const m = fs.readFileSync("/proc/self/status", "utf8").match(new RegExp(`^${name}:\\s*(\\S+)`, "m"));
  return m ? m[1] : null;
}
const KEY_RE = /sk-ant-[a-z]{3,6}\d{0,2}-[A-Za-z0-9_-]{20,}/;
function scanEnv() {
  const hits = [];
  for (const [k, v] of Object.entries(process.env)) {
    if (k === "ANTHROPIC_API_KEY" && v === DUMMY) continue;
    // The python image exports the public release-signing key id.
    if (k === "GPG_KEY" && /^[0-9A-F]{40}$/.test(v)) continue;
    if (KEY_RE.test(v) || (/(_KEY|_TOKEN|SECRET|PASSWORD)$/i.test(k) && v)) hits.push(k);
  }
  return hits;
}
function scanFiles(roots, limit = 20000) {
  const hits = [];
  let scanned = 0;
  const skip = new Set(["node_modules", ".git", "proc", "sys"]);
  const walk = (dir) => {
    if (scanned >= limit) return;
    let entries;
    try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch { return; }
    for (const e of entries) {
      if (skip.has(e.name)) continue;
      const p = path.join(dir, e.name);
      if (e.isDirectory()) walk(p);
      else if (e.isFile()) {
        scanned += 1;
        try {
          if (fs.statSync(p).size > 2_000_000) continue;
          if (KEY_RE.test(fs.readFileSync(p, "latin1"))) hits.push(p);
        } catch {}
      }
    }
  };
  roots.forEach(walk);
  return { hits, scanned, truncated: scanned >= limit };
}
function dockerSockets() {
  const found = [];
  for (const p of ["/var/run/docker.sock", "/run/docker.sock", "/var/run/docker.sock.raw", "/run/host-services/docker.proxy.sock"])
    if (fs.existsSync(p)) found.push(p);
  try {
    const out = cp.execFileSync("find", ["/", "-xdev", "-type", "s", "-not", "-path", "/proc/*", "-not", "-path", "/sys/*"],
      { stdio: ["ignore", "pipe", "ignore"], timeout: 10000 }).toString();
    for (const line of out.split("\n")) if (/docker/.test(line)) found.push(line);
  } catch (e) {
    if (e.stdout) for (const line of e.stdout.toString().split("\n")) if (/docker/.test(line)) found.push(line);
  }
  return [...new Set(found)];
}
function hostMounts() {
  const suspicious = /\/Users\/|\/host_mnt|docker\.sock|\/run\/desktop/;
  return fs.readFileSync("/proc/self/mountinfo", "utf8").split("\n").filter((l) => suspicious.test(l));
}
const meterCheck = () => new Promise((resolve) => {
  const req = http.get(METER, { timeout: 5000 }, (res) => {
    res.resume();
    res.on("end", () => resolve({ url: METER, status: res.statusCode, pass: res.statusCode === 200 }));
  });
  req.on("timeout", () => { req.destroy(); resolve({ url: METER, status: "TIMEOUT", pass: false }); });
  req.on("error", (e) => resolve({ url: METER, status: e.code, pass: false }));
});

(async () => {
  const r = { kind: CONTROL ? "control" : "probe", checks: {} };
  const c = r.checks;
  if (CONTROL) {
    const res = await lookup("example.com");
    const addr = (res.addrs || []).find((a) => a.includes("."));
    r.control = { example_com_dns: res, example_com_tcp: addr ? await tcp(addr, 443, 6000) : null };
    r.control.egress_detected = res.code === "RESOLVED" && !!r.control.example_com_tcp && r.control.example_com_tcp.code === "CONNECTED";
    r.pass = r.control.egress_detected;
    process.stdout.write(JSON.stringify(r) + "\n");
    process.exit(0);
  }
  c.example_com_name = await hostCheck("example.com");
  c.api_anthropic_com_name = await hostCheck("api.anthropic.com");
  // Literal addresses: Cloudflare/Google resolvers, example.com's published
  // address, and the Anthropic API inbound range from the official IP page.
  c.external_by_ip = await ipCheck([["1.1.1.1", 443], ["1.1.1.1", 53], ["8.8.8.8", 53], ["93.184.215.14", 443], ["23.215.0.136", 443]]);
  c.api_anthropic_by_ip = await ipCheck([["160.79.104.10", 443], ["160.79.105.10", 443]]);
  c.host_docker_internal = await hostCheck("host.docker.internal");
  c.gateway_docker_internal = await hostCheck("gateway.docker.internal");
  c.docker_desktop_host_ips = await ipCheck([["192.168.65.254", 80], ["192.168.65.254", 443], ["192.168.65.1", 80], ["192.168.65.1", 2375]]);
  // With gateway_mode isolated no address is reserved for a gateway, so the
  // meter can legitimately hold the subnet's first address. Peers are excluded;
  // any other answer on a candidate address is a real failure.
  const peers = new Set(Object.values(os.networkInterfaces()).flat().map((i) => i.address));
  const meterName = new URL(METER).hostname;
  const meterAddrs = await lookup(meterName);
  for (const a of meterAddrs.addrs || []) peers.add(a);
  const candidates = (process.env.PROBE_GATEWAY_IPS || "").split(/\s+/).filter(Boolean);
  const gateways = candidates.filter((g) => !peers.has(g));
  c.bridge_gateway = gateways.length
    ? { ...(await ipCheck(gateways.flatMap((g) => [[g, 22], [g, 80], [g, 443], [g, 2375], [g, 5000]]))), candidates, excluded_peers: candidates.filter((g) => peers.has(g)) }
    : { pass: false, note: "no gateway candidates left to test", candidates };
  c.default_route = (() => {
    const lines = fs.readFileSync("/proc/net/route", "utf8").split("\n").slice(1).filter(Boolean);
    const defaults = lines.filter((l) => l.split(/\s+/)[1] === "00000000");
    return { default_routes: defaults.length, pass: defaults.length === 0 };
  })();
  c.meter_reachable = await meterCheck();
  const uid = process.getuid();
  c.non_root = { uid, gid: process.getgid(), pass: uid !== 0 };
  const caps = Object.fromEntries(["CapInh", "CapPrm", "CapEff", "CapBnd", "CapAmb"].map((f) => [f, statusField(f)]));
  c.capabilities = { ...caps, pass: Object.values(caps).every((v) => v && /^0+$/.test(v)) };
  const nnp = statusField("NoNewPrivs");
  c.no_new_privileges = { NoNewPrivs: nnp, pass: nnp === "1" };
  const socks = dockerSockets();
  c.no_docker_socket = { found: socks, pass: socks.length === 0 };
  const mounts = hostMounts();
  c.no_host_mounts = { suspicious: mounts, pass: mounts.length === 0 };
  const envHits = scanEnv();
  c.no_key_in_env = { offending_names: envHits, dummy_key_set: DUMMY.length > 0, pass: envHits.length === 0 };
  const files = scanFiles(["/home", "/work", "/tmp", "/etc", "/root", "/opt", "/data", "/run"]);
  c.no_key_on_filesystem = { ...files, pass: files.hits.length === 0 && !files.truncated };
  r.pass = Object.values(c).every((x) => x.pass === true);
  process.stdout.write(JSON.stringify(r) + "\n");
  process.exit(r.pass ? 0 : 1);
})();
NODE
