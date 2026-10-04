// Egress probe, run inside the agent container by verify-egress.sh through
// `rapunzel --exec`. Each check is something a hostile agent could try; all
// must fail except the intended path out. The script only reports.
// verify-egress.sh decides about secrets and echoes.
//
//   egress-probe strict UPSTREAM_IP UPSTREAM_PORT HOST_CANARY_PORT
//   egress-probe allowlist HOST_CANARY_PORT ALLOWED_HOST [PRIVATE_HOST:PORT reachable|refused]
import { lookup } from "node:dns/promises";
import { readFile } from "node:fs/promises";
import { request } from "node:http";
import { connect } from "node:net";
import { networkInterfaces } from "node:os";
import { connect as tlsConnect } from "node:tls";

const [mode, ...rest] = process.argv.slice(1);
const usage =
  "usage: egress-probe strict UPSTREAM_IP UPSTREAM_PORT HOST_CANARY_PORT | allowlist HOST_CANARY_PORT ALLOWED_HOST [PRIVATE_HOST:PORT reachable|refused]";
let upstreamIp;
let upstreamPort;
let canaryPort;
let allowedHost;
let privateTarget;
let privateExpect;
if (mode === "strict") {
  [upstreamIp, upstreamPort, canaryPort] = [rest[0], Number(rest[1]), Number(rest[2])];
  if (!upstreamIp || !upstreamPort || !canaryPort || !process.env.RAPUNZEL_GATEWAY_URL) throw new Error(usage);
} else if (mode === "allowlist") {
  [canaryPort, allowedHost, privateTarget, privateExpect] = [Number(rest[0]), rest[1], rest[2], rest[3]];
  if (privateTarget && !["reachable", "refused"].includes(privateExpect)) throw new Error(usage);
  if (!canaryPort || !allowedHost || !process.env.HTTPS_PROXY) throw new Error(usage);
} else {
  throw new Error(usage);
}

function tcp(host, port, timeoutMs = 3000) {
  return new Promise((resolve) => {
    const socket = connect({ host, port });
    const done = (outcome) => {
      socket.destroy();
      resolve(outcome);
    };
    socket.setTimeout(timeoutMs, () => done("timeout"));
    socket.once("connect", () => done("connected"));
    socket.once("error", (error) => done(error.code ?? String(error)));
  });
}

// Off-network addresses must not answer at all; a refusal would mean a packet
// left the network. On-link addresses may be refused by Docker's own reject
// rules, so those are judged by the host canary listener instead.
const unreachable = (outcome) => outcome !== "connected" && outcome !== "ECONNREFUSED";
const notConnected = (outcome) => outcome !== "connected";

function bridgeGateway() {
  for (const addresses of Object.values(networkInterfaces())) {
    for (const address of addresses ?? []) {
      if (address.family !== "IPv4" || address.internal) continue;
      const ip = address.address.split(".").map(Number);
      const mask = address.netmask.split(".").map(Number);
      const network = ip.map((octet, index) => octet & mask[index]);
      network[3] += 1;
      return network.join(".");
    }
  }
  return undefined;
}

async function resolves(name) {
  try {
    return (await lookup(name)).address;
  } catch {
    return undefined;
  }
}

async function tcpCheck(name, host, port, judge = unreachable) {
  const outcome = await tcp(host, port);
  return { name, ok: judge(outcome), detail: `${host}:${port} ${outcome}` };
}

async function dnsCheck(name, host) {
  const address = await resolves(host);
  if (!address) return { name, ok: true, detail: `${host} does not resolve` };
  const outcome = await tcp(address, canaryPort);
  return {
    name,
    ok: notConnected(outcome),
    detail: `${host} resolves to ${address}, canary port ${canaryPort} ${outcome}`,
  };
}

