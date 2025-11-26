#!/usr/bin/env bash
set -euo pipefail

echo "Running integration tests"

if [[ -z "${RELEASE_BASENAME:-}" ]]; then
  echo "::error::RELEASE_BASENAME is not set"
  exit 1
fi

echo "--------Verify the sha512 signature and decompress the archive --------"

mkdir -p druid
cp -a "${RELEASE_BASENAME}.tar.gz" ./druid/
cp -a "${RELEASE_BASENAME}.tar.gz.sha512" ./druid/

ls -lh ./druid
(cd druid && sha512sum -c "${RELEASE_BASENAME}.tar.gz.sha512")
tar -xzf "druid/${RELEASE_BASENAME}.tar.gz" -C druid


cd "druid/apache-druid-${RELEASE_BASENAME}"

echo "-------- Start Druid (micro-quickstart) and run health checks --------"

nohup bash -lc "./bin/start-micro-quickstart" >/tmp/druid.out 2>&1 &

check_health() {
  local name=$1
  local port=$2
  local retries=120

  echo "Waiting for $name on port $port..."
  for _ in $(seq 1 $retries); do
    if curl -fsS "http://localhost:${port}/status/health" >/dev/null 2>&1; then
      echo "$name is healthy"
      return 0
    fi
    sleep 3
  done

  echo "::error::$name failed after $((retries*3)) seconds"
  exit 1
}

check_health "Router" 8888
check_health "Coordinator" 8081
check_health "Broker" 8082
check_health "Historical" 8083


echo "-------- Load sample data using batch ingestion --------"

TASK_ID=$(curl -X 'POST' -H 'Content-Type:application/json' -d @quickstart/tutorial/wikipedia-index.json http://localhost:8081/druid/indexer/v1/task | jq -r .task)
echo "TASK_ID=$TASK_ID"

for _ in {1..120}; do
  STATUS=$(curl -fsS "http://localhost:8888/druid/indexer/v1/task/${TASK_ID}/status" | jq -r .status.status)
  echo "Status: $STATUS"
  if [ "$STATUS" = "SUCCESS" ]; then echo "Ingestion is successful!"; break; fi
  if [ "$STATUS" = "FAILED" ]; then echo "::error::Ingestion failed"; exit 1; fi
  sleep 3
done

echo "---- ingestion row stats for ${TASK_ID} ----"
curl -s "http://localhost:8081/druid/indexer/v1/task/${TASK_ID}/reports" \
  | jq '.ingestionStatsAndErrors.payload.rowStats' \
  || echo "No rowStats in reports"
echo

echo "-------- WAIT FOR SEGMENTS TO LOAD  --------"

MAX_WAIT=120
WAITED=0

echo "Waiting for segments for datasource wikipedia ..."

while [ $WAITED -lt $MAX_WAIT ]; do
  RESPONSE=$(curl -s -X POST -H "Content-Type: application/json" \
    http://localhost:8888/druid/v2/sql \
    -d '{"query":"SELECT COUNT(*) AS c FROM sys.segments WHERE datasource='\''wikipedia'\''"}')
  CURL_STATUS=$?

  if [ $CURL_STATUS -ne 0 ] || [ -z "$RESPONSE" ]; then
    echo "::error::curl to Druid failed (exit code: $CURL_STATUS)"
    exit 1
  fi

  SEG_COUNT=$(echo "$RESPONSE" | jq -r '.[0].c // 0')

  if [ "$SEG_COUNT" -gt 0 ]; then
    echo "Segments are available: ${SEG_COUNT} segment(s) loaded."
    break
  fi

  echo "No segments yet... waited ${WAITED}s"
  sleep 5
  WAITED=$((WAITED+5))
done

if [ "$SEG_COUNT" -eq 0 ]; then
  echo "::error::Timed out waiting for segments to load."
  exit 1
fi

echo
echo "-------- segments by datasource --------"
curl -s -X POST -H "Content-Type: application/json" \
  http://localhost:8888/druid/v2/sql \
  -d '{"query":"SELECT datasource, COUNT(*) AS segments FROM sys.segments GROUP BY datasource"}'
echo

echo "-------- Run and verify native group-by query --------"

NATIVE=$(curl -X POST -H "Content-Type:application/json" \
  http://localhost:8888/druid/v2 \
  -d @../../.github/workflows/queries/native_query.json)

COUNT=$(jq 'length' <<<"$NATIVE")

if [[ "$COUNT" -ge 1 ]]; then
  echo "Native query is successful. Response contains $COUNT rows"
else
  echo "::error::No rows from native query"
  exit 1
fi


echo "-------- Run and verify SQL query --------"

SQL=$(curl -X POST -H "Content-Type: application/json" \
  http://localhost:8888/druid/v2/sql \
  -d @../../.github/workflows/queries/sql_query.json)

COUNT=$(jq 'length' <<<"$SQL")

if [[ "$COUNT" -ge 1 ]]; then
  echo "SQL is successful. Response contains $COUNT rows"
else
  echo "::error::No rows from SQL"
  exit 1
fi

echo "-------- Run and verify MSQ query --------"

MSQ=$(curl -X POST -H "Content-Type:application/json" \
  http://localhost:8888/druid/v2/sql/statements \
  -d @../../.github/workflows/queries/sql_query.json)

TASK_ID=$(echo "$MSQ" | jq -r '.queryId')

if [[ -z "$TASK_ID" ]]; then
  echo "::error::Failed to extract MSQ task ID"
  exit 1
fi
echo "Task ID is $TASK_ID"

for _ in {1..120}; do
  STATUS=$(curl -fsS "http://localhost:8888/druid/v2/sql/statements/${TASK_ID}" | jq -r .state)
  echo "MSQ status: $STATUS"
  if [ "$STATUS" = "SUCCESS" ]; then echo "Running MSQ query is successful!"; break; fi
  if [ "$STATUS" = "FAILED" ]; then echo "::error::MSQ query failed"; exit 1; fi
  sleep 3
done

COUNT=$(curl -fsS "http://localhost:8888/druid/v2/sql/statements/${TASK_ID}/results" | jq 'length')
if [[ "$COUNT" -ge 1 ]]; then
  echo "MSQ query is successful. Response contains $COUNT rows"
else
  echo "::error::No rows from MSQ query"
  exit 1
fi