#!/bin/bash
set -e

readonly MY_DIR="$( cd "$( dirname "${0}" )" && pwd )"

${MY_DIR}/../image_builder/run_build_image2.sh
${MY_DIR}/check_version.sh
