import http from "k6/http";
import { check } from "k6";

const BASE_URL = __ENV.BASE_URL || "http://localhost:8080";
const DURATION = __ENV.DURATION || "2m";
const EVENT_ID = __ENV.EVENT_ID || "show-carga";
const CONTRATOS_RPS = parseInt(__ENV.CONTRATOS_RPS || "20");
const CHECKOUT_RPS = parseInt(__ENV.CHECKOUT_RPS || "40");
const EXPORT_VUS = parseInt(__ENV.EXPORT_VUS || "1");
const EXPORT_RECORDS = parseInt(__ENV.EXPORT_RECORDS || "200000");
const JSON_HEADERS = { headers: { "Content-Type": "application/json" } };

http.setResponseCallback(http.expectedStatuses(200, 201, 409));

function rampTo(target) {
  return [
    { duration: "30s", target },
    { duration: DURATION, target },
    { duration: "15s", target: 0 },
  ];
}

export const options = {
  scenarios: {
    contratos: {
      executor: "ramping-arrival-rate",
      exec: "createContract",
      startRate: 1,
      timeUnit: "1s",
      stages: rampTo(CONTRATOS_RPS),
      preAllocatedVUs: 20,
      maxVUs: 100,
    },
    checkout: {
      executor: "ramping-arrival-rate",
      exec: "checkout",
      startRate: 1,
      timeUnit: "1s",
      stages: rampTo(CHECKOUT_RPS),
      preAllocatedVUs: 30,
      maxVUs: 150,
    },
    export: {
      executor: "constant-vus",
      exec: "exportReport",
      vus: EXPORT_VUS,
      duration: DURATION,
      startTime: "30s",
    },
  },
  thresholds: {
    http_req_failed: ["rate<0.02"],
    "http_req_duration{scenario:contratos}": ["p(95)<500"],
    "http_req_duration{scenario:checkout}": ["p(95)<500"],
    "checks{scenario:contratos}": ["rate>0.98"],
    "checks{scenario:checkout}": ["rate>0.98"],
  },
};

export function createContract() {
  const payload = JSON.stringify({
    title: `Contrato carga ${__VU}-${__ITER}`,
    userId: `user-${__VU}`,
    description: "Gerado pelo teste de carga",
    value: 100,
  });
  const res = http.post(`${BASE_URL}/contratos/contracts`, payload, JSON_HEADERS);
  check(res, { "contrato criado (201)": (r) => r.status === 201 });
}

export function checkout() {
  const payload = JSON.stringify({ eventId: EVENT_ID, userId: `user-${__VU}`, quantity: 1 });
  const res = http.post(`${BASE_URL}/flash-sales/checkout`, payload, JSON_HEADERS);
  check(res, { "checkout processado (201 ou 409 esgotado)": (r) => r.status === 201 || r.status === 409 });
}

export function exportReport() {
  const res = http.post(
    `${BASE_URL}/flash-sales/tickets/export`,
    JSON.stringify({ records: EXPORT_RECORDS }),
    { ...JSON_HEADERS, timeout: "120s" },
  );
  check(res, { "exportação concluída (200)": (r) => r.status === 200 });
}