function networkChecks() {
  const gateway = bridgeGateway();
  return [
    dnsCheck("no external DNS", "example.com"),
    dnsCheck("host.docker.internal unreachable", "host.docker.internal"),
    tcpCheck("no direct IPv4 egress", "1.1.1.1", 443),
    tcpCheck("no direct DNS server", "8.8.8.8", 53),
    tcpCheck("no cloud metadata", "169.254.169.254", 80),
    tcpCheck("no direct IPv6 egress", "2606:4700:4700::1111", 443),
    gateway
      ? tcpCheck("host canary unreachable via the bridge gateway address", gateway, canaryPort, notConnected)
      : { name: "host canary unreachable via the bridge gateway address", ok: false, detail: "no IPv4 interface" },
  ];
}

// --- strict: the credential gateway -------------------------------------

let echo = null;
async function strictChecks() {
  const gatewayUrl = process.env.RAPUNZEL_GATEWAY_URL;
  const status = async (name, path, expected) => {
    const response = await fetch(`${gatewayUrl}${path}`);
    return { name, ok: response.status === expected, detail: `${path} -> ${response.status}` };
  };
  const echoCheck = async () => {
    const response = await fetch(`${gatewayUrl}/custom/echo?probe=1`, {
      headers: { authorization: "Bearer attacker-key", "x-api-key": "attacker-key" },
    });
    echo = await response.text();
    return { name: "gateway forwards the custom route", ok: response.status === 200, detail: `status ${response.status}` };
  };
  return [
    tcpCheck("upstream only through the gateway", upstreamIp, upstreamPort),
    status("gateway rejects unknown routes", "/nope", 403),
    status("gateway rejects unconfigured providers", "/openai/v1/models", 403),
    echoCheck(),
  ];
}

// --- allowlist: the CONNECT proxy ---------------------------------------

const proxy = new URL(process.env.HTTPS_PROXY ?? "http://invalid:1");

// Open a CONNECT tunnel; resolves to { status, socket }.
function tunnel(target) {
  return new Promise((resolve) => {
    const req = request({ host: proxy.hostname, port: proxy.port, method: "CONNECT", path: target, timeout: 8000 });
    req.once("connect", (response, socket) => {
      if (response.statusCode !== 200) socket.destroy();
      resolve({ status: response.statusCode, socket });
    });
    req.once("error", (error) => resolve({ status: error.code ?? String(error) }));
    req.once("timeout", () => {
      req.destroy();
      resolve({ status: "timeout" });
    });
    req.end();
  });
}

// Speak TLS with SERVERNAME (or none) through a tunnel to TARGET and report
// the upstream's HTTP status line, or why there was none.
async function tlsThroughTunnel(target, servername, rejectUnauthorized = true) {
  const opened = await tunnel(target);
  if (opened.status !== 200) return `CONNECT ${opened.status}`;
  return new Promise((resolve) => {
    const socket = tlsConnect({ socket: opened.socket, servername, rejectUnauthorized, ALPNProtocols: ["http/1.1"] });
    let settled = false;
    const done = (outcome) => {
      if (settled) return;
      settled = true;
      socket.destroy();
      resolve(outcome);
    };
    let buffer = "";
    socket.setTimeout(8000, () => done("timeout"));
    socket.once("secureConnect", () => {
      socket.write(`GET / HTTP/1.1\r\nHost: ${servername || target}\r\nConnection: close\r\n\r\n`);
    });
    socket.on("data", (chunk) => {
      buffer += chunk;
      const match = buffer.match(/^HTTP\/1\.[01] (\d{3})/);
      if (match) done(`HTTP ${match[1]}`);
    });
    socket.once("error", (error) => done(`TLS ${error.code ?? error.message}`));
    socket.once("close", () => done("closed"));
  });
}

// Send plaintext HTTP through a tunnel, as a smuggling attempt would.
async function plaintextThroughTunnel(target) {
  const opened = await tunnel(target);
  if (opened.status !== 200) return `CONNECT ${opened.status}`;
  return new Promise((resolve) => {
    const socket = opened.socket;
    let buffer = "";
    const done = (outcome) => {
      socket.destroy();
      resolve(outcome);
    };
    socket.setTimeout(8000, () => done("timeout"));
    socket.on("data", (chunk) => {
      buffer += chunk;
      const match = buffer.match(/^HTTP\/1\.[01] (\d{3})/);
      if (match) done(`HTTP ${match[1]}`);
    });
    socket.once("error", (error) => done(error.code ?? String(error)));
    socket.once("close", () => done("closed"));
    socket.write(`GET / HTTP/1.1\r\nHost: ${target}\r\nConnection: close\r\n\r\n`);
  });
}

