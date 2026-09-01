#!/bin/bash -Eeu

readonly REGEX="image_name\": \"(.*)\""
readonly JSON=`cat docker/image_name.json`
[[ ${JSON} =~ ${REGEX} ]]
readonly IMAGE_NAME="${BASH_REMATCH[1]}"

readonly MY_DIR="$( cd "$( dirname "${0}" )" && pwd )"
# The same version Dockerfile.base names. Both say it, so that a JDK arriving
# here by any route other than that FROM line fails the build rather than
# shipping unnoticed.
readonly EXPECTED='javac 26.0.2.1'
readonly ACTUAL=$(docker run --rm -i ${IMAGE_NAME} sh -c 'javac -version 2>&1')

if echo "${ACTUAL}" | grep -q "${EXPECTED}"; then
  echo "VERSION CONFIRMED as ${EXPECTED}"
else
  echo "VERSION EXPECTED: ${EXPECTED}"
  echo "VERSION   ACTUAL: ${ACTUAL}"
  exit 42
fi
