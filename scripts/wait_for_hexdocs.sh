#!/usr/bin/env bash
set -euo pipefail

url=${1:?Pass the versioned HexDocs URL}
budget=${2:-60}
if [[ ! $budget =~ ^[1-9][0-9]{0,2}$ ]] || (( budget > 120 )); then
  printf 'HexDocs wait requires a budget of 1..120 seconds\n' >&2
  exit 1
fi

started=$SECONDS
deadline=$((started + budget))
attempts=0
http=000
code=0
while (( SECONDS < deadline )); do
  remaining=$((deadline - SECONDS))
  (( remaining > 0 )) || break
  request_seconds=$((remaining < 5 ? remaining : 5))
  attempts=$((attempts + 1))
  if http=$(curl --disable --fail --silent --show-error --location \
      --output /dev/null \
      --write-out '%{http_code}' \
      --max-time "$request_seconds" \
      "$url"); then
    code=0
  else
    code=$?
  fi

  if [[ $code == 0 && $http == 200 ]]; then
    printf 'HexDocs ready after %s attempts (%ss)\n' "$attempts" "$((SECONDS - started))"
    exit 0
  fi

  case "$code:$http" in
    22:404|22:408|22:429|22:5??|6:*|7:*|18:*|28:*|52:*|55:*|56:*) ;;
    *)
      printf 'HexDocs verification failed: HTTP %s, curl %s, attempt %s\n' \
        "$http" "$code" "$attempts" >&2
      exit 1
      ;;
  esac
  if (( SECONDS < deadline )); then sleep 1; fi
done

printf 'HexDocs readiness deadline after %ss: HTTP %s, curl %s, %s attempts\n' \
  "$((SECONDS - started))" "$http" "$code" "$attempts" >&2
exit 1
