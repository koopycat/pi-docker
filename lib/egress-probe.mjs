// Egress probe for PI_DOCKER_EGRESS=gateway, run inside the agent container by
// verify-egress.sh through `pi-project --exec`. Each network check is something
// a hostile agent could try; all must fail except the call through the gateway.
// The script only reports. verify-egress.sh decides about secrets and echoes.
import { lookup } from "node:dns/promises";
import { readFile } from "node:fs/promises";
import { connect } from "node:net";
import { networkInterfaces } from "node:os";

const [upstreamIp, canaryPortArg] = process.argv.slice(1);
const canaryPort = Number(canaryPortArg);
const gatewayUrl = process.env.PI_DOCKER_GATEWAY_URL;
if (!upstreamIp || !canaryPort || !gatewayUrl) {
  throw new Error("usage: egress-probe UPSTREAM_IP HOST_CANARY_PORT (in gateway mode)");
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

async function statusCheck(name, path, expected) {
  const response = await fetch(`${gatewayUrl}${path}`);
  return { name, ok: response.status === expected, detail: `${path} -> ${response.status}` };
}

let echo = null;
async function echoCheck() {
  const response = await fetch(`${gatewayUrl}/custom/echo?probe=1`, {
    headers: { authorization: "Bearer attacker-key", "x-api-key": "attacker-key" },
  });
  echo = await response.text();
  return { name: "gateway forwards the custom route", ok: response.status === 200, detail: `status ${response.status}` };
}

const gateway = bridgeGateway();
const checks = await Promise.all([
  dnsCheck("no external DNS", "example.com"),
  dnsCheck("host.docker.internal unreachable", "host.docker.internal"),
  tcpCheck("no direct IPv4 egress", "1.1.1.1", 443),
  tcpCheck("no direct DNS server", "8.8.8.8", 53),
  tcpCheck("no cloud metadata", "169.254.169.254", 80),
  tcpCheck("no direct IPv6 egress", "2606:4700:4700::1111", 443),
  tcpCheck("upstream only through the gateway", upstreamIp, 8080),
  gateway
    ? tcpCheck("host canary unreachable via the bridge gateway address", gateway, canaryPort, notConnected)
    : { name: "host canary unreachable via the bridge gateway address", ok: false, detail: "no IPv4 interface" },
  statusCheck("gateway rejects unknown routes", "/nope", 403),
  statusCheck("gateway rejects unconfigured providers", "/openai/v1/models", 403),
  echoCheck(),
]);

for (const check of checks) {
  console.log(`CHECK ${check.ok ? "PASS" : "FAIL"} ${check.name} (${check.detail})`);
}
console.log(`ENV ${JSON.stringify(process.env)}`);
console.log(`MODELS ${await readFile(`${process.env.PI_CODING_AGENT_DIR}/models.json`, "utf8").then((text) => JSON.stringify(JSON.parse(text)))}`);
console.log(`ECHO ${echo}`);