// Ask the proxy itself for PATH, e.g. an absolute-form http:// request.
function proxyRequest(path) {
  return new Promise((resolve) => {
    const req = request({ host: proxy.hostname, port: proxy.port, path, timeout: 8000 });
    req.once("response", (response) => {
      response.resume();
      resolve(response.statusCode);
    });
    req.once("error", (error) => resolve(error.code ?? String(error)));
    req.once("timeout", () => {
      req.destroy();
      resolve("timeout");
    });
    req.end();
  });
}

async function allowlistChecks() {
  const target = `${allowedHost}:443`;
  const noUpstreamResponse = (outcome) => !outcome.startsWith("HTTP ");
  const check = async (name, run, ok) => {
    const outcome = await run();
    return { name, ok: ok(outcome), detail: String(outcome) };
  };
  return [
    check(
      "allowed host reachable with fetch through HTTPS_PROXY",
      async () => {
        try {
          return `HTTP ${(await fetch(`https://${allowedHost}/`, { signal: AbortSignal.timeout(10000) })).status}`;
        } catch (error) {
          return `error ${error.cause?.message ?? error.message}`;
        }
      },
      (outcome) => outcome.startsWith("HTTP "),
    ),
    check("tunnel with matching SNI works", () => tlsThroughTunnel(target, allowedHost), (o) => o.startsWith("HTTP ")),
    check(
      "other hosts refused",
      async () => {
        try {
          return `HTTP ${(await fetch("https://example.com/", { signal: AbortSignal.timeout(10000) })).status}`;
        } catch (error) {
          return `error ${error.cause?.message ?? error.message}`;
        }
      },
      (outcome) => !outcome.startsWith("HTTP "),
    ),
    check("SNI must match the CONNECT host", () => tlsThroughTunnel(target, "www.cloudflare.com"), noUpstreamResponse),
    check("TLS without SNI refused", () => tlsThroughTunnel(target, ""), noUpstreamResponse),
    check("plaintext inside a tunnel refused", () => plaintextThroughTunnel(target), noUpstreamResponse),
    check("IP literal refused", async () => (await tunnel("1.1.1.1:443")).status, (s) => s !== 200),
    check("cloud metadata refused", async () => (await tunnel("169.254.169.254:80")).status, (s) => s !== 200),
    check("host.docker.internal refused", async () => (await tunnel("host.docker.internal:443")).status, (s) => s !== 200),
    check("plain http:// to other hosts refused", () => proxyRequest("http://example.com/"), (s) => s !== 200),
    check("proxy /stats not exposed", () => proxyRequest("/stats"), (s) => s !== 200),
    check("proxy /fetch refuses other hosts", () => proxyRequest("/fetch?url=https://example.com/"), (s) => s !== 200),
    // A host that resolves to a private address, served by a self-signed
    // test server: only RAPUNZEL_EGRESS_ALLOW_PRIVATE may make it reachable.
    ...(privateTarget
      ? [
          check(
            `private host ${privateExpect}`,
            () => tlsThroughTunnel(privateTarget, privateTarget.replace(/:\d+$/, ""), false),
            (outcome) => (privateExpect === "reachable") === outcome.startsWith("HTTP "),
          ),
        ]
      : []),
  ];
}

const checks = await Promise.all([
  ...networkChecks(),
  ...(mode === "strict" ? await strictChecks() : await allowlistChecks()),
]);

for (const check of checks) {
  console.log(`CHECK ${check.ok ? "PASS" : "FAIL"} ${check.name} (${check.detail})`);
}
console.log(`ENV ${JSON.stringify(process.env)}`);
if (mode === "strict") {
  console.log(`MODELS ${await readFile(`${process.env.PI_CODING_AGENT_DIR}/models.json`, "utf8").then((text) => JSON.stringify(JSON.parse(text)))}`);
  console.log(`ECHO ${echo}`);
}
// Pooled keep-alive connections would otherwise hold the process open.
process.exit(0);
