#!/bin/bash

set -eo pipefail

RANDOM_NAME="test_$(date +%s)"
trap 'docker compose -p $RANDOM_NAME down -v; docker rmi ${RANDOM_NAME}-app' EXIT

STAGE="starting containers"
trap 'echo "failed on" $STAGE; exit 1' ERR

PORT=6767

if (( $# > 0 )); then
    PORT=$1
fi

if ss -l "sport = :$PORT" 2>/dev/null | grep -q LISTEN; then
    echo "Port $PORT is occupied, please select another one by specifying it as first argument then running this script"
    exit 1
fi

get_count()
{
    curl -sf --max-time 5 http://localhost:$PORT | grep -o '"count": [0-9]*' | grep -o '[0-9]*'
}

get_app_status()
{
    curl -s --max-time 5 -o /dev/null -w "%{http_code}" http://localhost:$PORT/healthz
}

get_db_status()
{
    curl -s --max-time 5 -o /dev/null -w "%{http_code}" http://localhost:$PORT/readyz
}

increment()
{
    curl -sf --max-time 5 -X POST -o /dev/null http://localhost:$PORT/increment
}

PORT=$PORT docker compose -p $RANDOM_NAME up -d --build --wait --wait-timeout 60

STAGE="checking 0"
count=$(get_count)
[ "$count" -eq 0 ] 

STAGE="incrementing"
for i in {1..7}; do
    increment
done

STAGE="checking that counter is correct"
count=$(get_count)
[ "$count" -eq 7 ]

STAGE="shutting down and removing app container"
docker compose -p $RANDOM_NAME stop -t 3 app
docker compose -p $RANDOM_NAME rm -f app

STAGE="starting app container again"
PORT=$PORT docker compose -p $RANDOM_NAME up -d --wait --wait-timeout 60 app

STAGE="checking that value is independent from app container"
new_count=$(get_count)
[ "$new_count" -eq "$count" ]

STAGE="shutting down redis"
docker compose -p $RANDOM_NAME stop redis

STAGE="checking db error status"
status=$(get_db_status)
[ "$status" -eq 503 ]

STAGE="checking app status without db"
status=$(get_app_status)
[ "$status" -eq 200 ]

STAGE="starting redis again"
docker compose -p $RANDOM_NAME up -d --wait --wait-timeout 60 redis

STAGE="checking that counter persist after restarting redis"
new_count=$(get_count)
[ "$new_count" -eq "$count" ]

STAGE="stopping containers"
docker compose -p $RANDOM_NAME stop -t 3 app redis

STAGE="backing up"
docker cp "${RANDOM_NAME}-redis-1:/data" ./backup

echo "All checks passed!"

