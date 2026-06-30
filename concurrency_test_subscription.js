import http from 'k6/http';
import { check, sleep } from 'k6';

// Configuración de la carga: 50 usuarios concurrentes
export const options = {
  stages: [
    { duration: '5s', target: 50 },  // Rampa de subida
    { duration: '20s', target: 50 }, // Carga sostenida
    { duration: '5s', target: 0 },   // Rampa de bajada
  ],
  thresholds: {
    http_req_duration: ['p(95)<2000'], // El 95% debe responder en < 2s
  },
};

export default function () {
  const url = 'https://vtfsbogpkrcbfuhhoepf.supabase.co/functions/v1/tenant-actions';
  
  // CORRECCIÓN: Los parámetros deben ir dentro de un objeto "payload"
  const body = JSON.stringify({
    action: 'GET_SUBSCRIPTION_STATUS',
    payload: {
        tenantId: '2124edec-edb3-4374-8d0c-6c6aae4d029f',
        platformId: 'ca9090c3-f6a3-46c3-af1d-6362e2942e5f',
        userId: 'k6_load_tester_user'
    }
  });

  const params = {
    headers: {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InZ0ZnNib2dwa3JjYmZ1aGhvZXBmIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc1MDI4NTQ2NCwiZXhwIjoyMDY1ODYxNDY0fQ.k3oSZ5G7LxRm4VByrTZEo8EjS7woGmVWGNXbEQ4Vbqg',
    },
  };

  const res = http.post(url, body, params);

  const is200 = check(res, {
    'status is 200': (r) => r.status === 200,
  });

  if (is200) {
    check(res, {
      'has data': (r) => r.json().data !== undefined,
    });
  } else {
      console.log(`Failed! Status: ${res.status}, Body: ${res.body}`);
  }

  sleep(0.5);
}
