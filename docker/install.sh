#!/bin/sh -eu

# Records the Java this image holds, in the shape every image shares. The
# installed compiler is asked, so the version is one the image can run rather
# than one written down when someone last edited this file.
# javac -version prints "javac 26.0.2.1", to stderr.
readonly LANGUAGE_VERSION=$(javac -version 2>&1 | cut -d' ' -f2)

if [ -z "${LANGUAGE_VERSION}" ]; then
  echo 'Could not read a version from javac -version' >&2
  exit 1
fi

cat > /versions.json <<EOF
{
  "language": {
    "name": "Java",
    "version": "${LANGUAGE_VERSION}"
  },
  "test_frameworks": []
}
EOF
